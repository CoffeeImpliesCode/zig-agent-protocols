//! A working MCP server and client over a Unix socket, in one process.
//!
//! The point of this example is that it is not a mock. A real connection, a
//! real `Io`, a real socket, real JSON-RPC frames, and the same [`conn.Conn`]
//! a server binary would use. The codec in `src/*.zig` has its own tests, but a
//! codec that has only ever been tested against slices has never been driven by
//! a transport, and that is the gap this closes.
//!
//! The server answers `tools/list` and `tools/call` and refuses every other
//! method. The client calls the two the server has, calls `resources/list` to
//! watch a refusal arrive, and prints what came back. A peer error is not a
//! result, so the refusal is printed as a refusal. Everything is caller-owned
//! buffers, so the example doubles as a check that the API is usable without an
//! allocator.
//!
//! Run it with `zig build run-runtime`.

const std = @import("std");
const proto = @import("zig-agent-protocols");

/// The socket-name helper, development-only and deliberately not part of the
/// library's public API.
///
/// Where a socket may be created is a property of the environment the process
/// was handed, not something an example gets to spell out as a literal. A
/// hardcoded `/tmp` is a directory every user on the machine shares and can
/// write, so a name there is a rendezvous point with whatever else is running.
const testio = @import("testio");

const conn = proto.conn;
const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;
const mcp_session = proto.mcp_session;

const builtin = @import("builtin");

const Io = std.Io;

/// The answer to `tools/list`.
///
/// A cacheable result, so it carries `resultType` and the two fields
/// PROTOCOLS.md 4.6 says a cacheable result adds. A minute is the freshness
/// hint: the list changes when the server is redeployed and not before.
/// `public` is honest about this server, which sends the same list to every
/// caller, and a private scope would be the claim that a shared cache may not
/// keep it.
const list_result =
    "{\"resultType\":\"complete\",\"ttlMs\":60000,\"cacheScope\":\"public\"," ++
    "\"tools\":[{\"name\":\"echo\",\"description\":\"echo it back\"}]}";

/// The answer to `tools/call`. An ordinary result, so `resultType` and no
/// caching fields.
const call_result =
    "{\"resultType\":\"complete\"," ++
    "\"content\":[{\"type\":\"text\",\"text\":\"echo\"}]}";

/// A server that answers the two methods this example exercises, and refuses
/// every other one with a JSON-RPC error.
const ToolServer = struct {
    calls: usize = 0,

    fn handle(
        ctx: ?*anyopaque,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) conn.Error!?[]const u8 {
        // The context is the `ToolServer` `Peer.run` registered beside this
        // handler, and it is `handler`: a non-null field of a local in `main`
        // that outlives the group join. A null would be a wiring fault in this
        // example, and declining here would answer nothing and leave the
        // client blocked on a frame nobody would write.
        // zwanzig-disable-next-line: optional-unwrap
        const self: *ToolServer = @ptrCast(@alignCast(ctx.?));
        // The connection lends two regions to every request, and two things
        // are live at once: the decoded request and the answer. The decode
        // writes into the first, the answer is composed into the second, and
        // a handler need not check which one it is holding.

        // One region could not carry both. `jsonrpc.decode` unescapes into the
        // region it is given rather than borrowing from the frame, and the
        // escape offset `json.Reader` keeps is per reader and not per buffer,
        // so a peer that escaped its method name is enough to make the two
        // collide: the writer's first bytes land on the name the branches
        // below are about to compare.

        // Both regions die with this call. The connection writes the answer out
        // before it lends either of them to the next request.
        const request = jsonrpc.decodeRequest(frame, decode_scratch) catch return null;
        self.calls += 1;

        if (std.mem.eql(u8, request.method.text, "tools/list")) {
            return conn.respond(request, list_result, answer) catch null;
        }
        if (std.mem.eql(u8, request.method.text, "tools/call")) {
            return conn.respond(request, call_result, answer) catch null;
        }

        // A method this server does not have, answered with the
        // specification's own code. `conn.errorResponse` is a separate builder
        // from `conn.respond` so that a refusal is a value a caller passes in
        // and never a member a builder has to be told to emit: `error` is a
        // member beside `result`, and a decoder reads a result with no error
        // member as a success. An error object written inside a result
        // therefore reaches the caller as a successful call whose body happens
        // to be a refusal, with no code anywhere on the frame.

        // The id needs no arm of its own here either: the builder echoes it in
        // the arm it arrived in, which matters because an answer is matched by
        // id and by nothing else.

        // `conn.methodNotFound` would write the code and the standard's own
        // text, and this writes the method's name into the message, so a peer
        // can tell which one was refused.

        // The message is the one thing built here rather than handed to a
        // builder whole, and the one thing with nowhere to live. `answer` is
        // what `errorResponse` writes into, so a message kept there is the text
        // its own writer is about to overwrite; `decode_scratch` may be holding
        // the method name itself, unescaped there rather than borrowed from the
        // frame. So it is a local, which needs to outlive neither: the builder
        // has read it by the time this function returns.
        var message_buffer: [256]u8 = undefined;
        var text = json.Writer.init(&message_buffer);
        text.slice("no handler for ") catch return standardRefusal(request, answer);
        text.string(request.method.text) catch return standardRefusal(request, answer);
        return conn.errorResponse(request, .{
            .code = @intFromEnum(jsonrpc.StandardError.method_not_found),
            .message = text.written(),
        }, answer) catch null;
    }
};

