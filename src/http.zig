//! The MCP Streamable HTTP transport, `2026-07-28`.
//!
//! PROTOCOLS.md sections 4.1, 4.2 and 9 govern this file. It is the second of
//! the two transports; the first is stdio, which is `framing.zig` over a pipe.
//!
//! ## `std.http` is enough, and this file uses it
//!
//! The question this layer has to answer before it can be written is whether
//! `std.http` can express a reply that is *either* a single JSON body *or* a
//! server-sent event stream. It can, and the source says so:
//!
//!   - `std.http.Server.Request.respond` writes a whole response with a
//!     `content-length`. That is the single-JSON shape.
//!   - `std.http.Server.Request.respondStreaming` returns an `http.BodyWriter`
//!     over `transfer-encoding: chunked`. A `BodyWriter` is a `std.Io.Writer`,
//!     so writing `data: {...}\n\n` into it and flushing is the event-stream
//!     shape with nothing in the middle. `http` has no notion of SSE and does
//!     not need one: SSE is a line format over a chunked body.
//!   - `std.http.Client.Response.reader` hands back a `*std.Io.Reader` for the
//!     body, so a client reads events one at a time off a chunked reply rather
//!     than waiting for the whole of a stream that never ends.
//!
//! Nothing here re-implements HTTP, and the house rule of zero dependencies
//! holds. `std.http.Client.fetch` is deliberately not used: it drains the
//! whole body into a writer, and a reply that is still open is the case that
//! matters.
//!
//! ## There is no session
//!
//! `Mcp-Session-Id` and `Last-Event-ID` were removed at `2026-07-28`
//! (PROTOCOLS.md 4.2). This transport therefore mints no identifier, echoes
//! none, and keeps no state between requests on a connection.
//! [`Headers.removed`] records which of the two a peer sent. A request that
//! carried `Mcp-Session-Id` is refused, because PROTOCOLS.md 4.2 says a peer
//! that sends it is not speaking this revision. The HTTP+SSE transport,
//! deprecated in `2025-03-26`, is not implemented at all (section 9).
//!
//! ## What is decided here rather than in the caller
//!
//! The header rules are the substance of this layer, so they are enforced
//! here instead of being left to whoever writes the server: the revision
//! header, `Mcp-Method` and `Mcp-Name` checked against the body,
//! `Content-Type`, `Accept`, a repeated MCP-defined header, and
//! `Mcp-Session-Id`, which this revision removed and which therefore refuses
//! the request. A gateway that routes on `Mcp-Method` without checking it
//! against the body is the failure this file exists to prevent.
//!
//! The derived `Mcp-Param-{Name}` family is carried rather than enforced. Only
//! the tool's own `inputSchema` says what a value in `arguments` must equal,
//! and that is the caller's to say, so the headers arrive in [`Post.params`]
//! and are compared one at a time through [`Post.checkParam`], which is
//! [`mcp.checkParamBinding`] and nothing else.
//!
//! Buffers are the caller's throughout, as in `conn.zig`. Nothing here
//! allocates, and a body a peer sends is read into a buffer the caller sized.

const std = @import("std");
const conn = @import("conn.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const mcp = @import("mcp.zig");
const root = @import("root.zig");

const Io = std.Io;
const http = std.http;

const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

/// What this layer reports.
///
/// The transport members are separate from the wire members, for the reason
/// `conn.zig` gives: a caller that folds them together cannot tell a peer
/// speaking a protocol this library does not implement from a socket that
/// went away.
pub const Error = error{
    /// The request line, the header block, or the body is not something this
    /// transport accepts. The specification pairs a malformed request with
    /// `400 Bad Request`.
    MalformedRequest,
    /// An MCP-defined header arrived more than once, which includes one
    /// `Mcp-Param-{Name}` annotation sent twice.
    ///
    /// HTTP permits a repeated header and the specification is silent, but two
    /// values for a header that is checked against the body leaves the check
    /// ambiguous: a gateway and a library can disagree about which one the
    /// body was compared to, and they would then route and validate one
    /// request two different ways. A derived header is checked against
    /// `arguments` the same way, one annotation at a time, by
    /// [`Post.checkParam`].
    DuplicateHeader,
    /// The peer is not speaking a revision this library decodes: it named one
    /// this library does not know in `MCP-Protocol-Version`, or it sent
    /// `Mcp-Session-Id`, which PROTOCOLS.md 4.2 says a peer sends only when it
    /// speaks a revision older than `2026-07-28`. The specification pairs
    /// both with `-32022` and `400 Bad Request`.
    UnsupportedVersion,
    /// A header the specification requires is absent.
    MissingHeader,
    /// A header value disagrees with the body value it duplicates, or a value
    /// is not even decodable. Paired with `-32020` and `400 Bad Request`.
    HeaderMismatch,
    /// A peer sent `x-mcp-header`, which section 4.2 states is a JSON Schema
    /// keyword and not a header a client sends.
    NotAHeader,
    /// The HTTP method is not one this transport serves. `2026-07-28` keeps
    /// only POST, and the specification says `405` for GET and DELETE.
    MethodNotAllowed,
    /// `Content-Type` is not `application/json`.
    UnsupportedMediaType,
    /// The `Accept` header names neither response type this transport can
    /// return, so no reply to this request would be legal.
    NotAcceptable,
    /// The body did not fit the caller's buffer.
    BodyTooLarge,
    /// A handler declined to answer a request.
    ///
    /// Over stdio a request with no answer is simply unanswered. Over HTTP the
    /// connection has to be given something, and only the caller knows which
    /// status fits a method it has no handler for, so this is reported rather
    /// than answered.
    NoAnswer,
    /// The peer answered with a redirect.
    ///
    /// A POST whose body has already been sent cannot be replayed, and the
    /// specification names no way to replay one, so this is reported rather
    /// than followed.
    Redirected,
    /// The endpoint URI names a scheme this transport cannot speak. The URI is
    /// the caller's own, so this is a configuration fault rather than
    /// something that happened on the wire.
    UnsupportedUri,
    /// The peer hung up, or the socket failed.
    Transport,
    /// The reply carried no message answering the call.
    NoResponse,
} || DecodeError || conn.Error;

// --- Response media types -------------------------------------------------------

/// The two response types a Streamable HTTP reply may have.
///
/// Section 4.2 requires the server to return one of them and the client to
/// support both, so this is an enum of two rather than a set of strings.
pub const MediaType = enum {
    json,
    event_stream,
};

/// The `Accept` value a client must send on every POST.
///
/// Section 4.2: the client "MUST include an `Accept` header listing both
/// `application/json` and `text/event-stream` as supported content types".
pub const accept_value = mcp.uri_and_media.json_media_type ++
    ", " ++ mcp.uri_and_media.event_stream_media_type;

/// The media type a `Content-Type` or `Accept` value names.
///
/// Parameters after the type are ignored, so `application/json; charset=utf-8`
/// is the type it names. A value that names neither of the two is null rather
/// than a guess.
pub fn mediaType(value: []const u8) ?MediaType {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const text = std.mem.trim(u8, value[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(text, mcp.uri_and_media.json_media_type)) return .json;
    if (std.ascii.eqlIgnoreCase(text, mcp.uri_and_media.event_stream_media_type)) {
        return .event_stream;
    }
    return null;
}

/// Which response types a POST's `Accept` header allows.
pub const Accept = struct {
    json: bool = true,
    event_stream: bool = true,
    /// Whether the header arrived at all. It does not change what is allowed:
    /// HTTP reads a request with no `Accept` as one that takes any media type,
    /// and a server that refused one would break every client the
    /// specification does not require the header of.
    present: bool = false,

    /// Whether a reply of this type is one the client asked for.
    pub fn allows(self: Accept, kind: MediaType) bool {
        return switch (kind) {
            .json => self.json,
            .event_stream => self.event_stream,
        };
    }

    /// Whether any reply is legal, which is the condition for accepting the
    /// request at all.
    pub fn isAcceptable(self: Accept) bool {
        return self.json or self.event_stream;
    }
};

/// Read the response types an `Accept` header allows.
///
/// A wildcard counts for the types it covers, an entry whose `q` parameter is
/// zero counts for nothing, and an unparsable entry is skipped rather than
/// refused: the list is advisory and this is the layer that decides whether
/// anything is left.
pub fn parseAccept(value: ?[]const u8) Accept {
    const text = value orelse return .{};
    if (std.mem.trim(u8, text, " \t").len == 0) return .{};
    var accept: Accept = .{ .present = true, .json = false, .event_stream = false };
    var entries = std.mem.splitSequence(u8, text, ",");
    while (entries.next()) |entry| {
        const media = std.mem.trim(u8, entry, " \t");
        // The parameters are read before the type, because one of them decides
        // whether the entry counts at all. `mediaType` drops them, so an entry
        // that arrived as `application/json;q=0` would otherwise be read as a
        // request for the one type this transport answers most.
        const stop = std.mem.indexOfScalar(u8, media, ';') orelse media.len;
        if (refusedByQuality(media[stop..])) continue;
        const bare = media[0..stop];
        const slash = std.mem.indexOfScalar(u8, bare, '/') orelse continue;
        const major = bare[0..slash];
        const minor = bare[slash + 1 ..];
        const any_major = std.mem.eql(u8, major, "*");
        if (std.mem.eql(u8, minor, "*")) {
            if (any_major) {
                accept.json = true;
                accept.event_stream = true;
            } else if (std.ascii.eqlIgnoreCase(major, "application")) {
                accept.json = true;
            } else if (std.ascii.eqlIgnoreCase(major, "text")) {
                accept.event_stream = true;
            }
            continue;
        }
        if (mediaType(bare)) |kind| switch (kind) {
            .json => accept.json = true,
            .event_stream => accept.event_stream = true,
        };
    }
    return accept;
}

/// Whether an entry's own parameters refuse it, which `q=0` and nothing else
/// does.
///
/// RFC 9110 gives a quality of zero exactly one meaning: the type is not
/// acceptable. `q=0.0` and `q=0.000` are that same refusal written longer, so
/// the value is read as a number rather than compared as text. A `q` that is
/// not a number is not a quality, so it refuses nothing.
fn refusedByQuality(params: []const u8) bool {
    var fields = std.mem.splitSequence(u8, params, ";");
    while (fields.next()) |field| {
        const one = std.mem.trim(u8, field, " \t");
        const equals = std.mem.indexOfScalar(u8, one, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, one[0..equals], " \t"), "q")) continue;
        const text = std.mem.trim(u8, one[equals + 1 ..], " \t");
        const quality = std.fmt.parseFloat(f64, text) catch continue;
        return quality == 0;
    }
    return false;
}

// --- 4.2 HTTP headers -----------------------------------------------------------

/// One derived `Mcp-Param-{Name}` header, as it arrived.
///
/// Built by [`mcp.bindParamHeader`] on the sending side and checked by
/// [`Post.checkParam`] on the receiving side, so the derived-header rule has
/// exactly one implementation in this library.
pub const ParamHeader = struct {
    /// The `{Name}` part, borrowed from the header block.
    annotation: []const u8,
    /// The value, with the base64 sentinel already decoded.
    value: []const u8,
};

