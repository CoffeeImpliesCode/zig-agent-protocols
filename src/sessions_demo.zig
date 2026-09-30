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

    /// Runs inline on the reader task, so it answers out of the buffer the
    /// connection lends it and never calls back on this connection.
    fn handle(ctx: ?*anyopaque, frame: []const u8, scratch: []u8) conn.Error!?[]const u8 {
        const self: *Agent = @ptrCast(@alignCast(ctx.?));
        // Three regions of the one buffer, none of them a local. The decoded
        // message, the decoded envelope and the answer are all live at once,
        // and the answer has to stay readable for the write the connection
        // performs the moment this returns.
        const key_scratch = scratch[0..128];
        const envelope_scratch = scratch[128..1152];
        const body = scratch[1152..];

        const message = jsonrpc.decode(frame, key_scratch) catch return null;
        if (message.kind != .request) return null;
        const id = message.id orelse return null;
        const method = message.method orelse return null;
        self.calls += 1;

        var writer = json.Writer.init(body);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        var digits: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&digits, "{d}", .{id.integer}) catch return null;
        writer.slice(id_text) catch return null;

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
            carried(params, id, &writer, envelope_scratch) catch return null;
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
    frame_buffer: [8192]u8 = undefined,
    pending: [4]conn.Slot = undefined,
    decode_scratch: [1024]u8 = undefined,
    handler_scratch: [4096]u8 = undefined,
    out: [2048]u8 = undefined,
    result: [2048]u8 = undefined,
    params: [2048]u8 = undefined,
    /// The handshake reads the version out of the answer with a buffer of its
    /// own, because `decode_scratch` belongs to the reader task.
    handshake_scratch: [1024]u8 = undefined,
    /// Caller-owned storage for the capability decode, so the paths the client
    /// gates on outlive the call that produced them and the `result` buffer
    /// they were read from.
    cap_entries: [8]acp.Capability = undefined,
    cap_paths: [256]u8 = undefined,
    cap_scratch: [1024]u8 = undefined,
    cap_list: [8][]const u8 = undefined,
    /// The carried answers, kept apart from `result` so the first survives the
    /// second call.
    carried_result: [2048]u8 = undefined,
    outcome_scratch: [1024]u8 = undefined,
    envelope: [2048]u8 = undefined,
};

/// One end of the connection: the buffers and the connection over them.
const Endpoint = struct {
    side: Side = .{},
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned.
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    stream: Io.net.Stream = undefined,
    connection: conn.Conn = undefined,

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
        // Spawned on the group the example joins, because `Io.Group.async` does
        // not promise to run its task until the group is awaited or cancelled.
        group.async(io, pump, .{&self.connection});
    }

    /// Hang up. `shutdown` before `close`: closing a descriptor does not
    /// interrupt a read already blocked on it, so the peer's pump would sit on
    /// an open description and the group would never finish.
    fn hangUp(self: *Endpoint, io: Io) void {
        self.stream.shutdown(io, .both) catch {};
        self.stream.close(io);
    }
};

fn pump(c: *conn.Conn) void {
    c.pump();
}

/// What the exchange left behind, in buffers that outlive both tasks.
const Report = struct {
    failed: bool = false,
    /// The version both sides agreed on, and the gate every later call is
    /// decided against.
    version: u16 = 0,
    /// The paths the client adopted. Borrowed from the client's own storage.
    paths: []const []const u8 = &.{},

    /// What the opened gated method came back with.
    opened: [512]u8 = undefined,
    opened_len: usize = 0,
    /// What the client did about the closed one, in its own words.
    closed: []const u8 = "",

    /// The first carried call. The outer response succeeded and the inner one
    /// carried a result.
    inner_result: [1024]u8 = undefined,
    inner_result_len: usize = 0,

    /// The second carried call. The outer response succeeded and the inner one
    /// carried an error, which is the case the binding exists to get right.
    inner_failed: bool = false,
    inner_error: [1024]u8 = undefined,
    inner_error_len: usize = 0,
};