/// The refusal a handler falls back on when the method's own name does not fit
/// beside the standard's words.
///
/// A short message is a worse answer, never no answer: a handler that declines
/// writes nothing at all, and the peer is waiting on a request that already
/// arrived.
fn standardRefusal(request: jsonrpc.Request, answer: []u8) conn.Error!?[]const u8 {
    return conn.methodNotFound(request, answer) catch null;
}

/// One end of the connection: the buffers and the connection over them.
///
/// The reader and the writer of a connection are two different tasks, and
/// only one of them may close the descriptor. It is the owner of the side:
/// `main` releases both after it joins the group, which is the only point
/// at which no reader and no writer can still be on either stream.
///
/// The reader used to release, on the reasoning that it was the only task
/// touching the descriptor. It is not — the client task writes the very same
/// stream through `Conn.call` — and a reader that closed it while a write was
/// pending got `EBADF`, which the standard library answers by aborting the
/// process rather than by returning an error. That is why ownership is
/// tracked explicitly and why [`releaseSafe`] is the owner's and not the
/// reader's.
const Side = struct {
    // SAFETY: `open` assigns it before its first call that can fail, and both teardown paths run after it.
    io: Io = undefined,
    buffers: proto.stdio.Buffers = .{},
    // SAFETY: `open` hands it to `Stream.Reader.init`, which refills it before every read it serves.
    reader_buffer: [4096]u8 = undefined,
    // SAFETY: `open` hands it to `Stream.Writer.init`, which refills it before every write it serves.
    writer_buffer: [4096]u8 = undefined,
    // SAFETY: `open` assigns it before it spawns the pump, and the pump starts after that.
    connection: conn.Conn = undefined,
    // SAFETY: `open` assigns it before `Conn.init` can refuse, so both teardown paths hold the descriptor.
    stream: Io.net.Stream = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned.
    // SAFETY: `open` assigns it from `Stream.Reader.init` before it lends `reader.interface` to `Conn.init`.
    reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `open` assigns it from `Stream.Writer.init` before it lends `writer.interface` to `Conn.init`.
    writer: Io.net.Stream.Writer = undefined,
    /// Whether this side owns a descriptor at all, which [`open`] decides.
    ///
    /// Taken before `Conn.init`, which can refuse, so a refused open still
    /// leaves a descriptor the owner has to release. It is also what keeps
    /// [`releaseSafe`] off a side that was never opened, where `stream` is
    /// `undefined` and reading it would be reading nothing.
    owned: bool = false,
    /// Whether `open` built `connection`.
    ///
    /// Tracked apart from `owned` because the two are reached at different
    /// points: the descriptor is owned before `Conn.init`, which can refuse,
    /// and the connection only exists once it has returned. `hangUp` needs
    /// the first and the second separately.
    connected: bool = false,
    /// Whether this side has been hung up already.
    closed: bool = false,
    /// Whether the descriptor has been released.
    released: bool = false,
    /// How many times the descriptor was released. Must be one, and the
    /// tests say so: a second release closes whatever the process opened
    /// next, and a missing one leaks it.
    releases: u32 = 0,

    /// Open a side over `stream`, or report why there is no connection to
    /// open. `init` refuses a region with no room and a pair that shares a
    /// byte, and both are wiring faults a caller sees here rather than as a
    /// wrong answer on the wire.
    fn open(
        self: *Side,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) (conn.Error || Io.ConcurrentError)!void {
        self.io = io;
        self.stream = stream;
        self.owned = true;
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = try conn.Conn.init(
            io,
            &self.reader.interface,
            &self.writer.interface,
            self.buffers.config(),
        );
        self.connected = true;
        if (handler) |h| self.connection.setHandler(h);
        // A blocking reader needs concurrency; `async` may run it inline.
        try group.concurrent(io, Side.pump, .{self});
    }

    /// Read until the connection is told to stop or the peer hangs up.
    ///
    /// This task does not release the stream. It is the task that reads it,
    /// and reading is not the only thing done to a descriptor: the client
    /// task writes the same one from a task of its own, and a reader that
    /// closed it would take it away from a write already in flight. The owner
    /// releases, after the join that covers both tasks.
    fn pump(self: *Side) void {
        self.connection.pump();
    }

    /// Hang up: stop the reader and wake it, without closing anything.
    ///
    /// `shutdown` before any `close`, and no `close` here at all. Closing a
    /// descriptor does not interrupt a read already blocked on it, so the
    /// peer's pump would sit on an open description and the group would never
    /// finish; but closing it also answers a reader or a writer that is still
    /// using it, with `EBADF` and a process abort rather than an error.
    /// `shutdown` wakes the blocked read with end of stream and leaves the
    /// descriptor usable, which is the whole of what this call needs.
    ///
    /// `conn.pump` asks again after a read of zero bytes, so the shutdown
    /// alone would let the reader come straight back to the same descriptor;
    /// `connection.close` is what makes the loop leave at its next turn.
    ///
    /// Safe to call more than once, and safe on a side that was never opened,
    /// which is what the deferred call on the client's every-path-out hook
    /// reaches when the connect itself failed.
    fn hangUp(self: *Side) void {
        if (self.closed) return;
        self.closed = true;
        if (!self.owned) return;
        // Skipped when `Conn.init` refused: there is no connection to stop,
        // and stopping one that was never built would write through
        // undefined state. The shutdown below still runs, so the client is
        // not left waiting on an accepted descriptor nobody will answer.
        if (self.connected) self.connection.close();
        // Best effort, and only ever a wake-up: the reader has already been
        // told to stop and a `shutdown` here has nothing left to interrupt.
        // There is also nowhere to report a failure to, because this call is
        // already returning and no close is reachable from it.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        self.stream.shutdown(self.io, .both) catch {};
    }

    /// Release the descriptor, once, from the owner.
    ///
    /// The name says what the guards are for. Every path that reaches here
    /// runs after the group join, so no reader and no writer can still be on
    /// this stream and the release is the last thing done to it. The `owned`
    /// guard is what makes it legal on a side that never held a descriptor,
    /// and the `released` guard is what keeps a second call from closing
    /// whatever the process opened next.
    fn releaseSafe(self: *Side) void {
        if (!self.owned or self.released) return;
        self.released = true;
        self.releases += 1;
        // Best effort before the close, which releases the descriptor whether
        // or not the shutdown reached the peer: this is the last call this
        // scope makes on the stream.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        self.stream.shutdown(self.io, .both) catch {};
        self.stream.close(self.io);
    }
};

