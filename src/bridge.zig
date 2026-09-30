//! The `mcp-over-acp` binding, the one defined composition between the three
//! protocols this library implements.
//!
//! PROTOCOLS.md section 7. It carries stateless MCP `2026-07-28` requests over
//! an existing ACP connection. The draft is cheap to represent once both
//! protocols exist, which they now do in [`mcp`] and [`acp`].
//!
//! ## The rule that makes this safe to model
//!
//! An inner MCP error is a *successful* outer ACP response. A proxy that
//! conflated the two would treat a tool failure as a transport failure and
//! retry it, or treat a transport failure as a tool failure and report it to
//! the user as a bad answer. The two error-code spaces are disjoint in meaning
//! and not disjoint in number: `-32602` is both a binding-level
//! `invalid_request` and the standard JSON-RPC `invalid params` an MCP server
//! returns inside a `tool` error. So [`isBindingFailure`] takes the level the
//! code was read at, which is what keeps an inner `-32000` from triggering ACP
//! authentication, and [`Outcome`] keeps the inner error inside a successful
//! outer response rather than flattening it.
//!
//! The binding supports MCP `2026-07-28` only. It does not emulate earlier
//! revisions and performs no MCP handshake, so [`supported_revision`] is a
//! constant rather than a parameter.

const std = @import("std");
const root = @import("root.zig");
const json = @import("json.zig");
const mcp = @import("mcp.zig");
const acp = @import("acp.zig");
const jsonrpc = @import("jsonrpc.zig");

const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

/// The single method the binding defines, in both directions.
pub const method = "mcp/message";

/// The MCP revision the binding carries, and the only one it carries.
pub const supported_revision = mcp.latest_protocol_version;

/// Which direction a `mcp/message` travels.
pub const Direction = enum {
    /// Agent to provider. A request, so the outer ACP message has an `id`.
    agent_to_provider,
    /// Provider to agent. A notification, so the outer ACP message has no `id`.
    provider_to_agent,
};

/// The `mcp/message` envelope parameters.
pub const Envelope = struct {
    /// Names a server declared by its provider.
    ///
    /// It is not an MCP session, and it must not be rebound to a different
    /// server between the request and its notification.
    server_id: []const u8,
    /// Caller-generated, opaque, one per logical MCP request.
    ///
    /// A duplicate active `(serverId, requestId)` pair is a binding failure, so
    /// a caller must not reuse one while the first is still outstanding.
    request_id: []const u8,
    /// The inner MCP method this request invokes.
    inner_method: []const u8,
    /// The inner MCP params, as borrowed JSON text. Absent means absent.
    inner_params: ?[]const u8 = null,
    /// Which way this envelope is travelling.
    ///
    /// Derived from the outer ACP `id`, which the params object excludes, so a
    /// caller reading the params bytes alone cannot determine it.
    direction: Direction,
};

