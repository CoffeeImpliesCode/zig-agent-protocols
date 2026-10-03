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
//!
//! ## The three kinds of borrowed member in section 4.10
//!
//! Every payload type below carries members of three kinds, and which kind a
//! field is decides what a caller has to keep alive for it and what an
//! encoder checks. Each type's own comment names the kind for each of its
//! fields; this is the rule they all defer to.
//!
//! A **JSON lexeme** — the `_meta`, `annotations`, `icons`, `structuredContent`,
//! `inputSchema`, `outputSchema`, `inputRequests`, `capabilities` and every
//! other member this module carries rather than models — is [`json.Reader`]
//! `rawValue` output: exactly one JSON value of any type, borrowed from the
//! document the decoder was handed and never from the escape scratch. Every
//! encoder checks each lexeme at its actual container depth and reports
//! `error.InvalidField` before the first byte. The outer object, array elements
//! and embedded resource objects spend the same depth budget as the decoder.
//!
//! A **decoded string** — `uri`, `text`, `data`, `mime_type`, `title`, `name`,
//! `blob`, `next_cursor`, `description`, `instructions`, `request_state` and
//! `ResultType.value` — is `string` output: the JSON escapes resolved, so a
//! peer that wrote `"a\nb"` is read as `a<LF>b`. It borrows the document when
//! the peer wrote no escape and the caller's escape scratch when it wrote one,
//! and both of those have to outlive the value.
//!
//! A **carried member** — every `verbatim` field — is a [`VerbatimMember`]:
//! its slice aliases the caller's store array rather than copying it, and its
//! two halves borrow one region each. That type states both.
//!
//! Nothing here allocates and no decode copies any of the three, so the whole
//! of what a caller must keep alive for one decoded document is the document
//! itself, the escape scratch it supplied and the store array it supplied. A
//! decode that fails returns no value at all: the out-arrays may hold
//! partially filled elements and the store may hold entries the failed
//! attempt recorded, and neither is readable as part of a result. Each public
//! decoder says so on its own.
//!
//! ## The one caller obligation the encoders do not check
//!
//! Every encoder below quotes caller strings through [`json.Writer.string`],
//! which states that valid UTF-8 is the caller's obligation and enforces it in
//! no optimize mode: it escapes every byte JSON names and passes every other
//! one through. A string that arrived through [`json.Reader.string`] is valid
//! by construction, because that reader refuses anything else, so re-encoding
//! what a decoder produced needs no check at all. A caller building a result
//! from strings it wrote itself holds the obligation, and a stray byte
//! produces a literal this library's own reader then refuses with
//! `error.InvalidUtf8` — a body the sending side reported as written and the
//! receiving side rejected.
//!
//! So the inverse each encoder documents is an inverse **for the values its
//! decoder produces**, and not for any value handed to it, and each says so.
//! [`inputRequired`] is the one entry point here that checks rather than
//! asserts, because it is the only one whose whole job is to build a result
//! out of values the caller wrote rather than decoded.

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

/// The `jsonrpc` member every MCP message carries, section 4.1.
///
/// It names the JSON-RPC envelope, not the revision: both decoded revisions
/// send it and neither is derived from it, so a message carrying `"2.0"` says
/// nothing about which revision its methods are read against.
pub const jsonrpc_version = "2.0";

/// The two decoded revisions.
///
/// The tags are the library's own; `string` is the wire spelling.
pub const Revision = enum {
    /// `2026-07-28`. No handshake; capabilities are per request.
    current,
    /// `2025-11-25` and earlier. Capabilities travel in `initialize`.
    previous,

    /// The revision a wire spelling names, or null for one this library does
    /// not decode.
    ///
    /// Null rather than a default: a revision with no method table here has
    /// nothing to resolve a method against, so naming one would answer for a
    /// protocol the caller did not say it speaks.
    pub fn fromString(text: []const u8) ?Revision {
        if (std.mem.eql(u8, text, latest_protocol_version)) return .current;
        if (std.mem.eql(u8, text, previous_protocol_version)) return .previous;
        return null;
    }

    /// The wire spelling of this revision, which is what a peer sends.
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
/// The closing marker of the sentinel, the other half of
/// [`sentinel_prefix`].
///
/// Case-sensitive and required wherever the prefix is present, for the reason
/// that marker states: a reader that accepted a differently spelled closing
/// marker would be reading a value the peer never sent.
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
    return json.base64.decode(body, scratch, .standard);
}

/// The scratch a caller must supply to [`encodeHeaderValue`] for a value of
/// `value_len` bytes.
///
/// Base64 with padding emits four characters for every three input bytes, so
/// the bound is [`json.base64.encodedLen`] and this is the one place the
/// sentinel states it. The caller sizes the buffer because nothing in an
/// encode path allocates: a fixed buffer the caller cannot reach turns an
/// `Mcp-Name` past its size into an unencodable value rather than a larger
/// one.
pub fn sentinelScratchLen(value_len: usize) usize {
    return json.base64.encodedLen(value_len);
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

    const encoded = try json.base64.encode(value, scratch, .standard);
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

/// Whether `value` is inside the range above, both ends included.
///
/// The membership test, for a caller holding an integer read out of
/// `arguments` rather than an annotation. [`isBindableValue`] is what applies
/// it to a parameter the schema typed `integer`.
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

    /// The tag a schema `type` name maps to. A name this library does not know
    /// is [`ParamType.unstated`], so [`isBindableParamType`] refuses it
    /// rather than this function.
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
    const negative = value < 0;
    // SAFETY: both arms of the `if` below assign `magnitude` before the first read at `/ 10`.
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
///
/// The result borrows `out` and `annotation` is only read, so the caller keeps
/// `out` alive and unwritten for as long as it holds the name. Both refusals
/// land before a byte is written: `error.InvalidField` for a name that is not
/// an RFC 9110 field-name token, `error.BufferTooSmall` for an `out` shorter
/// than [`paramHeaderNameLen`]. Allocates nothing.
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
    /// `null`. The server MUST NOT expect it, which is a rule about what the
    /// server acts on and not a rule about rejecting: see [`isAcceptable`].
    unexpected_header,

    /// Whether the request may proceed.
    ///
    /// PROTOCOLS.md 4.2 makes a server "MUST reject on mismatch", which is
    /// [`ParamVerdict.mismatch`], and the normative table's last row adds one
    /// more: "Client omits header but value is in body | Non-conforming client
    /// | MUST reject the request", which is
    /// [`ParamVerdict.missing_header`]. Those two and no other.
    ///
    /// The two rows that read "MUST NOT expect the header" — a value that is
    /// `null`, and a parameter not in `arguments` — state what the server must
    /// not *expect*, and the table contains no rejection for either. Turning
    /// that sentence into a refusal derived a rejection the authority does not
    /// state, and it made [`ParamVerdict.unexpected_header`] a hard gate
    /// alongside a row that genuinely is one. A conforming client never
    /// reaches it, so no behaviour depended on the gate; what was wrong was
    /// the rule behind it. The verdict is still reported, so a server that
    /// does want to refuse one has the fact by name.
    pub fn isAcceptable(self: ParamVerdict) bool {
        return self != .mismatch and self != .missing_header;
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

/// Which leg of a request a result arrived on.
///
/// The two members are the two facts the no-cache rule composes. A client
/// that reads [`MethodInfo.cacheable`] on its own caches the `complete` leg of
/// a multi round-trip retry, which the specification forbids;
/// [`MethodInfo.mayCache`] takes both and is where that rule lives.
pub const CacheLeg = enum {
    /// The request the client sent first.
    original,
    /// A retry carrying `inputResponses` or `requestState`.
    mrtr_retry,
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
    ///
    /// The flag is a fact about the **message** this row describes, not about
    /// the name and not about a payload. `roots/list` carries it on
    /// [`previous_top_level_requests`] and on the row [`lookupMethod`]
    /// synthesizes at `.previous`, and leaves it at `false` in
    /// [`input_requests`] — because what `2026-07-28` retired there was the
    /// top-level request, while the same name is a value a server still sends
    /// inside `InputRequiredResult.inputRequests`. A caller that read the flag
    /// off `input_requests` would refuse a request the revision still requires
    /// a server to be able to make.
    ///
    /// It says nothing about the shapes the method carries either.
    /// `notifications/message` is marked because section 4.9 lists Logging as
    /// deprecated, and the notification a peer still sends is unchanged. The
    /// flag marks the method; the `direction` on the row marks who may send it.
    deprecated: bool = false,

    /// Whether a result for this method, arrived on `leg`, may be cached.
    ///
    /// PROTOCOLS.md section 4.6 states the two caching fields and does not
    /// carry the no-cache rule, so this is a gap in the authority rather than
    /// a contradiction of it and it is recorded here. The normative source
    /// does state it, verbatim: "Results produced by retrying a request
    /// through the multi round-trip requests mechanism—that is, requests
    /// carrying `inputResponses` or `requestState`—MUST NOT be cached."
    ///
    /// It is not folded into [`MethodInfo.cacheable`], which stays a property
    /// of the method: `resources/read` genuinely is cacheable on the leg that
    /// was not a retry, and two independent booleans are exactly what invite
    /// the wrong one. A method that is not cacheable is not cacheable on
    /// either leg, so this is a composition and not a third flag.
    pub fn mayCache(self: MethodInfo, leg: CacheLeg) bool {
        if (leg == .mrtr_retry) return false;
        return self.cacheable;
    }
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

/// The `InputRequest` union: the only three server-to-client requests, and
/// inside `inputRequests` at every revision this library decodes.
///
/// At `2025-11-25` the same three names are also ordinary client-to-server
/// requests, which is what [`previous_top_level_requests`] records. A name
/// resolving here says where a value is sent from, not every position it may
/// occupy.
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

/// The three methods that were top-level requests before `2026-07-28`.
///
/// PROTOCOLS.md section 4.4 removes `elicitation/create`,
/// `sampling/createMessage` and `roots/list` as top-level requests and keeps
/// their types inside `InputRequiredResult.inputRequests`, so at the previous
/// revision all three are ordinary client-to-server requests and this table
/// is what makes them resolve there. A removal is a fact about one revision:
/// PROTOCOLS.md section 8 says the library accepts `2025-11-25`, and a peer on
/// it sends `roots/list` as a request.
///
/// The direction is the top-level one rather than the one
/// [`input_requests`] carries. The carried direction is
/// `server_to_client_mrtr_only` because a server sends those values, and a
/// `2025-11-25` request is a thing the client sends; a row that reused the
/// carried direction would resolve the name and then be refused as
/// `NotARequest` by the session gate, so a previous-revision server would
/// refuse to answer `roots/list` as well as a client being unable to ask.
pub const previous_top_level_requests = [_]MethodInfo{
    .{ .name = "roots/list", .direction = .client_to_server, .present_at_current = false, .deprecated = true },
    .{ .name = "elicitation/create", .direction = .client_to_server, .present_at_current = false, .deprecated = true },
    .{
        .name = "sampling/createMessage",
        .direction = .client_to_server,
        .present_at_current = false,
        .deprecated = true,
    },
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
/// values inside `InputRequiredResult.inputRequests`, found by
/// [`lookupInputRequest`], and as requests at the previous revision, found by
/// [`lookupMethod`] through [`previous_top_level_requests`].
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
/// `2026-07-28` removed `elicitation/create`, `sampling/createMessage` and
/// `roots/list` from the top level, which makes them resolve at `2025-11-25`
/// and not at `2026-07-28`. PROTOCOLS.md section 4.4 reads "removed in
/// `2026-07-28`, and therefore decoded as `UnknownMethod` at that revision",
/// and modelling them at no revision would refuse a request the previous
/// revision's own document defines. [`previous_top_level_requests`] carries
/// them as the client-to-server requests they were then; they survive as
/// values inside `inputRequests`, and [`lookupInputRequest`] is the entry
/// point that finds them there.
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
        for (previous_top_level_requests) |info| {
            if (!std.mem.eql(u8, info.name, name)) continue;
            return .{
                .name = info.name,
                .direction = info.direction,
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

/// Whether a method is one this library refuses as a top-level method at
/// `revision`.
///
/// The revision is a parameter because the answer differs across it. What
/// `2026-07-28` removed from the top level is a request `2025-11-25` still
/// defines, so a gate that refused the name at both would turn a legal
/// previous-revision request away before the codec ever read it.
///
/// At `2026-07-28` this includes the three `InputRequest` methods: what was
/// removed is their use at the top level, so a caller gating on this refuses
/// them there and uses [`lookupInputRequest`] inside `inputRequests`.
pub fn isRemovedMethod(revision: Revision, name: []const u8) bool {
    // Every removal this library models happened at `2026-07-28`, and nothing
    // was removed before the revision that removed it.
    if (revision != .current) return false;
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

    /// The number this code carried before the `2026-07-28` renumbering, or
    /// null for a code the specification did not move.
    ///
    /// A client reading a previous-revision peer needs it, because
    /// [`ErrorCode.fromCode`] does not answer for the three codes the draft
    /// moved.
    pub fn renumberedFrom(self: ErrorCode) ?i32 {
        return switch (self) {
            .header_mismatch => -32001,
            .missing_required_client_capability => -32003,
            .unsupported_protocol_version => -32004,
            else => null,
        };
    }

    /// The code a wire number names, or null for a number this library does
    /// not know.
    ///
    /// It answers for the two retired codes a previous-revision peer still
    /// sends, and for nothing else: `-32602` is the JSON-RPC spelling of a
    /// condition MCP shares rather than one of its own, so
    /// [`acceptsResourceNotFound`] is what classifies that number.
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

    /// Parse a `resultType` string, keeping it as written.
    ///
    /// It validates nothing and normalises nothing: a name the revision does
    /// not define is kept, and [`ResultType.known`] is where a caller decides
    /// what it means. `text` is borrowed, so it has to outlive the result.
    pub fn parse(text: []const u8) ResultType {
        return .{ .value = text };
    }

    /// The [`KnownResultType`] this value names, or null for one the revision
    /// does not define.
    ///
    /// An absent value is `complete`, which is a decision rather than a
    /// default: a peer on an earlier revision omits the member and the client
    /// MUST treat that as complete. An unrecognised name is null rather than
    /// `complete`, for the opposite reason — the specification requires the
    /// client to consider it invalid, and what to do about a value an
    /// extension contributed is the caller's to choose.
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
///
/// The returned value keeps a slice: `ResultType.value` borrows `raw` when the
/// peer wrote no escape in the member and `scratch` when it wrote one, so both
/// must outlive it, and the member name it walked over drew from the same two.
/// Every other member is skipped and nothing is written outside `scratch`, so
/// an absent `resultType` is `ResultType{}` and not a fault.
pub fn decodeResultType(raw: []const u8, scratch: []u8) DecodeError!ResultType {
    var reader = json.Reader.init(raw);
    var result: ResultType = .{};
    // An empty object is a result that carries no `resultType` rather than a
    // refusal, so the loop is skipped and not the function: the check below
    // then stands for the empty object as well.
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "resultType")) {
                try claimFirst(&result.value, &reader, scratch, takeString);
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    // A result object is one JSON value. Bytes after the closing brace are a
    // second document the transport did not split, or a peer that disagrees
    // with it about where a message ends, and a decoder that accepted them
    // would re-encode the result without them — the silent truncation
    // `jsonrpc.decode` and `bridge.decodeEnvelope` refuse for the same reason.
    if (!reader.atEnd()) return error.MalformedJson;
    return result;
}

/// Encode the `resultType` [`ResultType`] carries, as a whole result object.
///
/// Public because [`decodeResultType`] is: a decoder with no encoder is the
/// asymmetry `acp.zig` removed across six functions, and this is the same hole
/// one line wide. It writes the members the type carries and nothing else — a
/// member [`decodeResultType`] does not govern is skipped by design, because
/// it is the rule [`checkResult`] applies to a body it did not build, and no
/// writer built from the decoded value could put it back. So this is the
/// narrowest encoder in the section: it reproduces the one member the type
/// holds, and a caller that wants the rest of a body preserved reaches for one
/// of the typed results in section 4.10, which carry what they skip.
/// [`VerbatimMember`] states the rule every one of them follows.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodeResultType`] produces and not for any value
/// handed to it. A caller building a `ResultType` from its own text must have
/// it valid.
pub fn encodeResultType(result: ResultType, writer: *json.Writer) EncodeError!void {
    try writer.byte('{');
    if (result.value) |value| {
        try writer.slice("\"resultType\":");
        try writer.string(value);
    }
    try writer.byte('}');
}

/// What the three result rules of sections 4.6 and 4.7 report.
///
/// [`classifyResult`], [`checkResult`] and [`inputRequired`] read and write a
/// whole result document, so they fail wherever the decoders beside them fail
/// and this is [`root.DecodeError`] with two names of its own added. It is a
/// superset rather than a second vocabulary: a caller holding the bytes names
/// every way any entry point of this module refuses them out of one set, and
/// no member of it duplicates what [`decodeResultType`] or [`decodeCacheable`]
/// can already return.
///
/// The two added names are deliberately not in [`root.DecodeError`], which
/// PROTOCOLS.md 2.1 transcribes member for member. Neither is a fault the
/// bytes can carry on their own: `NotAResult` is the verdict of the 4.6 rules
/// on a document rather than a JSON syntax error, and
/// `InputRequiredUnexpected` is decided from a method name. Putting the second
/// in the shared set would tell a caller of `a2a` or `acp` — two protocols
/// with no multi-round-trip request at all — that a decode can fail because an
/// interim result was unexpected.
pub const ResultError = DecodeError || error{
    /// A body is not a result this layer can pass on.
    ///
    /// A peer's body that does not decode as one, or one this revision does
    /// not define for the method that must carry it. PROTOCOLS.md 4.6 makes
    /// `resultType` required on every result and adds `ttlMs` and `cacheScope`
    /// to one the method table marks cacheable, so a body missing one of those
    /// three is refused whichever side wrote it.
    NotAResult,
    /// An interim result arrived where none could be answered: the method is
    /// one PROTOCOLS.md 4.7 does not let return one, or the caller supplied
    /// no answer to the one it did.
    InputRequiredUnexpected,
};

/// Classify a result body without consuming it.
///
/// A result from a peer on an earlier revision omits `resultType`, and the
/// specification requires that to be treated as `complete`.
///
/// Every fault but a short scratch collapses into [`error.NotAResult`]:
/// what this answers is what the body *is*, and a caller sent looking for a
/// malformed document should have asked [`decodeResultType`] instead. A short
/// scratch keeps its own name, because doubling the buffer and asking again is
/// a repair and the other is not.
///
/// No revision is threaded and none is needed, which is what puts this here
/// rather than in the session layer above. A body says nothing about the
/// revision that sent it — the same reader serves an answer from `2026-07-28`
/// and one from `2025-11-25` — and [`checkResult`] is where the method's own
/// rule is read, passed in rather than looked up. A consumer holding the bytes
/// and no session is the caller this is for, and a reader that needed a
/// session would refuse the very answer PROTOCOLS.md 4.6 tells it to accept.
///
/// The returned [`ResultType`] keeps a slice of `body` or of `scratch` under
/// the rule [`decodeResultType`] states, and both must outlive it. A caller
/// that only wants the verdict uses [`ResultType.isComplete`] and lets it go
/// at once.
pub fn classifyResult(body: []const u8, scratch: []u8) ResultError!ResultType {
    return decodeResultType(body, scratch) catch |err| switch (err) {
        error.BufferTooSmall => error.BufferTooSmall,
        else => error.NotAResult,
    };
}

/// Refuse a result that breaks the rule `info` carries, and accept the rest.
///
/// PROTOCOLS.md 4.6 makes `resultType` required on every result and adds
/// `ttlMs` and `cacheScope` to one the method table marks cacheable, so a
/// handler calls this on the body it built and learns from a return value
/// whether the body may be sent, rather than from a review of whether it
/// remembered the three members.
///
/// `resultType` is required here and absent-tolerant on the reading side,
/// which is not an inconsistency: 4.6's "a result from a peer on an earlier
/// revision omits `resultType`" is about what this library receives, and a
/// body a server built is not that. [`classifyResult`] is where such a peer
/// is answered for. A value outside the two the revision defines is not
/// refused either: what to do with one an extension contributed is the
/// client's decision, and this is the sending side.
///
/// `info` is an argument rather than a lookup, and that is what settles the
/// layer. PROTOCOLS.md 4.6 binds the two caching fields to the method, and
/// [`lookupMethod`] returns the same entry at both revisions for every method
/// it resolves, so a revision threaded in here could not change one outcome. A
/// caller already holding `info` from `mcp_session.Server.gate` passes it on
/// unchanged, and a caller holding none reads it here with no session in hand.
///
/// Nothing is returned and nothing is written outside `scratch`, so a refusal
/// leaves the body and the scratch as the caller passed them apart from the
/// escape regions this call consumed; a caller that fixes the fault and asks
/// again gets a whole answer.
pub fn checkResult(info: MethodInfo, result: []const u8, scratch: []u8) ResultError!void {
    const kind = decodeResultType(result, scratch) catch |err| switch (err) {
        error.BufferTooSmall => return error.BufferTooSmall,
        else => return error.NotAResult,
    };
    // The member is required on a result, so its absence is refused here
    // even though a peer on an earlier revision may omit one. A body that
    // is not an object was already reported by the decode above.
    if (kind.value == null) return error.NotAResult;
    if (!info.cacheable) return;
    // `decodeCacheable` is the one implementation of the caching rule,
    // and this is where it becomes reachable.
    _ = decodeCacheable(result, scratch) catch |err| switch (err) {
        error.BufferTooSmall => return error.BufferTooSmall,
        // Both fields are required, so an absent one and a value of the
        // wrong type are one fault to a server: the body it built is not a
        // result this method may answer with.
        else => return error.NotAResult,
    };
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
    /// Who may share a cache entry across this result.
    ///
    /// Required beside [`Cacheable.ttl_ms`], and not an optional with a
    /// default: collapsing an absent member into a tag would turn a document
    /// missing it into the widest scope there is. Only the two literals the
    /// schema defines are answers — anything else is `error.UnknownTag` at
    /// [`decodeCacheable`] and [`parseCacheScope`], and a peer that sent an
    /// extension's value gets no guess.
    cache_scope: CacheScope,
};

/// The tag a `cacheScope` string names, or `error.UnknownTag` for anything else.
///
/// The comparison is exact and case-sensitive: the two literals are the only
/// values the schema defines, and an extension's value is a caller's decision
/// rather than a third tag here. `text` is only read, so the result borrows
/// nothing.
pub fn parseCacheScope(text: []const u8) DecodeError!CacheScope {
    if (std.mem.eql(u8, text, "public")) return .public;
    if (std.mem.eql(u8, text, "private")) return .private;
    return error.UnknownTag;
}

/// Decode the two fields a cacheable result adds; both are required.
///
/// `raw` is the `result` object as borrowed JSON text, and the returned pair
/// borrows nothing from it: `ttl_ms` is a number and `cache_scope` a tag. The
/// members the caching rules do not govern are skipped rather than rejected, so
/// this composes with [`decodeResultType`] rather than replacing it.
///
/// Every fault but a short scratch is named: `MissingField` for an absent
/// member, `UnknownTag` for a `cacheScope` outside the two literals,
/// `InvalidField` for a `ttlMs` that is not a whole number of milliseconds,
/// and `MalformedJson` for a document that is not one JSON object or that
/// carries a tail. `scratch` receives the escape region of whichever member the
/// walk reads, and neither keeps a slice of it once the call returns, so the
/// caller may reuse it at once. This decoder owns no output storage, so a
/// failing path writes nothing outside `scratch` and returns no value.
///
/// ## What this skips, and who does not
///
/// A skipped member is gone, so a document this reads is not one any encoder
/// can write back whole and there is no encoder that would pretend otherwise.
/// It is the rule [`checkResult`] applies to a body this layer did not build,
/// where the question is whether the two caching members are present and well
/// formed rather than what else the body says.
///
/// A caller that wants the rest of the body uses one of the typed result
/// decoders in section 4.10 instead. Those read the same two members through
/// [`CacheableReader`] and **carry** every member they do not model as a
/// borrowed lexeme, so re-encoding what they read reproduces its wire values;
/// [`VerbatimMember`] states what that does and does not preserve. This decoder
/// and those compose; neither replaces the other.
pub fn decodeCacheable(raw: []const u8, scratch: []u8) DecodeError!Cacheable {
    var reader = json.Reader.init(raw);
    var ttl_ms: ?u64 = null;
    var cache_scope: ?CacheScope = null;

    if (try reader.beginObject()) return error.MissingField;
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "ttlMs")) {
            try claimFirst(&ttl_ms, &reader, scratch, takeMilliseconds);
        } else if (std.mem.eql(u8, key, "cacheScope")) {
            try claimFirst(&cache_scope, &reader, scratch, takeCacheScope);
        } else {
            try reader.skipValue(scratch);
        }
    }

    // A result object is one JSON value, for the reason stated in
    // `decodeResultType`. A `Cacheable` alone has no encoder that could put a
    // tail back, so a tail would cost no bytes on the way out; it would only
    // mean the decoder had read a document the specification does not
    // describe. The typed result decoders in section 4.10 **do** re-encode,
    // and they refuse the same document for the same reason.
    if (!reader.atEnd()) return error.MalformedJson;

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
    /// Any one JSON value: the decoder does not walk the map, does not validate
    /// an inner `method`, and does not check that the member is a JSON object at
    /// all, so `"inputRequests": []` decodes as readily as an object does. A
    /// consumer that needs a method name checked reads the lexeme itself and
    /// refuses a name outside the three with [`lookupInputRequest`], which
    /// answers `error.UnknownMethod`.
    ///
    /// It is borrowed from the document handed to
    /// [`decodeInputRequiredResult`] and never from the escape scratch, so it
    /// stays valid as long as that document does. The encoder splices it back
    /// after holding it to one whole JSON value, so a lexeme a caller built by
    /// hand is `error.InvalidField` before the first byte is written.
    input_requests: ?[]const u8 = null,
    /// Opaque, and attacker-controlled.
    ///
    /// The specification requires a server to integrity-protect this whenever it
    /// influences authorization, so a client that parses its contents is already
    /// outside the contract. The library carries it and never interprets it.
    ///
    /// Read as a JSON string, so these are the **decoded** characters rather
    /// than the lexeme: an escape in the document is resolved. It borrows the
    /// escape scratch when the peer wrote one and the document otherwise, which
    /// is the pair of regions a caller has to keep alive for it.
    request_state: ?[]const u8 = null,
    /// The members this shape does not model, as the peer sent them.
    ///
    /// `Result` declares `[key: string]: unknown` and a `_meta` of its own, so
    /// the member set of a result object is **open** and a member here is one
    /// a peer may legally send: a vendor key, or the carrier itself. None is
    /// ever dropped — the first occurrence and every repeat are carried, for
    /// the reason [`VerbatimMember`] states, and [`encodeInputRequiredResult`]
    /// writes them back last, in the order they arrived.
    ///
    /// The slice aliases the caller's store array rather than copying it, so it
    /// is valid until that array is written again or released, and it shares no
    /// storage with the escape scratch. [`VerbatimStore`] states the rule.
    verbatim: []const VerbatimMember = &.{},
};

/// Decode the members of an `InputRequiredResult`.
///
/// `raw` is the `result` object as borrowed JSON text. The caller has already
/// established from the JSON-RPC layer that this is a response, so this reads
/// the members the MRTR rules constrain and carries the rest.
///
/// `verbatim` is the caller's store for the members this shape does not model,
/// and it is the same third-party live region every other result decoder in
/// this module takes: a caller-owned array the caller sizes, so nothing here
/// allocates. It exists because `Result` declares `[key: string]: unknown` and
/// a `_meta` of its own, which makes both a vendor member and the carrier
/// members a peer may legally send, and this is the result a client answers
/// with the body it re-encoded. Skipping them would drop them on that answer
/// with no error anywhere.
///
/// A caller that does not care what the result carried beyond its three
/// members still passes one — the array it has, sized for what it expects.
/// Exhaustion is `error.BufferTooSmall`, which is a refusal and never a
/// truncation, so a store that is too small is a loud mistake rather than a
/// result that has quietly lost a member the peer sent.
///
/// The order is the ten section 4.10.3 decoders use — `raw`, the caller's
/// regions, `scratch` — and the position is the same one in all of them, so a
/// caller who has learned one has learned the other eleven.
///
/// On any error nothing is returned, and nothing already written into
/// `verbatim` may be read as part of a result: the slice in
/// [`InputRequiredResult.verbatim`] was never formed, so a caller that fixes
/// the fault and calls again re-reads `raw` and writes over what the first
/// attempt left. `raw` and `scratch` are borrowed for the call and never
/// retained.
pub fn decodeInputRequiredResult(
    raw: []const u8,
    verbatim: []VerbatimMember,
    scratch: []u8,
) DecodeError!InputRequiredResult {
    var reader = json.Reader.init(raw);
    var store = VerbatimStore.init(verbatim);
    const at = store.mark();
    var result: InputRequiredResult = .{};

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "resultType")) {
            try claimFirst(&result.result_type.value, &reader, scratch, takeInterimResultType);
        } else if (std.mem.eql(u8, key, "inputRequests")) {
            try claimFirst(&result.input_requests, &reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "requestState")) {
            try claimFirst(&result.request_state, &reader, scratch, takeString);
        } else {
            try takeVerbatim(key, &reader, &store, scratch);
        }
    }

    // A result object is one JSON value, for the reason stated in
    // `decodeResultType`. This is the decoder a caller re-encodes most often —
    // the client answers the interim result with a retry — so the tail is
    // dropped on the retry the same way, and nothing downstream reports it.
    const open_members = try closeResult(&reader, &store, at);

    // "At least one of inputRequests or requestState MUST be present."
    if (result.input_requests == null and result.request_state == null) {
        return error.MissingField;
    }
    result.verbatim = open_members;
    return result;
}