/// The size of the buffer `conn.Conn.call` fills and of every `Answer` body
/// beside it, as one constant because the two have to agree. `call` refuses
/// an answer longer than its result buffer with `error.ResponseTooLarge`, so an
/// `Answer` smaller than that buffer is cut without a marker and printed under
/// a heading claiming it is the whole result. Anything longer than this is a
/// failure the client reports rather than a body the example prints.
const answer_capacity = 4096;

/// What one call came back with: the body, and the code that says whether the
/// body is a result or a refusal.
///
/// The two travel together because a peer error is not a result. A refusal
/// arrives as an error object, which is a body like any other, and nothing but
/// the code beside it says the call failed. Each answer keeps its own buffer,
/// so the next call, which reuses the connection's result buffer, cannot
/// overwrite what this one returned.
const Answer = struct {
    // SAFETY: `take` copies the body in before it sets `len`; `text` slices those bytes and `len` starts at 0.
    body: [answer_capacity]u8 = undefined,
    len: usize = 0,
    /// The peer's JSON-RPC error code, or 0 when the call succeeded.
    code: i32 = 0,

    fn text(self: *const Answer) []const u8 {
        return self.body[0..self.len];
    }

    fn refused(self: *const Answer) bool {
        return self.code != 0;
    }

    /// Copy out what `conn.Conn.call` read into the caller's result buffer.
    fn take(self: *Answer, response: conn.Response) void {
        self.code = response.error_code orelse 0;
        // `response.body` is a prefix of the result buffer `call` was given,
        // and that buffer is `answer_capacity`, so this copy cannot cut. The
        // truncation is kept as the bound a defensive copy needs rather than
        // removed: a caller that hands `take` a bigger buffer gets the start of
        // a body rather than a panic, and this example's client cannot reach
        // that arm because `call` refuses such an answer with
        // `error.ResponseTooLarge` first, which the client reports.
        self.len = @min(response.body.len, self.body.len);
        @memcpy(self.body[0..self.len], response.body[0..self.len]);
    }
};

