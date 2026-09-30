//! The `mcp-over-acp` binding, driven over a live connection.
//!
//! PROTOCOLS.md section 7: the only defined composition between these
//! protocols. A provider carries stateless MCP `2026-07-28` requests over an
//! existing ACP connection, using one method, `mcp/message`, in two
//! directions.
//!
//! ## The three ways this can go wrong
//!
//! - **An inner MCP error is a successful outer response.** It arrives in the
//!   outer `result` member as an `error` object, not as an outer `error`. A
//!   client that only looks at whether the outer call failed reports a tool
//!   failure as a transport failure, and then retries it, which is exactly
//!   what the binding's whole design exists to prevent.
//! - **The error spaces overlap.** `-32602` is both the JSON-RPC standard
//!   "invalid params" an MCP server returns inside a tool error and this
//!   binding's own outer `invalid_request`. Only the level tells them apart,
//!   which is why `bridge.isBindingFailure` takes one.
//! - **The binding is MCP `2026-07-28` only.** It does not emulate earlier
//!   revisions and performs no MCP handshake, so a caller pinned to another
//!   revision is refused here rather than downstream.

const std = @import("std");
const bridge = @import("bridge.zig");
const conn = @import("conn.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const mcp = @import("mcp.zig");
const mcp_session = @import("mcp_session.zig");
const root = @import("root.zig");
const Io = std.Io;

pub const Error = error{
    /// The binding carries MCP `2026-07-28` only, and the caller pinned a
    /// session to something else.
    UnsupportedMcpRevision,
    /// The outer response carried neither an inner result nor an inner error.
    NoInnerOutcome,
    /// A caller-supplied buffer was too small.
    BufferTooSmall,
} || root.EncodeError || conn.Error;

/// The one method this binding uses.
pub const method = "mcp/message";

/// A client that carries MCP calls over an ACP connection.
pub const Client = struct {
    connection: *conn.Conn,
    /// The MCP revision carried inside. The binding is `2026-07-28` only.
    revision: mcp.Revision = .current,

    pub fn init(connection: *conn.Conn) Client {
        return .{ .connection = connection };
    }

    /// Pin the inner MCP revision.
    ///
    /// Refused rather than warned about: a binding that emulated `2025-11-25`
    /// would need an MCP handshake it does not perform, so every call on it
    /// would fail somewhere less obvious than here.
    pub fn setRevision(self: *Client, revision: mcp.Revision) Error!void {
        if (revision != .current) return error.UnsupportedMcpRevision;
        self.revision = revision;
    }

    /// Carry one MCP call and return its inner result.
    ///
    /// `server_id` names a server the provider declared and is never rebound;
    /// `request_id` is one per logical MCP request and survives proxies. The
    /// outer ACP id is this connection's own and a proxy may renumber it.
    ///
    /// The outer `result` body comes back for an inner result and for an
    /// inner error alike, because the outer call succeeded either way. An
    /// inner MCP error is therefore data and not an error return, and this
    /// function has no way to report one as a connection failure. Read the
    /// body with `readOutcome`, or with `classifyOutcome`, before acting on
    /// it: a caller that stopped here would report a tool failure as a
    /// success.
    pub fn call(
        self: *Client,
        server_id: []const u8,
        request_id: []const u8,
        method_name: []const u8,
        params: ?[]const u8,
        inner: []u8,
        out: []u8,
        envelope: []u8,
    ) Error![]const u8 {
        if (self.revision != .current) return error.UnsupportedMcpRevision;

        const body = try encodeEnvelope(server_id, request_id, method_name, params, envelope);
        const answer = try self.connection.call(method, body, inner, out);
        if (answer.error_code) |code| {
            // An outer error is a binding failure, and the binding allocates
            // its codes outside MCP's reserved range precisely so this cannot
            // be confused with a tool failure.
            if (bridge.isBindingFailure(code, .outer)) return error.ConnectionClosed;
            return error.Transport;
        }
        return answer.body;
    }

    /// Read an inner outcome out of a successful outer `result`.
    ///
    /// This is the step that keeps an inner failure from being mistaken for a
    /// success. It is a separate call rather than something `call` hides,
    /// because the caller has to look at both possibilities to answer
    /// correctly.
    pub fn readOutcome(outer_result: []const u8, scratch: []u8) Error!bridge.Outcome {
        return bridge.decodeOutcome(outer_result, scratch) catch |err| switch (err) {
            error.MissingField => error.NoInnerOutcome,
            else => error.NoInnerOutcome,
        };
    }
};

/// Build the `params` object for one carried MCP request.
pub fn encodeEnvelope(
    server_id: []const u8,
    request_id: []const u8,
    method_name: []const u8,
    params: ?[]const u8,
    out: []u8,
) root.EncodeError![]const u8 {
    var writer = json.Writer.init(out);
    try writer.slice("{\"serverId\":");
    try writer.string(server_id);
    try writer.slice(",\"requestId\":");
    try writer.string(request_id);
    try writer.slice(",\"method\":");
    try writer.string(method_name);
    if (params) |text| {
        try writer.slice(",\"params\":");
        try writer.slice(text);
    }
    try writer.byte('}');
    return writer.written();
}

/// The body a provider returns for a carried MCP request.
///
/// Exactly one of the two members is set. `inner_error` is set for an MCP
/// error, which is still a successful outer response; a caller that reads
/// `inner_result` without checking this flag reports a tool failure as
/// success.
pub const Outcome = struct {
    inner_result: ?[]const u8 = null,
    inner_error: ?[]const u8 = null,

    /// Whether the carried MCP operation failed. The outer call succeeded
    /// either way.
    pub fn failed(self: Outcome) bool {
        return self.inner_error != null;
    }
};

/// Split a successful outer `result` into its two possible shapes.
pub fn classifyOutcome(outer_result: []const u8, scratch: []u8) Error!Outcome {
    const outcome = try Client.readOutcome(outer_result, scratch);
    return switch (outcome) {
        .result => .{ .inner_result = outcome.result },
        .@"error" => .{ .inner_error = outcome.@"error" },
    };
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test "an envelope carries the three members the binding names" {
    var out: [256]u8 = undefined;
    const body = try encodeEnvelope("project-tools:7a72", "req-1", "tools/call", "{\"name\":\"echo\"}", &out);
    try testing.expectEqualStrings(
        "{\"serverId\":\"project-tools:7a72\",\"requestId\":\"req-1\"," ++
            "\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}",
        body,
    );
}

test "an envelope with no inner params is still well formed" {
    var out: [256]u8 = undefined;
    const body = try encodeEnvelope("s", "r", "subscriptions/listen", null, &out);
    try testing.expectEqualStrings(
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"subscriptions/listen\"}",
        body,
    );
}

test "a carried result is a success, not a failure" {
    var scratch: [256]u8 = undefined;
    const outcome = try classifyOutcome(
        "{\"result\":{\"resultType\":\"complete\"}}",
        &scratch,
    );
    try testing.expect(!outcome.failed());
    try testing.expect(outcome.inner_error == null);
    try testing.expect(outcome.inner_result != null);
}

test "an inner MCP error is a failure even though the outer call succeeded" {
    // This is the case the binding exists to get right. The outer response
    // carried `result`, so an outer-only check reports success; the inner
    // error is the failure.
    var scratch: [256]u8 = undefined;
    const outcome = try classifyOutcome(
        "{\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}",
        &scratch,
    );
    try testing.expect(outcome.failed());
    try testing.expect(outcome.inner_result == null);
    try testing.expect(std.mem.indexOf(u8, outcome.inner_error.?, "unknown tool") != null);
}

test "the error spaces stay apart across the boundary" {
    // -32602 is the one number both spaces use. Only the level separates an
    // MCP tool failure from a binding failure, so a caller that drops the
    // level would retry a tool failure as though it were a transport failure.
    try testing.expect(!bridge.isBindingFailure(-32602, .inner));
    try testing.expect(bridge.isBindingFailure(-32602, .outer));

    // The binding allocates outside MCP's reserved range, so no inner code can
    // ever be read as a binding failure.
    for ([_]i32{ -32000, -32019, -32020, -32022, -32601, -32602 }) |code| {
        try testing.expect(!bridge.isBindingFailure(code, .inner));
    }
}

test "an outer result with no inner outcome is refused" {
    var scratch: [256]u8 = undefined;
    try testing.expectError(
        error.NoInnerOutcome,
        classifyOutcome("{}", &scratch),
    );
}

test "the binding refuses an MCP revision it cannot carry" {
    // The binding performs no MCP handshake, so emulating 2025-11-25 would
    // fail somewhere far less obvious than at the call that asked for it.
    var client = Client.init(undefined);
    try testing.expectError(error.UnsupportedMcpRevision, client.setRevision(.previous));
    try client.setRevision(.current);
    try testing.expectEqual(mcp.Revision.current, client.revision);
}

test "the binding carries both outcomes over a real socket" {
    // The tests above decide what a carried answer means. Only a real socket
    // shows that an inner MCP error arrives inside a successful outer
    // `result` and never as a connection failure, which is the mistake this
    // binding exists to prevent: a caller that saw one would report a tool
    // failure as a broken transport and retry it.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    var address = try listenOn(io, &path_buffer, 0x5eed_0201);
    // Unlinked after the listener closes, not before: a path removed while
    // the server is still bound can no longer be connected to.
    defer std.Io.Dir.cwd().deleteFile(io, address.path) catch {};
    defer address.server.deinit(io);

    var state: State = .{};
    var provider_endpoint: Endpoint = .{};
    var caller_endpoint: Endpoint = .{};
    var provider_double: Provider = .{ .state = &state };

    // One group drives both sides. Two would deadlock: the caller blocks
    // waiting for an answer only the provider's task can produce.
    var group: Io.Group = .init;
    var serving = ProviderTask{
        .io = io,
        .group = &group,
        .server = &address.server,
        .endpoint = &provider_endpoint,
        .provider = &provider_double,
    };
    var calling = Caller{
        .io = io,
        .group = &group,
        .address = &address.address,
        .endpoint = &caller_endpoint,
        .state = &state,
    };
    group.async(io, ProviderTask.run, .{&serving});
    group.async(io, Caller.run, .{&calling});
    group.await(io) catch {};

    // The group joined because both sides hung up on their own. Nothing here
    // waits on a timer, so the exchange is over before these assertions run.
    try testing.expect(!state.failed);

    // The inner result arrived as a success, byte for byte as the provider
    // wrote it, so the envelope crossed the boundary intact.
    try testing.expectEqualStrings("{\"tools\":[{\"name\":\"echo\"}]}", state.listed_result);

    // The inner error arrived inside a successful outer response: the outer
    // call returned, and the body reads as a failure with no result beside
    // it. Its code is still the inner one, and `-32602` at this level is not
    // a binding failure, so a caller that classifies it here retries nothing.
    try testing.expect(state.refused_failed);
    try testing.expect(!state.refused_has_result);
    try testing.expect(std.mem.indexOf(u8, state.refused_error, "-32602") != null);
    try testing.expect(std.mem.indexOf(u8, state.refused_error, "unknown tool") != null);

    // The provider answered both carried calls and nothing else, so the
    // second answer is the second call's and not the first one read twice.
    try testing.expectEqual(@as(usize, 2), state.answered);
}

/// What the exchange proved, reported back after the group is joined.
///
/// Every slice borrows the caller's own buffers, which outlive the join, so
/// the test reads the bytes that came back rather than a copy of them.
const State = struct {
    /// Set by whichever task could not finish, so a failure surfaces as an
    /// assertion and not as a silently empty result.
    failed: bool = false,
    listed_result: []const u8 = "",
    refused_failed: bool = false,
    refused_has_result: bool = false,
    refused_error: []const u8 = "",
    /// The carried calls the provider answered.
    answered: usize = 0,
};

/// A listening Unix socket, with the address that reaches it.
///
/// A Unix socket rather than a TCP port: there is no race over which port the
/// kernel handed out, so the test is deterministic under parallel runs, and
/// there is no port to leak when the process dies.
///
/// `Io.net.UnixAddress` borrows its path, so the path buffer belongs to the
/// caller and must outlive both halves. A path built in a helper's own frame
/// would be dead the moment the helper returned.
const Socket = struct {
    address: Io.net.UnixAddress,
    server: Io.net.Server,
    path: []const u8,
};

fn listenOn(io: Io, path_buffer: []u8, tag: u64) !Socket {
    const path = try std.fmt.bufPrint(
        path_buffer,
        "/tmp/zig-agent-proto-bridge-session-{x}.sock",
        .{tag},
    );
    // A socket file left by a killed run would make `listen` fail.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const address = try Io.net.UnixAddress.init(path);
    return .{
        .address = address,
        .server = try address.listen(io, .{}),
        .path = path,
    };
}

/// The provider the caller carries MCP calls to.
///
/// It answers `tools/list`, and it has no tools, so a carried `tools/call`
/// is a tool it does not have. Both answers go back inside a successful outer
/// `result`, which is the point: a provider that answered the second call
/// with an outer error would be testing the error path instead of this
/// binding.
const Provider = struct {
    state: *State,
    /// Separate from the connection's handler scratch, which `jsonrpc.decode`
    /// has already taken by the time the carried envelope is decoded.
    envelope_scratch: [1024]u8 = undefined,

    /// Runs inline on the reader task, so it answers and returns. It makes no
    /// call of its own: the reader is the only task on this side, so a call
    /// made here would wait for an answer that task cannot deliver.
    fn handle(ctx: ?*anyopaque, frame: []const u8, scratch: []u8) conn.Error!?[]const u8 {
        const self: *Provider = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(frame, scratch) catch return null;
        if (message.kind != .request) return null;
        const id = message.id orelse return null;
        const name = message.method orelse return null;
        // Another method is not this binding's, and answering it would put a
        // `mcp/message` answer on a call this provider never read.
        if (!std.mem.eql(u8, name.text, method)) return null;
        const params = switch (message.params) {
            .value => |text| text,
            else => return null,
        };
        // The carried envelope decodes off the wire, which is how the provider
        // tells `tools/list` from `tools/call`.
        const envelope = bridge.decodeEnvelope(params, &self.envelope_scratch, id) catch return null;

        const body: []const u8 = if (std.mem.eql(u8, envelope.inner_method, "tools/list"))
            "{\"result\":{\"tools\":[{\"name\":\"echo\"}]}}"
        else
            "{\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}";

        // The scratch is this connection's handler buffer, so the answer can
        // borrow it for the length of the write.
        var writer = json.Writer.init(scratch);
        jsonrpc.encode(.{ .kind = .response, .id = id, .result = body }, &writer) catch return null;
        self.state.answered += 1;
        return writer.written();
    }
};

/// Accepts the one connection and leaves its reader to the group, so this
/// task has nothing left to do.
const ProviderTask = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    provider: *Provider,

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch return;
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = self.provider,
            .call = Provider.handle,
        });
    }
};

