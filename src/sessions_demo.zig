//! An ACP session and the `mcp-over-acp` binding, over one connection.
//!
//! The point of this example is that the two protocol layers compose without
//! either one knowing about the other. One real socket carries an ACP
//! handshake, one ACP call the agent's advertised capabilities open, one the
//! client refuses before it leaves the process, and then two MCP requests
//! carried over that same connection. The agent is a hand-written
//! [`conn.Handler`], so every answer on the wire is the library's framing and
//! JSON and not a mock of it.
//!
//! ## The safety rule this shows
//!
//! PROTOCOLS.md section 7: an inner MCP error is a *successful* outer ACP
//! response. It arrives in the outer `result` member as an `error` object, so a
//! caller that reads only the outer outcome reports a tool failure as a
//! transport failure and retries it. The second carried call here fails on the
//! inside: the printed outer result is a success and the inner one is not. Its
//! code is `-32602`, the one number both error spaces use, so the example also
//! shows that only the level tells a tool failure from a binding failure.
//!
//! The ACP layer's own rule is visible too. PROTOCOLS.md 6.5 makes omission
//! mean unsupported, so a gated method whose capability the agent never
//! advertised is refused in the client and the agent's handler never sees it.
//!
//! Run it with `zig build run-sessions`.

const std = @import("std");
const proto = @import("zig-agent-proto");

/// The socket-name helper, development-only and deliberately not part of the
/// library's public API. Where a socket may be created belongs to the
/// environment the process was handed, not to an example as a literal.
const testio = @import("testio");

const acp = proto.acp;
const acp_session = proto.acp_session;
const bridge = proto.bridge;
const bridge_session = proto.bridge_session;
const conn = proto.conn;
const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;

const Io = std.Io;

/// The gated method the agent's advertised capabilities open, and the gated
/// method they do not. PROTOCOLS.md 6.5 makes omission mean unsupported, so the
/// second is refused rather than sent.
const opened_method = "session/load";
const closed_method = "session/delete";

/// The server every carried request names. A `serverId` names a server its
/// provider declared, not a session, so it does not change from call to call.
const carried_server = "project-tools";

/// The agent this example serves: an ACP agent that also carries MCP over the
/// same connection.
const Agent = struct {
    /// Every request the handler answered. The count is what proves the
    /// locally refused method never arrived, so a request this agent has no
    /// answer for is still answered and still counted.
    calls: usize = 0,
    /// The `mcp/message` requests among them.
    carried: usize = 0,

    /// Where a carried request's own envelope is decoded, which is neither of
    /// the two regions the handler is handed.
    ///
    /// Two decoded values are live at once here: the outer message, in the
    /// `decode_scratch` the connection lends, and the inner envelope, decoded
    /// out of that message's `params`. Decoding the second into the first puts
    /// the second reader's escape offset back at zero and writes over the
    /// outer message it is still reading, and `answer` is no better, because
    /// anything the envelope unescapes would then live in the region the reply
    /// is composed into. So it is a field of the agent rather than a slice of
    /// either parameter, and its size is this caller's to choose.
    ///
    /// What it has to hold is the widest carried request's escaped `serverId`,
    /// `requestId` and inner `method` names together, since each takes its own
    /// region of it and none is recycled. The inner `params` member borrows the
    /// frame and costs nothing here.
    // SAFETY: `bridge.decodeEnvelope` unescapes each carried name in before `carried` reads one out.
    envelope: [1024]u8 = undefined,

    /// Runs inline on the reader task, so it answers out of the buffers the
    /// connection lends it and never calls back on this connection.
    fn handle(
        ctx: ?*anyopaque,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) conn.Error!?[]const u8 {
        // The context is the `Agent` `ServerTask.run` registered beside this
        // handler, and it is `agent`: a non-null field of a local in `main` that
        // outlives the group join. A null would be a wiring fault in this example,
        // and declining here would answer nothing and leave the client blocked on
        // a frame nobody would write.
        // zwanzig-disable-next-line: optional-unwrap
        const self: *Agent = @ptrCast(@alignCast(ctx.?));
        // The frame decodes into the region the connection lends and the reply
        // is composed into the other one. A name the peer escaped is unescaped
        // into `decode_scratch` rather than borrowed from the frame, and the
        // escape offset `json.Reader` keeps is per reader and not per buffer,
        // so a reply composed into the region that name was decoded into puts
        // its first bytes on the name the branches below are about to compare.

        // Both regions die with this call, because the connection writes the
        // answer out before it lends either of them to the next request.
        const message = jsonrpc.decode(frame, decode_scratch) catch return null;
        if (message.kind != .request) return null;
        const id = message.id orelse return null;
        const method = message.method orelse return null;
        self.calls += 1;

        var writer = json.Writer.init(answer);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        // The id is echoed in the arm it arrived in. A response is matched by
        // id and by nothing else, so a string id answered as an integer is an
        // answer to nothing, and a string id is legal JSON-RPC that this
        // handler has no way to promise it will not be sent: reading the
        // integer arm off a `.string` is a safety trap rather than a wrong
        // answer, and nothing about a `conn.Handler` on a socket makes the
        // peer's frame the example's own writing.
        switch (id) {
            .integer => |value| {
                var digits: [24]u8 = undefined;
                const id_text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return null;
                writer.slice(id_text) catch return null;
            },
            // `json.Writer.string` escapes, so an id the peer wrote with an
            // escape comes back as a JSON string rather than as its lexeme.
            // The text it borrows is the decode region and the writer is the
            // answer region, and those are two arrays.
            .string => |text| writer.string(text) catch return null,
        }

        if (std.mem.eql(u8, method.text, "initialize")) {
            // v1, and two advertised features. `loadSession` is the gate on
            // `session/load`, and `mcpCapabilities.acp` is the binding's own
            // key. PROTOCOLS.md 6.5 gates no ACP method on the second, which is
            // why the binding's call path is the connection and not the ACP
            // method registry.
            writer.slice(
                ",\"result\":{\"protocolVersion\":1," ++
                    "\"agentCapabilities\":{\"loadSession\":true," ++
                    "\"mcpCapabilities\":{\"acp\":true}}," ++
                    "\"agentInfo\":{\"name\":\"sessions-demo-agent\"}}}",
            ) catch return null;
        } else if (std.mem.eql(u8, method.text, opened_method)) {
            writer.slice(",\"result\":{\"sessionId\":\"s1\"}}") catch return null;
        } else if (std.mem.eql(u8, method.text, bridge_session.method)) {
            self.carried += 1;
            const params = switch (message.params) {
                .value => |value| value,
                else => return null,
            };
            carried(params, id, &writer, &self.envelope) catch return null;
        } else {
            // Answered, not dropped. A request left unanswered is a caller
            // blocked forever, and a count that skipped one would hide the
            // very case this example is about.
            writer.slice(
                ",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
            ) catch return null;
        }
        return writer.written();
    }
};

