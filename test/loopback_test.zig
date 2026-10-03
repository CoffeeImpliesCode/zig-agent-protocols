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
//! Blocking peers and readers need `Io.Group.concurrent`: `async` may run
//! inline when the executor reaches its async limit, leaving the caller unable
//! to send the request its reader is waiting for. A refused concurrent spawn
//! is propagated rather than converted into a socket failure.
//! Each test owns both sides on one group and joins or cancels every task
//! before releasing its buffers and connection state.
//!
//! A connection ends by its peer hanging up. The client has to unblock its own
//! reader to get there, and a `close` does not interrupt a `read` already
//! blocked on the descriptor, so its task shuts the stream down to wake that
//! read. Both readers then see end of file and both pumps return, and the
//! group completes on its own.
//!
//! The descriptor is closed by the test that owns both endpoints, not by the
//! reader that drained it. A reader is not the only task on its socket — the
//! calling side writes every request on it from a task of its own, and a
//! handler answers on the very task that is reading — so a close from the pump
//! takes the descriptor away from a write in flight and aborts the process on
//! the `EBADF` that follows, which kills the whole binary rather than failing
//! one test. Each test joins its group first and releases both endpoints
//! second, and the join is what makes this frame the only task left on either
//! descriptor.
//!
//! There is no sleep and no arbitrary timeout in this file, so a pass means the
//! exchange finished rather than that the test waited long enough to look.

const std = @import("std");
const proto = @import("zig-agent-proto");

/// The socket-name helper, development-only and not part of the library's
/// public API. This file is rooted in `test/`, so it reaches `src/testio.zig`
/// as a module the build names rather than by a relative path: `../src` is
/// outside this module's own directory. The build step that compiles this file
/// is the one that carries that name.
const testio = @import("testio");

const conn = proto.conn;
const json = proto.json;
const jsonrpc = proto.jsonrpc;

const Io = std.Io;
const testing = std.testing;

