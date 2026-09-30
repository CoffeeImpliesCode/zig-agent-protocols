//! Model Context Protocol, revisions `2026-07-28` and `2025-11-25`.
//!
//! Values come from PROTOCOLS.md section 4, which selects from
//! `research/normative/mcp-2026-07-28.md`. Where PROTOCOLS.md and the normative
//! extraction disagree, PROTOCOLS.md wins and the source is wrong.
//!
//! ## The two revisions are separate decoders
//!
//! PROTOCOLS.md section 8 is explicit: MCP is "two separately decoded revisions,
//! not one revision with a flag". The reason is asymmetry. On `2026-07-28` there
//! is no handshake and capabilities travel per request in `_meta`; on
//! `2025-11-25` and earlier they travel in the `initialize` request and result.
//! A single decoder with a revision flag would have to branch at every field
//! read, and a caller would have to remember which branch it was in. So a method
//! is resolved against an explicit `Revision`, and a method removed at the
//! current revision decodes to `error.UnknownMethod` rather than to a value that
//! a caller might then send.

const std = @import("std");
const root = @import("root.zig");
const json = @import("json.zig");

const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

// --- 4.1 Version and transport -------------------------------------------------

/// The revision this library is pinned to, section 4.1.
pub const latest_protocol_version = "2026-07-28";

/// The older revision, decoded separately rather than as a flag.
pub const previous_protocol_version = "2025-11-25";

pub const jsonrpc_version = "2.0";

/// The two decoded revisions.
///
/// The tags are the library's own; `string` is the wire spelling.
pub const Revision = enum {
    /// `2026-07-28`. No handshake; capabilities are per request.
    current,
    /// `2025-11-25` and earlier. Capabilities travel in `initialize`.
    previous,

    pub fn fromString(text: []const u8) ?Revision {
        if (std.mem.eql(u8, text, latest_protocol_version)) return .current;
        if (std.mem.eql(u8, text, previous_protocol_version)) return .previous;
        return null;
    }

    pub fn string(self: Revision) []const u8 {
        return switch (self) {
            .current => latest_protocol_version,
            .previous => previous_protocol_version,
        };
    }
};

/// The transports named in section 4.1.
///
/// The HTTP+SSE transport, deprecated in `2025-03-26` and formally deprecated in
/// `2026-07-28`, is deliberately absent rather than modelled as deprecated.
pub const Transport = enum {
    stdio,
    streamable_http,
};

// --- 4.2 HTTP headers ----------------------------------------------------------

/// The MCP-defined header names, spelled as the specification spells them.
///
/// `MCP-Protocol-Version` is all-caps while every other MCP-defined header is
/// title-case `Mcp-`. Both spellings appear verbatim in the same specification
/// document, both are required, and they are wire-equivalent under the spec's own
/// case-insensitivity rule, so `headerKind` matches case-insensitively and a
/// table keyed on one casing would be wrong.
pub const header_name = struct {
    pub const protocol_version = "MCP-Protocol-Version";
    pub const method = "Mcp-Method";
    pub const name = "Mcp-Name";
    pub const session_id = "Mcp-Session-Id";
    pub const origin = "Origin";
    pub const accept = "Accept";
    pub const content_type = "Content-Type";
    pub const last_event_id = "Last-Event-ID";
};

/// The prefix of a derived parameter header, `Mcp-Param-{Name}`.
pub const param_header_prefix = "Mcp-Param-";

/// The base64 sentinel that wraps a header value which is not safe to send raw.
///
/// Section 4.2: the `=?base64?` prefix and the `?=` suffix are case-sensitive
/// and MUST appear exactly as written when present.
pub const sentinel_prefix = "=?base64?";
pub const sentinel_suffix = "?=";

/// The JSON Schema extension keyword inside `Tool.inputSchema` properties.
///
/// It is not a header a client sends. A client derives an `Mcp-Param-{Name}`
/// header from it.
pub const schema_header_keyword = "x-mcp-header";

/// What an incoming header name denotes.
pub const HeaderKind = enum {
    protocol_version,
    method,
    /// `Mcp-Name`, and the `Mcp-Param-*` family by its prefix.
    name,
    param,
    origin,
    accept,
    content_type,
    authorization,
    www_authenticate,
    /// Sent by neither side. It is the JSON Schema keyword, not a header.
    schema_keyword,
    /// Removed in `2026-07-28`. A peer that sends it is not speaking this
    /// revision; the specification says to ignore it.
    session_id_removed,
    /// Not supported in `2026-07-28`. The specification says to ignore it.
    last_event_id_removed,
    /// Any other header. A server MUST still validate `Origin` and require
    /// `Authorization`, and neither is MCP-specific.
    other,
};

/// Classify a header name.
///
/// Matching is case-insensitive for the name and case-sensitive for the value,
/// which is the rule the specification states.
pub fn headerKind(name: []const u8) HeaderKind {
    if (std.ascii.eqlIgnoreCase(name, header_name.protocol_version)) return .protocol_version;
    if (std.ascii.eqlIgnoreCase(name, header_name.method)) return .method;
    if (std.ascii.eqlIgnoreCase(name, header_name.name)) return .name;
    if (std.ascii.eqlIgnoreCase(name, header_name.origin)) return .origin;
    if (std.ascii.eqlIgnoreCase(name, header_name.accept)) return .accept;
    if (std.ascii.eqlIgnoreCase(name, header_name.content_type)) return .content_type;
    if (std.ascii.eqlIgnoreCase(name, "Authorization")) return .authorization;
    if (std.ascii.eqlIgnoreCase(name, "WWW-Authenticate")) return .www_authenticate;
    if (std.ascii.eqlIgnoreCase(name, header_name.session_id)) return .session_id_removed;
    if (std.ascii.eqlIgnoreCase(name, header_name.last_event_id)) return .last_event_id_removed;
    if (std.ascii.eqlIgnoreCase(name, schema_header_keyword)) return .schema_keyword;
    if (hasPrefixIgnoreCase(name, param_header_prefix)) {
        // `Mcp-Param-` with no `{Name}` is not a derived header. Section 4.2
        // requires the annotation to be non-empty and to match field-name
        // token syntax, so a bare prefix — or one with a space after it — is
        // some other header a server validates by its own rules.
        return if (isValidSchemaHeaderName(name[param_header_prefix.len..]))
            .param
        else
            .other;
    }
    return .other;
}

fn hasPrefixIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

/// Whether a header value is wrapped in the base64 sentinel.
///
/// A value matching the sentinel pattern is base64 even when the bytes inside
/// are plain ASCII, because the specification requires clients to encode such a
/// value and servers to decode it before comparing.
pub fn isSentinelEncoded(value: []const u8) bool {
    if (value.len < sentinel_prefix.len + sentinel_suffix.len) return false;
    if (!std.mem.startsWith(u8, value, sentinel_prefix)) return false;
    return std.mem.endsWith(u8, value, sentinel_suffix);
}

/// The bytes a server should compare against the request body.
///
/// Section 4.2: servers MUST decode before comparing. The decoded value is
/// returned in `scratch` when the input is sentinel-encoded, and borrowed from
/// `value` otherwise.
///
/// A scratch buffer too small to hold the decoded value is `BufferTooSmall`,
/// not `InvalidField`: the caller chose the size, so this is a caller-side
/// sizing error rather than a malformed header, and collapsing the two would
/// send a peer that sent a legal value down the rejection path.
pub fn decodeHeaderValue(value: []const u8, scratch: []u8) DecodeError![]const u8 {
    if (!isSentinelEncoded(value)) return value;
    const body = value[sentinel_prefix.len .. value.len - sentinel_suffix.len];
    return base64.decode(body, scratch) catch |err| switch (err) {
        error.BufferTooSmall => error.BufferTooSmall,
        error.InvalidField => error.InvalidField,
    };
}

/// The scratch a caller must supply to [`encodeHeaderValue`] for a value of
/// `value_len` bytes.
///
/// Base64 with padding emits four characters for every three input bytes. The
/// caller sizes the buffer because nothing in an encode path allocates: a
/// fixed buffer the caller cannot reach turns an `Mcp-Name` past its size into
/// an unencodable value rather than a larger one.
pub fn sentinelScratchLen(value_len: usize) usize {
    return (value_len + 2) / 3 * 4;
}

/// Encode a header value, applying the sentinel when the specification requires
/// it: non-ASCII, a control character, or leading or trailing whitespace.
///
/// `scratch` receives the base64 output and must hold
/// [`sentinelScratchLen`] bytes for `value`. It is untouched when the value
/// needs no sentinel, so a caller may share it with an unrelated decode.
///
/// A header value is raw text, not JSON, so nothing here is quoted. The JSON
/// writer is used only for its byte sink.
pub fn encodeHeaderValue(value: []const u8, writer: *json.Writer, scratch: []u8) EncodeError!void {
    if (!needsSentinel(value)) return writer.slice(value);

    const encoded = try base64.encode(value, scratch);
    try writer.slice(sentinel_prefix);
    try writer.slice(encoded);
    try writer.slice(sentinel_suffix);
}

/// Whether a header value agrees with the body value it duplicates.
///
/// Section 4.2: `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and
/// `Mcp-Param-{Name}` each repeat a value the request body also carries, and a
/// server MUST decode the sentinel before comparing. A `false` result is the
/// condition for `ErrorCode.header_mismatch`, `-32020`; the caller raises the
/// error, because the specification pairs it with an HTTP status this library
/// does not carry.
///
/// `scratch` receives the decoded header value and is untouched when the header
/// value needs no decoding.
pub fn headerMatchesBody(
    header_value: []const u8,
    body_value: []const u8,
    scratch: []u8,
) DecodeError!bool {
    const decoded = try decodeHeaderValue(header_value, scratch);
    return std.mem.eql(u8, decoded, body_value);
}

fn needsSentinel(value: []const u8) bool {
    // A value that already matches the sentinel pattern is itself encoded, so
    // a server never mistakes the literal text for an encoded value. The
    // specification requires this even for plain-ASCII input.
    if (isSentinelEncoded(value)) return true;
    if (!std.unicode.utf8ValidateSlice(value)) return true;
    for (value) |byte| {
        // A control character, or anything outside plain ASCII.
        if (byte < 0x20 or byte >= 0x7f) return true;
    }
    if (value.len == 0) return true;
    if (std.ascii.isWhitespace(value[0])) return true;
    if (std.ascii.isWhitespace(value[value.len - 1])) return true;
    return false;
}

/// Validate an `x-mcp-header` annotation name, section 4.2.
///
/// MUST NOT be empty; MUST match RFC 9110 field-name token syntax; MUST NOT
/// contain a control character, including CR or LF.
pub fn isValidSchemaHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        const valid = switch (byte) {
            '0'...'9', 'a'...'z', 'A'...'Z' => true,
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
        if (!valid) return false;
    }
    return true;
}

/// Whether every `x-mcp-header` annotation name in one `inputSchema` is
/// distinct.
///
/// Section 4.2: the values must be case-insensitively unique within one
/// `inputSchema`, so `City` and `city` are one annotation, not two. The
/// comparison is pairwise because building a set would allocate and no decode
/// or validation path in this library allocates.
pub fn areSchemaHeaderNamesUnique(names: []const []const u8) bool {
    for (names, 0..) |name, index| {
        for (names[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(name, other)) return false;
        }
    }
    return true;
}

/// The inclusive range an `x-mcp-header` integer parameter must fall within.
///
/// The specification states −2^53+1 to 2^53−1, which is the range a JSON number
/// is required to hold exactly.
pub const header_integer_min: i64 = -(1 << 53) + 1;
pub const header_integer_max: i64 = (1 << 53) - 1;

pub fn isValidHeaderInteger(value: i64) bool {
    return value >= header_integer_min and value <= header_integer_max;
}

/// One keyword on the chain from a schema root to an annotated property.
pub const SchemaStep = enum {
    /// `properties`, the only keyword the chain may consist of.
    properties,
    /// `items`, or any other array keyword.
    array_keyword,
    /// `oneOf`, `anyOf`, `allOf` or `not`.
    composition,
    /// `if`, `then` or `else`.
    conditional,
    /// `$ref`.
    ref,
};

/// Whether an annotated property is statically reachable from the root.
///
/// Section 4.2: the chain from the schema root to an annotated property MUST
/// consist solely of `properties` keys, and MUST NOT pass through an array
/// keyword, a composition keyword, a conditional keyword or `$ref`. A chain
/// that crosses one of them describes a property the peer is not obliged to
/// send, so a header derived from it has no body value to agree with.
pub fn isStaticallyReachable(chain: []const SchemaStep) bool {
    for (chain) |step| {
        if (step != .properties) return false;
    }
    return true;
}

