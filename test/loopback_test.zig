//! End-to-end proof that a connection actually works over a real socket.
//!
//! The unit tests drive the framer and the encoder against slices. That cannot
//! catch the failures that matter most here: a reader task that never runs, a
//! pending slot that is never signalled, and a response delivered to the wrong
//! caller. All three only appear with a real socket, a real `Io`, and two real
//! tasks.
//!
//! The two sides run in one process over a Unix domain socket in a temporary
//! directory. The bytes cross a kernel socket exactly as they would between two
//! processes, and unlike a TCP port there is no race over which port the kernel
//! handed out, so the test is deterministic under parallel runs.
//!
//! ## Where the reader task goes, and why it matters
//!
//! `Io.Group.async` does not promise to run its task until `await` or `cancel`
//! is called. A reader parked on a group that nobody joins simply never starts,
//! and the call waiting for its response waits forever. So the reader is
//! spawned on the *caller's* group: the test joins one group per side, and
//! awaiting it drives the call and its reader together, each yielding to the
//! other at its own blocking point.
//!
//! A connection ends by its peer hanging up. The client's task closes its
//! stream, both readers see end of file, both pumps return, and both groups
//! complete on their own. There is no sleep and no arbitrary timeout in this
//! file, so a pass means the exchange finished rather than that the test waited
//! long enough to look.

const std = @import("std");
const proto = @import("zig-agent-proto");
const conn = proto.conn;
const json = proto.json;
const jsonrpc = proto.jsonrpc;

const Io = std.Io;
const testing = std.testing;

/// The buffers one side needs. Caller-owned, so a test cannot hide a leak in
/// the connection behind a test-side allocation.
const Side = struct {
    frame_buffer: [8192]u8 = undefined,
    pending: [8]conn.Slot = undefined,
    decode_scratch: [1024]u8 = undefined,
    handler_scratch: [1024]u8 = undefined,
    out: [1024]u8 = undefined,
    /// A second encode buffer, so a notification cannot overwrite the request
    /// the test still wants to assert on.
    notify_out: [1024]u8 = undefined,
    result: [1024]u8 = undefined,
};

/// A peer that answers every request and records what it was asked.
///
/// The reply is a real JSON-RPC response envelope carrying the request's own
/// id, not a bare result object. That is the whole point: a response is only
/// matched to a call by its id, so a peer that answers with something the
/// protocol does not define leaves the caller waiting forever, and a
/// connection that quietly accepted one would hide a whole class of server bug.
const TestHandler = struct {
    saw_method: [64]u8 = undefined,
    saw_len: usize = 0,
    notifications: usize = 0,
    reply: []const u8 = "{\"resultType\":\"complete\"}",

    fn handle(ctx: ?*anyopaque, frame: []const u8, scratch: []u8) conn.Error!?[]const u8 {
        const self: *TestHandler = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(frame, scratch) catch return null;
        switch (message.kind) {
            .notification => {
                self.notifications += 1;
                return null;
            },
            .response => return null,
            .request => {},
        }
        const name = message.method.?.text;
        const n = @min(name.len, self.saw_method.len);
        @memcpy(self.saw_method[0..n], name[0..n]);
        self.saw_len = n;

        // The scratch is this connection's handler buffer, so the answer can
        // borrow it for as long as the write takes.
        var writer = json.Writer.init(scratch);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        var id_buffer: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{message.id.?.integer}) catch return null;
        writer.slice(id_text) catch return null;
        writer.slice(",\"result\":") catch return null;
        writer.slice(self.reply) catch return null;
        writer.byte('}') catch return null;
        return writer.written();
    }
};

/// Answers every request with a JSON-RPC error object, which is the case where
/// a connection that only reads `result` silently reports success.
fn errorReply(_: ?*anyopaque, _: []const u8, _: []u8) conn.Error!?[]const u8 {
    return "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"no such method\"}}";
}

/// One connection plus the buffers, reader, writer and socket backing it.
const Endpoint = struct {
    side: Side = .{},
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned, which faults on the first read rather than at the call.
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    stream: Io.net.Stream = undefined,
    connection: conn.Conn = undefined,

    /// Start the connection and spawn its reader on `group`.
    fn open(
        self: *Endpoint,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) void {
        self.stream = stream;
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = conn.Conn.init(io, &self.reader.interface, &self.writer.interface, .{
            .frame_buffer = &self.side.frame_buffer,
            .pending = &self.side.pending,
            .decode_scratch = &self.side.decode_scratch,
            .handler_scratch = &self.side.handler_scratch,
        });
        if (handler) |h| self.connection.setHandler(h);
        group.async(io, pump, .{&self.connection});
    }

    fn pump(c: *conn.Conn) void {
        c.pump();
    }
};

fn socketPath(buffer: []u8, id: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "/tmp/zig-agent-proto-test-{x}.sock", .{id});
}