/// Copy an answer into a buffer that outlives the task that read it.
fn keep(into: []u8, length: *usize, text: []const u8) void {
    const n = @min(text.len, into.len);
    @memcpy(into[0..n], text[0..n]);
    length.* = n;
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

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch {
            self.report.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = self.agent,
            .call = Agent.handle,
        });
    }
};

/// The client half: one ACP session and one binding, over one connection.
const ClientTask = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    report: *Report,

    /// Give up on the exchange. The connection is hung up on the way out, so
    /// the peer's pump ends and the group finishes either way.
    fn abandon(self: *@This()) void {
        self.report.failed = true;
        self.endpoint.hangUp(self.io);
    }

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch {
            self.report.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null);
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
        //
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
        //
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
        switch (first) {
            .result => |value| keep(
                &report.inner_result,
                &report.inner_result_len,
                value,
            ),
            .@"error" => |value| {
                keep(&report.inner_error, &report.inner_error_len, value);
                report.inner_failed = true;
            },
        }

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
        switch (second) {
            .result => |value| {
                keep(&report.inner_result, &report.inner_result_len, value);
                report.inner_failed = false;
            },
            .@"error" => |value| {
                keep(&report.inner_error, &report.inner_error_len, value);
                report.inner_failed = true;
            },
        }

        // The client hangs up. The agent's reader sees end of file and returns,
        // and this side's own pump returns with it.
        self.endpoint.hangUp(self.io);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    defer stdout.flush() catch {};

    try out.print("zig-agent-proto sessions example\n\n", .{});
    try out.print("  acp   1 (settled by the handshake)\n", .{});
    try out.print("  mcp   {s} (carried over the acp connection)\n\n", .{
        mcp.latest_protocol_version,
    });

    // A Unix socket rather than a TCP port: there is no race over which port
    // the kernel handed out, so the example is deterministic, and there is no
    // port to leak. The name carries the pid, so two runs never share one.
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "/tmp/zig-agent-proto-sessions-{x}.sock",
        .{std.os.linux.getpid()},
    );
    // A socket file left by a killed run would make `listen` fail.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var report: Report = .{};
    var agent: Agent = .{};
    var server_side: Endpoint = .{};
    var client_side: Endpoint = .{};

    // One group drives both ends. Two would deadlock: the client blocks waiting
    // for an answer only the peer's task can produce.
    var group: Io.Group = .init;
    var server_task = ServerTask{
        .io = io,
        .group = &group,
        .server = &server,
        .endpoint = &server_side,
        .agent = &agent,
        .report = &report,
    };
    var client_task = ClientTask{
        .io = io,
        .group = &group,
        .address = &address,
        .endpoint = &client_side,
        .report = &report,
    };
    group.async(io, ServerTask.run, .{&server_task});
    group.async(io, ClientTask.run, .{&client_task});
    // Join, do not cancel: cancelling here would stop both tasks before they
    // ran. The client hangs up when it is done, the agent sees end of file, and
    // both pumps return on their own.
    group.await(io) catch {};

    if (report.failed) {
        try out.print("the exchange failed\n", .{});
        return;
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
    try out.print("  {s} carrying tools/call\n", .{bridge_session.method});
    try out.print("    outer call    succeeded\n", .{});
    try out.print("    inner result  {s}\n\n", .{
        report.inner_result[0..report.inner_result_len],
    });
    try out.print("  {s} carrying resources/read\n", .{bridge_session.method});
    try out.print("    outer call    succeeded\n", .{});
    const inner: []const u8 = if (report.inner_failed) "failed" else "succeeded";
    try out.print("    inner outcome {s}\n", .{inner});
    if (report.inner_failed) {
        try out.print("    inner error   {s}\n\n", .{
            report.inner_error[0..report.inner_error_len],
        });
    } else {
        try out.print("    inner result  {s}\n\n", .{
            report.inner_result[0..report.inner_result_len],
        });
    }

    // Four requests: the handshake, the one gated call the agent advertised,
    // and the two carried ones. The refused method is not among them, which is
    // the count that shows it never left the client.
    try out.print("agent handled {d} request(s), {d} of them carried\n", .{
        agent.calls,
        agent.carried,
    });
}