/// The `type` keyword of a property an `x-mcp-header` annotation may sit on.
pub const ParamType = enum {
    /// JSON Schema `string`. The value travels as-is.
    string,
    /// JSON Schema `integer`. The value travels as a decimal string, so it
    /// must be one a JSON number holds exactly.
    integer,
    /// JSON Schema `boolean`. The value travels as lowercase `true`/`false`.
    boolean,
    /// JSON Schema `number`. The specification names this one out by name.
    number,
    /// JSON Schema `array`. Not primitive, so not bindable.
    array,
    /// JSON Schema `object`. Not primitive, so not bindable.
    object,
    /// JSON Schema `null`. A parameter of this type carries no value at all,
    /// and the rule omits the header for it anyway.
    ///
    /// The tag is not spelled `null` because the enum would shadow the
    /// literal inside its own namespace.
    null_type,
    /// `type` held a union array, or a name this library does not know.
    ///
    /// Neither form is a primitive type, so the gate rejects both rather than
    /// guessing which member of a union the peer meant.
    unstated,

    pub fn fromSchemaType(name: []const u8) ParamType {
        return if (std.mem.eql(u8, name, "string"))
            .string
        else if (std.mem.eql(u8, name, "integer"))
            .integer
        else if (std.mem.eql(u8, name, "boolean"))
            .boolean
        else if (std.mem.eql(u8, name, "number"))
            .number
        else if (std.mem.eql(u8, name, "array"))
            .array
        else if (std.mem.eql(u8, name, "object"))
            .object
        else if (std.mem.eql(u8, name, "null"))
            .null_type
        else
            .unstated;
    }
};

/// Whether an `x-mcp-header` annotation may sit on a property of this type.
///
/// Section 4.2: an annotation MUST only be applied to parameters with
/// primitive types — integer, string, boolean — and parameters with type
/// `number` are not permitted. The remaining JSON Schema types are not
/// primitive either, so they are refused for the same reason rather than
/// because this library disliked them.
///
/// The switch covers every tag on purpose: a tag added to [`ParamType`] has
/// to make this decision rather than fall through it.
pub fn isBindableParamType(param_type: ParamType) bool {
    return switch (param_type) {
        .string, .integer, .boolean => true,
        .number, .array, .object, .null_type, .unstated => false,
    };
}

/// Why one `x-mcp-header` annotation is not conformant.
pub const AnnotationError = error{
    /// The name is empty, or is not an RFC 9110 field-name token.
    InvalidName,
    /// The name repeats one already in the same `inputSchema`, comparing
    /// case-insensitively.
    DuplicateName,
    /// The annotated property is not of a primitive type.
    NotPrimitive,
    /// The annotated property is not reachable from the root by `properties`
    /// keys alone.
    Unreachable,
};

/// One `x-mcp-header` annotation and everything the gate needs to judge it.
pub const Annotation = struct {
    /// The `x-mcp-header` value as the schema wrote it.
    name: []const u8,
    /// The `type` keyword of the property it sits on.
    param_type: ParamType,
    /// The keywords crossed from the schema root to that property. An empty
    /// chain is a property of the root schema itself.
    chain: []const SchemaStep = &.{},
    /// Every other annotation name in the same `inputSchema`.
    siblings: []const []const u8 = &.{},

    /// Whether this annotation is legal where it sits.
    pub fn isConformant(self: Annotation) bool {
        checkAnnotation(self) catch return false;
        return true;
    }
};

/// Check every constraint section 4.2 places on one annotation.
///
/// The checks run in the order the specification states them, so the returned
/// error names the first rule the annotation breaks. The integer bound is not
/// among them: it constrains a value rather than a schema, and
/// [`isBindableValue`] applies it where the value is known.
pub fn checkAnnotation(annotation: Annotation) AnnotationError!void {
    if (!isValidSchemaHeaderName(annotation.name)) return error.InvalidName;
    // Pairwise, because a set of names would allocate and no validation path
    // in this library allocates.
    for (annotation.siblings) |sibling| {
        if (std.ascii.eqlIgnoreCase(sibling, annotation.name)) return error.DuplicateName;
    }
    if (!isBindableParamType(annotation.param_type)) return error.NotPrimitive;
    if (!isStaticallyReachable(annotation.chain)) return error.Unreachable;
}

/// A primitive `arguments` value, as the binding reads it.
pub const ParamValue = union(enum) {
    /// A JSON Schema `string` parameter.
    string_value: []const u8,
    /// An `integer` parameter.
    integer: i64,
    /// A `boolean` parameter.
    boolean: bool,
};

/// The scratch a caller must supply to render an integer parameter, and to
/// render one for a server-side comparison.
///
/// An `i64` renders to nineteen digits at most, so the widest output is
/// twenty bytes with the sign. 24 leaves room above that bound.
pub const param_value_max_len: usize = 24;

/// Whether a value is bindable to a derived header: it has the type the
/// schema declares, and an integer is one a JSON number holds exactly.
///
/// Section 4.2 states the integer range as −2^53+1 to 2^53−1, which is
/// [`isValidHeaderInteger`]. A value outside it is not a header the peer can
/// read back as the same number.
pub fn isBindableValue(param_type: ParamType, value: ParamValue) bool {
    return switch (value) {
        .string_value => param_type == .string,
        .boolean => param_type == .boolean,
        .integer => |number| param_type == .integer and isValidHeaderInteger(number),
    };
}

/// Render a primitive value the way a derived header carries it.
///
/// Section 4.2 fixes the conversion: `string` as-is, `integer` to a decimal
/// string, `boolean` to lowercase `true` or `false`. The result borrows from
/// `value` for a string and is a literal for a boolean; only an integer is
/// written to `out`, so a caller comparing the result must keep that buffer
/// alive. [`param_value_max_len`] bytes always suffice.
pub fn renderParamValue(value: ParamValue, out: []u8) error{BufferTooSmall}![]const u8 {
    return switch (value) {
        .string_value => |text| text,
        .boolean => |flag| if (flag) "true" else "false",
        .integer => |number| writeDecimal(number, out),
    };
}

fn writeDecimal(value: i64, out: []u8) error{BufferTooSmall}![]const u8 {
    // `-(value + 1) + 1` rather than `-value`, which traps on `i64.min`. The
    // range gate rejects that value first, but a total function is cheaper
    // than an invariant a later edit can break.
    // The negation stays in the signed domain, where `value + 1` is one past
    // the magnitude and so is itself representable. `@intCast` then carries
    // the non-negative result into the unsigned domain; `@as` cannot, because
    // an `i64` does not coerce to a `u64`. The trailing `+ 1` runs unsigned,
    // where the widest magnitude, `2^63`, is a value and not an overflow.
    // `magnitude` is undefined only until the arms below assign it: the first
    // read is after the `if`, and neither arm falls through.
    const negative = value < 0;
    var magnitude: u64 = undefined;
    if (negative) {
        const one_past: i64 = -(value + 1);
        const positive: u64 = @intCast(one_past);
        magnitude = positive + 1;
    } else {
        magnitude = @intCast(value);
    }

    var width: usize = 1;
    var rest = magnitude / 10;
    while (rest != 0) : (rest /= 10) width += 1;

    const needed: usize = width + @intFromBool(negative);
    if (out.len < needed) return error.BufferTooSmall;
    if (negative) out[0] = '-';

    // Filled from the least significant digit, straight into `out` and with
    // no intermediate copy. The digits start one byte in when there is a
    // sign, so a negative value keeps its `-` rather than having the units
    // digit written over it.
    rest = magnitude;
    const first: usize = @intFromBool(negative);
    var index = needed;
    while (index > first) {
        index -= 1;
        out[index] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
    }
    return out[0..needed];
}

/// The bytes a derived header name needs for an annotation of `name_len`.
pub fn paramHeaderNameLen(name_len: usize) usize {
    return param_header_prefix.len + name_len;
}

/// Write `Mcp-Param-{Name}` for one annotation.
///
/// The name is validated first: an annotation that is not a field-name token
/// cannot appear in a header name, and a header the peer classifies as
/// [`HeaderKind.other`] is a header it ignores.
pub fn deriveParamHeaderName(annotation: []const u8, out: []u8) EncodeError![]const u8 {
    if (!isValidSchemaHeaderName(annotation)) return error.InvalidField;
    const needed = paramHeaderNameLen(annotation.len);
    if (out.len < needed) return error.BufferTooSmall;
    @memcpy(out[0..param_header_prefix.len], param_header_prefix);
    @memcpy(out[param_header_prefix.len..][0..annotation.len], annotation);
    return out[0..needed];
}

/// One derived header, ready to send.
pub const ParamBinding = struct {
    /// The annotation name as the schema wrote it.
    annotation: []const u8,
    /// `Mcp-Param-` followed by the annotation, in the caller's name buffer.
    header_name: []const u8,
    /// The converted value, with the base64 sentinel applied when the
    /// specification requires it, in the caller's value buffer.
    header_value: []const u8,
};

/// Bind one annotated `arguments` value to the header a client derives.
///
/// `value` is null when `arguments` omits the key or carries JSON `null`:
/// section 4.2 gives both the same MUST-omit rule, so the binding returns
/// null for each and does not need them apart. A value present in the body
/// MUST have its header, and a server MUST reject a request that carries the
/// value without one.
///
/// The three buffers are the caller's: `names` receives the derived header
/// name, `values` the header value, and `scratch` the base64 the sentinel
/// needs — [`sentinelScratchLen`] of the longest rendered value is always
/// enough. Nothing here allocates.
///
/// A schema fault surfaces as `error.InvalidField`, because a client holds an
/// encode error set and the buffer faults are the other member of it.
/// [`checkAnnotation`] names which rule a non-conforming schema broke.
///
/// Only `InvalidName` and `NotPrimitive` can fire here. The other two rules
/// need the schema, and this signature carries neither a chain nor a sibling
/// list, so a caller holding either runs [`checkAnnotation`] itself first.
pub fn bindParamHeader(
    annotation: []const u8,
    param_type: ParamType,
    value: ?ParamValue,
    names: []u8,
    values: []u8,
    scratch: []u8,
) EncodeError!?ParamBinding {
    // The gate runs before the presence rule: a schema that annotates a
    // non-primitive property is a tool-author fault whether or not this call
    // had a value to send, and a client that sends such a header is the party
    // the server is told to reject.
    checkAnnotation(.{
        .name = annotation,
        .param_type = param_type,
    }) catch return error.InvalidField;

    const present = value orelse return null;
    if (!isBindableValue(param_type, present)) return error.InvalidField;

    var converted: [param_value_max_len]u8 = undefined;
    const rendered = try renderParamValue(present, &converted);

    // Not named `header_name`: that is the module's table of the fixed MCP
    // header spellings, and a local may not shadow it.
    const derived = try deriveParamHeaderName(annotation, names);
    var writer = json.Writer.init(values);
    try encodeHeaderValue(rendered, &writer, scratch);
    return .{
        .annotation = annotation,
        .header_name = derived,
        .header_value = writer.written(),
    };
}

/// What a server concluded about one derived header.
pub const ParamVerdict = enum {
    /// The header carries the value `arguments` carries, or neither is
    /// present. Accept.
    accepted,
    /// The header disagrees with the body. Reject: the specification pairs a
    /// value-versus-header disagreement with [`ErrorCode.header_mismatch`].
    mismatch,
    /// `arguments` carries a value and the client sent no header. The
    /// specification calls that a non-conforming client, and the server MUST
    /// reject the request.
    missing_header,
    /// The client sent a header for a value `arguments` omits or sets to
    /// `null`. The server MUST NOT expect it, so the request is rejected.
    unexpected_header,

    /// Whether the request may proceed.
    pub fn isAcceptable(self: ParamVerdict) bool {
        return self == .accepted;
    }

    /// The code to reject with, where the specification names one.
    ///
    /// Only the disagreement is named. The other two rows require a rejection
    /// without stating a code, and this library does not invent one, so they
    /// report `null` and leave the choice to the caller.
    pub fn errorCode(self: ParamVerdict) ?ErrorCode {
        return switch (self) {
            .mismatch => .header_mismatch,
            .accepted, .missing_header, .unexpected_header => null,
        };
    }
};