/// Write the whole outer response for one carried MCP request.
///
/// The envelope names the inner method, and the inner method is what decides
/// the outcome: this agent carries one tool and holds no resources at all.
/// Both answers are successful outer responses, which is the whole of
/// PROTOCOLS.md section 7.
///
/// `scratch` is the agent's own region rather than a slice of one the handler
/// was handed: the inner envelope is decoded while the outer message's borrows
/// are still live, and a second reader over either of those regions starts its
/// escape offset at zero again and writes over them.
///
/// The call closes the message the handler opened, outer object included.
/// The `tools/call` answer carries four opening braces and four closing ones;
/// the error answer carries three of each. `conn.Conn.route` drops a frame
/// that will not parse, so an answer one closing brace short is a caller
/// blocked forever on an answer that was already sent.
fn carried(
    params: []const u8,
    outer_id: jsonrpc.Id,
    writer: *json.Writer,
    scratch: []u8,
) (proto.DecodeError || proto.EncodeError)!void {
    const envelope = try bridge.decodeEnvelope(params, scratch, outer_id);
    if (std.mem.eql(u8, envelope.inner_method, "tools/call")) {
        // The result member, the inner result, the text object and the outer
        // message object are the four opening braces, and the last byte
        // written closes the outer one.
        try writer.slice(",\"result\":{\"result\":");
        try writer.slice(
            "{\"resultType\":\"complete\",\"content\":" ++
                "[{\"type\":\"text\",\"text\":\"echo\"}]}}",
        );
        try writer.byte('}');
    } else {
        // `-32602` is the invalid-params a `2026-07-28` server returns for a
        // resource it does not have, and it is also the binding's own outer
        // invalid request. Only the level separates the two, so this number
        // appearing on the inside is why `readOutcome` exists.
        try writer.slice(
            ",\"result\":{\"error\":{\"code\":-32602," ++
                "\"message\":\"unknown resource\"}}",
        );
        // The result member, the error object and the message are the three
        // opening braces, and this byte closes the outer one.
        try writer.byte('}');
    }
}