/// The MCP headers on one request, as this transport reads them.
///
/// Slices borrow the header block or `readHeaders`' scratch, so both must
/// outlive the `Headers` and everything built from it.
pub const Headers = struct {
    protocol_version: ?[]const u8 = null,
    method: ?[]const u8 = null,
    name: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// `Origin` is not MCP's, but section 4.2 requires a server to validate
    /// it, so it is carried through rather than dropped.
    origin: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    /// A header removed at `2026-07-28` arrived, and which of the two it was.
    ///
    /// Recorded because a caller can then see that a peer sent a header this
    /// revision has no use for. It is never echoed, and this transport mints
    /// no identifier. `checkPost` refuses a request that carried
    /// `Mcp-Session-Id` and serves one that carried `Last-Event-ID`, because
    /// PROTOCOLS.md 4.2 says only of the first that a peer sending it is not
    /// speaking this revision.
    removed: ?mcp.HeaderKind = null,
    /// The derived parameter headers, in the order they arrived.
    params: []const ParamHeader = &.{},
    /// The value of a header named `x-mcp-header`, which is the JSON Schema
    /// keyword rather than a header. Present only so a caller can tell the
    /// peer apart; [`checkPost`] rejects it.
    schema_keyword_sent: ?[]const u8 = null,
};

/// Read the MCP headers out of a raw header block.
///
/// `head` is what `std.http` hands back, so the request line is already in it
/// and this only walks the fields. Matching is by [`mcp.headerKind`], which
/// is case-insensitive: section 4.2 spells the version header all-caps and
/// every other one title-case, and both spellings are required, so a table
/// keyed on either casing would be wrong.
///
/// `params` is the caller's array of derived headers, sized to the most the
/// peer may send, and `scratch` backs the base64 decoding. A value that is
/// not sentinel-encoded borrows the header block, so an all-ASCII request
/// needs no scratch at all.
pub fn readHeaders(head: []const u8, params: []ParamHeader, scratch: []u8) Error!Headers {
    // `http.HeaderIterator` unwraps its finds, so a block this function did
    // not check would be a panic rather than an error. Every byte here is
    // attacker-controlled, so the shape is verified before it is walked.
    if (!std.mem.endsWith(u8, head, "\r\n\r\n")) return error.MalformedRequest;

    var headers: Headers = .{};
    var count: usize = 0;
    var cursor = Cursor{ .buffer = scratch };

    var iterator = http.HeaderIterator.init(head);
    while (iterator.next()) |field| {
        switch (mcp.headerKind(field.name)) {
            .protocol_version => {
                if (headers.protocol_version != null) return error.DuplicateHeader;
                headers.protocol_version = try decodeValue(field.value, &cursor);
            },
            .method => {
                if (headers.method != null) return error.DuplicateHeader;
                headers.method = try decodeValue(field.value, &cursor);
            },
            .name => {
                if (headers.name != null) return error.DuplicateHeader;
                headers.name = try decodeValue(field.value, &cursor);
            },
            .param => {
                const annotation = field.name[mcp.param_header_prefix.len..];
                // A derived header is checked against `arguments` by
                // `Post.checkParam`, so two of them for one annotation leave
                // that check as ambiguous as a repeated `Mcp-Method`, and a
                // header name is case-insensitive on the wire.
                for (params[0..count]) |seen| {
                    if (std.ascii.eqlIgnoreCase(seen.annotation, annotation)) {
                        return error.DuplicateHeader;
                    }
                }
                if (count == params.len) return error.BufferTooSmall;
                params[count] = .{
                    .annotation = annotation,
                    .value = try decodeValue(field.value, &cursor),
                };
                count += 1;
            },
            .accept => headers.accept = field.value,
            .content_type => headers.content_type = field.value,
            .origin => headers.origin = field.value,
            .authorization => headers.authorization = field.value,
            .session_id_removed, .last_event_id_removed => {
                // Never read into a field and never echoed. Recorded so a
                // caller can see that a peer sent a header this revision
                // removed, and so `checkPost` can refuse the request.
                if (headers.removed == null) headers.removed = mcp.headerKind(field.name);
            },
            .schema_keyword => headers.schema_keyword_sent = field.value,
            // `www_authenticate` and every other header belong to whoever owns
            // the endpoint, and the body is where the MCP rules live.
            .other, .www_authenticate => {},
        }
    }
    headers.params = params[0..count];
    return headers;
}

/// Hands out non-overlapping regions of one caller-owned buffer.
///
/// Decoding several sentinel-encoded values into the same buffer without one
/// would leave every value but the last pointing at the last value's bytes.
const Cursor = struct {
    buffer: []u8,
    used: usize = 0,

    fn rest(self: *const Cursor) []u8 {
        return self.buffer[self.used..];
    }
};

fn decodeValue(value: []const u8, cursor: *Cursor) Error![]const u8 {
    // A value with no sentinel is returned as it arrived, so an all-ASCII
    // request decodes no bytes at all.
    if (!mcp.isSentinelEncoded(value)) return value;
    const decoded = try mcp.decodeHeaderValue(value, cursor.rest());
    cursor.used += decoded.len;
    return decoded;
}

/// The revision a POST declares, before its body is read.
///
/// Separate from [`checkPost`] on purpose: it costs nothing, so a server can
/// refuse a request this library does not decode without first reading an
/// arbitrary body off the socket.
pub fn revisionOf(headers: Headers) Error!mcp.Revision {
    const text = headers.protocol_version orelse return error.MissingHeader;
    return mcp.Revision.fromString(text) orelse error.UnsupportedVersion;
}

// --- The accepted request ------------------------------------------------------

/// A POST that passed every header rule section 4.2 states.
///
/// Nothing here is derived from a guess. The method is the one both the header
/// and the body named, the name is the body's own `params.name` or
/// `params.uri` once the header was shown to agree with it, and the
/// parameter headers are compared against `arguments` by the caller through
/// [`Post.checkParam`], which is [`mcp.checkParamBinding`] and nothing else.
///
/// Nothing here is copied out of the buffers the request was read into, so
/// every slice borrows. `body` is the buffer it was read into, `origin` the
/// header block, and `params` the caller's array, whose entries borrow the
/// header block or the scratch [`readHeaders`] was given. `method` borrows
/// that scratch as well when the peer sent the value base64-wrapped, and
/// `name` borrows the decode scratch when the body's own string had to be
/// unescaped. A `Post` from [`Server.receive`] is therefore valid only until
/// the next `receive` on the same server, because every buffer it borrows is
/// the server's own.
pub const Post = struct {
    /// The revision `MCP-Protocol-Version` named.
    revision: mcp.Revision,
    /// The JSON-RPC method. Section 4.2 says header *names* compare
    /// case-insensitively and header *values* case-sensitively, so this is
    /// compared exactly.
    method: []const u8,
    /// The name the request addresses, or null for a method that names
    /// nothing. This is the body's own value: the header was only accepted
    /// after it was shown to equal it.
    name: ?[]const u8,
    /// Whether the body is a JSON-RPC notification, which the specification
    /// answers with `202 Accepted` and no body.
    notification: bool,
    /// The JSON-RPC message, as it arrived.
    body: []const u8,
    /// The derived `Mcp-Param-{Name}` headers, decoded.
    params: []const ParamHeader,
    /// Which reply types this request permits.
    accept: Accept,
    /// The `Origin` header, for the DNS-rebinding check a server must do and
    /// this library does not make on its behalf.
    origin: ?[]const u8,
    /// Whether an `Authorization` header arrived. The value is not retained:
    /// section 4.2 requires one on every request, and a credential does not
    /// belong in a struct a caller might log.
    has_authorization: bool,

    /// The value the derived header for `annotation` carries, or null.
    ///
    /// Matched case-insensitively, because `x-mcp-header` values must be
    /// unique case-insensitively within one `inputSchema` and a header name
    /// is case-insensitive on the wire.
    pub fn param(self: Post, annotation: []const u8) ?[]const u8 {
        for (self.params) |header| {
            if (std.ascii.eqlIgnoreCase(header.annotation, annotation)) return header.value;
        }
        return null;
    }

    /// Check one derived header against the `arguments` value it duplicates.
    ///
    /// The verdict is [`mcp.ParamVerdict`], unchanged: this is the rule from
    /// section 4.2 and it is not restated here. `body_value` is the value the
    /// tool's own `inputSchema` declares, which only the tool's dispatcher
    /// knows.
    pub fn checkParam(
        self: Post,
        annotation: []const u8,
        body_value: ?mcp.ParamValue,
        converted: []u8,
        scratch: []u8,
    ) DecodeError!mcp.ParamVerdict {
        return mcp.checkParamBinding(
            self.param(annotation),
            body_value,
            converted,
            scratch,
        );
    }
};

/// Whether a method addresses one named entity, and so requires `Mcp-Name`.
///
/// Section 4.2 requires `Mcp-Name` for `tools/call`, `resources/read` and
/// `prompts/get` and names no other method.
pub fn requiresName(method: []const u8) bool {
    return std.mem.eql(u8, method, "tools/call") or
        std.mem.eql(u8, method, "resources/read") or
        std.mem.eql(u8, method, "prompts/get");
}

/// Validate a POST's headers against its body.
///
/// The order is the specification's: the version first, because a request
/// this library does not decode has no other rule worth applying; then the
/// media types, because a body that is not JSON cannot be checked against
/// anything; then the headers that duplicate body values, each of which
/// either agrees or is `-32020` and `400 Bad Request`.
///
/// `scratch` backs the body decode, and the [`Post`] returned may borrow it,
/// so [`Post`] says which buffer each field lives in.
pub fn checkPost(headers: Headers, body: []const u8, scratch: []u8) Error!Post {
    // `x-mcp-header` is a JSON Schema keyword. A peer that sent it as a
    // header is either confused about which side of the wire it is on or
    // echoing a name back at us, and neither is a request to serve.
    if (headers.schema_keyword_sent != null) return error.NotAHeader;

    const revision = try revisionOf(headers);

    // PROTOCOLS.md 4.2: `Mcp-Session-Id` was removed at `2026-07-28` and "a
    // peer that sends it is not speaking this revision", so the request is
    // refused here. The compatibility matrix in the normative source instead
    // asks for legacy handling — "an `Mcp-Session-Id` header on a request:
    // ignore it" — and PROTOCOLS.md wins where the two disagree, so the
    // conflict is recorded here rather than resolved silently. A peer that
    // sent `Last-Event-ID` is served, because PROTOCOLS.md says no such thing
    // of that header.
    if (headers.removed) |removed| {
        if (removed == .session_id_removed) return error.UnsupportedVersion;
    }

    if (mediaType(headers.content_type orelse return error.MissingHeader) != .json) {
        return error.UnsupportedMediaType;
    }
    const accept = parseAccept(headers.accept);
    if (!accept.isAcceptable()) return error.NotAcceptable;

    const message = try jsonrpc.decode(body, scratch);
    // A response has no method to route on and no answer to give, so a body
    // that is one is not a request this endpoint can serve.
    if (message.kind == .response) return error.MalformedRequest;
    const declared = message.method orelse return error.MalformedRequest;

    // The method is checked rather than read. `Mcp-Method` exists so a
    // gateway can route without the body, and a header a gateway can route
    // on that the body contradicts is the request-splitting case the
    // specification makes a MUST-reject.
    const method = headers.method orelse return error.MissingHeader;
    if (!std.mem.eql(u8, method, declared.text)) return error.HeaderMismatch;

    var name: ?[]const u8 = null;
    if (requiresName(method)) {
        if (headers.name == null) return error.MissingHeader;
        const from_body = nameFromParams(message.params, scratch) catch
            return error.MalformedRequest;
        const claimed = from_body orelse return error.HeaderMismatch;
        if (!std.mem.eql(u8, headers.name.?, claimed)) return error.HeaderMismatch;
        name = claimed;
    }

    return .{
        .revision = revision,
        .method = method,
        .name = name,
        .notification = message.kind == .notification,
        .body = body,
        .params = headers.params,
        .accept = accept,
        .origin = headers.origin,
        .has_authorization = headers.authorization != null,
    };
}