/// Check one derived header against the `arguments` value it duplicates.
///
/// `body_value` is null when `arguments` omits the key or carries JSON
/// `null`; `header_value` is null when the client sent no such header. All
/// four rows of the specification's table resolve here: a value whose header
/// agrees is `accepted`, a header that disagrees is `mismatch`, a value with
/// no header is `missing_header`, and a header with no value is
/// `unexpected_header`.
///
/// `converted` receives the rendered form of an integer parameter and is
/// untouched otherwise, so a caller that already holds rendered text passes
/// it as a `string_value`. `scratch` receives the decoded sentinel and is
/// untouched when the header value needs no decoding.
pub fn checkParamBinding(
    header_value: ?[]const u8,
    body_value: ?ParamValue,
    converted: []u8,
    scratch: []u8,
) DecodeError!ParamVerdict {
    const present = body_value orelse {
        // A header the body does not account for is not a bonus a server
        // accepts: it is one the server MUST NOT expect.
        if (header_value != null) return .unexpected_header;
        return .accepted;
    };
    const header = header_value orelse return .missing_header;
    // A server decodes the sentinel before comparing, which `headerMatchesBody`
    // does, so the value it must agree with is the rendered plaintext.
    const rendered = try renderParamValue(present, converted);
    return if (try headerMatchesBody(header, rendered, scratch)) .accepted else .mismatch;
}

// --- 4.3 Reserved `_meta` keys -------------------------------------------------

/// The reserved `_meta` keys.
///
/// Four bare key names are excepted from the prefix rule: the three W3C trace
/// context keys, and `progressToken`, which the schema also defines bare.
pub const meta_key = struct {
    pub const progress_token = "progressToken";
    pub const protocol_version = "io.modelcontextprotocol/protocolVersion";
    pub const client_info = "io.modelcontextprotocol/clientInfo";
    pub const client_capabilities = "io.modelcontextprotocol/clientCapabilities";
    pub const log_level = "io.modelcontextprotocol/logLevel";
    pub const subscription_id = "io.modelcontextprotocol/subscriptionId";
    pub const server_info = "io.modelcontextprotocol/serverInfo";
    // W3C, exempt from the prefix rule.
    pub const traceparent = "traceparent";
    pub const tracestate = "tracestate";
    pub const baggage = "baggage";
};

/// The namespace prefix a vendor must own to use for MCP extensions.
pub const meta_prefix = "io.modelcontextprotocol/";

/// Whether a key name is inside a prefix MCP reserves for itself.
///
/// The rule is about the whole second label: a prefix whose second label is
/// `modelcontextprotocol` or `mcp` is reserved and nothing else is. Comparing
/// a label prefix instead would also reserve `io.modelcontextprotocolX/`, which
/// the specification does not reserve, and would reject a key a server is
/// required to accept. `com.example.mcp/` is not reserved either, because its
/// second label is `example`.
pub fn isReservedMetaPrefix(prefix: []const u8) bool {
    // The prefix is a series of dot-separated labels followed by a slash, so
    // the label sequence ends where the slash does.
    const slash = std.mem.findScalar(u8, prefix, '/') orelse prefix.len;
    const labels = prefix[0..slash];
    const first_dot = std.mem.findScalar(u8, labels, '.') orelse return false;
    const after_first = labels[first_dot + 1 ..];
    const label_end = std.mem.findScalar(u8, after_first, '.') orelse after_first.len;
    const second_label = after_first[0..label_end];
    return std.mem.eql(u8, second_label, "modelcontextprotocol") or
        std.mem.eql(u8, second_label, "mcp");
}

// --- 4.4 Method inventory ------------------------------------------------------

/// Who may send a method.
pub const Direction = enum {
    client_to_server,
    server_to_client,
    /// A server may send it, but only as a value inside
    /// `InputRequiredResult.inputRequests`. Top-level server requests are
    /// forbidden at `2026-07-28`.
    server_to_client_mrtr_only,
    /// Either side.
    bidirectional,
};

/// A method name and where it is valid.
pub const MethodInfo = struct {
    name: []const u8,
    direction: Direction,
    /// False when the method was removed at `2026-07-28`.
    present_at_current: bool,
    /// Whether a server MUST implement the method.
    ///
    /// `server/discover` is the only mandatory core method at `2026-07-28`,
    /// so this defaults to false and the table does not repeat the default at
    /// every entry.
    mandatory: bool = false,
    /// Whether the method's result may be an `InputRequiredResult`.
    mrtr: bool = false,
    /// Whether the result carries caching hints. Only a `complete` result does.
    cacheable: bool = false,
    /// Whether the method is retired rather than active.
    deprecated: bool = false,
};

/// The methods a server MUST implement at `revision`.
///
/// PROTOCOLS.md section 4.4 states the mandatory set for `2026-07-28` and does
/// not state one for any other revision, so this reports none for `2025-11-25`
/// rather than inventing one. The tables are comptime constants, so the
/// returned slice borrows static memory and nothing is allocated.
pub fn mandatoryMethods(revision: Revision) []const MethodInfo {
    return switch (revision) {
        // `server/discover` is the only mandatory method and heads the table.
        .current => client_requests[0..1],
        .previous => no_mandatory_methods[0..],
    };
}

/// The previous revision's mandatory set is not stated by the source.
const no_mandatory_methods: [0]MethodInfo = .{};

/// The complete core `2026-07-28` client-to-server request inventory: 10 members.
///
/// PROTOCOLS.md section 4.4 lists the ten in this order, and a test below
/// compares the two name for name in both directions, so a row the document
/// gains, drops or renames fails there.
pub const client_requests = [_]MethodInfo{
    .{
        .name = "server/discover",
        .direction = .client_to_server,
        .present_at_current = true,
        .mandatory = true,
        .cacheable = true,
    },
    .{ .name = "tools/list", .direction = .client_to_server, .present_at_current = true, .cacheable = true },
    .{ .name = "tools/call", .direction = .client_to_server, .present_at_current = true, .mrtr = true },
    .{ .name = "resources/list", .direction = .client_to_server, .present_at_current = true, .cacheable = true },
    .{
        .name = "resources/read",
        .direction = .client_to_server,
        .present_at_current = true,
        .mrtr = true,
        .cacheable = true,
    },
    .{
        .name = "resources/templates/list",
        .direction = .client_to_server,
        .present_at_current = true,
        .cacheable = true,
    },
    .{ .name = "prompts/list", .direction = .client_to_server, .present_at_current = true, .cacheable = true },
    .{ .name = "prompts/get", .direction = .client_to_server, .present_at_current = true, .mrtr = true },
    .{ .name = "completion/complete", .direction = .client_to_server, .present_at_current = true },
    .{ .name = "subscriptions/listen", .direction = .client_to_server, .present_at_current = true },
};

/// The core notification inventory.
///
/// `notifications/cancelled` is in both unions: the client sends it to cancel,
/// and the server sends it solely to terminate a `subscriptions/listen` stream.
///
/// PROTOCOLS.md section 4.4 lists the eight in this order, and a test below
/// compares the two name for name in both directions.
pub const notifications = [_]MethodInfo{
    .{ .name = "notifications/progress", .direction = .server_to_client, .present_at_current = true },
    .{
        .name = "notifications/message",
        .direction = .server_to_client,
        .present_at_current = true,
        // Section 4.4 does not mark it deprecated; section 4.9 lists Logging as
        // deprecated, and this is the logging notification.
        .deprecated = true,
    },
    .{ .name = "notifications/cancelled", .direction = .bidirectional, .present_at_current = true },
    .{ .name = "notifications/resources/updated", .direction = .server_to_client, .present_at_current = true },
    .{ .name = "notifications/resources/list_changed", .direction = .server_to_client, .present_at_current = true },
    .{ .name = "notifications/tools/list_changed", .direction = .server_to_client, .present_at_current = true },
    .{ .name = "notifications/prompts/list_changed", .direction = .server_to_client, .present_at_current = true },
    .{ .name = "notifications/subscriptions/acknowledged", .direction = .server_to_client, .present_at_current = true },
};

/// The `InputRequest` union: the only three server-to-client requests, and only
/// ever inside `inputRequests`.
pub const input_requests = [_]MethodInfo{
    .{ .name = "elicitation/create", .direction = .server_to_client_mrtr_only, .present_at_current = true },
    .{
        .name = "sampling/createMessage",
        .direction = .server_to_client_mrtr_only,
        .present_at_current = true,
        .deprecated = true,
    },
    .{ .name = "roots/list", .direction = .server_to_client_mrtr_only, .present_at_current = true, .deprecated = true },
};

/// A method this library removed at `2026-07-28`.
///
/// The direction is carried here rather than derived from the method name,
/// because a `notifications/` prefix says nothing about which side sends the
/// message: `notifications/initialized` is a client-to-server notification,
/// and deriving the direction from the prefix sent it the other way.
pub const RemovedMethod = struct {
    name: []const u8,
    direction: Direction,
    /// Whether the method is a notification: no `id`, and no result.
    notification: bool,
};

/// Methods removed at `2026-07-28`, which therefore decode as `UnknownMethod`.
///
/// `sampling/createMessage`, `elicitation/create` and `roots/list` are not
/// listed: what is removed is their use as top-level requests. They survive as
/// values inside `InputRequiredResult.inputRequests`, and
/// [`lookupInputRequest`] is the entry point that finds them.
pub const removed_methods = [_]RemovedMethod{
    .{ .name = "initialize", .direction = .client_to_server, .notification = false },
    .{
        .name = "notifications/initialized",
        .direction = .client_to_server,
        .notification = true,
    },
    .{ .name = "ping", .direction = .client_to_server, .notification = false },
    .{ .name = "logging/setLevel", .direction = .client_to_server, .notification = false },
    .{
        .name = "notifications/roots/list_changed",
        .direction = .server_to_client,
        .notification = true,
    },
    .{ .name = "resources/subscribe", .direction = .client_to_server, .notification = false },
    .{ .name = "resources/unsubscribe", .direction = .client_to_server, .notification = false },
    .{
        .name = "notifications/elicitation/complete",
        .direction = .server_to_client,
        .notification = true,
    },
};

/// Look a top-level method up, pinned to a revision.
///
/// A method removed at the current revision is `error.UnknownMethod`, which is
/// the point of pinning a decoder to a revision: a `ping` sent to a
/// `2026-07-28` server is a method-not-found, not a silently accepted no-op.
///
/// The `InputRequest` methods are deliberately not resolved here. A top-level
/// server request is forbidden at `2026-07-28`, so `elicitation/create`,
/// `sampling/createMessage` and `roots/list` are `UnknownMethod` as top-level
/// names even though they are live methods inside `inputRequests`; one entry
/// point for both would hand a caller a request it must not send. This library
/// models those three at no revision, because the source states only where
/// they may appear now.
pub fn lookupMethod(revision: Revision, name: []const u8) DecodeError!MethodInfo {
    for ([_][]const MethodInfo{ &client_requests, &notifications }) |set| {
        for (set) |*info| {
            if (!std.mem.eql(u8, info.name, name)) continue;
            if (!info.present_at_current and revision == .current) {
                return error.UnknownMethod;
            }
            return info.*;
        }
    }
    // A method this revision removed is still a method the previous revision
    // defines, which is what makes two separately decoded revisions worth having
    // rather than a flag.
    if (revision == .previous) {
        for (removed_methods) |removed| {
            if (!std.mem.eql(u8, removed.name, name)) continue;
            return .{
                .name = removed.name,
                .direction = removed.direction,
                .present_at_current = false,
                .deprecated = true,
            };
        }
    }
    return error.UnknownMethod;
}

/// Look a method up as a value inside `InputRequiredResult.inputRequests`.
///
/// These three retain their types at `2026-07-28` after being removed as
/// top-level requests, so they resolve at every revision the library decodes:
/// the removal changed where a server may send them, not what they are.
pub fn lookupInputRequest(name: []const u8) DecodeError!MethodInfo {
    for (input_requests) |info| {
        if (std.mem.eql(u8, info.name, name)) return info;
    }
    return error.UnknownMethod;
}

/// Whether a method is one this library refuses as a top-level method.
///
/// This includes the three `InputRequest` methods: what `2026-07-28` removed
/// is their use at the top level, so a caller gating on this refuses them
/// there and uses [`lookupInputRequest`] inside `inputRequests`.
pub fn isRemovedMethod(name: []const u8) bool {
    for (removed_methods) |removed| {
        if (std.mem.eql(u8, removed.name, name)) return true;
    }
    for (input_requests) |info| {
        if (std.mem.eql(u8, info.name, name)) return true;
    }
    return false;
}

/// Whether a method this library removed at `2026-07-28` was a notification.
///
/// A notification has no `id` and returns no result, so a peer handling a
/// previous-revision method has to know which it is looking at.
pub fn isRemovedNotification(name: []const u8) bool {
    for (removed_methods) |removed| {
        if (std.mem.eql(u8, removed.name, name)) return removed.notification;
    }
    return false;
}

/// Methods contributed by the tasks extension, section 4.8.
pub const tasks_extension_methods = [_][]const u8{
    "tasks/get",
    "tasks/update",
    "tasks/cancel",
    "notifications/tasks",
};

