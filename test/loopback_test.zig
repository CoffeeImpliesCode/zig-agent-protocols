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
//! blocked on the descriptor, so its task shuts the stream down before it
//! closes it. Both readers then see end of file and both pumps return. The
//! accepted side has no caller left to close it, so its reader closes the
//! stream as it returns, rather than leaving the descriptor to the process.
//! The group then completes on its own. There is no sleep and no arbitrary
//! timeout in this file, so a pass means the exchange finished rather than
//! that the test waited long enough to look.

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
    // SAFETY: `open`'s first statement assigns it, ahead of the `errdefer` and the pump that read it.
    stream: Io.net.Stream = undefined,
    // SAFETY: `open` assigns it before the pump spawn, and `hangUp` runs only after `open` returned.
    connection: conn.Conn = undefined,
    /// Whether this endpoint has been hung up already.
    closed: bool = false,
    /// Whether a task reads this endpoint, which `open` sets.
    ///
    /// It decides who releases the descriptor: the pump, because it is the only
    /// task that reads it. See `hangUp`.
    pumping: bool = false,
    /// Whether the descriptor has been released.
    released: bool = false,

    /// Start the connection and spawn its reader on `group`.
    ///
    /// A wiring fault is `init`'s to report and this function's to return: the
    /// refusal comes before the slot table is cleared, so a refused `open`
    /// leaves the caller's slots as they were handed over. The stream is
    /// released on the way out, because the reader that would have released it
    /// is never started and the peer would otherwise wait on a connection that
    /// was never made.
    fn open(
        self: *Endpoint,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) (conn.Error || Io.ConcurrentError)!void {
        self.stream = stream;
        errdefer self.release(io);
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = try conn.Conn.init(io, &self.reader.interface, &self.writer.interface, .{
            .frame_buffer = &self.side.frame_buffer,
            .pending = &self.side.pending,
            .decode_scratch = &self.side.decode_scratch,
            .answer = &self.side.answer,
        });
        if (handler) |h| self.connection.setHandler(h);
        // A blocking reader needs concurrency; `async` may run it inline.
        // Publish ownership before spawning, but give it back on refusal.
        self.pumping = true;
        group.concurrent(io, Endpoint.pump, .{self}) catch |err| {
            self.pumping = false;
            return err;
        };
    }

    /// Hang up: stop the reader, wake it, and let the descriptor go once.
    ///
    /// `shutdown` before `close`: closing a descriptor does not interrupt a read
    /// already blocked on it, so the peer's pump would sit on an open
    /// description and the group would never finish. That is a transport
    /// contract, not a detail of this test.
    ///
    /// The pump releases the descriptor, not this call. `conn.pump` asks again
    /// after a read of zero bytes, and a local `shutdown` makes the next read
    /// return exactly that, so a caller that released the descriptor under a
    /// live pump would have that pump read a freed descriptor: the standard
    /// library aborts on `EBADF` inside `netReadPosix`, before the pump's own
    /// `catch` can see an error, and the whole test binary dies instead of the
    /// test failing. Telling the connection first is what makes the loop stop —
    /// the pump leaves at its next turn and closes the stream on its way out,
    /// after the last read that can touch it.
    fn hangUp(self: *Endpoint, io: Io) void {
        if (self.closed) return;
        self.closed = true;
        // Every call below is a syscall on the descriptor, and a `shutdown` on
        // a released one is `EBADF`, which aborts the process rather than
        // returning.
        if (self.released) return;
        if (self.pumping) {
            self.connection.close();
            // Best-effort, and reported by the pump rather than here: this call
            // has already told the connection to stop, so `shutdown` only
            // interrupts a read that is on its way out. `hangUp` returns
            // nothing and its caller is a task, so a failure has nowhere to
            // propagate; a transport that never hangs up shows up as the peer
            // going unanswered and the group not finishing.
            // The pump releases the descriptor on its own way out, so a skipped
            // interrupt is not a skipped release and nothing is left unreleased.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            // ziglint-ignore: Z026
            // zwanzig-disable-next-line: empty-catch-engine
            self.stream.shutdown(io, .both) catch {};
            return;
        }
        self.release(io);
    }

    /// Release the descriptor once, and only on a stream that still has one.
    fn release(self: *Endpoint, io: Io) void {
        if (self.released) return;
        self.released = true;
        // Best-effort on the pump's way out: the descriptor is closed on the
        // next line whatever `shutdown` reports, and the only task that owns
        // it is returning, so there is no caller to carry an error to.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        self.stream.shutdown(io, .both) catch {};
        self.stream.close(io);
    }

    /// Read until the transport ends, then release the stream.
    ///
    /// Every endpoint here is read by its own pump and no other task may
    /// release the descriptor, so both sides close it here: the accepted side
    /// has no caller left to do it, and the calling side hangs up first and
    /// lets this close happen after the read that would touch the descriptor
    /// has returned. A test that waits for end of file therefore does not also
    /// need the process to exit to release the descriptor.
    fn pump(self: *Endpoint) void {
        self.connection.pump();
        self.release(self.connection.io);
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
            // The accepted side has no caller left to close it, so its own
            // reader releases the descriptor when the client hangs up.
            // A refused `open` leaves no connection, so the flag is the whole
            // report; the stream has already been released by `open` itself.
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
            // Hang up. `shutdown` before `close`, because closing a file
            // descriptor does not interrupt a `read` already blocked on it:
            // the reader would sit on an open file description forever and
            // the group would never finish. A transport must unblock its
            // peers this way, so it is part of the contract, not a detail —
            // and the descriptor itself is released by this endpoint's own
            // pump, which is the only task reading it.
            self.endpoint.hangUp(self.io);
        }
    };

    // One owner joins both peers and both readers before their state expires.
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
    group.await(io) catch {
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
            // The accepted side has no caller left to close it, so its own
            // reader releases the descriptor when the client hangs up.
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
            // Hang up, for the reason given in the first test: closing does
            // not interrupt a read already blocked on the fd, so the shutdown
            // comes first and the pump releases the descriptor after its last
            // read.
            self.endpoint.hangUp(self.io);
        }
    };

    // One owner joins both peers and both readers before their state expires.
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
    group.await(io) catch {
        failed = true;
    };

    try testing.expect(!failed);
    try testing.expectEqual(@as(?i32, -32601), answer.error_code);
    try testing.expect(std.mem.indexOf(u8, answer.body, "no such method") != null);
}
