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
    /// The outer `_meta`, as borrowed JSON text, beside `serverId`.
    ///
    /// `research/normative/acp-v1-v2.md` table 10b, verbatim: "An optional
    /// outer `_meta` object alongside `serverId` is ACP envelope metadata.
    /// Omission and `null` are equivalent." PROTOCOLS.md section 7 names only
    /// `serverId`, `requestId` and the outer `id`, so that row fills a silence
    /// in the authority rather than contradicting it, and it is recorded
    /// here.
    ///
    /// This is the *envelope* `_meta`, the one beside `serverId`. It is not
    /// the inner MCP `_meta` that lives inside `params`, which
    /// [`Envelope.inner_params`] already carries.
    ///
    /// The text is spliced verbatim rather than decoded into a shape. A shape
    /// cannot round-trip a member it does not model, which is the defect this
    /// field exists to remove, so borrowing the lexeme is both the cheaper and
    /// the more faithful representation.
    meta: ?[]const u8 = null,
    /// Which way this envelope is travelling.
    ///
    /// Derived from the outer ACP `id`, which the params object excludes, so a
    /// caller reading the params bytes alone cannot determine it.
    direction: Direction,

    /// Whether this envelope carries inner MCP parameters.
    ///
    /// The same normative row types `params` as "object | `null`" and says
    /// "Omission and `null` both mean no inner parameters", so a non-null
    /// [`Envelope.inner_params`] holding the four bytes `null` is not the fact
    /// the specification means by carrying parameters. The field keeps those
    /// bytes so the envelope re-encodes to what arrived; this is where the
    /// equivalence is applied. Normalising the member away instead would
    /// trade a semantic wrinkle for a broken `encode(decode(b)) == b`.
    pub fn carriesParams(self: Envelope) bool {
        const params = self.inner_params orelse return false;
        return !std.mem.eql(u8, params, "null");
    }
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
///
/// A member this module does not model is skipped, and re-encoding an
/// envelope therefore drops it — the same stated consequence
/// [`jsonrpc.decode`] records, and it remains open for an *unrecognised*
/// member. `_meta` is the one the RFD defines, so it is carried rather than
/// skipped; the RFD names no other member of this object.
///
/// A member the input spells more than once resolves first-wins, which is the
/// rule [`json.memberText`] and [`jsonrpc.decode`] apply and the reason they
/// apply it: a later member must not be able to make a failed comparison
/// pass. So the first `serverId` is the server the envelope names, and a
/// second one appended beside it cannot repair an empty identifier or
/// redirect the call to another tenant than the one a first-wins intermediary
/// read. The repeat is stepped over rather than refused; `http` is the one
/// decoder in this library that refuses one outright, and this is not it.
///
/// The walk is ordered, so a document wrong in more than one way reports the
/// first fault the walk reaches. A `params` shape fault is detected inside
/// the member loop and is therefore reported ahead of a trailing tail, which
/// is only examined once the loop has closed. A trailing tail is in turn
/// reported ahead of the required-member and empty-member checks, which run
/// after it. [`decodeOutcome`] orders its walk the same way.
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
    var saw_params = false;
    var saw_meta = false;
    // A request carries an inner method; a notification carries the MCP
    // notification belonging to the operation, which also has a method.

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        // Each member is taken from its first occurrence and the second is
        // stepped over, for the reason the doc above gives. The guards are
        // read before the value rather than after it, so a repeat is spent by
        // `skipValue` and never overwrites what the first one decoded.
        if (std.mem.eql(u8, key, "serverId")) {
            if (saw_server) {
                try reader.skipValue(scratch);
            } else {
                envelope.server_id = try reader.string(scratch);
                saw_server = true;
            }
        } else if (std.mem.eql(u8, key, "requestId")) {
            if (saw_request) {
                try reader.skipValue(scratch);
            } else {
                envelope.request_id = try reader.string(scratch);
                saw_request = true;
            }
        } else if (std.mem.eql(u8, key, "method")) {
            if (saw_method) {
                try reader.skipValue(scratch);
            } else {
                envelope.inner_method = try reader.string(scratch);
                saw_method = true;
            }
        } else if (std.mem.eql(u8, key, "params")) {
            // `research/normative/acp-v1-v2.md` table 10b types this member
            // "object | `null`" and says "positional arrays are invalid", which
            // the same document's table 10d and PROTOCOLS.md section 7 both map
            // to the outer `-32602` of [`BindingError.invalid_request`].
            //
            // `rawValue` delegates to `skipValue`, which accepts `[`, so
            // nothing on this path distinguished an object from an array and
            // `bridge_session.Provider.serve` forwarded an envelope it is
            // required to refuse. The shape is checked before the lexeme is
            // taken; `n` is the `null` the same row allows, and `skipValue`
            // is what rejects a malformed literal under it.
            //
            // The shape is checked on a repeat too. The first occurrence is
            // the one that is carried, and a document whose second `params`
            // is an array is malformed whatever the first one said.
            reader.skipWhitespace();
            const byte = reader.peek() orelse return error.Truncated;
            if (byte != '{' and byte != 'n') return error.InvalidField;
            const value = try reader.rawValue(scratch);
            if (!saw_params) {
                envelope.inner_params = value;
                saw_params = true;
            }
        } else if (std.mem.eql(u8, key, "_meta")) {
            // Carried verbatim so `encodeEnvelope` can put it back. See
            // [`Envelope.meta`] for why it is borrowed text and not a shape.
            const value = try reader.rawValue(scratch);
            if (!saw_meta) {
                envelope.meta = value;
                saw_meta = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    // The params object is one JSON value. Bytes after the closing brace are
    // a second document the transport did not split, or a peer that disagrees
    // with it about where a frame ends, and a codec that accepted them would
    // re-encode the envelope without them — the silent truncation
    // `jsonrpc.decode` refuses for the same reason.
    if (!reader.atEnd()) return error.MalformedJson;

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
///
/// Members are written in the order table 10b lists them, so a byte sequence
/// that already reads in that order comes back unchanged and one that does not
/// comes back with the same members in it. `_meta` is written last, which is
/// where the table puts it.
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
    if (envelope.meta) |meta| {
        try writer.slice(",\"_meta\":");
        try writer.slice(meta);
    }
    try writer.byte('}');
}

/// One inner MCP outcome and the ACP metadata travelling beside it.
///
/// Both halves are borrowed JSON text and both are spliced verbatim. The
/// payload is never re-serialised because a codec does not rebuild a value it
/// did not produce, and the carrier `_meta` is carried the same way because a
/// typed shape cannot write back a member it does not model, which is the
/// defect carrying it fixes.
pub const OutcomePayload = struct {
    /// The inner MCP payload under the `result` or `error` member.
    text: []const u8,
    /// The carrier `_meta`, if the response carried one.
    ///
    /// `research/normative/acp-v1-v2.md` table 10c, verbatim: "An optional
    /// carrier `_meta` contains ACP metadata and is separate from the inner
    /// outcome's metadata." PROTOCOLS.md section 7 names only the outcome
    /// member itself, so that row fills a silence in the authority rather than
    /// contradicting it, and it is recorded here.
    meta: ?[]const u8 = null,
};

/// The inner MCP outcome carried by a successful outer response.
///
/// Exactly one of `result` or `error` is present. An inner error is still a
/// successful outer response, which is why this is a union rather than a flag.
pub const Outcome = union(enum) {
    result: OutcomePayload,
    /// The inner MCP error object. Quoted because `error` is a Zig keyword.
    @"error": OutcomePayload,
};

/// Decode the inner outcome of a successful outer response.
///
/// A member this module does not model is skipped, and re-encoding an outcome
/// therefore drops it — the same stated consequence [`jsonrpc.decode`]
/// records, and it remains open for an *unrecognised* member. The carrier
/// `_meta` is the one table 10c defines, so it is carried rather than skipped.
///
/// A member the input spells more than once resolves first-wins, as in
/// [`decodeEnvelope`] and as [`jsonrpc.decode`] applies it. A repeat is not a
/// second outcome, so `{"result":1,"result":2}` is the first result rather
/// than a document to refuse, and a carrier `_meta` appended twice carries the
/// first one. What is still refused is the *pair*: an object carrying both
/// `result` and `error` has two outcomes whichever order they arrived in, and
/// the specification allows one.
pub fn decodeOutcome(raw: []const u8, scratch: []u8) DecodeError!Outcome {
    var reader = json.Reader.init(raw);
    // The outcome member and the carrier metadata are collected apart and
    // joined after the walk. A peer may write `_meta` before or after the
    // outcome, and a payload built the moment the member is read would carry
    // whichever half arrived first and drop the other.
    var text: ?[]const u8 = null;
    var is_error = false;
    var carrier_meta: ?[]const u8 = null;
    var saw_result = false;
    var saw_error = false;
    var saw_meta = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        // Each member is taken from its first occurrence and the second is
        // stepped over, for the reason the doc above gives. The guard is read
        // before the value, so a repeat never overwrites what the first one
        // decoded.
        if (std.mem.eql(u8, key, "result")) {
            if (saw_result) {
                try reader.skipValue(scratch);
            } else {
                // The two members are mutually exclusive whichever came
                // first, so the *other* outcome beside this one is the
                // refusal. It is the pair that is illegal, not the repetition.
                if (saw_error) return error.InvalidField;
                saw_result = true;
                // Deliberately not checked. A result carries whatever the MCP
                // operation returned, and an explicit `null` is a result.
                text = try reader.rawValue(scratch);
            }
        } else if (std.mem.eql(u8, key, "error")) {
            if (saw_error) {
                try reader.skipValue(scratch);
            } else {
                // And in the other order, for the same reason.
                if (saw_result) return error.InvalidField;
                saw_error = true;
                // The lexeme is taken around the check rather than by
                // `rawValue`, which consumes the value before anything can
                // look at it.
                reader.skipWhitespace();
                const start = reader.pos;
                try checkInnerError(&reader, scratch);
                text = reader.input[start..reader.pos];
                is_error = true;
            }
        } else if (std.mem.eql(u8, key, "_meta")) {
            const value = try reader.rawValue(scratch);
            if (!saw_meta) {
                saw_meta = true;
                // Carried verbatim so `encodeOutcome` can put it back. See
                // [`OutcomePayload.meta`] for why it is borrowed text and not
                // a shape.
                carrier_meta = value;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    // The carrier is one JSON value, and the same reasoning as in
    // `decodeEnvelope`: trailing bytes are a second document the transport
    // did not split, and accepting them would re-encode an outcome without
    // them.
    if (!reader.atEnd()) return error.MalformedJson;

    // Exactly one inner MCP outcome, per the specification.
    const payload = OutcomePayload{
        .text = text orelse return error.MissingField,
        .meta = carrier_meta,
    };
    return if (is_error) .{ .@"error" = payload } else .{ .result = payload };
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
    // object, and a caller cannot tell which of them it was handed. Input
    // that ended is none of those six: PROTOCOLS.md 2.1 calls that `Truncated`,
    // and the two members below already say so, so one short read cannot be
    // `InvalidField` here and `Truncated` on the closing-brace path. A
    // consumer that separates "short read" from "bad peer" needs it named one
    // way.
    reader.skipWhitespace();
    if ((reader.peek() orelse return error.Truncated) != '{') return error.InvalidField;
    if (try reader.beginObject()) return error.MissingField;

    var saw_code = false;
    var saw_message = false;
    while (try reader.nextKey(scratch)) |key| {
        // First-wins here as in every other member walk in this library, so a
        // second `code` cannot supply the integer the first one was refused
        // for.
        if (std.mem.eql(u8, key, "code")) {
            if (saw_code) {
                try reader.skipValue(scratch);
                continue;
            }
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
            if (saw_message) {
                try reader.skipValue(scratch);
                continue;
            }
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
/// The carrier `_meta` is spliced the same way, for the same reason: it is a
/// member this module does not model, so it is written back as it arrived
/// rather than rebuilt from a shape that could not hold it.
///
/// A raw newline inside the payload is written as it stands too. The framer
/// refuses such a frame on its way to the wire, because a message carrying one
/// has already broken the framing.
pub fn encodeOutcome(outcome: Outcome, writer: *json.Writer) EncodeError!void {
    switch (outcome) {
        .result => |arm| {
            try writer.slice("{\"result\":");
            try writer.slice(arm.text);
            try writeCarrierMeta(arm.meta, writer);
        },
        .@"error" => |arm| {
            try writer.slice("{\"error\":");
            try writer.slice(arm.text);
            try writeCarrierMeta(arm.meta, writer);
        },
    }
    try writer.byte('}');
}

/// Write the optional ACP carrier `_meta` member, if there is one.
///
/// Written after the outcome member, so a response that already reads in that
/// order re-encodes to the bytes it arrived as.
fn writeCarrierMeta(meta: ?[]const u8, writer: *json.Writer) EncodeError!void {
    const text = meta orelse return;
    try writer.slice(",\"_meta\":");
    try writer.slice(text);
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

    /// The binding failure a wire code names, or null for a code this binding
    /// does not allocate.
    ///
    /// A bare code does not say which space it was read from; see
    /// [`ErrorLevel`] and [`isBindingFailure`].
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

test "envelope params must be an object or null" {
    var scratch: [128]u8 = undefined;
    // Table 10b types `params` as "object | `null`" and says "positional
    // arrays are invalid". `rawValue` delegates to `skipValue`, which accepts
    // `[`, so before the shape check `{"params":[1,2]}` decoded and
    // `bridge_session.Provider.serve` forwarded an envelope the binding is
    // required to refuse. Table 10d and PROTOCOLS.md section 7 both map a
    // malformed envelope to the outer `-32602`, which is the caller's to
    // answer; the codec's part is to refuse the bytes.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":[1,2]}
    , &scratch, null));
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":[{"name":"echo"}]}
    , &scratch, null));
    // The type is "object | null", so a scalar is no more permitted than an
    // array is.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":"echo"}
    , &scratch, null));
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":7}
    , &scratch, null));

    // An object is what the RFD worked example carries, and `null` is the
    // other half of the type, so both still decode.
    const object = try decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":{"name":"echo"}}
    , &scratch, null);
    try testing.expect(object.carriesParams());

    // Input that ended is a short read, not a wrong type.
    try testing.expectError(error.Truncated, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":
    , &scratch, null));
}