/// The buffers one side needs. Caller-owned, so a test cannot hide a leak in
/// the connection behind a test-side allocation.
///
/// `Conn.init` refuses a region with no room and refuses two that share a
/// byte, both before it clears the slot table, so every length here is
/// deliberately non-zero and no two of these regions touch. The sizes are far
/// more than the test exchanges — the largest frame either side sends is a
/// notification under a hundred bytes — because a buffer bound is not what is
/// under test here; the wire is.
const Side = struct {
    // SAFETY: Conn.init binds it to the framer, which writes into it and reads only start..end from zero.
    frame_buffer: [8192]u8 = undefined,
    // SAFETY: Conn.init writes every slot to `.{}` before it stores the table, so no `used` flag is read unwritten.
    pending: [8]conn.Slot = undefined,
    /// Where an inbound frame is decoded, and the region a handler is handed
    /// to decode one into.
    // SAFETY: Each decode writes the text it returns; it is read only as slices that decode produced.
    decode_scratch: [1024]u8 = undefined,
    /// Where a handler writes its answer. Separate from `decode_scratch`
    /// because the escape offset `json.Reader` keeps is per reader and not per
    /// buffer: a decode and a write into one region both start at offset 0 and
    /// overwrite each other.
    // SAFETY: A handler writes into it and returns `writer.written()`, so a read is bounded by what was written.
    answer: [1024]u8 = undefined,
    /// One encode buffer and one result buffer per call, plus a third encode
    /// buffer for the notification. Two frames or two answers that shared one
    /// of them would overwrite the bytes an assertion is about.
    // SAFETY: Read only as `out[0..lastEncodedLen()]`, the count the encode recorded after writing.
    out: [1024]u8 = undefined,
    // SAFETY: Same as `out`: read only as `second_out[0..second_request]`, its own encode's recorded count.
    second_out: [1024]u8 = undefined,
    // SAFETY: Read only as `notify_out[0..notification]`; the tail past that is planted to fail a longer read.
    notify_out: [1024]u8 = undefined,
    // SAFETY: `Conn` writes it and records the length in the slot; `Response.body` is `result[0..len]`.
    result: [1024]u8 = undefined,
    // SAFETY: Same as `result`, for the second call's own answer; the two bodies never share a byte.
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
    // SAFETY: `saw_len` stays 0 until the `@memcpy` below, and the assertion reads `[0..saw_len]` and no more.
    saw_method: [64]u8 = undefined,
    saw_len: usize = 0,
    notifications: usize = 0,

    fn handle(ctx: ?*anyopaque, frame: []const u8, decode_scratch: []u8, answer: []u8) conn.Error!?[]const u8 {
        // The context is the `&handler_state` this file installs on the line
        // that registers this handler — `Endpoint.open` hands it to
        // `setHandler` — and the connection calls a handler back with exactly
        // the context it was given (`src/conn.zig` calls
        // `func(self.ctx, ...)`). A null one is this test wired wrong rather
        // than anything a peer can bring about, and no member of `conn.Error`
        // would say what a caller should do about it, so it is unwrapped here
        // rather than turned into "no answer", which would leave the caller
        // waiting for a reply that never comes.
        // zwanzig-disable-next-line: optional-unwrap
        const self: *TestHandler = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(frame, decode_scratch) catch return null;
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
            // A `.request` is exactly a message that carried a `method` and an
            // `id`: `jsonrpc.decode` assigns that kind only when it saw both
            // members, and it refuses an `id` of `null` on a message that
            // carries a method before it gets there. The switch above has
            // already proved this message is a request, so the member is
            // present on every path that reaches this line.
            // zwanzig-disable-next-line: optional-unwrap
            const name = message.method.?.text;
            const n = @min(name.len, self.saw_method.len);
            @memcpy(self.saw_method[0..n], name[0..n]);
            self.saw_len = n;
        }

        // The answer is composed into `answer` while the name came out of
        // `decode_scratch`, so the writer cannot land on the value this
        // handler is still reading. That is what turns the copy above from a
        // rule into a shape: handed one region for both jobs, this handler
        // would hold only because its statements happen to run in this order,
        // and the next reader has to re-verify that by reading. The id is
        // formatted into a local, so nothing this handler still reads is
        // borrowed from the region the writer is filling.

        // The result carries the id the peer was asked for, so the two answers
        // this test collects are different bytes and neither can be mistaken
        // for the other.
        var writer = json.Writer.init(answer);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        var id_buffer: [24]u8 = undefined;
        // The id of a `.request`, on the rule the name above is read under: a
        // request is assigned only for a message that carried an `id`, and a
        // `null` id on a message with a method is refused as `InvalidField`.
        // This answer echoes that id, so it is the one the peer is waiting on.
        // zwanzig-disable-next-line: optional-unwrap
        const request_id = message.id.?;
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{request_id.integer}) catch return null;
        writer.slice(id_text) catch return null;
        writer.slice(",\"result\":{\"resultType\":\"complete\",\"call\":") catch return null;
        writer.slice(id_text) catch return null;
        writer.slice("}}") catch return null;
        return writer.written();
    }
};

/// Answers every request with a JSON-RPC error object, which is the case where
/// a connection that only reads `result` silently reports success.
///
/// It decodes nothing and writes nothing, so the body it returns borrows
/// neither region and is still valid after the connection overwrites both.
fn errorReply(_: ?*anyopaque, _: []const u8, _: []u8, _: []u8) conn.Error!?[]const u8 {
    return "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"no such method\"}}";
}

