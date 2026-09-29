//! The MCP session: a client and a server on top of [`conn.Conn`].
//!
//! The connection knows JSON-RPC. This knows MCP, and the difference is almost
//! entirely about revision. PROTOCOLS.md 4.8 states that at `2026-07-28` there
//! is no handshake and capabilities ride per request in `_meta`, while at
//! `2025-11-25` they travel in `initialize`. Those two shapes are not
//! symmetric, which is why a session is pinned to one revision rather than
//! carrying a flag and branching at every call.
//!
//! ## What a session adds over the connection
//!
//! - A method is checked against the pinned revision *before* it goes on the
//!   wire, so a caller that asks for a method removed at `2026-07-28` learns so
//!   immediately instead of after a round trip to a peer that may or may not
//!   have removed it.
//! - At the current revision every request carries the client capabilities in
//!   `_meta`, because there is no `initialize` to carry them in.
//! - A result is classified as complete or `input_required` before the caller
//!   sees it, so an interim result is never mistaken for a final one.
//!
//! ## Allocating
//!
//! `ARCHITECTURE.md` section 4 lets this layer allocate where state is
//! genuinely dynamic. Here it does not need to: every buffer is the caller's.

const std = @import("std");
const conn = @import("conn.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const mcp = @import("mcp.zig");
const root = @import("root.zig");

pub const Error = error{
    /// The method is not part of the pinned revision, so it was not sent.
    ///
    /// Reported before the wire rather than as a peer's `-32601`, because the
    /// caller can fix it without a round trip and a peer on another revision
    /// may well still accept it.
    MethodNotInRevision,
    /// The body a peer returned is not a result this layer can read.
    NotAResult,
    /// The result was `input_required` and the caller supplied no answer.
    InputRequiredUnexpected,
    /// The result carried a `resultType` this library does not define.
    UnknownResultType,
    /// A caller-supplied buffer was too small.
    BufferTooSmall,
} || conn.Error;

/// The `_meta` key that carries the client capabilities at `2026-07-28`.
pub const client_capabilities_key = "io.modelcontextprotocol/clientCapabilities";

/// A client bound to one revision.
pub const Client = struct {
    connection: *conn.Conn,
    revision: mcp.Revision,
    /// The capabilities object sent in `_meta` at the current revision, or
    /// null to send none. Borrowed; never copied.
    capabilities: ?[]const u8 = null,

    pub fn init(connection: *conn.Conn, revision: mcp.Revision) Client {
        return .{ .connection = connection, .revision = revision };
    }

    /// The revision string for the wire.
    pub fn versionString(self: Client) []const u8 {
        return self.revision.string();
    }

    /// Send `method` and return the raw `result` member.
    ///
    /// `params` is the caller's own JSON object, or null. When this session
    /// has to add the `_meta` wrapper it builds one into `params_out` and sends
    /// that, leaving the caller's buffer untouched.
    pub fn request(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
        params_out: []u8,
    ) Error![]const u8 {
        // Checked before the wire, so a removed method is refused locally.
        _ = mcp.lookupMethod(self.revision, method) catch return error.MethodNotInRevision;

        const payload = if (self.capabilities) |caps| blk: {
            // At the previous revision the capabilities travel in `initialize`,
            // so wrapping every request would be sending something the peer
            // never asked for.
            if (self.revision != .current) break :blk params;
            if (params) |text| {
                break :blk injectMeta(text, caps, params_out) catch
                    return error.BufferTooSmall;
            } else {
                break :blk emptyParamsWithMeta(caps, params_out) catch
                    return error.BufferTooSmall;
            }
        } else params;

        const answer = try self.connection.call(method, payload, result, out);
        // A peer-reported failure carries its own body; returning it lets the
        // caller read the message, and `error_code` says which it is.
        return answer.body;
    }

    /// Classify a result body without consuming it.
    ///
    /// A result from a peer on an earlier revision omits `resultType`, and the
    /// specification requires that to be treated as `complete`.
    pub fn classify(body: []const u8, scratch: []u8) Error!mcp.ResultType {
        return mcp.decodeResultType(body, scratch) catch |err| switch (err) {
            error.BufferTooSmall => error.BufferTooSmall,
            else => error.NotAResult,
        };
    }

    /// Run one multi-round-trip exchange to completion.
    ///
    /// Sends `method`; while the answer is `input_required`, builds the retry
    /// from `answer_interim` and sends it under a *new* id, which the
    /// specification requires and the connection guarantees.
    ///
    /// The caller drives this rather than the library looping, because
    /// answering `input_required` needs input this layer has no business
    /// inventing.
    pub fn respond(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
        params_out: []u8,
        answer_interim: ?[]const u8,
    ) Error![]const u8 {
        const first = try self.request(method, params, result, out, params_out);
        const kind = try Client.classify(first, params_out);
        if (kind.isComplete()) return first;

        const known = kind.known() orelse return error.UnknownResultType;
        if (known != .input_required) return error.InputRequiredUnexpected;
        const responses = answer_interim orelse return error.InputRequiredUnexpected;
        return self.request(method, responses, result, out, params_out);
    }
};

/// A server bound to one revision.
pub const Server = struct {
    connection: *conn.Conn,
    revision: mcp.Revision,

    pub fn init(connection: *conn.Conn, revision: mcp.Revision) Server {
        return .{ .connection = connection, .revision = revision };
    }

    /// Whether a method is part of the current core inventory.
    ///
    /// The dispatcher uses this so a peer asking for a removed method gets the
    /// specification's method-not-found rather than a handler that guesses.
    pub fn accepts(self: Server, method: []const u8) bool {
        _ = mcp.lookupMethod(self.revision, method) catch return false;
        return true;
    }
};

/// Add `_meta` to a params object, keeping the caller's members.
fn injectMeta(
    params: []const u8,
    caps: []const u8,
    out: []u8,
) root.EncodeError![]const u8 {
    // The wrapper goes in front of the caller's own members. Parsing and
    // re-emitting the object would need a decode the caller has already done,
    // and splicing keeps the caller's bytes exactly as written.
    if (params.len < 2) return error.BufferTooSmall;
    if (params[0] != '{' or params[params.len - 1] != '}') return error.BufferTooSmall;
    const body = params[1 .. params.len - 1];

    var writer = json.Writer.init(out);
    try writer.slice("{\"_meta\":{\"");
    try writer.slice(client_capabilities_key);
    try writer.slice("\":");
    try writer.slice(caps);
    // Close `_meta` before the caller's members, or they land inside the
    // capabilities object instead of beside it.
    try writer.byte('}');
    if (body.len != 0) {
        // The object has members of its own, so its first needs the comma that
        // separates it from `_meta`.
        try writer.byte(',');
        try writer.slice(body);
    }
    try writer.byte('}');
    return writer.written();
}

/// The params object for a call with none of its own that still needs `_meta`.
fn emptyParamsWithMeta(caps: []const u8, out: []u8) root.EncodeError![]const u8 {
    var writer = json.Writer.init(out);
    try writer.slice("{\"_meta\":{\"");
    try writer.slice(client_capabilities_key);
    try writer.slice("\":");
    try writer.slice(caps);
    try writer.slice("}}");
    return writer.written();
}

/// The error body a server returns for a method it does not have.
pub fn methodNotFound(id: jsonrpc.Id, out: []u8) root.EncodeError![]const u8 {
    var writer = json.Writer.init(out);
    try writer.slice("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, &writer);
    try writer.slice(",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    return writer.written();
}

fn writeId(id: jsonrpc.Id, writer: *json.Writer) root.EncodeError!void {
    switch (id) {
        .integer => |value| {
            var buffer: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch
                return error.BufferTooSmall;
            try writer.slice(text);
        },
        .string => |text| try writer.string(text),
    }
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test "the current revision wraps params in _meta and keeps the caller's members" {
    var out: [256]u8 = undefined;
    const params = try injectMeta("{\"name\":\"echo\"}", "{\"tools\":{}}", &out);
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"tools\":{}}},\"name\":\"echo\"}",
        params,
    );
}

test "a call with no params still carries _meta" {
    var out: [256]u8 = undefined;
    const params = try emptyParamsWithMeta("{\"tools\":{}}", &out);
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"tools\":{}}}}",
        params,
    );
}

test "params that are not an object are refused rather than mangled" {
    var out: [256]u8 = undefined;
    // Splicing assumes an object. A caller that passed an array would
    // otherwise get a silent rewrite into something the peer never sent.
    try testing.expectError(error.BufferTooSmall, injectMeta("[1,2]", "{}", &out));
    try testing.expectError(error.BufferTooSmall, injectMeta("nope", "{}", &out));
    try testing.expectError(error.BufferTooSmall, injectMeta("", "{}", &out));
}

test "classify treats an absent resultType as complete, as the spec requires" {
    var scratch: [128]u8 = undefined;
    const complete = try Client.classify("{\"content\":[]}", &scratch);
    try testing.expect(complete.isComplete());

    const interim = try Client.classify("{\"resultType\":\"input_required\"}", &scratch);
    try testing.expect(!interim.isComplete());
    try testing.expectEqual(mcp.KnownResultType.input_required, interim.known().?);

    // A value the specification does not define is not guessed at, and not
    // quietly treated as the safe-to-assume case.
    const unknown = try Client.classify("{\"resultType\":\"weird\"}", &scratch);
    try testing.expect(!unknown.isComplete());
    try testing.expect(unknown.known() == null);
}

test "a body that is not a result is reported, not classified" {
    var scratch: [128]u8 = undefined;
    try testing.expectError(error.NotAResult, Client.classify("[1,2]", &scratch));
    try testing.expectError(error.NotAResult, Client.classify("\"a string\"", &scratch));
}

test "method-not-found is a well-formed JSON-RPC error" {
    var out: [128]u8 = undefined;
    const body = try methodNotFound(.{ .integer = 7 }, &out);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        body,
    );
}