/// Decode a `mcp/message` params object.
///
/// The outer `id` is deliberately not a field: it is the ACP request id of one
/// hop, and a proxy is permitted to renumber it. Keying the logical request on
/// `(serverId, requestId)` rather than on the outer id is what lets a proxy
/// renumber safely.
///
/// It is taken as an argument anyway, because the params object alone cannot
/// say which way the envelope travelled. The binding defines one direction per
/// shape: the agent-to-provider message is a request and carries an outer `id`,
/// and the provider-to-agent message is a notification and does not. Deriving
/// the direction inside the decoder instead would report a request for every
/// envelope, including the notifications.
pub fn decodeEnvelope(
    raw: []const u8,
    scratch: []u8,
    outer_id: ?jsonrpc.Id,
) DecodeError!Envelope {
    var reader = json.Reader.init(raw);
    var envelope: Envelope = .{
        .server_id = "",
        .request_id = "",
        .inner_method = "",
        .direction = if (outer_id == null) .provider_to_agent else .agent_to_provider,
    };

    var saw_server = false;
    var saw_request = false;
    var saw_method = false;
    // A request carries an inner method; a notification carries the MCP
    // notification belonging to the operation, which also has a method.

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "serverId")) {
            envelope.server_id = try reader.string(scratch);
            saw_server = true;
        } else if (std.mem.eql(u8, key, "requestId")) {
            envelope.request_id = try reader.string(scratch);
            saw_request = true;
        } else if (std.mem.eql(u8, key, "method")) {
            envelope.inner_method = try reader.string(scratch);
            saw_method = true;
        } else if (std.mem.eql(u8, key, "params")) {
            envelope.inner_params = try reader.rawValue(scratch);
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!saw_server or !saw_request or !saw_method) return error.MissingField;
    // `encodeEnvelope` refuses an empty member, so the decoder refuses one
    // too. Without the check a proxy that decodes a forwarded envelope and
    // re-encodes it cannot emit a byte for an envelope the decoder accepted.
    if (envelope.server_id.len == 0) return error.InvalidField;
    if (envelope.request_id.len == 0) return error.InvalidField;
    if (envelope.inner_method.len == 0) return error.InvalidField;
    return envelope;
}

/// Encode a `mcp/message` params object.
pub fn encodeEnvelope(envelope: Envelope, writer: *json.Writer) EncodeError!void {
    if (envelope.server_id.len == 0) return error.InvalidField;
    if (envelope.request_id.len == 0) return error.InvalidField;
    if (envelope.inner_method.len == 0) return error.InvalidField;

    try writer.slice("{\"serverId\":");
    try writer.string(envelope.server_id);
    try writer.slice(",\"requestId\":");
    try writer.string(envelope.request_id);
    try writer.slice(",\"method\":");
    try writer.string(envelope.inner_method);
    if (envelope.inner_params) |params| {
        try writer.slice(",\"params\":");
        try writer.slice(params);
    }
    try writer.byte('}');
}

/// The inner MCP outcome carried by a successful outer response.
///
/// Exactly one of `result` or `error` is present. An inner error is still a
/// successful outer response, which is why this is a union rather than a flag.
pub const Outcome = union(enum) {
    result: []const u8,
    /// The inner MCP error object, as borrowed JSON text. Quoted because
    /// `error` is a Zig keyword.
    @"error": []const u8,
};

/// Decode the inner outcome of a successful outer response.
pub fn decodeOutcome(raw: []const u8, scratch: []u8) DecodeError!Outcome {
    var reader = json.Reader.init(raw);
    var outcome: ?Outcome = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "result")) {
            if (outcome != null) return error.InvalidField;
            // Deliberately not checked. A result carries whatever the MCP
            // operation returned, and an explicit `null` is a result.
            outcome = .{ .result = try reader.rawValue(scratch) };
        } else if (std.mem.eql(u8, key, "error")) {
            if (outcome != null) return error.InvalidField;
            // The lexeme is taken around the check rather than by `rawValue`,
            // which consumes the value before anything can look at it.
            reader.skipWhitespace();
            const start = reader.pos;
            try checkInnerError(&reader, scratch);
            outcome = .{ .@"error" = reader.input[start..reader.pos] };
        } else {
            try reader.skipValue(scratch);
        }
    }

    // Exactly one inner MCP outcome, per the specification.
    return outcome orelse error.MissingField;
}