/// The `name` or `uri` an `Mcp-Name` header must agree with.
///
/// Section 4.2 names `params.name` or `params.uri` as the source, and the
/// schema of the three methods that require the header gives one or the
/// other. The `params` member is passed in as the raw JSON the base layer
/// already isolated, so this reads one member of it rather than re-deriving
/// where it begins and ends.
fn nameFromParams(params: jsonrpc.Params, scratch: []u8) DecodeError!?[]const u8 {
    const text = switch (params) {
        .absent, .null_value => return null,
        .value => |raw| raw,
    };

    var reader = json.Reader.init(text);
    // An empty object names nothing, which the caller reports as a header
    // claiming a value the body does not carry. A `params` that is not an
    // object at all fails inside `beginObject`, and a malformed body must not
    // be reported as a header disagreement.
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "uri")) {
            return try reader.string(scratch);
        }
        try reader.skipValue(scratch);
    }
    return null;
}

// --- Event stream framing ------------------------------------------------------

/// Write one event carrying a single JSON-RPC message.
///
/// A `data:` line and a blank line, and nothing else. The specification names
/// no event type for this transport, so none is invented: an SSE event with
/// no `event:` field is by definition of type `message`, and a peer that keys
/// on the field sees the same thing either way. A peer that keys on a name
/// this file invented would see nothing at all.
///
/// A message containing a raw newline is refused. `framing.zig` already
/// guarantees a JSON-RPC message on this library's own transports has none,
/// and a newline inside an event would split one message into two the peer
/// then has to rejoin by guesswork.
pub fn writeEvent(out: []u8, message: []const u8) EncodeError![]const u8 {
    if (std.mem.indexOfAny(u8, message, &.{ '\n', '\r' }) != null) {
        return error.InvalidField;
    }
    var writer = json.Writer.init(out);
    try writer.slice("data: ");
    try writer.slice(message);
    // The blank line dispatches the event. Without it the message would sit in
    // the stream until the next one arrived, which for a `subscriptions/listen`
    // response could be never.
    try writer.slice("\n\n");
    return writer.written();
}

/// Read one event from a stream, or return 0 at the end of the stream.
///
/// The SSE rules that matter for this transport: a line beginning `:` is a
/// comment, every field other than `data` is ignored, and several `data`
/// lines join with a newline into one event. `id` is ignored rather than
/// stored because `Last-Event-ID` and resumption were removed at
/// `2026-07-28`, so a stream that recorded event ids would imply a
/// capability this revision does not have.
pub fn readEvent(reader: *Io.Reader, out: []u8) Error!usize {
    var len: usize = 0;
    // Where the next line is read to. It only moves forward and never falls
    // behind `len`, so a line and the event being built out of it can share
    // one caller buffer.
    var read_to: usize = 0;
    var saw_data = false;
    while (true) {
        // The line is streamed rather than taken, so its length is bounded by
        // `out` and not by whatever the reader happens to have buffered. An SSE
        // line is one message long, and a message is bounded by the caller's
        // event buffer.
        var writer = Io.Writer.fixed(out[read_to..]);
        const count = reader.streamDelimiter(&writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return error.Transport,
            error.WriteFailed => return error.BufferTooSmall,
            // The stream ended without a delimiter, so the last line was never
            // dispatched. SSE discards it, and so does this.
            error.EndOfStream => return 0,
        };
        const line = out[read_to..][0..count];
        read_to += count;
        // `streamDelimiter` leaves the delimiter in the reader.
        reader.toss(1);

        if (line.len == 0) {
            // The dispatch. An event that carried no `data` line is a comment
            // or a bare field, and SSE does not deliver those, so the loop
            // continues rather than handing the caller an empty message.
            if (!saw_data) continue;
            return len;
        }
        if (line[0] == ':') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const field = line[0..colon];
        if (!std.mem.eql(u8, field, "data")) continue;
        var value = line[colon + 1 ..];
        // One leading space after the colon is the field separator, not part
        // of the value.
        if (value.len != 0 and value[0] == ' ') value = value[1..];

        if (saw_data) {
            if (len == out.len) return error.BufferTooSmall;
            out[len] = '\n';
            len += 1;
        }
        // `value` lies inside the region the line was read to, and `len` never
        // passes it, so the copy is always forwards and may overlap.
        std.mem.copyForwards(u8, out[len..][0..value.len], value);
        len += value.len;
        saw_data = true;
    }
}

// --- The client ----------------------------------------------------------------

/// The headers one POST carries beyond the ones the transport always sends.
pub const PostHeaders = struct {
    /// The value for `Mcp-Method`. Required by section 4.2 from
    /// `2026-07-28`, and not defaulted here: a client that could send a POST
    /// without it would be one this revision calls non-conforming.
    method: []const u8,
    /// The value for `Mcp-Name`, required for `tools/call`, `resources/read`
    /// and `prompts/get`.
    ///
    /// A name that is not plain ASCII must already carry the base64 sentinel;
    /// [`mcp.encodeHeaderValue`] writes one and the caller owns its buffer.
    name: ?[]const u8 = null,
    /// The derived `Mcp-Param-{Name}` headers, as [`mcp.bindParamHeader`]
    /// returns them. The derived-header rule is not restated in this file, so
    /// a client cannot get the name or the value wrong independently.
    params: []const mcp.ParamBinding = &.{},
    /// Sent verbatim, e.g. `Authorization: Bearer …`, which section 4.2
    /// requires on every request.
    extra: []const http.Header = &.{},
};

/// A POST's response, still open.
///
/// The caller owns the storage and it must not move once `post` has filled it:
/// `std.http` points the response back into the request, so a struct returned
/// by value would leave a pointer into the copy that just died.
pub const Exchange = struct {
    request: http.Client.Request,
    response: http.Client.Response,
    /// Whether the reply is an event stream. Read before the body reader is
    /// taken, because taking it invalidates the head's strings.
    kind: MediaType,
    transfer: []u8,
    /// The body reader, created on first use. `std.http` allows it once.
    body: ?*Io.Reader = null,
    drained: bool = false,

    /// The HTTP status the peer answered with.
    pub fn status(self: *const Exchange) std.http.Status {
        return self.response.head.status;
    }

    /// Whether the reply carried a header of this kind.
    ///
    /// `mcp.HeaderKind.session_id_removed` is the one worth asking about: this
    /// revision removed the header, and a reply that carried one would be
    /// reviving a session model the client has no way to honour.
    ///
    /// Must be called before the first `nextMessage`, because taking the body
    /// reader invalidates the head's strings.
    pub fn hasHeader(self: *const Exchange, kind: mcp.HeaderKind) bool {
        var iterator = http.HeaderIterator.init(self.response.head.bytes);
        while (iterator.next()) |field| {
            if (mcp.headerKind(field.name) == kind) return true;
        }
        return false;
    }

    /// Read the next JSON-RPC message: the whole body of a single-body reply,
    /// or the next event of a stream. An empty slice means the reply is over.
    pub fn nextMessage(self: *Exchange, out: []u8) Error![]const u8 {
        if (self.drained) return out[0..0];
        if (self.body == null) self.body = self.response.reader(self.transfer);
        const reader = self.body.?;

        const len: usize = switch (self.kind) {
            .json => blk: {
                var writer = Io.Writer.fixed(out);
                break :blk reader.streamRemaining(&writer) catch |err| switch (err) {
                    // A fixed writer that is full reports a write failure, so
                    // the body is larger than the buffer the caller sized.
                    error.WriteFailed => return error.BufferTooSmall,
                    error.ReadFailed => return error.Transport,
                };
            },
            .event_stream => try readEvent(reader, out),
        };
        if (len == 0) {
            self.drained = true;
            return out[0..0];
        }
        return out[0..len];
    }

    /// Release the connection. The exchange cannot be used afterwards.
    pub fn close(self: *Exchange) void {
        self.request.deinit();
        self.* = undefined;
    }
};

/// What a peer answered to a call.
///
/// `message` and `body` borrow the buffer the exchange read into, which is
/// [`Client.Buffers`] `out` for a single body and the caller's event buffer
/// for a stream, and `body` is either that message or a slice of it. Nothing
/// here is copied, so a `Reply` is valid exactly as long as those buffers
/// are. `error_code` is the one member that owns its value.
pub const Reply = struct {
    /// The HTTP status. Not folded into an error: the specification pairs
    /// `-32601` with `404` and `-32020` with `400`, so a caller that cannot
    /// read the status cannot read the failure either. The body carries the
    /// JSON-RPC error, and `error_code` says which it is.
    status: std.http.Status,
    /// The whole JSON-RPC response message.
    message: []const u8,
    /// The `result` member, or the whole message when the peer answered with
    /// an error.
    ///
    /// The error object is not re-serialised out of its parts: the base layer
    /// keeps `code` and `message` separately and may have unescaped the
    /// message into the decode scratch, so the one place a caller can read a
    /// well-formed error is the message it arrived in.
    body: []const u8,
    /// The JSON-RPC error code, or null.
    error_code: ?i32,
    /// Whether the reply arrived on an event stream.
    streamed: bool,
};