/// The server task: accept one connection and hand its stream to the pump.
const Peer = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    side: *Side,
    handler: *ToolServer,

    fn run(self: *Peer) void {
        const stream = self.server.accept(self.io) catch return;
        // A side that could not be opened hangs its end up rather than
        // returning quietly: the pump never started, so nothing else would
        // tell the reader there is nothing coming, and the client would sit in
        // `call` waiting for a server that is no longer there. `hangUp` stops
        // and wakes without closing; the accepted descriptor is released by
        // the owner after the join, which reaches here like any other path.
        self.side.open(self.io, self.group, stream, .{
            .ctx = self.handler,
            .call = ToolServer.handle,
        }) catch {
            self.side.hangUp();
            return;
        };
    }
};

/// The client task: the two calls the server answers, and one it does not.
const Client = struct {
    io: Io,
    group: *Io.Group,
    address: *Io.net.UnixAddress,
    side: *Side,
    listed: Answer = .{},
    refused: Answer = .{},
    called: Answer = .{},
    /// The last request as it went on the wire. The current revision has no
    /// handshake, so this is where the `_meta` wrapper carrying the client
    /// capabilities becomes visible.
    // SAFETY: `keepEncoded` copies the request in before it sets `last_sent_len`, which starts at 0.
    last_sent: [2048]u8 = undefined,
    last_sent_len: usize = 0,
    /// The error that ended the exchange, or null when it completed.
    failure: ?[:0]const u8 = null,

    /// Record the last request as it went on the wire.
    fn remember(self: *Client, encoded: []const u8) void {
        keepEncoded(&self.last_sent, &self.last_sent_len, encoded);
    }

    fn run(self: *Client) void {
        const stream = self.address.connect(self.io) catch {
            self.failure = "the socket would not connect";
            return;
        };
        // Hung up on every path out of this task, so this side's own reader
        // stops and the peer's sees end of file, and the group drains. A
        // `defer` rather than a last line, because the paths that skipped
        // that line were the ones that failed: the client returned with a flag
        // set, its own pump stayed blocked in a read nobody woke, and the join
        // never returned. Ahead of the open for the same reason: a side with
        // no connection is a path out of this task too.

        // What it stops is this side's reader and what it wakes is that
        // reader's blocked read. It closes nothing. The descriptor belongs to
        // the owner, which releases it after the join covering both the pump
        // that reads it and this task that writes it.
        defer self.side.hangUp();
        self.side.open(self.io, self.group, stream, null) catch |err| {
            self.failure = @errorName(err);
            return;
        };

        // A session pinned to the current revision. There is no handshake
        // here, so the capabilities ride on each request in `_meta`.
        var session = mcp_session.Client.init(&self.side.connection, .current);
        session.capabilities = "{\"tools\":{}}";

        // `answer_capacity` and not a literal, because `call` measures the
        // answer against this buffer and every `Answer` measures it against
        // its own. The two disagreeing is what used to let a reply between
        // their sizes come back whole and then be printed cut.
        var result_buffer: [answer_capacity]u8 = undefined;
        var out_buffer: [4096]u8 = undefined;
        var params_buffer: [4096]u8 = undefined;

        const listed = session.request(
            "tools/list",
            null,
            &result_buffer,
            &out_buffer,
            &params_buffer,
        ) catch |err| {
            self.failure = @errorName(err);
            return;
        };
        self.listed.take(listed);
        self.remember(out_buffer[0..self.side.connection.lastEncodedLen()]);

        // A method the revision has and this server does not, asked for before
        // the tool call so that the last frame the client writes is the one
        // worth showing: a `_meta` wrapper around the caller's own members.

        // The answer is a refusal, and it is read as one. `error_code` is what
        // says so; the body is the error object the server sent, and a reader
        // that kept only the body would call this a successful call.
        const refused = session.request(
            "resources/list",
            null,
            &result_buffer,
            &out_buffer,
            &params_buffer,
        ) catch |err| {
            self.failure = @errorName(err);
            return;
        };
        self.refused.take(refused);
        self.remember(out_buffer[0..self.side.connection.lastEncodedLen()]);

        const called = session.request(
            "tools/call",
            "{\"name\":\"echo\"}",
            &result_buffer,
            &out_buffer,
            &params_buffer,
        ) catch |err| {
            self.failure = @errorName(err);
            return;
        };
        self.called.take(called);
        self.remember(out_buffer[0..self.side.connection.lastEncodedLen()]);
    }
};