test "omitted and null inner params mean the same thing, and both re-encode" {
    var scratch: [128]u8 = undefined;
    // "Omission and `null` both mean no inner parameters", so a caller asking
    // whether this envelope carries parameters is told no for both. A
    // non-null `inner_params` holding four bytes is not that answer.
    const omitted = try decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call"}
    , &scratch, null);
    try testing.expect(!omitted.carriesParams());

    const explicit_null = try decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":null}
    , &scratch, null);
    try testing.expect(!explicit_null.carriesParams());

    // The bytes are kept rather than normalised to an absent member. Dropping
    // them would make `encode(decode(b)) != b` for an envelope that arrived
    // with the member written out, and the encoding contract is not
    // negotiable per protocol. The equivalence lives in `carriesParams`
    // instead, where a caller reaches it by name.
    try testing.expectEqual(@as(?[]const u8, null), omitted.inner_params);
    try testing.expectEqualStrings("null", explicit_null.inner_params.?);

    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeEnvelope(explicit_null, &writer);
    try testing.expectEqualStrings(
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":null}
    , writer.written());
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

test "an envelope round-trips its outer _meta byte for byte" {
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;

    // The ACP envelope metadata a peer sent has to survive a proxy's decode
    // and re-encode. Before the member was carried, this wrote the three
    // members the encoder knew and dropped the fourth, and nothing reported
    // it: what came back still decoded cleanly.
    const bare =
        \\{"serverId":"s","requestId":"r","method":"tools/call","_meta":{"trace":"abc"}}
    ;
    const envelope = try decodeEnvelope(bare, &scratch, .{ .integer = 7 });
    var writer = json.Writer.init(&buffer);
    try encodeEnvelope(envelope, &writer);
    try testing.expectEqualStrings(bare, writer.written());

    // The same beside `params`, which is the member order table 10b lists and
    // the one this encoder writes.
    const with_params =
        \\{"serverId":"s","requestId":"r","method":"tools/call","params":{"name":"echo"},"_meta":{"a":1}}
    ;
    const both = try decodeEnvelope(with_params, &scratch, .{ .integer = 7 });
    var second = json.Writer.init(&buffer);
    try encodeEnvelope(both, &second);
    try testing.expectEqualStrings(with_params, second.written());
}

