//! A working MCP server and client over Streamable HTTP, in one process.
//!
//! This is the second of the two MCP transports; the first is stdio, which
//! `runtime_demo.zig` drives. The part stdio cannot show is the one this
//! example is for: a reply is either one JSON body or a long-lived event
//! stream, and both are legal for the same request. The client asks for both
//! in one `Accept` and the server takes the choice per request, so both
//! shapes run here against a real server, over a real loopback socket.
//!
//! The headers are the ones `2026-07-28` requires, and the two it removed are
//! absent: `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, the derived
//! `Mcp-Param-{Name}`, and the two-type `Accept`. `Mcp-Session-Id` and
//! `Last-Event-ID` are gone at this revision, so neither is sent and the
//! answer mints no session to put one in.
//!
//! Every buffer below belongs to the caller, on both sides, so the example
//! doubles as a check that the transport is usable without an allocator. The
//! one allocator it takes from `init` is the one each exchange's
//! `std.http.Client` needs for its own connection pool, and no connection
//! outlives the exchange that made it.
//!
//! The two tasks share one group and one handoff, and no wait in either of
//! them outlives the other. The two waits fail for different reasons and are
//! answered differently, so neither mechanism covers the other wait.
//! A `receive` waits on a socket the client owns, and the client closing it
//! on the way out is what ends that wait. An `accept` waits on a listening
//! socket, which no peer can shut down, so the client announces a
//! connection once the kernel has it queued and the accept is then a call
//! that returns rather than one that waits. The client sets the handoff flag
//! on every path out of its task, so the server stops whether the client
//! finished or failed.
//!
//! Run it with `zig build run-http`.

const std = @import("std");
const proto = @import("zig-agent-proto");

const conn = proto.conn;
const http = proto.http;
const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;

const Io = std.Io;
/// The standard library's HTTP client sits under this library's transport, so
/// both names are in scope here: `http` is MCP and `wire` is `std.http`.
const wire = std.http;

/// Which of the two reply shapes section 4.2 allows answers a POST.
const Plan = enum { json_body, event_stream };

/// The requests this example makes, in order.
const plans = [_]Plan{ .json_body, .event_stream };

/// The argument of the `echo` tool. Its `inputSchema` annotates the property
/// with `"x-mcp-header": "Text"`, which is what `Mcp-Param-Text` is derived
/// from, and the annotation is a JSON Schema keyword that never reaches the
/// wire.
const argument = "hello";

/// The body of the `tools/call` POST. `params.name` is the value `Mcp-Name`
/// must agree with, and the id is the only thing the answer can be matched
/// by.
const tools_call_body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
    "\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"" ++ argument ++ "\"}}}";

/// The `subscriptions/listen` POST: one long-lived stream, and no name,
/// because section 4.2 requires `Mcp-Name` for three methods and this is not
/// one of them.
const listen_body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"subscriptions/listen\"}";

/// The notifications the stream carries after its result. Each is one
/// server-to-client method of the `subscriptions/listen` reply, and the
/// second needs no `params` because its notification declares none.
const events = [_][]const u8{
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\"," ++
        "\"params\":{\"uri\":\"file:///demo/notes.txt\"}}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
};

/// The result arrives first, so this is how many events the client expects.
const expected_events = 1 + events.len;

/// A server that answers the two methods this example drives.
///
/// The reply is written into the scratch the transport hands the handler, so
/// it borrows that buffer for the length of the write and nothing allocates.
const Tools = struct {
    /// The handler holds no state, on purpose. One field for the method
    /// answered would hold the last request's method, because both plans
    /// dispatch this same handler and the second request overwrites the
    /// first before `main` prints. `Serve` records the method per plan.
    fn handle(_: ?*anyopaque, frame: []const u8, scratch: []u8) conn.Error!?[]const u8 {
        const message = jsonrpc.decode(frame, scratch) catch return null;
        if (message.kind != .request) return null;
        // A request that names no method is not one this server answers.
        if (message.method == null) return null;

        // Read out of the decode scratch before the reply is written over
        // it, and carry the request's own id into the answer.
        const id = switch (message.id orelse return null) {
            .integer => |value| value,
            // A string id is legal JSON-RPC and is not an id this library
            // mints, so this server does not claim to answer one.
            .string => return null,
        };
        var id_buffer: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{id}) catch return null;

        var writer = json.Writer.init(scratch);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        writer.slice(id_text) catch return null;
        writer.slice(
            ",\"result\":{\"resultType\":\"complete\"," ++
                "\"content\":[{\"type\":\"text\",\"text\":\"echo: ",
        ) catch return null;
        writer.slice(argument) catch return null;
        writer.slice("\"}]}}") catch return null;
        return writer.written();
    }
};