/// Keep an encoded request so the example can show exactly what went out.
fn keepEncoded(into: []u8, into_len: *usize, encoded: []const u8) void {
    const n = @min(encoded.len, into.len);
    @memcpy(into[0..n], encoded[0..n]);
    into_len.* = n;
}

/// Print one answer, labelled for what it is.
///
/// A refusal is labelled as one because its body is an error object, and
/// nothing inside the body says the call failed.
fn printAnswer(out: *Io.Writer, method: []const u8, answer: *const Answer) !void {
    if (answer.refused()) {
        try out.print("{s} -> refused with {d}\n  {s}\n", .{ method, answer.code, answer.text() });
    } else {
        try out.print("{s} ->\n  {s}\n", .{ method, answer.text() });
    }
}

/// The tags this file's two socket names are rendered under.
///
/// Each call site passes its own tag, and `testio.socketPath` adds a nonce of
/// its own, so two runs in one temporary directory never land on one name.
/// Distinct tags per call site are what the two literal prefixes used to do:
/// the example's socket and this file's test socket stay apart even when one
/// run picks the directory the other is using.
const example_tag: u64 = 0x5171_0001;
const runtime_test_tag: u64 = 0x5171_0002;

/// Remove the socket file this process bound, and say nothing about why it
/// stayed.
///
/// Teardown runs while `main` is unwinding or a test is already failing, so an
/// unlink that fails has nowhere to report to and reporting it would replace
/// the failure that got here. The unlink before `listen` refuses every error
/// but the absence of the file, so nothing about this file's own behaviour is
/// hidden by the ignore.
fn unlinkSocket(io: Io, path: []const u8) void {
    // The unlink is teardown while the process is unwinding, so a failure has
    // nowhere to report and reporting it would replace the real failure.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    // Whether this run's last flush has already been made, so the report is
    // written once and a write that failed is not written again.
    var final_flush_attempted = false;
    errdefer {
        if (!final_flush_attempted) {
            // Best effort, and only while `main` unwinds. This exists so the
            // lines the run already printed reach the reader beside the error
            // that got here, and that error is the one this must not replace.
            // The flush at the end of this function is what reports a report
            // that could not be written, and the guard above is set before it,
            // so nothing here repeats that attempt.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            // ziglint-ignore: Z026
            // zwanzig-disable-next-line: empty-catch-engine
            stdout.flush() catch {};
        }
    }

    try out.print("zig-agent-protocols runtime example\n\n", .{});
    try out.print("  zig       {s}\n", .{@tagName(builtin.cpu.arch)});
    try out.print("  mcp       {s} (pinned)\n", .{mcp.latest_protocol_version});
    try out.print("  a2a       1.0.0\n", .{});
    try out.print("  acp       1 (v2 gated)\n\n", .{});
    // Pushed out before anything else happens. A buffered line that a hang
    // never reaches is a line the reader never gets, and the version block is
    // the one thing worth having when the run does not finish.
    try out.flush();

    // A real socket, so this is the same code path a subprocess would take
    // over a pipe. stdio is the normative ACP transport and one of the two MCP
    // ones; a socket exercises the identical framing and JSON-RPC.
    //
    // The name is not a literal. `testio.socketPath` borrows the `TMPDIR` this
    // process was given and refuses one the machine shares with every other
    // user, so the socket lands in an area this run owns. The buffer is sized
    // from `Io.net.UnixAddress.max_len` because that is the length
    // `UnixAddress.init` refuses, and a `TMPDIR` too long to leave room for the
    // name is reported rather than rendered into a path that cannot be bound.
    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try testio.socketPath(io, init.minimal.environ, &path_buffer, example_tag);
    // A socket file left by a killed run would make `listen` fail. Only its
    // absence is the outcome this call is written for; any other is a real
    // fault and is reported here rather than becoming a `listen` error that
    // says less about it.
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        unlinkSocket(io, path);
    }

    var server_side: Side = .{};
    var client_side: Side = .{};
    var tools: ToolServer = .{};

    // One group drives both ends. Two would deadlock: the client blocks waiting
    // for an answer only the peer's task can produce.
    var group: Io.Group = .init;
    // Released on every path out of this scope, and after the cancel below has
    // joined whatever was still running on either stream. Declared first of
    // the two so that it runs last: a descriptor is closed only once no reader
    // and no writer can still be on it, and the join is what establishes that.
    defer {
        server_side.releaseSafe();
        client_side.releaseSafe();
    }
    defer group.cancel(io);
    var peer: Peer = .{
        .io = io,
        .group = &group,
        .server = &server,
        .side = &server_side,
        .handler = &tools,
    };
    var client: Client = .{
        .io = io,
        .group = &group,
        .address = &address,
        .side = &client_side,
    };

    try group.concurrent(io, Peer.run, .{&peer});
    try group.concurrent(io, Client.run, .{&client});
    // Await normal completion; the defer cancels only on an early exit. The
    // client hangs up on every path and that wakes both readers, so both
    // pumps return — and this join is what lets the defer above close a
    // descriptor no reader and no writer is still on.
    //
    // Joined with `try` because a join that reported a fault is this step's own
    // fault, and the check below reads a client flag rather than the join.
    try group.await(io);

    // Reached, not hung on. A client that returned without hanging its end up
    // left the join above waiting on a pump that could not end, and the name
    // of the error was the one thing the reader never got.
    //
    // The step fails rather than returning quietly, as `http_demo` does with
    // `error.ExchangeFailed`. This run step is the proof that the codec
    // composes on transport bytes, so an exit status of 0 on a run whose own
    // output says the exchange failed is a green build line over a broken
    // binding. The line stays on stdout beside the status, so the run says in
    // its own output what the status is about.
    if (client.failure) |name| {
        try out.print("the exchange failed: {s}\n", .{name});
        return error.ExchangeFailed;
    }

    try printAnswer(out, "tools/list", &client.listed);
    try printAnswer(out, "resources/list", &client.refused);
    try printAnswer(out, "tools/call", &client.called);
    const wire = client.last_sent[0..client.last_sent_len];
    try out.print("\nlast request on the wire:\n  {s}\n", .{wire});
    try out.print("server handled {d} request(s)\n", .{tools.calls});
    // The report, flushed once here. Every line above was still buffered, so
    // a reader given none of them was told nothing about a run that finished,
    // and that is returned as a failure rather than swallowed into a zero exit
    // status over output nobody received. The guard is set first, so the
    // unwinding path above does not attempt this same flush a second time.
    final_flush_attempted = true;
    try stdout.flush();
}