/// Methods contributed by the skills extension, section 4.8.
pub const skills_extension_methods = [_][]const u8{
    "skills/list",
    "skills/get",
    "resources/directory/read",
};

// --- 4.5 Error codes -----------------------------------------------------------

/// MCP's own error codes, in addition to the JSON-RPC standard set.
///
/// The specification renumbered these in the `2026-07-28` draft: `HeaderMismatch`
/// was `-32001`, `MissingRequiredClientCapability` `-32003` and
/// `UnsupportedProtocolVersion` `-32004`. The current values are normative; the
/// old ones are recorded in `renumbered_from` because a peer on the previous
/// revision may still send them.
pub const ErrorCode = enum(i32) {
    header_mismatch = -32020,
    missing_required_client_capability = -32021,
    unsupported_protocol_version = -32022,

    /// Resource-not-found, `-32002` at `2025-11-25` and earlier.
    ///
    /// It became `-32602` at `2026-07-28` to match JSON-RPC. An implementation
    /// of the current revision MUST NOT emit it; a client SHOULD still accept it
    /// from an earlier-version server.
    resource_not_found_legacy = -32002,
    /// URL elicitation required, `-32042`, `2025-11-25` only.
    url_elicitation_required_legacy = -32042,

    pub fn renumberedFrom(self: ErrorCode) ?i32 {
        return switch (self) {
            .header_mismatch => -32001,
            .missing_required_client_capability => -32003,
            .unsupported_protocol_version => -32004,
            else => null,
        };
    }

    pub fn fromCode(code: i32) ?ErrorCode {
        return switch (code) {
            -32020 => .header_mismatch,
            -32021 => .missing_required_client_capability,
            -32022 => .unsupported_protocol_version,
            -32002 => .resource_not_found_legacy,
            -32042 => .url_elicitation_required_legacy,
            else => null,
        };
    }

    /// Whether an implementation of `2026-07-28` may emit this code.
    pub fn emittableAt(self: ErrorCode, revision: Revision) bool {
        return switch (self) {
            .resource_not_found_legacy, .url_elicitation_required_legacy => revision == .previous,
            else => true,
        };
    }
};

/// The implementation-defined range, section 4.5.
///
/// New codes MUST NOT be allocated here, and new implementations SHOULD NOT use
/// it at all. The specification labels it "legacy".
pub const legacy_error_min: i32 = -32000;
pub const legacy_error_max: i32 = -32019;

/// The range the specification allocates its own codes from, allocated
/// sequentially from the bottom.
pub const reserved_error_min: i32 = -32020;
pub const reserved_error_max: i32 = -32099;

// --- 4.6 The result envelope ---------------------------------------------------

/// The `resultType` values the core specification defines, as they appear on
/// the wire.
pub const result_type_value = struct {
    pub const complete = "complete";
    pub const input_required = "input_required";
};

/// The two `resultType` values the core specification defines.
///
/// The generated JSON Schema types `resultType` as a bare string with no enum,
/// so the constraint is normative only in the TypeScript source. A value outside
/// these two is an extension-contributed value and the specification says a
/// client MUST consider it invalid — which is a decision for the caller, not a
/// value this library invents.
pub const KnownResultType = enum {
    /// The request completed and the result holds the final content.
    complete,
    /// The request needs more input; the client answers and retries.
    input_required,
};

/// A `resultType` as it appears on the wire.
///
/// An absent `resultType` is preserved as absent rather than normalised, because
/// a peer on an earlier revision omits it and the client MUST treat that as
/// `complete`.
pub const ResultType = struct {
    /// The wire value, or null when the member was absent.
    value: ?[]const u8 = null,

    /// Parse a `resultType` string.
    pub fn parse(text: []const u8) ResultType {
        return .{ .value = text };
    }

    pub fn known(self: ResultType) ?KnownResultType {
        const value = self.value orelse return .complete;
        if (std.mem.eql(u8, value, result_type_value.complete)) return .complete;
        if (std.mem.eql(u8, value, result_type_value.input_required)) return .input_required;
        return null;
    }

    /// Whether this result is final.
    ///
    /// An absent `resultType` counts as `complete`; an unrecognised one does
    /// not, because the specification requires an unrecognised value to be
    /// treated as invalid rather than guessed at.
    pub fn isComplete(self: ResultType) bool {
        return self.known() == .complete;
    }
};

/// Decode the `resultType` of a result object given as borrowed JSON text.
///
/// "Every result carries `resultType`." An absent member is preserved as
/// absent rather than defaulted, because a peer on an earlier revision omits
/// it and the client MUST treat that as `complete` — a value substituted here
/// would be indistinguishable from one the peer sent, and would be re-encoded
/// as one. An unrecognised value is carried through unvalidated for the same
/// reason: the specification requires the client to consider it invalid, and
/// [`ResultType.known`] is where a caller makes that decision.
pub fn decodeResultType(raw: []const u8, scratch: []u8) DecodeError!ResultType {
    var reader = json.Reader.init(raw);
    var result: ResultType = .{};
    if (try reader.beginObject()) return result;
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "resultType")) {
            result.value = try reader.string(scratch);
        } else {
            try reader.skipValue(scratch);
        }
    }
    return result;
}

/// `cacheScope`, section 4.6.
pub const CacheScope = enum {
    /// No user-specific data; shared intermediaries may cache across
    /// authorization contexts.
    public,
    /// Caches MUST NOT be shared across authorization contexts.
    private,
};

/// The two fields a cacheable result adds, both required.
pub const Cacheable = struct {
    /// Freshness hint in milliseconds. `0` means immediately stale.
    ///
    /// The schema says `@minimum 0` and PROTOCOLS.md section 4.6 fixes the
    /// field at `u64`, which has no representation for a negative count of
    /// milliseconds, so [`decodeCacheable`] rejects one rather than
    /// substituting `0`. The normative client rule — ignore a negative value
    /// and treat it as `0` — is a SHOULD about caching, not a claim that the
    /// value is representable, and honouring it here would mean fabricating a
    /// number the server did not send.
    ttl_ms: u64,
    cache_scope: CacheScope,
};

/// Decode the `cacheScope` literal.
pub fn parseCacheScope(text: []const u8) DecodeError!CacheScope {
    if (std.mem.eql(u8, text, "public")) return .public;
    if (std.mem.eql(u8, text, "private")) return .private;
    return error.UnknownTag;
}

/// Decode the two fields a cacheable result adds; both are required.
///
/// `raw` is the `result` object as borrowed JSON text. Members the caching
/// rules do not govern are skipped rather than rejected, so this composes with
/// [`decodeResultType`] rather than replacing it.
pub fn decodeCacheable(raw: []const u8, scratch: []u8) DecodeError!Cacheable {
    var reader = json.Reader.init(raw);
    var ttl_ms: ?u64 = null;
    var cache_scope: ?CacheScope = null;

    if (try reader.beginObject()) return error.MissingField;
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "ttlMs")) {
            ttl_ms = try parseMilliseconds(try reader.number());
        } else if (std.mem.eql(u8, key, "cacheScope")) {
            cache_scope = try parseCacheScope(try reader.string(scratch));
        } else {
            try reader.skipValue(scratch);
        }
    }

    // "Cacheable results add two required fields."
    return .{
        .ttl_ms = ttl_ms orelse return error.MissingField,
        .cache_scope = cache_scope orelse return error.MissingField,
    };
}

/// Parse a JSON number lexeme as a whole number of milliseconds.
///
/// The lexeme is borrowed from the input, so nothing is copied. A fraction, an
/// exponent or a sign is not a whole number of milliseconds, and the field is
/// declared `u64`, so each of those is `InvalidField` rather than a silent
/// truncation of something the server sent.
fn parseMilliseconds(lexeme: []const u8) DecodeError!u64 {
    if (lexeme.len == 0) return error.InvalidField;
    if (lexeme[0] == '-') return error.InvalidField;
    for (lexeme) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidField;
    }
    // Only an overflow can fail here, and a millisecond count that does not fit
    // in 64 bits is a number the schema does not describe.
    return std.fmt.parseInt(u64, lexeme, 10) catch error.InvalidField;
}

// --- 4.7 Multi round-trip requests ----------------------------------------------

/// A decoded `InputRequiredResult`.
///
/// At least one of `input_requests` or `request_state` MUST be present; a result
/// with neither is `error.MissingField`.
pub const InputRequiredResult = struct {
    /// `input_required` when the peer sent it, and absent when it did not.
    ///
    /// A default of `input_required` would be indistinguishable from a wire
    /// value and would be re-encoded as one. A result from a peer on an earlier
    /// revision omits `resultType` and the client MUST treat that as
    /// `complete`, so the decoder records the absence and lets
    /// [`ResultType.known`] apply that rule.
    result_type: ResultType = ResultType{},
    /// The server-assigned request map, as borrowed JSON text.
    ///
    /// The decoder does not walk the map, does not validate an inner `method`,
    /// and does not check that the member is a JSON object at all, so
    /// `"inputRequests": []` decodes as readily as an object does. A consumer
    /// that needs a method name checked reads it itself and refuses a name
    /// outside the three with [`lookupInputRequest`], which answers
    /// `error.UnknownMethod`.
    input_requests: ?[]const u8 = null,
    /// Opaque, and attacker-controlled.
    ///
    /// The specification requires a server to integrity-protect this whenever it
    /// influences authorization, so a client that parses its contents is already
    /// outside the contract. The library carries it and never interprets it.
    request_state: ?[]const u8 = null,
};

/// Decode the members of an `InputRequiredResult`.
///
/// `raw` is the `result` object as borrowed JSON text. The caller has already
/// established from the JSON-RPC layer that this is a response, so this reads
/// the members the MRTR rules constrain and skips the rest.
pub fn decodeInputRequiredResult(
    raw: []const u8,
    scratch: []u8,
) DecodeError!InputRequiredResult {
    var reader = json.Reader.init(raw);
    var result: InputRequiredResult = .{};

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "resultType")) {
            const text = try reader.string(scratch);
            if (!std.mem.eql(u8, text, result_type_value.input_required)) return error.InvalidField;
            result.result_type = ResultType.parse(text);
        } else if (std.mem.eql(u8, key, "inputRequests")) {
            result.input_requests = try reader.rawValue(scratch);
        } else if (std.mem.eql(u8, key, "requestState")) {
            result.request_state = try reader.string(scratch);
        } else {
            try reader.skipValue(scratch);
        }
    }

    // "At least one of inputRequests or requestState MUST be present."
    if (result.input_requests == null and result.request_state == null) {
        return error.MissingField;
    }
    return result;
}

/// The methods that may return an `InputRequiredResult`.
///
/// `prompts/get`, `resources/read` and `tools/call` only. A server that sends
/// one for any other request is violating the specification, so this is a
/// predicate rather than a comment.
pub fn permitsMrtr(method: []const u8) bool {
    return std.mem.eql(u8, method, "prompts/get") or
        std.mem.eql(u8, method, "resources/read") or
        std.mem.eql(u8, method, "tools/call");
}

// --- 4.8 Capabilities and extensions --------------------------------------------

/// Official extension identifiers, section 4.8.
pub const extension_id = struct {
    pub const ui = "io.modelcontextprotocol/ui";
    pub const tasks = "io.modelcontextprotocol/tasks";
    pub const skills = "io.modelcontextprotocol/skills";
    pub const oauth_client_credentials = "io.modelcontextprotocol/oauth-client-credentials";
    pub const enterprise_managed_authorization = "io.modelcontextprotocol/enterprise-managed-authorization";
};

/// URI schemes and media types, section 4.8.
pub const uri_and_media = struct {
    pub const ui_scheme = "ui://";
    pub const skill_scheme = "skill://";
    pub const ui_mime_type = "text/html;profile=mcp-app";
    pub const skill_digest_prefix = "sha256:";
    pub const skill_digest_hex_length = 64;
    pub const json_media_type = "application/json";
    pub const event_stream_media_type = "text/event-stream";
    pub const directory_media_type = "inode/directory";
    pub const json_schema_dialect = "https://json-schema.org/draft/2020-12/schema";
};

/// The `ContentBlock` discriminator literals.
///
/// These are structural strings rather than media types, which is why they are
/// their own constant group.
pub const content_block_type = struct {
    pub const text = "text";
    pub const image = "image";
    pub const audio = "audio";
    pub const resource_link = "resource_link";
    pub const resource = "resource";
};

/// The `ElicitResult.action` values.
pub const elicit_action = struct {
    pub const accept = "accept";
    pub const decline = "decline";
    pub const cancel = "cancel";
};

/// The `Role` values.
pub const role = struct {
    pub const user = "user";
    pub const assistant = "assistant";
};

/// Reference discriminator literals.
pub const reference_type = struct {
    pub const resource = "ref/resource";
    pub const prompt = "ref/prompt";
};