test "an envelope member the input spells twice resolves first-wins" {
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;

    // `AGENTS.md` pins first-wins for a repeated member, and names the harm
    // it prevents: a later member must not be able to make a failed
    // comparison pass. This walk took the last occurrence of every member it
    // compared, so a peer could name one tenant and then, on the same line,
    // name another, and a proxy reading the document with `json.memberText`
    // beside it would forward the call somewhere the first reader did not.
    const redirected =
        \\{"serverId":"tenant-a","requestId":"r","method":"tools/call","serverId":"tenant-b"}
    ;
    const envelope = try decodeEnvelope(redirected, &scratch, .{ .integer = 7 });
    try testing.expectEqualStrings("tenant-a", envelope.server_id);

    // The repeat is stepped over rather than refused, and the encoder writes
    // the member once, from the occurrence the decoder kept.
    var writer = json.Writer.init(&buffer);
    try encodeEnvelope(envelope, &writer);
    try testing.expectEqualStrings(
        \\{"serverId":"tenant-a","requestId":"r","method":"tools/call"}
    , writer.written());

    // Every member the walk compares, not only the one the harm is named
    // against: a repeat of `requestId`, `method` or `params` is the same
    // question and the same answer.
    const repeated = try decodeEnvelope(
        \\{"serverId":"s","requestId":"first","requestId":"second","method":"first","method":"second","params":{"a":1},"params":{"b":2}}
    , &scratch, null);
    try testing.expectEqualStrings("first", repeated.request_id);
    try testing.expectEqualStrings("first", repeated.inner_method);
    try testing.expectEqualStrings("{\"a\":1}", repeated.inner_params.?);

    // The carrier `_meta` is carried the same way, because it is carried
    // rather than modelled, so a second one is a second document a peer did
    // not mean to write.
    const twice_meta = try decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"m","_meta":{"a":1},"_meta":{"b":2}}
    , &scratch, null);
    try testing.expectEqualStrings("{\"a\":1}", twice_meta.meta.?);
}