const testing = std.testing;

test "the three frames this example's client sends are all answered" {
    // The three frames `mcp_session.Client.request` writes for these three
    // calls at this revision, `_meta` wrapper and all, written out by hand
    // rather than derived from it. This test pins the handler, and a test that
    // built its frames with the session would be checking the session against
    // itself; the spelling of the wrapper is `injectMeta`'s, which
    // `mcp_session`'s own tests pin, and the exchange below drives the real
    // session over a real socket.
    //
    // A handler that declines answers nothing, and a caller blocked in `call`
    // then waits for an answer that is never coming: a decline is not a
    // failure a test sees, it is a hang. Driving the real frames through the
    // handler turns it into a failure instead, and it is the one case a frame
    // without `params` does not reach.
    var server: ToolServer = .{};
    var decode_scratch: [4096]u8 = undefined;
    var answer: [4096]u8 = undefined;
    var check: [512]u8 = undefined;

    const meta = "\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":" ++
        "{\"tools\":{}}}";
    const frames = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ meta ++ "}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/list\",\"params\":{" ++ meta ++ "}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{" ++
            meta ++ ",\"name\":\"echo\"}}",
    };

    for (frames) |frame| {
        const reply = (try ToolServer.handle(&server, frame, &decode_scratch, &answer)) orelse
            return error.DeclinedARequest;
        // An answer the reader cannot decode is as bad as no answer: the
        // reader drops a frame it cannot read and the caller waits on it.
        const message = try jsonrpc.decode(reply, &check);
        try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    }
    try testing.expectEqual(@as(usize, 3), server.calls);
}

