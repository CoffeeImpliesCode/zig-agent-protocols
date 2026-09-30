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
const proto = @import("zig-agent-proto");

const conn = proto.conn;
const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;
const mcp_session = proto.mcp_session;

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

    fn handle(ctx: ?*anyopaque, frame: []const u8, scratch: []u8) conn.Error!?[]const u8 {
        const self: *ToolServer = @ptrCast(@alignCast(ctx.?));
        // The connection lends one handler scratch to every request, and two
        // things are live in it at once. The decoded request borrows the region
        // the decode writes into, and the answer borrows a second while it is
        // written from the first. One region cannot hold both: the writer's
        // first bytes land on the method name the branches below are about to
        // compare, and a peer that escaped its method name is enough to make
        // that happen, because `jsonrpc.decode` unescapes into the region it is
        // given rather than borrowing from the frame.
        //
        // The front region dies with this call. The back one is what the
        // connection writes out before it lends the scratch to the next
        // request, so the answer has to be the second region written.
        const half = scratch.len / 2;
        const request_scratch = scratch[0..half];
        const answer = scratch[half..];

        // A request and nothing else: a notification and a response are not
        // `Request` values at all, so there is nothing here to hand a builder
        // that must not be answered.
        const request = jsonrpc.decodeRequest(frame, request_scratch) catch return null;
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
        //
        // The id needs no arm of its own here either: the builder echoes it in
        // the arm it arrived in, which matters because an answer is matched by
        // id and by nothing else.
        //
        // `conn.methodNotFound` would write the code and the standard's own
        // text, and this writes the method's name into the message, so a peer
        // can tell which one was refused.
        //
        // The message is the one thing built here rather than handed to a
        // builder whole, so it is the one thing that does not need a region of
        // the scratch: `errorResponse` reads it and it is dead before this
        // function returns, and what the connection writes out is the answer
        // beside it. A local is the honest home for text with that lifetime.
        var message_buffer: [256]u8 = undefined;
        var text = json.Writer.init(&message_buffer);
        text.slice("no handler for ") catch return standard_refusal(request, answer);
        text.string(request.method.text) catch return standard_refusal(request, answer);
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
fn standard_refusal(request: jsonrpc.Request, answer: []u8) conn.Error!?[]const u8 {
    return conn.methodNotFound(request, answer) catch null;
}

/// One end of the connection: the buffers and the connection over them.
const Side = struct {
    io: Io = undefined,
    buffers: proto.stdio.Buffers = .{},
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    connection: conn.Conn = undefined,
    stream: Io.net.Stream = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned.
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    /// Whether this side's pump releases the stream when it ends. The peer sets
    /// it, because `Peer.run` hands the accepted stream over and returns, so
    /// the pump is the last task holding that descriptor. The client leaves it
    /// false, because `Client.run` hangs up its own end, and a second close
    /// releases whatever descriptor the second one is given.
    release_in_pump: bool = false,

    fn open(
        self: *Side,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) void {
        self.io = io;
        self.stream = stream;
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = conn.Conn.init(
            io,
            &self.reader.interface,
            &self.writer.interface,
            self.buffers.config(),
        );
        if (handler) |h| self.connection.setHandler(h);
        // On the group the example joins, because `Io.Group.async` does not run
        // its task until the group is awaited or cancelled.
        group.async(io, Side.pump, .{self});
    }

    /// The reader task, which ends when the peer hangs up.
    fn pump(self: *Side) void {
        self.connection.pump();
        if (self.release_in_pump) self.hangUp();
    }

    /// Hang up. `shutdown` before `close`: closing a descriptor does not
    /// interrupt a read already blocked on it, so the peer's pump would sit on
    /// an open description and the group would never finish.
    fn hangUp(self: *Side) void {
        self.stream.shutdown(self.io, .both) catch {};
        self.stream.close(self.io);
    }
};

/// What one call came back with: the body, and the code that says whether the
/// body is a result or a refusal.
///
/// The two travel together because a peer error is not a result. A refusal
/// arrives as an error object, which is a body like any other, and nothing but
/// the code beside it says the call failed. Each answer keeps its own buffer,
/// so the next call, which reuses the connection's result buffer, cannot
/// overwrite what this one returned.
const Answer = struct {
    body: [2048]u8 = undefined,
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
        // Truncated rather than dropped, so a buffer too small still shows the
        // start of a body. `call` already refuses an answer that does not fit
        // with `error.ResponseTooLarge`, so the two agree about the length.
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

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch return;
        // The reader runs on the shared group and ends by itself when the
        // client hangs up, so this task has nothing left to do and the pump is
        // the last task holding the accepted descriptor.
        self.side.release_in_pump = true;
        self.side.open(self.io, self.group, stream, .{
            .ctx = self.handler,
            .call = ToolServer.handle,
        });
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
    last_sent: [2048]u8 = undefined,
    last_sent_len: usize = 0,
    /// The error that ended the exchange, or null when it completed.
    failure: ?[:0]const u8 = null,

    /// Record the last request as it went on the wire.
    fn remember(self: *@This(), encoded: []const u8) void {
        keepEncoded(&self.last_sent, &self.last_sent_len, encoded);
    }

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch {
            self.failure = "the socket would not connect";
            return;
        };
        self.side.open(self.io, self.group, stream, null);
        // Hung up on every path out of this task, so the peer's pump sees end
        // of file and the group drains. A `defer` rather than a last line,
        // because the paths that skipped that line were the ones that failed:
        // the client returned with a flag set, its own pump stayed blocked in
        // a read on a descriptor nobody closed, and the join never returned.
        defer self.side.hangUp();

        // A session pinned to the current revision. There is no handshake
        // here, so the capabilities ride on each request in `_meta`.
        var session = mcp_session.Client.init(&self.side.connection, .current);
        session.capabilities = "{\"tools\":{}}";

        var result_buffer: [4096]u8 = undefined;
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
        //
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    defer stdout.flush() catch {};

    try out.print("zig-agent-proto runtime example\n\n", .{});
    try out.print("  zig       {s}\n", .{@tagName(@import("builtin").cpu.arch)});
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
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/zig-agent-proto-example-{d}.sock", .{
        std.os.linux.getpid(),
    });
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var server_side: Side = .{};
    var client_side: Side = .{};
    var tools: ToolServer = .{};

    // One group drives both ends. Two would deadlock: the client blocks waiting
    // for an answer only the peer's task can produce.
    var group: Io.Group = .init;
    var peer = Peer{
        .io = io,
        .group = &group,
        .server = &server,
        .side = &server_side,
        .handler = &tools,
    };
    var client = Client{
        .io = io,
        .group = &group,
        .address = &address,
        .side = &client_side,
    };

    group.async(io, Peer.run, .{&peer});
    group.async(io, Client.run, .{&client});
    // Join, do not cancel: cancelling here would stop both tasks before they
    // ran. The client hangs up on every path out of its task, the peer's pump
    // sees end of file, and both pumps return on their own.
    group.await(io) catch {};

    // Reached, not hung on. A client that returned without releasing its end
    // left the join above waiting on a pump that could not end, and the name
    // of the error was the one thing the reader never got.
    if (client.failure) |name| {
        try out.print("the exchange failed: {s}\n", .{name});
        return;
    }

    try printAnswer(out, "tools/list", &client.listed);
    try printAnswer(out, "resources/list", &client.refused);
    try printAnswer(out, "tools/call", &client.called);
    const wire = client.last_sent[0..client.last_sent_len];
    try out.print("\nlast request on the wire:\n  {s}\n", .{wire});
    try out.print("server handled {d} request(s)\n", .{tools.calls});
}