/// Check the shape of the inner MCP `error` object, leaving the reader after
/// it.
///
/// The inner error is a non-null object with a required integer `code` and a
/// required string `message`. Carrying the bytes without checking would hand
/// the caller `null`, `{}` or `"boom"` labelled as an error object, with no
/// code to report and no message to show. `result` is deliberately not checked
/// the same way, because it carries any JSON value.
fn checkInnerError(reader: *json.Reader, scratch: []u8) DecodeError!void {
    // `null`, a string, an array, a number, a boolean: none is the error
    // object, and a caller cannot tell which of them it was handed.
    if (reader.peek() != '{') return error.InvalidField;
    if (try reader.beginObject()) return error.MissingField;

    var saw_code = false;
    var saw_message = false;
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "code")) {
            // A JSON-RPC code is an integer: not a quoted number, and not a
            // fraction, so `-32602.0` is not the code the binding allocates.
            reader.skipWhitespace();
            const byte = reader.peek() orelse return error.Truncated;
            if (byte != '-' and (byte < '0' or byte > '9')) return error.InvalidField;
            for (try reader.number()) |char| {
                switch (char) {
                    '-', '0'...'9' => {},
                    else => return error.InvalidField,
                }
            }
            saw_code = true;
        } else if (std.mem.eql(u8, key, "message")) {
            reader.skipWhitespace();
            if ((reader.peek() orelse return error.Truncated) != '"') {
                return error.InvalidField;
            }
            _ = try reader.string(scratch);
            saw_message = true;
        } else {
            try reader.skipValue(scratch);
        }
    }
    if (!saw_code) return error.MissingField;
    if (!saw_message) return error.MissingField;
}

/// Encode the inner MCP outcome of a successful outer response.
///
/// The payload is borrowed JSON text, and it is spliced verbatim, exactly as
/// [`jsonrpc.encode`] splices a `result`. A codec does not re-serialise a value
/// it did not produce, and the payload came from [`decodeOutcome`], which has
/// already checked it against the shape its arm requires. So a payload the
/// `result` arm takes as any JSON value at all, a bare string or a number or
/// `null`, is written as it stands. Checking it here instead would make the
/// encoder refuse bytes its own decoder accepted.
///
/// A raw newline inside the payload is written as it stands too. The framer
/// refuses such a frame on its way to the wire, because a message carrying one
/// has already broken the framing.
pub fn encodeOutcome(outcome: Outcome, writer: *json.Writer) EncodeError!void {
    switch (outcome) {
        .result => |text| {
            try writer.slice("{\"result\":");
            try writer.slice(text);
        },
        .@"error" => |text| {
            try writer.slice("{\"error\":");
            try writer.slice(text);
        },
    }
    try writer.byte('}');
}

/// The binding-level failures, which are *outer* ACP errors.
///
/// These are distinct from an inner MCP error. A caller that cannot tell them
/// apart will retry a tool failure as though it were a transport failure.
pub const BindingError = enum(i32) {
    /// Malformed envelope, or a duplicate active `(serverId, requestId)`.
    invalid_request = -32602,
    /// The ACP operation was cancelled.
    operation_cancelled = -32800,
    /// A binding resource limit was exceeded.
    resource_limit_exceeded = -33000,
    /// The named server is not registered with the provider.
    server_registration_unavailable = -33001,
    /// The backend or transport failed without producing a valid MCP outcome.
    backend_failed = -33002,

    pub fn fromCode(code: i32) ?BindingError {
        return switch (code) {
            -32602 => .invalid_request,
            -32800 => .operation_cancelled,
            -33000 => .resource_limit_exceeded,
            -33001 => .server_registration_unavailable,
            -33002 => .backend_failed,
            else => null,
        };
    }
};

/// Which error space a code was read from.
///
/// The two spaces are disjoint in meaning and overlap in number, so a code on
/// its own cannot be classified. `-32602` is this binding's outer
/// `invalid_request` *and* the standard JSON-RPC `invalid params` an MCP
/// server returns inside a `tool` error. Only the level tells them apart.
pub const ErrorLevel = enum {
    /// Inside a successful outer response, in its `result` member.
    inner,
    /// On the outer ACP message itself, which failed.
    outer,
};

