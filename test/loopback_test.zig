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
//! spawned on the *caller's* group: each test runs both sides on one group,
//! and awaiting that group drives the call and both readers together, each
//! yielding to the other at its own blocking point.
//!
//! A connection ends by its peer hanging up. The client has to unblock its own
//! reader to get there, and a `close` does not interrupt a `read` already
//! blocked on the descriptor, so its task shuts the stream down before it
//! closes it. Both readers then see end of file and both pumps return. The
//! accepted side has no caller left to close it, so its reader closes the
//! stream as it returns, rather than leaving the descriptor to the process.
//! The group then completes on its own. There is no sleep and no arbitrary
//! timeout in this file, so a pass means the exchange finished rather than
//! that the test waited long enough to look.

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
    /// One encode buffer and one result buffer per call, plus a third encode
    /// buffer for the notification. Two frames or two answers that shared one
    /// of them would overwrite the bytes an assertion is about.
    out: [1024]u8 = undefined,
    second_out: [1024]u8 = undefined,
    notify_out: [1024]u8 = undefined,
    result: [1024]u8 = undefined,
    second_result: [1024]u8 = undefined,
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
        // Only the first, so a later call on the same connection cannot
        // overwrite what the assertion is about.
        if (self.saw_len == 0) {
            const name = message.method.?.text;
            const n = @min(name.len, self.saw_method.len);
            @memcpy(self.saw_method[0..n], name[0..n]);
            self.saw_len = n;
        }

        // The scratch is this connection's handler buffer, so the answer can
        // borrow it for as long as the write takes. The result carries the id
        // the peer was asked for, so the two answers this test collects are
        // different bytes and neither can be mistaken for the other.
        var writer = json.Writer.init(scratch);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        var id_buffer: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{message.id.?.integer}) catch return null;
        writer.slice(id_text) catch return null;
        writer.slice(",\"result\":{\"resultType\":\"complete\",\"call\":") catch return null;
        writer.slice(id_text) catch return null;
        writer.slice("}}") catch return null;
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
    /// Set on the accepted side, which has no caller left to close its stream.
    /// Its reader closes the stream as it returns, so a test that waits for
    /// end of file does not also need the process to exit to release the
    /// descriptor.
    close_on_end_of_stream: bool = false,

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
        group.async(io, Endpoint.pump, .{self});
    }

    /// Read until the transport ends, then release the stream if this side is
    /// the one that closes it.
    fn pump(self: *Endpoint) void {
        self.connection.pump();
        if (self.close_on_end_of_stream) self.stream.close(self.connection.io);
    }
};

fn socketPath(buffer: []u8, id: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "/tmp/zig-agent-proto-test-{x}.sock", .{id});
}

/// What the client task leaves for the test, and how much of each encode
/// buffer is a frame.
///
/// The three lengths are the number of bytes the encode really wrote, taken
/// inside the task right after that encode. An assertion reads an encode
/// buffer only through the length of the frame in it, so it never reads a
/// byte the client did not write.
const Observed = struct {
    /// The first answer, borrowing the first call's result buffer.
    first_answer: conn.Response = undefined,
    /// The second answer, borrowing the second call's own result buffer.
    second_answer: conn.Response = undefined,
    first_request: usize = 0,
    second_request: usize = 0,
    notification: usize = 0,
};