// --- 4.9 Deprecated feature registry -------------------------------------------

/// A feature present in the specification and not to be adopted.
///
/// Earliest removal is the first revision released on or after `2027-07-28`,
/// with a 90-day floor on any expedited removal. No feature has reached the
/// Removed state.
pub const DeprecatedFeature = enum {
    roots,
    sampling,
    logging,
    dynamic_client_registration,
    http_sse_transport,
    include_context_server_values,

    /// The earliest revision at which a deprecated feature may be removed.
    pub fn deprecationFloorRevision() []const u8 {
        return "2027-07-28";
    }

    /// The floor on any expedited removal, in days.
    pub fn expeditedRemovalFloorDays() u32 {
        return 90;
    }
};

// --- 4.5 version-dependent behaviour --------------------------------------------

/// Whether a decoder pinned to `revision` accepts the resource-not-found code.
///
/// The code moved from `-32002` to `-32602` at `2026-07-28` to match JSON-RPC.
/// A decoder pinned to `2025-11-25` accepts `-32002`; one pinned to
/// `2026-07-28` does not.
pub fn acceptsResourceNotFound(revision: Revision, code: i32) bool {
    return switch (revision) {
        .previous => code == -32002 or code == -32602,
        .current => code == -32602,
    };
}

/// A `sha256:` skill digest: exactly 64 lowercase hex digits after the prefix.
pub fn isValidSkillDigest(digest: []const u8) bool {
    const prefix = uri_and_media.skill_digest_prefix;
    if (!std.mem.startsWith(u8, digest, prefix)) return false;
    const hex = digest[prefix.len..];
    if (hex.len != uri_and_media.skill_digest_hex_length) return false;
    for (hex) |byte| {
        const ok = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!ok) return false;
    }
    return true;
}

// Base64 with `=` padding, which is the form the sentinel carries.
const base64 = struct {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    fn valueOf(byte: u8) ?u8 {
        return switch (byte) {
            'A'...'Z' => byte - 'A',
            'a'...'z' => byte - 'a' + 26,
            '0'...'9' => byte - '0' + 52,
            '+' => 62,
            '/' => 63,
            else => null,
        };
    }

    fn encode(input: []const u8, output: []u8) ![]const u8 {
        var out: usize = 0;
        var index: usize = 0;
        while (index + 3 <= input.len) : (index += 3) {
            const chunk = std.mem.readInt(u24, input[index..][0..3], .big);
            if (out + 4 > output.len) return error.BufferTooSmall;
            output[out] = alphabet[(chunk >> 18) & 0x3f];
            output[out + 1] = alphabet[(chunk >> 12) & 0x3f];
            output[out + 2] = alphabet[(chunk >> 6) & 0x3f];
            output[out + 3] = alphabet[chunk & 0x3f];
            out += 4;
        }
        // The final partial group is padded, because a decoder groups four
        // characters at a time and an unpadded tail is a length error.
        const rest = input.len - index;
        if (rest == 1) {
            const chunk: u32 = @as(u32, input[index]) << 16;
            if (out + 4 > output.len) return error.BufferTooSmall;
            output[out] = alphabet[(chunk >> 18) & 0x3f];
            output[out + 1] = alphabet[(chunk >> 12) & 0x3f];
            output[out + 2] = '=';
            output[out + 3] = '=';
            out += 4;
        } else if (rest == 2) {
            const chunk: u32 = @as(u32, input[index]) << 16 |
                @as(u32, input[index + 1]) << 8;
            if (out + 4 > output.len) return error.BufferTooSmall;
            output[out] = alphabet[(chunk >> 18) & 0x3f];
            output[out + 1] = alphabet[(chunk >> 12) & 0x3f];
            output[out + 2] = alphabet[(chunk >> 6) & 0x3f];
            output[out + 3] = '=';
            out += 4;
        }
        return output[0..out];
    }

    fn decode(input: []const u8, output: []u8) ![]const u8 {
        if (input.len % 4 != 0) return error.InvalidField;
        var out: usize = 0;
        var index: usize = 0;
        while (index < input.len) : (index += 4) {
            const quad = input[index..][0..4];
            var bits: u32 = 0;
            var count: usize = 0;
            for (quad, 0..) |byte, position| {
                if (byte == '=') break;
                const digit = valueOf(byte) orelse return error.InvalidField;
                bits |= @as(u32, digit) << @intCast(18 - 6 * position);
                count += 1;
            }
            // A quad carries at least two digits. One digit is not a whole
            // byte, and a quad that opens with `=` carries none at all, so
            // `count - 1` below would underflow a `usize`.
            if (count < 2) return error.InvalidField;
            const produced: usize = if (count == 4) 3 else count - 1;
            if (out + produced > output.len) return error.BufferTooSmall;
            for (0..produced) |offset| {
                output[out + offset] = @truncate(bits >> @intCast(16 - 8 * offset));
            }
            out += produced;
        }
        return output[0..out];
    }
};

const testing = std.testing;

test "revision round-trips through its wire string" {
    try testing.expectEqual(Revision.current, Revision.fromString("2026-07-28").?);
    try testing.expectEqual(Revision.previous, Revision.fromString("2025-11-25").?);
    try testing.expectEqual(@as(?Revision, null), Revision.fromString("2025-06-18"));
    try testing.expectEqualStrings("2026-07-28", Revision.current.string());
}

test "the client request inventory has exactly the 10 core members" {
    try testing.expectEqual(@as(usize, 10), client_requests.len);
    for (client_requests) |info| {
        try testing.expect(info.present_at_current);
        try testing.expectEqual(Direction.client_to_server, info.direction);
    }
}

/// Whether `set` holds exactly the members `expected` names.
///
/// Both directions, so a duplicate in either list fails too. The inventories are
/// transcribed from PROTOCOLS.md section 4.4, and a count cannot check that: a
/// renamed method, a dropped one, and a dropped one paired with a filler all
/// leave the count standing and all break a peer that answers to the name in the
/// document.
fn namesAre(set: []const MethodInfo, expected: []const []const u8) bool {
    if (set.len != expected.len) return false;
    for (expected) |name| {
        var found = false;
        for (set) |info| {
            if (std.mem.eql(u8, info.name, name)) found = true;
        }
        if (!found) return false;
    }
    for (set) |info| {
        if (!contains(expected, info.name)) return false;
    }
    return true;
}