/// Whether `code`, read at `level`, is a binding failure.
///
/// The level is an argument rather than a comment because the two spaces are
/// disjoint in meaning while sharing a number, and the mistake this module
/// exists to prevent is exactly the one a bare integer invites: treating an
/// inner tool failure as a transport failure and retrying it. The binding also
/// deliberately allocates outside both MCP code ranges, the
/// implementation-defined `-32000` to `-32019` and the `-32020` to `-32099`
/// the specification reserves for itself, so an inner code in either range
/// can never be mistaken for a binding failure at any level.
pub fn isBindingFailure(code: i32, level: ErrorLevel) bool {
    if (level == .inner) return false;
    return BindingError.fromCode(code) != null;
}

/// The capability a peer advertises to accept `mcp/message`.
///
/// The `acp` key is in no published schema in either version. A v1 peer
/// advertises it as a boolean, a v2 peer as a presence object, and v2 removes
/// the boolean form entirely.
pub const capability_path = struct {
    pub const v1 = "mcpCapabilities.acp";
    pub const v2 = "capabilities.session.mcp.acp";
};

/// The server declaration the RFD example uses.
pub const server_declaration = struct {
    /// The `type` discriminator, named `kind` because `type` is a Zig keyword.
    pub const kind = "acp";
    pub const name = "project-tools";
    pub const server_id = "project-tools:7a72";
};

const testing = std.testing;

test "the binding carries only the current MCP revision" {
    try testing.expectEqualStrings("2026-07-28", supported_revision);
    // It does not emulate the earlier revision, and does not do a handshake.
    try testing.expect(!std.mem.eql(u8, supported_revision, mcp.previous_protocol_version));
}

test "the normative worked example decodes" {
    var scratch: [256]u8 = undefined;
    // The worked example from the RFD, verbatim.
    const raw =
        \\{"serverId":"project-tools:7a72","requestId":"mcp-request:a11f"
        \\,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}
    ;
    const envelope = try decodeEnvelope(raw, &scratch, .{ .integer = 7 });
    try testing.expectEqualStrings("project-tools:7a72", envelope.server_id);
    try testing.expectEqualStrings("mcp-request:a11f", envelope.request_id);
    try testing.expectEqualStrings("tools/call", envelope.inner_method);
    try testing.expect(envelope.inner_params != null);
}

test "an envelope missing any required member is MissingField" {
    var scratch: [128]u8 = undefined;
    try testing.expectError(error.MissingField, decodeEnvelope(
        \\{"requestId":"r","method":"tools/call"}
    , &scratch, null));
    try testing.expectError(error.MissingField, decodeEnvelope(
        \\{"serverId":"s","method":"tools/call"}
    , &scratch, null));
    try testing.expectError(error.MissingField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r"}
    , &scratch, null));
    // An empty identifier is present but not usable.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"","requestId":"r","method":"tools/call"}
    , &scratch, null));
}

test "decode and encode refuse an empty inner method alike" {
    var scratch: [128]u8 = undefined;
    // An empty method names no operation. Without the decode-side check the
    // decoder hands a proxy an envelope it cannot re-encode, so the
    // `encode(decode(b))` identity fails for bytes the decoder accepted.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":""}
    , &scratch, null));

    // The encoder answers the same envelope with the same error, so both
    // directions agree on which envelopes are usable.
    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encodeEnvelope(.{
        .server_id = "s",
        .request_id = "r",
        .inner_method = "",
        .direction = .agent_to_provider,
    }, &writer));
    // The encoder validates before it writes, so nothing reached the buffer.
    try testing.expectEqual(@as(usize, 0), writer.len);
}

test "an envelope with no inner params is valid" {
    var scratch: [128]u8 = undefined;
    const envelope = try decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"subscriptions/listen"}
    , &scratch, null);
    try testing.expectEqual(@as(?[]const u8, null), envelope.inner_params);
}

test "an envelope round-trips through the encoder" {
    var scratch: [256]u8 = undefined;
    const raw =
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":{"name":"echo"}}
    ;
    const envelope = try decodeEnvelope(raw, &scratch, .{ .integer = 7 });

    var buffer: [256]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeEnvelope(envelope, &writer);
    try testing.expectEqualStrings(raw, writer.written());
}