/// A client for one MCP endpoint.
pub const Client = struct {
    http: *http.Client,
    /// The endpoint. Borrowed, and it must outlive the client: `std.http`
    /// re-resolves the URI in place when it follows a redirect, and this
    /// transport never follows one.
    uri: std.Uri,
    revision: mcp.Revision,
    /// An already-open connection, or null to let `std.http` open one.
    ///
    /// A caller holding a connection uses this rather than the pool: a Unix
    /// socket and a TLS session both exist before any request is made, and
    /// neither is reachable through a URI.
    connection: ?*http.Client.Connection = null,

    /// The buffers one exchange needs. The caller's, as everywhere else here.
    pub const Buffers = struct {
        /// Where `std.http` stages chunked-transfer data. Sixty-four bytes is
        /// what `std.http` itself uses; it must not be empty.
        transfer: []u8,
        /// The response body, or one event of a stream.
        out: []u8,
        /// Backs the decode of the reply.
        decode: []u8,
    };

    pub fn init(http_client: *http.Client, uri: std.Uri, revision: mcp.Revision) Client {
        return .{ .http = http_client, .uri = uri, .revision = revision };
    }

    /// The headers one POST carries, in wire order.
    ///
    /// `MCP-Protocol-Version` and the two-type `Accept` are always sent,
    /// because both are MUSTs and neither is the caller's to forget. The
    /// spellings are `mcp.header_name`'s, so the all-caps version header and
    /// the title-case ones cannot drift apart.
    pub fn requestHeaders(
        self: Client,
        spec: PostHeaders,
        out: []http.Header,
    ) EncodeError![]const http.Header {
        const needed = @as(usize, 3) +
            @intFromBool(spec.name != null) +
            spec.params.len +
            spec.extra.len;
        if (out.len < needed) return error.BufferTooSmall;

        var count: usize = 0;
        out[count] = .{
            .name = mcp.header_name.protocol_version,
            .value = self.revision.string(),
        };
        count += 1;
        out[count] = .{ .name = mcp.header_name.accept, .value = accept_value };
        count += 1;
        out[count] = .{ .name = mcp.header_name.method, .value = spec.method };
        count += 1;
        if (spec.name) |name| {
            out[count] = .{ .name = mcp.header_name.name, .value = name };
            count += 1;
        }
        for (spec.params) |binding| {
            out[count] = .{ .name = binding.header_name, .value = binding.header_value };
            count += 1;
        }
        for (spec.extra) |header| {
            out[count] = header;
            count += 1;
        }
        return out[0..count];
    }

    /// POST one JSON-RPC message and hand back the still-open reply.
    ///
    /// `head` receives the header block and must outlive the exchange, because
    /// `std.http` keeps the slice rather than copying it. A redirect is
    /// refused rather than followed: a POST whose body has already been sent
    /// cannot be replayed, and a client that silently retried a tool call
    /// would be calling it twice.
    pub fn post(
        self: *Client,
        exchange: *Exchange,
        body: []const u8,
        spec: PostHeaders,
        head: []http.Header,
        transfer: []u8,
    ) Error!void {
        const headers = try self.requestHeaders(spec, head);
        // The request is written where it will stay before a single byte goes
        // out. `std.http` points the response back into the request, so a
        // request that moved after `receiveHead` would leave that pointer aimed
        // at a copy that is gone, and the body reader would then read whatever
        // the dead stack slot has since been used for.
        exchange.request = self.http.request(.POST, self.uri, .{
            .extra_headers = headers,
            .headers = .{
                .content_type = .{ .override = mcp.uri_and_media.json_media_type },
                // Neither of the two response types has a compressed variant
                // in this revision, so advertising them would only let a peer
                // answer with one this transport cannot read.
                .accept_encoding = .omit,
            },
            .redirect_behavior = .not_allowed,
            .connection = self.connection,
        }) catch |err| switch (err) {
            // The endpoint is the caller's own, so a scheme this transport
            // cannot speak is a configuration fault rather than something that
            // happened on the wire.
            error.UnsupportedUriScheme, error.UriMissingHost => return error.UnsupportedUri,
            else => return error.Transport,
        };
        errdefer exchange.request.deinit();

        exchange.request.transfer_encoding = .{ .content_length = body.len };
        var out = exchange.request.sendBodyUnflushed(&.{}) catch return error.Transport;
        out.writer.writeAll(body) catch return error.Transport;
        out.end() catch return error.Transport;
        exchange.request.connection.?.flush() catch return error.Transport;

        exchange.response = exchange.request.receiveHead(&.{}) catch |err| switch (err) {
            // A peer that answers a POST with a redirect is asking for a
            // request that cannot be replayed, and the specification names no
            // way to replay one.
            error.TooManyHttpRedirects => return error.Redirected,
            else => return error.Transport,
        };
        exchange.transfer = transfer;
        exchange.body = null;
        exchange.drained = false;
        // Read before the body reader takes the head, because taking it
        // invalidates the head's strings.
        exchange.kind = if (mediaType(exchange.response.head.content_type orelse "") ==
            .event_stream)
            .event_stream
        else
            .json;
    }

    /// POST one JSON-RPC message and return the message that answers `id`.
    ///
    /// Messages on the same stream that are not the answer are stepped over:
    /// a server may send notifications for other subscriptions first, and the
    /// specification forbids it from sending independent requests on this
    /// stream, so a message that is neither a response for `id` nor a
    /// notification is one this client has no way to route and is reported
    /// rather than dropped.
    pub fn call(
        self: *Client,
        id: i64,
        body: []const u8,
        spec: PostHeaders,
        head: []http.Header,
        buffers: Buffers,
    ) Error!Reply {
        var exchange: Exchange = undefined;
        try self.post(&exchange, body, spec, head, buffers.transfer);
        defer exchange.close();

        while (true) {
            const message = try exchange.nextMessage(buffers.out);
            if (message.len == 0) return error.NoResponse;
            const decoded = jsonrpc.decode(message, buffers.decode) catch |err| switch (err) {
                // Padding and keep-alive whitespace are not messages, and
                // refusing them would fail a request the peer did answer.
                error.Truncated, error.MalformedJson => continue,
                else => |other| return other,
            };
            switch (decoded.kind) {
                .notification => continue,
                .request => return error.MalformedRequest,
                .response => {
                    // A string id is legal JSON-RPC, but this library's own
                    // ids are integers and a string cannot be one of them, so
                    // it is not a response to this call.
                    const answer = switch (decoded.id orelse continue) {
                        .integer => |value| value,
                        .string => continue,
                    };
                    if (answer != id) continue;
                    return .{
                        .status = exchange.status(),
                        .message = message,
                        .body = decoded.result orelse message,
                        .error_code = if (decoded.rpc_error) |rpc_error| rpc_error.code else null,
                        .streamed = exchange.kind == .event_stream,
                    };
                },
            }
        }
    }
};

// --- The server ----------------------------------------------------------------

/// The shape a server answers a request with.
///
/// Both are legal for the same request. Section 4.2 requires the client to
/// support both, and `subscriptions/listen` is the case where the stream is
/// the point: its result arrives first and the notifications that justified
/// the subscription follow on the same reply.
pub const ResponseShape = enum {
    /// One JSON body, framed with `content-length`.
    single,
    /// An event stream, framed with `transfer-encoding: chunked`.
    stream,
};

/// An open event stream.
///
/// The caller owns it and must [`Stream.close`] it. The staging buffer is the
/// caller's too, and outlives the stream: `std.http` writes the chunk header
/// out of it on every flush.
pub const Stream = struct {
    body: http.BodyWriter,

    /// Send one JSON-RPC message as one event.
    ///
    /// `event` is scratch for the framing and is not retained. The flush is
    /// per event rather than per stream because a subscription that buffers
    /// until it ends is not a subscription.
    pub fn send(self: *Stream, event: []u8, message: []const u8) Error!void {
        const framed = try writeEvent(event, message);
        self.body.writer.writeAll(framed) catch return error.Transport;
        // Two levels are flushed, and both are needed. `BodyWriter.flush`
        // reaches the `chunk_len` state an event stream spends its whole life
        // in, so that is not what is missing; what it flushes is
        // `http_protocol_output`, and the framed event is still sitting in
        // `body.writer`'s own staging buffer, which nothing else drains.
        // Draining that first is what writes the chunk header and the event
        // out of it, and flushing the protocol output after that is what puts
        // the chunk on the wire while the stream is still open, which is the
        // whole of a subscription. With only the first flush a stream that
        // never ends delivered nothing: the reader took the head and then
        // waited for an event that had been written.
        self.body.writer.flush() catch return error.Transport;
        self.body.http_protocol_output.flush() catch return error.Transport;
    }

    /// End the stream. The connection is then ready for the next request.
    pub fn close(self: *Stream) Error!void {
        self.body.end() catch return error.Transport;
    }
};

/// A Streamable HTTP server on one accepted connection.
///
/// One connection, not one server: `std.http.Server` is exactly that, and a
/// caller that wants a listener accepts and constructs one per connection.
/// Nothing is kept between requests, because `Mcp-Session-Id` was removed at
/// `2026-07-28` and there is nothing this revision permits to keep.
pub const Server = struct {
    http: std.http.Server,
    /// The request being answered. `std.http` answers through the request, so
    /// it has to survive from `receive` to whichever `respond` follows.
    request: ?http.Server.Request = null,
    /// The caller-owned buffers. See [`Server.Buffers`].
    buffers: Buffers,

    /// Every buffer one server needs. None is allocated here.
    pub const Buffers = struct {
        /// Room for the derived parameter headers, one per `Mcp-Param-{Name}`
        /// the peer may send.
        params: []ParamHeader,
        /// Backs the base64 decoding of header values.
        head_scratch: []u8,
        /// Where the request body is read.
        body: []u8,
        /// Backs the body decode.
        body_scratch: []u8,
        /// Handed to the handler that answers a request.
        handler_scratch: []u8,
        /// Chunked-transfer scratch, owned by `std.http`. The body reader
        /// writes through it, so it must not be empty.
        transfer: []u8,
        /// Scratch for one event's framing. It is deliberately not the same
        /// buffer as `stream`: the framing is written out of it into the
        /// stream's own staging buffer, and one buffer cannot be both the
        /// source and the destination of a copy.
        event: []u8,
        /// The staging buffer of the chunked body writer an event stream runs
        /// on. It must outlive the stream.
        stream: []u8,
    };

    /// `in` and `out` are held by the caller, for the same reason
    /// `conn.Conn` holds its reader and writer: `std.http.Server` keeps raw
    /// pointers to both, and a local would dangle before the first read.
    ///
    /// There is no `Io` parameter because nothing here blocks on anything but
    /// the reader and the writer: every wait this transport does is a read or
    /// a write, and both already carry the interface.
    pub fn init(in: *Io.Reader, out: *Io.Writer, buffers: Buffers) Server {
        return .{ .http = std.http.Server.init(in, out), .buffers = buffers };
    }

    /// Read and validate the next POST.
    ///
    /// Null when the peer hung up between requests, which is how a connection
    /// ends and is not a failure. The body is not read until the headers have
    /// been checked, so a request this library will refuse never has its body
    /// read here. Those bytes stay on the socket, and `std.http` drains them
    /// when the request is answered, so a connection is reusable after an
    /// answer; a caller that answers nothing must hang up rather than call
    /// `receive` again.
    pub fn receive(self: *Server) Error!?Post {
        const request = self.http.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return null,
            else => return error.MalformedRequest,
        };
        self.request = request;
        // `2026-07-28` keeps POST only, and the specification says `405` for
        // the GET and DELETE of an earlier transport.
        if (request.head.method != .POST) return error.MethodNotAllowed;

        const headers = try readHeaders(
            request.head_buffer,
            self.buffers.params,
            self.buffers.head_scratch,
        );
        if (headers.schema_keyword_sent != null) return error.NotAHeader;
        _ = try revisionOf(headers);
        // A peer that sent `Mcp-Session-Id` is refused before its body is
        // taken off the socket, for the reason `checkPost` gives.
        if (headers.removed) |removed| {
            if (removed == .session_id_removed) return error.UnsupportedVersion;
        }
        if (mediaType(headers.content_type orelse return error.MissingHeader) != .json) {
            return error.UnsupportedMediaType;
        }
        if (!parseAccept(headers.accept).isAcceptable()) return error.NotAcceptable;

        const body = try self.readBody(request);
        return try checkPost(headers, body, self.buffers.body_scratch);
    }

    /// Answer with one JSON body.
    pub fn respondJson(self: *Server, post: Post, response: []const u8) Error!void {
        if (!post.accept.allows(.json)) return error.NotAcceptable;
        const request = &(self.request orelse return error.MalformedRequest);
        var headers = [_]http.Header{.{
            .name = mcp.header_name.content_type,
            .value = mcp.uri_and_media.json_media_type,
        }};
        request.respond(response, .{ .status = .ok, .extra_headers = &headers }) catch
            return error.Transport;
    }

    /// Answer with an event stream the caller owns.
    ///
    /// `X-Accel-Buffering: no` is here because section 4.2 says a server
    /// SHOULD send it when it starts a stream: a reverse proxy that buffers
    /// the body would turn a subscription into one late delivery, which is
    /// the failure the header exists to prevent. No `Cache-Control` is sent,
    /// because none of the sources this library works from states one.
    pub fn respondStream(self: *Server, post: Post) Error!Stream {
        if (!post.accept.allows(.event_stream)) return error.NotAcceptable;
        const request = &(self.request orelse return error.MalformedRequest);
        var headers = [_]http.Header{
            .{
                .name = mcp.header_name.content_type,
                .value = mcp.uri_and_media.event_stream_media_type,
            },
            .{ .name = "X-Accel-Buffering", .value = "no" },
        };
        const body = request.respondStreaming(self.buffers.stream, .{
            .respond_options = .{ .status = .ok, .extra_headers = &headers },
        }) catch return error.Transport;
        return .{ .body = body };
    }

    /// `202 Accepted` with no body: the answer to a notification POST.
    pub fn respondAccepted(self: *Server) Error!void {
        const request = &(self.request orelse return error.MalformedRequest);
        request.respond("", .{ .status = .accepted }) catch return error.Transport;
    }

    /// Answer with a status and, when the failure has a JSON-RPC body, one.
    pub fn reject(self: *Server, status: std.http.Status, body: []const u8) Error!void {
        const request = &(self.request orelse return error.MalformedRequest);
        var headers = [_]http.Header{.{
            .name = mcp.header_name.content_type,
            .value = mcp.uri_and_media.json_media_type,
        }};
        request.respond(body, .{ .status = status, .extra_headers = &headers }) catch
            return error.Transport;
    }

    /// Answer an accepted POST through `handler`.
    ///
    /// The handler is a [`conn.Handler`], unchanged: it sees the whole
    /// JSON-RPC message and returns a response envelope borrowed from the
    /// scratch it is given. One dispatcher therefore serves stdio and
    /// Streamable HTTP without a second dispatch table, which is the point of
    /// `conn.Conn` being the only place a message is sorted.
    ///
    /// A notification is answered `202` with no body whatever the handler
    /// returns, because a notification has no answer to send. A request the
    /// handler declines is [`Error.NoAnswer`] rather than an invented status.
    pub fn answer(
        self: *Server,
        post: Post,
        handler: conn.Handler,
        shape: ResponseShape,
    ) Error!std.http.Status {
        const dispatch = handler.call orelse return error.NoAnswer;
        const response = try dispatch(handler.ctx, post.body, self.buffers.handler_scratch);

        if (post.notification) {
            try self.respondAccepted();
            return .accepted;
        }
        const envelope = response orelse return error.NoAnswer;
        switch (shape) {
            .single => {
                try self.respondJson(post, envelope);
                return .ok;
            },
            .stream => {
                var stream = try self.respondStream(post);
                defer stream.close() catch {};
                try stream.send(self.buffers.event, envelope);
                return .ok;
            },
        }
    }

    /// The body reader reads through `transfer`, and the reader for it may be
    /// created once per request, so the length comes from `content-length`
    /// rather than from an attempt to read until the socket says stop.
    ///
    /// A `transfer-encoding: chunked` POST is refused rather than read. There
    /// is no `content-length` to take the length from, and a body this
    /// transport does not read stays on the socket, so a caller that leaves the
    /// refusal unanswered has its next `receive` parse chunk data as a request
    /// line. Refusing it here is what keeps a connection reused across
    /// requests from dying after one legal request.
    fn readBody(self: *Server, request: http.Server.Request) Error![]const u8 {
        if (request.head.transfer_encoding == .chunked) return error.MalformedRequest;
        const length = request.head.content_length orelse 0;
        if (length > self.buffers.body.len) return error.BodyTooLarge;
        if (length == 0) return self.buffers.body[0..0];
        if (self.buffers.transfer.len == 0) return error.BufferTooSmall;
        const reader = self.http.reader.bodyReader(
            self.buffers.transfer,
            request.head.transfer_encoding,
            request.head.content_length,
        );
        reader.readSliceAll(self.buffers.body[0..length]) catch return error.Transport;
        return self.buffers.body[0..length];
    }
};

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test {
    // Zig analyses only what a test reaches, so name the module rather than
    // trusting a build to discover it.
    testing.refAllDecls(@This());
}