/// One connection plus the buffers, reader, writer and socket backing it.
const Endpoint = struct {
    side: Side = .{},
    // SAFETY: `Reader.init` binds it with `seek` and `end` at zero; only the bytes it filled are read.
    reader_buffer: [4096]u8 = undefined,
    // SAFETY: `Writer.init` binds it with an empty write region; `drain` sends `buffered()` only.
    writer_buffer: [4096]u8 = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned, which faults on the first read rather than at the call.
    // SAFETY: `open` assigns it before `Conn.init` borrows `&self.reader.interface` and spawns the pump.
    reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `open` assigns it before `Conn.init` borrows `&self.writer.interface` and spawns the pump.
    writer: Io.net.Stream.Writer = undefined,
    /// The descriptor this endpoint owns, and the proof that it owns one.
    ///
    /// `open` stores the stream before it can refuse, so a refused `open` still
    /// leaves the caller holding a descriptor to hang up, and `release` stores
    /// `null` before it closes, so a second release closes nothing rather than
    /// an unrelated descriptor this process opened in the meantime. An option
    /// rather than an `undefined` field because each test releases both of its
    /// endpoints after the join, and one whose `open` never ran owns nothing.
    stream: ?Io.net.Stream = null,
    // SAFETY: `open` assigns it before it sets `connected`, and only a connected endpoint reads it.
    connection: conn.Conn = undefined,
    /// Whether `open` built a connection over `stream`, which it sets once
    /// `Conn.init` hands one back. A hang-up reads the connection through it,
    /// so a refused `init` leaves the field alone rather than calling into a
    /// `Conn` that was never initialised.
    connected: bool = false,
    /// Whether this endpoint has been hung up already.
    closed: bool = false,
    /// How many times `release` closed a descriptor. The accounting a test
    /// reads after the join: one endpoint, one descriptor, one close.
    releases: usize = 0,

    /// Start the connection and spawn its reader on `group`.
    ///
    /// A wiring fault is `init`'s to report and this function's to return: the
    /// refusal comes before the slot table is cleared, so a refused `open`
    /// leaves the caller's slots as they were handed over. The stream stays
    /// with this endpoint on that path and the test closes it after the join.
    /// A refused initialization or reader spawn hangs up here, because no
    /// reader can otherwise wake a peer waiting on this connection.
    fn open(
        self: *Endpoint,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) (conn.Error || Io.ConcurrentError)!void {
        self.stream = stream;
        errdefer self.hangUp(io);
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = try conn.Conn.init(io, &self.reader.interface, &self.writer.interface, .{
            .frame_buffer = &self.side.frame_buffer,
            .pending = &self.side.pending,
            .decode_scratch = &self.side.decode_scratch,
            .answer = &self.side.answer,
        });
        self.connected = true;
        if (handler) |h| self.connection.setHandler(h);
        // A blocking reader needs concurrency; `async` may run it inline.
        // A refused spawn hangs up without closing the owner's descriptor.
        try group.concurrent(io, Endpoint.pump, .{self});
    }

    /// Hang up: tell the reader to stop, wake it, and leave the descriptor to
    /// the owner.
    ///
    /// `shutdown` before anything else, and no `close` here at all. Closing a
    /// descriptor does not interrupt a read already blocked on it, so a hang-up
    /// that only closed would leave the pump sitting on an open description and
    /// the group would never finish; `shutdown` is what makes the next read
    /// return zero bytes and the loop leave. That is a transport contract, not
    /// a detail of this test.
    ///
    /// The pump is not the only task on this socket, and never was.
    /// `Client.run` writes every call on it from a task of its own, and a
    /// handler answers on the very task that is reading. A reader that released
    /// the descriptor on its way out would take it away from a write in flight,
    /// and the standard library aborts the process on the `EBADF` that follows
    /// rather than returning an error the pump's own `catch` could see.
    /// [`release`] is the owner's, and runs once every task has joined.
    ///
    /// Best effort, and nothing is lost by it: the reader has already been told
    /// to stop, and a `shutdown` that cannot be sent means the peer is already
    /// gone, which is the case this runs in. `hangUp` returns nothing and its
    /// caller is a task, so a failure has nowhere to propagate; a transport
    /// that never hangs up shows up as the peer going unanswered and the group
    /// not finishing.
    fn hangUp(self: *Endpoint, io: Io) void {
        if (self.closed) return;
        self.closed = true;
        const stream = self.stream orelse return;
        if (self.connected) self.connection.close();
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        stream.shutdown(io, .both) catch {};
    }

    /// Release the descriptor once, and only on a stream this endpoint still
    /// owns.
    ///
    /// The owner calls this after the group has been joined or cancelled, never
    /// before and never from a task a live reader runs beside. By then every
    /// task that could read or write the socket has returned, and the two
    /// syscalls below are the last any of them will see of it.
    ///
    /// `shutdown` before `close`, and best effort before both. Nothing is
    /// blocked on the descriptor any more, so the shutdown only tells the peer
    /// the exchange is over; the close releases the number whether or not that
    /// reached it.
    fn release(self: *Endpoint, io: Io) void {
        const stream = self.stream orelse return;
        self.stream = null;
        self.releases += 1;
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        stream.shutdown(io, .both) catch {};
        stream.close(io);
    }

    /// Drive the connection until it is told to stop, and stop there.
    ///
    /// It takes the endpoint rather than the connection because that is what
    /// `open` spawns it with, and because what it does *not* do is the point:
    /// the descriptor is the owner's to release. This task is the only one that
    /// reads the stream, but it is not the only one that uses it, so it leaves
    /// the release to an owner that has joined this task and every other one
    /// first.
    fn pump(self: *Endpoint) void {
        self.connection.pump();
    }
};