/// Carries two MCP calls and classifies both answers.
const Caller = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    state: *State,

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch {
            self.state.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null);
        self.exchange() catch {
            self.state.failed = true;
        };
        // Hangs up last, so the exchange is over before the peer's reader
        // sees end of file.
        self.endpoint.hangUp(self.io);
    }

    fn exchange(self: *@This()) Error!void {
        const side = &self.endpoint.side;
        var client = Client.init(&self.endpoint.connection);

        // A carried `tools/list`. The inner MCP answer is a result, so the
        // outer `result` body is a success and reads as one.
        const listed = try client.call(
            "project-tools:7a72",
            "req-1",
            "tools/list",
            null,
            &side.result,
            &side.out,
            &side.envelope,
        );
        const listed_outcome = try classifyOutcome(listed, &side.outcome_scratch);
        if (listed_outcome.inner_error != null) self.state.failed = true;
        self.state.listed_result = listed_outcome.inner_result orelse "";

        // A carried `tools/call` for a tool the provider does not have. The
        // outer call still succeeds, `call` returns the outer `result` body
        // either way, and the inner error is visible only once that body is
        // read.
        const refused = try client.call(
            "project-tools:7a72",
            "req-2",
            "tools/call",
            "{\"name\":\"missing\"}",
            &side.second_result,
            &side.out,
            &side.envelope,
        );
        const refused_outcome = try classifyOutcome(refused, &side.second_outcome_scratch);
        self.state.refused_failed = refused_outcome.failed();
        self.state.refused_has_result = refused_outcome.inner_result != null;
        self.state.refused_error = refused_outcome.inner_error orelse "";
    }
};

/// The buffers one side needs, all caller-owned, so the test cannot hide an
/// allocation behind the binding.
const Side = struct {
    frame_buffer: [4096]u8 = undefined,
    pending: [4]conn.Slot = undefined,
    decode_scratch: [1024]u8 = undefined,
    handler_scratch: [2048]u8 = undefined,
    /// The envelope `call` builds, the bytes it puts on the wire, and the
    /// answer it reads back.
    envelope: [1024]u8 = undefined,
    out: [1024]u8 = undefined,
    result: [1024]u8 = undefined,
    outcome_scratch: [1024]u8 = undefined,
    /// The second call gets its own answer buffers. An outcome borrows the
    /// body it was read from, so one shared result buffer would leave the
    /// first answer pointing at bytes the second call overwrote.
    second_result: [1024]u8 = undefined,
    second_outcome_scratch: [1024]u8 = undefined,
};

/// One end of the connection: the buffers, and the connection over them.
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
        // Spawned on the group the test joins, because `Io.Group.async` does
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