/// The buffers one side needs. Caller-owned, so the example cannot hide an
/// allocation behind a session.
const Side = struct {
    // SAFETY: `Endpoint.open` hands it to `conn.Conn.init`, which writes a frame in before it parses one out.
    frame_buffer: [8192]u8 = undefined,
    // SAFETY: `conn.Conn.init` runs `slot.* = .{}` over the whole table before it returns the connection.
    pending: [4]conn.Slot = undefined,
    /// Where an inbound frame is decoded into, and the region a handler is
    /// handed to decode one into. An escaped name is unescaped here rather than
    /// borrowed from the frame, so it has to hold every escaped string in one
    /// frame at once: an escaped `method`, a string `id`, an error `message`
    /// and any escaped key, each of which takes its own region of it.
    // SAFETY: `jsonrpc.decode` writes each escaped token in before it borrows one back out.
    decode_scratch: [1024]u8 = undefined,
    /// Where this side's answers are composed, and the other half of the pair
    /// `conn.Conn.init` refuses to let share a byte with the one above.
    // SAFETY: `Agent.handle` composes the answer here and returns `writer.written()`, never reading first.
    answer: [4096]u8 = undefined,
    // SAFETY: `initialize` and `request` encode into it before the writer writes those bytes to the wire.
    out: [2048]u8 = undefined,
    // SAFETY: the session decodes the answer into it, and `Response.body` slices only what it wrote.
    result: [2048]u8 = undefined,
    // SAFETY: `initialize` and `request` write the params body in before `Conn.call` encodes the frame.
    params: [2048]u8 = undefined,
    /// The handshake reads the version out of the answer with a buffer of its
    /// own, because `decode_scratch` belongs to the reader task.
    // SAFETY: the handshake decodes through it, and the reader slices out only the token it wrote.
    handshake_scratch: [1024]u8 = undefined,
    /// Caller-owned storage for the capability decode, so the paths the client
    /// gates on outlive the call that produced them and the `result` buffer
    /// they were read from.
    // SAFETY: `decodeCapabilityObject` fills each entry before `capabilityPaths` reads one of them.
    cap_entries: [8]acp.Capability = undefined,
    // SAFETY: `decodeCapabilityObject` writes each path in before the entry borrows that run.
    cap_paths: [256]u8 = undefined,
    // SAFETY: `decodeCapabilityObject` unescapes the object here before it reads a member of it.
    cap_scratch: [1024]u8 = undefined,
    // SAFETY: `capabilityPaths` fills it before the client stores the slice; an empty set writes nothing.
    cap_list: [8][]const u8 = undefined,
    /// The carried answers, kept apart from `result` so the first survives the
    /// second call.
    // SAFETY: `provider.call` decodes the answer into it before `readOutcome` parses a member of it.
    carried_result: [2048]u8 = undefined,
    // SAFETY: `readOutcome` decodes the carried payload here before the printer slices a run of it.
    outcome_scratch: [1024]u8 = undefined,
    // SAFETY: `provider.call` decodes the envelope here before `carried` compares a member of it.
    envelope: [2048]u8 = undefined,
};

/// One end of the connection: the buffers and the connection over them.
const Endpoint = struct {
    side: Side = .{},
    // SAFETY: `open` hands it to `Stream.Reader.init`, which refills it before every read it serves.
    reader_buffer: [4096]u8 = undefined,
    // SAFETY: `open` hands it to `Stream.Writer.init`, which refills it before every write it serves.
    writer_buffer: [4096]u8 = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned.
    // SAFETY: `open` assigns it from `Stream.Reader.init` before it lends `reader.interface` to `Conn.init`.
    reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `open` assigns it from `Stream.Writer.init` before it lends `writer.interface` to `Conn.init`.
    writer: Io.net.Stream.Writer = undefined,
    /// The descriptor this endpoint owns, and the proof that it owns one.
    ///
    /// `open` stores it before `Conn.init` can refuse, so a caller that gives
    /// up here still holds the descriptor it has to hang up, and `release`
    /// stores `null` before it closes, so neither end of the example can close
    /// the same number twice. An option rather than an `undefined` field
    /// because the owner releases both endpoints after the join, and one whose
    /// `open` never ran owns no descriptor at all.
    stream: ?Io.net.Stream = null,
    // SAFETY: `open` assigns it before it sets `connected`, and only a connected endpoint reads it.
    connection: conn.Conn = undefined,
    /// Whether `open` built a connection over `stream`, which it sets once
    /// `conn.Conn.init` hands one back. A hang-up reads the connection through
    /// it, so a refused `init` leaves the field alone rather than calling into
    /// a `Conn` that was never initialised.
    connected: bool = false,
    /// Whether this endpoint has been hung up already.
    closed: bool = false,

    /// Open an endpoint over `stream`, or report why there is no connection to
    /// open. `conn.Conn.init` refuses a region with no room and a pair that
    /// shares a byte, and both are wiring faults a caller sees here rather
    /// than as a wrong answer on the wire.
    ///
    /// `stream` is stored before the connection is built, so a caller that
    /// gives up here still holds the descriptor it has to hang up.
    fn open(
        self: *Endpoint,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) (conn.Error || Io.ConcurrentError)!void {
        self.stream = stream;
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
        // A blocking reader needs concurrency; `async` may run it inline. A
        // refused spawn leaves the descriptor with this endpoint and no reader
        // on it, which the owner releases after the join like any other one.
        try group.concurrent(io, pump, .{self});
    }

    /// Hang up: tell the reader to stop, wake it, and leave the descriptor to
    /// the owner.
    ///
    /// `shutdown` before anything else, and no `close` here at all. Closing a
    /// descriptor does not interrupt a read already blocked on it, so a hang-up
    /// that only closed would leave the pump sitting on an open description and
    /// the group would never finish; `shutdown` is what makes the next read
    /// return zero bytes and the loop leave.
    ///
    /// This side's own reader is the one this is for, and it is not the only
    /// task on this socket: `ClientTask.run` is a task of its own and writes
    /// every request on it, and `Agent.handle` answers on the very task that is
    /// reading. A reader that released the descriptor on its way out would take
    /// it away from a write in flight, and the standard library aborts the
    /// process on the `EBADF` that follows rather than returning an error the
    /// pump's own `catch` could see. [`release`] is the owner's, and runs once
    /// every task has joined.
    ///
    /// Best effort, and nothing is lost by it: the reader has already been told
    /// to stop, and a `shutdown` that cannot be sent means the peer is already
    /// gone. This call returns nothing and its caller is a task, so a failure
    /// has nowhere to propagate.
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
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        stream.shutdown(io, .both) catch {};
        stream.close(io);
    }
};