// The socket names below are not literals. `testio.socketPath` borrows the
// `TMPDIR` this test binary was given and refuses one the machine shares with
// every other user, so the socket lands in an area this run owns rather than in
// a directory any process on the host can write.

// Each test passes its own tag and the helper adds a nonce of its own on top,
// so two runs in one temporary directory never land on one name. A fixed name
// is a rendezvous point: whichever run reaches the unlink second deletes the
// other's bound path, the client then connects to nothing, and the loser of
// the race aborts in a pump with `BADF` on a socket file that is gone. It reads
// as a transport fault and is not one. The examples carry the same tag and
// nonce for the same reason, and this is that mechanism rather than a second
// one.

// Each test calls the helper once and hands the result to both halves — the
// listener is built from `path` and the client connects to the
// `Io.net.UnixAddress` made from the same `path` — so the server and the
// client cannot disagree about which socket they mean.

// `path_buffer` is sized from `Io.net.UnixAddress.max_len` rather than a round
// number, because that is the one length that fails: `UnixAddress.init`
// refuses a longer name with `error.NameTooLong`, which a test reads as a peer
// that never connected. Sized this way a `TMPDIR` too long to leave room for
// the name is reported by the helper rather than rendered, and the helper does
// not truncate a name the two halves would then disagree about.

/// What the client task leaves for the test, and how much of each encode
/// buffer is a frame.
///
/// The three lengths are the number of bytes the encode really wrote, taken
/// inside the task right after that encode. An assertion reads an encode
/// buffer only through the length of the frame in it, so it never reads a
/// byte the client did not write.
const Observed = struct {
    /// The first answer, borrowing the first call's result buffer.
    // SAFETY: `Client.run` assigns it, or sets `call_failed` and returns; the read follows `expect(!call_failed)`.
    first_answer: conn.Response = undefined,
    /// The second answer, borrowing the second call's own result buffer.
    // SAFETY: Same as `first_answer`: a failed second call sets `call_failed` and returns before the read.
    second_answer: conn.Response = undefined,
    first_request: usize = 0,
    second_request: usize = 0,
    notification: usize = 0,
};