test "the exchange drains, and a refusal the server sent reaches the client as a refusal" {
    // Both halves of this example, over a real socket.
    //
    // The join is the assertion. A client that returned without hanging its
    // end up would leave the peer's pump blocked in a read, and this test
    // would hang instead of failing, which is what the example used to do in
    // place of reporting the failure.
    //
    // The release counts are the second half of the same assertion: both
    // sides are closed once by the owner after that join, and not before, so
    // a reader that had closed one for itself would show up here as a
    // double close rather than as a hang.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    // The same kind of name the example's `main` renders, out of the same
    // environment this test binary was given, so a machine with no usable
    // `TMPDIR` fails here for the reason it would fail there rather than only
    // beside the literal `/tmp` path this line used to spell out.
    const path = try testio.socketPath(io, testing.environ, &path_buffer, runtime_test_tag);
    // As in `main`: only the absence of the file is the outcome this call is
    // written for, and any other is reported rather than swallowed.
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var address = try Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{});
    defer {
        listener.deinit(io);
        unlinkSocket(io, path);
    }

    var server_side: Side = .{};
    var client_side: Side = .{};
    var tools: ToolServer = .{};

    var group: Io.Group = .init;
    // The owner's release, after the cancel below has joined whatever was
    // still on either stream. Declared first of the two so it runs last: the
    // descriptor is closed only once no reader and no writer can be on it,
    // and this join is what establishes that.
    defer {
        server_side.releaseSafe();
        client_side.releaseSafe();
    }
    defer group.cancel(io);
    var peer: Peer = .{
        .io = io,
        .group = &group,
        .server = &listener,
        .side = &server_side,
        .handler = &tools,
    };
    var client: Client = .{
        .io = io,
        .group = &group,
        .address = &address,
        .side = &client_side,
    };
    try group.concurrent(io, Peer.run, .{&peer});
    try group.concurrent(io, Client.run, .{&client});
    // Joined with `try` for the reason given in `main`.
    try group.await(io);

    // The owner's release, on the same terms as the defer above: after the
    // join, once per side. Repeating it here is what makes the count
    // readable, and it is a no-op because the side already released.
    server_side.releaseSafe();
    client_side.releaseSafe();
    // One each, so: nothing was closed while a reader or a writer could
    // still have been on it, and nothing was left open.
    try testing.expectEqual(@as(u32, 1), server_side.releases);
    try testing.expectEqual(@as(u32, 1), client_side.releases);

    try testing.expect(client.failure == null);
    // Three requests reached the server, and the refusal is one of them: the
    // client asked for a method, so the count cannot be read as a call the
    // server declined to receive.
    try testing.expectEqual(@as(usize, 3), tools.calls);

    // The two answers the server meant to give carry no code, and the one it
    // refused carries the specification's own `-32601` beside its body. That
    // code is the whole difference between a refusal and a result here.
    try testing.expect(!client.listed.refused());
    try testing.expect(!client.called.refused());
    try testing.expectEqual(@as(i32, -32601), client.refused.code);
    try testing.expect(std.mem.indexOf(u8, client.refused.text(), "resources/list") != null);

    // The list answer is a conformant result at the revision this session is
    // pinned to: a `resultType`, and the two fields a cacheable result adds.
    var scratch: [512]u8 = undefined;
    const kind = try mcp.decodeResultType(client.listed.text(), &scratch);
    try testing.expectEqualStrings(mcp.result_type_value.complete, kind.value.?);
    const cacheable = try mcp.decodeCacheable(client.listed.text(), &scratch);
    try testing.expectEqual(@as(u64, 60000), cacheable.ttl_ms);
    try testing.expectEqual(mcp.CacheScope.public, cacheable.cache_scope);
}