/// Encode an [`InputRequiredResult`], as a whole result object.
///
/// Public because [`decodeInputRequiredResult`] is, and for the same reason
/// [`encodeResultType`] is: a decoder with no encoder is the asymmetry this
/// module no longer has. A server implementing the multi round-trip pattern
/// writes this interim result, and it is one of the three rows section 4.10.1
/// gives a second result type to, so it is a body a server both reads and
/// writes.
///
/// The inverse of [`decodeInputRequiredResult`] for the values it produces,
/// which is what a member the shape does not model buys: `Result`
/// declares `[key: string]: unknown` and a `_meta` of its own, so such a member
/// is one a peer may legally send and it comes back in
/// [`InputRequiredResult.verbatim`] as the lexeme it arrived as rather than
/// being skipped. [`VerbatimMember`] states what that preserves and what it
/// does not; the short of it is that member order is the encoder's, so the
/// encoding is stable rather than a copy of the peer's byte order.
///
/// The three modelled members come first, in the order [`inputRequired`]
/// writes them, and the carried members follow in the order the peer sent them.
/// `inputRequests` is spliced as the lexeme it arrived as, `requestState` is
/// written as a JSON string literal so the escapes do not end the member early,
/// and a carried member is spliced whole after [`checkVerbatim`] has held it to
/// one JSON value. `error.InvalidField` names a value that is not one whole
/// JSON value and lands before the first byte; after that the only failure
/// left is `error.BufferTooSmall` from the writer, which leaves what it had
/// already written in the caller's buffer.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodeInputRequiredResult`] produces and not for
/// any value handed to it. In particular `request_state` must be valid UTF-8
/// here; [`inputRequired`] is the entry point that checks it.
pub fn encodeInputRequiredResult(
    result: InputRequiredResult,
    writer: *json.Writer,
) EncodeError!void {
    // Checked before the first byte, for the reason `acp.encodePermissionRequest`
    // states: a refusal halfway through would leave `{"resultType":"input_` in
    // the caller's buffer, which is neither a result nor nothing, so a caller
    // that sized the buffer for the refusal would have to discard what it
    // holds rather than read it.
    try checkRaw(&.{result.input_requests}, 1);
    try checkVerbatim(result.verbatim, 1);

    // The separator belongs to the object writer rather than to each member
    // here, for the reason `ObjectWriter` states: `resultType` is optional, and
    // a comma where that member stood is a document no reader is right to
    // accept.
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeResultType(&object, result.result_type);
    try object.optRaw("inputRequests", result.input_requests);
    try object.optText("requestState", result.request_state);
    try object.verbatim(result.verbatim);
    try object.close();
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

/// Write the interim result body for `method`, or refuse the method.
///
/// PROTOCOLS.md 4.7 lets `tools/call`, `resources/read` and `prompts/get`
/// answer with an interim result, and [`permitsMrtr`] is that list. A server
/// that wants one on any other method is refused here rather than on the wire,
/// because a peer has to treat such a result as invalid. That refusal is the
/// first thing the call does and costs the caller no buffer: `out` and
/// `requests` are both untouched.
///
/// What comes back is the body and not the frame. The caller wraps it with
/// `conn.respond`, so the id the answer echoes is the one the connection
/// decoded rather than one written here. The result borrows `out` and is
/// invalidated by the next write to it.
///
/// `requests` is spliced as written, because it is a JSON object the caller
/// built and keyed by the server-assigned ids. It is also the one value here
/// the caller built rather than decoded, so this call holds the caller to it
/// rather than trusting it: `error.InvalidField` is the refusal when `requests`
/// is not exactly one complete JSON object — a scalar, an array, a member that
/// does not parse, or a second document behind the closing brace. Each of those
/// used to be spliced, and the body it produced is one
/// [`decodeInputRequiredResult`] and [`classifyResult`] both refuse, after the
/// peer had already been sent it and with nothing on the sending side to say
/// so. The check runs before the first byte, so a refused call leaves `out`
/// exactly as the caller passed it and the retry after a fix reads a whole body.
/// Neither the names nor the members inside are checked: PROTOCOLS.md 4.7
/// constrains the member to being a map, and a caller that needs an inner
/// `method` checked reads the map itself and refuses a name outside the three
/// with [`lookupInputRequest`].
///
/// `request_state` is a string and not an object, so it is written as a JSON
/// string literal with the escapes JSON requires, and what the peer reads back
/// decodes to the characters that were passed in. Splicing it would have ended
/// the member at the first quote in it and handed the peer a different state.
/// It is opaque and attacker controlled besides, and PROTOCOLS.md 4.7 requires
/// a server to integrity-protect it wherever it influences authorization.
///
/// That string is validated too, which is the one caller obligation
/// [`json.Writer.string`] deliberately leaves open. The writer escapes every
/// byte JSON names and passes every other one through, so a state carrying a
/// stray byte would produce a literal this library's own
/// [`json.Reader.string`] then refuses with `error.InvalidUtf8` on the far side
/// of the wire — a body the sending side reported as written and the receiving
/// side rejected. `error.InvalidField` is the right name for it rather than
/// `error.BufferTooSmall`, because the fault is a value that is not JSON text
/// this may quote and not a buffer that is too small; it lands before the first
/// byte, so a refused call leaves `out` exactly as the caller passed it.
///
/// What can still fail once those three checks have passed is room:
/// `error.BufferTooSmall` from any write below, with the writer's partial
/// output left in `out`. A caller that grew the buffer and called again gets
/// the whole body; one sent on the truncated prefix would hand the peer a state
/// the server never chose, and the retry that comes back would key off it.
///
/// It takes no revision and needs none: [`permitsMrtr`] reads a name and no
/// revision, and the 4.7 list is the same at both. Everything below is decided
/// from the method name and the two values the caller already holds, which is
/// what makes this a codec rule rather than a session one.
///
/// This is not a second copy of [`encodeInputRequiredResult`], and the
/// difference is what each is handed rather than what either writes. That one
/// writes the members a decoded value carries, which may be two rather than
/// three, and accepts any one JSON value where this one requires the map 4.7
/// names; this one always writes the three members 4.6 and 4.7 require, refuses
/// the method before the first byte, and checks state text where the typed
/// encoder keeps the UTF-8 caller precondition. For a whole interim result,
/// both write the same modeled members in the same order.
pub fn inputRequired(
    method: []const u8,
    requests: []const u8,
    request_state: []const u8,
    out: []u8,
) ResultError![]const u8 {
    if (!permitsMrtr(method)) return error.InputRequiredUnexpected;
    // Second, and still before the first byte. `requests` is the one value
    // here the caller built rather than decoded, and PROTOCOLS.md 4.7 types it
    // as a map.
    if (!isOneJsonObject(requests)) return error.InvalidField;
    // Third, and the last of the two caller-built values.
    // `json.Writer.string` does not validate UTF-8 and escapes only the bytes
    // JSON names, so a stray byte here becomes a literal this library's own
    // reader refuses on the far side of the wire.
    if (!std.unicode.utf8ValidateSlice(request_state)) return error.InvalidField;
    var writer = json.Writer.init(out);
    // `resultType` first, because PROTOCOLS.md 4.6 puts it on every
    // result, then the two members 4.7 names beside it in the order the
    // table lists them. Every write below can fail for want of room and
    // for no other reason: the writer escapes a string rather than
    // refusing one.
    writer.slice("{\"resultType\":\"" ++ result_type_value.input_required ++
        "\",\"inputRequests\":") catch return error.BufferTooSmall;
    writer.slice(requests) catch return error.BufferTooSmall;
    writer.slice(",\"requestState\":") catch return error.BufferTooSmall;
    writer.string(request_state) catch return error.BufferTooSmall;
    writer.byte('}') catch return error.BufferTooSmall;
    return writer.written();
}

/// Which leg a request's `params` put it on.
///
/// The normative no-cache rule reads "requests carrying `inputResponses` or
/// `requestState`", so presence of either member is the whole test and the
/// members are not walked: an `inputResponses` map a client cannot have filled
/// yet still puts the request on the retry leg, and a client that read only
/// the method would cache a result the specification forbids caching.
///
/// `params` is a borrowed JSON object as it arrived. A peer that sends no
/// params at all has sent nothing that can be a retry, and an empty object
/// has sent nothing either, so both are `.original`.
///
/// ## Why this has no encoder
///
/// A leg is derived from the caller's whole `params` document, and there is
/// nothing for it to write back: the member a retry carries is the answer the
/// caller put in it, not a value this function produced. An `encodeCacheLeg`
/// would have to invent a `params` document, and the one it invented would be
/// a member set the specification does not define rather than the caller's
/// own bytes. So there is no encoder here, and its absence is the design
/// rather than an omission — a decoder with no encoder is otherwise the hole
/// this module closed across [`encodeResultType`] and
/// [`encodeInputRequiredResult`].
///
/// A caller that needs to *send* the retry leg builds the members 4.7 names
/// and hands them to its own writer. This answers only which of the two legs a
/// document it was handed is on.
pub fn decodeCacheLeg(params: []const u8, scratch: []u8) DecodeError!CacheLeg {
    var reader = json.Reader.init(params);
    var leg: CacheLeg = .original;

    // An empty object is a request that can have been on no leg rather than a
    // refusal, so the loop is skipped and not the function: the check below
    // then stands for the empty object as well.
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "inputResponses") or
                std.mem.eql(u8, key, "requestState"))
            {
                leg = .mrtr_retry;
            }
            try reader.skipValue(scratch);
        }
    }

    // `params` is one JSON object, for the reason stated in
    // `decodeResultType`. Nothing re-encodes a `CacheLeg` either, so a tail
    // would cost no bytes on the way out; it would only mean the leg was read
    // off the first of two documents a peer sent as one.
    if (!reader.atEnd()) return error.MalformedJson;
    return leg;
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
    /// Asking a server to repeat server-set context values in a client request.
    ///
    /// Named here because the name is the only thing that carries the
    /// deprecation: section 4.9 lists the feature, and nothing in the request
    /// or result types encodes it. A peer that still sends it decodes, because
    /// the members it affects are open.
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

// --- 4.10 Result payloads -------------------------------------------------------

/// A member a result object carried that this shape does not name.
///
/// PROTOCOLS.md section 4.10.6 opens the member set of *any* result object:
/// `Result` declares `[key: string]: unknown`, and `basic/index.md` says a
/// result "MAY follow any JSON object structure". A key the shape cannot hold
/// cannot be dropped either, because section 2 requires that re-encoding what
/// a decoder read reproduce the wire values it read — every member, its value
/// and its presence. That is the rule `bridge.Envelope` and
/// `bridge.OutcomePayload` follow, and a typed shape is exactly what re-opened
/// a loss that had been closed for the life of this repository.
///
/// Every occurrence is carried, not the first one. A member this shape does
/// not name is never interpreted, so there is no value for the first-wins rule
/// to resolve; that rule guards the members a shape *does* name, where a
/// later occurrence must not be able to make a failed comparison pass.
/// Keeping one and dropping the next would be the silent loss this type
/// exists to prevent.
///
/// ## What re-encoding preserves, and what it does not
///
/// Re-encoding a decoded value reproduces every wire value that value carried:
/// each modelled member with the value the decoder read, each member's
/// presence or absence, and every open member of this kind. It does not
/// reproduce the **byte** form, and the three things it does not are all
/// different spellings of the same wire values:
///
/// - Member order is the encoder's. The modelled members are written in a
///   fixed order and the carried ones follow in the order the peer sent them,
///   so a document whose peer wrote them in another order re-encodes to the
///   canonical one.
/// - Insignificant whitespace is not preserved.
/// - `key` is the decoded name, not the source spelling, so `"\u0041"` arrives
///   as `"A"` and is written back that way.
///
/// The encoding is **stable** in exchange: the same decoded value always
/// encodes to the same bytes, which is the property a caller relies on when it
/// compares an answer against a body it built. A caller that needs the peer's
/// own bytes to survive has to hold them itself — this type never promises
/// them.
///
/// ## Neither half copies
///
/// `key` and `value` are borrowed from two different places and are invalidated
/// by two different writes, so a caller holding this member has to keep two
/// regions alive:
///
/// - `value` always borrows the input document, never the escape scratch: no
///   value of this kind is unescaped, so none of them can name a byte of it.
/// - `key` borrows the escape scratch when the peer wrote the name with an
///   escape and the document otherwise.
///
/// The record itself sits in the caller's [`VerbatimStore`] array and is never
/// copied out of it, so the slice a caller holds aliases that array.
pub const VerbatimMember = struct {
    /// The member name as `json.Reader.nextKey` returned it.
    ///
    /// With no escape this borrows the input document; with one it borrows the
    /// escape scratch the decoder was handed, and a later escaped string from
    /// the same decode takes a region after this one rather than over it. It is
    /// the decoded name rather than the source spelling, so a peer that wrote
    /// `"\u0041"` hands back `"A"` and the encoder writes that back — the same
    /// member name under RFC 8259, in a spelling that differs from the peer's.
    key: []const u8,
    /// The member value as the lexeme it arrived as: exactly one JSON value,
    /// without its name and without the bytes behind it.
    ///
    /// Any JSON type, so a member the peer sent as `null`, a bare number or a
    /// string is a value here too. Borrowed from the input document and never
    /// from the escape scratch, so it stays valid as long as that document does
    /// and independently of how many strings were decoded around it. An
    /// encoder holds it to one whole JSON value and refuses anything else with
    /// `error.InvalidField` before writing a byte.
    value: []const u8,
};

/// The caller-owned store every open member of one decode lands in.
///
/// One array serves a whole document, and each decoded object holds the
/// sub-slice it filled rather than an offset, so a nested element costs its
/// caller no second argument. Regions are handed out in arrival order and are
/// never recycled, which is the rule `json.Reader` states for its escape
/// scratch: a value the caller still holds must not be overwritten by one
/// decoded after it.
///
/// A store with no room left is `error.BufferTooSmall`. Exhaustion is a
/// refusal and never a truncation, because a card whose eleventh skill
/// silently vanished is worse than one refused.
///
/// ## What a copy of this type means
///
/// `arena` is a slice, so copying the store copies the descriptor and **both
/// copies hand out the same `arena` slots**. `used` is a plain counter and not
/// a shared one, so two copies issue their own regions over one array and
/// silently overwrite one another. There is no move-only type in Zig to prevent
/// it, so the rule is the caller's: one array per document, and a second array
/// for the next document. A caller that wants to decode another document and
/// keep the first result reads its members out — they borrow the document, not
/// the store — rather than reusing the store.
///
/// ## What a mark and a range mean
///
/// [`VerbatimStore.mark`] is `used` as it stands and [`VerbatimStore.since`] is
/// `arena[at..used]`, so a mark is an offset into **this** store's array and
/// nothing else. It is not an index into any slice a call returned, and a mark
/// taken from a store over one array cannot be spent on a store over another:
/// `since` would then be asked for a range this store never issued, which
/// slices past its own end. Every region inside a range therefore belongs to
/// whatever filled it and to nothing else — and a nested payload fills the
/// same store, which is what makes the ordering rule below a rule the decoders
/// follow rather than one this type enforces.
///
/// ## Why a nested payload is decoded after its object closes
///
/// A nested payload appends to the same store, so decoding one *during* the
/// enclosing member loop puts the nested object's entries between the
/// enclosing object's own, and [`VerbatimStore.since`] would then hand back
/// entries belonging to something further in. Every decoder below therefore
/// captures a nested payload as a raw lexeme in its loop, takes its own
/// [`VerbatimStore.since`] the moment the loop closes, and only then decodes
/// the lexeme. That is what keeps one object's slice its own.
pub const VerbatimStore = struct {
    /// The caller's array, and the only storage a decode of one document may
    /// fill. Nothing here allocates, so an array that is too small is a refusal
    /// rather than a grow, and a caller sizes it from the document it was
    /// handed — `testkit` derives the bound from the document length rather
    /// than guessing at it.
    ///
    /// Borrowed, not copied, and the store never reallocates or clears it: it
    /// has to stay alive for as long as any slice handed out of it is still
    /// held, and it has to stay unwritten.
    arena: []VerbatimMember,
    /// How much of `arena` is filled: the offset the next
    /// [`VerbatimStore.take`] writes at.
    ///
    /// Monotone within a store's life. It is never reset while a caller still
    /// holds a region and it is never shared between copies of the store, so
    /// "start over" means "hand in a different array".
    used: usize = 0,

    /// An empty store over `arena`.
    ///
    /// Takes no allocator and retains nothing of its own: the array is the
    /// caller's, it is borrowed rather than copied, and it must stay alive and
    /// unwritten for as long as any slice [`VerbatimStore.since`] or
    /// [`VerbatimStore.take`] handed out is still held. A second decode over
    /// the same array starts writing over the first one's members rather than
    /// after them, which is why one array serves one document.
    pub fn init(arena: []VerbatimMember) VerbatimStore {
        return .{ .arena = arena };
    }

    /// Record one member this shape does not name, and hand back its slot.
    ///
    /// `key` and `value` are recorded as given and are borrowed rather than
    /// copied, so they have to outlive the returned slice — `key` from the
    /// escape scratch when the peer wrote the name with an escape, `value`
    /// from the input document, as [`VerbatimMember`] states. The store copies
    /// neither, so nothing here can outlive the buffer it borrowed.
    ///
    /// The returned slice is one element long and aliases `arena` at the
    /// position this call issued, so it stays valid until the next
    /// [`VerbatimStore.take`] on the same store. `error.BufferTooSmall` when
    /// `arena` is full, and nothing is recorded on that path: an exhausted
    /// store is a refusal rather than a member that quietly stopped being
    /// written back.
    pub fn take(
        self: *VerbatimStore,
        key: []const u8,
        value: []const u8,
    ) DecodeError![]const VerbatimMember {
        if (self.used == self.arena.len) return error.BufferTooSmall;
        self.arena[self.used] = .{ .key = key, .value = value };
        const region = self.arena[self.used..][0..1];
        self.used += 1;
        return region;
    }

    /// Where an object is about to start filling the store: `used` as it
    /// stands, with nothing written or reserved.
    ///
    /// An offset into **this** store's `arena` and nothing else, to be spent on
    /// [`VerbatimStore.since`]. It is not an index into a slice any other call
    /// returned, and a mark taken from a store over one array cannot be spent
    /// on a store over another.
    pub fn mark(self: *const VerbatimStore) usize {
        return self.used;
    }

    /// The members filled since `at`, in arrival order.
    ///
    /// Read this the moment the enclosing member loop closes, for the reason
    /// the type documents: a nested payload appended after this call lands
    /// inside the range a later `since` hands back, and the object would then
    /// hold members that belong to something further in. `at` must be a mark
    /// this store returned.
    ///
    /// The slice borrows `arena`, and each element borrows the input document
    /// and the escape scratch as [`VerbatimMember`] states. A decode into the
    /// same storage invalidates both, which is why this is read once and kept.
    pub fn since(self: *const VerbatimStore, at: usize) []const VerbatimMember {
        return self.arena[at..self.used];
    }
};

/// Carry one member the shape does not name.
fn takeVerbatim(
    key: []const u8,
    reader: *json.Reader,
    store: *VerbatimStore,
    scratch: []u8,
) DecodeError!void {
    const value = try reader.rawValue(scratch);
    _ = try store.take(key, value);
}

/// Resolve one member this shape names, first-wins.
///
/// PROTOCOLS.md section 2 gives the first occurrence the answer, for the reason
/// `json.memberText` states: a later member must not be able to make a failed
/// comparison pass. The converse holds here as well — a repeat that has already
/// been resolved is consumed and not interpreted, so it can neither rewrite the
/// value nor make a decode that had already passed fail. That second half was
/// open in `CacheableReader`, where the value parsed on every occurrence and
/// only the assignment was guarded, and it was open the other way in three
/// decoders that had no guard at all and so took the last value instead of the
/// first.
///
/// `take` runs on the first occurrence and nowhere else, so a member this
/// decoder validates is validated once. A repeat goes through `skipValue`
/// rather than through `take`, and rather than by being left in the document: a
/// member left behind would be read again as the next key.
///
/// One helper rather than a guard written at each walk, because a guard on its
/// own is what three of the five sites that read these members lacked, and a
/// guard with the read and the validation left above it is what the other two
/// had. `ResultEnvelope`, `CacheableReader`, the three standalone result
/// decoders and the content-block loop all reach for this now, which is what
/// makes one rule settle a body however it is read.
fn claimFirst(
    slot: anytype,
    reader: *json.Reader,
    scratch: []u8,
    comptime take: anytype,
) DecodeError!void {
    if (slot.* != null) return reader.skipValue(scratch);
    slot.* = try take(reader, scratch);
}

/// `claimFirst`'s value reader for a member that is a JSON string.
fn takeString(reader: *json.Reader, scratch: []u8) DecodeError![]const u8 {
    return reader.string(scratch);
}

/// `claimFirst`'s value reader for a member carried as the lexeme it arrived
/// as.
///
/// Both halves the image and audio arms read as a string and the
/// `resource_link` arm writes back as raw text need, which is why a loop that
/// cannot know its arm yet captures the lexeme: the bytes a peer sent are not
/// the bytes a string decodes to. It costs no scratch, so a captured lexeme
/// leaves `Reader.requiredScratchLen` unchanged for the decode that follows.
fn takeRaw(reader: *json.Reader, scratch: []u8) DecodeError![]const u8 {
    return reader.rawValue(scratch);
}

/// `claimFirst`'s value reader for `ttlMs`, a whole number of milliseconds.
fn takeMilliseconds(reader: *json.Reader, _: []u8) DecodeError!u64 {
    return parseMilliseconds(try reader.number());
}

/// `claimFirst`'s value reader for `cacheScope`.
fn takeCacheScope(reader: *json.Reader, scratch: []u8) DecodeError!CacheScope {
    return parseCacheScope(try reader.string(scratch));
}

/// `claimFirst`'s value reader for the `resultType` an interim result carries,
/// which has to be exactly `input_required` for the decoder to accept the
/// result at all.
///
/// The check is inside the reader rather than beside the assignment because a
/// repeat must not be able to refuse a document whose first `resultType` was the
/// right one. `{"resultType":"input_required","resultType":"complete"}` is a
/// peer naming the answer twice, and the library's rule is that the first name
/// decides.
fn takeInterimResultType(reader: *json.Reader, scratch: []u8) DecodeError![]const u8 {
    const text = try reader.string(scratch);
    if (!std.mem.eql(u8, text, result_type_value.input_required)) return error.InvalidField;
    return text;
}