test "each answer is matched to its own call over a real socket" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try testio.socketPath(io, testing.environ, &path_buffer, 0x5eed_0001);
    // A socket file left by a killed run would make listen fail. An absent
    // file is the expected answer to this call; anything else is a real fault
    // in this run's own directory and belongs in the failure.
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        // Best-effort while the test is already unwinding: the next run in this
        // directory unlinks the same path itself before it listens, so a failed
        // cleanup here has no caller left to report to.
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var peer_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};
    var handler_state: TestHandler = .{};
    var observed: Observed = .{};
    var call_failed: bool = false;

    const Peer = struct {
        const Self = @This();

        io: Io,
        group: *Io.Group,
        server: *Io.net.Server,
        endpoint: *Endpoint,
        handler: conn.Handler,
        failed: *bool,

        /// Accept one connection and let its reader run on the same group.
        fn run(self: *Self) void {
            const stream = self.server.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            // A refused `open` leaves no connection, so the flag is the whole
            // report. The stream stays with this endpoint and the test closes
            // it after the join, once no task is left on it either way.
            self.endpoint.open(self.io, self.group, stream, self.handler) catch {
                self.failed.* = true;
                return;
            };
        }
    };

    const Client = struct {
        const Self = @This();

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
        fn notifyProgress(self: *Self) void {
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

        fn run(self: *Self) void {
            const stream = self.address.connect(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, null) catch {
                self.failed.* = true;
                return;
            };
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
            // Hang up. `shutdown` before anything else, because closing a file
            // descriptor does not interrupt a `read` already blocked on it:
            // the reader would sit on an open file description forever and
            // the group would never finish. A transport must unblock its
            // peers this way, so it is part of the contract, not a detail —
            // and the close is not this task's to make, because the descriptor
            // belongs to the owner as much as it belongs to this reader. The
            // test closes it once the join has brought every task back.
            self.endpoint.hangUp(self.io);
        }
    };

    // One owner joins both peers and both readers before their state expires,
    // and releases both descriptors once they have all returned.
    var group: Io.Group = .init;
    defer group.cancel(io);
    var peer: Peer = .{
        .io = io,
        .group = &group,
        .server = &server,
        .endpoint = &peer_endpoint,
        .handler = .{ .ctx = &handler_state, .call = TestHandler.handle },
        .failed = &call_failed,
    };
    var client: Client = .{
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
    try group.concurrent(io, Peer.run, .{&peer});
    try group.concurrent(io, Client.run, .{&client});
    const joined = group.await(io);
    peer_endpoint.release(io);
    client_endpoint.release(io);
    joined catch {
        call_failed = true;
    };

    try testing.expect(!call_failed);

    // Each answer came back over the socket, matched to the call that asked
    // for it by its own id. The peer stamps every result with the id it was
    // asked for, so an answer read out of the other call's buffer would carry
    // the other id and fail here instead of passing under the wrong name.
    // The peer's handler is handed a decode region and an answer region that
    // share no byte, so what is read here cannot be an answer the handler
    // wrote over the frame it decoded: only a swapped answer fails now.
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

    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try testio.socketPath(io, testing.environ, &path_buffer, 0x5eed_0002);
    // A socket file left by a killed run would make listen fail. An absent
    // file is the expected answer to this call; anything else is a real fault
    // in this run's own directory and belongs in the failure.
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        // Best-effort while the test is already unwinding: the next run in this
        // directory unlinks the same path itself before it listens, so a failed
        // cleanup here has no caller left to report to.
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var peer_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};
    var answer: conn.Response = undefined;
    var failed: bool = false;

    const Peer = struct {
        const Self = @This();

        io: Io,
        group: *Io.Group,
        server: *Io.net.Server,
        endpoint: *Endpoint,
        failed: *bool,

        fn run(self: *Self) void {
            const stream = self.server.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            // The accepted side has no caller of its own left on the stream
            // once this task returns, and neither has its reader; the test
            // closes it after the join.
            self.endpoint.open(self.io, self.group, stream, .{ .call = errorReply }) catch {
                self.failed.* = true;
                return;
            };
        }
    };

    const Client = struct {
        const Self = @This();

        io: Io,
        group: *Io.Group,
        address: *const Io.net.UnixAddress,
        endpoint: *Endpoint,
        answer: *conn.Response,
        failed: *bool,

        fn run(self: *Self) void {
            const stream = self.address.connect(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, null) catch {
                self.failed.* = true;
                return;
            };
            self.answer.* = self.endpoint.connection.call(
                "nosuch/method",
                null,
                &self.endpoint.side.result,
                &self.endpoint.side.out,
            ) catch {
                self.failed.* = true;
                return;
            };
            // Hang up, for the reason given in the first test: a close does not
            // interrupt a read already blocked on the fd, so the shutdown comes
            // first and the owner closes the descriptor once every task has
            // come back from the join.
            self.endpoint.hangUp(self.io);
        }
    };

    // One owner joins both peers and both readers before their state expires,
    // and releases both descriptors once they have all returned.
    var group: Io.Group = .init;
    defer group.cancel(io);
    var peer: Peer = .{
        .io = io,
        .group = &group,
        .server = &server,
        .endpoint = &peer_endpoint,
        .failed = &failed,
    };
    var client: Client = .{
        .io = io,
        .group = &group,
        .address = &address,
        .endpoint = &client_endpoint,
        .answer = &answer,
        .failed = &failed,
    };
    try group.concurrent(io, Peer.run, .{&peer});
    try group.concurrent(io, Client.run, .{&client});
    const joined = group.await(io);
    peer_endpoint.release(io);
    client_endpoint.release(io);
    joined catch {
        failed = true;
    };

    try testing.expect(!failed);
    try testing.expectEqual(@as(?i32, -32601), answer.error_code);
    try testing.expect(std.mem.indexOf(u8, answer.body, "no such method") != null);
}