/// Drive the connection until it is told to stop, and stop there.
///
/// It takes the endpoint rather than the connection because that is what
/// `open` spawns it with, and because what it does *not* do is the point: the
/// descriptor is the owner's to release. This task is the only one that reads
/// the stream, but it is not the only one that uses it — `Agent.handle` answers
/// on this very task — so it leaves the release to an owner that has joined
/// this task and every other one first.
fn pump(endpoint: *Endpoint) void {
    endpoint.connection.pump();
}

/// One carried call's inner outcome.
///
/// The outer call succeeded either way, so `failed` is the only thing that
/// tells a tool failure from a binding failure, and `text` holds whichever of
/// the two answers the agent sent. `record` writes the flag and the text in one
/// place, so the buffer a later call reuses cannot leave this one reporting an
/// outcome it never received.
const Carried = struct {
    failed: bool = false,
    // SAFETY: `record` copies the payload in before it sets `len`; the printer slices those bytes.
    text: [1024]u8 = undefined,
    len: usize = 0,
};

/// What the exchange left behind, in buffers that outlive both tasks.
const Report = struct {
    failed: bool = false,
    /// The version both sides agreed on, and the gate every later call is
    /// decided against.
    version: u16 = 0,
    /// The paths the client adopted. Borrowed from the client's own storage.
    paths: []const []const u8 = &.{},

    /// What the opened gated method came back with.
    // SAFETY: `keep` copies the body in before it sets `opened_len`, and `main` slices that many bytes.
    opened: [512]u8 = undefined,
    opened_len: usize = 0,
    /// What the client did about the closed one, in its own words.
    closed: []const u8 = "",

    /// The first carried call, `tools/call`, and what the agent answered on
    /// the inside. A pair of its own rather than one pair shared with the
    /// second call, because the second answer arrives later and would then be
    /// printed under the first call's heading as well.
    first: Carried = .{},
    /// The second carried call, `resources/read`. The agent answers it with an
    /// inner error, which is the case the binding exists to get right.
    second: Carried = .{},
};

/// Copy an answer into a buffer that outlives the task that read it.
fn keep(into: []u8, length: *usize, text: []const u8) void {
    const n = @min(text.len, into.len);
    @memcpy(into[0..n], text[0..n]);
    length.* = n;
}

/// Record one carried call's inner outcome, so that the flag and the text
/// always describe the same answer.
///
/// An arm is a `bridge.OutcomePayload` rather than a bare slice, so its `text`
/// is the inner MCP payload and its `meta` is the ACP carrier metadata
/// travelling beside it. This exchange sends no carrier `_meta`, so there is
/// none to record, and the payload's `text` is the whole of what the call
/// below prints.
fn record(into: *Carried, outcome: bridge.Outcome) void {
    switch (outcome) {
        .result => |payload| {
            into.failed = false;
            keep(&into.text, &into.len, payload.text);
        },
        .@"error" => |payload| {
            into.failed = true;
            keep(&into.text, &into.len, payload.text);
        },
    }
}