/// The endpoint, listened on and ready to be accepted.
///
/// Port zero, and the kernel's choice read back off the listening socket, so
/// two runs of this file cannot collide over a port. A Unix domain socket
/// would remove even that, and `std.http.Client` cannot reach one: its
/// `connectUnix` names `std.posix.SocketError`, which this toolchain's
/// `std.posix` does not define.
const Endpoint = struct {
    listener: Io.net.Server = undefined,
    uri_buffer: [64]u8 = undefined,
    uri_text: []const u8 = "",

    fn open(self: *Endpoint, io: Io) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.listener = try address.listen(io, .{});
        self.uri_text = try std.fmt.bufPrint(
            &self.uri_buffer,
            "http://127.0.0.1:{d}/mcp",
            .{self.port()},
        );
    }

    fn close(self: *Endpoint, io: Io) void {
        self.listener.deinit(io);
    }

    /// The port the kernel gave out.
    fn port(self: *const Endpoint) u16 {
        return self.listener.socket.address.getPort();
    }
};

/// One end of the exchange: the buffers, and the connection over them.
///
/// The reader and the writer are fields rather than locals in the function
/// that opens the socket, because `http.Server` keeps raw pointers to both
/// and a local would dangle before the first request. The client half uses
/// only `head`, `out`, `decode` and `transfer`.
const Side = struct {
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    stream_reader: Io.net.Stream.Reader = undefined,
    stream_writer: Io.net.Stream.Writer = undefined,

    params: [8]http.ParamHeader = undefined,
    head_scratch: [256]u8 = undefined,
    body: [4096]u8 = undefined,
    body_scratch: [1024]u8 = undefined,
    handler_scratch: [1024]u8 = undefined,
    transfer: [64]u8 = undefined,
    event: [4096]u8 = undefined,
    stream_buffer: [4096]u8 = undefined,
    server: http.Server = undefined,

    head: [8]wire.Header = undefined,
    out: [4096]u8 = undefined,
    decode: [1024]u8 = undefined,

    fn open(self: *Side, io: Io, stream: Io.net.Stream) void {
        self.stream_reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.stream_writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.server = http.Server.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            .{
                .params = &self.params,
                .head_scratch = &self.head_scratch,
                .body = &self.body,
                .body_scratch = &self.body_scratch,
                .handler_scratch = &self.handler_scratch,
                .transfer = &self.transfer,
                .event = &self.event,
                .stream = &self.stream_buffer,
            },
        );
    }
};

/// What the two tasks tell each other, and nothing else.
///
/// A streaming reply has no end, so the server cannot tell when the client
/// has what it was sent. It waits here instead of hanging up on its own: a
/// close on a socket whose peer still holds unread bytes answers with a
/// reset, and the reset discards those bytes.
///
/// Two flags and one condition carry the whole handshake, and the flags are
/// what the condition means, because a `Condition` signal with no waiter
/// yet is dropped: a client that finishes first must still be seen by a
/// server that has not begun to wait.
const Handoff = struct {
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Read and written under `mutex`, and nowhere else.
    client_done: bool = false,
    /// A connection the kernel has queued in the listener and the server has
    /// not accepted yet. The client sets it once `connectTcp` has returned,
    /// and `waitConnection` clears it, because the accept that follows is
    /// what takes the connection.
    connection_queued: bool = false,

    /// The client either holds the events it was told to expect or has given
    /// up on them, and the server may hang up either way. It is also the
    /// answer to "will there be another connection", because the client
    /// signals on every path out of its task and not only on the one that
    /// succeeded.
    fn signalDone(self: *@This(), io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.client_done = true;
        self.condition.signal(io);
    }

    /// Whether the client is finished. A server that is about to wait does
    /// not begin, and one that is waiting stops.
    fn isDone(self: *@This(), io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.client_done;
    }

    /// A connection is in the listener's queue, so `accept` returns it
    /// rather than waiting for a client that may never come.
    fn announceConnection(self: *@This(), io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.connection_queued = true;
        self.condition.signal(io);
    }

    /// Block until there is a connection to accept, or until the client says
    /// there will not be one.
    ///
    /// This is what keeps `accept` from being the one wait in this example
    /// that a client which gives up early would outlive: a listening socket
    /// has no way to be told that no more connections are coming, so the
    /// client is the only side that can say a wait for one is safe.
    fn waitConnection(self: *@This(), io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.connection_queued and !self.client_done) {
            self.condition.wait(io, &self.mutex) catch return;
        }
        self.connection_queued = false;
    }

    /// Block until the client has said so. A cancelation ends the wait,
    /// because a task that will never be answered still has to return.
    fn waitDone(self: *@This(), io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.client_done) {
            self.condition.wait(io, &self.mutex) catch return;
        }
    }
};