/// `claimFirst`'s value reader for the `type` of a content block, the one
/// claimed member the loop reads as a value rather than capturing: the tag
/// chooses the arm, so nothing ever writes it back as raw text.
fn takeBlockKind(reader: *json.Reader, scratch: []u8) DecodeError!ContentBlockKind {
    return ContentBlockKind.fromString(try reader.string(scratch)) orelse error.UnknownTag;
}

/// Open a reader over a lexeme an enclosing walk captured.
///
/// `json.Reader` keeps its escape-scratch offset per reader, and a reader
/// opened here would start at zero again while sharing the caller's one
/// buffer: it would write its first escaped string over whatever the
/// enclosing walk had already handed out, including a verbatim member
/// **key**, and the encoder would then write back a member name the peer
/// never sent. The offset is the buffer's and not the reader's, so this
/// hands the enclosing walk's high-water mark to the nested one and
/// [`adoptScratch`] takes it back afterwards.
///
/// One region and not two, and deliberately not `scratch[bump..]`: a decode
/// of one document needs `json.Reader.requiredScratchLen` bytes, and that
/// measurement is the **sum** over every escaped string in the document
/// because regions are never recycled. Two readers over one document
/// therefore want the whole buffer, each starting where the last stopped —
/// which is what a caller sizing from that measurement has already sized
/// for, and what carving the buffer in half would break.
fn openLexeme(text: []const u8, parent: *const json.Reader) json.Reader {
    var reader = json.Reader.init(text);
    reader.bump = parent.bump;
    return reader;
}

/// Take back the high-water mark a nested walk reached.
///
/// The enclosing walk decodes again after the nested one — the next element
/// of an array, or the next member — so it has to start past what the
/// nested one wrote. A walk that is finished with the buffer needs no call.
fn adoptScratch(parent: *json.Reader, nested: *const json.Reader) void {
    parent.bump = nested.bump;
}

/// Writes the members of one JSON object, separator included.
///
/// The separator goes in front of every member after the first rather than
/// baked into each one, because every member a section 4.10 result carries is
/// optional and a comma where an omitted member stood is a document no reader
/// is right to accept.
const ObjectWriter = struct {
    writer: *json.Writer,
    written: bool = false,

    fn separator(self: *ObjectWriter) EncodeError!void {
        if (self.written) try self.writer.byte(',');
        self.written = true;
    }

    fn key(self: *ObjectWriter, name: []const u8) EncodeError!void {
        try self.separator();
        try self.writer.string(name);
        try self.writer.byte(':');
    }

    fn text(self: *ObjectWriter, name: []const u8, value: []const u8) EncodeError!void {
        try self.key(name);
        try self.writer.string(value);
    }

    fn optText(self: *ObjectWriter, name: []const u8, value: ?[]const u8) EncodeError!void {
        if (value) |body| try self.text(name, body);
    }

    /// Write a member whose value is carried as raw JSON text.
    ///
    /// Public encoders already checked every raw value at its write depth
    /// before opening the document. This write half does not parse it again.
    fn raw(self: *ObjectWriter, name: []const u8, value: []const u8) EncodeError!void {
        try self.key(name);
        try self.writer.slice(value);
    }

    fn optRaw(self: *ObjectWriter, name: []const u8, value: ?[]const u8) EncodeError!void {
        if (value) |body| try self.raw(name, body);
    }

    fn boolean(self: *ObjectWriter, name: []const u8, value: bool) EncodeError!void {
        try self.key(name);
        try self.writer.slice(if (value) "true" else "false");
    }

    /// Write the members the shape does not name, last.
    fn open(self: *ObjectWriter) EncodeError!void {
        try self.writer.byte('{');
    }

    fn close(self: *ObjectWriter) EncodeError!void {
        try self.writer.byte('}');
    }

    fn verbatim(self: *ObjectWriter, members: []const VerbatimMember) EncodeError!void {
        for (members) |member| try self.raw(member.key, member.value);
    }
};

/// Whether `text` is exactly one JSON value, for a member this library
/// splices.
///
/// A lexeme that arrived from `rawValue` always passes: `rawValue` is this
/// same walk over this same grammar. One a caller built by hand does not, and
/// is refused before a byte of the document reaches the buffer, which is the
/// whole of what "encode validates before writing" asks for here — the writer
/// still owns no state, and the reader still decides what a document means.
///
/// A first-byte test would not do the job. `"{}x"`, `"tru"` and `"1,2"` all
/// open like values and none of them is one, so a document carrying any of
/// them decodes cleanly and does not decode back, which is the inverse
/// PROTOCOLS.md section 2 asks of the pair.
///
/// The walk borrows throughout: `skipValue` takes no scratch because a
/// skipped value produces no slice, so the zero-length buffer below is the
/// whole of what this check allocates.
fn isOneJsonValue(text: []const u8, depth: u32) bool {
    var reader = json.Reader.init(text);
    reader.depth = depth;
    const no_scratch: [0]u8 = .{};
    reader.skipValue(&no_scratch) catch return false;
    return reader.atEnd();
}

/// Whether `text` is exactly one complete JSON **object**, for the
/// `inputRequests` member this module's builder splices.
///
/// `isOneJsonValue` is not enough on its own: PROTOCOLS.md 4.7 types
/// `inputRequests` as a map keyed by the server-assigned ids, so a scalar or an
/// array spliced into the member is a body whose map no reader of this library
/// would resolve. Only the opening byte is asked about here — the walk
/// underneath already proved the lexeme is one whole value, and `peek` is the
/// one step that reads no member.
///
/// The walk borrows throughout and `skipValue` takes no scratch because a
/// skipped value produces no slice, so the zero-length buffer below is the
/// whole of what this check allocates. That is also why member names are not
/// decoded: decoding one would need a buffer sized from the document, and a
/// caller would be handing a constructor scratch it has no other use for.
fn isOneJsonObject(text: []const u8) bool {
    var reader = json.Reader.init(text);
    reader.depth = 1; // `inputRequests` is a member of the result object.
    const no_scratch: [0]u8 = .{};
    reader.skipWhitespace();
    if ((reader.peek() orelse return false) != '{') return false;
    reader.skipValue(&no_scratch) catch return false;
    return reader.atEnd();
}

/// Refuse every member a value carries as raw JSON text, before a byte is
/// written.
///
/// PROTOCOLS.md section 2 requires an encoder to validate before writing, so
/// that it cannot emit bytes its own decoder rejects. The check has to run
/// **before** the first byte, for the reason `acp.encodePermissionRequest`
/// states: a refusal halfway through would leave `{"resultType":"input_` in
/// the caller's buffer, which is neither a document nor nothing, so a caller
/// that sized the buffer for the refusal would have to discard what it holds
/// rather than read it.
///
/// Every public encoder in this section opens with the checks for the whole
/// value it is about to write, elements included, so the refusal is the same
/// wherever in the document the offending member sat.
/// `depth` counts the containers around each raw field at its write position.
fn checkRaw(lexemes: []const ?[]const u8, depth: u32) EncodeError!void {
    for (lexemes) |maybe| {
        const text = maybe orelse continue;
        if (!isOneJsonValue(text, depth)) return error.InvalidField;
    }
}

/// Refuse every member no shape named whose value is not one JSON value,
/// before a byte is written.
///
/// The **name** is not checked, and that is the rule rather than an omission:
/// RFC 8259 makes an object name an arbitrary string, so `{"":1}` is a member
/// the decoders above accept and carry, and refusing to write one back would
/// break PROTOCOLS.md section 2 in the `decode(encode(x)) == x` direction for
/// a document this library itself decodes. `ObjectWriter.key` escapes the
/// name, so an empty one writes `""` and an escaped one writes its value.
fn checkVerbatim(members: []const VerbatimMember, depth: u32) EncodeError!void {
    for (members) |member| {
        if (!isOneJsonValue(member.value, depth)) return error.InvalidField;
    }
}

fn checkResourceContents(contents: ResourceContents, depth: u32) EncodeError!void {
    switch (contents) {
        .text => |value| try checkRaw(&.{value.meta}, depth),
        .blob => |value| try checkRaw(&.{value.meta}, depth),
    }
    try checkVerbatim(switch (contents) {
        .text => |value| value.verbatim,
        .blob => |value| value.verbatim,
    }, depth);
}

fn checkContentBlock(block: ContentBlock, depth: u32) EncodeError!void {
    switch (block) {
        .text => |value| try checkRaw(&.{ value.annotations, value.meta }, depth),
        .image => |value| try checkRaw(&.{ value.annotations, value.meta }, depth),
        .audio => |value| try checkRaw(&.{ value.annotations, value.meta }, depth),
        .resource_link => |value| try checkRaw(&.{ value.icons, value.meta }, depth),
        .resource => |value| {
            try checkResourceContents(value.resource, depth + 1);
            try checkRaw(&.{ value.annotations, value.meta }, depth);
        },
    }
    try checkVerbatim(switch (block) {
        .text => |value| value.verbatim,
        .image => |value| value.verbatim,
        .audio => |value| value.verbatim,
        .resource_link => |value| value.verbatim,
        .resource => |value| value.verbatim,
    }, depth);
}

fn checkPromptMessage(message: PromptMessage, depth: u32) EncodeError!void {
    try checkContentBlock(message.content, depth + 1);
    try checkRaw(&.{message.meta}, depth);
    try checkVerbatim(message.verbatim, depth);
}

fn checkTool(tool: Tool, depth: u32) EncodeError!void {
    try checkRaw(&.{
        tool.input_schema,
        tool.output_schema,
        tool.annotations,
        tool.icons,
        tool.meta,
    }, depth);
    try checkVerbatim(tool.verbatim, depth);
}

/// The members every section 4.10 result object carries, collected apart from
/// the payload so the result decoders share one walk of them.
///
/// This reads exactly the two members that sit on **every** result, and not
/// one more. `ttlMs` and `cacheScope` live in [`CacheableReader`] and
/// `nextCursor` is read by the decoders whose results section 4.10.2 makes
/// paginated, because a member a shared reader claims is a member every
/// encoder using that reader has to write back — and three of the ten results
/// model neither. A `ttlMs` on a `CallToolResult`, or a `nextCursor` on a
/// `resources/read` answer, is a member no shape here models, and it comes
/// back through [`VerbatimMember`] instead of being read and dropped. That
/// distinction is the whole difference between a shared envelope and a silent
/// truncation.
const ResultEnvelope = struct {
    result_type: ResultType = ResultType{},
    meta: ?[]const u8 = null,

    /// Read one envelope member, or report that it is not one.
    ///
    /// A repeat is consumed and discarded rather than left in the document,
    /// because a member left behind would be read again as the next key, and
    /// it is not interpreted, because a later member must not be able to make
    /// a comparison that has already passed fail. The first occurrence is the
    /// one kept, for the reason `json.memberText` states, and
    /// [`claimFirst`] is what writes that as one rule rather than five.
    fn read(
        self: *ResultEnvelope,
        key: []const u8,
        reader: *json.Reader,
        scratch: []u8,
    ) DecodeError!bool {
        if (std.mem.eql(u8, key, "resultType")) {
            try claimFirst(&self.result_type.value, reader, scratch, takeString);
        } else if (std.mem.eql(u8, key, "_meta")) {
            try claimFirst(&self.meta, reader, scratch, takeRaw);
        } else {
            return false;
        }
        return true;
    }
};

/// The two members a cacheable result requires, held apart from the envelope.
///
/// Held as optionals even though the result requires them, because presence is
/// a separate fact from the value: a `ttlMs` of `0` and an absent `ttlMs` are
/// the same `u64`, and collapsing the two here would turn a missing required
/// member into a freshness hint of zero. [`CacheableReader.build`] is where
/// the requiredness is enforced, not a default.
const CacheableReader = struct {
    ttl_ms: ?u64 = null,
    cache_scope: ?CacheScope = null,

    /// Read one caching member, or report that it is not one.
    ///
    /// [`claimFirst`] resolves the repeat, and resolving it is what keeps the
    /// parse inside the guard: a second `ttlMs` is consumed and not parsed, so
    /// `{"ttlMs":60000,"cacheScope":"public","ttlMs":-1}` is the cacheable
    /// result its first two members describe rather than a refusal blamed on a
    /// bad freshness hint the peer did not lead with.
    fn read(
        self: *CacheableReader,
        key: []const u8,
        reader: *json.Reader,
        scratch: []u8,
    ) DecodeError!bool {
        if (std.mem.eql(u8, key, "ttlMs")) {
            try claimFirst(&self.ttl_ms, reader, scratch, takeMilliseconds);
        } else if (std.mem.eql(u8, key, "cacheScope")) {
            try claimFirst(&self.cache_scope, reader, scratch, takeCacheScope);
        } else {
            return false;
        }
        return true;
    }

    fn build(self: CacheableReader) DecodeError!Cacheable {
        return .{
            .ttl_ms = self.ttl_ms orelse return error.MissingField,
            .cache_scope = self.cache_scope orelse return error.MissingField,
        };
    }
};

fn writeResultType(object: *ObjectWriter, result_type: ResultType) EncodeError!void {
    try object.optText("resultType", result_type.value);
}

