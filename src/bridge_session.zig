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

pub const Error = error{
    /// The binding carries MCP `2026-07-28` only, and the caller pinned a
    /// session to something else.
    UnsupportedMcpRevision,
    /// The outer response carried neither an inner result nor an inner error.
    NoInnerOutcome,
    /// A caller-supplied buffer was too small.
    BufferTooSmall,
} || conn.Error;

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
    /// An inner MCP error is returned as `error.InnerFailure` with the error
    /// body in `inner`, not as a connection error, because the outer call
    /// *succeeded*. See `Outcome` for how to read both without guessing.
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