test "the version header is all-caps and the rest are title-case, and both are read" {
    var params: [4]ParamHeader = undefined;
    var scratch: [64]u8 = undefined;
    // Section 4.2 spells these two ways in the same document. A table keyed on
    // either casing reads one and drops the other, and the peer that sent the
    // other spelling gets a 400 for having sent exactly what the
    // specification says.
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "mcp-method: tools/list\r\n" ++
        "MCP-NAME: unrelated\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    try testing.expectEqualStrings("2026-07-28", headers.protocol_version.?);
    try testing.expectEqualStrings("tools/list", headers.method.?);
    try testing.expectEqualStrings("unrelated", headers.name.?);
    try testing.expectEqual(mcp.Revision.current, try revisionOf(headers));
    try testing.expect(headers.removed == null);
}

test "a header block that is not one is refused, not walked" {
    var params: [2]ParamHeader = undefined;
    var scratch: [64]u8 = undefined;
    // `std.http`'s iterator unwraps the end-of-block find, so a block that is
    // not a block has to be refused before it is walked.
    try testing.expectError(
        error.MalformedRequest,
        readHeaders("MCP-Protocol-Version: 2026-07-28", &params, &scratch),
    );
    try testing.expectError(error.MalformedRequest, readHeaders("", &params, &scratch));
}

test "a peer that sends the session id this revision removed is refused" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Mcp-Session-Id: 5eed\r\n" ++
        "Last-Event-ID: 11\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    try testing.expectEqual(mcp.HeaderKind.session_id_removed, headers.removed.?);
    // PROTOCOLS.md 4.2 says a peer that sends `Mcp-Session-Id` is not speaking
    // this revision, so the request is refused. The compatibility matrix in
    // the normative source asks for the opposite, and the two disagree, so
    // this is the refusal PROTOCOLS.md requires.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    try testing.expectError(error.UnsupportedVersion, checkPost(headers, body, &scratch));
}

test "Last-Event-ID alone is recorded, and the request it arrived on is served" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Last-Event-ID: 11\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    try testing.expectEqual(mcp.HeaderKind.last_event_id_removed, headers.removed.?);
    // PROTOCOLS.md 4.2 says of `Mcp-Session-Id` that a peer sending it is not
    // speaking this revision, and says no such thing of this header, so a
    // request that carried only this one is served. Nothing echoes it back and
    // there is no resumption to resume.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    try testing.expectEqualStrings("tools/list", (try checkPost(headers, body, &scratch)).method);
}

test "a repeated control header is refused rather than resolved by order" {
    var params: [2]ParamHeader = undefined;
    var scratch: [64]u8 = undefined;
    // HTTP allows this and the specification is silent. Two revisions and one
    // body is a request a gateway and a library would validate two different
    // ways, so it is refused instead.
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "MCP-Protocol-Version: 2025-11-25\r\n" ++
        "\r\n";
    try testing.expectError(error.DuplicateHeader, readHeaders(head, &params, &scratch));
}

test "one derived annotation sent twice is refused, because only one value is checked" {
    var params: [4]ParamHeader = undefined;
    var scratch: [128]u8 = undefined;
    // Section 4.2 makes a server validate the derived header against
    // `arguments` and reject on mismatch, so two headers for one annotation
    // leave that check as ambiguous as a repeated `Mcp-Method`. A header name
    // is case-insensitive on the wire, so the repeat below arrives under
    // another casing and is not a second annotation.
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Param-city: Bern\r\n" ++
        "Mcp-Param-unit: metric\r\n" ++
        "MCP-PARAM-CITY: Geneva\r\n" ++
        "\r\n";
    try testing.expectError(error.DuplicateHeader, readHeaders(head, &params, &scratch));

    // Two annotations for two members are two derived headers, and they are
    // carried rather than refused. Without this half the assertion above would
    // also pass for a server that refused every second header.
    const two = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Param-city: Bern\r\n" ++
        "Mcp-Param-unit: metric\r\n" ++
        "\r\n";
    try testing.expectEqual(@as(usize, 2), (try readHeaders(two, &params, &scratch)).params.len);
}

test "x-mcp-header sent as a header is refused, because it is a schema keyword" {
    var params: [2]ParamHeader = undefined;
    var scratch: [128]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/call\r\n" ++
        "Mcp-Name: echo\r\n" ++
        "x-mcp-header: city\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    try testing.expectEqualStrings("city", headers.schema_keyword_sent.?);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\"}}";
    try testing.expectError(error.NotAHeader, checkPost(headers, body, &scratch));
}

test "Mcp-Method that disagrees with the body is a mismatch, not a route" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    // The header exists so a gateway can route without the body. A gateway
    // that routes on it while the library reads the body would send the
    // request somewhere the client never meant, so the two must agree.
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\"}}";
    try testing.expectError(error.HeaderMismatch, checkPost(headers, body, &scratch));
}

test "Mcp-Method is required, including on a notification" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    const body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}";
    try testing.expectError(error.MissingHeader, checkPost(headers, body, &scratch));
}

test "Mcp-Name is required for the three methods that name an entity, and only those" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/call\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\"}}";
    try testing.expectError(error.MissingHeader, checkPost(headers, body, &scratch));

    // A method that names nothing does not get a header requirement invented
    // for it, or every notification POST would be refused.
    const list_head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const list_headers = try readHeaders(list_head, &params, &scratch);
    const list_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    const post = try checkPost(list_headers, list_body, &scratch);
    try testing.expectEqualStrings("tools/list", post.method);
    try testing.expect(post.name == null);
    try testing.expect(!post.notification);
}

test "Mcp-Name must equal the name the body carries" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/call\r\n" ++
        "Mcp-Name: other\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\"}}";
    try testing.expectError(error.HeaderMismatch, checkPost(headers, body, &scratch));
}

test "a sentinel-encoded Mcp-Name is decoded before it is compared" {
    var params: [2]ParamHeader = undefined;
    var head_scratch: [256]u8 = undefined;
    var writer_buffer: [128]u8 = undefined;
    var encode_scratch: [64]u8 = undefined;
    var body_scratch: [256]u8 = undefined;

    // A name that is not plain ASCII must be sent base64-wrapped, and a server
    // that compared the raw value would reject the conforming client.
    var writer = json.Writer.init(&writer_buffer);
    try mcp.encodeHeaderValue("städte", &writer, &encode_scratch);
    const encoded = writer.written();
    try testing.expect(mcp.isSentinelEncoded(encoded));

    var head_buffer: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buffer,
        "POST /mcp HTTP/1.1\r\n" ++
            "MCP-Protocol-Version: 2026-07-28\r\n" ++
            "Mcp-Method: tools/call\r\n" ++
            "Mcp-Name: {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "\r\n",
        .{encoded},
    );
    const headers = try readHeaders(head, &params, &head_scratch);
    try testing.expectEqualStrings("städte", headers.name.?);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"städte\"}}";
    const post = try checkPost(headers, body, &body_scratch);
    try testing.expectEqualStrings("städte", post.name.?);
}

test "a derived parameter header is checked against the value arguments carries" {
    var names: [32]u8 = undefined;
    var values: [64]u8 = undefined;
    var encode_scratch: [64]u8 = undefined;
    var params: [2]ParamHeader = undefined;
    var scratch: [512]u8 = undefined;

    // The header is derived by the module that owns the rule, so the two
    // sides of it cannot disagree about the name or the sentinel.
    const binding = (try mcp.bindParamHeader(
        "city",
        .string,
        .{ .string_value = "Zürich" },
        &names,
        &values,
        &encode_scratch,
    )).?;
    try testing.expectEqualStrings("Mcp-Param-city", binding.header_name);

    var head_buffer: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buffer,
        "POST /mcp HTTP/1.1\r\n" ++
            "MCP-Protocol-Version: 2026-07-28\r\n" ++
            "Mcp-Method: tools/call\r\n" ++
            "Mcp-Name: echo\r\n" ++
            "{s}: {s}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "\r\n",
        .{ binding.header_name, binding.header_value },
    );
    const headers = try readHeaders(head, &params, &scratch);
    try testing.expectEqual(@as(usize, 1), headers.params.len);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\",\"arguments\":{\"city\":\"Zürich\"}}}";
    const post = try checkPost(headers, body, &scratch);
    try testing.expectEqualStrings("Zürich", post.param("city").?);

    var converted: [mcp.param_value_max_len]u8 = undefined;
    var decode_scratch: [64]u8 = undefined;
    // The value the tool's own schema declares is what the header is checked
    // against, and the verdict is the one section 4.2 names.
    try testing.expectEqual(mcp.ParamVerdict.accepted, try post.checkParam(
        "city",
        .{ .string_value = "Zürich" },
        &converted,
        &decode_scratch,
    ));
    try testing.expectEqual(mcp.ParamVerdict.mismatch, try post.checkParam(
        "city",
        .{ .string_value = "Bern" },
        &converted,
        &decode_scratch,
    ));
    try testing.expectEqual(mcp.ParamVerdict.accepted, try post.checkParam(
        "unit",
        null,
        &converted,
        &decode_scratch,
    ));
}