fn contains(expected: []const []const u8, needle: []const u8) bool {
    for (expected) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

/// Whether `namespace` declares a member whose value is `key`.
fn declaresKey(comptime namespace: type, key: []const u8) bool {
    inline for (@typeInfo(namespace).@"struct".decls) |decl| {
        if (std.mem.eql(u8, @field(namespace, decl.name), key)) return true;
    }
    return false;
}

test "the client request inventory names exactly the methods section 4.4 lists" {
    // PROTOCOLS.md section 4.4 is the authority, and its client-to-server group
    // is these ten names in its own row order, so a reader who edits that table
    // edits this literal in the same direction. A count is not a check on a
    // transcription: a renamed method, a dropped one, and a dropped one paired
    // with a filler all leave the count standing.
    try testing.expect(namesAre(
        &client_requests,
        &[_][]const u8{
            "server/discover",
            "tools/list",
            "tools/call",
            "resources/list",
            "resources/read",
            "resources/templates/list",
            "prompts/list",
            "prompts/get",
            "completion/complete",
            "subscriptions/listen",
        },
    ));
}

test "the notification inventory names exactly the methods section 4.4 lists" {
    // The same check on the notification group: the seven server-to-client rows
    // and the one `both` row, in the document's row order.
    try testing.expect(namesAre(
        &notifications,
        &[_][]const u8{
            "notifications/progress",
            "notifications/message",
            "notifications/cancelled",
            "notifications/resources/updated",
            "notifications/resources/list_changed",
            "notifications/tools/list_changed",
            "notifications/prompts/list_changed",
            "notifications/subscriptions/acknowledged",
        },
    ));
}

test "each notification carries the direction section 4.4 states" {
    // The names are pinned above, so a row that turns one-way from the
    // document's `both`, or a server-to-client row that turns client-to-server,
    // fails here. The client-to-server group needs no equivalent: the inventory
    // test above asserts every one of its rows already.
    for (notifications) |info| {
        const expected: Direction = if (std.mem.eql(u8, info.name, "notifications/cancelled"))
            .bidirectional
        else
            .server_to_client;
        try testing.expectEqual(expected, info.direction);
    }
}

test "the cacheable rows are the six section 4.4 marks" {
    // Transcribed from the Notes column, which marks exactly six results
    // "Cacheable result". The one mandatory method is already pinned by name and
    // by exclusion in the test above, so this covers the flag nothing checks
    // yet: a row that loses the mark, or gains one the document does not carry,
    // fails here.
    const cacheable = [_][]const u8{
        "server/discover",
        "tools/list",
        "resources/list",
        "resources/read",
        "resources/templates/list",
        "prompts/list",
    };
    for (client_requests) |info| {
        try testing.expectEqual(contains(&cacheable, info.name), info.cacheable);
    }
}

test "the _meta key set is exactly the ten keys section 4.3 lists" {
    // Transcribed from PROTOCOLS.md section 4.3, the authority, in its row order.
    // The document's row order is not the declaration order, so this compares the
    // set in both directions rather than row by row. A reader who edits section
    // 4.3 edits this literal in the same direction.
    const keys = [_][]const u8{
        "io.modelcontextprotocol/protocolVersion",
        "io.modelcontextprotocol/clientCapabilities",
        "io.modelcontextprotocol/clientInfo",
        "io.modelcontextprotocol/serverInfo",
        "io.modelcontextprotocol/logLevel",
        "io.modelcontextprotocol/subscriptionId",
        "traceparent",
        "tracestate",
        "baggage",
        "progressToken",
    };
    // Every member the table declares is a key the document lists. `meta_key` is
    // a namespace of reserved keys and nothing else, so a declaration that is not
    // one is a fault here rather than an addition.
    inline for (@typeInfo(meta_key).@"struct".decls) |decl| {
        try testing.expect(contains(&keys, @field(meta_key, decl.name)));
    }
    // And every key the document lists is one the table declares.
    for (keys) |key| {
        try testing.expect(declaresKey(meta_key, key));
    }
    try testing.expectEqual(keys.len, @typeInfo(meta_key).@"struct".decls.len);
}

test "lookupMethod accepts every core client request at the current revision" {
    for (client_requests) |info| {
        const found = try lookupMethod(.current, info.name);
        try testing.expectEqualStrings(info.name, found.name);
    }
}

test "a removed method is UnknownMethod at the current revision" {
    for (removed_methods) |removed| {
        try testing.expectError(error.UnknownMethod, lookupMethod(.current, removed.name));
        try testing.expect(isRemovedMethod(removed.name));
    }
    // A `ping` is a live method on the previous revision, which is the whole
    // reason a decoder is pinned rather than switched by a flag.
    try testing.expectEqualStrings(
        "ping",
        (try lookupMethod(.previous, "ping")).name,
    );
}

test "a removed method keeps the direction it had, not the one its name implies" {
    // A `notifications/` prefix says nothing about which side sends a message.
    // The handshake notification travels client to server, and deriving the
    // direction from the prefix sends a previous-revision peer's notification
    // the wrong way.
    const initialized = try lookupMethod(.previous, "notifications/initialized");
    try testing.expectEqual(Direction.client_to_server, initialized.direction);

    // A notification returns nothing, so a peer has to know which it is.
    try testing.expect(isRemovedNotification("notifications/initialized"));
    try testing.expect(isRemovedNotification("notifications/roots/list_changed"));
    try testing.expect(!isRemovedNotification("initialize"));
    try testing.expect(!isRemovedNotification("logging/setLevel"));
    try testing.expect(!isRemovedNotification("tools/call"));
}

test "an InputRequest method resolves inside inputRequests and nowhere else" {
    for (input_requests) |info| {
        // The three retain their types, so they resolve as carried values at
        // every revision the library decodes.
        const carried = try lookupInputRequest(info.name);
        try testing.expectEqualStrings(info.name, carried.name);
        try testing.expectEqual(info.direction, carried.direction);

        // What was removed is their use as top-level names.
        try testing.expectError(error.UnknownMethod, lookupMethod(.current, info.name));
        try testing.expectError(error.UnknownMethod, lookupMethod(.previous, info.name));
        try testing.expect(isRemovedMethod(info.name));
    }
    // The InputRequest table is not a second top-level registry.
    try testing.expectError(error.UnknownMethod, lookupInputRequest("initialize"));
    try testing.expectError(error.UnknownMethod, lookupInputRequest("tools/call"));
}

test "server-initiated requests are MRTR-only, never top level" {
    try testing.expectEqual(
        Direction.server_to_client_mrtr_only,
        (try lookupInputRequest("elicitation/create")).direction,
    );
    try testing.expectEqual(@as(usize, 3), input_requests.len);
    // Only three client requests may answer with an InputRequiredResult.
    var permitting: usize = 0;
    for (client_requests) |info| {
        if (permitsMrtr(info.name)) permitting += 1;
    }
    try testing.expectEqual(@as(usize, 3), permitting);
}

test "permitsMrtr and the mrtr flag agree on every client request" {
    // PROTOCOLS.md 4.7 names three methods whose result may be interim, and
    // `permitsMrtr` and the `.mrtr` flag are two transcriptions of that one
    // sentence. A caller that applies one and not the other applies half a rule,
    // and the count above cannot tell the two apart: dropping the flag from a
    // row the predicate still approves leaves that count standing. Pinning them
    // row for row is what makes the predicate usable as the single gate.
    for (client_requests) |info| {
        try testing.expectEqual(info.mrtr, permitsMrtr(info.name));
    }
    // The three the document names, and no fourth. The count below is over the
    // flag rather than over the predicate, so it fails once the two disagree.
    for ([_][]const u8{ "tools/call", "resources/read", "prompts/get" }) |name| {
        try testing.expect(permitsMrtr(name));
    }
    var flagged: usize = 0;
    for (client_requests) |info| {
        if (info.mrtr) flagged += 1;
    }
    try testing.expectEqual(@as(usize, 3), flagged);

    // `lookupMethod` searches the notification table too and `respond` will gate
    // on whatever method it was handed, and the document names no notification
    // as one that may return an interim result, so neither the predicate nor the
    // flag may answer true for a row of that table.
    for (notifications) |info| {
        try testing.expect(!permitsMrtr(info.name));
        try testing.expect(!info.mrtr);
    }
}

test "server/discover is the only mandatory method" {
    const mandatory = mandatoryMethods(.current);
    try testing.expectEqual(@as(usize, 1), mandatory.len);
    try testing.expectEqualStrings("server/discover", mandatory[0].name);
    try testing.expect(mandatory[0].mandatory);

    // Every other member leaves the flag at its default rather than restating
    // it, so a second mandatory method has to be added deliberately.
    for (client_requests) |info| {
        if (std.mem.eql(u8, info.name, "server/discover")) continue;
        try testing.expect(!info.mandatory);
    }
    for (notifications) |info| {
        try testing.expect(!info.mandatory);
    }

    // The source states the mandatory set for 2026-07-28 only, so the previous
    // revision reports none rather than an invented one.
    try testing.expectEqual(@as(usize, 0), mandatoryMethods(.previous).len);
}

test "an unknown method name is UnknownMethod, never a default" {
    try testing.expectError(error.UnknownMethod, lookupMethod(.current, "tools/nope"));
    try testing.expectError(error.UnknownMethod, lookupMethod(.previous, "server/discover/extra"));
}

test "header classification is case-insensitive across both spellings" {
    // The specification writes this one all-caps and the rest title-case. A
    // table keyed on one casing would drop the other.
    try testing.expectEqual(HeaderKind.protocol_version, headerKind("MCP-Protocol-Version"));
    try testing.expectEqual(HeaderKind.protocol_version, headerKind("mcp-protocol-version"));
    try testing.expectEqual(HeaderKind.protocol_version, headerKind("Mcp-Protocol-Version"));
    try testing.expectEqual(HeaderKind.method, headerKind("Mcp-Method"));
    try testing.expectEqual(HeaderKind.method, headerKind("mcp-method"));
    try testing.expectEqual(HeaderKind.name, headerKind("Mcp-Name"));
    try testing.expectEqual(HeaderKind.param, headerKind("Mcp-Param-city"));
    // A bare `Mcp-Param-` names no annotation, and the annotation name must be
    // a non-empty token, so none of these are derived headers.
    try testing.expectEqual(HeaderKind.other, headerKind("Mcp-Param-"));
    try testing.expectEqual(HeaderKind.other, headerKind("mcp-param-"));
    try testing.expectEqual(HeaderKind.other, headerKind("Mcp-Param- "));
    try testing.expectEqual(HeaderKind.other, headerKind("Mcp-Param-\r"));
    try testing.expectEqual(HeaderKind.schema_keyword, headerKind("x-mcp-header"));
}

test "removed headers are classified so a caller can ignore them" {
    try testing.expectEqual(HeaderKind.session_id_removed, headerKind("Mcp-Session-Id"));
    try testing.expectEqual(HeaderKind.last_event_id_removed, headerKind("Last-Event-ID"));
}

test "the base64 sentinel is detected only in its exact case-sensitive spelling" {
    try testing.expect(isSentinelEncoded("=?base64?aGk=?="));
    try testing.expect(!isSentinelEncoded("=?BASE64?aGk=?="));
    try testing.expect(!isSentinelEncoded("=?base64?aGk="));
    try testing.expect(!isSentinelEncoded("plain"));
}

test "a sentinel-encoded header value decodes back to its plaintext" {
    var scratch: [64]u8 = undefined;
    // "hi" in standard base64.
    const encoded = "=?base64?aGk=?=";
    try testing.expectEqualStrings("hi", try decodeHeaderValue(encoded, &scratch));
    // A plain value is returned borrowed, without touching scratch.
    try testing.expectEqualStrings("plain", try decodeHeaderValue("plain", &scratch));
}

test "a value of every length mod 3 round-trips through the sentinel" {
    // A one- or two-byte final group is padded with `=`, and a decoder that
    // groups four characters at a time rejects an unpadded tail. Lengths 3 and 6
    // need no padding, so a case covering only those would not catch it.
    var scratch: [64]u8 = undefined;

    // Non-ASCII forces the sentinel, which is the path that exercises base64.
    for ([_][]const u8{ "é", "éé", "ééé", "éééé", "ééééé" }) |value| {
        var buffer: [128]u8 = undefined;
        var digits: [32]u8 = undefined;
        var writer = json.Writer.init(&buffer);
        try encodeHeaderValue(value, &writer, &digits);
        const emitted = writer.written();
        try testing.expect(isSentinelEncoded(emitted));
        try testing.expectEqualStrings(value, try decodeHeaderValue(emitted, &scratch));
    }

    // Plain ASCII needs no sentinel and is passed through, so the round trip
    // has to hold for the unwrapped case too.
    for ([_][]const u8{ "a", "ab", "abc", "abcd", "abcde", "abcdef", "abcdefg" }) |value| {
        var buffer: [128]u8 = undefined;
        var digits: [32]u8 = undefined;
        var writer = json.Writer.init(&buffer);
        try encodeHeaderValue(value, &writer, &digits);
        try testing.expect(!isSentinelEncoded(writer.written()));
        try testing.expectEqualStrings(value, try decodeHeaderValue(writer.written(), &scratch));
    }
}

test "a non-ASCII header value round-trips through the sentinel" {
    // Seven bytes, so this is the padded case as well.
    var scratch: [64]u8 = undefined;
    var buffer: [128]u8 = undefined;
    var digits: [32]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeHeaderValue("Zürich", &writer, &digits);
    const emitted = writer.written();
    try testing.expect(std.mem.startsWith(u8, emitted, "=?base64?"));
    try testing.expectEqualStrings("Zürich", try decodeHeaderValue(emitted, &scratch));
}

test "a value needing the sentinel is wrapped, and round-trips" {
    var scratch: [64]u8 = undefined;

    var buffer: [128]u8 = undefined;
    var digits: [32]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeHeaderValue("héllo", &writer, &digits);
    const emitted = writer.written();
    // A header value is raw text, so the output carries no JSON quoting. A
    // quoted value would be a different value on the wire.
    try testing.expect(std.mem.startsWith(u8, emitted, "=?base64?"));
    try testing.expect(std.mem.endsWith(u8, emitted, "?="));
    try testing.expectEqualStrings("héllo", try decodeHeaderValue(emitted, &scratch));
}

test "an ASCII value matching the sentinel pattern is still encoded" {
    // The specification requires clients to encode such a value, so a server
    // must not be the one deciding it is harmless.
    var buffer: [64]u8 = undefined;
    var digits: [32]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeHeaderValue("=?base64?x?=", &writer, &digits);
    try testing.expect(std.mem.indexOf(u8, writer.written(), "=?base64?") != null);
}

test "a scratch buffer too small to decode is the caller's error, not a bad header" {
    // "hi" decodes to two bytes, so a one-byte buffer is a caller-side sizing
    // mistake. Reporting it as InvalidField would tell the caller the peer sent
    // a malformed value, which is a different failure with a different fix.
    var tiny: [1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, decodeHeaderValue("=?base64?aGk=?=", &tiny));

    // A value that is not base64 at all is still the peer's error.
    try testing.expectError(error.InvalidField, decodeHeaderValue("=?base64?aGk?aGk=?=", &tiny));
}

test "a sentinel body that opens with padding is rejected, not trapped" {
    var scratch: [64]u8 = undefined;

    // The body is four padding bytes, so the quad carries no digit at all and
    // one byte fewer than the quad holds underflows a `usize`. Without the
    // guard this traps, and every byte of a header value is a peer's choice,
    // so one header takes a server task down.
    try testing.expect(isSentinelEncoded("=?base64?====?="));
    try testing.expectError(error.InvalidField, decodeHeaderValue("=?base64?====?=", &scratch));

    // The same fault on a later quad, after a byte has already been produced,
    // so a check that ran only on the first quad would let this through.
    try testing.expectError(error.InvalidField, decodeHeaderValue("=?base64?aGk==AAA?=", &scratch));

    // One digit then padding is the other degenerate count, and it carries no
    // whole byte either.
    try testing.expectError(error.InvalidField, decodeHeaderValue("=?base64?A===?=", &scratch));
}

test "the caller sizes the base64 scratch, so a long value still encodes" {
    // 600 bytes of non-UTF-8, so the sentinel path runs and the base64 output
    // is 800 characters: past what a fixed internal buffer could have held.
    var value: [600]u8 = undefined;
    @memset(&value, 0x80);
    var digits: [sentinelScratchLen(value.len)]u8 = undefined;
    var buffer: [1024]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeHeaderValue(&value, &writer, &digits);
    const emitted = writer.written();
    try testing.expect(isSentinelEncoded(emitted));
    try testing.expectEqualStrings(&value, try decodeHeaderValue(emitted, &digits));

    // The same value with a scratch one base64 group short names the shortfall
    // rather than emitting a truncated header.
    var short: [4]u8 = undefined;
    var other: [64]u8 = undefined;
    var other_writer = json.Writer.init(&other);
    try testing.expectError(error.BufferTooSmall, encodeHeaderValue(&value, &other_writer, &short));
    try testing.expectEqual(@as(usize, 0), other_writer.written().len);
}

test "a header that disagrees with the body is the HeaderMismatch condition" {
    var scratch: [64]u8 = undefined;

    // A plain value compares as itself, so the mismatch a server rejects is the
    // same condition the client avoids by sending both copies alike.
    try testing.expect(try headerMatchesBody("Zürich", "Zürich", &scratch));
    try testing.expect(!try headerMatchesBody("Zürich", "Zurich", &scratch));

    // A sentinel-encoded value is compared decoded, which is the decoding the
    // specification requires before rejecting.
    var digits: [sentinelScratchLen("Zürich".len)]u8 = undefined;
    var buffer: [64]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodeHeaderValue("Zürich", &writer, &digits);
    try testing.expect(try headerMatchesBody(writer.written(), "Zürich", &scratch));
    try testing.expect(!try headerMatchesBody(writer.written(), "Bern", &scratch));

    // The caller's own sizing error still surfaces as itself.
    var tiny: [1]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        headerMatchesBody(writer.written(), "Zürich", &tiny),
    );
}

test "x-mcp-header name validation enforces token syntax" {
    try testing.expect(isValidSchemaHeaderName("city"));
    try testing.expect(isValidSchemaHeaderName("X-City"));
    try testing.expect(isValidSchemaHeaderName("x-1"));
    try testing.expect(!isValidSchemaHeaderName(""));
    try testing.expect(!isValidSchemaHeaderName("has space"));
    try testing.expect(!isValidSchemaHeaderName("has\rreturn"));
    try testing.expect(!isValidSchemaHeaderName("has\nnewline"));
    try testing.expect(!isValidSchemaHeaderName("colon:"));
}