/// Accepts the one connection and serves it, so the client's reader is the
/// only task left on this side.
const ServerTask = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    agent: *Agent,
    report: *Report,

    fn run(self: *ServerTask) void {
        const stream = self.server.accept(self.io) catch {
            self.report.failed = true;
            return;
        };
        // A refused `open` started no reader, so nothing is on the accepted
        // stream but this task, and it hangs its end up itself. A reader that
        // did start closes nothing: `hangUp` tells it to stop, and the owner
        // closes the stream once this group has been joined.
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = self.agent,
            .call = Agent.handle,
        }) catch {
            self.report.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
    }
};

/// The client half: one ACP session and one binding, over one connection.
const ClientTask = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    report: *Report,

    /// Give up on the exchange. Every arm that reaches here has an endpoint
    /// holding this side's stream — `open` stores it before it can refuse —
    /// so there is a descriptor to hang up, and the peer's reader ends on it.
    /// What that hang-up does not do is close: this task shares the stream with
    /// its own reader, so the close belongs to the owner and happens after the
    /// join.
    fn abandon(self: *ClientTask) void {
        self.report.failed = true;
        self.endpoint.hangUp(self.io);
    }

    fn run(self: *ClientTask) void {
        const stream = self.address.connect(self.io) catch {
            // Not `abandon`, because there is nothing of this side's to hang up:
            // `connect` failed, so `Endpoint.open` never took a stream and no
            // descriptor was ever assigned.

            // What this arm cannot reach is the agent's task, which is still
            // parked in `accept`. `main` listens before it spawns either task,
            // so the listener is already there and a connection to it is
            // queued rather than refused; this arm runs when the kernel has no
            // room for one, and then the join in `main` waits on a task that
            // will not return, because a listening socket has no way to be
            // told that no connection is coming. `http_demo` answers the same
            // wait with a handoff its client signals, and that is the
            // mechanism that would end this arm as well.
            self.report.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null) catch return self.abandon();
        const side = &self.endpoint.side;
        const report = self.report;

        // --- 1. The ACP handshake, which is where the version is settled.
        var session: acp_session.Client = .init(&self.endpoint.connection, .stable);
        const handshake = session.initialize(
            1,
            "{\"name\":\"sessions-demo-client\"}",
            // An empty object advertises nothing, which is the whole of what
            // this client offers. It never serves a client method, so a
            // capability claimed here would be a claim nothing exercises.
            "{}",
            &side.result,
            &side.out,
            &side.params,
            &side.handshake_scratch,
        ) catch return self.abandon();
        const agreed = handshake.version orelse return self.abandon();
        report.version = agreed.number();

        // The advertised paths are the gate for every call after this, so they
        // are decoded out of the handshake answer into caller-owned storage
        // before `result` is reused by the next call.
        const set = acp.decodeCapabilityObject(
            agreed,
            .agent,
            handshake.capabilities orelse "{}",
            &side.cap_entries,
            &side.cap_paths,
            &side.cap_scratch,
        ) catch return self.abandon();
        const paths = acp_session.capabilityPaths(set, &side.cap_list) catch
            return self.abandon();
        session.setAgentCapabilities(paths);
        report.paths = paths;

        // --- 2. One gated call the agent opened, and one it did not.

        // The session id is a value the client names, not a wire id, so the
        // delete names the same session the load did.
        const opened = session.request(
            opened_method,
            "{\"sessionId\":\"s1\"}",
            &side.result,
            &side.out,
        ) catch return self.abandon();
        keep(&report.opened, &report.opened_len, opened.body);

        // The gate the agent never opened. `NotPermitted` is decided here, so
        // no frame is written and the agent's count does not move.
        const closed = session.request(
            closed_method,
            "{\"sessionId\":\"s1\"}",
            &side.result,
            &side.out,
        );
        // Reaching the agent at all is the failure this example rules out, and
        // so is a refusal for any other reason, so both give up here.
        if (closed) |_| {
            return self.abandon();
        } else |err| {
            if (err != error.NotPermitted) return self.abandon();
        }
        report.closed = "refused in the client: NotPermitted, nothing sent";

        // --- 3 and 4. The binding, over the connection the session is on.

        // The binding is not in the ACP method registry, so it calls the
        // connection rather than the session: PROTOCOLS.md 6.5 gates ACP
        // methods, and the binding carries its own error space inside one.
        var provider: bridge_session.Client = .init(&self.endpoint.connection);
        // MCP `2026-07-28` and no other. The binding performs no MCP handshake,
        // so the revision is pinned here or not at all.
        provider.setRevision(.current) catch return self.abandon();

        // A `requestId` is one per logical MCP request, and a duplicate active
        // `(serverId, requestId)` pair is a binding failure. Both are taken
        // from the connection's own next id, so neither is a constant that a
        // second run or a second client could collide with.
        var request_buffer: [32]u8 = undefined;

        const first_outer = provider.call(
            carried_server,
            std.fmt.bufPrint(&request_buffer, "req-{d}", .{
                self.endpoint.connection.nextId(),
            }) catch return self.abandon(),
            "tools/call",
            "{\"name\":\"echo\",\"arguments\":{\"text\":\"hello\"}}",
            &side.carried_result,
            &side.out,
            &side.envelope,
        ) catch return self.abandon();
        const first = bridge_session.Client.readOutcome(
            first_outer,
            &side.outcome_scratch,
        ) catch return self.abandon();
        record(&report.first, first);

        // The second carried call. The outer call succeeds to get here: a
        // binding failure would have been a Zig error instead of a returned
        // body. The inner one does not.
        const second_outer = provider.call(
            carried_server,
            std.fmt.bufPrint(&request_buffer, "req-{d}", .{
                self.endpoint.connection.nextId(),
            }) catch return self.abandon(),
            "resources/read",
            "{\"uri\":\"file:///notes/0\"}",
            &side.carried_result,
            &side.out,
            &side.envelope,
        ) catch return self.abandon();
        const second = bridge_session.Client.readOutcome(
            second_outer,
            &side.outcome_scratch,
        ) catch return self.abandon();
        record(&report.second, second);

        // The client hangs up. The agent's reader sees end of file and returns,
        // and this side's own reader returns with it — which is the point at
        // which `main` owns both descriptors and may close them.
        self.endpoint.hangUp(self.io);
    }
};