fn writeCacheable(object: *ObjectWriter, cacheable: Cacheable) EncodeError!void {
    try object.key("ttlMs");
    // Digit by digit rather than through a formatter, so the encoder needs no
    // scratch buffer and takes none: a `u64` is at most twenty decimal
    // digits, and a fixed array of them is smaller than any header this
    // library writes beside one. The existing `writeDecimal` cannot serve
    // here because it formats into a caller buffer rather than into the
    // writer, and `ttlMs` has no sign and cannot overflow the array.
    var digits: [20]u8 = undefined;
    var index: usize = digits.len;
    var rest = cacheable.ttl_ms;
    // Looped until the quotient is zero rather than until the array is full,
    // so `0` writes one digit and `60000` writes five. The array cannot
    // overflow: a `u64` is at most twenty decimal digits and there are
    // exactly twenty of them.
    while (true) {
        index -= 1;
        digits[index] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    try object.writer.slice(digits[index..]);
    try object.key("cacheScope");
    try object.writer.string(@tagName(cacheable.cache_scope));
}

// --- 4.10.4 ContentBlock --------------------------------------------------------

/// The five `ContentBlock.type` values, section 4.10.4.
///
/// The set is closed: the schema declares five literal `type` discriminators
/// with no `| string` arm; its generated JSON Schema confirms each with
/// `const`. This constrains discriminator values, not object member names. A sixth
/// string is `error.UnknownTag`, which is the rule
/// `a2a.TaskState.fromTag`, `a2a.Role.fromTag` and `acp.PermissionOptionKind`
/// already follow and the reason `root.DecodeError` carries `UnknownTag` at
/// all. `SPEC-DECISIONS.md` section 5 records why that and the open result
/// object beside it are not in tension.
pub const ContentBlockKind = enum {
    text,
    image,
    audio,
    resource_link,
    resource,

    /// The tag a wire `type` names, or null for one this revision does not
    /// define.
    ///
    /// Null rather than a default: the set is closed, so a sixth string is a
    /// block this revision cannot read and not the first of the five. Where a
    /// decoder has an error to report it turns the null into
    /// `error.UnknownTag`; a caller holding the string decides for itself. The
    /// comparison is exact, so `"Text"` names nothing. `text` is only read and
    /// the result is a tag, so nothing is borrowed and kept.
    pub fn fromString(text: []const u8) ?ContentBlockKind {
        if (std.mem.eql(u8, text, content_block_type.text)) return .text;
        if (std.mem.eql(u8, text, content_block_type.image)) return .image;
        if (std.mem.eql(u8, text, content_block_type.audio)) return .audio;
        if (std.mem.eql(u8, text, content_block_type.resource_link)) return .resource_link;
        if (std.mem.eql(u8, text, content_block_type.resource)) return .resource;
        return null;
    }

    /// The wire spelling of this tag, which is what a peer sends.
    ///
    /// Points at this module's own `content_block_type` literals and borrows
    /// static memory, so the result outlives every caller and needs no copy
    /// and no allocation.
    pub fn string(self: ContentBlockKind) []const u8 {
        return switch (self) {
            .text => content_block_type.text,
            .image => content_block_type.image,
            .audio => content_block_type.audio,
            .resource_link => content_block_type.resource_link,
            .resource => content_block_type.resource,
        };
    }
};

/// The two `Role` values, section 4.10.3.
pub const Role = enum {
    user,
    assistant,

    /// The role a wire `role` names, or null for one this revision does not
    /// define.
    ///
    /// Null rather than a default, for the reason
    /// [`ContentBlockKind.fromString`] states: the set is closed, so `system`
    /// is a third role a peer may send rather than the first of two. Where a
    /// decoder has an error to report it turns the null into
    /// `error.UnknownTag`. `text` is only read and the result is a tag, so
    /// nothing is borrowed and kept.
    pub fn fromString(text: []const u8) ?Role {
        if (std.mem.eql(u8, text, role.user)) return .user;
        if (std.mem.eql(u8, text, role.assistant)) return .assistant;
        return null;
    }

    /// The wire spelling of this role, which is what a peer sends.
    ///
    /// Points at this module's own `role` literals and borrows static memory,
    /// so the result outlives every caller and needs no copy.
    pub fn string(self: Role) []const u8 {
        return switch (self) {
            .user => role.user,
            .assistant => role.assistant,
        };
    }
};

/// A `TextContent` block: `type: "text"` and a `text` string.
///
/// `text` is a decoded string, `annotations` and `meta` are JSON lexemes, and
/// `verbatim` is a carried member — each as the module rule at the top of this
/// file states. Nothing here is required beyond `text`: a block the peer wrote
/// with no `annotations` and no `_meta` decodes with both absent, and that is
/// the same value as one whose peers sent them empty.
pub const TextContent = struct {
    text: []const u8,
    /// The `Annotations` object, carried as the lexeme it arrived as.
    ///
    /// Section 4.10.5 puts `annotations` in the list of sequences inside an
    /// element, and section 4.10.7 records that the source does not say
    /// whether `annotations.priority` is an integer or a real. Modelling the
    /// object would mean settling a question the source leaves open, so it is
    /// carried: a typed shape cannot hold a key a peer may send, and dropping
    /// one is the defect `bridge.Envelope.meta` exists to avoid. A consumer
    /// that needs the members reads the lexeme.
    annotations: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// An `ImageContent` block: `type: "image"`, base64 `data`, a `mimeType`.
///
/// `data` and `mime_type` are decoded strings, `annotations` and `meta` are
/// JSON lexemes, and `verbatim` is a carried member — each as the module rule
/// at the top of this file states. Both required members are required: a block
/// without them is `error.MissingField` and not an empty image.
pub const ImageContent = struct {
    /// The base64 **string**, not bytes.
    ///
    /// `server/prompts.md` requires image data to be base64-encoded and to
    /// carry a valid MIME type, and the same for audio. The alphabet is not
    /// checked here: the requirement is on the server that produces it, and a
    /// client that refused a block it could display would be the wrong
    /// reader. The value is carried so the consumer that cares can run
    /// `json.base64.decode` itself.
    data: []const u8,
    mime_type: []const u8,
    annotations: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// An `AudioContent` block. The same two required members as the image.
///
/// `data` and `mime_type` are decoded strings, `annotations` and `meta` are
/// JSON lexemes, and `verbatim` is a carried member — each as the module rule
/// at the top of this file states, and for the same reason
/// [`ImageContent.data`] carries its base64 as a string.
pub const AudioContent = struct {
    data: []const u8,
    mime_type: []const u8,
    annotations: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// A `ResourceLink` block: a `Resource` with a `type` tag added.
///
/// Section 4.10.4 is explicit that the same underlying object appears with
/// and without the tag depending on which result carries it, so `type` is
/// written from the union and is not a field here. Only the members
/// PROTOCOLS.md names are modelled; `mimeType`, `size`, `description` and
/// `annotations` are among the ones it does not, and a block carrying them is
/// carried in [`ResourceLink.verbatim`] rather than refused.
///
/// `uri`, `name` and `title` are decoded strings, `icons` and `meta` are JSON
/// lexemes, and `verbatim` is a carried member — each as the module rule at the
/// top of this file states.
pub const ResourceLink = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    icons: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// An `EmbeddedResource` block: `type: "resource"` and one `resource`.
///
/// `resource` is a decoded value rather than a slice of this block's own:
/// reading it appends to the same caller store the block's own `verbatim` came
/// from, which is why the block's slice is taken before the resource is read.
/// `annotations` and `meta` are JSON lexemes and `verbatim` is a carried
/// member — each as the module rule at the top of this file states.
pub const EmbeddedResource = struct {
    resource: ResourceContents,
    annotations: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// A `ContentBlock`, the closed union section 4.10.4 transcribes.
///
/// The active arm carries the members section 4.10.4 gives that arm; a member
/// belonging to another arm is not refused here but carried in that arm's own
/// `verbatim`, so a block this revision cannot read structurally still encodes
/// back to the document it came from.
pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,
    resource_link: ResourceLink,
    resource: EmbeddedResource,

    /// The tag this block writes as its `type`, and the arm its decoder read.
    ///
    /// A function of the active union member alone, so an encoder can ask
    /// before it has reached the member and a caller can branch on it without
    /// reading the payload. It copies nothing and borrows nothing, and the
    /// block it takes by value is not retained.
    pub fn tag(self: ContentBlock) ContentBlockKind {
        return switch (self) {
            .text => .text,
            .image => .image,
            .audio => .audio,
            .resource_link => .resource_link,
            .resource => .resource,
        };
    }
};

/// `TextResourceContents`: a `uri` and a `text`.
///
/// `uri`, `text` and `mime_type` are decoded strings, `meta` is a JSON lexeme,
/// and `verbatim` is a carried member — each as the module rule at the top of
/// this file states. Only `uri` is required; the union has no discriminator, so
/// what `text` is, is what this arm is.
pub const TextResourceContents = struct {
    uri: []const u8,
    text: []const u8,
    mime_type: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// `BlobResourceContents`: a `uri` and a base64 `blob`.
///
/// `uri`, `blob` and `mime_type` are decoded strings, `meta` is a JSON lexeme,
/// and `verbatim` is a carried member — each as the module rule at the top of
/// this file states. `blob` is the base64 **string**, not bytes, and its
/// alphabet is not checked, for the reason [`ImageContent.data`] states.
pub const BlobResourceContents = struct {
    uri: []const u8,
    blob: []const u8,
    mime_type: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// `TextResourceContents | BlobResourceContents`, which has no discriminator.
///
/// Section 4.10.4 says so outright, and section 4.10.7 records what follows
/// from it: an object carrying both matches both members and the source does
/// not say which to read, and an object carrying neither matches neither.
/// Both are decode failures here rather than a guess.
pub const ResourceContents = union(enum) {
    text: TextResourceContents,
    blob: BlobResourceContents,
};

/// A `PromptMessage`: a `role` and one `ContentBlock`.
///
/// `content` is a single block, not a sequence, and section 4.10.5 names this
/// as the one place a `ContentBlock` stands alone. It is also the reason the
/// decode is two-staged here: the block is captured as a lexeme in the member
/// loop and decoded after it, for the reason [`VerbatimStore`] documents.
///
/// `role` is a tag, `content` is the one block this shape carries, and `meta`
/// is a JSON lexeme with `verbatim` a carried member — each as the module rule
/// at the top of this file states.
pub const PromptMessage = struct {
    role: Role,
    content: ContentBlock,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// A `Tool`, as `tools/list` carries it.
///
/// Only the members PROTOCOLS.md section 4.10.4 names are modelled: `name`
/// from `BaseMetadata`, the optional `title`, the required `inputSchema`, the
/// optional `outputSchema`, `icons` and `_meta`. `description` and
/// `ToolAnnotations` are members the section names without enumerating, and a
/// block carrying them arrives in [`Tool.verbatim`] — which is a refusal to
/// model rather than a refusal to accept, and is the reason the encoder can
/// write one back.
///
/// `name` and `title` are decoded strings, `input_schema`, `output_schema`,
/// `annotations`, `icons` and `meta` are JSON lexemes, and `verbatim` is a
/// carried member — each as the module rule at the top of this file states.
pub const Tool = struct {
    name: []const u8,
    /// The JSON Schema object, carried as the lexeme it arrived as.
    ///
    /// Section 4.10.4 says the root `type` is the literal `"object"`, and
    /// this library does not enforce it: JSON Schema does not require the
    /// keyword to be present, and the authority states the shape rather than
    /// a requirement a receiver may impose. A consumer that needs the
    /// properties reads `json.memberText` over the lexeme.
    input_schema: []const u8,
    title: ?[]const u8 = null,
    output_schema: ?[]const u8 = null,
    /// The `ToolAnnotations` object, whose five optional members PROTOCOLS.md
    /// counts without naming, so it is carried whole.
    annotations: ?[]const u8 = null,
    /// The `icons` array, carried whole.
    ///
    /// Section 4.10.5 names `Icon.sizes` as a sequence inside an element and
    /// says an element type either carries its own `out` slice or gives up on
    /// those members. Giving up by dropping them would break section 2's
    /// inverse, so they are given up by carrying the array instead.
    icons: ?[]const u8 = null,
    meta: ?[]const u8 = null,
    verbatim: []const VerbatimMember = &.{},
};

/// The members `decodeContentBlock`'s loop claims, and the arms that read each.
///
/// One entry per name the loop claims other than the two every arm models, and
/// the table and the loop are that same list: a name the loop claims and this
/// table omits is a name the decoder takes and the encoder never writes, which
/// is the fault the table exists to make impossible to write, and a name here
/// the loop does not claim is a name nothing reads. `type` and `_meta` are
/// absent because all five arms model them, so neither can reach the carry, and
/// a name the loop does not claim arrives through the `else` arm already
/// carried.
///
/// PROTOCOLS.md section 4.10.7 records the five block interfaces as closed, so
/// at the pinned revision no name outside its own arm is legal. That is why the
/// carry is not a requirement the schema imposes and is still not optional: the
/// case it exists for is a peer speaking a later revision, and PROTOCOLS.md
/// section 2 requires decoding to be total there rather than lossy.
const content_block_claims = [_]struct {
    key: []const u8,
    tags: []const ContentBlockKind,
}{
    .{ .key = "text", .tags = &.{.text} },
    .{ .key = "data", .tags = &.{ .image, .audio } },
    .{ .key = "mimeType", .tags = &.{ .image, .audio } },
    .{ .key = "uri", .tags = &.{.resource_link} },
    .{ .key = "name", .tags = &.{.resource_link} },
    .{ .key = "title", .tags = &.{.resource_link} },
    .{ .key = "icons", .tags = &.{.resource_link} },
    .{ .key = "annotations", .tags = &.{ .text, .image, .audio, .resource } },
    .{ .key = "resource", .tags = &.{.resource} },
};

/// Decode one `ContentBlock`.
///
/// An absent `type` is `error.MissingField` and an unrecognised one is
/// `error.UnknownTag`. They are different faults and are kept apart: the
/// first is an object that is not a `ContentBlock` at all, and the second is
/// a block this revision cannot read, which is the case an agent speaking a
/// later revision produces and must not crash an older one.
///
/// The reader is the **caller's**, and this reads one element out of it
/// rather than one document: the member loop stops at this block's closing
/// brace and leaves the reader standing on whatever follows. That is why
/// there is no `atEnd` here, and why [`decodeArray`] — the one caller that
/// owns a document — asks it after the last element. A check in this
/// function would refuse every array with a second element, and a check
/// nowhere would accept a document with a tail behind it.
fn decodeContentBlock(
    reader: *json.Reader,
    store: *VerbatimStore,
    scratch: []u8,
) DecodeError!ContentBlock {
    if (try reader.beginObject()) return error.MissingField;
    const at = store.mark();

    // Every claimed member is captured as the lexeme it arrived as, not decoded
    // here, because the loop cannot know its arm until the `type` beside it has
    // been read: the image and audio arms want `mimeType` as a string, the
    // `resource_link` arm writes it back as raw text, and a block whose tag
    // models neither has to carry it. One capture serves all three, and
    // `json.Reader.rawValue` borrows from the input, so the loop costs no
    // scratch and `requiredScratchLen` still bounds the decodes that follow.
    var kind: ?ContentBlockKind = null;
    var text: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var mime_type: ?[]const u8 = null;
    var uri: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var icons: ?[]const u8 = null;
    var annotations: ?[]const u8 = null;
    var meta: ?[]const u8 = null;
    var resource: ?[]const u8 = null;

    // [`claimFirst`] settles the repeat for every member here, including `type`
    // and including the validation each arm does on the way past: a second
    // `type` is consumed and not parsed, so it can neither rename the block nor
    // refuse one whose first name was already a tag this revision knows.
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "type")) {
            try claimFirst(&kind, reader, scratch, takeBlockKind);
        } else if (std.mem.eql(u8, key, "text")) {
            try claimFirst(&text, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "data")) {
            try claimFirst(&data, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "mimeType")) {
            try claimFirst(&mime_type, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "uri")) {
            try claimFirst(&uri, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "name")) {
            try claimFirst(&name, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "title")) {
            try claimFirst(&title, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "icons")) {
            try claimFirst(&icons, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "annotations")) {
            try claimFirst(&annotations, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "resource")) {
            try claimFirst(&resource, reader, scratch, takeRaw);
        } else if (std.mem.eql(u8, key, "_meta")) {
            try claimFirst(&meta, reader, scratch, takeRaw);
        } else {
            try takeVerbatim(key, reader, store, scratch);
        }
    }

    const tag = kind orelse return error.MissingField;

    // The loop above claims eleven members for every tag and each arm reads a
    // few of them, so most pairs are a member this block accepted and no
    // encoder could write back. A member a decoder accepts has to be able to
    // write itself back — PROTOCOLS.md section 2 — so what the chosen arm does
    // not model is carried into this block's own slice rather than dropped.
    // Before the repair the loop claimed eleven and the carry named two, so
    // seven names were read and thrown away; `size` and `description` were
    // carried the whole time, by arriving through the `else` arm.
    //
    // The name recorded is the one `nextKey` unescaped, the same form
    // `takeVerbatim` records, so a member carried from here and one carried from
    // the `else` arm cannot differ on the wire.
    const claimed = [_]?[]const u8{
        text, data, mime_type, uri, name, title, icons, annotations, resource,
    };
    for (content_block_claims, claimed) |claim, maybe| {
        const value = maybe orelse continue;
        if (std.mem.indexOfScalar(ContentBlockKind, claim.tags, tag) != null) continue;
        _ = try store.take(claim.key, value);
    }

    // Taken before the embedded resource is decoded, so this block's slice
    // holds this block's members and not the resource's.
    const verbatim = store.since(at);

    return switch (tag) {
        .text => .{ .text = .{
            .text = try decodeTextLexeme(
                text orelse return error.MissingField,
                reader,
                scratch,
            ),
            .annotations = annotations,
            .meta = meta,
            .verbatim = verbatim,
        } },
        .image => .{ .image = .{
            .data = try decodeTextLexeme(
                data orelse return error.MissingField,
                reader,
                scratch,
            ),
            .mime_type = try decodeTextLexeme(
                mime_type orelse return error.MissingField,
                reader,
                scratch,
            ),
            .annotations = annotations,
            .meta = meta,
            .verbatim = verbatim,
        } },
        .audio => .{ .audio = .{
            .data = try decodeTextLexeme(
                data orelse return error.MissingField,
                reader,
                scratch,
            ),
            .mime_type = try decodeTextLexeme(
                mime_type orelse return error.MissingField,
                reader,
                scratch,
            ),
            .annotations = annotations,
            .meta = meta,
            .verbatim = verbatim,
        } },
        .resource_link => .{ .resource_link = .{
            .uri = try decodeTextLexeme(
                uri orelse return error.MissingField,
                reader,
                scratch,
            ),
            .name = try decodeTextLexeme(
                name orelse return error.MissingField,
                reader,
                scratch,
            ),
            .title = try decodeOptionalTextLexeme(title, reader, scratch),
            .icons = icons,
            .meta = meta,
            .verbatim = verbatim,
        } },
        .resource => .{ .resource = .{
            .resource = try decodeResourceLexeme(
                resource orelse return error.MissingField,
                reader,
                store,
                scratch,
            ),
            .annotations = annotations,
            .meta = meta,
            .verbatim = verbatim,
        } },
    };
}

fn encodeContentBlock(block: ContentBlock, writer: *json.Writer) EncodeError!void {
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try object.text("type", block.tag().string());
    switch (block) {
        .text => |value| {
            try object.text("text", value.text);
            try object.optRaw("annotations", value.annotations);
            try object.optRaw("_meta", value.meta);
            try object.verbatim(value.verbatim);
        },
        .image => |value| {
            try object.text("data", value.data);
            try object.text("mimeType", value.mime_type);
            try object.optRaw("annotations", value.annotations);
            try object.optRaw("_meta", value.meta);
            try object.verbatim(value.verbatim);
        },
        .audio => |value| {
            try object.text("data", value.data);
            try object.text("mimeType", value.mime_type);
            try object.optRaw("annotations", value.annotations);
            try object.optRaw("_meta", value.meta);
            try object.verbatim(value.verbatim);
        },
        .resource_link => |value| {
            try object.text("uri", value.uri);
            try object.text("name", value.name);
            try object.optText("title", value.title);
            try object.optRaw("icons", value.icons);
            try object.optRaw("_meta", value.meta);
            try object.verbatim(value.verbatim);
        },
        .resource => |value| {
            try object.key("resource");
            try encodeResourceContents(value.resource, writer);
            try object.optRaw("annotations", value.annotations);
            try object.optRaw("_meta", value.meta);
            try object.verbatim(value.verbatim);
        },
    }
    try object.close();
}

/// Decode one `ResourceContents`, which is a union with no discriminator.
///
/// One element of the caller's reader and not one document, so there is no
/// `atEnd` here: [`decodeArray`] asks it, for the reason `decodeContentBlock`
/// states.
fn decodeResourceContents(
    reader: *json.Reader,
    store: *VerbatimStore,
    scratch: []u8,
) DecodeError!ResourceContents {
    if (try reader.beginObject()) return error.MissingField;
    const at = store.mark();

    var uri: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var blob: ?[]const u8 = null;
    var mime_type: ?[]const u8 = null;
    var meta: ?[]const u8 = null;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "uri")) {
            const value = try reader.string(scratch);
            if (uri == null) uri = value;
        } else if (std.mem.eql(u8, key, "text")) {
            const value = try reader.string(scratch);
            if (text == null) text = value;
        } else if (std.mem.eql(u8, key, "blob")) {
            const value = try reader.string(scratch);
            if (blob == null) blob = value;
        } else if (std.mem.eql(u8, key, "mimeType")) {
            const value = try reader.string(scratch);
            if (mime_type == null) mime_type = value;
        } else if (std.mem.eql(u8, key, "_meta")) {
            const value = try reader.rawValue(scratch);
            if (meta == null) meta = value;
        } else {
            try takeVerbatim(key, reader, store, scratch);
        }
    }

    // Taken after the loop closes and before anything below can refuse, for
    // the reason `VerbatimStore` documents.
    const verbatim = store.since(at);
    const resource_uri = uri orelse return error.MissingField;

    // Section 4.10.7, both rows: an object carrying `text` and `blob` matches
    // both members and the source does not say which to read, and an object
    // carrying neither matches neither. Neither case is resolved here.
    if (text) |body| {
        if (blob != null) return error.InvalidField;
        return .{ .text = .{
            .uri = resource_uri,
            .text = body,
            .mime_type = mime_type,
            .meta = meta,
            .verbatim = verbatim,
        } };
    }
    if (blob) |body| {
        return .{ .blob = .{
            .uri = resource_uri,
            .blob = body,
            .mime_type = mime_type,
            .meta = meta,
            .verbatim = verbatim,
        } };
    }
    return error.MissingField;
}

fn encodeResourceContents(contents: ResourceContents, writer: *json.Writer) EncodeError!void {
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    switch (contents) {
        .text => |value| {
            try object.text("uri", value.uri);
            try object.text("text", value.text);
            try object.optText("mimeType", value.mime_type);
            try object.optRaw("_meta", value.meta);
            try object.verbatim(value.verbatim);
        },
        .blob => |value| {
            try object.text("uri", value.uri);
            try object.text("blob", value.blob);
            try object.optText("mimeType", value.mime_type);
            try object.optRaw("_meta", value.meta);
            try object.verbatim(value.verbatim);
        },
    }
    try object.close();
}

/// Decode the string a member lexeme holds.
///
/// One member, two answers: the image and audio arms read `mimeType` as the
/// string both of them require, and the `resource_link` arm writes the same
/// member back as the lexeme it arrived as. Decoding it out of the lexeme
/// rather than in the member loop is what keeps both answers available —
/// reading it as a string in the loop would leave the `resource_link` arm
/// with a decoded value it cannot splice, because the bytes a peer sent are
/// not the bytes a string decodes to.
fn decodeTextLexeme(
    text: []const u8,
    parent: *json.Reader,
    scratch: []u8,
) DecodeError![]const u8 {
    var reader = openLexeme(text, parent);
    const value = try reader.string(scratch);
    // Asked even though `text` came from `rawValue` and is therefore already
    // exactly one JSON value: a private helper is one call away from a caller
    // that hands it something else, which is the reason `decodeArray` and
    // `decodeStrings` ask it of an array lexeme as well.
    if (!reader.atEnd()) return error.MalformedJson;
    adoptScratch(parent, &reader);
    return value;
}

/// Decode the optional string a member lexeme holds.
///
/// The same answer [`decodeTextLexeme`] gives for a member its arm requires,
/// and kept as its own function because `title` is the one optional string
/// among them: a `resource_link` without a `title` is one the peer wrote rather
/// than one this refuses, and an absent member and an empty string stay the two
/// documents they are.
fn decodeOptionalTextLexeme(
    text: ?[]const u8,
    parent: *json.Reader,
    scratch: []u8,
) DecodeError!?[]const u8 {
    const lexeme = text orelse return null;
    const value = try decodeTextLexeme(lexeme, parent, scratch);
    return value;
}

/// Decode a `ResourceContents` out of the lexeme its block captured.
fn decodeResourceLexeme(
    text: []const u8,
    parent: *json.Reader,
    store: *VerbatimStore,
    scratch: []u8,
) DecodeError!ResourceContents {
    var reader = openLexeme(text, parent);
    const contents = try decodeResourceContents(&reader, store, scratch);
    adoptScratch(parent, &reader);
    return contents;
}

/// Decode one `Tool`.
///
/// One element of the caller's reader and not one document, so there is no
/// `atEnd` here: [`decodeArray`] asks it, for the reason `decodeContentBlock`
/// states.
fn decodeTool(
    reader: *json.Reader,
    store: *VerbatimStore,
    scratch: []u8,
) DecodeError!Tool {
    if (try reader.beginObject()) return error.MissingField;
    const at = store.mark();

    var name: ?[]const u8 = null;
    var input_schema: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var output_schema: ?[]const u8 = null;
    var annotations: ?[]const u8 = null;
    var icons: ?[]const u8 = null;
    var meta: ?[]const u8 = null;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "name")) {
            const value = try reader.string(scratch);
            if (name == null) name = value;
        } else if (std.mem.eql(u8, key, "inputSchema")) {
            const value = try reader.rawValue(scratch);
            if (input_schema == null) input_schema = value;
        } else if (std.mem.eql(u8, key, "title")) {
            const value = try reader.string(scratch);
            if (title == null) title = value;
        } else if (std.mem.eql(u8, key, "outputSchema")) {
            const value = try reader.rawValue(scratch);
            if (output_schema == null) output_schema = value;
        } else if (std.mem.eql(u8, key, "annotations")) {
            const value = try reader.rawValue(scratch);
            if (annotations == null) annotations = value;
        } else if (std.mem.eql(u8, key, "icons")) {
            const value = try reader.rawValue(scratch);
            if (icons == null) icons = value;
        } else if (std.mem.eql(u8, key, "_meta")) {
            const value = try reader.rawValue(scratch);
            if (meta == null) meta = value;
        } else {
            try takeVerbatim(key, reader, store, scratch);
        }
    }

    return .{
        .name = name orelse return error.MissingField,
        .input_schema = input_schema orelse return error.MissingField,
        .title = title,
        .output_schema = output_schema,
        .annotations = annotations,
        .icons = icons,
        .meta = meta,
        .verbatim = store.since(at),
    };
}

fn encodeTool(tool: Tool, writer: *json.Writer) EncodeError!void {
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try object.text("name", tool.name);
    try object.raw("inputSchema", tool.input_schema);
    try object.optText("title", tool.title);
    try object.optRaw("outputSchema", tool.output_schema);
    try object.optRaw("annotations", tool.annotations);
    try object.optRaw("icons", tool.icons);
    try object.optRaw("_meta", tool.meta);
    try object.verbatim(tool.verbatim);
    try object.close();
}

/// Decode one `PromptMessage`.
///
/// One element of the caller's reader and not one document, so there is no
/// `atEnd` here: [`decodeArray`] asks it, for the reason `decodeContentBlock`
/// states.
fn decodePromptMessage(
    reader: *json.Reader,
    store: *VerbatimStore,
    scratch: []u8,
) DecodeError!PromptMessage {
    if (try reader.beginObject()) return error.MissingField;
    const at = store.mark();

    var speaker: ?Role = null;
    var content: ?[]const u8 = null;
    var meta: ?[]const u8 = null;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "role")) {
            const value = try reader.string(scratch);
            if (speaker == null) speaker = Role.fromString(value) orelse return error.UnknownTag;
        } else if (std.mem.eql(u8, key, "content")) {
            // Captured rather than decoded, for the reason `VerbatimStore`
            // documents. The first occurrence wins.
            const value = try reader.rawValue(scratch);
            if (content == null) content = value;
        } else if (std.mem.eql(u8, key, "_meta")) {
            const value = try reader.rawValue(scratch);
            if (meta == null) meta = value;
        } else {
            try takeVerbatim(key, reader, store, scratch);
        }
    }

    // Taken before the content block is decoded, so this message's slice
    // holds this message's members and not the block's.
    const verbatim = store.since(at);
    var block_reader = openLexeme(content orelse return error.MissingField, reader);
    const block = try decodeContentBlock(&block_reader, store, scratch);
    adoptScratch(reader, &block_reader);
    return .{
        .role = speaker orelse return error.MissingField,
        .content = block,
        .meta = meta,
        .verbatim = verbatim,
    };
}

fn encodePromptMessage(message: PromptMessage, writer: *json.Writer) EncodeError!void {
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try object.text("role", message.role.string());
    try object.key("content");
    try encodeContentBlock(message.content, writer);
    try object.optRaw("_meta", message.meta);
    try object.verbatim(message.verbatim);
    try object.close();
}

/// Read one caller-owned array member into `out`, returning the filled
/// prefix.
///
/// Every sequence in section 4.10.5 takes this shape: an `out` slice the
/// caller supplies plus a returned count, because a `[]T` the decoder
/// allocated is not available under section 2. Exhaustion is
/// `error.BufferTooSmall` and never a truncation — a card whose eleventh
/// skill silently vanished is worse than one refused.
///
/// `atEnd` is checked even though `text` came from `rawValue` and is therefore
/// already exactly one JSON value, because a private helper is one more call
/// away from a caller that hands it something else. This walk also owns the
/// document for the element decoders it calls: they stop at each element's
/// closing brace and leave the reader standing here, so the tail check
/// belongs after the last element and nowhere else.
///
/// `parent` is the reader the enclosing walk is standing on. Every element
/// borrows the caller's one escape scratch through the hand-off
/// [`openLexeme`] opens, so the second element cannot write over strings the
/// first is still holding.
fn decodeArray(
    comptime T: type,
    text: []const u8,
    out: []T,
    decode_one: *const fn (*json.Reader, *VerbatimStore, []u8) DecodeError!T,
    store: *VerbatimStore,
    parent: *json.Reader,
    scratch: []u8,
) DecodeError![]const T {
    var reader = openLexeme(text, parent);
    var count: usize = 0;
    // Read under the `if` rather than returned from it, so the empty array
    // reaches the `atEnd` below like every other one.
    if (!try reader.beginArray()) {
        while (try reader.nextArrayElement()) {
            if (count == out.len) return error.BufferTooSmall;
            out[count] = try decode_one(&reader, store, scratch);
            count += 1;
        }
    }
    if (!reader.atEnd()) return error.MalformedJson;
    adoptScratch(parent, &reader);
    return out[0..count];
}

/// Read a `string[]` into caller-owned storage.
///
/// Every element stays live at once, so the regions are handed out one after
/// another and never recycled, and `parent` carries where the enclosing walk
/// stopped for the reason [`decodeArray`] states.
fn decodeStrings(
    text: []const u8,
    out: [][]const u8,
    parent: *json.Reader,
    scratch: []u8,
) DecodeError![]const []const u8 {
    var reader = openLexeme(text, parent);
    var count: usize = 0;
    if (!try reader.beginArray()) {
        while (try reader.nextArrayElement()) {
            if (count == out.len) return error.BufferTooSmall;
            out[count] = try reader.string(scratch);
            count += 1;
        }
    }
    if (!reader.atEnd()) return error.MalformedJson;
    adoptScratch(parent, &reader);
    return out[0..count];
}

fn writeStringArray(values: []const []const u8, writer: *json.Writer) EncodeError!void {
    try writer.byte('[');
    for (values, 0..) |value, at| {
        if (at != 0) try writer.byte(',');
        try writer.string(value);
    }
    try writer.byte(']');
}

/// Close a result document: the members the envelope did not claim are
/// carried, and a document with a tail is refused.
///
/// Every result decoder ends here, for the reason `decodeResultType` states:
/// bytes after the closing brace are a second document the transport did not
/// split, and an encoder has nowhere inside an object to put them, so
/// accepting one would let a document the encoder could not have produced come
/// back out of a decoder that called it whole. [`VerbatimMember`] states what
/// re-encoding does preserve.
fn closeResult(
    reader: *json.Reader,
    store: *VerbatimStore,
    at: usize,
) DecodeError![]const VerbatimMember {
    if (!reader.atEnd()) return error.MalformedJson;
    return store.since(at);
}

// --- 4.10.2 The list page -------------------------------------------------------

/// The one member a paginated result adds, section 4.10.2.
///
/// `PaginatedResult` is `/** @internal */` in the schema, so it has no wire
/// discriminator: a result is paginated because it carries `nextCursor` and
/// not because it announced it. `ReadResourceResult` is cacheable but **not**
/// paginated, and `resources/read` returns a sequence without a `nextCursor`,
/// which is the row a decoder cannot get right from the field name alone.
pub const PaginatedResult = struct {
    /// The cursor for the next page, as a decoded string, or null when this is
    /// the last page.
    ///
    /// Null is the absence the peer wrote, not a default: a page with a
    /// `nextCursor` and one without are different facts, and a result this
    /// module reads is not paginated at all on three of the ten rows.
    next_cursor: ?[]const u8 = null,
};

/// Read the page a result object carries, on its own.
///
/// It answers "is there another page" without decoding the payload, which is
/// the question a caller paging a list asks before it commits to holding the
/// elements. Everything else the document carries is kept in
/// [`Page.verbatim`] of the returned envelope rather than dropped,
/// because a member this shape does not name cannot be written back if it is
/// not carried.
///
/// `raw` is the `result` object as borrowed JSON text and the returned value
/// keeps slices of it: `nextCursor` is a decoded string and `meta` a lexeme, so
/// both borrow the document or the escape scratch as the module rule states,
/// and `verbatim` aliases the caller's store array. `raw` and `scratch` must
/// both outlive the returned [`Page`].
///
/// `verbatim` is filled with every member this shape does not model, the
/// payload included, so the store has to be sized for the whole document rather
/// than for the envelope. Exhaustion is `error.BufferTooSmall` and never a
/// truncation.
///
/// On any error nothing is returned and nothing already in `verbatim` may be
/// read as part of a page: [`Page.verbatim`] was never formed, so a caller that
/// fixes the fault and calls again re-reads `raw` and writes over what the
/// first attempt left.
pub fn decodePaginatedResult(
    raw: []const u8,
    verbatim: []VerbatimMember,
    scratch: []u8,
) DecodeError!Page {
    var reader = json.Reader.init(raw);
    var store = VerbatimStore.init(verbatim);
    const at = store.mark();
    var envelope: ResultEnvelope = .{};

    // The caching members are captured as lexemes rather than read through
    // `CacheableReader`, because the pair is what section 4.10.2 requires and
    // a document carrying only one of the two is not a cacheable result: it is
    // a member no shape here names, on a result this reader is handed as
    // readily as a cacheable one. Keeping the lexeme is what lets it come back
    // in [`Page.verbatim`] rather than refusing the whole page.
    var ttl: ?[]const u8 = null;
    var scope: ?[]const u8 = null;
    var next_cursor: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (try envelope.read(key, &reader, scratch)) continue;
        if (std.mem.eql(u8, key, "ttlMs")) {
            const value = try reader.rawValue(scratch);
            if (ttl == null) ttl = value;
            continue;
        }
        if (std.mem.eql(u8, key, "cacheScope")) {
            const value = try reader.rawValue(scratch);
            if (scope == null) scope = value;
            continue;
        }
        if (std.mem.eql(u8, key, "nextCursor")) {
            const value = try reader.string(scratch);
            if (next_cursor == null) next_cursor = value;
            continue;
        }
        try takeVerbatim(key, &reader, &store, scratch);
    }

    // Built only when the document carried the pair. Three of the ten results
    // section 4.10.1 names are not cacheable and this reader is handed any of
    // them, so demanding both here would refuse a legal answer to a question
    // about paging — and one of the two is the same refusal one step short.
    const cacheable: ?Cacheable = if (ttl != null and scope != null)
        try buildCacheable(ttl.?, scope.?, &reader, scratch)
    else
        null;
    if (cacheable == null) {
        if (ttl) |value| _ = try store.take("ttlMs", value);
        if (scope) |value| _ = try store.take("cacheScope", value);
    }
    const carried = try closeResult(&reader, &store, at);

    return .{
        .result_type = envelope.result_type,
        .cacheable = cacheable,
        .page = .{ .next_cursor = next_cursor },
        .meta = envelope.meta,
        .verbatim = carried,
    };
}

/// Read the caching pair out of the two lexemes the member loop captured.
///
/// One reader per lexeme because each lexeme is a value of its own, and
/// `ttlMs` is a number where `cacheScope` is a string. Both take their region
/// from the same hand-off as every other nested read, for the reason
/// [`openLexeme`] states.
fn buildCacheable(
    ttl_lexeme: []const u8,
    scope_lexeme: []const u8,
    parent: *json.Reader,
    scratch: []u8,
) DecodeError!Cacheable {
    var ttl_reader = openLexeme(ttl_lexeme, parent);
    const ttl_ms = try parseMilliseconds(try ttl_reader.number());
    if (!ttl_reader.atEnd()) return error.MalformedJson;
    adoptScratch(parent, &ttl_reader);

    var scope_reader = openLexeme(scope_lexeme, parent);
    const cache_scope = try parseCacheScope(try scope_reader.string(scratch));
    if (!scope_reader.atEnd()) return error.MalformedJson;
    adoptScratch(parent, &scope_reader);

    return .{ .ttl_ms = ttl_ms, .cache_scope = cache_scope };
}

/// A result read only for its page, and for what it carries beside it.
///
/// `next_cursor` is a decoded string and `meta` a JSON lexeme, and `verbatim`
/// is a carried member aliasing the caller's store array — each as the module
/// rule at the top of this file states, and each borrowed from the document
/// and the store the [`decodePaginatedResult`] call was given rather than
/// copied.
pub const Page = struct {
    result_type: ResultType = ResultType{},
    /// The caching members, or null when the document did not carry both.
    ///
    /// Optional rather than required because this reader answers "is there
    /// another page" and is handed any of the ten results; three of them are
    /// not cacheable. A document that carries one of the two and not the
    /// other is not a cacheable result either, so the member it did carry
    /// comes back in [`Page.verbatim`] rather than refusing the page. Reading
    /// the pair and keeping it is what lets the encoder be their inverse.
    cacheable: ?Cacheable = null,
    page: PaginatedResult = PaginatedResult{},
    /// The `_meta` object, carried whole as the lexeme it arrived as.
    ///
    /// Optional and not defaulted: a peer that sent no `_meta` and one that sent
    /// `{}` are the two documents they are.
    meta: ?[]const u8 = null,
    /// The members this shape does not model, including the whole payload.
    ///
    /// This reader skips the payload rather than decoding it, so the payload
    /// is the member most often found here — and it is carried for that reason
    /// rather than dropped, as [`VerbatimMember`] requires.
    verbatim: []const VerbatimMember = &.{},
};