test "a peer that hangs up mid-call is reported, and both descriptors are released once" {
    // The teardown boundary the two tests above cannot reach, and the one this
    // file exists to keep. Both of them hang up from the calling side after its
    // own last write, so a reader never returns while the task that shares its
    // socket is still writing on it. Here the peer hangs up as soon as it has
    // accepted, so the client's reader sees end of file on a descriptor its
    // caller task is about to write a request on.
    //
    // A reader that closed the descriptor on its way out would take it away
    // from that write, and the standard library aborts the whole binary on the
    // `EBADF` rather than returning an error: reaching the assertions below at
    // all is most of what this test proves. The counts that follow pin the
    // accounting, so a teardown cannot trade one fault for another.
    //
    // Nothing here waits on a timer. The peer hangs up on its own, the
    // client's reader then sees end of file on its own, and the group finishes
    // because both sides were told to stop.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try testio.socketPath(io, testing.environ, &path_buffer, 0x5eed_0003);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var peer_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};
    var failed: bool = false;
    // What the call came back with, recorded by the client task and read after
    // the join. Null is the answer this test rules out: a call that returned
    // means the peer answered, and this peer never answers.
    var reported: ?conn.Error = null;

    const Peer = struct {
        const Self = @This();

        io: Io,
        group: *Io.Group,
        server: *Io.net.Server,
        endpoint: *Endpoint,
        failed: *bool,

        /// Accept, open with no handler, and hang up without answering.
        fn run(self: *Self) void {
            const stream = self.server.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            // No handler, and that is what makes the client's failure certain
            // rather than a race: a connection with nothing installed to
            // answer a request writes nothing back for it, so the only thing
            // that can ever reach the client's call is this socket ending.
            self.endpoint.open(self.io, self.group, stream, null) catch {
                self.failed.* = true;
                self.endpoint.hangUp(self.io);
                return;
            };
            self.endpoint.hangUp(self.io);
        }
    };

    const Client = struct {
        const Self = @This();

        io: Io,
        group: *Io.Group,
        address: *const Io.net.UnixAddress,
        endpoint: *Endpoint,
        reported: *?conn.Error,
        failed: *bool,

        fn run(self: *Self) void {
            const stream = self.address.connect(self.io) catch {
                self.failed.* = true;
                return;
            };
            self.endpoint.open(self.io, self.group, stream, null) catch {
                self.failed.* = true;
                self.endpoint.hangUp(self.io);
                return;
            };
            // One call, and a peer that has already promised not to answer it.
            // The write may reach a socket that is on its way down or land on
            // one that is already shut; either way the caller is told, and
            // this task never waits on a reader that has gone away.
            if (self.endpoint.connection.call(
                "tools/call",
                "{\"name\":\"echo\"}",
                &self.endpoint.side.result,
                &self.endpoint.side.out,
            )) |_| {
                self.failed.* = true;
            } else |err| {
                self.reported.* = err;
            }
            self.endpoint.hangUp(self.io);
        }
    };

    var group: Io.Group = .init;
    defer group.cancel(io);
    var peer: Peer = .{
        .io = io,
        .group = &group,
        .server = &server,
        .endpoint = &peer_endpoint,
        .failed = &failed,
    };
    var client: Client = .{
        .io = io,
        .group = &group,
        .address = &address,
        .endpoint = &client_endpoint,
        .reported = &reported,
        .failed = &failed,
    };
    try group.concurrent(io, Peer.run, .{&peer});
    try group.concurrent(io, Client.run, .{&client});
    const joined = group.await(io);
    peer_endpoint.release(io);
    client_endpoint.release(io);
    joined catch {
        failed = true;
    };

    try testing.expect(!failed);
    // The call was reported, and what it reported is a peer that is gone: the
    // socket refused the write, the reader saw end of file and closed the
    // connection the answer would have arrived on, or that reader had already
    // returned before this call began. None of them is the `BADF` a reader that
    // closed its own descriptor would have produced, and none of them hangs.
    const reported_error = reported orelse return error.ExpectedAPeerThatHungUp;
    try testing.expect(
        reported_error == error.Transport or
            reported_error == error.ConnectionClosed or
            reported_error == error.Closed,
    );

    // One descriptor at each end and one close apiece. The two hang-ups shut
    // them down, these two releases close them, and neither a reader nor a
    // second release closed anything of its own: the fault this file is about
    // is a close from the wrong task, and a double close is the same mistake
    // with the descriptor arriving somewhere else.
    try testing.expectEqual(@as(usize, 1), peer_endpoint.releases);
    try testing.expectEqual(@as(usize, 1), client_endpoint.releases);
}