test "the outer id is what tells a request from a notification" {
    var scratch: [256]u8 = undefined;
    const raw =
        \\{"serverId":"s","requestId":"r","method":"tools/call"}
    ;
    // The params object is byte-identical in both directions. What differs is
    // the outer ACP message, and a request carries an `id` while a
    // notification does not, so the decoder reads the direction from the id
    // the caller already has rather than asserting a request for everything.
    const request = try decodeEnvelope(raw, &scratch, .{ .integer = 7 });
    try testing.expect(request.direction == .agent_to_provider);

    const notification = try decodeEnvelope(raw, &scratch, null);
    try testing.expect(notification.direction == .provider_to_agent);

    // A string id is still an id. PROTOCOLS.md 6.1 leaves the id opaque.
    const string_id = try decodeEnvelope(raw, &scratch, .{ .string = "hop-1" });
    try testing.expect(string_id.direction == .agent_to_provider);

    // The direction is not a member of the params object, so the same bytes
    // come back out of the encoder either way.
    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeEnvelope(notification, &writer);
    try testing.expectEqualStrings(raw, writer.written());
}

test "an inner MCP error is an outcome, not a binding failure" {
    var scratch: [128]u8 = undefined;
    // Exactly one of result or error, and the error is an outcome of a
    // successful outer response.
    const failure = try decodeOutcome(
        \\{"error":{"code":-32602,"message":"unknown tool"}}
    , &scratch);
    try testing.expect(failure == .@"error");

    const success = try decodeOutcome(
        \\{"result":{"resultType":"complete"}}
    , &scratch);
    try testing.expect(success == .result);
}

test "an outcome with both or neither member is a decode error" {
    var scratch: [128]u8 = undefined;
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"result":{},"error":{"code":-1,"message":"m"}}
    , &scratch));
    try testing.expectError(error.MissingField, decodeOutcome(
        \\{}
    , &scratch));
}

test "the inner and outer error spaces are disjoint" {
    // Binding failures, read on the outer message.
    try testing.expect(isBindingFailure(-32602, .outer));
    try testing.expect(isBindingFailure(-32800, .outer));
    try testing.expect(isBindingFailure(-33000, .outer));
    try testing.expect(isBindingFailure(-33001, .outer));
    try testing.expect(isBindingFailure(-33002, .outer));

    // The -32602 collision is deliberate and stated: the JSON-RPC standard
    // "invalid params" code is reused for a malformed binding envelope. It is
    // an *outer* code here, which is exactly why the level is an argument
    // rather than a comment on the number.
    try testing.expectEqual(BindingError.invalid_request, BindingError.fromCode(-32602).?);

    // A code that is not a binding code is not one at the outer level either,
    // and an inner MCP code in the implementation-defined range is never one,
    // so it can never trigger a transport-level reaction.
    try testing.expect(!isBindingFailure(-32000, .outer));
    try testing.expect(!isBindingFailure(-32020, .outer));
    try testing.expect(!isBindingFailure(-32001, .outer));
    try testing.expect(!isBindingFailure(0, .outer));
}

test "an inner -32602 is an MCP failure, never a binding failure" {
    // -32602 is both the standard "invalid params" an MCP server returns
    // inside a `tool` error and this binding's own outer `invalid_request`.
    // The level, not the number, is what tells them apart, so a caller that
    // passes the level cannot read a tool failure as a transport failure.
    try testing.expect(!isBindingFailure(-32602, .inner));
    try testing.expect(isBindingFailure(-32602, .outer));

    // No inner code is a binding failure, whatever its value, so the inner
    // path cannot be driven into a transport-level reaction by any number.
    for ([_]i32{ -32602, -32601, -32800, -33002, -32000, -32001, -32020, 0, 1 }) |code| {
        try testing.expect(!isBindingFailure(code, .inner));
    }
}