/// Answers the planned POSTs, one connection at a time.
///
/// The listener is the server and `http.Server` is one connection, so the
/// loop belongs here. This example's client opens one connection per
/// exchange and releases it when that exchange is over, so one pass of the
/// outer loop is one connection, and the loop ends when the client says it
/// is finished.
const Serve = struct {
    io: Io,
    listener: *Io.net.Server,
    side: *Side,
    /// What the two tasks tell each other.
    handoff: *Handoff,

    handler: conn.Handler,
    /// The answer the next POST gets. The plan moves on once it has been
    /// answered, and `answered` counts what has been answered so far.
    plan: Plan = plans[0],
    answered: *usize,
    /// What the server concluded about the derived header, so the example can
    /// show that it crossed the socket and was compared with the body.
    verdict: *?mcp.ParamVerdict,
    failed: *bool,
    converted: [mcp.param_value_max_len]u8 = undefined,
    scratch: [256]u8 = undefined,

    /// The method of the request the single-JSON plan answered, copied out of
    /// the `Post` because `post.method` borrows the transport's head buffer
    /// and the next request writes over it.
    method_buffer: [64]u8 = undefined,
    method_len: usize = 0,

    fn run(self: *@This()) void {
        while (self.answered.* < plans.len) {
            // The two waits below fail for different reasons, and each one
            // has its own answer. `receive` waits on a socket this side
            // does not own, and the client closing it is what ends that
            // wait. `accept` waits on a listening socket, which has no way to
            // be told that no more connections are coming, so the client
            // announces each connection it opens and only then is the
            // accept a call that returns.
            self.handoff.waitConnection(self.io);
            if (self.handoff.isDone(self.io)) return;
            const connection = self.listener.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            // `shutdown` before `close`. A close on a socket whose peer still
            // has unread bytes in its receive queue answers with a reset, and
            // the reset discards the bytes, so a client that has not read the
            // reply yet loses it. A shutdown lets the peer drain what is
            // already in flight, and the close then releases the descriptor.
            defer {
                connection.shutdown(self.io, .both) catch {};
                connection.close(self.io);
            }
            self.side.open(self.io, connection);

            while (self.answered.* < plans.len) {
                const post = self.side.server.receive() catch {
                    self.failed.* = true;
                    return;
                } orelse break;
                if (!self.answer(post, self.plan)) {
                    self.failed.* = true;
                    return;
                }
                self.plan = switch (self.plan) {
                    .json_body => .event_stream,
                    .event_stream => .json_body,
                };
                self.answered.* += 1;
            }
        }
    }

    /// Answer the POST in the way its plan says. False is a failure, and the
    /// reason is the socket or the peer, so the example stops rather than
    /// invent a status for it.
    fn answer(self: *@This(), post: http.Post, plan: Plan) bool {
        switch (plan) {
            .json_body => {
                // Recorded here rather than on the handler, because the
                // streaming plan dispatches the same handler and one field
                // there would answer for whichever request came last.
                const n = @min(post.method.len, self.method_buffer.len);
                @memcpy(self.method_buffer[0..n], post.method[0..n]);
                self.method_len = n;

                // The one header rule a server owns. The transport has
                // already compared `Mcp-Method` and `Mcp-Name` with the body,
                // and only the tool's own `inputSchema` says what the argument
                // is, so only the tool's dispatcher can compare the derived
                // header with the value it duplicates.
                self.verdict.* = post.checkParam(
                    "Text",
                    .{ .string_value = argument },
                    &self.converted,
                    &self.scratch,
                ) catch return false;
                _ = self.side.server.answer(post, self.handler, .single) catch return false;
            },
            .event_stream => self.stream(post) catch return false,
        }
        return true;
    }

    /// The `subscriptions/listen` shape: the result arrives first and the
    /// notifications the subscription was opened for follow on the same
    /// reply, so a server that can answer once is not answering that method.
    ///
    /// The reply has no end, so `Stream.close` is deliberately not called.
    /// The client stops reading when it holds the events it was told to
    /// expect and then says so on the handoff, and only then does the caller
    /// hang the connection up.
    fn stream(self: *@This(), post: http.Post) !void {
        const dispatch = self.handler.call orelse return error.NoAnswer;
        const result = try dispatch(
            self.handler.ctx,
            post.body,
            self.side.server.buffers.handler_scratch,
        );
        const reply = result orelse return error.NoAnswer;
        // A local, unlike the reader and the writer `Side.open` holds as
        // fields, and the difference is what `respondStream` copies. A
        // `std.http.BodyWriter` points at the server's output writer and at
        // `buffers.stream`, both of which are fields of `Side`, and its
        // state is a union with no pointer in it. Nothing in the copy aims
        // at the copy, so this local is the stream and the chunk length
        // `Stream.send` advances is the live one. `Server.answer` copies the
        // same value into a local of its own, so this is the shape the
        // transport itself is written for.
        var out = try self.side.server.respondStream(post);
        try out.send(self.side.server.buffers.event, reply);
        for (events) |event| {
            try out.send(self.side.server.buffers.event, event);
        }
        self.handoff.waitDone(self.io);
    }
};