test "x-mcp-header names are case-insensitively unique within one inputSchema" {
    const distinct = [_][]const u8{ "city", "unit", "X-Trace" };
    try testing.expect(areSchemaHeaderNamesUnique(&distinct));
    try testing.expect(areSchemaHeaderNamesUnique(&[_][]const u8{}));
    try testing.expect(areSchemaHeaderNamesUnique(&[_][]const u8{"only"}));

    // Case does not make a second annotation a different one, so a schema with
    // both spellings of one name is not conformant.
    const clashing = [_][]const u8{ "city", "City" };
    try testing.expect(!areSchemaHeaderNamesUnique(&clashing));
    try testing.expect(!areSchemaHeaderNamesUnique(&[_][]const u8{ "a", "b", "A" }));
}

test "the x-mcp-header integer range matches the stated 53-bit bound" {
    try testing.expect(isValidHeaderInteger(0));
    try testing.expect(isValidHeaderInteger(header_integer_max));
    try testing.expect(isValidHeaderInteger(header_integer_min));
    try testing.expect(!isValidHeaderInteger(header_integer_max + 1));
    try testing.expect(!isValidHeaderInteger(header_integer_min - 1));
}

test "the derived header name is the prefix followed by the annotation" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "Mcp-Param-city",
        try deriveParamHeaderName("city", &buffer),
    );
    // The prefix is `Mcp-Param-`, ten bytes, so a four-character annotation
    // needs fourteen.
    try testing.expectEqual(@as(usize, 14), paramHeaderNameLen("city".len));

    // The annotation becomes part of a header name, so a name that is not a
    // field-name token cannot become one.
    try testing.expectError(
        error.InvalidField,
        deriveParamHeaderName("has space", &buffer),
    );

    var short: [4]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        deriveParamHeaderName("city", &short),
    );
}

test "the primitive-type gate admits integer, string and boolean only" {
    try testing.expectEqual(ParamType.string, ParamType.fromSchemaType("string"));
    try testing.expectEqual(ParamType.integer, ParamType.fromSchemaType("integer"));
    try testing.expectEqual(ParamType.boolean, ParamType.fromSchemaType("boolean"));
    try testing.expectEqual(ParamType.number, ParamType.fromSchemaType("number"));
    try testing.expectEqual(ParamType.array, ParamType.fromSchemaType("array"));
    try testing.expectEqual(ParamType.object, ParamType.fromSchemaType("object"));
    try testing.expectEqual(ParamType.null_type, ParamType.fromSchemaType("null"));
    // A type name is not case-insensitive, and one this library does not know
    // is not a primitive type it may pass.
    try testing.expectEqual(ParamType.unstated, ParamType.fromSchemaType("String"));

    for ([_]ParamType{ .string, .integer, .boolean }) |param_type| {
        try testing.expect(isBindableParamType(param_type));
    }
    for ([_]ParamType{ .number, .array, .object, .null_type, .unstated }) |param_type| {
        try testing.expect(!isBindableParamType(param_type));
    }
}

test "only a properties chain keeps an annotated property reachable" {
    try testing.expect(isStaticallyReachable(&.{}));
    try testing.expect(isStaticallyReachable(&.{ .properties, .properties }));

    for ([_]SchemaStep{ .array_keyword, .composition, .conditional, .ref }) |step| {
        try testing.expect(!isStaticallyReachable(&[_]SchemaStep{step}));
        try testing.expect(!isStaticallyReachable(&[_]SchemaStep{ .properties, step }));
    }
}

test "an annotation that breaks a rule names that rule" {
    const legal: Annotation = .{ .name = "city", .param_type = .string };
    try checkAnnotation(legal);
    try testing.expect(legal.isConformant());

    // The name must be a non-empty field-name token.
    try testing.expectError(
        error.InvalidName,
        checkAnnotation(.{ .name = "", .param_type = .string }),
    );
    try testing.expectError(
        error.InvalidName,
        checkAnnotation(.{ .name = "has space", .param_type = .string }),
    );

    // Case does not make a second annotation a different one.
    try testing.expectError(error.DuplicateName, checkAnnotation(.{
        .name = "City",
        .param_type = .string,
        .siblings = &.{"city"},
    }));

    // A number is named out by the specification, and the rest are not
    // primitives.
    try testing.expectError(
        error.NotPrimitive,
        checkAnnotation(.{ .name = "ratio", .param_type = .number }),
    );
    try testing.expectError(
        error.NotPrimitive,
        checkAnnotation(.{ .name = "rows", .param_type = .array }),
    );

    // Reachable but behind a `$ref` is not statically reachable.
    try testing.expectError(error.Unreachable, checkAnnotation(.{
        .name = "count",
        .param_type = .integer,
        .chain = &.{ .properties, .ref },
    }));
}

test "a parameter value renders the way a header carries it" {
    var out: [param_value_max_len]u8 = undefined;

    // A string travels as it was given, and nothing is written to the buffer.
    @memset(&out, 'x');
    try testing.expectEqualStrings(
        "Zürich",
        try renderParamValue(.{ .string_value = "Zürich" }, &out),
    );
    try testing.expectEqual(@as(u8, 'x'), out[0]);

    // A boolean becomes the lowercase literal, never `True` or `1`.
    try testing.expectEqualStrings("true", try renderParamValue(.{ .boolean = true }, &out));
    try testing.expectEqualStrings("false", try renderParamValue(.{ .boolean = false }, &out));

    // An integer becomes a plain decimal: no exponent, no padding, and one
    // digit for zero.
    try testing.expectEqualStrings("0", try renderParamValue(.{ .integer = 0 }, &out));
    try testing.expectEqualStrings("7", try renderParamValue(.{ .integer = 7 }, &out));
    try testing.expectEqualStrings("-7", try renderParamValue(.{ .integer = -7 }, &out));
    try testing.expectEqualStrings(
        "9007199254740991",
        try renderParamValue(.{ .integer = header_integer_max }, &out),
    );
    try testing.expectEqualStrings(
        "-9007199254740991",
        try renderParamValue(.{ .integer = header_integer_min }, &out),
    );

    // The magnitude never negates a value that has no positive counterpart,
    // so both ends of the signed range render rather than trapping.
    try testing.expectEqualStrings(
        "9223372036854775807",
        try renderParamValue(.{ .integer = 9223372036854775807 }, &out),
    );
    try testing.expectEqualStrings(
        "-9223372036854775808",
        try renderParamValue(.{ .integer = -9223372036854775808 }, &out),
    );

    // A buffer one byte short of the widest decimal names the shortfall.
    var short: [3]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        renderParamValue(.{ .integer = 1234 }, &short),
    );
}

test "a client binds a provided value and omits an absent one" {
    var names: [64]u8 = undefined;
    var values: [128]u8 = undefined;
    var digits: [64]u8 = undefined;

    const city = (try bindParamHeader(
        "city",
        .string,
        .{ .string_value = "Zürich" },
        &names,
        &values,
        &digits,
    )).?;
    try testing.expectEqualStrings("city", city.annotation);
    try testing.expectEqualStrings("Mcp-Param-city", city.header_name);
    // The value is not plain ASCII, so the sentinel wraps it.
    try testing.expect(isSentinelEncoded(city.header_value));

    const count = (try bindParamHeader(
        "count",
        .integer,
        .{ .integer = 7 },
        &names,
        &values,
        &digits,
    )).?;
    try testing.expectEqualStrings("Mcp-Param-count", count.header_name);
    try testing.expectEqualStrings("7", count.header_value);

    const flag = (try bindParamHeader(
        "flag",
        .boolean,
        .{ .boolean = true },
        &names,
        &values,
        &digits,
    )).?;
    try testing.expectEqualStrings("Mcp-Param-flag", flag.header_name);
    try testing.expectEqualStrings("true", flag.header_value);

    // A `null` value and a key `arguments` omits both mean no header at all.
    const absent = try bindParamHeader("city", .string, null, &names, &values, &digits);
    try testing.expect(absent == null);
    try testing.expect(try bindParamHeader(
        "count",
        .integer,
        null,
        &names,
        &values,
        &digits,
    ) == null);
}

test "a bound parameter round-trips to the verdict a server reaches" {
    var names: [64]u8 = undefined;
    var values: [128]u8 = undefined;
    var digits: [64]u8 = undefined;
    var converted: [param_value_max_len]u8 = undefined;
    var scratch: [64]u8 = undefined;

    const sent = (try bindParamHeader(
        "city",
        .string,
        .{ .string_value = "Zürich" },
        &names,
        &values,
        &digits,
    )).?;

    // A server decodes the sentinel before comparing, so the value it must
    // agree with is the plaintext the body carries.
    const agreed = try checkParamBinding(
        sent.header_value,
        .{ .string_value = "Zürich" },
        &converted,
        &scratch,
    );
    try testing.expectEqual(ParamVerdict.accepted, agreed);
    try testing.expect(agreed.isAcceptable());

    const other = try checkParamBinding(
        sent.header_value,
        .{ .string_value = "Bern" },
        &converted,
        &scratch,
    );
    try testing.expectEqual(ParamVerdict.mismatch, other);
    try testing.expect(!other.isAcceptable());
    try testing.expectEqual(ErrorCode.header_mismatch, other.errorCode().?);

    // An integer travels as a decimal in both directions.
    const count = (try bindParamHeader(
        "count",
        .integer,
        .{ .integer = header_integer_max },
        &names,
        &values,
        &digits,
    )).?;
    try testing.expectEqual(ParamVerdict.accepted, try checkParamBinding(
        count.header_value,
        .{ .integer = header_integer_max },
        &converted,
        &scratch,
    ));
}

test "the four parameter rows resolve to one verdict each" {
    var converted: [param_value_max_len]u8 = undefined;
    var scratch: [64]u8 = undefined;
    const provided: ParamValue = .{ .integer = 7 };

    try testing.expectEqual(
        ParamVerdict.accepted,
        try checkParamBinding("7", provided, &converted, &scratch),
    );
    try testing.expectEqual(
        ParamVerdict.mismatch,
        try checkParamBinding("8", provided, &converted, &scratch),
    );
    // A value in the body with no header is a non-conforming client.
    try testing.expectEqual(
        ParamVerdict.missing_header,
        try checkParamBinding(null, provided, &converted, &scratch),
    );
    // A header for a value the body does not carry is one a server MUST NOT
    // expect.
    try testing.expectEqual(
        ParamVerdict.unexpected_header,
        try checkParamBinding("7", null, &converted, &scratch),
    );
    // Neither present is nothing to reject.
    try testing.expectEqual(
        ParamVerdict.accepted,
        try checkParamBinding(null, null, &converted, &scratch),
    );

    // Only a disagreement carries a code the specification names.
    try testing.expectEqual(@as(?ErrorCode, null), ParamVerdict.accepted.errorCode());
    try testing.expectEqual(@as(?ErrorCode, null), ParamVerdict.missing_header.errorCode());
    try testing.expectEqual(@as(?ErrorCode, null), ParamVerdict.unexpected_header.errorCode());
    try testing.expectEqual(
        @as(i32, -32020),
        @intFromEnum(ParamVerdict.mismatch.errorCode().?),
    );
}

test "an unbindable value or schema is refused, not sent" {
    var names: [64]u8 = undefined;
    var values: [128]u8 = undefined;
    var digits: [64]u8 = undefined;

    // The value must have the type the schema declares.
    try testing.expectError(error.InvalidField, bindParamHeader(
        "count",
        .integer,
        .{ .string_value = "7" },
        &names,
        &values,
        &digits,
    ));

    // An integer a JSON number cannot hold exactly has no header form that
    // reads back as the same number.
    try testing.expectError(error.InvalidField, bindParamHeader(
        "count",
        .integer,
        .{ .integer = header_integer_max + 1 },
        &names,
        &values,
        &digits,
    ));

    // A schema that annotates a non-primitive property is the same fault, and
    // it is reported before any value is rendered.
    try testing.expectError(error.InvalidField, bindParamHeader(
        "ratio",
        .number,
        .{ .integer = 7 },
        &names,
        &values,
        &digits,
    ));
    try testing.expectError(error.InvalidField, bindParamHeader(
        "has space",
        .string,
        .{ .string_value = "x" },
        &names,
        &values,
        &digits,
    ));

    try testing.expect(isBindableValue(.string, .{ .string_value = "" }));
    try testing.expect(!isBindableValue(.string, .{ .boolean = false }));
    try testing.expect(isBindableValue(.integer, .{ .integer = header_integer_min }));
    try testing.expect(!isBindableValue(.integer, .{ .integer = header_integer_min - 1 }));
    try testing.expect(!isBindableValue(.unstated, .{ .string_value = "x" }));
}