test "a client and a server complete a request over a real socket" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    const path = try socketPath(&path_buffer, 0x5eed_0001);
    // A socket file left by a killed run would make listen fail.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var peer_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};
    var handler_state: TestHandler = .{};
    var answer: conn.Response = undefined;
    var call_failed: bool = false;

    const Peer = struct {
        io: Io,
        group: *Io.Group,
        server: *Io.net.Server,
        endpoint: *Endpoint,
        handler: conn.Handler,
        failed: *bool,

        /// Accept one connection and let its reader run on the same group.
        fn run(self: *@This()) void {
            const stream = self.server.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, self.handler);
        }
    };

    const Client = struct {
        io: Io,
        group: *Io.Group,
        address: *const Io.net.UnixAddress,
        endpoint: *Endpoint,
        answer: *conn.Response,
        failed: *bool,
        method: []const u8,
        params: ?[]const u8,
        notify_after: bool,

        fn run(self: *@This()) void {
            const stream = self.address.connect(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, null);
            self.answer.* = self.endpoint.connection.call(
                self.method,
                self.params,
                &self.endpoint.side.result,
                &self.endpoint.side.out,
            ) catch {
                self.failed.* = true;
                return;
            };
            if (self.notify_after) {
                self.endpoint.connection.notify(
                    "notifications/progress",
                    "{\"progress\":1}",
                    &self.endpoint.side.notify_out,
                ) catch {};
            }
            // Hang up. `shutdown` before `close`, because closing a file
            // descriptor does not interrupt a `read` already blocked on it:
            // the reader would sit on an open file description forever and
            // the group would never finish. A transport must unblock its
            // peers this way, so it is part of the contract, not a detail.
            self.endpoint.stream.shutdown(self.io, .both) catch {};
            self.endpoint.stream.close(self.io);
        }
    };

    // One group drives both sides. Two would deadlock: the client blocks
    // waiting for an answer only the peer's task can produce, so awaiting the
    // client group first would never let the peer run.
    var group: Io.Group = .init;
    var peer = Peer{
        .io = io,
        .group = &group,
        .server = &server,
        .endpoint = &peer_endpoint,
        .handler = .{ .ctx = &handler_state, .call = TestHandler.handle },
        .failed = &call_failed,
    };
    var client = Client{
        .io = io,
        .group = &group,
        .address = &address,
        .endpoint = &client_endpoint,
        .answer = &answer,
        .failed = &call_failed,
        .method = "tools/call",
        .params = "{\"name\":\"echo\"}",
        .notify_after = true,
    };
    group.async(io, Peer.run, .{&peer});
    group.async(io, Client.run, .{&client});
    group.await(io) catch {};

    try testing.expect(!call_failed);
    // The response really came back over the socket and was decoded, not
    // synthesised by the test.
    try testing.expectEqual(@as(?i32, null), answer.error_code);
    try testing.expectEqualStrings("{\"resultType\":\"complete\"}", answer.body);

    // The request really went out as one well-formed frame with a real id.
    try testing.expect(std.mem.startsWith(
        u8,
        client_endpoint.side.out[0..],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"",
    ));

    // The peer really read the method, so its reader ran, decoded, dispatched
    // and answered.
    try testing.expectEqualStrings("tools/call", handler_state.saw_method[0..handler_state.saw_len]);

    // The notification went out as a frame with no id at all. An id here would
    // make the peer wait for a response that this library never sends.
    try testing.expect(std.mem.startsWith(
        u8,
        client_endpoint.side.notify_out[0..],
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"",
    ));
    try testing.expect(std.mem.indexOf(u8, client_endpoint.side.notify_out[0..], "\"id\"") == null);

    // The notification was delivered and correctly expected no answer.
    try testing.expectEqual(@as(usize, 1), handler_state.notifications);
}

test "a peer error answer is reported as an error, not as a result" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    const path = try socketPath(&path_buffer, 0x5eed_0002);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var peer_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};
    var answer: conn.Response = undefined;
    var failed: bool = false;

    const Peer = struct {
        io: Io,
        group: *Io.Group,
        server: *Io.net.Server,
        endpoint: *Endpoint,
        failed: *bool,

        fn run(self: *@This()) void {
            const stream = self.server.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, .{ .call = errorReply });
        }
    };

    const Client = struct {
        io: Io,
        group: *Io.Group,
        address: *const Io.net.UnixAddress,
        endpoint: *Endpoint,
        answer: *conn.Response,
        failed: *bool,

        fn run(self: *@This()) void {
            const stream = self.address.connect(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, null);
            self.answer.* = self.endpoint.connection.call(
                "nosuch/method",
                null,
                &self.endpoint.side.result,
                &self.endpoint.side.out,
            ) catch {
                self.failed.* = true;
                return;
            };
            // Shutdown before close, for the reason given in the first test:
            // closing does not interrupt a read already blocked on the fd.
            self.endpoint.stream.shutdown(self.io, .both) catch {};
            self.endpoint.stream.close(self.io);
        }
    };

    // One group drives both sides. Two would deadlock: the client blocks
    // waiting for an answer only the peer's task can produce, so awaiting the
    // client group first would never let the peer run.
    var group: Io.Group = .init;
    var peer = Peer{
        .io = io,
        .group = &group,
        .server = &server,
        .endpoint = &peer_endpoint,
        .failed = &failed,
    };
    var client = Client{
        .io = io,
        .group = &group,
        .address = &address,
        .endpoint = &client_endpoint,
        .answer = &answer,
        .failed = &failed,
    };
    group.async(io, Peer.run, .{&peer});
    group.async(io, Client.run, .{&client});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expectEqual(@as(?i32, -32601), answer.error_code);
    try testing.expect(std.mem.indexOf(u8, answer.body, "no such method") != null);
}