/// Print one carried call. The heading names the inner MCP method, so every
/// line under it says which of the two calls it belongs to, and the outcome
/// flag picks the last of the three, so a failed call never prints a result
/// and a successful one never prints an error.
///
/// The last line is the `text` of the arm's `bridge.OutcomePayload`, which is
/// the inner MCP payload spliced verbatim. The carrier `_meta` beside it is a
/// member of the same payload, and this exchange sends none, so there is no
/// second line here to print.
fn printCarried(out: *Io.Writer, inner_method: []const u8, outcome: Carried) !void {
    try out.print("  {s} carrying {s}\n", .{ bridge_session.method, inner_method });
    try out.print("    outer call    succeeded\n", .{});
    const inner: []const u8 = if (outcome.failed) "failed" else "succeeded";
    try out.print("    inner outcome {s}\n", .{inner});
    if (outcome.failed) {
        try out.print("    inner error   {s}\n\n", .{outcome.text[0..outcome.len]});
    } else {
        try out.print("    inner result  {s}\n\n", .{outcome.text[0..outcome.len]});
    }
}

/// The tag this example's socket name is rendered under.
///
/// `testio.socketPath` adds a nonce of its own on top of it, so two runs
/// sharing one temporary directory never land on one name.
const sessions_tag: u64 = 0x5e55_0001;