test "the reply type is bounded by what the client said it accepts" {
    // Section 4.2 requires the client to list both, so a client that lists one
    // has narrowed the choice and a server that answers with the other one
    // sends a media type the client said it cannot read.
    const both = parseAccept(accept_value);
    try testing.expect(both.allows(.json) and both.allows(.event_stream));

    const one = parseAccept("application/json");
    try testing.expect(one.allows(.json));
    try testing.expect(!one.allows(.event_stream));

    const wildcard = parseAccept("*/*");
    try testing.expect(wildcard.allows(.json) and wildcard.allows(.event_stream));

    // No header at all is HTTP's "any media type", and refusing it would break
    // every client the specification does not require the header of.
    const absent = parseAccept(null);
    try testing.expect(!absent.present);
    try testing.expect(absent.isAcceptable());

    try testing.expect(!parseAccept("text/plain").isAcceptable());
    try testing.expect(!parseAccept("text/plain").allows(.json));
}

test "a media type the peer refused with q=0 is one this transport may not answer with" {
    // RFC 9110 gives a quality of zero one meaning, and `respondJson` reads
    // this header. Without the rule `application/json;q=0` is read as a
    // request for a JSON body, and the answer is a media type the peer said it
    // will not read.
    const refused = parseAccept("application/json;q=0");
    try testing.expect(!refused.allows(.json));
    try testing.expect(!refused.allows(.event_stream));
    try testing.expect(!refused.isAcceptable());

    // A quality of zero written longer is that same refusal, and any other
    // quality accepts. A `q` that is not a number is not a quality, so it
    // refuses nothing.
    try testing.expect(!parseAccept("application/json;q=0.000").allows(.json));
    try testing.expect(parseAccept("application/json;q=0.5").allows(.json));
    try testing.expect(parseAccept("application/json;q=1").allows(.json));
    try testing.expect(parseAccept("application/json; charset=utf-8").allows(.json));

    // One refused entry does not refuse the others, so a peer that refused the
    // body and kept the stream is answered with the stream.
    const mixed = parseAccept("application/json;q=0, text/event-stream");
    try testing.expect(!mixed.allows(.json));
    try testing.expect(mixed.allows(.event_stream));
}

test "a POST that accepts no reply this transport can send is refused" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Accept: text/plain\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    try testing.expectError(error.NotAcceptable, checkPost(headers, body, &scratch));
}

test "a POST whose only acceptable type arrived with q=0 is refused" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    // Naming a type this transport cannot send and refusing a type it can are
    // the same answer to the server, so they are refused the same way and the
    // request never reaches a handler.
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Accept: application/json;q=0\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    try testing.expectError(error.NotAcceptable, checkPost(headers, body, &scratch));
}

test "a version this library does not decode is refused before the body is read" {
    var params: [2]ParamHeader = undefined;
    var scratch: [64]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2027-01-01\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    try testing.expectError(error.UnsupportedVersion, revisionOf(headers));
}

test "a body that is not a request is refused" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    // A response has no method to route and no answer to give.
    try testing.expectError(error.MalformedRequest, checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        &scratch,
    ));
    // A media type this transport does not read is refused too.
    const text_head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n";
    const text_headers = try readHeaders(text_head, &params, &scratch);
    try testing.expectError(error.UnsupportedMediaType, checkPost(
        text_headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
        &scratch,
    ));
}

test "a notification is told apart from a request, because it is answered 202" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: notifications/progress\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);
    const post = try checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}",
        &scratch,
    );
    try testing.expect(post.notification);
}

test "an event is one data line and a blank line" {
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "data: {\"a\":1}\n\n",
        try writeEvent(&out, "{\"a\":1}"),
    );
    // A raw newline would split one message into two events, and the peer
    // would have to rejoin them by guesswork.
    try testing.expectError(error.InvalidField, writeEvent(&out, "{\"a\":\n1}"));
    try testing.expectError(error.InvalidField, writeEvent(&out, "{\"a\":\r1}"));
}

test "a comment and every field but data are not part of an event" {
    var out: [128]u8 = undefined;
    var reader = Io.Reader.fixed(
        ": keep-alive\n" ++
            "event: message\n" ++
            "id: 4\n" ++
            "retry: 1000\n" ++
            "data: {\"b\":2}\n" ++
            "\n",
    );
    const len = try readEvent(&reader, &out);
    try testing.expectEqualStrings("{\"b\":2}", out[0..len]);
}

test "several data lines are one event, and the stream may then end" {
    var out: [128]u8 = undefined;
    var reader = Io.Reader.fixed("data: {\"a\":\ndata: 1}\n\n");
    const len = try readEvent(&reader, &out);
    try testing.expectEqualStrings("{\"a\":\n1}", out[0..len]);

    // The next event is the next one, and the end of the stream is zero
    // messages rather than an error.
    try testing.expectEqual(@as(usize, 0), try readEvent(&reader, &out));
}

test "an event the stream ended inside is delivered as nothing" {
    var out: [128]u8 = undefined;
    var reader = Io.Reader.fixed("data: {\"a\":");
    // SSE discards an event that was never dispatched, so a peer that hangs up
    // mid-event produces no message rather than a truncated one that a caller
    // would try to parse.
    try testing.expectEqual(@as(usize, 0), try readEvent(&reader, &out));
}

test "a reply that does not fit the caller's buffer is reported, not truncated" {
    var out: [4]u8 = undefined;
    var reader = Io.Reader.fixed("data: {\"a\":1}\n\n");
    try testing.expectError(error.BufferTooSmall, readEvent(&reader, &out));
}

// --- Loopback over a real socket ----------------------------------------------

/// One loopback endpoint, listened on and ready to be accepted.
///
/// Port zero, and the kernel's choice is read back off the listening socket,
/// so two runs of this file cannot collide over a port. A Unix domain socket
/// would remove even that, and this library's own tests use one elsewhere, but
/// `std.http.Client` cannot reach one: its `connectUnix` names
/// `std.posix.SocketError`, which this toolchain's `std.posix` does not
/// define, so the function does not compile. `connectTcp` compiles and is what
/// a real client uses anyway.
const Endpoint = struct {
    address: Io.net.IpAddress = undefined,
    listener: Io.net.Server = undefined,
    uri_buffer: [64]u8 = undefined,
    uri_text: []const u8 = "",

    fn open(self: *Endpoint, io: Io) !void {
        self.address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.listener = try self.address.listen(io, .{ .reuse_address = true });
        self.uri_text = try std.fmt.bufPrint(
            &self.uri_buffer,
            "http://127.0.0.1:{d}/mcp",
            .{self.listener.socket.address.getPort()},
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

/// Every buffer one side of an exchange needs.
///
/// Caller-owned, so a leak in the transport shows up as a leak in the test
/// rather than being absorbed by an allocator the transport was handed.
const Side = struct {
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    stream: Io.net.Stream = undefined,
    stream_reader: Io.net.Stream.Reader = undefined,
    stream_writer: Io.net.Stream.Writer = undefined,

    params: [8]ParamHeader = undefined,
    head_scratch: [256]u8 = undefined,
    body: [4096]u8 = undefined,
    body_scratch: [1024]u8 = undefined,
    handler_scratch: [1024]u8 = undefined,
    transfer: [64]u8 = undefined,
    event: [4096]u8 = undefined,
    stream_buffer: [4096]u8 = undefined,
    server: Server = undefined,

    head: [16]http.Header = undefined,
    out: [8192]u8 = undefined,
    decode: [1024]u8 = undefined,
};

/// Answers every request with a result, and records what it was asked.
const Answer = struct {
    calls: usize = 0,
    method_buffer: [64]u8 = undefined,
    method_len: usize = 0,

    fn handle(ctx: ?*anyopaque, body: []const u8, scratch: []u8) conn.Error!?[]const u8 {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(body, scratch) catch return null;
        self.calls += 1;
        const name = message.method orelse return null;
        const n = @min(name.text.len, self.method_buffer.len);
        @memcpy(self.method_buffer[0..n], name.text[0..n]);
        self.method_len = n;
        if (message.id == null) return null;

        // The reply is a real JSON-RPC envelope carrying the request's own id,
        // which is the only thing a client can match an answer by.
        var writer = json.Writer.init(scratch);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        var id_buffer: [24]u8 = undefined;
        const id = switch (message.id.?) {
            .integer => |value| value,
            .string => return null,
        };
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{id}) catch return null;
        writer.slice(id_text) catch return null;
        writer.slice(",\"result\":{\"resultType\":\"complete\"}}") catch return null;
        return writer.written();
    }
};

/// Serves a fixed number of POSTs on one accepted connection.
const Serve = struct {
    io: Io,
    listener: *Io.net.Server,
    side: *Side,
    handler: conn.Handler,
    shape: ResponseShape,
    /// How many POSTs to answer before hanging up.
    count: usize,
    /// The failure the first request must be refused with, or null when it is
    /// one to serve.
    ///
    /// A refused request is answered and the connection then carries the next
    /// one, which is the point: the body was refused before it was read, so
    /// `std.http` can drain it and the connection stays in step.
    refuse_first: ?anyerror = null,
    /// The status a refused request is answered with.
    refuse_status: std.http.Status = .bad_request,
    /// Whether a request was refused, so a test can tell a refusal from a
    /// result.
    refused: ?*bool = null,
    /// The status of each answer, in order.
    statuses: []std.http.Status,
    /// How many requests this connection answered. A request refused is not
    /// counted, which is the only way a test can tell the two apart.
    answered: *usize,
    /// The revision the accepted POST named, so a test can assert the header
    /// really was read rather than assumed.
    revision: ?*?mcp.Revision = null,
    failed: *bool,

    fn run(self: *@This()) void {
        const stream = self.listener.accept(self.io) catch {
            self.failed.* = true;
            return;
        };
        // A response that has been written is in the kernel's buffer, so
        // closing does not lose it, and the peer reads it and then sees end of
        // file. Nothing is left blocked on this socket.
        defer stream.close(self.io);
        self.side.stream = stream;
        self.side.stream_reader =
            Io.net.Stream.Reader.init(stream, self.io, &self.side.reader_buffer);
        self.side.stream_writer =
            Io.net.Stream.Writer.init(stream, self.io, &self.side.writer_buffer);
        self.side.server = Server.init(
            &self.side.stream_reader.interface,
            &self.side.stream_writer.interface,
            .{
                .params = &self.side.params,
                .head_scratch = &self.side.head_scratch,
                .body = &self.side.body,
                .body_scratch = &self.side.body_scratch,
                .handler_scratch = &self.side.handler_scratch,
                .transfer = &self.side.transfer,
                .event = &self.side.event,
                .stream = &self.side.stream_buffer,
            },
        );

        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            const expected: ?anyerror = if (index == 0) self.refuse_first else null;
            const post = self.side.server.receive() catch |err| {
                // A refusal this server was not told to expect is a failure,
                // and so is a request that arrived with nothing to refuse.
                const wanted = expected orelse {
                    self.failed.* = true;
                    return;
                };
                if (err != wanted) {
                    self.failed.* = true;
                    return;
                }
                self.side.server.reject(self.refuse_status, "") catch {
                    self.failed.* = true;
                    return;
                };
                if (self.refused) |slot| slot.* = true;
                continue;
            } orelse {
                self.failed.* = true;
                return;
            };
            // A request that was to be refused and reached a handler instead
            // is a server that answered what it was told not to.
            if (expected != null) {
                self.failed.* = true;
                return;
            }
            const status = self.side.server.answer(post, self.handler, self.shape) catch {
                self.failed.* = true;
                return;
            };
            self.statuses[index] = status;
            self.answered.* += 1;
            if (self.revision) |slot| slot.* = post.revision;
        }
    }
};

/// POSTs one message and returns the reply that answers `id`.
const Call = struct {
    io: Io,
    http: *http.Client,
    endpoint: *const Endpoint,
    side: *Side,
    body: []const u8,
    spec: PostHeaders,
    id: i64,
    /// The reply, which borrows `side.out` and `side.decode` and so stays
    /// valid exactly as long as they do.
    reply: *Reply,
    got: *bool,
    failed: *bool,

    fn run(self: *@This()) void {
        var client = openClient(self.http, self.endpoint) orelse {
            self.failed.* = true;
            return;
        };
        const reply = client.call(self.id, self.body, self.spec, &self.side.head, .{
            .transfer = &self.side.transfer,
            .out = &self.side.out,
            .decode = &self.side.decode,
        }) catch {
            self.failed.* = true;
            return;
        };
        self.reply.* = reply;
        self.got.* = true;
    }
};

/// POSTs one message and reads a whole reply, event by event.
const Listen = struct {
    io: Io,
    http: *http.Client,
    endpoint: *const Endpoint,
    side: *Side,
    body: []const u8,
    spec: PostHeaders,
    /// The status that came back.
    status: std.http.Status,
    /// Whether the reply was an event stream.
    streamed: bool = false,
    /// The `Content-Type` the reply carried, copied out of the head before
    /// the body reader invalidates it.
    content_type: [64]u8 = undefined,
    content_type_len: usize = 0,
    /// Whether the reply carried a session identifier, which this revision
    /// removed and no compliant server may send.
    session_echoed: bool = false,
    /// The length of the first message, so a test can assert on it.
    first_len: usize = 0,
    /// The length of the second, for a stream that carries more than a result.
    second_len: usize = 0,
    /// How many messages the reply held, and the count at the read that
    /// reported the reply over.
    messages: usize = 0,
    ended: usize = 0,
    got: *bool,
    failed: *bool,

    fn run(self: *@This()) void {
        var client = openClient(self.http, self.endpoint) orelse {
            self.failed.* = true;
            return;
        };
        var exchange: Exchange = undefined;
        client.post(&exchange, self.body, self.spec, &self.side.head, &self.side.transfer) catch {
            self.failed.* = true;
            return;
        };
        defer exchange.close();
        self.status = exchange.status();
        self.streamed = exchange.kind == .event_stream;
        // Read off the head before the first `nextMessage`, which is when
        // `std.http` lets go of it.
        self.session_echoed = exchange.hasHeader(.session_id_removed);
        if (exchange.response.head.content_type) |value| {
            const n = @min(value.len, self.content_type.len);
            @memcpy(self.content_type[0..n], value[0..n]);
            self.content_type_len = n;
        }

        // Two halves of one buffer, so a message read second does not land on
        // top of the first.
        while (true) {
            const out = if (self.messages == 0)
                self.side.out[0..4096]
            else
                self.side.out[4096..8192];
            const message = exchange.nextMessage(out) catch {
                self.failed.* = true;
                return;
            };
            if (message.len == 0) {
                self.ended = self.messages;
                break;
            }
            if (self.messages == 0) self.first_len = message.len;
            if (self.messages == 1) self.second_len = message.len;
            self.messages += 1;
            if (self.messages == 2) break;
        }
        self.got.* = true;
    }
};

/// POSTs one message with `transfer-encoding: chunked`, then POSTs a second
/// message on the same connection.
///
/// Chunked is a legal framing and one this transport does not read, so the
/// first request is answered rather than served. The second request is the
/// proof that the refusal left the connection in step: a body the server read
/// past, or one it never drained, leaves the next request head to be parsed
/// out of chunk data.
const Chunked = struct {
    io: Io,
    http: *http.Client,
    endpoint: *const Endpoint,
    side: *Side,
    /// The status the chunked request came back with.
    first: std.http.Status = .ok,
    /// The answer to the request after it, which is proof that one was served.
    answer: ?Reply = null,
    failed: *bool,

    fn run(self: *@This()) void {
        var client = openClient(self.http, self.endpoint) orelse {
            self.failed.* = true;
            return;
        };
        const spec: PostHeaders = .{ .method = "tools/list" };
        const headers = client.requestHeaders(spec, &self.side.head) catch {
            self.failed.* = true;
            return;
        };
        var request = self.http.request(.POST, client.uri, .{
            .extra_headers = headers,
            .headers = .{
                .content_type = .{ .override = mcp.uri_and_media.json_media_type },
                .accept_encoding = .omit,
            },
            .redirect_behavior = .not_allowed,
            .connection = client.connection,
        }) catch {
            self.failed.* = true;
            return;
        };
        // This request is not deinited: the connection belongs to this task
        // and the request after it goes out on the same one.
        request.transfer_encoding = .{ .chunked = {} };
        var out = request.sendBodyUnflushed(&self.side.transfer) catch {
            self.failed.* = true;
            return;
        };
        out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}") catch {
            self.failed.* = true;
            return;
        };
        // `end` writes the last chunk and flushes, so the whole request is on
        // the wire before the reply is waited for.
        out.end() catch {
            self.failed.* = true;
            return;
        };
        var response = request.receiveHead(&.{}) catch {
            self.failed.* = true;
            return;
        };
        self.first = response.head.status;
        // The reply body is drained here rather than by `deinit`, because the
        // connection is reused rather than released. The refusal carries no
        // body, so what is expected to be discarded is nothing: a zero
        // `content-length` is at its end before the first read.
        _ = response.reader(&self.side.transfer).discardRemaining() catch {
            self.failed.* = true;
            return;
        };

        self.answer = client.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", spec, &self.side.head, .{
            .transfer = &self.side.transfer,
            .out = &self.side.out,
            .decode = &self.side.decode,
        }) catch {
            self.failed.* = true;
            return;
        };
    }
};