/// Encode what [`decodePaginatedResult`] read.
///
/// The inverse of it for the values [`decodePaginatedResult`] produces, and
/// what a member it does not model buys: the payload and every other one
/// comes back in [`Page.verbatim`] rather than being skipped, and
/// [`VerbatimMember`] states what that preserves and what it does not — member
/// order is the encoder's, so the encoding is stable rather than a copy of the
/// peer's byte order.
///
/// `error.InvalidField` names a lexeme that is not one whole JSON value and
/// lands before the first byte; after that the only failure left is
/// `error.BufferTooSmall` from the writer, which leaves what it had already
/// written in the caller's buffer.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodePaginatedResult`] produces and not for any
/// value handed to it.
pub fn encodePaginatedResult(page: Page, writer: *json.Writer) EncodeError!void {
    try checkRaw(&.{page.meta}, 1);
    try checkVerbatim(page.verbatim, 1);
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeResultType(&object, page.result_type);
    if (page.cacheable) |cacheable| try writeCacheable(&object, cacheable);
    try writeNextCursor(&object, page.page);
    try object.optRaw("_meta", page.meta);
    try object.verbatim(page.verbatim);
    try object.close();
}

fn writeNextCursor(object: *ObjectWriter, page: PaginatedResult) EncodeError!void {
    try object.optText("nextCursor", page.next_cursor);
}

/// Encode the two members a cacheable result requires, as a whole object.
///
/// ## What this is, and what composes with it
///
/// What it writes is `{"ttlMs":…,"cacheScope":…}` and nothing else, so it is a
/// **fragment constructor rather than a complete result**: PROTOCOLS.md 4.6
/// puts `resultType` on every result, so an object this writes is not one
/// [`checkResult`] would accept and not one any typed decoder reads as the
/// answer to a method. A caller writing a whole cacheable result composes
/// instead — [`encodeDiscoverResult`], [`encodeToolListResult`],
/// [`encodeResourceReadResult`] and [`encodePaginatedResult`] each write this
/// pair beside their own members — and reaches for this only when the object is
/// genuinely nothing but a freshness hint, as the harness's cache battery
/// does. This is the composition boundary: inside a result encoder the pair is
/// a member, and here it is the whole document.
///
/// It is deliberately not the inverse of [`decodeCacheable`]. That decoder skips
/// every member the caching rules do not govern — it is the rule
/// [`checkResult`] applies to a body it did not build — so a document decoded
/// by it has already lost the members this cannot put back. The result decoders
/// in this section do not skip, and a result round trip through them reproduces
/// its wire values; [`VerbatimMember`] states what that does and does not
/// preserve.
///
/// Both members are constructed here, so there is nothing to validate and no
/// `error.InvalidField` to report: a `u64` and one of the two `cacheScope`
/// literals are always a pair this library's own reader accepts. The only
/// failure is `error.BufferTooSmall`, and the writer leaves what it had already
/// written in the caller's buffer.
pub fn encodeCacheable(cacheable: Cacheable, writer: *json.Writer) EncodeError!void {
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeCacheable(&object, cacheable);
    try object.close();
}

// --- 4.10.3 The typed results ---------------------------------------------------

/// A `CallToolResult`, the answer to `tools/call`.
///
/// `extends Result` and **not** `CacheableResult`, so a tools/call result
/// carries no `ttlMs` and no `cacheScope` and this struct has no place to
/// put them. `content` is required and present-and-empty is well formed, so
/// presence is tracked apart from the count: an empty `content` and an absent
/// one are both a zero-length slice here, and only the decoder's refusal can
/// tell them apart.
///
/// `content` is the caller's own array of blocks, `meta` and
/// `structured_content` are JSON lexemes and `verbatim` is a carried member —
/// each as the module rule at the top of this file states, and each borrowed
/// from the document, the escape scratch or the store array the
/// [`decodeToolCallResult`] call was given rather than copied.
pub const ToolCallResult = struct {
    result_type: ResultType = ResultType{},
    /// The `_meta` object, carried whole as the lexeme it arrived as.
    ///
    /// Optional and not defaulted: a peer that sent no `_meta` and one that sent
    /// `{}` are the two documents they are.
    meta: ?[]const u8 = null,
    /// The blocks, in `out_content` — a slice of the caller's array, not a copy.
    ///
    /// Read-only here, and the decoder does not write through it afterwards, so
    /// a caller may inspect or re-encode the blocks without disturbing the
    /// array. An empty slice means either an empty `content` or a member the
    /// decoder never had, which are different documents and only
    /// `error.MissingField` tells them apart.
    content: []const ContentBlock = &.{},
    /// Any JSON value, conforming to the tool's `outputSchema` if it has one.
    ///
    /// Carried as the lexeme it arrived as. The schema types it `unknown` and
    /// says "any JSON value", so a typed shape here would be a guess about
    /// the tool rather than about the protocol, and a consumer that has the
    /// tool in hand can read the lexeme with the parser it already trusts.
    structured_content: ?[]const u8 = null,
    /// A tool's own failure belongs here and not in a JSON-RPC error, so the
    /// model can see it.
    ///
    /// An optional rather than a `bool`, because absent means false and a
    /// `false` default would make a result that said nothing
    /// indistinguishable from one that said false.
    is_error: ?bool = null,
    /// Unmodeled members of this result object. Nested elements retain their
    /// own members in their own `verbatim` slices.
    ///
    /// Aliases the caller's store array rather than copying it, so it is valid
    /// until that array is written again or released.
    verbatim: []const VerbatimMember = &.{},
};

/// Decode a `CallToolResult`.
///
/// `out_content` is the caller's array of blocks and `verbatim` its store for
/// the members no shape names, across the whole document including the blocks,
/// so size both for the document rather than for the envelope. Every slice the
/// result holds borrows the document, the escape scratch or the store array —
/// the three regions this call was given, which must all outlive it, as the
/// module rule at the top of this file states.
///
/// Exhaustion of either is `error.BufferTooSmall` and never a truncation: a
/// result with more content than the caller reserved is reported rather than
/// cut. On any error nothing is returned and both arrays may hold what the
/// failed attempt wrote; neither is readable as part of a result, because
/// [`ToolCallResult.verbatim`] was never formed. A caller that fixes the fault
/// calls again with the same storage and lets the second pass overwrite them.
pub fn decodeToolCallResult(
    raw: []const u8,
    out_content: []ContentBlock,
    verbatim: []VerbatimMember,
    scratch: []u8,
) DecodeError!ToolCallResult {
    var reader = json.Reader.init(raw);
    var store = VerbatimStore.init(verbatim);
    const at = store.mark();
    var envelope: ResultEnvelope = .{};

    var content: ?[]const u8 = null;
    var structured_content: ?[]const u8 = null;
    var is_error: ?bool = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (try envelope.read(key, &reader, scratch)) continue;
        if (std.mem.eql(u8, key, "content")) {
            const value = try reader.rawValue(scratch);
            if (content == null) content = value;
        } else if (std.mem.eql(u8, key, "structuredContent")) {
            const value = try reader.rawValue(scratch);
            if (structured_content == null) structured_content = value;
        } else if (std.mem.eql(u8, key, "isError")) {
            const value = try reader.boolean();
            if (is_error == null) is_error = value;
        } else {
            try takeVerbatim(key, &reader, &store, scratch);
        }
    }

    const open_members = try closeResult(&reader, &store, at);
    const blocks = content orelse return error.MissingField;
    return .{
        .result_type = envelope.result_type,
        .meta = envelope.meta,
        .content = try decodeArray(
            ContentBlock,
            blocks,
            out_content,
            decodeContentBlock,
            &store,
            &reader,
            scratch,
        ),
        .structured_content = structured_content,
        .is_error = is_error,
        .verbatim = open_members,
    };
}

/// Encode a `CallToolResult` — the inverse of [`decodeToolCallResult`] for the
/// values it produces, which is what a member the shape does not model
/// buys: it comes back in [`ToolCallResult.verbatim`] rather than being
/// skipped, and [`VerbatimMember`] states what that preserves and what it does
/// not. Member order is the encoder's, so the encoding is stable rather than a
/// copy of the peer's byte order.
///
/// `error.InvalidField` names a lexeme that is not one whole JSON value,
/// wherever in the document it sat, and lands before the first byte; after that
/// the only failure left is `error.BufferTooSmall` from the writer, which
/// leaves what it had already written in the caller's buffer.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodeToolCallResult`] produces and not for any
/// value handed to it. A caller building a result from strings it wrote itself
/// must have them valid.
pub fn encodeToolCallResult(result: ToolCallResult, writer: *json.Writer) EncodeError!void {
    for (result.content) |block| try checkContentBlock(block, 3);
    try checkRaw(&.{ result.structured_content, result.meta }, 1);
    try checkVerbatim(result.verbatim, 1);
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeResultType(&object, result.result_type);
    try object.key("content");
    try writer.byte('[');
    for (result.content, 0..) |block, at| {
        if (at != 0) try writer.byte(',');
        try encodeContentBlock(block, writer);
    }
    try writer.byte(']');
    try object.optRaw("structuredContent", result.structured_content);
    if (result.is_error) |flag| try object.boolean("isError", flag);
    try object.optRaw("_meta", result.meta);
    try object.verbatim(result.verbatim);
    try object.close();
}

/// A `ListToolsResult`, the answer to `tools/list`.
///
/// `cacheable` is required and has no default, so a server that means to answer
/// `tools/list` cannot build one without a freshness hint and a scope;
/// `page` is optional, because a last page is a document without `nextCursor`.
/// `tools` is a slice of the caller's array, `meta` a JSON lexeme and
/// `verbatim` a carried member — each as the module rule at the top of this
/// file states.
pub const ToolListResult = struct {
    result_type: ResultType = ResultType{},
    cacheable: Cacheable,
    page: PaginatedResult = PaginatedResult{},
    /// The `_meta` object, carried whole as the lexeme it arrived as.
    ///
    /// Optional and not defaulted: a peer that sent no `_meta` and one that sent
    /// `{}` are the two documents they are.
    meta: ?[]const u8 = null,
    /// The tools, in `out_tools` — a slice of the caller's array, not a copy.
    ///
    /// Required and present-and-empty is well formed, so an empty slice here
    /// means a server that listed no tools and never an absent `tools`; only
    /// `error.MissingField` tells those apart.
    tools: []const Tool = &.{},
    /// Unmodeled members of this result object. Tools retain their own members
    /// in `Tool.verbatim`, not in this slice.
    ///
    /// Aliases the caller's store array rather than copying it, so it is valid
    /// until that array is written again or released.
    verbatim: []const VerbatimMember = &.{},
};

/// Decode a `ListToolsResult`.
///
/// `out_tools` is the caller's array of tools and `verbatim` its store for the
/// members no shape names, across the whole document including the tools, so
/// size both for the document rather than for the envelope. Every slice the
/// result holds borrows the document, the escape scratch or the store array —
/// the three regions this call was given, which must all outlive it, as the
/// module rule at the top of this file states.
///
/// All three required members are required: an absent `tools`, `ttlMs` or
/// `cacheScope` is `error.MissingField`. Exhaustion of either array is
/// `error.BufferTooSmall` and never a truncation, and on any error nothing is
/// returned and both arrays may hold what the failed attempt wrote — readable
/// as nothing, because [`ToolListResult.verbatim`] was never formed. A caller
/// that fixes the fault calls again with the same storage.
pub fn decodeToolListResult(
    raw: []const u8,
    out_tools: []Tool,
    verbatim: []VerbatimMember,
    scratch: []u8,
) DecodeError!ToolListResult {
    var reader = json.Reader.init(raw);
    var store = VerbatimStore.init(verbatim);
    const at = store.mark();
    var envelope: ResultEnvelope = .{};
    var cache: CacheableReader = .{};

    var tools: ?[]const u8 = null;
    var next_cursor: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (try envelope.read(key, &reader, scratch)) continue;
        if (try cache.read(key, &reader, scratch)) continue;
        if (std.mem.eql(u8, key, "tools")) {
            const value = try reader.rawValue(scratch);
            if (tools == null) tools = value;
        } else if (std.mem.eql(u8, key, "nextCursor")) {
            const value = try reader.string(scratch);
            if (next_cursor == null) next_cursor = value;
        } else {
            try takeVerbatim(key, &reader, &store, scratch);
        }
    }

    const open_members = try closeResult(&reader, &store, at);
    const list = tools orelse return error.MissingField;
    return .{
        .result_type = envelope.result_type,
        .cacheable = try cache.build(),
        .page = .{ .next_cursor = next_cursor },
        .meta = envelope.meta,
        .tools = try decodeArray(Tool, list, out_tools, decodeTool, &store, &reader, scratch),
        .verbatim = open_members,
    };
}

/// Encode a `ListToolsResult` — the inverse of [`decodeToolListResult`] for the
/// values it produces, which is what a member the shape does not model
/// buys: it comes back in [`ToolListResult.verbatim`] rather than being
/// skipped, and [`VerbatimMember`] states what that preserves and what it does
/// not. Member order is the encoder's, so the encoding is stable rather than a
/// copy of the peer's byte order.
///
/// `error.InvalidField` names a lexeme that is not one whole JSON value,
/// wherever in the document it sat, and lands before the first byte; after that
/// the only failure left is `error.BufferTooSmall` from the writer, which
/// leaves what it had already written in the caller's buffer.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodeToolListResult`] produces and not for any
/// value handed to it. A caller building a result from strings it wrote itself
/// must have them valid.
pub fn encodeToolListResult(result: ToolListResult, writer: *json.Writer) EncodeError!void {
    for (result.tools) |tool| try checkTool(tool, 3);
    try checkRaw(&.{result.meta}, 1);
    try checkVerbatim(result.verbatim, 1);
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeResultType(&object, result.result_type);
    try writeCacheable(&object, result.cacheable);
    try writeNextCursor(&object, result.page);
    try object.key("tools");
    try writer.byte('[');
    for (result.tools, 0..) |tool, at| {
        if (at != 0) try writer.byte(',');
        try encodeTool(tool, writer);
    }
    try writer.byte(']');
    try object.optRaw("_meta", result.meta);
    try object.verbatim(result.verbatim);
    try object.close();
}

/// A `ReadResourceResult`, the answer to `resources/read`.
///
/// Cacheable and **not** paginated: `contents` is a sequence but not a page,
/// and it may hold more than one entry. A server MUST NOT answer with an empty
/// array for a resource that does not exist, and this decoder does not read
/// that as a rule it may enforce — an empty array is a legal document, and the
/// resource's existence is the caller's question to ask.
///
/// `contents` is a slice of the caller's array, `meta` a JSON lexeme and
/// `verbatim` a carried member — each as the module rule at the top of this
/// file states, and each borrowed from the document, the escape scratch or the
/// store array the [`decodeResourceReadResult`] call was given rather than
/// copied.
pub const ResourceReadResult = struct {
    result_type: ResultType = ResultType{},
    cacheable: Cacheable,
    /// The `_meta` object, carried whole as the lexeme it arrived as.
    ///
    /// Optional and not defaulted: a peer that sent no `_meta` and one that sent
    /// `{}` are the two documents they are.
    meta: ?[]const u8 = null,
    /// The contents, in `out_contents` — a slice of the caller's array, not a
    /// copy.
    ///
    /// Required, and it may hold more than one entry: this is the row the field
    /// name alone cannot classify, because a sequence is not a page.
    contents: []const ResourceContents = &.{},
    /// Unmodeled members of this result object. Nested resource contents retain
    /// their own members in their own `verbatim` slices.
    ///
    /// Aliases the caller's store array rather than copying it, so it is valid
    /// until that array is written again or released.
    verbatim: []const VerbatimMember = &.{},
};

/// Decode a `ReadResourceResult`.
///
/// `out_contents` is the caller's array of contents and `verbatim` its store
/// for the members no shape names, across the whole document including the
/// contents, so size both for the document rather than for the envelope. Every
/// slice the result holds borrows the document, the escape scratch or the store
/// array — the three regions this call was given, which must all outlive it, as
/// the module rule at the top of this file states.
///
/// All three required members are required: an absent `contents`, `ttlMs` or
/// `cacheScope` is `error.MissingField`. Exhaustion of either array is
/// `error.BufferTooSmall` and never a truncation, and on any error nothing is
/// returned and both arrays may hold what the failed attempt wrote — readable
/// as nothing, because [`ResourceReadResult.verbatim`] was never formed. A
/// caller that fixes the fault calls again with the same storage.
pub fn decodeResourceReadResult(
    raw: []const u8,
    out_contents: []ResourceContents,
    verbatim: []VerbatimMember,
    scratch: []u8,
) DecodeError!ResourceReadResult {
    var reader = json.Reader.init(raw);
    var store = VerbatimStore.init(verbatim);
    const at = store.mark();
    var envelope: ResultEnvelope = .{};
    var cache: CacheableReader = .{};

    var contents: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (try envelope.read(key, &reader, scratch)) continue;
        if (try cache.read(key, &reader, scratch)) continue;
        if (std.mem.eql(u8, key, "contents")) {
            const value = try reader.rawValue(scratch);
            if (contents == null) contents = value;
        } else {
            try takeVerbatim(key, &reader, &store, scratch);
        }
    }

    const open_members = try closeResult(&reader, &store, at);
    const list = contents orelse return error.MissingField;
    return .{
        .result_type = envelope.result_type,
        .cacheable = try cache.build(),
        .meta = envelope.meta,
        .contents = try decodeArray(
            ResourceContents,
            list,
            out_contents,
            decodeResourceContents,
            &store,
            &reader,
            scratch,
        ),
        .verbatim = open_members,
    };
}

/// Encode a `ReadResourceResult` — the inverse of [`decodeResourceReadResult`]
/// for the values it produces, which is what a member the shape does not
/// model buys: it comes back in [`ResourceReadResult.verbatim`] rather than
/// being skipped, and [`VerbatimMember`] states what that preserves and what it
/// does not. Member order is the encoder's, so the encoding is stable rather
/// than a copy of the peer's byte order.
///
/// `error.InvalidField` names a lexeme that is not one whole JSON value,
/// wherever in the document it sat, and lands before the first byte; after that
/// the only failure left is `error.BufferTooSmall` from the writer, which
/// leaves what it had already written in the caller's buffer.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodeResourceReadResult`] produces and not for any
/// value handed to it. A caller building a result from strings it wrote itself
/// must have them valid.
pub fn encodeResourceReadResult(
    result: ResourceReadResult,
    writer: *json.Writer,
) EncodeError!void {
    for (result.contents) |entry| try checkResourceContents(entry, 3);
    try checkRaw(&.{result.meta}, 1);
    try checkVerbatim(result.verbatim, 1);
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeResultType(&object, result.result_type);
    try writeCacheable(&object, result.cacheable);
    try object.key("contents");
    try writer.byte('[');
    for (result.contents, 0..) |entry, at| {
        if (at != 0) try writer.byte(',');
        try encodeResourceContents(entry, writer);
    }
    try writer.byte(']');
    try object.optRaw("_meta", result.meta);
    try object.verbatim(result.verbatim);
    try object.close();
}

/// A `GetPromptResult`, the answer to `prompts/get`.
///
/// `messages` is a slice of the caller's array, `description` a decoded string,
/// `meta` a JSON lexeme and `verbatim` a carried member — each as the module
/// rule at the top of this file states, and each borrowed from the document, the
/// escape scratch or the store array the [`decodePromptsGetResult`] call was
/// given rather than copied.
pub const PromptsGetResult = struct {
    result_type: ResultType = ResultType{},
    /// The `_meta` object, carried whole as the lexeme it arrived as.
    ///
    /// Optional and not defaulted: a peer that sent no `_meta` and one that sent
    /// `{}` are the two documents they are.
    meta: ?[]const u8 = null,
    /// The messages, in `out_messages` — a slice of the caller's array, not a
    /// copy.
    ///
    /// Required, and present-and-empty is well formed: an empty slice here is a
    /// prompt with no messages and never an absent `messages`.
    messages: []const PromptMessage = &.{},
    /// The prompt's prose, as a decoded string.
    ///
    /// Optional because the section does not require it, and not defaulted to an
    /// empty string: a prompt the server left undescribed and one it described
    /// as `""` are different documents.
    description: ?[]const u8 = null,
    /// Unmodeled members of this result object. Messages retain their own
    /// members in `PromptMessage.verbatim`, not in this slice.
    ///
    /// Aliases the caller's store array rather than copying it, so it is valid
    /// until that array is written again or released.
    verbatim: []const VerbatimMember = &.{},
};

/// Decode a `GetPromptResult`.
///
/// `out_messages` is the caller's array of messages and `verbatim` its store
/// for the members no shape names, across the whole document including the
/// messages and the block each one carries, so size both for the document
/// rather than for the envelope. Every slice the result holds borrows the
/// document, the escape scratch or the store array — the three regions this
/// call was given, which must all outlive it, as the module rule at the top of
/// this file states.
///
/// Exhaustion of either array is `error.BufferTooSmall` and never a truncation,
/// and on any error nothing is returned and both arrays may hold what the
/// failed attempt wrote — readable as nothing, because
/// [`PromptsGetResult.verbatim`] was never formed. A caller that fixes the
/// fault calls again with the same storage.
pub fn decodePromptsGetResult(
    raw: []const u8,
    out_messages: []PromptMessage,
    verbatim: []VerbatimMember,
    scratch: []u8,
) DecodeError!PromptsGetResult {
    var reader = json.Reader.init(raw);
    var store = VerbatimStore.init(verbatim);
    const at = store.mark();
    var envelope: ResultEnvelope = .{};

    var messages: ?[]const u8 = null;
    var description: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (try envelope.read(key, &reader, scratch)) continue;
        if (std.mem.eql(u8, key, "messages")) {
            const value = try reader.rawValue(scratch);
            if (messages == null) messages = value;
        } else if (std.mem.eql(u8, key, "description")) {
            const value = try reader.string(scratch);
            if (description == null) description = value;
        } else {
            try takeVerbatim(key, &reader, &store, scratch);
        }
    }

    const open_members = try closeResult(&reader, &store, at);
    const list = messages orelse return error.MissingField;
    return .{
        .result_type = envelope.result_type,
        .meta = envelope.meta,
        .messages = try decodeArray(
            PromptMessage,
            list,
            out_messages,
            decodePromptMessage,
            &store,
            &reader,
            scratch,
        ),
        .description = description,
        .verbatim = open_members,
    };
}

/// Encode a `GetPromptResult` — the inverse of [`decodePromptsGetResult`] for
/// the values it produces, which is what a member the shape does not model
/// buys: it comes back in [`PromptsGetResult.verbatim`] rather than being
/// skipped, and [`VerbatimMember`] states what that preserves and what it does
/// not. Member order is the encoder's, so the encoding is stable rather than a
/// copy of the peer's byte order.
///
/// `error.InvalidField` names a lexeme that is not one whole JSON value,
/// wherever in the document it sat, and lands before the first byte; after that
/// the only failure left is `error.BufferTooSmall` from the writer, which
/// leaves what it had already written in the caller's buffer.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodePromptsGetResult`] produces and not for any
/// value handed to it. A caller building a result from strings it wrote itself
/// must have them valid.
pub fn encodePromptsGetResult(result: PromptsGetResult, writer: *json.Writer) EncodeError!void {
    for (result.messages) |message| try checkPromptMessage(message, 3);
    try checkRaw(&.{result.meta}, 1);
    try checkVerbatim(result.verbatim, 1);
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeResultType(&object, result.result_type);
    try object.key("messages");
    try writer.byte('[');
    for (result.messages, 0..) |message, at| {
        if (at != 0) try writer.byte(',');
        try encodePromptMessage(message, writer);
    }
    try writer.byte(']');
    try object.optText("description", result.description);
    try object.optRaw("_meta", result.meta);
    try object.verbatim(result.verbatim);
    try object.close();
}

/// A `DiscoverResult`, the answer to `server/discover`.
///
/// The one mandatory method, and the only result a client cannot route by
/// guessing: it is what tells the client which versions it may speak.
///
/// `supported_versions` is a slice of the caller's array of decoded strings,
/// `capabilities` and `meta` are JSON lexemes, `instructions` a decoded string
/// and `verbatim` a carried member — each as the module rule at the top of this
/// file states, and each borrowed from the document, the escape scratch or the
/// store array the [`decodeDiscoverResult`] call was given rather than copied.
pub const DiscoverResult = struct {
    result_type: ResultType = ResultType{},
    cacheable: Cacheable,
    /// The `_meta` object, carried whole as the lexeme it arrived as.
    ///
    /// Optional and not defaulted: a peer that sent no `_meta` and one that sent
    /// `{}` are the two documents they are.
    meta: ?[]const u8 = null,
    /// The versions the server speaks; the client picks one.
    ///
    /// In `out_versions`, one slice per element: every element stays live at
    /// once, so the strings borrow separate regions of the escape scratch or of
    /// the document rather than one another.
    supported_versions: []const []const u8 = &.{},
    /// The `ServerCapabilities` object, carried whole.
    ///
    /// Section 4.10.3 requires it, and section 4.10.4 calls it the 4.8 shape;
    /// the schema's own doc comment on both capability objects says "this is
    /// not a closed set: any client/server can define its own, additional
    /// capabilities". A typed shape would then have to hold keys it does not
    /// name, which is the defect `bridge.Envelope.meta` exists to avoid, so
    /// the object is carried as the lexeme it arrived as. A member with no
    /// object in it is `"null"`, and that is distinct from an absent member
    /// — a session with no capabilities writes the literal `null`, and a
    /// reader that collapsed the two would report a refusal as an omission.
    capabilities: []const u8,
    /// Prose for the model, as a decoded string.
    ///
    /// Optional because the section does not require it, and not defaulted to an
    /// empty string: a server that said nothing and one that said `""` are
    /// different documents.
    instructions: ?[]const u8 = null,
    /// The members this shape does not model.
    ///
    /// Aliases the caller's store array rather than copying it, so it is valid
    /// until that array is written again or released.
    verbatim: []const VerbatimMember = &.{},
};