test "an unrecognised resultType is neither complete nor input_required" {
    const complete = ResultType.parse("complete");
    try testing.expectEqual(KnownResultType.complete, complete.known().?);
    try testing.expect(complete.isComplete());

    const interim = ResultType.parse("input_required");
    try testing.expectEqual(KnownResultType.input_required, interim.known().?);
    try testing.expect(!interim.isComplete());

    // The tasks extension contributes `task`, and the core schema does not
    // enumerate it. The specification says an unrecognised value is invalid, so
    // this must not silently read as complete.
    const extension = ResultType.parse("task");
    try testing.expectEqual(@as(?KnownResultType, null), extension.known());
    try testing.expect(!extension.isComplete());

    // An absent resultType is complete, per the backward-compatibility rule.
    const absent: ResultType = .{};
    try testing.expectEqual(KnownResultType.complete, absent.known().?);
    try testing.expect(absent.isComplete());
}

test "decodeResultType carries the wire value and preserves an absent member" {
    var scratch: [64]u8 = undefined;

    const complete = try decodeResultType(
        \\{"resultType":"complete","tools":[]}
    , &scratch);
    try testing.expectEqualStrings(result_type_value.complete, complete.value.?);
    try testing.expect(complete.isComplete());

    // The tasks extension contributes `task` and the core does not enumerate
    // it, so the decoder hands it back rather than rejecting a value the
    // specification does not define.
    const extension = try decodeResultType(
        \\{"resultType":"task","taskId":"t1"}
    , &scratch);
    try testing.expectEqual(@as(?KnownResultType, null), extension.known());
    try testing.expect(!extension.isComplete());

    // A result from an earlier revision omits the member, and the client MUST
    // treat that as complete.
    const absent = try decodeResultType(
        \\{"tools":[]}
    , &scratch);
    try testing.expectEqual(@as(?[]const u8, null), absent.value);
    try testing.expectEqual(KnownResultType.complete, absent.known().?);
    try testing.expectEqual(@as(?[]const u8, null), (try decodeResultType("{}", &scratch)).value);
}

test "cacheScope accepts only the two defined values" {
    try testing.expectEqual(CacheScope.public, try parseCacheScope("public"));
    try testing.expectEqual(CacheScope.private, try parseCacheScope("private"));
    try testing.expectError(error.UnknownTag, parseCacheScope("Public"));
    try testing.expectError(error.UnknownTag, parseCacheScope("shared"));
}

test "a cacheable result decodes its two required fields and rejects a bad one" {
    var scratch: [64]u8 = undefined;

    const cacheable = try decodeCacheable(
        \\{"resultType":"complete","ttlMs":60000,"cacheScope":"private"}
    , &scratch);
    try testing.expectEqual(@as(u64, 60000), cacheable.ttl_ms);
    try testing.expectEqual(CacheScope.private, cacheable.cache_scope);

    // Zero is legal and means immediately stale.
    const stale = try decodeCacheable(
        \\{"ttlMs":0,"cacheScope":"public"}
    , &scratch);
    try testing.expectEqual(@as(u64, 0), stale.ttl_ms);

    // The field is `@minimum 0` and declared `u64`, so a negative is malformed
    // rather than a value this library quietly replaces with zero.
    try testing.expectError(error.InvalidField, decodeCacheable(
        \\{"ttlMs":-1,"cacheScope":"public"}
    , &scratch));
    // A fraction and an exponent are not whole milliseconds.
    try testing.expectError(error.InvalidField, decodeCacheable(
        \\{"ttlMs":1.5,"cacheScope":"public"}
    , &scratch));
    try testing.expectError(error.InvalidField, decodeCacheable(
        \\{"ttlMs":1e3,"cacheScope":"public"}
    , &scratch));
    // A millisecond count that does not fit in 64 bits is not a number the
    // schema describes.
    try testing.expectError(error.InvalidField, decodeCacheable(
        \\{"ttlMs":99999999999999999999,"cacheScope":"public"}
    , &scratch));

    // Both fields are required, and `cacheScope` is still the two-value enum.
    try testing.expectError(error.MissingField, decodeCacheable(
        \\{"ttlMs":0}
    , &scratch));
    try testing.expectError(error.MissingField, decodeCacheable(
        \\{"cacheScope":"public"}
    , &scratch));
    try testing.expectError(error.MissingField, decodeCacheable("{}", &scratch));
    try testing.expectError(error.UnknownTag, decodeCacheable(
        \\{"ttlMs":0,"cacheScope":"shared"}
    , &scratch));
}

test "error codes match the renumbering record" {
    try testing.expectEqual(@as(i32, -32020), @intFromEnum(ErrorCode.header_mismatch));
    try testing.expectEqual(@as(i32, -32021), @intFromEnum(ErrorCode.missing_required_client_capability));
    try testing.expectEqual(@as(i32, -32022), @intFromEnum(ErrorCode.unsupported_protocol_version));
    try testing.expectEqual(@as(i32, -32001), ErrorCode.header_mismatch.renumberedFrom().?);
    try testing.expectEqual(@as(i32, -32003), ErrorCode.missing_required_client_capability.renumberedFrom().?);
    try testing.expectEqual(@as(i32, -32004), ErrorCode.unsupported_protocol_version.renumberedFrom().?);
}

test "a wire code maps back to the member PROTOCOLS.md section 4.5 names" {
    // The reverse of the enum. A tag added without a row here resolves to null,
    // and this fails rather than letting the gap reach a caller.
    inline for (@typeInfo(ErrorCode).@"enum".fields) |field| {
        const value: ErrorCode = @field(ErrorCode, field.name);
        try testing.expectEqual(value, ErrorCode.fromCode(@intFromEnum(value)).?);
    }

    // The three the specification allocates carry their current values, and the
    // two retired ones keep the spellings a previous-revision peer still sends.
    try testing.expectEqual(ErrorCode.header_mismatch, ErrorCode.fromCode(-32020).?);
    try testing.expectEqual(
        ErrorCode.missing_required_client_capability,
        ErrorCode.fromCode(-32021).?,
    );
    try testing.expectEqual(
        ErrorCode.unsupported_protocol_version,
        ErrorCode.fromCode(-32022).?,
    );
    try testing.expectEqual(ErrorCode.resource_not_found_legacy, ErrorCode.fromCode(-32002).?);
    try testing.expectEqual(ErrorCode.url_elicitation_required_legacy, ErrorCode.fromCode(-32042).?);

    // `-32602` is the JSON-RPC resource-not-found code, not one of MCP's own,
    // so a decoder that asked this table for it gets nothing rather than the
    // retired `-32002` spelling of the same condition.
    try testing.expectEqual(@as(?ErrorCode, null), ErrorCode.fromCode(-32602));
    try testing.expectEqual(@as(?ErrorCode, null), ErrorCode.fromCode(0));
}

test "a retired code may not be emitted at the current revision" {
    try testing.expect(ErrorCode.resource_not_found_legacy.emittableAt(.previous));
    try testing.expect(!ErrorCode.resource_not_found_legacy.emittableAt(.current));
    try testing.expect(!ErrorCode.url_elicitation_required_legacy.emittableAt(.current));
    try testing.expect(ErrorCode.header_mismatch.emittableAt(.current));
}

test "the resource-not-found code is revision-dependent" {
    // -32002 is the 2025-11-25 spelling; -32602 is the 2026-07-28 one.
    try testing.expect(acceptsResourceNotFound(.previous, -32002));
    try testing.expect(!acceptsResourceNotFound(.current, -32002));
    try testing.expect(acceptsResourceNotFound(.current, -32602));
    try testing.expect(!acceptsResourceNotFound(.current, -32021));
}

test "the reserved and legacy ranges are disjoint" {
    // The legacy range is `-32000` to `-32019` and the specification's own is
    // `-32020` to `-32099`. Both are negative, so the specification's range sits
    // numerically below the legacy one; the property that matters is that they
    // share no code.
    try testing.expectEqual(@as(i32, -32000), legacy_error_min);
    try testing.expectEqual(@as(i32, -32019), legacy_error_max);
    try testing.expectEqual(@as(i32, -32020), reserved_error_min);
    try testing.expectEqual(@as(i32, -32099), reserved_error_max);
    try testing.expect(legacy_error_min > reserved_error_max);
}

test "an InputRequiredResult needs at least one of its two optional members" {
    var scratch: [128]u8 = undefined;

    const both = try decodeInputRequiredResult(
        \\{"resultType":"input_required","inputRequests":{"a":{"method":"elicitation/create"}},"requestState":"opaque"}
    , &scratch);
    try testing.expect(both.input_requests != null);
    try testing.expectEqualStrings("opaque", both.request_state.?);

    const state_only = try decodeInputRequiredResult(
        \\{"resultType":"input_required","requestState":"opaque"}
    , &scratch);
    try testing.expectEqual(@as(?[]const u8, null), state_only.input_requests);

    try testing.expectError(error.MissingField, decodeInputRequiredResult(
        \\{"resultType":"input_required"}
    , &scratch));

    // A complete result is not an InputRequiredResult.
    try testing.expectError(error.InvalidField, decodeInputRequiredResult(
        \\{"resultType":"complete","requestState":"x"}
    , &scratch));
}

test "requestState is carried and never interpreted" {
    var scratch: [128]u8 = undefined;
    // A value that would be dangerous if parsed as anything else. The library
    // hands it back byte for byte.
    const hostile = "{\"admin\":true,\"role\":\"owner\"}";
    const decoded = try decodeInputRequiredResult(
        \\{"resultType":"input_required","requestState":"{\"admin\":true,\"role\":\"owner\"}"}
    , &scratch);
    try testing.expectEqualStrings(hostile, decoded.request_state.?);
}

test "an InputRequiredResult records an absent resultType instead of inventing one" {
    var scratch: [128]u8 = undefined;

    const present = try decodeInputRequiredResult(
        \\{"resultType":"input_required","requestState":"x"}
    , &scratch);
    try testing.expectEqualStrings(result_type_value.input_required, present.result_type.value.?);
    try testing.expectEqual(KnownResultType.input_required, present.result_type.known().?);

    // A peer on an earlier revision omits the member. A default of
    // `input_required` would be indistinguishable from a value the peer sent
    // and would be re-encoded as one.
    const absent = try decodeInputRequiredResult(
        \\{"requestState":"x"}
    , &scratch);
    try testing.expectEqual(@as(?[]const u8, null), absent.result_type.value);
    // ... and the client MUST treat an absent member as complete.
    try testing.expectEqual(KnownResultType.complete, absent.result_type.known().?);
}

test "only the second label decides whether a prefix is reserved" {
    try testing.expect(isReservedMetaPrefix("io.modelcontextprotocol"));
    try testing.expect(isReservedMetaPrefix("dev.mcp"));
    try testing.expect(isReservedMetaPrefix("com.mcp.tools"));
    // The trailing slash ends the label sequence, so the key namespace itself
    // is recognised as well as a bare prefix.
    try testing.expect(isReservedMetaPrefix("io.modelcontextprotocol/"));
    try testing.expect(isReservedMetaPrefix("dev.mcp/"));

    // The rule is about the whole second label, so a longer label that merely
    // starts with a reserved one is not reserved, and neither is a longer
    // label that merely starts with `mcp`.
    try testing.expect(!isReservedMetaPrefix("io.modelcontextprotocolX/tools"));
    try testing.expect(!isReservedMetaPrefix("com.mcpfoo"));
    // The specification calls this one out: `example` is the second label.
    try testing.expect(!isReservedMetaPrefix("com.example.mcp"));
    try testing.expect(!isReservedMetaPrefix("com.example"));
    // A single label has no second label for the rule to find.
    try testing.expect(!isReservedMetaPrefix("mcp"));
}

test "a skill digest is a sha256 prefix and 64 lowercase hex digits" {
    var digest: [7 + 64]u8 = undefined;
    _ = std.fmt.bufPrint(digest[0..7], "sha256:", .{}) catch unreachable;
    @memset(digest[7..], 'a');
    try testing.expect(isValidSkillDigest(&digest));

    // Uppercase is not the stated format.
    digest[7] = 'A';
    try testing.expect(!isValidSkillDigest(&digest));
    digest[7] = 'a';
    // Short by one digit.
    try testing.expect(!isValidSkillDigest(digest[0 .. digest.len - 1]));
    try testing.expect(!isValidSkillDigest("deadbeef"));
}

test "the deprecation floor is the stated revision and 90 days" {
    try testing.expectEqualStrings("2027-07-28", DeprecatedFeature.deprecationFloorRevision());
    try testing.expectEqual(@as(u32, 90), DeprecatedFeature.expeditedRemovalFloorDays());
}

test "extension method sets are the specified ones" {
    try testing.expectEqual(@as(usize, 4), tasks_extension_methods.len);
    try testing.expectEqual(@as(usize, 3), skills_extension_methods.len);
    // A core method name must not collide with an extension method name.
    for (tasks_extension_methods) |name| {
        for (client_requests) |info| {
            try testing.expect(!std.mem.eql(u8, info.name, name));
        }
    }
}