test "a refused reader spawn hangs up without releasing the owner's descriptor" {
    var threaded: Io.Threaded = .init(testing.allocator, .{
        .concurrent_limit = .nothing,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try testio.socketPath(io, testing.environ, &path_buffer, 0x5eed_0004);
    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        // The test owns this socket name; teardown must also run after a fault.
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    const peer = try address.connect(io);
    defer peer.close(io);
    const accepted = try server.accept(io);
    var endpoint: Endpoint = .{};
    var group: Io.Group = .init;
    defer {
        group.cancel(io);
        endpoint.release(io);
    }

    try testing.expectError(error.ConcurrencyUnavailable, endpoint.open(io, &group, accepted, null));
    // Checking the transition first makes a regression fail instead of blocking
    // on the peer read below. The read proves that the refused open sends EOF.
    try testing.expect(endpoint.closed);
    try testing.expectEqual(@as(usize, 0), endpoint.releases);
    var reader_buffer: [16]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(peer, io, &reader_buffer);
    var byte: [1]u8 = undefined;
    var slices = [_][]u8{&byte};
    try testing.expectError(error.EndOfStream, reader.interface.readVec(&slices));
    try group.await(io);
    endpoint.release(io);
    try testing.expectEqual(@as(usize, 1), endpoint.releases);
}