test "each answer is matched to its own call over a real socket" {
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
    var observed: Observed = .{};
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
            // The accepted side has no caller left to close it, so its reader
            // closes it when the client hangs up.
            self.endpoint.close_on_end_of_stream = true;
            self.endpoint.open(self.io, self.group, stream, self.handler);
        }
    };

    const Client = struct {
        io: Io,
        group: *Io.Group,
        address: *const Io.net.UnixAddress,
        endpoint: *Endpoint,
        observed: *Observed,
        failed: *bool,
        method: []const u8,
        params: ?[]const u8,
        notify_after: bool,

        /// Send the progress notification and record how many bytes the
        /// encode wrote. A notification that fails writes nothing, so the
        /// recorded length stays zero and the test reads no bytes rather than
        /// reads a buffer the client never wrote to.
        fn notifyProgress(self: *@This()) void {
            self.endpoint.connection.notify(
                "notifications/progress",
                "{\"progress\":1}",
                &self.endpoint.side.notify_out,
            ) catch {
                self.observed.notification = 0;
                return;
            };
            self.observed.notification = self.endpoint.connection.lastEncodedLen();
        }

        fn run(self: *@This()) void {
            const stream = self.address.connect(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, null);
            const side = &self.endpoint.side;
            self.observed.first_answer = self.endpoint.connection.call(
                self.method,
                self.params,
                &side.result,
                &side.out,
            ) catch {
                self.failed.* = true;
                return;
            };
            self.observed.first_request = self.endpoint.connection.lastEncodedLen();
            // A second call on the same connection is a genuinely different
            // request. Two calls sharing an id would let one steal the other's
            // answer, and the multi-round-trip rule requires a retry to be a
            // new call, so this is the assertion that keeps a reused id from
            // passing silently. The second call has its own result and encode
            // buffers: a shared result buffer would let its answer rewrite the
            // bytes the first answer still borrows, and the assertion on the
            // first answer would then read the second answer's bytes.
            self.observed.second_answer = self.endpoint.connection.call(
                "tools/list",
                null,
                &side.second_result,
                &side.second_out,
            ) catch {
                self.failed.* = true;
                return;
            };
            self.observed.second_request = self.endpoint.connection.lastEncodedLen();
            if (self.notify_after) {
                // Plant an id in the tail of the buffer the notification
                // encodes into. The frame covers the start of that buffer and
                // the assertion reads only the frame, so a scan that runs past
                // the recorded length finds this id and fails, rather than
                // passes on whatever the stack held in the tail before.
                const out = &side.notify_out;
                out[out.len - 1] = '"';
                out[out.len - 2] = 'd';
                out[out.len - 3] = 'i';
                out[out.len - 4] = '"';
                self.notifyProgress();
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
        .observed = &observed,
        .failed = &call_failed,
        .method = "tools/call",
        .params = "{\"name\":\"echo\"}",
        .notify_after = true,
    };
    group.async(io, Peer.run, .{&peer});
    group.async(io, Client.run, .{&client});
    group.await(io) catch {};

    try testing.expect(!call_failed);

    // Each answer came back over the socket, matched to the call that asked
    // for it by its own id. The peer stamps every result with the id it was
    // asked for, so an answer read out of the other call's buffer would carry
    // the other id and fail here instead of passing under the wrong name.
    try testing.expectEqual(@as(?i32, null), observed.first_answer.error_code);
    try testing.expectEqualStrings(
        "{\"resultType\":\"complete\",\"call\":1}",
        observed.first_answer.body,
    );
    try testing.expectEqual(@as(?i32, null), observed.second_answer.error_code);
    try testing.expectEqualStrings(
        "{\"resultType\":\"complete\",\"call\":2}",
        observed.second_answer.body,
    );

    // Each request went out as one well-formed frame with its own id, read
    // through the length its own encode recorded. A read past that length
    // would take in bytes that are not part of the frame.
    try testing.expect(std.mem.startsWith(
        u8,
        client_endpoint.side.out[0..observed.first_request],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"",
    ));
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
        client_endpoint.side.second_out[0..observed.second_request],
    );

    // The peer really read the method, so its reader ran, decoded, dispatched
    // and answered.
    try testing.expectEqualStrings("tools/call", handler_state.saw_method[0..handler_state.saw_len]);

    // Two calls on one connection got two different ids.
    try testing.expectEqual(@as(i64, 3), client_endpoint.connection.nextId());

    // The notification went out as a frame with no id at all, over the bytes
    // its own encode wrote. An id here would make the peer wait for a
    // response this library never sends.
    const notification = client_endpoint.side.notify_out[0..observed.notification];
    try testing.expect(std.mem.startsWith(
        u8,
        notification,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"",
    ));
    try testing.expect(std.mem.indexOf(u8, notification, "\"id\"") == null);

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
            // The accepted side has no caller left to close it, so its reader
            // closes it when the client hangs up.
            self.endpoint.close_on_end_of_stream = true;
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