test "an inner error must be a non-null object with a code and a message" {
    var scratch: [256]u8 = undefined;
    // `null` is a valid MCP result and not a valid error object.
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":null}
    , &scratch));
    try testing.expectError(error.MissingField, decodeOutcome(
        \\{"error":{}}
    , &scratch));
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":"boom"}
    , &scratch));
    try testing.expectError(error.MissingField, decodeOutcome(
        \\{"error":{"code":-32602}}
    , &scratch));
    try testing.expectError(error.MissingField, decodeOutcome(
        \\{"error":{"message":"boom"}}
    , &scratch));
    // A code is an integer, and a message is a string.
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":{"code":"-32602","message":"boom"}}
    , &scratch));
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":{"code":-32602.5,"message":"boom"}}
    , &scratch));
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":{"code":-32602,"message":7}}
    , &scratch));

    // A well-formed error object is carried verbatim, data member and all.
    const failure = try decodeOutcome(
        \\{"error":{"code":-32602,"message":"unknown tool","data":{"name":"echo"}}}
    , &scratch);
    try testing.expect(failure == .@"error");
    try testing.expectEqualStrings(
        "{\"code\":-32602,\"message\":\"unknown tool\",\"data\":{\"name\":\"echo\"}}",
        failure.@"error",
    );
}

test "a result is any JSON value, an explicit null included" {
    var scratch: [256]u8 = undefined;
    // Deliberately not checked like the error arm: a result carries whatever
    // the MCP operation returned, and `null` is a value it may return.
    const nulled = try decodeOutcome(
        \\{"result":null}
    , &scratch);
    try testing.expect(nulled == .result);
    try testing.expectEqualStrings("null", nulled.result);

    const empty = try decodeOutcome(
        \\{"result":{}}
    , &scratch);
    try testing.expectEqualStrings("{}", empty.result);
}

test "the result arm round-trips through the encoder" {
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;

    const raw = "{\"result\":{\"resultType\":\"complete\"}}";
    const outcome = try decodeOutcome(raw, &scratch);
    try testing.expect(outcome == .result);

    var writer = json.Writer.init(&buffer);
    try encodeOutcome(outcome, &writer);
    // Byte-identical, so the payload is spliced and not rebuilt from a value
    // this codec never parsed.
    try testing.expectEqualStrings(raw, writer.written());

    const again = try decodeOutcome(writer.written(), &scratch);
    try testing.expect(again == .result);
    try testing.expectEqualStrings(outcome.result, again.result);

    // Every one of these is a result `decodeOutcome` accepted, so every one
    // is written as it stands. A bare string, a number and `null` are results
    // the MCP operation may return, not input the encoder second-guesses.
    const cases = [_]struct { payload: []const u8, framed: []const u8 }{
        .{ .payload = "null", .framed = "{\"result\":null}" },
        .{ .payload = "42", .framed = "{\"result\":42}" },
        .{ .payload = "\"text\"", .framed = "{\"result\":\"text\"}" },
        .{ .payload = "[1,2]", .framed = "{\"result\":[1,2]}" },
    };
    for (cases) |case| {
        var each_buffer: [64]u8 = undefined;
        var each = json.Writer.init(&each_buffer);
        try encodeOutcome(.{ .result = case.payload }, &each);
        try testing.expectEqualStrings(case.framed, each.written());
    }
}

test "the error arm round-trips through the encoder" {
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;

    const raw = "{\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}";
    const outcome = try decodeOutcome(raw, &scratch);
    try testing.expect(outcome == .@"error");

    var writer = json.Writer.init(&buffer);
    try encodeOutcome(outcome, &writer);
    // The member the union names, and the payload under it verbatim, so a
    // rejection cannot reach the peer wearing the name of a success.
    try testing.expectEqualStrings(raw, writer.written());

    const again = try decodeOutcome(writer.written(), &scratch);
    try testing.expect(again == .@"error");
    try testing.expectEqualStrings(outcome.@"error", again.@"error");
}