/// Remove the socket file this process bound, and say nothing about why it
/// stayed.
///
/// Teardown runs while `main` is unwinding, so an unlink that fails has
/// nowhere to report to and reporting it would replace the failure that got
/// here. The unlink before `listen` refuses every error but the absence of the
/// file, so nothing about this file's own behaviour is hidden by the ignore.
fn unlinkSocket(io: Io, path: []const u8) void {
    // The unlink is teardown while `main` is unwinding, so a failure has
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
            // Best effort, and only while `main` unwinds. The failure line and
            // the error that got here are what the reader needs, and a second
            // failing flush would replace that error with its own. The flush at
            // the end of this function reports a report that could not be
            // written, and the guard above is set before it, so nothing here
            // repeats that attempt.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            // ziglint-ignore: Z026
            // zwanzig-disable-next-line: empty-catch-engine
            stdout.flush() catch {};
        }
    }

    try out.print("zig-agent-proto sessions example\n\n", .{});
    try out.print("  acp   1 (settled by the handshake)\n", .{});
    try out.print("  mcp   {s} (carried over the acp connection)\n\n", .{
        mcp.latest_protocol_version,
    });

    // A Unix socket rather than a TCP port: there is no race over which port
    // the kernel handed out, so the example is deterministic, and there is no
    // port to leak. The name carries this call's tag and a nonce
    // `testio.socketPath` draws, so two runs never share one.
    //
    // It is not a literal `/tmp` path. The helper borrows the `TMPDIR` this
    // process was given and refuses one the machine shares with every other
    // user, so the socket lands in an area this run owns. The buffer is sized
    // from `Io.net.UnixAddress.max_len` because that is the length
    // `UnixAddress.init` refuses, and a `TMPDIR` too long to leave room for the
    // name is reported rather than rendered into a path that cannot be bound.
    var path_buffer: [Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try testio.socketPath(io, init.minimal.environ, &path_buffer, sessions_tag);
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

    var report: Report = .{};
    var agent: Agent = .{};
    var server_side: Endpoint = .{};
    var client_side: Endpoint = .{};

    // One group drives both ends. Two would deadlock: the client blocks waiting
    // for an answer only the peer's task can produce.
    var group: Io.Group = .init;
    defer {
        server_side.release(io);
        client_side.release(io);
    }
    defer group.cancel(io);
    var server_task: ServerTask = .{
        .io = io,
        .group = &group,
        .server = &server,
        .endpoint = &server_side,
        .agent = &agent,
        .report = &report,
    };
    var client_task: ClientTask = .{
        .io = io,
        .group = &group,
        .address = &address,
        .endpoint = &client_side,
        .report = &report,
    };
    try group.concurrent(io, ServerTask.run, .{&server_task});
    try group.concurrent(io, ClientTask.run, .{&client_task});
    // Await normal completion; the defer cancels only on an early exit.
    // The client hangs up when done; both readers then return.
    //
    // `await` also joins on cancellation. On a refused spawn the cancel defer
    // runs before the release defer, so neither descriptor is closed while a
    // task can still use it.
    try group.await(io);

    // The step fails rather than returning quietly. `http_demo` answers the
    // same condition with `error.ExchangeFailed`, and this run step is the
    // proof that the two protocol layers compose on transport bytes, so an
    // exit status of 0 on a run whose own output says the exchange failed is
    // a green build line over a broken binding. The line stays on stdout
    // beside the status, so the run says in its own output what the status is
    // about.
    if (report.failed) {
        try out.print("the exchange failed\n", .{});
        return error.ExchangeFailed;
    }

    try out.print("ACP handshake\n", .{});
    try out.print("  asked for wire version 1, agreed on {d}\n", .{report.version});
    try out.print("  the client now gates on ", .{});
    if (report.paths.len == 0) {
        try out.print("nothing", .{});
    } else {
        for (report.paths, 0..) |advertised, index| {
            const separator: []const u8 = if (index == 0) "" else ", ";
            try out.print("{s}{s}", .{ separator, advertised });
        }
    }
    try out.print("\n\n", .{});

    try out.print("ACP gating on what the agent advertised\n", .{});
    try out.print("  {s}  gated on loadSession\n", .{opened_method});
    try out.print("    -> {s}\n", .{report.opened[0..report.opened_len]});
    try out.print("  {s}  gated on session.delete, which the agent did not advertise\n", .{
        closed_method,
    });
    try out.print("    -> {s}\n\n", .{report.closed});

    try out.print("mcp-over-acp, carried over the same connection\n", .{});
    try printCarried(out, "tools/call", report.first);
    try printCarried(out, "resources/read", report.second);

    // Four requests: the handshake, the one gated call the agent advertised,
    // and the two carried ones. The refused method is not among them, which is
    // the count that shows it never left the client.
    try out.print("agent handled {d} request(s), {d} of them carried\n", .{
        agent.calls,
        agent.carried,
    });
    // The report, flushed once here. Every line above was still buffered, so
    // a reader given none of them was told nothing about a run that composed
    // its whole output and then lost it, and that is returned as a failure
    // rather than swallowed into a zero exit status. The guard is set first,
    // so the unwinding path above does not attempt this flush a second time.
    final_flush_attempted = true;
    try stdout.flush();
}

const testing = std.testing;

test "the second carried call cannot overwrite what the first one recorded" {
    var report: Report = .{};
    record(&report.first, .{ .result = .{ .text = "{\"echo\":\"hello\"}" } });
    record(&report.second, .{ .@"error" = .{ .text = "{\"code\":-32602}" } });

    // The two calls answered in opposite directions, so one shared pair would
    // leave both flags reading `failed` and both texts holding the error, and
    // the first call's own result would be gone.
    try testing.expect(!report.first.failed);
    try testing.expect(report.second.failed);
    try testing.expectEqualStrings("{\"echo\":\"hello\"}", report.first.text[0..report.first.len]);
    try testing.expectEqualStrings("{\"code\":-32602}", report.second.text[0..report.second.len]);
}