/// Decode a `DiscoverResult`.
///
/// `out_versions` is the caller's array of version strings and `verbatim` its
/// store for the members no shape names, so size the store for the whole
/// document. Every slice the result holds borrows the document, the escape
/// scratch or the store array — the three regions this call was given, which
/// must all outlive it, as the module rule at the top of this file states.
///
/// All three required members are required: an absent `supportedVersions`,
/// `capabilities`, `ttlMs` or `cacheScope` is `error.MissingField`.
/// Exhaustion of either array is `error.BufferTooSmall` and never a truncation,
/// and on any error nothing is returned and both arrays may hold what the
/// failed attempt wrote — readable as nothing, because
/// [`DiscoverResult.verbatim`] was never formed. A caller that fixes the fault
/// calls again with the same storage.
pub fn decodeDiscoverResult(
    raw: []const u8,
    out_versions: [][]const u8,
    verbatim: []VerbatimMember,
    scratch: []u8,
) DecodeError!DiscoverResult {
    var reader = json.Reader.init(raw);
    var store = VerbatimStore.init(verbatim);
    const at = store.mark();
    var envelope: ResultEnvelope = .{};
    var cache: CacheableReader = .{};

    var supported_versions: ?[]const u8 = null;
    var capabilities: ?[]const u8 = null;
    var instructions: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (try envelope.read(key, &reader, scratch)) continue;
        if (try cache.read(key, &reader, scratch)) continue;
        if (std.mem.eql(u8, key, "supportedVersions")) {
            const value = try reader.rawValue(scratch);
            if (supported_versions == null) supported_versions = value;
        } else if (std.mem.eql(u8, key, "capabilities")) {
            const value = try reader.rawValue(scratch);
            if (capabilities == null) capabilities = value;
        } else if (std.mem.eql(u8, key, "instructions")) {
            const value = try reader.string(scratch);
            if (instructions == null) instructions = value;
        } else {
            try takeVerbatim(key, &reader, &store, scratch);
        }
    }

    const open_members = try closeResult(&reader, &store, at);
    const versions = supported_versions orelse return error.MissingField;
    return .{
        .result_type = envelope.result_type,
        .cacheable = try cache.build(),
        .meta = envelope.meta,
        .supported_versions = try decodeStrings(versions, out_versions, &reader, scratch),
        .capabilities = capabilities orelse return error.MissingField,
        .instructions = instructions,
        .verbatim = open_members,
    };
}

/// Encode a `DiscoverResult` — the inverse of [`decodeDiscoverResult`] for the
/// values it produces, which is what a member the shape does not model
/// buys: it comes back in [`DiscoverResult.verbatim`] rather than being
/// skipped, and [`VerbatimMember`] states what that preserves and what it does
/// not. Member order is the encoder's, so the encoding is stable rather than a
/// copy of the peer's byte order.
///
/// The order chosen is the one `mcp_session.Server.discoverBody` already
/// writes, so a body a session built re-encodes to the very bytes it was built
/// from rather than to the same document in another member order. That is the
/// stable-encoding half of the contract and it is why this is the member order
/// this module fixes; it is not a promise that a peer's own order survives.
///
/// `nextCursor` is not a member of this result, and `DiscoverResult` is not one
/// of the four paginated rows: the artifact has it extend `CacheableResult` and
/// not `PaginatedResult`, so it is the sixth cacheable row and none of the four
/// that page.
///
/// `error.InvalidField` names a lexeme that is not one whole JSON value,
/// wherever in the document it sat, and lands before the first byte; after that
/// the only failure left is `error.BufferTooSmall` from the writer, which
/// leaves what it had already written in the caller's buffer.
///
/// The one obligation this leaves open is the module rule at the top of this
/// file states: [`json.Writer.string`] does not check UTF-8, so this is an
/// inverse for the values [`decodeDiscoverResult`] produces and not for any
/// value handed to it. A caller building a result from strings it wrote itself
/// must have them valid.
pub fn encodeDiscoverResult(result: DiscoverResult, writer: *json.Writer) EncodeError!void {
    try checkRaw(&.{ result.capabilities, result.meta }, 1);
    try checkVerbatim(result.verbatim, 1);
    var object: ObjectWriter = .{ .writer = writer };
    try object.open();
    try writeResultType(&object, result.result_type);
    try writeCacheable(&object, result.cacheable);
    try object.key("supportedVersions");
    try writeStringArray(result.supported_versions, writer);
    try object.raw("capabilities", result.capabilities);
    try object.optText("instructions", result.instructions);
    try object.optRaw("_meta", result.meta);
    try object.verbatim(result.verbatim);
    try object.close();
}

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
        try testing.expect(isRemovedMethod(.current, removed.name));
        // The same name is a live method at the previous revision. A gate that
        // did not name a revision would refuse a request that revision defines.
        try testing.expect(!isRemovedMethod(.previous, removed.name));
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

test "an InputRequest method resolves as a carried value at every revision" {
    for (input_requests) |info| {
        // The three retain their types, so they resolve as carried values at
        // every revision the library decodes.
        const carried = try lookupInputRequest(info.name);
        try testing.expectEqualStrings(info.name, carried.name);
        try testing.expectEqual(info.direction, carried.direction);

        // What `2026-07-28` removed is their use as top-level names.
        try testing.expectError(error.UnknownMethod, lookupMethod(.current, info.name));
        try testing.expect(isRemovedMethod(.current, info.name));
    }
    // The InputRequest table is not a second top-level registry.
    try testing.expectError(error.UnknownMethod, lookupInputRequest("initialize"));
    try testing.expectError(error.UnknownMethod, lookupInputRequest("tools/call"));
}

test "the three former top-level requests resolve at the previous revision only" {
    // PROTOCOLS.md 4.4 removes them in `2026-07-28`, "and therefore decoded as
    // `UnknownMethod` at that revision". A removal is a fact about one
    // revision rather than about every one, and section 8 says this library
    // accepts `2025-11-25`, so a peer on it sends `roots/list` as a request
    // and this library has to have an answer for it.
    for (previous_top_level_requests) |info| {
        const found = try lookupMethod(.previous, info.name);
        try testing.expectEqualStrings(info.name, found.name);
        // The top-level direction, which is the whole reason this is a table
        // rather than a reuse of the `input_requests` row.
        try testing.expectEqual(Direction.client_to_server, found.direction);
        try testing.expect(!found.present_at_current);
        try testing.expect(found.deprecated);

        // And the revision that removed them still refuses each one.
        try testing.expectError(error.UnknownMethod, lookupMethod(.current, info.name));
        try testing.expect(isRemovedMethod(.current, info.name));
        try testing.expect(!isRemovedMethod(.previous, info.name));
    }
    // The three the document names, and no fourth.
    try testing.expectEqual(@as(usize, 3), previous_top_level_requests.len);
}

test "the previous-revision resolution of these three is not the row they carry" {
    // One name resolves to two different things, and a caller that reaches for
    // the wrong one gets either a request it must not send or a request it is
    // forbidden to answer. A session gate refuses any direction that is not
    // `client_to_server`, so the carried row would resolve the name and then
    // be refused as `NotARequest`, and a `2025-11-25` server would not answer
    // `roots/list`.
    for (input_requests) |carried| {
        const top_level = try lookupMethod(.previous, carried.name);
        try testing.expectEqualStrings(carried.name, top_level.name);
        try testing.expectEqual(Direction.client_to_server, top_level.direction);
        try testing.expectEqual(Direction.server_to_client_mrtr_only, carried.direction);
        try testing.expect(carried.present_at_current);
        try testing.expect(!top_level.present_at_current);
    }
    // And the two tables have to keep naming the same three, in both
    // directions. A name that entered one and not the other would resolve at
    // a revision where the document does not define it, or stop resolving
    // where it does, and a count over either table alone cannot tell those
    // apart.
    const three = [_][]const u8{
        "roots/list",
        "elicitation/create",
        "sampling/createMessage",
    };
    try testing.expect(namesAre(&previous_top_level_requests, &three));
    try testing.expect(namesAre(&input_requests, &three));
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

test "a retry leg's result is never cacheable, whatever the method says" {
    var scratch: [256]u8 = undefined;

    // `resources/read` is the one client request that is both cacheable and
    // may return an interim result, so it is the row where reading one flag
    // instead of the composition caches the `complete` leg of a retry and
    // serves it stale. The method flag is deliberately unchanged: the method
    // genuinely is cacheable on the leg that was not a retry.
    const read = try lookupMethod(.current, "resources/read");
    try testing.expect(read.cacheable);
    try testing.expect(read.mrtr);
    try testing.expect(read.mayCache(.original));
    try testing.expect(!read.mayCache(.mrtr_retry));

    // The other five cacheable requests have no interim leg at all, so nothing
    // changes for them and the flag stays the whole answer on the leg that can
    // arrive.
    const cacheable = [_][]const u8{
        "server/discover",
        "tools/list",
        "prompts/list",
        "resources/list",
        "resources/templates/list",
    };
    for (cacheable) |name| {
        const info = try lookupMethod(.current, name);
        try testing.expect(info.mayCache(.original));
        try testing.expect(!info.mayCache(.mrtr_retry));
    }

    // A method that is not cacheable is not cacheable on either leg, so this
    // is a composition of two facts and not a third flag.
    const call = try lookupMethod(.current, "tools/call");
    try testing.expect(!call.cacheable);
    try testing.expect(!call.mayCache(.original));
    try testing.expect(!call.mayCache(.mrtr_retry));

    // Which leg a request is on is read from the two members the normative
    // sentence names, and presence alone counts: an `inputResponses` map a
    // client has not filled yet still makes the request a retry.
    const first_call =
        \\{"name":"echo","arguments":{"message":"hello"}}
    ;
    try testing.expectEqual(CacheLeg.original, try decodeCacheLeg(first_call, &scratch));
    // Nothing but those two members puts a request on the retry leg, and an
    // empty params object is not a retry.
    try testing.expectEqual(CacheLeg.original, try decodeCacheLeg("{}", &scratch));
    const both =
        \\{"name":"echo","inputResponses":{},"requestState":"st"}
    ;
    try testing.expectEqual(CacheLeg.mrtr_retry, try decodeCacheLeg(both, &scratch));
    const responses =
        \\{"name":"echo","inputResponses":{}}
    ;
    try testing.expectEqual(CacheLeg.mrtr_retry, try decodeCacheLeg(responses, &scratch));
    const state =
        \\{"name":"echo","requestState":"st"}
    ;
    try testing.expectEqual(CacheLeg.mrtr_retry, try decodeCacheLeg(state, &scratch));
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
    )) orelse return error.TestUnexpectedResult;
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
    )) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Mcp-Param-count", count.header_name);
    try testing.expectEqualStrings("7", count.header_value);

    const flag = (try bindParamHeader(
        "flag",
        .boolean,
        .{ .boolean = true },
        &names,
        &values,
        &digits,
    )) orelse return error.TestUnexpectedResult;
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
    )) orelse return error.TestUnexpectedResult;

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
    )) orelse return error.TestUnexpectedResult;
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

test "only the two rows the authority rejects are a refusal" {
    var converted: [64]u8 = undefined;
    var scratch: [128]u8 = undefined;

    // PROTOCOLS.md 4.2 rejects "on mismatch", and the normative table's last
    // row adds the missing header for a value the body carries. Those two.
    try testing.expect(ParamVerdict.accepted.isAcceptable());
    try testing.expect(!ParamVerdict.mismatch.isAcceptable());
    try testing.expect(!ParamVerdict.missing_header.isAcceptable());

    // The two rows that read "MUST NOT expect the header" — a value that is
    // `null`, and a parameter not in `arguments` — state what the server must
    // not *expect*, and the table names no outcome for either. The server does
    // not act on the header, which is what the row requires; the codec does
    // not turn a sentence about expectations into a rejection it cannot cite.
    // The verdict is still reported, so a server that does want to refuse one
    // has the fact by name.
    try testing.expect(ParamVerdict.unexpected_header.isAcceptable());

    // Reached the way a caller reaches it. `checkParamBinding` takes one null
    // for "the body omits the key" and "the body carries JSON null" alike, so
    // this is both of those two rows at once: reported as the extra-header
    // row, and not gating the request.
    const verdict = try checkParamBinding("7", null, &converted, &scratch);
    try testing.expectEqual(ParamVerdict.unexpected_header, verdict);
    try testing.expect(verdict.isAcceptable());
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

test "classify treats an absent resultType as complete, as the spec requires" {
    var scratch: [128]u8 = undefined;
    const complete = try classifyResult("{\"content\":[]}", &scratch);
    try testing.expect(complete.isComplete());

    const interim = try classifyResult("{\"resultType\":\"input_required\"}", &scratch);
    try testing.expect(!interim.isComplete());
    try testing.expectEqual(KnownResultType.input_required, interim.known().?);

    // A value the specification does not define is not guessed at, and not
    // quietly treated as the safe-to-assume case.
    const unknown = try classifyResult("{\"resultType\":\"weird\"}", &scratch);
    try testing.expect(!unknown.isComplete());
    try testing.expect(unknown.known() == null);
}

test "a body that is not a result is reported, not classified" {
    var scratch: [128]u8 = undefined;
    try testing.expectError(error.NotAResult, classifyResult("[1,2]", &scratch));
    try testing.expectError(error.NotAResult, classifyResult("\"a string\"", &scratch));
}

test "the three result rules answer for a body with no session in hand" {
    // This module has no `Client` and no `Server` to build, so the three cannot
    // take one: a fact read out of a document does not depend on the session
    // that put the document on the wire, and a consumer holding the bytes and
    // no session has to be able to ask anyway.
    var scratch: [256]u8 = undefined;
    var out: [512]u8 = undefined;

    // The reading side. PROTOCOLS.md 4.6 makes a peer on an earlier revision
    // omit `resultType`, and an absent one is `complete` rather than a fault.
    const absent = try classifyResult("{\"content\":[]}", &scratch);
    try testing.expect(absent.isComplete());

    // The sending side, which is the mirror and not the same rule: `resultType`
    // is required on a body this library built, and the two caching fields on
    // one 4.6 marks cacheable.
    const listing = try lookupMethod(.current, "tools/list");
    try testing.expect(listing.cacheable);
    try checkResult(
        listing,
        "{\"resultType\":\"complete\",\"ttlMs\":1,\"cacheScope\":\"public\",\"tools\":[]}",
        &scratch,
    );
    try testing.expectError(error.NotAResult, checkResult(listing, "{\"tools\":[]}", &scratch));

    // The one body PROTOCOLS.md 4.7 defines, on a method that may answer with
    // it and not on one that may not, read back by the rule above: the writing
    // side and the reading side of a result are one exchange rather than two
    // readers that agree today.
    try testing.expectError(
        error.InputRequiredUnexpected,
        inputRequired("tools/list", "{}", "st", &out),
    );
    const interim = try classifyResult(
        try inputRequired("tools/call", "{}", "st", &out),
        &scratch,
    );
    try testing.expect(!interim.isComplete());
    try testing.expectEqual(KnownResultType.input_required, interim.known().?);
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
    var verbatim: [16]VerbatimMember = undefined;

    const both = try decodeInputRequiredResult(
        \\{"resultType":"input_required","inputRequests":{"a":{"method":"elicitation/create"}},"requestState":"opaque"}
    , verbatim[0..], &scratch);
    try testing.expect(both.input_requests != null);
    try testing.expectEqualStrings("opaque", both.request_state.?);

    const state_only = try decodeInputRequiredResult(
        \\{"resultType":"input_required","requestState":"opaque"}
    , verbatim[0..], &scratch);
    try testing.expectEqual(@as(?[]const u8, null), state_only.input_requests);

    try testing.expectError(error.MissingField, decodeInputRequiredResult(
        \\{"resultType":"input_required"}
    , verbatim[0..], &scratch));

    // A complete result is not an InputRequiredResult.
    try testing.expectError(error.InvalidField, decodeInputRequiredResult(
        \\{"resultType":"complete","requestState":"x"}
    , verbatim[0..], &scratch));
}

test "an unmodelled member of an interim result is written back whole" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // The result object is open in its keys: `Result` declares
    // `[key: string]: unknown`, so a member this shape does not model is one a
    // peer may legally send. It used to be skipped here and the encoder wrote
    // only the three members the type models, so a client that answered the
    // interim result with the body it re-encoded dropped what the server had
    // sent — on the one result a client always re-encodes, and with no error
    // anywhere.
    const wire =
        \\{"resultType":"input_required","requestState":"x","vendor.example.com/trace":{"a":[1,2]}}
    ;
    const decoded = try decodeInputRequiredResult(wire, verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 1), decoded.verbatim.len);
    try testing.expectEqualStrings("vendor.example.com/trace", decoded.verbatim[0].key);
    try testing.expectEqualStrings("{\"a\":[1,2]}", decoded.verbatim[0].value);
    var writer = json.Writer.init(&out);
    try encodeInputRequiredResult(decoded, &writer);
    try testing.expectEqualStrings(wire, writer.written());

    // The carrier `_meta` is declared on `Result` itself, so it is the member a
    // peer is likeliest to send, and no fixture in the tree carries one: the
    // same rule, one member nearer the specification's own, and it comes back
    // beside the others rather than in place of them.
    const carrier =
        "{\"resultType\":\"input_required\"," ++
        "\"inputRequests\":{\"e1\":{\"method\":\"elicitation/create\"}}," ++
        "\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"s\"}}}";
    const carried = try decodeInputRequiredResult(carrier, verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 1), carried.verbatim.len);
    try testing.expectEqualStrings("_meta", carried.verbatim[0].key);
    writer = json.Writer.init(&out);
    try encodeInputRequiredResult(carried, &writer);
    try testing.expectEqualStrings(carrier, writer.written());

    // A document carrying only the three members the type models is the
    // ordinary path, and the store leaves it alone: no carried member, and the
    // same bytes it has always re-encoded to.
    const plain = "{\"resultType\":\"input_required\",\"requestState\":\"x\"}";
    const bare = try decodeInputRequiredResult(plain, verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 0), bare.verbatim.len);
    writer = json.Writer.init(&out);
    try encodeInputRequiredResult(bare, &writer);
    try testing.expectEqualStrings(plain, writer.written());

    // A member this shape does not name is never interpreted, so there is no
    // value for the first-wins rule to resolve and every occurrence is carried.
    const twice = try decodeInputRequiredResult(
        \\{"requestState":"x","hint":1,"hint":2}
    , verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 2), twice.verbatim.len);
    writer = json.Writer.init(&out);
    try encodeInputRequiredResult(twice, &writer);
    try testing.expectEqualStrings(
        \\{"requestState":"x","hint":1,"hint":2}
    , writer.written());

    // A store with no room left is a refusal and never a truncation, which is
    // what a caller who sizes it wrong is told: this pair would otherwise hand
    // back a result whose open members quietly stopped being written back, and
    // that is the defect the store was added to close.
    var one_member: [1]VerbatimMember = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        decodeInputRequiredResult(
            \\{"requestState":"x","first":1,"second":2}
        , one_member[0..], &scratch),
    );
}

test "requestState is carried and never interpreted" {
    var scratch: [128]u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;
    // A value that would be dangerous if parsed as anything else. The library
    // hands back the same characters without ever reading them as a structure.
    const hostile = "{\"admin\":true,\"role\":\"owner\"}";
    const decoded = try decodeInputRequiredResult(
        \\{"resultType":"input_required","requestState":"{\"admin\":true,\"role\":\"owner\"}"}
    , verbatim[0..], &scratch);
    try testing.expectEqualStrings(hostile, decoded.request_state.?);
}