test "a later envelope member cannot repair an empty one" {
    var scratch: [256]u8 = undefined;

    // The check below the member loop refuses an empty identifier, and a walk
    // that resolved last-wins let a peer append a usable one and be accepted
    // anyway: the document the encoder was handed was not the document the
    // first reader saw. Under first-wins the empty `serverId` is the one that
    // is read, so the refusal stands.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"","requestId":"r","method":"m","serverId":"s"}
    , &scratch, null));
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"","requestId":"r","method":"m"}
    , &scratch, null));
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"","method":"m"}
    , &scratch, null));

    // A member that is absent stays absent. A repeat is not a way to supply
    // one the document never carried.
    try testing.expectError(error.MissingField, decodeEnvelope(
        \\{"requestId":"r","method":"m","requestId":"r"}
    , &scratch, null));
}

test "a repeated params member is shape-checked even though it is skipped" {
    var scratch: [256]u8 = undefined;

    // The first occurrence is the lexeme the envelope carries, and a document
    // whose second `params` is an array is malformed whatever the first one
    // said: table 10b types the member "object | `null`" and says positional
    // arrays are invalid, and the member is named in the document however
    // often it is spelled.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"m","params":{},"params":[1,2]}
    , &scratch, null));
    // And the first one is still checked, so a second valid member cannot
    // stand in for a malformed first.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"m","params":[1,2],"params":{}}
    , &scratch, null));
}