test "every printed line names the carried call it belongs to" {
    var first: Carried = .{};
    record(&first, .{ .result = .{ .text = "{\"resultType\":\"complete\"}" } });
    var second: Carried = .{};
    record(&second, .{ .@"error" = .{ .text = "{\"code\":-32602}" } });

    var buffer: [512]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    try printCarried(&out, "tools/call", first);
    try printCarried(&out, "resources/read", second);

    const printed =
        \\  mcp/message carrying tools/call
        \\    outer call    succeeded
        \\    inner outcome succeeded
        \\    inner result  {"resultType":"complete"}
        \\
        \\  mcp/message carrying resources/read
        \\    outer call    succeeded
        \\    inner outcome failed
        \\    inner error   {"code":-32602}
        \\
        \\
    ;
    try testing.expectEqualStrings(printed, out.buffered());
}

test "a method written with an escape is answered on the branch it decodes to" {
    // `mcp\/message` decodes to `mcp/message`, and the decoder unescapes it
    // into the decode region rather than borrowing it from the frame. The
    // reply is composed into the other region, so the name is still whole
    // when the branch below compares it. One region would put the writer's
    // first bytes on the name, the agent would answer `-32601` instead, and
    // nothing on the wire or inside the handler would say so.
    var agent: Agent = .{};
    var decode_scratch: [1024]u8 = undefined;
    var answer: [4096]u8 = undefined;
    const frame =
        \\{"jsonrpc":"2.0","id":7,"method":"mcp\/message","params":{"serverId":
        \\"project-tools","requestId":"req-1","method":"tools/call","params":
        \\{"name":"echo","arguments":{"text":"hello"}}}}
    ;
    const reply = (try Agent.handle(&agent, frame, &decode_scratch, &answer)) orelse
        return error.DeclinedARequest;

    // The carried branch, and the inner success that decides it. The whole
    // outer response is pinned rather than a member of it: `conn.Conn.route`
    // drops a frame that will not parse, so an answer one closing brace short
    // is a caller blocked forever on an answer that was already sent.
    try testing.expectEqual(@as(usize, 1), agent.calls);
    try testing.expectEqual(@as(usize, 1), agent.carried);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"result\":" ++
            "{\"resultType\":\"complete\",\"content\":" ++
            "[{\"type\":\"text\",\"text\":\"echo\"}]}}}",
        reply,
    );
}

test "an escaped carried envelope is decoded into the agent's own region" {
    // Both escapes here are the peer's own spelling and decode to the names the
    // demo already sends: `project-tools` and `tools/call`. The inner one
    // decides the branch, so it has to be unescaped into a region of its own
    // before the comparison, and a region too small to hold it fails the
    // decode and the handler declines. A caller blocked forever on a request
    // that arrived is what pins the size.
    var agent: Agent = .{};
    var decode_scratch: [1024]u8 = undefined;
    var answer: [4096]u8 = undefined;
    const frame =
        \\{"jsonrpc":"2.0","id":8,"method":"mcp/message","params":{"serverId":
        \\"project\u002Dtools","requestId":"req-2","method":"tools\/call","params":
        \\{"name":"echo"}}}
    ;
    const reply = (try Agent.handle(&agent, frame, &decode_scratch, &answer)) orelse
        return error.DeclinedARequest;

    try testing.expectEqual(@as(usize, 1), agent.carried);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"result\":" ++
            "{\"resultType\":\"complete\",\"content\":" ++
            "[{\"type\":\"text\",\"text\":\"echo\"}]}}}",
        reply,
    );
}

test "a string id is answered in the arm it arrived in" {
    // A string id is legal JSON-RPC and legal here: `conn.Conn.route` hands
    // every request to this handler whatever arm its id arrived in, and every
    // byte off that socket is a peer's. Reading the integer arm instead is a
    // safety panic in Debug and ReleaseSafe rather than a wrong answer, so the
    // handler has to branch on the arm to be able to answer at all.
    var agent: Agent = .{};
    var decode_scratch: [1024]u8 = undefined;
    var answer: [4096]u8 = undefined;
    const frame =
        \\{"jsonrpc":"2.0","id":"x","method":"session/load"}
    ;
    const reply = (try Agent.handle(&agent, frame, &decode_scratch, &answer)) orelse
        return error.DeclinedARequest;

    // The whole answer is pinned rather than a member of it: an answer that
    // does not parse is one `conn.Conn.route` drops, and a dropped answer is a
    // caller waiting on a reply that is never coming.
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":"x","result":{"sessionId":"s1"}}
    , reply);
    try testing.expectEqual(@as(usize, 1), agent.calls);
    // An answer is matched by id and by nothing else, so the id has to come
    // back as the string it arrived as.
    var check: [256]u8 = undefined;
    const message = try jsonrpc.decode(reply, &check);
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    const id = message.id orelse return error.ExpectedAnId;
    try testing.expectEqualStrings("x", id.string);
}