test "an InputRequiredResult records an absent resultType instead of inventing one" {
    var scratch: [128]u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    const present = try decodeInputRequiredResult(
        \\{"resultType":"input_required","requestState":"x"}
    , verbatim[0..], &scratch);
    try testing.expectEqualStrings(result_type_value.input_required, present.result_type.value.?);
    try testing.expectEqual(KnownResultType.input_required, present.result_type.known().?);

    // A peer on an earlier revision omits the member. A default of
    // `input_required` would be indistinguishable from a value the peer sent
    // and would be re-encoded as one.
    const absent = try decodeInputRequiredResult(
        \\{"requestState":"x"}
    , verbatim[0..], &scratch);
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

test "a result object with a trailing byte is refused, not truncated" {
    var scratch: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    // The document is one result and the tail is a second one. Accepting it
    // lost the tail silently: the bytes that came back still decoded, so
    // nothing downstream ever reported an error, and a document no encoder here
    // could have produced came back out of a decoder that called it whole.
    try testing.expectError(
        error.MalformedJson,
        decodeResultType("{\"resultType\":\"complete\",\"tools\":[]} trailing", &scratch),
    );
    // `{}` is the other accepted shape, and the check stands for it as well:
    // an empty object skips the member loop, not the check.
    try testing.expectError(error.MalformedJson, decodeResultType("{} trailing", &scratch));

    // The round trip the tail would have broken, on documents the decoder
    // accepts whole. The member the type does not govern is in the refusal
    // above rather than here, because a skipped member is gone by design and
    // says nothing about the tail.
    const complete = try decodeResultType("{\"resultType\":\"complete\"}", &scratch);
    var writer = json.Writer.init(&out);
    try encodeResultType(complete, &writer);
    try testing.expectEqualStrings("{\"resultType\":\"complete\"}", writer.written());
    const empty = try decodeResultType("{}", &scratch);
    writer = json.Writer.init(&out);
    try encodeResultType(empty, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    // `decodeCacheable` skips every member the caching rules do not govern, so
    // it has no byte-exact encoder to lose a tail with. The decoder must
    // refuse the document anyway: it is not one. `encodeCacheable` writes the
    // two required members and no third, which is a constructor rather than
    // this decoder's inverse, and its doc says so.
    try testing.expectError(
        error.MalformedJson,
        decodeCacheable("{\"ttlMs\":0,\"cacheScope\":\"public\"} trailing", &scratch),
    );

    // Whitespace after the value is not a second document, and a result
    // written across lines is the ordinary case, so it still decodes.
    const spaced = try decodeResultType("{\"resultType\":\"complete\"} \n\t ", &scratch);
    try testing.expectEqualStrings(result_type_value.complete, spaced.value.?);
    const cacheable = try decodeCacheable("{\"ttlMs\":0,\"cacheScope\":\"public\"}\n", &scratch);
    try testing.expectEqual(@as(u64, 0), cacheable.ttl_ms);
}

test "an InputRequiredResult with a trailing byte is refused" {
    var scratch: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // The tail is dropped whichever arm took the last member, so the case is
    // stated against the `requestState` arm, which takes a lexeme and is the
    // one a check written inside the arm would pass. The `inputRequests` arm
    // takes a `rawValue` and is the second half of the same claim.
    const interim = "{\"resultType\":\"input_required\",\"requestState\":\"x\"}";
    try testing.expectError(
        error.MalformedJson,
        decodeInputRequiredResult(
            "{\"resultType\":\"input_required\",\"requestState\":\"x\"} trailing",
            verbatim[0..],
            &scratch,
        ),
    );
    const requests =
        "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"tools/call\"}}}";
    try testing.expectError(
        error.MalformedJson,
        decodeInputRequiredResult(
            "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"tools/call\"}}} trailing",
            verbatim[0..],
            &scratch,
        ),
    );
    // A document that is malformed at its end is malformed whatever else is
    // wrong with it, so this answers the tail rather than the presence rule
    // that sits below the check.
    try testing.expectError(
        error.MalformedJson,
        decodeInputRequiredResult(
            "{\"resultType\":\"input_required\"} trailing",
            verbatim[0..],
            &scratch,
        ),
    );

    // The round trip the tail would have broken, on the documents that are
    // accepted. A client answers the interim result with a retry, so this pair
    // is one a caller really writes.
    const state_decoded = try decodeInputRequiredResult(interim, verbatim[0..], &scratch);
    var writer = json.Writer.init(&out);
    try encodeInputRequiredResult(state_decoded, &writer);
    try testing.expectEqualStrings(interim, writer.written());
    const request_decoded = try decodeInputRequiredResult(requests, verbatim[0..], &scratch);
    writer = json.Writer.init(&out);
    try encodeInputRequiredResult(request_decoded, &writer);
    try testing.expectEqualStrings(requests, writer.written());

    // Whitespace after the value is not a second document.
    const spaced = try decodeInputRequiredResult(
        "{\"resultType\":\"input_required\",\"requestState\":\"x\"} \n",
        verbatim[0..],
        &scratch,
    );
    try testing.expectEqualStrings("x", spaced.request_state.?);
}

test "params with a trailing byte are refused before the leg is read" {
    var scratch: [128]u8 = undefined;

    // `CacheLeg` has no encoder either, so this is a validation hole rather
    // than a lost byte. It is on the leg that decides whether a result may be
    // cached at all, which is the one place a truncated read is not visible.
    try testing.expectError(
        error.MalformedJson,
        decodeCacheLeg("{\"name\":\"echo\",\"requestState\":\"st\"} trailing", &scratch),
    );
    // The empty object is the other accepted shape, and it takes the check as
    // well: it skips the member loop, not the check.
    try testing.expectError(error.MalformedJson, decodeCacheLeg("{} trailing", &scratch));

    // Whitespace after the value is not a second document.
    try testing.expectEqual(
        CacheLeg.mrtr_retry,
        try decodeCacheLeg("{\"name\":\"echo\",\"requestState\":\"st\"} \n", &scratch),
    );
    try testing.expectEqual(
        CacheLeg.original,
        try decodeCacheLeg("{\"name\":\"echo\",\"arguments\":{\"message\":\"hi\"}} \n", &scratch),
    );
}

test "the five ContentBlock tags are the literals section 4.10.4 gives" {
    const kinds = [_]ContentBlockKind{
        .text,
        .image,
        .audio,
        .resource_link,
        .resource,
    };
    try testing.expectEqual(@as(usize, 5), kinds.len);
    for (kinds) |kind| {
        try testing.expectEqual(kind, ContentBlockKind.fromString(kind.string()).?);
    }
    try testing.expectEqualStrings("resource_link", ContentBlockKind.resource_link.string());
    try testing.expectEqual(Role.user, Role.fromString(role.user).?);
    // Both sets are closed, so a value outside them names nothing rather than
    // resolving to the first arm or to a catch-all.
    try testing.expectEqual(@as(?ContentBlockKind, null), ContentBlockKind.fromString("video"));
    try testing.expectEqual(@as(?ContentBlockKind, null), ContentBlockKind.fromString("Text"));
    try testing.expectEqual(@as(?Role, null), Role.fromString("system"));
}

test "an unrecognised ContentBlock type is UnknownTag, not a carried lexeme" {
    var scratch: [256]u8 = undefined;
    var blocks: [4]ContentBlock = undefined;
    var messages: [4]PromptMessage = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // A `type` this revision cannot read has no arm to decode into, and
    // refusing it is the only answer that reports a fault rather than
    // inventing one. `SPEC-DECISIONS.md` section 5 records why this and the
    // member rule below are not in tension.
    try testing.expectError(
        error.UnknownTag,
        decodeToolCallResult(
            \\{"content":[{"type":"video","data":"AAAA"}]}
        , blocks[0..], verbatim[0..], &scratch),
    );
    // An object that is not a block at all is a different fault and stays one.
    try testing.expectError(
        error.MissingField,
        decodeToolCallResult(
            \\{"content":[{"text":"no tag here"}]}
        , blocks[0..], verbatim[0..], &scratch),
    );
    // The other closed sets in this library refuse the same way, so this is
    // the house rule rather than a policy of one decoder.
    try testing.expectError(
        error.UnknownTag,
        decodePromptsGetResult(
            \\{"messages":[{"role":"system","content":{"type":"text","text":"x"}}]}
        , messages[0..], verbatim[0..], &scratch),
    );
    // A block whose required member is absent is refused for that, not for
    // the tag it did carry.
    try testing.expectError(
        error.MissingField,
        decodeToolCallResult(
            \\{"content":[{"type":"text"}]}
        , blocks[0..], verbatim[0..], &scratch),
    );
}

test "an unrecognised member beside a recognised one is written back whole" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var blocks: [4]ContentBlock = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // The result object is open in its keys: `Result` declares
    // `[key: string]: unknown` and the specification says a result may follow
    // any object structure, so a key no result type models is carried as the
    // lexeme it arrived as rather than dropped.
    const result = try decodeToolCallResult(
        \\{"resultType":"complete","content":[{"type":"text","text":"h\ti"}],"vendorHint":{"a":[1,2]},"x-vendor":7}
    , blocks[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 2), result.verbatim.len);
    try testing.expectEqualStrings("vendorHint", result.verbatim[0].key);
    var writer = json.Writer.init(&out);
    try encodeToolCallResult(result, &writer);
    try testing.expectEqualStrings(
        \\{"resultType":"complete","content":[{"type":"text","text":"h\ti"}],"vendorHint":{"a":[1,2]},"x-vendor":7}
    , writer.written());

    // The same rule one level in, and the two slices are separate: a store
    // that let them share one region would write each member twice.
    var blocks_two: [4]ContentBlock = undefined;
    var verbatim_two: [16]VerbatimMember = undefined;
    const nested = try decodeToolCallResult(
        \\{"content":[{"type":"text","text":"hi","annotations":{"priority":0.8},"futureHint":7}],"topLevel":1}
    , blocks_two[0..], verbatim_two[0..], &scratch);
    try testing.expectEqual(@as(usize, 1), nested.verbatim.len);
    try testing.expectEqual(@as(usize, 1), nested.content[0].text.verbatim.len);
    try testing.expectEqualStrings("futureHint", nested.content[0].text.verbatim[0].key);
    // `annotations` is a member section 4.10.4 names, so it is a field and
    // not a carried lexeme; the block's lexeme is the one the shape does not
    // close.
    try testing.expectEqualStrings("{\"priority\":0.8}", nested.content[0].text.annotations.?);
    writer = json.Writer.init(&out);
    try encodeToolCallResult(nested, &writer);
    try testing.expectEqualStrings(
        \\{"content":[{"type":"text","text":"hi","annotations":{"priority":0.8},"futureHint":7}],"topLevel":1}
    , writer.written());

    // An embedded resource carries its own unmodelled members, and they come
    // back inside the `resource` member rather than beside it.
    var blocks_three: [4]ContentBlock = undefined;
    var verbatim_three: [16]VerbatimMember = undefined;
    const embedded = try decodeToolCallResult(
        \\{"content":[{"type":"resource","resource":{"uri":"file:///a","text":"x","checksum":"aa"}}]}
    , blocks_three[0..], verbatim_three[0..], &scratch);
    try testing.expectEqual(@as(usize, 0), embedded.verbatim.len);
    try testing.expectEqual(@as(usize, 1), embedded.content[0].resource.resource.text.verbatim.len);
    writer = json.Writer.init(&out);
    try encodeToolCallResult(embedded, &writer);
    try testing.expectEqualStrings(
        \\{"content":[{"type":"resource","resource":{"uri":"file:///a","text":"x","checksum":"aa"}}]}
    , writer.written());
}

test "a CallToolResult round-trips, refuses what is missing, and refuses a tail" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var blocks: [4]ContentBlock = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    const wire =
        "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"h\\ti\"}," ++
        "{\"type\":\"image\",\"data\":\"AAEC\",\"mimeType\":\"image/png\"}]," ++
        "\"structuredContent\":{\"ok\":true},\"isError\":false," ++
        "\"_meta\":{\"io.modelcontextprotocol/x\":1}}";
    const decoded = try decodeToolCallResult(wire, blocks[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 2), decoded.content.len);
    try testing.expectEqualStrings("h\ti", decoded.content[0].text.text);
    try testing.expectEqual(ContentBlockKind.image, decoded.content[1].tag());
    try testing.expectEqual(@as(?bool, false), decoded.is_error);
    var writer = json.Writer.init(&out);
    try encodeToolCallResult(decoded, &writer);
    try testing.expectEqualStrings(wire, writer.written());

    // `content` is required, and an absent one is not an empty array: both are
    // a zero-length slice on the value, so only the refusal tells them apart.
    try testing.expectError(
        error.MissingField,
        decodeToolCallResult(
            \\{"resultType":"complete"}
        , blocks[0..], verbatim[0..], &scratch),
    );
    // Present and empty is well formed and stays that way.
    const empty = try decodeToolCallResult(
        \\{"content":[]}
    , blocks[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 0), empty.content.len);
    try testing.expectEqual(@as(?bool, null), empty.is_error);

    // A JSON document is exactly one value.
    try testing.expectError(
        error.MalformedJson,
        decodeToolCallResult(
            \\{"content":[]} trailing
        , blocks[0..], verbatim[0..], &scratch),
    );
    // Whitespace after the value is not a second document.
    const spaced = try decodeToolCallResult(
        "{\"content\":[]} \n",
        blocks[0..],
        verbatim[0..],
        &scratch,
    );
    try testing.expectEqual(@as(usize, 0), spaced.content.len);
}

test "a content array or member store that fills is refused, not truncated" {
    var scratch: [256]u8 = undefined;
    var blocks: [1]ContentBlock = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    try testing.expectError(
        error.BufferTooSmall,
        decodeToolCallResult(
            \\{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}
        , blocks[0..], verbatim[0..], &scratch),
    );
    // The caller's own store is exhausted by the same shape of document, and
    // that is a refusal rather than a result whose members quietly stopped
    // being written back.
    var one_member: [1]VerbatimMember = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        decodeToolCallResult(
            \\{"content":[{"type":"text","text":"a"}],"first":1,"second":2}
        , blocks[0..], one_member[0..], &scratch),
    );
}