/// Answers one POST with a stream and then keeps sending on it.
///
/// This is the `subscriptions/listen` shape: the result arrives first and the
/// notifications the subscription was opened for follow on the same reply, so
/// a server that can only answer once is not answering that method at all.
const Subscribe = struct {
    io: Io,
    listener: *Io.net.Server,
    side: *Side,
    handler: conn.Handler,
    /// Sent after the result, in this order.
    notifications: []const []const u8,
    sent: *usize,
    failed: *bool,

    fn run(self: *@This()) void {
        const stream = self.listener.accept(self.io) catch {
            self.failed.* = true;
            return;
        };
        defer stream.close(self.io);
        self.side.stream = stream;
        self.side.stream_reader =
            Io.net.Stream.Reader.init(stream, self.io, &self.side.reader_buffer);
        self.side.stream_writer =
            Io.net.Stream.Writer.init(stream, self.io, &self.side.writer_buffer);
        self.side.server = Server.init(
            &self.side.stream_reader.interface,
            &self.side.stream_writer.interface,
            .{
                .params = &self.side.params,
                .head_scratch = &self.side.head_scratch,
                .body = &self.side.body,
                .body_scratch = &self.side.body_scratch,
                .handler_scratch = &self.side.handler_scratch,
                .transfer = &self.side.transfer,
                .event = &self.side.event,
                .stream = &self.side.stream_buffer,
            },
        );

        const post = self.side.server.receive() catch {
            self.failed.* = true;
            return;
        } orelse {
            self.failed.* = true;
            return;
        };
        const dispatch = self.handler.call orelse {
            self.failed.* = true;
            return;
        };
        const result = dispatch(
            self.handler.ctx,
            post.body,
            self.side.server.buffers.handler_scratch,
        ) catch {
            self.failed.* = true;
            return;
        };
        var out = self.side.server.respondStream(post) catch {
            self.failed.* = true;
            return;
        };
        out.send(self.side.server.buffers.event, result orelse return) catch {
            self.failed.* = true;
            return;
        };
        self.sent.* = 1;

        for (self.notifications) |notification| {
            out.send(self.side.server.buffers.event, notification) catch {
                self.failed.* = true;
                return;
            };
            self.sent.* += 1;
        }
        out.close() catch {
            self.failed.* = true;
            return;
        };
    }
};

fn openClient(http_client: *http.Client, endpoint: *const Endpoint) ?Client {
    const uri = std.Uri.parse(endpoint.uri_text) catch return null;
    // The connection is opened here and handed over, rather than left to the
    // URI. A TLS session and a proxied connection are both reachable only this
    // way, and a test that went through the pool would not cover the field at
    // all.
    const host = Io.net.HostName.init("127.0.0.1") catch return null;
    const connection = http_client.connectTcp(host, endpoint.port(), .plain) catch
        return null;
    var client = Client.init(http_client, uri, .current);
    client.connection = connection;
    return client;
}

test "one POST over a real socket is answered with a single JSON body" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var answer: Answer = .{};
    var reply: Reply = undefined;
    var got = false;
    var failed = false;
    var answered: usize = 0;
    var revision: ?mcp.Revision = null;
    var statuses = [_]std.http.Status{.ok};

    var group: Io.Group = .init;
    // One group drives both sides. Two would deadlock: the client blocks
    // waiting for an answer only the server's task can produce.
    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .shape = .single,
        .count = 1,
        .statuses = &statuses,
        .answered = &answered,
        .revision = &revision,
        .failed = &failed,
    };
    var call = Call{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\"," ++
            "\"params\":{\"name\":\"echo\"}}",
        .spec = .{ .method = "tools/call", .name = "echo" },
        .id = 7,
        .reply = &reply,
        .got = &got,
        .failed = &failed,
    };
    group.async(io, Serve.run, .{&serve});
    group.async(io, Call.run, .{&call});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(got);
    try testing.expectEqual(@as(usize, 1), answered);
    try testing.expectEqual(std.http.Status.ok, statuses[0]);

    // The answer really came back over the socket and was matched by the id
    // the request carried, so a response for another call could not have been
    // mistaken for this one.
    try testing.expectEqual(@as(?i32, null), reply.error_code);
    try testing.expectEqualStrings("{\"resultType\":\"complete\"}", reply.body);
    try testing.expect(!reply.streamed);

    // The body really crossed the socket and was decoded on the far side.
    try testing.expectEqual(@as(usize, 1), answer.calls);
    try testing.expectEqualStrings("tools/call", answer.method_buffer[0..answer.method_len]);

    // The revision really came off the header rather than being assumed.
    try testing.expectEqual(mcp.Revision.current, revision.?);
}

test "a request carrying the removed session id is refused, and nothing is echoed" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var answer: Answer = .{};
    var got = false;
    var failed = false;
    var refused = false;
    var answered: usize = 0;
    var statuses = [_]std.http.Status{.ok};

    var group: Io.Group = .init;
    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .shape = .single,
        .count = 1,
        .refuse_first = error.UnsupportedVersion,
        .refused = &refused,
        .statuses = &statuses,
        .answered = &answered,
        .failed = &failed,
    };
    var listen = Listen{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
        .spec = .{
            .method = "tools/list",
            // A peer that sends the header this revision removed is speaking an
            // earlier revision, and the answer must carry no identifier either.
            .extra = &.{
                .{ .name = mcp.header_name.session_id, .value = "5eed" },
            },
        },
        .status = .ok,
        .got = &got,
        .failed = &failed,
    };
    group.async(io, Serve.run, .{&serve});
    group.async(io, Listen.run, .{&listen});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(got);
    try testing.expect(refused);
    // The request really did carry the removed header, so the refusal below is
    // about that header and not about something the peer never sent.
    const head = server_side.server.request.?.head_buffer;
    var iterator = http.HeaderIterator.init(head);
    var sent = false;
    while (iterator.next()) |field| {
        if (mcp.headerKind(field.name) == .session_id_removed) sent = true;
    }
    try testing.expect(sent);
    // The peer is told the request is one this revision does not speak, the
    // handler never saw it, and the answer minted no session of its own.
    try testing.expectEqual(std.http.Status.bad_request, listen.status);
    try testing.expectEqual(@as(usize, 0), answer.calls);
    try testing.expectEqual(@as(usize, 0), answered);
    try testing.expect(!listen.session_echoed);
    try testing.expectEqual(@as(usize, 0), listen.messages);
}