/// Drives both POSTs and records what each one produced.
///
/// A task on the group cannot print, because the one writer belongs to the
/// main task, so the client copies what it saw into its own fields and `main`
/// prints it. The events are recorded in the order they were read, which is
/// the order they arrived.
const Client = struct {
    /// The one `Io` both tasks share, handed down from `main`. The handoff
    /// needs it, and a second executor is a second group, which deadlocks.
    io: Io,
    /// The allocator each exchange's `std.http.Client` takes for its own
    /// connection pool. One pool per exchange, released with the exchange:
    /// a pooled connection outlives the task that made it, and a server
    /// waiting on such a connection for the next request waits forever.
    allocator: std.mem.Allocator,
    endpoint: *const Endpoint,
    side: *Side,
    handoff: *Handoff,

    /// The derived header's name and value, which the request borrows and
    /// which must therefore outlive it.
    names: [64]u8 = undefined,
    values: [256]u8 = undefined,
    sentinel: [mcp.sentinelScratchLen(argument.len)]u8 = undefined,
    bindings: [1]mcp.ParamBinding = undefined,

    /// The headers each POST carried, as the transport built them.
    sent: [plans.len][8]wire.Header = undefined,
    sent_len: [plans.len]usize = [_]usize{0} ** plans.len,

    /// The single-body reply, which borrowed the side's buffers and is
    /// copied out before the second POST reuses them.
    status: wire.Status = .ok,
    message: [2048]u8 = undefined,
    message_len: usize = 0,
    error_code: ?i32 = null,
    /// Whether the single-body reply arrived on a stream, which for this
    /// revision is the only thing that tells the two shapes apart.
    streamed: bool = false,

    /// The stream reply's head, copied out before the body reader takes it.
    stream_status: wire.Status = .ok,
    content_type: [64]u8 = undefined,
    content_type_len: usize = 0,
    chunked: bool = false,
    events: [expected_events][1024]u8 = undefined,
    event_len: [expected_events]usize = [_]usize{0} ** expected_events,
    event_count: usize = 0,

    failed: bool = false,

    fn run(self: *@This()) void {
        // The signal covers every path out of this task, not only the one
        // that succeeds. A failure before the first POST leaves the server
        // waiting for a connection, and a failure after one leaves it
        // waiting for a request on a connection this task is about to
        // close; either way the flag is the only thing that says the client
        // has stopped asking, and the closed socket is the other.
        defer self.handoff.signalDone(self.io);
        if (!self.single()) {
            self.failed = true;
            return;
        }
        if (!self.listen()) self.failed = true;
    }

    /// One `tools/call` POST answered with one JSON body.
    ///
    /// `requestHeaders` is called here to record what the transport will put
    /// on the wire, and `post` calls it again over the same array to send it,
    /// so the printed request and the sent request cannot drift apart.
    fn single(self: *@This()) bool {
        var wire_client = self.pooledClient();
        defer wire_client.deinit();
        var client = self.openExchange(&wire_client) orelse return false;
        const binding = (mcp.bindParamHeader(
            "Text",
            .string,
            .{ .string_value = argument },
            &self.names,
            &self.values,
            &self.sentinel,
        ) catch return false) orelse return false;
        self.bindings[0] = binding;

        const spec: http.PostHeaders = .{
            .method = "tools/call",
            .name = "echo",
            .params = &self.bindings,
        };
        const headers = client.requestHeaders(spec, &self.side.head) catch return false;
        for (headers, 0..) |field, index| self.sent[0][index] = field;
        self.sent_len[0] = headers.len;

        const reply = client.call(1, tools_call_body, spec, &self.side.head, .{
            .transfer = &self.side.transfer,
            .out = &self.side.out,
            .decode = &self.side.decode,
        }) catch return false;
        self.status = reply.status;
        self.error_code = reply.error_code;
        self.streamed = reply.streamed;
        if (reply.message.len > self.message.len) return false;
        @memcpy(self.message[0..reply.message.len], reply.message);
        self.message_len = reply.message.len;
        return true;
    }

    /// One `subscriptions/listen` POST answered with a stream that never
    /// ends.
    fn listen(self: *@This()) bool {
        // The handoff is signalled in `run`, so it covers this function's
        // failures as well as its success: a connect that failed, a read
        // that failed, a stream that ended early, and an event too large
        // all reach it through there.
        var wire_client = self.pooledClient();
        defer wire_client.deinit();
        var client = self.openExchange(&wire_client) orelse return false;
        const spec: http.PostHeaders = .{ .method = "subscriptions/listen" };
        const headers = client.requestHeaders(spec, &self.side.head) catch return false;
        for (headers, 0..) |field, index| self.sent[1][index] = field;
        self.sent_len[1] = headers.len;

        var exchange: http.Exchange = undefined;
        client.post(&exchange, listen_body, spec, &self.side.head, &self.side.transfer) catch
            return false;
        // Deliberate. The reply never ends, so the exchange is released once
        // the expected events are in hand, and the pool that holds its
        // connection is released with it, which closes the socket.
        defer exchange.close();

        // Read off the head first: taking the body reader below is what
        // invalidates the head's strings.
        self.stream_status = exchange.status();
        self.chunked = switch (exchange.response.head.transfer_encoding) {
            .chunked => true,
            .none => false,
        };
        if (exchange.response.head.content_type) |value| {
            const n = @min(value.len, self.content_type.len);
            @memcpy(self.content_type[0..n], value[0..n]);
            self.content_type_len = n;
        }

        const reader = exchange.response.reader(exchange.transfer);
        while (self.event_count < expected_events) {
            const len = http.readEvent(reader, &self.side.out) catch return false;
            // Zero is the end of the stream, and a stream that ended before
            // the client held its events is a failure, not a short reply.
            if (len == 0) return false;
            if (len > self.events[self.event_count].len) return false;
            @memcpy(self.events[self.event_count][0..len], self.side.out[0..len]);
            self.event_len[self.event_count] = len;
            self.event_count += 1;
        }
        return true;
    }

    /// Open one connection for a transport client over `wire_client`.
    ///
    /// The connection is opened here rather than left to the URI, and it is
    /// opened per exchange, so one `std.http.Client` pool serves one POST
    /// and is released with it.
    ///
    /// The connection is announced to the server once `connectTcp` has
    /// returned, because from then on the kernel has it queued and the
    /// server's `accept` returns it rather than waiting. That is what keeps
    /// the accept from being a wait this task could outlive: a listening
    /// socket cannot be told that no more connections are coming.
    fn openExchange(self: *@This(), wire_client: *wire.Client) ?http.Client {
        const uri = std.Uri.parse(self.endpoint.uri_text) catch return null;
        const host = Io.net.HostName.init("127.0.0.1") catch return null;
        const connection = wire_client.connectTcp(host, self.endpoint.port(), .plain) catch
            return null;
        self.handoff.announceConnection(self.io);
        var client = http.Client.init(wire_client, uri, .current);
        client.connection = connection;
        return client;
    }

    /// One exchange's `std.http.Client`, pool and all, which the caller
    /// releases with a `defer`.
    ///
    /// The pool is per exchange rather than per task because `deinit` closes
    /// the socket it holds. A connection left in a pool outlives the task
    /// that made it, so the server would sit in `receive()` on a live
    /// keep-alive connection waiting for a POST that is never coming.
    fn pooledClient(self: *@This()) wire.Client {
        return .{ .allocator = self.allocator, .io = self.io };
    }
};