test "a method the server does not have is refused beside the result, not inside it" {
    var server: ToolServer = .{};
    var decode_scratch: [4096]u8 = undefined;
    var answer: [4096]u8 = undefined;
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}";
    const reply = (try ToolServer.handle(&server, frame, &decode_scratch, &answer)) orelse
        return error.DeclinedARequest;

    var check: [512]u8 = undefined;
    const message = try jsonrpc.decode(reply, &check);
    // `result` and `error` are mutually exclusive on the wire, and a decoder
    // reads a result with no error member as a success. An error object inside
    // a result is a successful call whose body is a refusal, and the code the
    // peer needs is nowhere on the frame.
    try testing.expect(message.result == null);
    const refusal = message.rpc_error orelse return error.ExpectedARefusal;
    try testing.expectEqual(@as(i32, -32601), refusal.code);
    // The message names the method, so a peer can tell which one was refused.
    // The handler writes it through `json.Writer.string`, which escapes, so the
    // quotes around the method are part of the message a caller reads.
    try testing.expectEqualStrings(
        "no handler for \"resources/list\"",
        refusal.message,
    );
}

test "a string id is answered in the arm it arrived in" {
    var server: ToolServer = .{};
    var decode_scratch: [4096]u8 = undefined;
    var answer: [4096]u8 = undefined;
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":\"call-7\",\"method\":\"tools/list\"}";
    const reply = (try ToolServer.handle(&server, frame, &decode_scratch, &answer)) orelse
        return error.DeclinedARequest;

    var check: [512]u8 = undefined;
    const message = try jsonrpc.decode(reply, &check);
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    // An id is an integer or a string, and a response is matched by id and by
    // nothing else, so the answer has to carry the id as the string it
    // arrived as. Reading the integer arm instead is a trap.
    const id = message.id orelse return error.ExpectedAnId;
    try testing.expectEqualStrings("call-7", id.string);
    try testing.expect(message.rpc_error == null);
    try testing.expect(std.mem.indexOf(u8, message.result.?, "\"resultType\"") != null);
}

test "a method written with an escape is answered as the method it decodes to" {
    var server: ToolServer = .{};
    var decode_scratch: [4096]u8 = undefined;
    var answer: [4096]u8 = undefined;
    // `tools\/list` decodes to `tools/list`, and the decoder unescapes it into
    // the decode region rather than borrowing it from the frame. The answer is
    // composed into the other region, so the name is still whole when the
    // branch compares it and the id is still whole when the builder echoes it.
    //
    // Two regions make that structural rather than a matter of order. A handler
    // given one has the writer's first bytes land on the name and takes the
    // refusal branch instead, silently, and no assertion inside the handler
    // would say so.
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools\\/list\"}";
    const reply = (try ToolServer.handle(&server, frame, &decode_scratch, &answer)) orelse
        return error.DeclinedARequest;

    var check: [512]u8 = undefined;
    const message = try jsonrpc.decode(reply, &check);
    try testing.expect(message.rpc_error == null);
    try testing.expect(std.mem.indexOf(u8, message.result.?, "\"cacheScope\"") != null);
}

test "an answer as long as the buffer call fills is not cut" {
    // The result buffer `conn.Conn.call` fills and the `Answer` body it is
    // copied into are both `answer_capacity`, and `Response.body` is a prefix
    // of that buffer, so an answer of this length is the longest one this
    // client's `take` can be handed.
    //
    // It is also the case the two sizes used to disagree about. A `tools/list`
    // answer of a few more tools lands between 2048 and 4096 bytes: `call`
    // accepted it whole, `take` cut it to the length of its own body with no
    // marker, and `main` printed the prefix under a `tools/list ->` heading
    // that claims it is the whole result.
    var answer: Answer = .{};
    var body: [answer_capacity - 1]u8 = undefined;
    @memset(&body, 'x');
    answer.take(.{ .body = &body });

    try testing.expectEqual(body.len, answer.len);
}