test "an outcome member the input spells twice resolves first-wins" {
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;

    // The same rule as the envelope. The pair is still refused — that is a
    // document with two outcomes — and the repetition is not.
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"result":1,"error":{"code":-1,"message":"m"}}
    , &scratch));
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":{"code":-1,"message":"m"},"result":1}
    , &scratch));

    const first = try decodeOutcome(
        \\{"result":{"a":1},"result":{"b":2}}
    , &scratch);
    try testing.expect(first == .result);
    try testing.expectEqualStrings("{\"a\":1}", first.result.text);
    var writer = json.Writer.init(&buffer);
    try encodeOutcome(first, &writer);
    try testing.expectEqualStrings("{\"result\":{\"a\":1}}", writer.written());

    // The carrier `_meta` rides the same rule, and an `error` pair does too:
    // the second `code` is not the code the caller is told about.
    const repeated_error = try decodeOutcome(
        \\{"error":{"code":-1,"message":"first","code":-32022,"message":"second"},"_meta":{"a":1},"_meta":{"b":2}}
    , &scratch);
    try testing.expect(repeated_error == .@"error");
    try testing.expectEqualStrings(
        \\{"code":-1,"message":"first","code":-32022,"message":"second"}
    , repeated_error.@"error".text);
    try testing.expectEqualStrings("{\"a\":1}", repeated_error.@"error".meta.?);
}