test "a ListToolsResult round-trips, refuses what is missing, and refuses a tail" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var tools: [4]Tool = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    const wire =
        "{\"resultType\":\"complete\",\"ttlMs\":60000,\"cacheScope\":\"public\",\"nextCursor\":\"c2\"," ++
        "\"tools\":[{\"name\":\"ech\\no\",\"inputSchema\":{\"type\":\"object\"}," ++
        "\"description\":\"says it back\"}],\"_meta\":{\"a\":1}," ++
        "\"note\":\"hi\"}";
    const decoded = try decodeToolListResult(wire, tools[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 1), decoded.tools.len);
    try testing.expectEqualStrings("ech\no", decoded.tools[0].name);
    try testing.expectEqual(@as(u64, 60000), decoded.cacheable.ttl_ms);
    try testing.expectEqualStrings("c2", decoded.page.next_cursor.?);
    // `description` is a member PROTOCOLS.md names without enumerating, so it
    // arrives in the tool's own verbatim slice rather than being refused.
    try testing.expectEqualStrings("description", decoded.tools[0].verbatim[0].key);
    var writer = json.Writer.init(&out);
    try encodeToolListResult(decoded, &writer);
    try testing.expectEqualStrings(wire, writer.written());

    // Each of the three required members on its own: `tools`, and the two the
    // caching rules govern.
    try testing.expectError(
        error.MissingField,
        decodeToolListResult(
            \\{"ttlMs":0,"cacheScope":"public"}
        , tools[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeToolListResult(
            \\{"cacheScope":"public","tools":[]}
        , tools[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeToolListResult(
            \\{"ttlMs":0,"tools":[]}
        , tools[0..], verbatim[0..], &scratch),
    );
    // `ttlMs: 0` is a hint of immediately stale, not an absent member. The
    // presence is tracked beside the value for exactly this.
    const zero = try decodeToolListResult(
        \\{"ttlMs":0,"cacheScope":"public","tools":[]}
    , tools[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(u64, 0), zero.cacheable.ttl_ms);

    try testing.expectError(
        error.MalformedJson,
        decodeToolListResult(
            \\{"ttlMs":0,"cacheScope":"public","tools":[]} trailing
        , tools[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodeToolListResult(
            \\{"ttlMs":0,"cacheScope":"public","tools":[{"name":"a","inputSchema":{}},{"name":"b","inputSchema":{}}]}
        , tools[0..1], verbatim[0..], &scratch),
    );
}

test "a ReadResourceResult round-trips both contents forms" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var contents: [4]ResourceContents = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    const wire =
        "{\"resultType\":\"complete\",\"ttlMs\":300000,\"cacheScope\":\"private\"," ++
        "\"contents\":[{\"uri\":\"file:///a\",\"text\":\"hel\\tlo\"},{\"uri\":\"file:///b\"," ++
        "\"blob\":\"AAEC\",\"mimeType\":\"application/octet-stream\"}]," ++
        "\"_meta\":{}}";
    const decoded = try decodeResourceReadResult(wire, contents[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 2), decoded.contents.len);
    try testing.expectEqualStrings("hel\tlo", decoded.contents[0].text.text);
    try testing.expectEqualStrings("AAEC", decoded.contents[1].blob.blob);
    var writer = json.Writer.init(&out);
    try encodeResourceReadResult(decoded, &writer);
    try testing.expectEqualStrings(wire, writer.written());

    try testing.expectError(
        error.MissingField,
        decodeResourceReadResult(
            \\{"ttlMs":0,"cacheScope":"public"}
        , contents[0..], verbatim[0..], &scratch),
    );
    // Each of the three required members on its own: `contents`, and the two
    // the caching rules govern.
    try testing.expectError(
        error.MissingField,
        decodeResourceReadResult(
            \\{"cacheScope":"public","contents":[]}
        , contents[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeResourceReadResult(
            \\{"ttlMs":0,"contents":[]}
        , contents[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeResourceReadResult(
            \\{"ttlMs":0,"cacheScope":"public","contents":[]} trailing
        , contents[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodeResourceReadResult(
            \\{"ttlMs":0,"cacheScope":"public","contents":[{"uri":"a","text":""},{"uri":"b","text":""}]}
        , contents[0..1], verbatim[0..], &scratch),
    );
}

test "contents carrying both forms or neither is the 4.10.7 refusal" {
    var scratch: [256]u8 = undefined;
    var contents: [4]ResourceContents = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // The union has no discriminator, so an object with both matches both
    // members and the source does not say which to read.
    try testing.expectError(
        error.InvalidField,
        decodeResourceReadResult(
            \\{"ttlMs":0,"cacheScope":"public","contents":[{"uri":"a","text":"x","blob":"AAEC"}]}
        , contents[0..], verbatim[0..], &scratch),
    );
    // Well-formed JSON that matches neither member.
    try testing.expectError(
        error.MissingField,
        decodeResourceReadResult(
            \\{"ttlMs":0,"cacheScope":"public","contents":[{"uri":"a"}]}
        , contents[0..], verbatim[0..], &scratch),
    );
    // `resources/read` returns a sequence with no `nextCursor`, so a page
    // member on it is one nothing models and is carried rather than applied.
    const carried = try decodeResourceReadResult(
        \\{"ttlMs":0,"cacheScope":"public","contents":[{"uri":"a","text":"x"}],"nextCursor":"c2"}
    , contents[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 1), carried.verbatim.len);
    try testing.expectEqualStrings("nextCursor", carried.verbatim[0].key);
}

test "a GetPromptResult round-trips one block per message" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var messages: [4]PromptMessage = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    const wire =
        "{\"resultType\":\"complete\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\"," ++
        "\"text\":\"h\\ti\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"resource_link\"," ++
        "\"uri\":\"file:///a\",\"name\":\"a\"}}],\"description\":\"a prompt\"," ++
        "\"_meta\":{}}";
    const decoded = try decodePromptsGetResult(wire, messages[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 2), decoded.messages.len);
    try testing.expectEqual(Role.user, decoded.messages[0].role);
    try testing.expectEqual(ContentBlockKind.resource_link, decoded.messages[1].content.tag());
    var writer = json.Writer.init(&out);
    try encodePromptsGetResult(decoded, &writer);
    try testing.expectEqualStrings(wire, writer.written());

    try testing.expectError(
        error.MissingField,
        decodePromptsGetResult(
            \\{"resultType":"complete","description":"d"}
        , messages[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodePromptsGetResult(
            \\{"messages":[{"content":{"type":"text","text":"hi"}}]}
        , messages[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodePromptsGetResult(
            \\{"messages":[{"role":"user"}]}
        , messages[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodePromptsGetResult(
            \\{"messages":[]} trailing
        , messages[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodePromptsGetResult("{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"a\"}}," ++
            "{\"role\":\"user\",\"content\":{\"type\":\"text\"," ++
            "\"text\":\"b\"}}]}", messages[0..1], verbatim[0..], &scratch),
    );
}

test "a DiscoverResult round-trips in the order a session already writes" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var versions: [4][]const u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // The same member order `mcp_session.Server.discoverBody` writes, so a
    // body a session built re-encodes to the same bytes rather than to an
    // equivalent document in another order.
    const wire =
        "{\"resultType\":\"complete\",\"ttlMs\":300000,\"cacheScope\":\"public\"," ++
        "\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\"]," ++
        "\"capabilities\":{\"tools\":{\"listChanged\":true},\"experimental\":{\"x/thing\":{}}}," ++
        "\"instructions\":\"be\\tbrief\"," ++
        "\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"s\"}}}";
    const decoded = try decodeDiscoverResult(wire, versions[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 2), decoded.supported_versions.len);
    try testing.expectEqualStrings("2026-07-28", decoded.supported_versions[0]);
    // The capability set is explicitly not closed, so the object is carried
    // whole rather than flattened into a shape that cannot hold every key a
    // peer may declare.
    try testing.expectEqualStrings(
        "{\"tools\":{\"listChanged\":true},\"experimental\":{\"x/thing\":{}}}",
        decoded.capabilities,
    );
    var writer = json.Writer.init(&out);
    try encodeDiscoverResult(decoded, &writer);
    try testing.expectEqualStrings(wire, writer.written());

    try testing.expectError(
        error.MissingField,
        decodeDiscoverResult(
            \\{"ttlMs":0,"cacheScope":"public","supportedVersions":[]}
        , versions[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeDiscoverResult(
            \\{"ttlMs":0,"cacheScope":"public","capabilities":{}}
        , versions[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeDiscoverResult(
            \\{"cacheScope":"public","supportedVersions":[],"capabilities":{}}
        , versions[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeDiscoverResult(
            \\{"ttlMs":0,"cacheScope":"public","supportedVersions":[],"capabilities":null} trailing
        , versions[0..], verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodeDiscoverResult(
            \\{"ttlMs":0,"cacheScope":"public","supportedVersions":["a","b"],"capabilities":null}
        , versions[0..1], verbatim[0..], &scratch),
    );

    // A member with no object in it is `"null"`, and that is distinct from an
    // absent member: a session with no capabilities writes the literal.
    const bare = try decodeDiscoverResult(
        \\{"ttlMs":0,"cacheScope":"public","supportedVersions":[],"capabilities":null}
    , versions[0..], verbatim[0..], &scratch);
    try testing.expectEqualStrings("null", bare.capabilities);
}

test "a page is read without its payload and written back whole" {
    var scratch: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    const wire =
        "{\"resultType\":\"complete\",\"ttlMs\":1000,\"cacheScope\":\"public\"," ++
        "\"nextCursor\":\"c\\t2\",\"tools\":[{\"name\":\"echo\"," ++
        "\"inputSchema\":{}}]}";
    const decoded = try decodePaginatedResult(wire, verbatim[0..], &scratch);
    try testing.expectEqualStrings("c\t2", decoded.page.next_cursor.?);
    // The payload is not the page reader's business, and skipping it would
    // lose it on the way out, so the one member it does not model comes back
    // as a lexeme and is written again.
    try testing.expectEqual(@as(usize, 1), decoded.verbatim.len);
    try testing.expectEqualStrings("tools", decoded.verbatim[0].key);
    var writer = json.Writer.init(&out);
    try encodePaginatedResult(decoded, &writer);
    try testing.expectEqualStrings(wire, writer.written());
    // `PaginatedResult` has no required member — `nextCursor` is the one it
    // contributes and it is optional — so the absence case here is a document
    // that is not a result object at all. `{}` and an array are both refused,
    // and the reader will not read an empty object as a last page.
    try testing.expectError(
        error.MissingField,
        decodePaginatedResult("{}", verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodePaginatedResult("[]", verbatim[0..], &scratch),
    );
    // A result with a `resultType` and no cursor is the last page, and the two
    // are different facts rather than one default.
    const last = try decodePaginatedResult(
        \\{"resultType":"complete","tools":[]}
    , verbatim[0..], &scratch);
    try testing.expectEqual(@as(?[]const u8, null), last.page.next_cursor);
    try testing.expectEqual(@as(?Cacheable, null), last.cacheable);

    try testing.expectError(
        error.MalformedJson,
        decodePaginatedResult(
            \\{"nextCursor":"c2"} trailing
        , verbatim[0..], &scratch),
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodePaginatedResult(
            \\{"a":1,"b":2}
        , verbatim[0..1], &scratch),
    );
}

test "the two cacheable members are written as the digits that were read" {
    var out: [128]u8 = undefined;
    var writer = json.Writer.init(&out);
    try encodeCacheable(.{ .ttl_ms = 0, .cache_scope = .public }, &writer);
    try testing.expectEqualStrings("{\"ttlMs\":0,\"cacheScope\":\"public\"}", writer.written());

    writer = json.Writer.init(&out);
    try encodeCacheable(.{ .ttl_ms = 60000, .cache_scope = .private }, &writer);
    try testing.expectEqualStrings("{\"ttlMs\":60000,\"cacheScope\":\"private\"}", writer.written());

    // Twenty digits is the widest a `u64` is, and the fixed array the writer
    // uses covers exactly that.
    writer = json.Writer.init(&out);
    try encodeCacheable(.{
        .ttl_ms = std.math.maxInt(u64),
        .cache_scope = .private,
    }, &writer);
    try testing.expectEqualStrings(
        "{\"ttlMs\":18446744073709551615,\"cacheScope\":\"private\"}",
        writer.written(),
    );
}

test "an encoder refuses a carried value its own reader would refuse" {
    var out: [128]u8 = undefined;
    var writer = json.Writer.init(&out);

    // `inputRequests` is spliced verbatim, so a caller that handed the
    // encoder something that is not JSON would emit a body no reader can
    // read.
    try testing.expectError(error.InvalidField, encodeInputRequiredResult(.{
        .result_type = ResultType.parse(result_type_value.input_required),
        .input_requests = "",
    }, &writer));
    try testing.expectError(
        error.InvalidField,
        encodeToolCallResult(.{ .structured_content = "not json" }, &writer),
    );
    // The refusal leaves the caller's buffer as it was, which is what makes a
    // retry after a grow worth anything.
    try testing.expectEqualStrings("", writer.written());

    // A `structuredContent` that is `null` is a value where an absent one is
    // not, so it is written rather than refused.
    const blocks: [0]ContentBlock = .{};
    writer = json.Writer.init(&out);
    try encodeToolCallResult(.{ .content = blocks[0..], .structured_content = "null" }, &writer);
    try testing.expectEqualStrings("{\"content\":[],\"structuredContent\":null}", writer.written());
}

test "a repeated member is first-wins, and a repeated unmodelled one is kept twice" {
    var scratch: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var blocks: [4]ContentBlock = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // The members the shape names: a later occurrence must not be able to
    // make a failed comparison pass, so the first is the one kept.
    const first = try decodeToolCallResult(
        \\{"content":[{"type":"text","text":"a"}],"content":[{"type":"text","text":"b"}],"isError":true,"isError":false}
    , blocks[0..], verbatim[0..], &scratch);
    try testing.expectEqualStrings("a", first.content[0].text.text);
    try testing.expectEqual(@as(?bool, true), first.is_error);

    // The members it does not: there is no value to resolve, so both
    // occurrences are carried and the document re-encodes whole.
    const both = try decodeToolCallResult(
        \\{"content":[],"hint":1,"hint":2}
    , blocks[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(usize, 2), both.verbatim.len);
    var writer = json.Writer.init(&out);
    try encodeToolCallResult(both, &writer);
    try testing.expectEqualStrings("{\"content\":[],\"hint\":1,\"hint\":2}", writer.written());
}

test "the interim result writers are the library's, not a harness's" {
    var scratch: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // `encodeResultType` and `encodeInputRequiredResult` are the encoders for
    // the two public decoders beside them. A result type a server writes is
    // the same value a client reads back, so the pair is worth stating here
    // rather than only in the harness that used to own a private copy.
    const decoded = try decodeResultType("{\"resultType\":\"complete\"}", &scratch);
    var writer = json.Writer.init(&out);
    try encodeResultType(decoded, &writer);
    try testing.expectEqualStrings("{\"resultType\":\"complete\"}", writer.written());

    const interim = try decodeInputRequiredResult(
        \\{"resultType":"input_required","inputRequests":{"a":{"method":"tools/call"}}}
    , verbatim[0..], &scratch);
    writer = json.Writer.init(&out);
    try encodeInputRequiredResult(interim, &writer);
    try testing.expectEqualStrings(
        \\{"resultType":"input_required","inputRequests":{"a":{"method":"tools/call"}}}
    , writer.written());
}

test "a bad member inside an element is refused before the object is written" {
    var out: [256]u8 = undefined;
    var writer = json.Writer.init(&out);

    // The offending member is four levels down, in a list element's schema.
    // A check that ran only as each member was written would leave
    // `{"resultType":"complete","ttlMs":0,"cacheScope":"public","tools":[{"name":`
    // in the buffer, which is neither a result nor nothing.
    const tools = [_]Tool{
        .{ .name = "a", .input_schema = "{\"type\":\"object\"}" },
        .{ .name = "b", .input_schema = "" },
    };
    try testing.expectError(error.InvalidField, encodeToolListResult(.{
        .cacheable = .{ .ttl_ms = 0, .cache_scope = .public },
        .tools = tools[0..],
    }, &writer));
    try testing.expectEqualStrings("", writer.written());

    // The same rule for a content block and for the `_meta` of a result.
    const blocks = [_]ContentBlock{
        .{ .text = .{ .text = "ok", .annotations = "{\"priority\":0.8}" } },
    };
    try testing.expectError(
        error.InvalidField,
        encodeToolCallResult(.{
            .content = blocks[0..1],
            .meta = "} not json",
        }, &writer),
    );
    try testing.expectEqualStrings("", writer.written());

    // An object name is an arbitrary string under RFC 8259, so an empty one
    // is a member and not a fault. The decoder accepts `{"":1}` and carries
    // it; an encoder that refused to write it back would break PROTOCOLS.md
    // section 2 in the `decode(encode(x)) == x` direction for a document this
    // library itself decodes.
    var scratch: [64]u8 = undefined;
    var empty_name: [1]VerbatimMember = undefined;
    const no_blocks: [0]ContentBlock = .{};
    const named = try decodeToolCallResult(
        \\{"content":[],"":1}
    , no_blocks[0..], empty_name[0..], &scratch);
    try testing.expectEqual(@as(usize, 1), named.verbatim.len);
    try testing.expectEqualStrings("", named.verbatim[0].key);
    writer = json.Writer.init(&out);
    try encodeToolCallResult(named, &writer);
    try testing.expectEqualStrings(
        \\{"content":[],"":1}
    , writer.written());
}

test "every nested decode takes its own region of the one escape scratch" {
    var scratch: [256]u8 = undefined;
    var out: [1024]u8 = undefined;
    var messages: [4]PromptMessage = undefined;
    var tools: [4]Tool = undefined;
    var blocks: [4]ContentBlock = undefined;
    var contents: [4]ResourceContents = undefined;
    var versions: [4][]const u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // Every document below carries escaped strings in more than one place, and
    // every one of them is still live when the encode happens. A reader built
    // over a captured lexeme restarts the escape scratch at zero, so the
    // second string decoded would land on the first one's bytes — and
    // `json.Reader.requiredScratchLen` cannot see it, because the writes
    // collide rather than overflow.
    const prompts = try decodePromptsGetResult(
        "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"a\\nb\"}}," ++
            "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"c\\nd\"}}]," ++
            "\"description\":\"D\\nD\"}",
        messages[0..],
        verbatim[0..],
        &scratch,
    );
    try testing.expectEqualStrings("a\nb", prompts.messages[0].content.text.text);
    try testing.expectEqualStrings("c\nd", prompts.messages[1].content.text.text);
    try testing.expectEqualStrings("D\nD", prompts.description.?);
    var writer = json.Writer.init(&out);
    try encodePromptsGetResult(prompts, &writer);
    try testing.expectEqualStrings(
        "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"a\\nb\"}}," ++
            "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"c\\nd\"}}]," ++
            "\"description\":\"D\\nD\"}",
        writer.written(),
    );

    // The same collision between the cursor the result decoder read and the
    // elements it decoded afterwards.
    const listed = try decodeToolListResult(
        \\{"ttlMs":1000,"cacheScope":"public","nextCursor":"c\nc","tools":[{"name":"n\nn","inputSchema":{}}]}
    , tools[0..], verbatim[0..], &scratch);
    try testing.expectEqualStrings("c\nc", listed.page.next_cursor.?);
    try testing.expectEqualStrings("n\nn", listed.tools[0].name);
    writer = json.Writer.init(&out);
    try encodeToolListResult(listed, &writer);
    try testing.expectEqualStrings(
        \\{"ttlMs":1000,"cacheScope":"public","nextCursor":"c\nc","tools":[{"name":"n\nn","inputSchema":{}}]}
    , writer.written());

    // And between a member the loop read and a `string[]` decoded after it.
    const found = try decodeDiscoverResult(
        \\{"ttlMs":1,"cacheScope":"public","supportedVersions":["v\nv"],"capabilities":{},"instructions":"i\ni"}
    , versions[0..], verbatim[0..], &scratch);
    try testing.expectEqualStrings("v\nv", found.supported_versions[0]);
    try testing.expectEqualStrings("i\ni", found.instructions.?);
    writer = json.Writer.init(&out);
    try encodeDiscoverResult(found, &writer);
    try testing.expectEqualStrings(
        \\{"ttlMs":1,"cacheScope":"public","supportedVersions":["v\nv"],"capabilities":{},"instructions":"i\ni"}
    , writer.written());

    // `resultType` is a string like any other, and it is read before the
    // payload that would otherwise be written over it.
    const called = try decodeToolCallResult(
        \\{"resultType":"c\no","content":[{"type":"text","text":"t\tt"}]}
    , blocks[0..], verbatim[0..], &scratch);
    try testing.expectEqualStrings("c\no", called.result_type.value.?);
    try testing.expectEqualStrings("t\tt", called.content[0].text.text);
    writer = json.Writer.init(&out);
    try encodeToolCallResult(called, &writer);
    try testing.expectEqualStrings(
        \\{"resultType":"c\no","content":[{"type":"text","text":"t\tt"}]}
    , writer.written());

    const read = try decodeResourceReadResult(
        \\{"resultType":"c\no","ttlMs":0,"cacheScope":"public","contents":[{"uri":"u\n1","text":"x\ny"}]}
    , contents[0..], verbatim[0..], &scratch);
    try testing.expectEqualStrings("c\no", read.result_type.value.?);
    try testing.expectEqualStrings("u\n1", read.contents[0].text.uri);
    try testing.expectEqualStrings("x\ny", read.contents[0].text.text);
    writer = json.Writer.init(&out);
    try encodeResourceReadResult(read, &writer);
    try testing.expectEqualStrings(
        \\{"resultType":"c\no","ttlMs":0,"cacheScope":"public","contents":[{"uri":"u\n1","text":"x\ny"}]}
    , writer.written());

    // The member **name**, which is the one corruption the peer sees on the
    // wire: `nextKey` unescapes into the same scratch, so the encoder would
    // write back a member name the document never carried.
    var keyed_verbatim: [8]VerbatimMember = undefined;
    const keyed = try decodeToolCallResult(
        \\{"content":[{"type":"text","text":"a\nb"}],"x\ty":1}
    , blocks[0..], keyed_verbatim[0..], &scratch);
    try testing.expectEqualStrings("x\ty", keyed.verbatim[0].key);
    try testing.expectEqualStrings("a\nb", keyed.content[0].text.text);
    writer = json.Writer.init(&out);
    try encodeToolCallResult(keyed, &writer);
    try testing.expectEqualStrings(
        \\{"content":[{"type":"text","text":"a\nb"}],"x\ty":1}
    , writer.written());

    // And the lexeme inside a block: an embedded resource is decoded by a
    // reader of its own, so its strings and the next element's both have to
    // be standing when the encode happens.
    var embedded_verbatim: [8]VerbatimMember = undefined;
    const embedded = try decodeToolCallResult(
        \\{"content":[{"type":"resource","resource":{"uri":"file:///a","text":"r\n1"}},{"type":"text","text":"t\n2"}]}
    , blocks[0..], embedded_verbatim[0..], &scratch);
    try testing.expectEqualStrings("r\n1", embedded.content[0].resource.resource.text.text);
    try testing.expectEqualStrings("t\n2", embedded.content[1].text.text);
    writer = json.Writer.init(&out);
    try encodeToolCallResult(embedded, &writer);
    try testing.expectEqualStrings(
        \\{"content":[{"type":"resource","resource":{"uri":"file:///a","text":"r\n1"}},{"type":"text","text":"t\n2"}]}
    , writer.written());
}

test "a block keeps the members its shape does not model" {
    var scratch: [256]u8 = undefined;
    var out: [512]u8 = undefined;
    var messages: [4]PromptMessage = undefined;
    var blocks: [4]ContentBlock = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // `ResourceLink` is a `Resource` with a tag added, so `mimeType` and
    // `annotations` are legal on it; `ResourceLink` models neither, and the
    // member loop claims both for every tag. Claiming a member is a promise
    // to write it back, so they are carried rather than dropped — the same
    // rule `size` and `description` already follow through the `else` arm.
    const link = try decodePromptsGetResult(
        "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"resource_link\"," ++
            "\"uri\":\"file:///a\",\"name\":\"a\",\"mimeType\":\"text/plain\"," ++
            "\"annotations\":{\"audience\":[\"user\"]}}}]}",
        messages[0..],
        verbatim[0..],
        &scratch,
    );
    const carried = link.messages[0].content.resource_link;
    try testing.expectEqual(@as(usize, 2), carried.verbatim.len);
    try testing.expectEqualStrings("mimeType", carried.verbatim[0].key);
    try testing.expectEqualStrings("\"text/plain\"", carried.verbatim[0].value);
    try testing.expectEqualStrings("annotations", carried.verbatim[1].key);
    try testing.expectEqualStrings("{\"audience\":[\"user\"]}", carried.verbatim[1].value);
    var writer = json.Writer.init(&out);
    try encodePromptsGetResult(link, &writer);
    try testing.expectEqualStrings("{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"resource_link\"," ++
        "\"uri\":\"file:///a\",\"name\":\"a\",\"mimeType\":\"text/plain\"," ++
        "\"annotations\":{\"audience\":[\"user\"]}}}]}", writer.written());

    // One member along: the image and audio arms read the same member as the
    // string they require, escape and all, while a block that models no such
    // member carries it.
    const mixed = try decodeToolCallResult(
        "{\"content\":[{\"type\":\"text\",\"text\":\"t\",\"mimeType\":\"text/plain\"}," ++
            "{\"type\":\"image\",\"data\":\"AAEC\"," ++
            "\"mimeType\":\"image/p\\nng\"}]}",
        blocks[0..],
        verbatim[0..],
        &scratch,
    );
    try testing.expectEqualStrings("image/p\nng", mixed.content[1].image.mime_type);
    try testing.expectEqual(@as(usize, 1), mixed.content[0].text.verbatim.len);
    try testing.expectEqualStrings("mimeType", mixed.content[0].text.verbatim[0].key);
    try testing.expectEqualStrings("\"text/plain\"", mixed.content[0].text.verbatim[0].value);
    writer = json.Writer.init(&out);
    try encodeToolCallResult(mixed, &writer);
    try testing.expectEqualStrings("{\"content\":[{\"type\":\"text\",\"text\":\"t\",\"mimeType\":\"text/plain\"}," ++
        "{\"type\":\"image\",\"data\":\"AAEC\"," ++
        "\"mimeType\":\"image/p\\nng\"}]}", writer.written());
}

test "every claimed member the chosen arm does not model is carried, not dropped" {
    var scratch: [512]u8 = undefined;
    var in: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var blocks: [4]ContentBlock = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // The member loop claims eleven names for every tag and each arm reads a few
    // of them, so most pairs are a member this block accepted and no encoder
    // could write back. `size` and `description` already reach `verbatim`
    // through the `else` arm; these reach it through the carry. One row per
    // arm, each naming every member that arm does not model, so a name added to
    // the loop and left out of `content_block_claims` fails here.
    const arms = [_]struct {
        tag: []const u8,
        /// The members this arm does model, so the decode reaches the member
        /// under test rather than refusing over one it requires.
        modelled: []const u8,
        unmodelled: []const []const u8,
    }{
        .{ .tag = "text", .modelled = "\"text\":\"t\"", .unmodelled = &.{
            "data", "mimeType", "uri", "name", "title", "icons", "resource",
        } },
        .{ .tag = "image", .modelled = "\"data\":\"AAEC\",\"mimeType\":\"image/png\"", .unmodelled = &.{
            "text", "uri", "name", "title", "icons", "resource",
        } },
        .{ .tag = "audio", .modelled = "\"data\":\"AAEC\",\"mimeType\":\"audio/mpeg\"", .unmodelled = &.{
            "text", "uri", "name", "title", "icons", "resource",
        } },
        .{ .tag = "resource_link", .modelled = "\"uri\":\"file:///a\",\"name\":\"a\"", .unmodelled = &.{
            "text", "data", "mimeType", "annotations", "resource",
        } },
        .{ .tag = "resource", .modelled = "\"resource\":{\"uri\":\"file:///a\",\"text\":\"r\"}", .unmodelled = &.{
            "text", "data", "mimeType", "uri", "name", "title", "icons",
        } },
    };

    for (arms) |arm| {
        for (arm.unmodelled) |key| {
            var source = json.Writer.init(&in);
            try source.slice("{\"content\":[{\"type\":\"");
            try source.slice(arm.tag);
            try source.slice("\",");
            try source.slice(arm.modelled);
            try source.slice(",\"");
            try source.slice(key);
            try source.slice("\":\"v\"}]}");

            const result = try decodeToolCallResult(
                source.written(),
                blocks[0..],
                verbatim[0..],
                &scratch,
            );
            const carried: []const VerbatimMember = switch (result.content[0]) {
                .text => |value| value.verbatim,
                .image => |value| value.verbatim,
                .audio => |value| value.verbatim,
                .resource_link => |value| value.verbatim,
                .resource => |value| value.verbatim,
            };
            try testing.expectEqual(@as(usize, 1), carried.len);
            try testing.expectEqualStrings(key, carried[0].key);
            try testing.expectEqualStrings("\"v\"", carried[0].value);

            // The inverse is the half a field comparison cannot see, and it is
            // the half that was broken: the encoder wrote a document with the
            // member gone while the decoded fields still compared equal.
            var writer = json.Writer.init(&out);
            try encodeToolCallResult(result, &writer);
            try testing.expectEqualStrings(source.written(), writer.written());
        }
    }

    // A `resource` lexeme is the sharpest of them, because a peer that mis-tags
    // an embedded resource used to lose the whole body and the decode reported
    // success. It is carried whole, escapes and all, and the arm that does model
    // it still reads it as a `ResourceContents`.
    var source = json.Writer.init(&in);
    try source.slice("{\"content\":[{\"type\":\"resource_link\",\"uri\":\"file:///a\",\"name\":\"a\"," ++
        "\"resource\":{\"uri\":\"file:///b\",\"text\":\"b\\no\",\"mimeType\":\"text/plain\"," ++
        "\"size\":7}},{\"type\":\"resource\",\"resource\":{\"uri\":\"file:///c\"," ++
        "\"text\":\"c\\no\"}}]}");
    const result = try decodeToolCallResult(source.written(), blocks[0..], verbatim[0..], &scratch);
    const carried: []const VerbatimMember = switch (result.content[0]) {
        .text => |value| value.verbatim,
        .image => |value| value.verbatim,
        .audio => |value| value.verbatim,
        .resource_link => |value| value.verbatim,
        .resource => |value| value.verbatim,
    };
    try testing.expectEqual(@as(usize, 1), carried.len);
    try testing.expectEqualStrings("resource", carried[0].key);
    try testing.expectEqualStrings(
        \\{"uri":"file:///b","text":"b\no","mimeType":"text/plain","size":7}
    , carried[0].value);
    try testing.expectEqualStrings("c\no", result.content[1].resource.resource.text.text);
    var writer = json.Writer.init(&out);
    try encodeToolCallResult(result, &writer);
    try testing.expectEqualStrings(source.written(), writer.written());
}

test "a repeated member resolves first-wins in every decoder that names one" {
    var scratch: [512]u8 = undefined;
    var blocks: [4]ContentBlock = undefined;
    var tools: [4]Tool = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // One rule in one place. `claimFirst` is what every walk below reaches for,
    // so a body that names a member twice has one answer whichever of these
    // decoders reads it, and a second occurrence can neither rewrite the first
    // nor refuse a body the first occurrence already settled.

    // The pair the divergence showed in: one public function said the answer was
    // interim and another read the same bytes as final, and a duplicate member
    // decided which.
    const disagreeing =
        \\{"resultType":"complete","resultType":"input_required","content":[]}
    ;
    try testing.expectEqualStrings(
        result_type_value.complete,
        (try classifyResult(disagreeing, &scratch)).value.?,
    );
    try testing.expectEqualStrings(
        result_type_value.complete,
        (try decodeResultType(disagreeing, &scratch)).value.?,
    );
    try testing.expectEqualStrings(
        result_type_value.complete,
        (try decodeToolCallResult(disagreeing, blocks[0..], verbatim[0..], &scratch))
            .result_type.value.?,
    );

    // `decodeCacheable` and `CacheableReader` read the same two members and had
    // to agree: the first `ttlMs` is the one the result describes.
    try testing.expectEqual(
        @as(u64, 60000),
        (try decodeCacheable(
            \\{"ttlMs":60000,"cacheScope":"public","ttlMs":5000}
        , &scratch)).ttl_ms,
    );
    // ... and a repeat the parser refuses cannot refuse the body with it. The
    // fault these two reported was blamed on a freshness hint the peer did not
    // lead with, which is the wrong member to blame.
    try testing.expectEqual(
        @as(u64, 60000),
        (try decodeCacheable(
            \\{"ttlMs":60000,"cacheScope":"public","ttlMs":-1}
        , &scratch)).ttl_ms,
    );
    try testing.expectEqual(
        CacheScope.public,
        (try decodeCacheable(
            \\{"ttlMs":60000,"cacheScope":"public","cacheScope":"forever"}
        , &scratch)).cache_scope,
    );
    const cached = try decodeToolListResult(
        \\{"ttlMs":60000,"cacheScope":"public","tools":[],"ttlMs":-1}
    , tools[0..], verbatim[0..], &scratch);
    try testing.expectEqual(@as(u64, 60000), cached.cacheable.ttl_ms);
    const rescoped = try decodeToolListResult(
        \\{"ttlMs":60000,"cacheScope":"public","tools":[],"cacheScope":"forever"}
    , tools[0..], verbatim[0..], &scratch);
    try testing.expectEqual(CacheScope.public, rescoped.cacheable.cache_scope);

    // The interim result has to be exactly `input_required`, and the check is
    // part of reading the member rather than a verdict on the body: a peer
    // that names it twice is answered by the first name. The store is the
    // caller's here as in every other result decoder.
    const interim = try decodeInputRequiredResult(
        \\{"resultType":"input_required","resultType":"complete","requestState":"s"}
    , verbatim[0..], &scratch);
    try testing.expectEqualStrings(result_type_value.input_required, interim.result_type.value.?);
    try testing.expectEqualStrings("s", interim.request_state.?);

    // A repeat that is not even the member's own JSON type is a repeat and
    // nothing more: the first occurrence settled the arm, so the second is
    // consumed and not read as a tag, a string, or a number.
    const mistyped = try decodeToolCallResult(
        \\{"content":[{"type":"text","type":1,"text":"t"}],"resultType":"complete","resultType":1}
    , blocks[0..], verbatim[0..], &scratch);
    try testing.expectEqualStrings("t", mistyped.content[0].text.text);
    try testing.expectEqualStrings(result_type_value.complete, mistyped.result_type.value.?);
}

test "a page carries a caching member it cannot read as a pair" {
    var scratch: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var verbatim: [16]VerbatimMember = undefined;

    // `ttlMs` and `cacheScope` are required together, so a document carrying
    // one of them is not a cacheable result: it is a member no shape here
    // names, on a result this reader is handed as readily as a cacheable
    // one. Demanding both as soon as either is present refuses the whole page
    // over a member that has somewhere to go.
    const half = try decodePaginatedResult(
        \\{"resultType":"complete","content":[],"ttlMs":5000}
    , verbatim[0..], &scratch);
    try testing.expectEqual(@as(?Cacheable, null), half.cacheable);
    try testing.expectEqual(@as(usize, 2), half.verbatim.len);
    try testing.expectEqualStrings("content", half.verbatim[0].key);
    try testing.expectEqualStrings("ttlMs", half.verbatim[1].key);
    try testing.expectEqualStrings("5000", half.verbatim[1].value);
    var writer = json.Writer.init(&out);
    try encodePaginatedResult(half, &writer);
    try testing.expectEqualStrings(
        \\{"resultType":"complete","content":[],"ttlMs":5000}
    , writer.written());

    // The other member alone, and the pair that does build.
    const other = try decodePaginatedResult(
        \\{"cacheScope":"public"}
    , verbatim[0..], &scratch);
    try testing.expectEqual(@as(?Cacheable, null), other.cacheable);
    try testing.expectEqual(@as(usize, 1), other.verbatim.len);
    writer = json.Writer.init(&out);
    try encodePaginatedResult(other, &writer);
    try testing.expectEqualStrings(
        \\{"cacheScope":"public"}
    , writer.written());

    const both = try decodePaginatedResult(
        \\{"ttlMs":1000,"cacheScope":"public"}
    , verbatim[0..], &scratch);
    try testing.expectEqual(@as(u64, 1000), both.cacheable.?.ttl_ms);
    try testing.expectEqual(CacheScope.public, both.cacheable.?.cache_scope);
    try testing.expectEqual(@as(usize, 0), both.verbatim.len);
}

test "an encoder refuses a spliced value that is not one whole value" {
    var out: [256]u8 = undefined;
    var writer = json.Writer.init(&out);

    // Both open like a value and neither is one, so a document carrying
    // either decodes cleanly and does not decode back. The check is the whole
    // lexeme and not its first byte.
    const trailing = [_]Tool{.{ .name = "t", .input_schema = "{}x" }};
    try testing.expectError(error.InvalidField, encodeToolListResult(.{
        .cacheable = .{ .ttl_ms = 0, .cache_scope = .public },
        .tools = trailing[0..],
    }, &writer));
    try testing.expectEqualStrings("", writer.written());

    const partial = [_]Tool{.{ .name = "t", .input_schema = "tru" }};
    writer = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodeToolListResult(.{
        .cacheable = .{ .ttl_ms = 0, .cache_scope = .public },
        .tools = partial[0..],
    }, &writer));
    try testing.expectEqualStrings("", writer.written());

    // The same rule for a carried member, and for the whole document rather
    // than one member of it.
    const no_blocks: [0]ContentBlock = .{};
    const members = [_]VerbatimMember{.{ .key = "k", .value = "1,2" }};
    writer = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodeToolCallResult(.{
        .content = no_blocks[0..],
        .verbatim = members[0..],
    }, &writer));
    try testing.expectEqualStrings("", writer.written());

    // A lexeme that came from a decoder is exactly one value, trailing
    // whitespace aside, so the check does not refuse what the reader accepts.
    writer = json.Writer.init(&out);
    try encodeToolCallResult(.{ .structured_content = "{} " }, &writer);
    try testing.expectEqualStrings(
        \\{"content":[],"structuredContent":{} }
    , writer.written());
}

test "inputRequired refuses a request map that is not one whole JSON object" {
    var scratch: [256]u8 = undefined;
    var verbatim: [8]VerbatimMember = undefined;
    var out: [512]u8 = undefined;

    // Section 4.7 types `inputRequests` as a map keyed by the server-assigned
    // ids, and this is the one encoder in the module that takes a value the
    // caller built rather than one a decoder handed back. Each of these used to
    // be spliced as written, and each produced a body this library's own reader
    // refuses — after the peer had already been sent it, and with no error
    // anywhere on the sending side.
    const refused = [_][]const u8{
        "",
        "e1",
        "42",
        "null",
        "[]",
        "{} extra",
        "{\"e1\":}",
        "{\"e1\":{\"method\":\"elicitation/create\"}",
        "{\"e1\" {\"method\":\"elicitation/create\"}}",
    };
    for (refused) |requests| {
        @memset(&out, 'x');
        try testing.expectError(
            error.InvalidField,
            inputRequired("tools/call", requests, "st", &out),
        );
        // The refusal lands before the first byte, so a caller that fixed the
        // value and called again is not reading a body with a hole in it.
        try testing.expectEqual(@as(u8, 'x'), out[0]);
    }

    // The state is quoted with `json.Writer.string`, which escapes every byte
    // JSON names and passes every other one through without checking it. A
    // stray byte used to become a literal in the body, so the sending side
    // reported the write as done and this library's own `json.Reader.string`
    // refused the same bytes with `error.InvalidUtf8` on the far side of the
    // wire. It is `InvalidField` rather than `BufferTooSmall`: the value is not
    // text this may quote, which is a different fault from a buffer too small
    // to hold it.
    const stray: [3]u8 = .{ 0xC3, 0x28, 'x' };
    @memset(&out, 'x');
    try testing.expectError(
        error.InvalidField,
        inputRequired("tools/call", "{\"e1\":{}}", &stray, &out),
    );
    try testing.expectEqual(@as(u8, 'x'), out[0]);

    // The valid half of the same check: multi-byte UTF-8 that is well formed is
    // passed through byte for byte and comes back as the same characters,
    // because the preflight is a validation rather than a normalisation.
    const body_utf8 = try inputRequired("tools/call", "{\"e1\":{}}", "Zürich", &out);
    const decoded_utf8 = try decodeInputRequiredResult(body_utf8, verbatim[0..], &scratch);
    try testing.expectEqualStrings("Zürich", decoded_utf8.request_state.?);

    // The method is still refused before the value is looked at, so a caller
    // that named a method PROTOCOLS.md 4.7 does not allow learns that from the
    // one error it already handles rather than from a second one.
    @memset(&out, 'x');
    try testing.expectError(
        error.InputRequiredUnexpected,
        inputRequired("tools/list", "[]", "st", &out),
    );
    try testing.expectEqual(@as(u8, 'x'), out[0]);

    // A whole object is accepted whatever its names are spelled with and
    // whatever whitespace sits inside it, so the check asks for the shape and
    // not for a spelling the peer was free to choose. It needs no escape
    // scratch to ask either, which is why a name written with a `\u` escape is
    // not refused here.
    const built = "{ \"e\\u0031\" : { \"method\" : \"elicitation/create\" } }";
    const body = try inputRequired("prompts/get", built, "a\"b\\c", &out);
    try testing.expectEqualStrings(
        "{\"resultType\":\"input_required\"," ++
            "\"inputRequests\":" ++ built ++
            ",\"requestState\":\"a\\\"b\\\\c\"}",
        body,
    );

    // ... and what it writes is a body the decoders read back with every wire
    // value intact, which is the half the refused values above would have
    // broken on the receiving side.
    const decoded = try decodeInputRequiredResult(body, verbatim[0..], &scratch);
    try testing.expectEqualStrings(built, decoded.input_requests.?);
    try testing.expectEqualStrings("a\"b\\c", decoded.request_state.?);
    try testing.expectEqual(@as(usize, 0), decoded.verbatim.len);
    try testing.expect(!decoded.result_type.isComplete());
    try checkResult((try lookupMethod(.current, "prompts/get")), body, &scratch);

    var again: [512]u8 = undefined;
    var writer = json.Writer.init(&again);
    try encodeInputRequiredResult(decoded, &writer);
    try testing.expectEqualStrings(body, writer.written());
}

test "opaque MCP values spend their enclosing containers" {
    const map = "{\"1\":" ++ "[" ** (json.max_depth - 2) ++ "0" ++ "]" ** (json.max_depth - 2) ++ "}";
    const deep_map = "{\"1\":" ++ "[" ** (json.max_depth - 1) ++ "0" ++ "]" ** (json.max_depth - 1) ++ "}";
    const schema = "{\"k\":" ++ "[" ** (json.max_depth - 4) ++ "0" ++ "]" ** (json.max_depth - 4) ++ "}";
    const deep_schema = "{\"k\":" ++ "[" ** (json.max_depth - 3) ++ "0" ++ "]" ** (json.max_depth - 3) ++ "}";
    var out: [1024]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var verbatim: [8]VerbatimMember = undefined;
    const interim = try inputRequired("tools/call", map, "state", &out);
    const decoded_interim = try decodeInputRequiredResult(interim, &verbatim, &scratch);
    try testing.expectEqualStrings(map, decoded_interim.input_requests.?);
    @memset(&out, 0xa5);
    try testing.expectError(error.InvalidField, inputRequired("tools/call", deep_map, "state", &out));
    try testing.expectEqualSlices(u8, &([_]u8{0xa5} ** out.len), &out);

    const tools = [_]Tool{.{ .name = "t", .input_schema = schema }};
    var writer = json.Writer.init(&out);
    try encodeToolListResult(.{
        .cacheable = .{ .ttl_ms = 0, .cache_scope = .public },
        .tools = &tools,
    }, &writer);
    var decoded_tools: [1]Tool = undefined;
    const decoded_page = try decodeToolListResult(writer.written(), &decoded_tools, &verbatim, &scratch);
    try testing.expectEqualStrings(schema, decoded_page.tools[0].input_schema);
    const deep_tools = [_]Tool{.{ .name = "t", .input_schema = deep_schema }};
    @memset(&out, 0xa5);
    writer = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodeToolListResult(.{
        .cacheable = .{ .ttl_ms = 0, .cache_scope = .public },
        .tools = &deep_tools,
    }, &writer));
    try testing.expectEqualSlices(u8, &([_]u8{0xa5} ** out.len), &out);
}