/// Print the request one POST put on the wire, as the transport built it.
fn showRequest(out: *Io.Writer, client: *const Client, index: usize, body: []const u8) !void {
    try out.print("  POST /mcp HTTP/1.1\n", .{});
    for (client.sent[index][0..client.sent_len[index]]) |field| {
        try out.print("  {s}: {s}\n", .{ field.name, field.value });
    }
    // The request line, `Host` and the content type are `std.http`'s to
    // write: the transport fixes the content type rather than sending it in
    // the header list above.
    try out.print("  Content-Type: {s}\n\n", .{mcp.uri_and_media.json_media_type});
    try out.print("  {s}\n", .{body});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    defer stdout.flush() catch {};

    try out.print("zig-agent-proto streamable http example\n\n", .{});
    try out.print("  mcp       {s}\n", .{mcp.latest_protocol_version});
    try out.print("  transport Streamable HTTP, the second of the two\n", .{});

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);
    try out.print("  endpoint  {s}\n\n", .{endpoint.uri_text});

    var server_side: Side = .{};
    var client_side: Side = .{};
    var tools: Tools = .{};
    var verdict: ?mcp.ParamVerdict = null;
    var answered: usize = 0;
    var failed = false;
    var handoff: Handoff = .{};

    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &tools, .call = Tools.handle },
        .answered = &answered,
        .verdict = &verdict,
        .failed = &failed,
        .handoff = &handoff,
    };
    var call = Client{
        .io = io,
        // The one allocator in this example, and the one each exchange's
        // `std.http.Client` takes for its own connection pool. Nothing on
        // the codec path allocates at all.
        .allocator = init.gpa,
        .endpoint = &endpoint,
        .side = &client_side,
        .handoff = &handoff,
    };

    // One group drives both ends. Two would deadlock: the client blocks
    // waiting for an answer only the server's task can produce.
    var group: Io.Group = .init;
    group.async(io, Serve.run, .{&serve});
    group.async(io, Client.run, .{&call});
    // Join, do not cancel: cancelling here would stop both tasks before they
    // ran. The group drains on its own on every path out of either task: the
    // client closes the socket it opened and sets the handoff flag whether it
    // finished or failed, and the server stops when it has answered every
    // plan or when the client is finished. No wait here outlives the peer
    // that has to satisfy it.
    group.await(io) catch {};

    if (failed or call.failed) {
        try out.print("the exchange failed\n", .{});
        return error.ExchangeFailed;
    }
    // Every planned POST really was answered, and the stream really carried
    // the events the client was told to expect. One counter says both: it is
    // the server's own, and it counts answers rather than requests read.
    if (answered != plans.len or call.event_count != expected_events) {
        try out.print(
            "the exchange did not complete: {d} request(s) answered, {d} event(s) read\n",
            .{ answered, call.event_count },
        );
        return error.ExchangeFailed;
    }
    // The first reply was a body and not an error. Both shapes answer `200`,
    // so the media type the client read and the JSON-RPC error code are what
    // tell them apart.
    if (call.streamed or call.error_code != null) {
        try out.print("the first reply was not one successful JSON body\n", .{});
        return error.ExchangeFailed;
    }
    // The server compared the derived header, so the example may print what
    // it concluded rather than assuming a comparison that never ran.
    const checked = verdict orelse {
        try out.print("the server compared no derived header\n", .{});
        return error.ExchangeFailed;
    };
    if (checked != .accepted) {
        try out.print("the server rejected the derived header: {s}\n", .{@tagName(checked)});
        return error.ExchangeFailed;
    }

    try out.print("-- 1. one JSON body --\n", .{});
    try showRequest(out, &call, 0, tools_call_body);
    try out.print("\n  status    {d} {s}, one JSON body\n", .{
        @intFromEnum(call.status),
        call.status.phrase() orelse @tagName(call.status),
    });
    try out.print("  reply     {s}\n", .{call.message[0..call.message_len]});
    try out.print("  server    decoded the method as {s}\n", .{
        serve.method_buffer[0..serve.method_len],
    });
    try out.print("  server    Mcp-Param-Text against arguments.text: {s}\n", .{@tagName(checked)});

    try out.print("\n-- 2. an event stream --\n", .{});
    try showRequest(out, &call, 1, listen_body);
    try out.print("\n  status    {d} {s}, {s}, transfer-encoding: {s}\n", .{
        @intFromEnum(call.stream_status),
        call.stream_status.phrase() orelse @tagName(call.stream_status),
        call.content_type[0..call.content_type_len],
        if (call.chunked) "chunked" else "not chunked",
    });
    for (call.events[0..call.event_count], 0..) |*event, index| {
        try out.print("  event {d}/{d}  {s}\n", .{
            index + 1,
            expected_events,
            event[0..call.event_len[index]],
        });
    }
    try out.print("\nserver handled {d} request(s)\n", .{answered});
}