test "a chunked POST is refused, and the connection still serves the request after it" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var answer: Answer = .{};
    var failed = false;
    var refused = false;
    var answered: usize = 0;
    var statuses = [_]std.http.Status{ .ok, .ok };

    var group: Io.Group = .init;
    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .shape = .single,
        .count = 2,
        .refuse_first = error.MalformedRequest,
        .refused = &refused,
        .statuses = &statuses,
        .answered = &answered,
        .failed = &failed,
    };
    var chunked = Chunked{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .failed = &failed,
    };
    group.async(io, Serve.run, .{&serve});
    group.async(io, Chunked.run, .{&chunked});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(refused);
    // The body was never read, so the request was refused on the framing this
    // transport does not read rather than served as an empty one.
    try testing.expectEqual(std.http.Status.bad_request, chunked.first);
    // The request after it was answered on the same connection, which is the
    // proof that the refusal left nothing on the socket for the next request
    // head to be parsed out of.
    try testing.expectEqual(std.http.Status.ok, chunked.answer.?.status);
    // Two requests came off this connection and one of them was answered. The
    // count is not the loop position: a refused request skips it, and a
    // counter that recorded the position would report a served request as two
    // answers the moment a refusal shares the connection with it.
    try testing.expectEqual(@as(usize, 1), answered);
    // Only the second request reached a handler, and it was the one the client
    // asked for.
    try testing.expectEqual(@as(usize, 1), answer.calls);
    try testing.expectEqualStrings("tools/list", answer.method_buffer[0..answer.method_len]);
    try testing.expectEqualStrings("{\"resultType\":\"complete\"}", chunked.answer.?.body);
}

test "the same request is answered as a stream when the client accepts one" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var answer: Answer = .{};
    var got = false;
    var failed = false;
    var answered: usize = 0;
    var statuses = [_]std.http.Status{.ok};

    var group: Io.Group = .init;
    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .shape = .stream,
        .count = 1,
        .statuses = &statuses,
        .answered = &answered,
        .failed = &failed,
    };
    var listen = Listen{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"subscriptions/listen\"}",
        .spec = .{ .method = "subscriptions/listen" },
        .status = .ok,
        .got = &got,
        .failed = &failed,
    };
    group.async(io, Serve.run, .{&serve});
    group.async(io, Listen.run, .{&listen});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(got);
    try testing.expectEqual(@as(usize, 1), answered);
    // The reply was a stream, and the client read the message off it and then
    // found the end of it. A server that had answered with a body instead
    // would have produced `streamed == false` and one whole-body read.
    try testing.expect(listen.streamed);
    try testing.expectEqual(@as(usize, 1), listen.messages);
    try testing.expectEqual(@as(usize, 1), listen.ended);
    // The media type really was the event stream and not a JSON body. The
    // status is 200 either way, so this is the only thing that tells a client
    // which of the two it is holding.
    try testing.expectEqualStrings(
        mcp.uri_and_media.event_stream_media_type,
        listen.content_type[0..listen.content_type_len],
    );
    // The message really arrived as one event and is the response for the id
    // the request carried, so the framing was undone rather than guessed at.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resultType\":\"complete\"}}",
        client_side.out[0..listen.first_len],
    );
}

test "a notification POST is answered 202 with no body" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var answer: Answer = .{};
    var got = false;
    var failed = false;
    var answered: usize = 0;
    var statuses = [_]std.http.Status{.ok};

    var group: Io.Group = .init;
    var serve = Serve{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .shape = .single,
        .count = 1,
        .statuses = &statuses,
        .answered = &answered,
        .failed = &failed,
    };
    var listen = Listen{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"," ++
            "\"params\":{\"progress\":1}}",
        .spec = .{ .method = "notifications/progress" },
        .status = .ok,
        .got = &got,
        .failed = &failed,
    };
    group.async(io, Serve.run, .{&serve});
    group.async(io, Listen.run, .{&listen});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(got);
    // The handler saw the notification, which is how a server learns of it, and
    // the answer is the one the specification names: accepted, no body.
    try testing.expectEqual(@as(usize, 1), answer.calls);
    try testing.expectEqualStrings(
        "notifications/progress",
        answer.method_buffer[0..answer.method_len],
    );
    try testing.expectEqual(std.http.Status.accepted, statuses[0]);
    try testing.expectEqual(std.http.Status.accepted, listen.status);
    try testing.expectEqual(@as(usize, 0), listen.messages);
}

test "a GET to the endpoint is 405, because this revision serves POST only" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var got = false;
    var failed = false;
    var status: std.http.Status = .ok;
    var rejected: bool = false;

    const Reject = struct {
        io: Io,
        listener: *Io.net.Server,
        side: *Side,
        status: *std.http.Status,
        rejected: *bool,
        failed: *bool,

        fn run(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            defer stream.close(self.io);
            self.side.stream = stream;
            self.side.stream_reader =
                Io.net.Stream.Reader.init(stream, self.io, &self.side.reader_buffer);
            self.side.stream_writer =
                Io.net.Stream.Writer.init(stream, self.io, &self.side.writer_buffer);
            self.side.server = Server.init(
                &self.side.stream_reader.interface,
                &self.side.stream_writer.interface,
                .{
                    .params = &self.side.params,
                    .head_scratch = &self.side.head_scratch,
                    .body = &self.side.body,
                    .body_scratch = &self.side.body_scratch,
                    .handler_scratch = &self.side.handler_scratch,
                    .transfer = &self.side.transfer,
                    .event = &self.side.event,
                    .stream = &self.side.stream_buffer,
                },
            );
            // A GET has no body to check headers against, so the method is
            // refused on its own, before anything is read.
            _ = self.side.server.receive() catch |err| {
                if (err != error.MethodNotAllowed) {
                    self.failed.* = true;
                    return;
                }
                self.side.server.reject(.method_not_allowed, "") catch {
                    self.failed.* = true;
                    return;
                };
                self.status.* = .method_not_allowed;
                self.rejected.* = true;
                return;
            };
            self.failed.* = true;
        }
    };

    var group: Io.Group = .init;
    var serve = Reject{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .status = &status,
        .rejected = &rejected,
        .failed = &failed,
    };
    const Probe = struct {
        io: Io,
        http: *http.Client,
        endpoint: *const Endpoint,
        status: *std.http.Status,
        got: *bool,
        failed: *bool,

        fn run(self: *@This()) void {
            const uri = std.Uri.parse(self.endpoint.uri_text) catch {
                self.failed.* = true;
                return;
            };
            // No connection handed over, so this is the path a client takes
            // when the pool dials from the URI.
            var request = self.http.request(.GET, uri, .{
                .keep_alive = false,
            }) catch {
                self.failed.* = true;
                return;
            };
            defer request.deinit();
            request.sendBodiless() catch {
                self.failed.* = true;
                return;
            };
            const response = request.receiveHead(&.{}) catch {
                self.failed.* = true;
                return;
            };
            self.status.* = response.head.status;
            self.got.* = true;
        }
    };
    var probe = Probe{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .status = &status,
        .got = &got,
        .failed = &failed,
    };
    group.async(io, Reject.run, .{&serve});
    group.async(io, Probe.run, .{&probe});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(got);
    try testing.expect(rejected);
    try testing.expectEqual(std.http.Status.method_not_allowed, status);
}

test "a stream keeps delivering after the result, which is what a subscription is" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var answer: Answer = .{};
    var got = false;
    var failed = false;
    var sent: usize = 0;
    const notifications = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tasks\"," ++
            "\"params\":{\"taskId\":\"t1\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"," ++
            "\"params\":{\"progress\":1}}",
    };

    var group: Io.Group = .init;
    var serve = Subscribe{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .notifications = &notifications,
        .sent = &sent,
        .failed = &failed,
    };
    var listen = Listen{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"subscriptions/listen\"," ++
            "\"params\":{\"resourceSubscriptions\":[\"file:///a\"]}}",
        .spec = .{ .method = "subscriptions/listen" },
        .status = .ok,
        .got = &got,
        .failed = &failed,
    };
    group.async(io, Subscribe.run, .{&serve});
    group.async(io, Listen.run, .{&listen});
    group.await(io) catch {};

    try testing.expect(!failed);
    try testing.expect(got);
    // Three messages went out and three came back, in order. A server that
    // answered once and closed would have delivered the result and nothing
    // else, which is the whole reason the stream exists.
    try testing.expectEqual(@as(usize, 3), sent);
    try testing.expectEqual(@as(usize, 2), listen.messages);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"resultType\":\"complete\"}}",
        client_side.out[0..listen.first_len],
    );
    try testing.expectEqualStrings(
        notifications[0],
        client_side.out[4096..][0..listen.second_len],
    );
}

test "a body larger than the caller's buffer is refused, not grown for" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client: http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http_client.deinit();

    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    var client_side: Side = .{};
    var got = false;
    var failed = false;
    var rejected = false;
    // The server's body buffer is 4096, and this is larger than that by a wide
    // margin, so a server that grew to fit would be a server a peer decides
    // how much memory it uses.
    var big: [6000]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &big,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{{\"pad\":\"{s}\"}}}}",
        .{"x" ** 5900},
    );

    const Refuse = struct {
        io: Io,
        listener: *Io.net.Server,
        side: *Side,
        rejected: *bool,
        failed: *bool,

        fn run(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch {
                self.failed.* = true;
                return;
            };
            defer stream.close(self.io);
            self.side.stream = stream;
            self.side.stream_reader =
                Io.net.Stream.Reader.init(stream, self.io, &self.side.reader_buffer);
            self.side.stream_writer =
                Io.net.Stream.Writer.init(stream, self.io, &self.side.writer_buffer);
            self.side.server = Server.init(
                &self.side.stream_reader.interface,
                &self.side.stream_writer.interface,
                .{
                    .params = &self.side.params,
                    .head_scratch = &self.side.head_scratch,
                    .body = &self.side.body,
                    .body_scratch = &self.side.body_scratch,
                    .handler_scratch = &self.side.handler_scratch,
                    .transfer = &self.side.transfer,
                    .event = &self.side.event,
                    .stream = &self.side.stream_buffer,
                },
            );
            _ = self.side.server.receive() catch |err| {
                if (err != error.BodyTooLarge) {
                    self.failed.* = true;
                    return;
                }
                // The peer sent more than this server will hold, so the size
                // is a failure the peer is told about rather than one it can
                // push past.
                self.side.server.reject(.payload_too_large, "") catch {
                    self.failed.* = true;
                    return;
                };
                self.rejected.* = true;
                return;
            };
            self.failed.* = true;
        }
    };

    var group: Io.Group = .init;
    var serve = Refuse{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .rejected = &rejected,
        .failed = &failed,
    };
    var reply: Reply = undefined;
    var client_failed = false;
    var call = Call{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = body,
        .spec = .{ .method = "tools/list" },
        .id = 1,
        .reply = &reply,
        .got = &got,
        .failed = &client_failed,
    };
    group.async(io, Refuse.run, .{&serve});
    group.async(io, Call.run, .{&call});
    group.await(io) catch {};

    // The server refused the size and said so, and the client was told the
    // request went unanswered rather than being handed a truncated result.
    try testing.expect(rejected);
    try testing.expect(client_failed);
    try testing.expect(!got);
}