test "an outcome round-trips through a whole outer response" {
    var scratch: [256]u8 = undefined;
    var inner_buffer: [256]u8 = undefined;
    var outer_buffer: [512]u8 = undefined;
    var inner = json.Writer.init(&inner_buffer);
    var outer = json.Writer.init(&outer_buffer);

    // An inner MCP error rides inside the outer `result`, because the MCP
    // call failed and the exchange did not. The outer `error` member would
    // tell the client the transport failed, and it would retry a tool failure.
    try encodeOutcome(.{
        .@"error" = "{\"code\":-32602,\"message\":\"unknown tool\"}",
    }, &inner);
    try jsonrpc.encode(.{
        .kind = .response,
        .id = .{ .integer = 7 },
        .result = inner.written(),
    }, &outer);

    const wire =
        \\{"jsonrpc":"2.0","id":7,"result":{"error":{"code":-32602,"message":"unknown tool"}}}
    ;
    try testing.expectEqualStrings(wire, outer.written());

    // What the peer reads back: a successful outer response whose result
    // carries the inner error, and no outer error at all.
    const message = try jsonrpc.decode(outer.written(), &scratch);
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    try testing.expect(message.rpc_error == null);

    const back = try decodeOutcome(message.result.?, &scratch);
    try testing.expect(back == .@"error");
    try testing.expectEqualStrings(
        "{\"code\":-32602,\"message\":\"unknown tool\"}",
        back.@"error",
    );
}

test "the binding allocates no code inside either MCP code range" {
    // An inner MCP code in the implementation-defined range, or in the range
    // the specification reserves for itself, means an inner failure. A
    // binding code in either would make the two spaces ambiguous, so all
    // five binding codes have to fall outside both.
    const codes = [_]i32{
        @intFromEnum(BindingError.invalid_request),
        @intFromEnum(BindingError.operation_cancelled),
        @intFromEnum(BindingError.resource_limit_exceeded),
        @intFromEnum(BindingError.server_registration_unavailable),
        @intFromEnum(BindingError.backend_failed),
    };
    for (codes) |code| {
        const in_legacy = code >= mcp.legacy_error_min and code <= mcp.legacy_error_max;
        const in_reserved = code >= mcp.reserved_error_min and code <= mcp.reserved_error_max;
        try testing.expect(!in_legacy);
        try testing.expect(!in_reserved);
    }
}

test "the capability path differs by version, and uses each version's form" {
    try testing.expectEqualStrings("mcpCapabilities.acp", capability_path.v1);
    try testing.expectEqualStrings("capabilities.session.mcp.acp", capability_path.v2);
    // v1 advertises it as a boolean; v2 has removed the boolean form.
    try testing.expectEqual(acp.CapabilityForm.boolean, acp.v1CapabilityForm("mcpCapabilities.acp"));
    try testing.expectEqual(acp.CapabilityForm.presence_object, acp.v2_capability_form);
}

test "the method name is the one the RFD states" {
    try testing.expectEqualStrings("mcp/message", method);
    // It is not an ACP core method in either version; it is a binding method.
    try testing.expectError(error.UnknownMethod, acp.lookupMethod(.stable, method));
    try testing.expectError(error.UnknownMethod, acp.lookupMethod(.draft, method));
}

test "the inner method is validated against the MCP registry" {
    // A binding cannot carry a method the MCP revision does not define.
    _ = try mcp.lookupMethod(.current, "tools/call");
    try testing.expectError(error.UnknownMethod, mcp.lookupMethod(.current, "initialize"));
    // The RFD targets 2026-07-28 only, so a method removed at that revision is
    // not available over this binding.
    try testing.expectError(error.UnknownMethod, mcp.lookupMethod(.current, "ping"));
}