test "an envelope carries the outer _meta as the lexeme that arrived" {
    var scratch: [256]u8 = undefined;

    // Borrowed, not modelled. A shape would have to name every key a peer or a
    // proxy may put in ACP metadata, and one it did not name could not be
    // written back, which is the defect the borrowed lexeme removes.
    const envelope = try decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"tools/call","_meta":{"trace":"abc","n":1}}
    , &scratch, .{ .integer = 7 });
    try testing.expectEqualStrings("{\"trace\":\"abc\",\"n\":1}", envelope.meta.?);

    // This is the envelope `_meta`, beside `serverId`. The inner MCP `_meta`
    // is a different member in a different place — it lives inside `params`,
    // which is carried as text and is untouched by any of this.
    try testing.expectEqual(@as(?[]const u8, null), envelope.inner_params);

    // The member is read wherever it is written. A peer may put it before
    // `serverId` or after `method`, and both arrive with it attached.
    const leading = try decodeEnvelope(
        \\{"_meta":{"trace":"abc"},"serverId":"s","requestId":"r","method":"tools/call"}
    , &scratch, .{ .integer = 7 });
    try testing.expectEqualStrings("{\"trace\":\"abc\"}", leading.meta.?);
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
        failure.@"error".text,
    );
}

test "a short read is Truncated wherever in the error object it lands" {
    var scratch: [128]u8 = undefined;
    // PROTOCOLS.md 2.1: `Truncated` is "Input ended before the value was
    // complete". The byte check read `reader.peek()` against `'{'` without
    // the `orelse` its two siblings carry, so a reader at end of input
    // compared null against a byte and answered `InvalidField`. One short
    // read was then reported two ways depending on where it landed, and a
    // consumer that separates "short read" from "bad peer" could not.
    try testing.expectError(error.Truncated, decodeOutcome(
        \\{"error":
    , &scratch));
    // The same short read on the closing-brace path, which already said
    // `Truncated`, so both halves of one input now agree.
    try testing.expectError(error.Truncated, decodeOutcome(
        \\{"error":{"code":-32602,"message":"m"
    , &scratch));

    // A value that is present and is not an error object is still a field the
    // protocol does not permit. Only input that *ended* is a short read.
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":null}
    , &scratch));
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":"boom"}
    , &scratch));
    try testing.expectError(error.InvalidField, decodeOutcome(
        \\{"error":[1]}
    , &scratch));
}

test "a result is any JSON value, an explicit null included" {
    var scratch: [256]u8 = undefined;
    // Deliberately not checked like the error arm: a result carries whatever
    // the MCP operation returned, and `null` is a value it may return.
    const nulled = try decodeOutcome(
        \\{"result":null}
    , &scratch);
    try testing.expect(nulled == .result);
    try testing.expectEqualStrings("null", nulled.result.text);

    const empty = try decodeOutcome(
        \\{"result":{}}
    , &scratch);
    try testing.expectEqualStrings("{}", empty.result.text);
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
    try testing.expectEqualStrings(outcome.result.text, again.result.text);

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
        try encodeOutcome(.{ .result = .{ .text = case.payload } }, &each);
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
    try testing.expectEqualStrings(outcome.@"error".text, again.@"error".text);
}

test "an outcome round-trips its carrier _meta byte for byte" {
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;

    // The carrier `_meta` of a successful outer response, which the outcome
    // payload alone could not carry. Before the member was carried this wrote
    // `{"result":{"resultType":"complete"}}`, and the loss was invisible: what
    // came back still decoded, so nothing downstream ever reported an error.
    const result_raw = "{\"result\":{\"resultType\":\"complete\"},\"_meta\":{\"x\":1}}";
    const result_outcome = try decodeOutcome(result_raw, &scratch);
    var result_writer = json.Writer.init(&buffer);
    try encodeOutcome(result_outcome, &result_writer);
    try testing.expectEqualStrings(result_raw, result_writer.written());

    // The same on the error arm, so a rejection cannot reach the peer stripped
    // of the metadata the caller put beside it.
    const error_raw =
        \\{"error":{"code":-32602,"message":"unknown tool"},"_meta":{"x":1}}
    ;
    const error_outcome = try decodeOutcome(error_raw, &scratch);
    var error_writer = json.Writer.init(&buffer);
    try encodeOutcome(error_outcome, &error_writer);
    try testing.expectEqualStrings(error_raw, error_writer.written());
}