const testing = std.testing;

test "the server stops when the client is finished before it connects" {
    // The client that never connects, and the server that has to notice.
    //
    // This is the first of the two ways this example used to hang: a client
    // that failed before it opened a socket left the server parked in `accept`
    // with nothing to accept, so the group never drained and the failure was
    // never reported.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var tools: Tools = .{};
    var verdict: ?mcp.ParamVerdict = null;
    var answered: usize = 0;
    var failed = false;
    var handoff: Handoff = .{};

    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handoff = &handoff,
        .handler = .{ .ctx = &tools, .call = Tools.handle },
        .answered = &answered,
        .verdict = &verdict,
        .failed = &failed,
    };

    // The whole client task, minus the connects: what the server hears is
    // the flag, and it is set before the server ever begins to wait.
    handoff.signalDone(io);
    serve.run();

    // Nothing was accepted, nothing was answered, and a client that went
    // away is not a transport failure.
    try testing.expectEqual(@as(usize, 0), answered);
    try testing.expect(!failed);
}

test "a client that stops after its first exchange leaves the server nothing to wait for" {
    // The client that answers one exchange and then stops.
    //
    // This is the other hang this example had: the connection went back to the
    // client's pool instead of closing, so the server sat in `receive()` on a
    // live socket waiting for a second POST that was never coming. The client
    // closes the socket and sets the flag on the way out, and the server stops
    // on each of them.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var tools: Tools = .{};
    var verdict: ?mcp.ParamVerdict = null;
    var answered: usize = 0;
    var failed = false;
    var handoff: Handoff = .{};

    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handoff = &handoff,
        .handler = .{ .ctx = &tools, .call = Tools.handle },
        .answered = &answered,
        .verdict = &verdict,
        .failed = &failed,
    };
    var call = Client{
        .io = io,
        .allocator = testing.allocator,
        .endpoint = &endpoint,
        .side = &client_side,
        .handoff = &handoff,
    };

    // `Client.run` with the second exchange left out, and with the signal
    // where `Client.run` puts it.
    const One = struct {
        client: *Client,

        fn run(self: *@This()) void {
            defer self.client.handoff.signalDone(self.client.io);
            if (!self.client.single()) self.client.failed = true;
        }
    };
    var one = One{ .client = &call };

    var group: Io.Group = .init;
    group.async(io, Serve.run, .{&serve});
    group.async(io, One.run, .{&one});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(!call.failed);
    // One POST of the two this example plans was answered, and the count
    // says one. A second counter written from the same place could not have
    // said anything else, so the check over it could never fail on its own.
    try testing.expectEqual(@as(usize, 1), answered);
    try testing.expect(answered < plans.len);
    // The one reply that arrived is the single JSON body the plan calls for,
    // and it came over a real socket.
    try testing.expectEqual(wire.Status.ok, call.status);
    try testing.expect(!call.streamed);
    try testing.expect(call.error_code == null);
    const reply = call.message[0..call.message_len];
    try testing.expect(std.mem.indexOf(u8, reply, "echo: " ++ argument) != null);
    // And the server compared the derived header the request carried.
    const checked = verdict orelse return error.NoVerdict;
    try testing.expectEqual(mcp.ParamVerdict.accepted, checked);
}