const testing = std.testing;

test "the three frames this example's client sends are all answered" {
    // The exact bytes the session puts on the wire, `_meta` wrapper and all.
    //
    // A handler that declines answers nothing, and a caller blocked in `call`
    // then waits for an answer that is never coming: a decline is not a
    // failure a test sees, it is a hang. Driving the real frames through the
    // handler turns it into a failure instead, and it is the one case a frame
    // without `params` does not reach.
    var server: ToolServer = .{};
    var scratch: [4096]u8 = undefined;
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
        const answer = (try ToolServer.handle(&server, frame, &scratch)) orelse
            return error.DeclinedARequest;
        // An answer the reader cannot decode is as bad as no answer: the
        // reader drops a frame it cannot read and the caller waits on it.
        const message = try jsonrpc.decode(answer, &check);
        try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    }
    try testing.expectEqual(@as(usize, 3), server.calls);
}

test "the exchange drains, and a refusal the server sent reaches the client as a refusal" {
    // Both halves of this example, over a real socket.
    //
    // The join is the assertion. A client that returned without releasing its
    // end would leave the peer's pump blocked in a read, and this test would
    // hang instead of failing, which is what the example used to do in place
    // of reporting the failure.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "/tmp/zig-agent-proto-runtime-test-{d}.sock",
        .{std.os.linux.getpid()},
    );
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var address = try Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{});
    defer {
        listener.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var server_side: Side = .{};
    var client_side: Side = .{};
    var tools: ToolServer = .{};

    var group: Io.Group = .init;
    var peer = Peer{
        .io = io,
        .group = &group,
        .server = &listener,
        .side = &server_side,
        .handler = &tools,
    };
    var client = Client{
        .io = io,
        .group = &group,
        .address = &address,
        .side = &client_side,
    };
    group.async(io, Peer.run, .{&peer});
    group.async(io, Client.run, .{&client});
    group.await(io) catch {};

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
    var scratch: [4096]u8 = undefined;
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}";
    const answer = (try ToolServer.handle(&server, frame, &scratch)).?;

    var check: [512]u8 = undefined;
    const message = try jsonrpc.decode(answer, &check);
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
    var scratch: [4096]u8 = undefined;
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":\"call-7\",\"method\":\"tools/list\"}";
    const answer = (try ToolServer.handle(&server, frame, &scratch)).?;

    var check: [512]u8 = undefined;
    const message = try jsonrpc.decode(answer, &check);
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
    var scratch: [4096]u8 = undefined;
    // `tools\/list` decodes to `tools/list`, and the decoder unescapes it into
    // the scratch rather than borrowing it from the frame. The answer is
    // written into that same scratch and the name is compared while it is
    // written, so a handler with one region has the writer's first bytes land
    // on the name and answers the refusal branch instead.
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools\\/list\"}";
    const answer = (try ToolServer.handle(&server, frame, &scratch)).?;

    var check: [512]u8 = undefined;
    const message = try jsonrpc.decode(answer, &check);
    try testing.expect(message.rpc_error == null);
    try testing.expect(std.mem.indexOf(u8, message.result.?, "\"cacheScope\"") != null);
}