test "an outcome carries the carrier _meta wherever it was written" {
    var scratch: [256]u8 = undefined;
    var buffer: [128]u8 = undefined;

    // Borrowed text, spliced verbatim. A shape would have to name every key a
    // peer or a proxy may put in ACP metadata, and one it did not name could
    // not be written back — which is the defect the borrowed lexeme removes.
    const leading = try decodeOutcome(
        \\{"_meta":{"x":1},"result":{"resultType":"complete"}}
    , &scratch);
    try testing.expectEqualStrings("{\"resultType\":\"complete\"}", leading.result.text);
    try testing.expectEqualStrings("{\"x\":1}", leading.result.meta.?);

    // An explicit `null` is ACP metadata the same way an empty object is: the
    // normative row types the member as an object and says omission and
    // `null` are equivalent. It is carried as the bytes that arrived and
    // written back as they were, because the carrier is not modelled.
    const nulled = try decodeOutcome(
        \\{"result":1,"_meta":null}
    , &scratch);
    try testing.expectEqualStrings("null", nulled.result.meta.?);
    var writer = json.Writer.init(&buffer);
    try encodeOutcome(nulled, &writer);
    try testing.expectEqualStrings("{\"result\":1,\"_meta\":null}", writer.written());
}

test "trailing bytes are refused, not silently truncated" {
    var scratch: [256]u8 = undefined;

    // Both decoders walk one object and stop at its closing brace. Bytes after
    // it are a second document the transport did not split, and accepting them
    // re-encodes an envelope or a carrier without them — the same silent loss
    // a dropped `_meta` was, and the reason `jsonrpc.decode`, `acp_session`
    // and `mcp_session` all ask `atEnd`.
    try testing.expectError(error.MalformedJson, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"m"} trailing
    , &scratch, null));
    try testing.expectError(error.MalformedJson, decodeOutcome(
        \\{"result":{"a":1}} trailing
    , &scratch));
    // A second whole message spliced on, which is what the transport failed
    // to split, is the same refusal.
    try testing.expectError(error.MalformedJson, decodeOutcome(
        \\{"result":{"a":1}}{"result":{"a":2}}
    , &scratch));
    // The `error` arm takes its lexeme around a validation call rather than
    // through `rawValue`, so it is the one arm where a check written inside
    // the arm, or before the member loop closes, would pass on a tail as long
    // as the inner object itself parsed. The check is after the loop, so the
    // tail is refused here too.
    try testing.expectError(error.MalformedJson, decodeOutcome(
        \\{"error":{"code":-1,"message":"m"}} trailing
    , &scratch));
    // The same with a `_meta` sibling after the outcome member, so the
    // refusal cannot be an artefact of `_meta` being where the tail is.
    try testing.expectError(error.MalformedJson, decodeOutcome(
        \\{"error":{"code":-1,"message":"m"},"_meta":{"b":1}} trailing
    , &scratch));
    // An envelope that carries `params`, so the tail follows a lexeme the
    // decoder borrowed rather than one it walked.
    try testing.expectError(error.MalformedJson, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"m","params":{"a":1}} trailing
    , &scratch, null));

    // Trailing whitespace is not trailing data: a frame that arrived padded
    // still decodes, which is the reason `atEnd` skips whitespace first.
    const padded = try decodeOutcome("{\"result\":{\"a\":1}}\n", &scratch);
    try testing.expectEqualStrings("{\"a\":1}", padded.result.text);
    const padded_envelope = try decodeEnvelope(
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"m\"}  \n",
        &scratch,
        null,
    );
    try testing.expectEqualStrings("m", padded_envelope.inner_method);
    // Which fault is reported when a document is wrong in two ways. The walk
    // is ordered, so the answer is whichever fault it reaches first. The
    // `params` shape check is inside the member loop and `atEnd` is after it,
    // so a wrong shape beside a tail reports the shape. A tail is in turn
    // ahead of the required-member check, which runs after it.
    try testing.expectError(error.InvalidField, decodeEnvelope(
        \\{"serverId":"s","requestId":"r","method":"m","params":[1,2]} trailing
    , &scratch, null));
    try testing.expectError(error.MalformedJson, decodeEnvelope(
        \\{"serverId":"s","requestId":"r"} trailing
    , &scratch, null));
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
        .@"error" = .{ .text = "{\"code\":-32602,\"message\":\"unknown tool\"}" },
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
        back.@"error".text,
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
