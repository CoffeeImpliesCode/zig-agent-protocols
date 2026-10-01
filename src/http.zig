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
//! [`Headers.removed`] records which of the two a peer sent, and both bits are
//! set when a peer sent both, because the two decide independently. A request
//! that carried `Mcp-Session-Id` is refused, whichever of the two arrived
//! first, because PROTOCOLS.md 4.2 says a peer that sends it is not speaking
//! this revision. The HTTP+SSE transport,
//! deprecated in `2025-03-26`, is not implemented at all (section 9).
//!
//! ## What is decided here rather than in the caller
//!
//! The header rules are the substance of this layer, so they are enforced
//! here instead of being left to whoever writes the server: the revision
//! header, `Mcp-Method` and `Mcp-Name` checked against the body, and the
//! `params._meta` declaration of the revision that PROTOCOLS.md 4.3 records as
//! carried on every request — so a client request that does not declare it is
//! refused rather than served. `Content-Type`, `Accept`, a repeated
//! MCP-defined header, and `Mcp-Session-Id`, which this revision removed and
//! which therefore refuses the request. A gateway that routes on
//! `Mcp-Method` without checking it against the body is the failure this file
//! exists to prevent.
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
    /// transport accepts.
    ///
    /// `research/normative/mcp-2026-07-28.md` §4, "Other HTTP mechanics", puts
    /// header validation and a malformed request under `400 Bad Request`.
    MalformedRequest,
    /// A header arrived more than once, which covers the MCP-defined ones,
    /// one `Mcp-Param-{Name}` annotation sent twice, and a repeated `Accept`,
    /// `Content-Type`, `Origin` or `Authorization`.
    ///
    /// HTTP permits a repeated header and the specification is silent, but two
    /// values for a header that is checked against the body leaves the check
    /// ambiguous: a gateway and a library can disagree about which one the
    /// body was compared to, and they would then route and validate one
    /// request two different ways. A derived header is checked against
    /// `arguments` the same way, one annotation at a time, by
    /// [`Post.checkParam`].
    ///
    /// RFC 9110 §5.3 would have a recipient join the field lines of a
    /// list-valued header in the order they arrived. This refuses instead,
    /// which is the same rule as for the headers above rather than a second
    /// one beside it: joining them needs a buffer this library does not have,
    /// and `Origin` and `Authorization` are not list fields, so two of them
    /// are two requests whatever the joining rule says.
    DuplicateHeader,
    /// The peer is not speaking a revision this library decodes: it named one
    /// this library does not know in `MCP-Protocol-Version`, or it sent
    /// `Mcp-Session-Id`, which PROTOCOLS.md 4.2 says a peer sends only when it
    /// speaks a revision older than `2026-07-28`.
    /// `research/normative/mcp-2026-07-28.md` §4 pairs an unsupported or
    /// unknown version with `UnsupportedProtocolVersionError` (`-32022`) and
    /// `400 Bad Request`.
    UnsupportedVersion,
    /// A header the specification requires is absent.
    MissingHeader,
    /// A header value disagrees with the body value it duplicates, or a value
    /// is not even decodable.
    ///
    /// `research/normative/mcp-2026-07-28.md` §4 pairs a `MCP-Protocol-Version`
    /// that disagrees with `_meta` — and a `Mcp-Method` or `Mcp-Name` that
    /// disagrees with the body — with `HeaderMismatch` (`-32020`) and
    /// `400 Bad Request`.
    HeaderMismatch,
    /// A peer sent `x-mcp-header`, which PROTOCOLS.md 4.2 states is a JSON
    /// Schema keyword and not a header a client sends.
    NotAHeader,
    /// The HTTP method is not one this transport serves.
    ///
    /// `2026-07-28` keeps only POST, and `research/normative/mcp-2026-07-28.md`
    /// §4 pairs a GET or a DELETE to the endpoint with `405 Method Not
    /// Allowed`.
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
    /// The reply carried no bytes at all: the body ended with nothing in it.
    ///
    /// Distinct from a body that arrived and was not one this transport can
    /// read, which is a [`Reply`] with its status and `answered` false. There
    /// is a status here too, but a peer that answered with an empty body has
    /// said nothing this call can be matched against, and the caller has no
    /// message to read either way.
    NoResponse,
} || DecodeError || conn.Error;

// --- Response media types -------------------------------------------------------

/// The two response types a Streamable HTTP reply may have.
///
/// `research/normative/mcp-2026-07-28.md` §4 requires the server to return one
/// of them and the client to support both, so this is an enum of two rather
/// than a set of strings.
pub const MediaType = enum {
    json,
    event_stream,
};

/// The `Accept` value a client must send on every POST.
///
/// `research/normative/mcp-2026-07-28.md` §4: the client "MUST include an
/// `Accept` header listing both `application/json` and `text/event-stream` as
/// supported content types".
pub const accept_value = mcp.uri_and_media.json_media_type ++
    ", " ++ mcp.uri_and_media.event_stream_media_type;

/// The media type a `Content-Type` or `Accept` value names.
///
/// Parameters after the type are ignored, so `application/json; charset=utf-8`
/// is the type it names. A value that names neither of the two is null rather
/// than a guess.
pub fn mediaType(value: []const u8) ?MediaType {
    const end = std.mem.findScalar(u8, value, ';') orelse value.len;
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
///
/// The entry that decides a type is the most specific one that matches it,
/// because RFC 9110 §12.5.1 gives precedence to the most specific reference
/// and says a less specific range never re-admits what a more specific one
/// refused. `*/*, application/json;q=0` is therefore a request for a stream
/// and not one that also accepts a JSON body.
pub fn parseAccept(value: ?[]const u8) Accept {
    const text = value orelse return .{};
    if (std.mem.trim(u8, text, " \t").len == 0) return .{};
    var accept: Accept = .{ .present = true, .json = false, .event_stream = false };
    // The deciding entry for each of the two types, and null where nothing
    // matched. An entry that arrives later replaces one that is less specific
    // and never one that is not: two entries of the same specificity are read
    // as one entry, which is what the order they arrived in can decide.
    var decided = [_]?Decision{ null, null };
    var entries = std.mem.splitSequence(u8, text, ",");
    while (entries.next()) |entry| {
        const one = std.mem.trim(u8, entry, " \t");
        // The parameters are read before the type, because one of them decides
        // whether the entry counts at all. `mediaType` drops them, so an entry
        // that arrived as `application/json;q=0` would otherwise be read as a
        // request for the one type this transport answers most.
        const stop = std.mem.findScalar(u8, one, ';') orelse one.len;
        const refused = refusedByQuality(one[stop..]);
        const bare = std.mem.trim(u8, one[0..stop], " \t");
        const slash = std.mem.findScalar(u8, bare, '/') orelse continue;
        const major = bare[0..slash];
        const minor = bare[slash + 1 ..];
        for (&decided, 0..) |*slot, index| {
            const rank = precedence(major, minor, @enumFromInt(index)) orelse continue;
            if (slot.* == null or rank > slot.*.?.rank) {
                slot.* = .{ .rank = rank, .allowed = !refused };
            }
        }
    }
    accept.json = if (decided[0]) |decision| decision.allowed else false;
    accept.event_stream = if (decided[1]) |decision| decision.allowed else false;
    return accept;
}

/// The entry that decides one of the two types an `Accept` header can name.
const Decision = struct {
    /// How specific the deciding entry is.
    rank: u2,
    /// Whether that entry admits the type.
    allowed: bool,
};

/// How specific a media range is over one of the two types this transport
/// answers with, or null when the range does not cover it.
///
/// RFC 9110 §12.5.1 orders precedence as a concrete type, then `type/*`, then
/// `*/*`, and the order is what decides which entry sets the quality. One
/// range can cover both of this transport's types at once, so this is asked
/// once per type rather than once per range. A parameter is not part of the
/// rank: the two types this transport answers with carry none, so the cases a
/// parameter would distinguish are not cases it can be asked about.
///
/// `*/*` is the only range whose `*` is the type. RFC 9110 §12.5.1 spells that
/// one out literally as `"*/*"` rather than as `type "/" "*"`, and the text
/// beside it names `*/*` and `type/*` as the two wildcards there are. A `*` as
/// the type beside any other subtype is neither of them, so `*/json` names no
/// range this transport can match and is skipped like any other entry that
/// names none: reading it as covering both types is how a client that listed
/// only `*/event-stream` was answered `Content-Type: application/json`.
fn precedence(major: []const u8, minor: []const u8, kind: MediaType) ?u2 {
    if (std.mem.eql(u8, major, "*")) {
        return if (std.mem.eql(u8, minor, "*")) 0 else null;
    }
    const name: []const u8 = switch (kind) {
        .json => mcp.uri_and_media.json_media_type,
        .event_stream => mcp.uri_and_media.event_stream_media_type,
    };
    const slash = std.mem.findScalar(u8, name, '/') orelse return null;
    if (!std.ascii.eqlIgnoreCase(major, name[0..slash])) return null;
    if (std.mem.eql(u8, minor, "*")) return 1;
    if (!std.ascii.eqlIgnoreCase(minor, name[slash + 1 ..])) return null;
    return 2;
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
        const equals = std.mem.findScalar(u8, one, '=') orelse continue;
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

/// Which of the two headers `2026-07-28` removed a peer sent.
///
/// Two independent bits rather than one first-wins optional, because the two
/// are independent verdicts: PROTOCOLS.md 4.2 refuses a request that carried
/// `Mcp-Session-Id` and says nothing of one that carried `Last-Event-ID`, so
/// whichever of the two arrived last must not be able to decide the verdict.
pub const Removed = struct {
    /// `Mcp-Session-Id` arrived, which PROTOCOLS.md 4.2 refuses.
    session_id: bool = false,
    /// `Last-Event-ID` arrived, which PROTOCOLS.md 4.2 removed without saying
    /// a peer sending it is not speaking this revision.
    last_event_id: bool = false,

    /// Whether the peer sent neither, which is what `readHeaders` starts from.
    pub fn none(self: Removed) bool {
        return !self.session_id and !self.last_event_id;
    }
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
    /// `Origin` is not MCP's, but `research/normative/mcp-2026-07-28.md` §4
    /// requires a server to validate it, so it is carried through rather than
    /// dropped.
    origin: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    /// A header removed at `2026-07-28` arrived, and which of the two.
    ///
    /// Recorded because a caller can then see that a peer sent a header this
    /// revision has no use for. It is never echoed, and this transport mints
    /// no identifier. [`checkPost`] refuses a request that carried
    /// `Mcp-Session-Id` and serves one that carried only `Last-Event-ID`,
    /// because PROTOCOLS.md 4.2 says only of the first that a peer sending it
    /// is not speaking this revision.
    removed: Removed = .{},
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
/// is case-insensitive: PROTOCOLS.md 4.2 spells the version header all-caps
/// and every other one title-case, and both spellings are required, so a
/// table keyed on either casing would be wrong.
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
    var cursor: Cursor = .{ .buffer = scratch };

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
            // RFC 9110 §5.3 would have a recipient join the field lines of a
            // list-valued header in the order they arrived, and this one
            // refuses instead. The rule is the one the MCP-defined headers
            // above already follow and for the same reason: a gateway that
            // joined them and a library that read the last one would answer
            // one request two different ways, and there is no buffer here to
            // join into without a caller-sized one. `Origin` and
            // `Authorization` settle it: neither is a list, so two of them
            // are two requests, and a rule that covers all four is one rule.
            .accept => {
                if (headers.accept != null) return error.DuplicateHeader;
                headers.accept = field.value;
            },
            .content_type => {
                if (headers.content_type != null) return error.DuplicateHeader;
                headers.content_type = field.value;
            },
            .origin => {
                if (headers.origin != null) return error.DuplicateHeader;
                headers.origin = field.value;
            },
            .authorization => {
                if (headers.authorization != null) return error.DuplicateHeader;
                headers.authorization = field.value;
            },
            .session_id_removed => {
                // Never read into a field and never echoed. Recorded so a
                // caller can see that a peer sent a header this revision
                // removed, and so `checkPost` can refuse the request.

                // Its own bit and not a slot the two headers share, so a peer
                // that wrote `Last-Event-ID` first cannot hide the
                // `Mcp-Session-Id` that refuses the request. Neither is a
                // first-wins record, so there is no order left to get wrong.
                headers.removed.session_id = true;
            },
            .last_event_id_removed => headers.removed.last_event_id = true,
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

/// A POST that passed every header rule PROTOCOLS.md 4.2 and
/// `research/normative/mcp-2026-07-28.md` §4 state.
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
    /// The JSON-RPC method.
    /// `research/normative/mcp-2026-07-28.md` §4 says header *names* compare
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
    /// `research/normative/mcp-2026-07-28.md` §4 requires one on every request,
    /// and a credential does not belong in a struct a caller might log.
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
    /// PROTOCOLS.md 4.2 and it is not restated here. `body_value` is the value
    /// the tool's own `inputSchema` declares, which only the tool's dispatcher
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
/// `research/normative/mcp-2026-07-28.md` §4 requires `Mcp-Name` for
/// `tools/call`, `resources/read` and `prompts/get` and names no other method.
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
    // of that header. A request that sent both is refused either way: the bit
    // is read on its own, so which of the two the peer wrote first cannot
    // decide the verdict.
    if (headers.removed.session_id) return error.UnsupportedVersion;

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

    // The revision is claimed twice: once in the header and once in the body.
    // `MCP-Protocol-Version` is what a gateway routes on and `_meta` is what a
    // handler reads, so a request that makes the claim two different ways
    // cannot be served at whichever one this library happened to read.
    // `research/normative/mcp-2026-07-28.md` §4 grades that disagreement as
    // `HeaderMismatch` (`-32020`) on `400 Bad Request`, and this is that
    // error.

    // The claim also has to be made at all. PROTOCOLS.md 4.3 records
    // `io.modelcontextprotocol/protocolVersion` as carried "on every request",
    // PROTOCOLS.md 2 says a field the specification marks required but the
    // peer omits is a decode error, and
    // `research/normative/mcp-2026-07-28.md` §2 grades the key
    // `Required: Yes` on every client request `_meta` with "Missing ⇒ `-32602`
    // on HTTP `400 Bad Request`", which §4 restates as a Server MUST. So a
    // request whose `params` carries no `_meta` at all, an empty one, or one
    // without the key is a request missing a required `_meta` field, and
    // `MissingField` is the member that says exactly that — as distinct from
    // `HeaderMismatch`, which is a value that is there and disagrees. The
    // three null cases were served before, and none of them is a claim this
    // library can check.

    // A notification is not a request. The same table grades the key on
    // "every client request `_meta`", and PROTOCOLS.md 4.3 says "on every
    // request", so a POST carrying a notification is not required to declare
    // the revision — and one that declares it is still checked against the
    // header, because a disagreement is a disagreement whatever the message
    // carries.
    const body_revision = metaRevision(message.params, scratch) catch |err| switch (err) {
        // The caller's `scratch`, not the peer's request. `jsonrpc.decode` two
        // lines above propagates the same shortage as `BufferTooSmall`, and a
        // `400` here would blame the peer for a fault only the caller can fix.
        error.BufferTooSmall => return error.BufferTooSmall,
        else => return error.MalformedRequest,
    };
    if (body_revision) |value| {
        if (!std.mem.eql(u8, revision.string(), value)) return error.HeaderMismatch;
    } else if (message.kind != .notification) {
        return error.MissingField;
    }

    var name: ?[]const u8 = null;
    if (requiresName(method)) {
        // Bound rather than unwrapped a second time: the header is the peer's
        // own text, so it is read once into a value that cannot be null and
        // compared from there.
        const header_name = headers.name orelse return error.MissingHeader;
        const from_body = nameFromParams(method, message.params, scratch) catch |err| switch (err) {
            // The same caller's buffer as above, and the same reason: this
            // shortage is not the peer's request and must not be reported as
            // one.
            error.BufferTooSmall => return error.BufferTooSmall,
            else => return error.MalformedRequest,
        };
        const claimed = from_body orelse return error.HeaderMismatch;
        if (!std.mem.eql(u8, header_name, claimed)) return error.HeaderMismatch;
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

/// The `name` or `uri` an `Mcp-Name` header must agree with, which the method
/// decides rather than the reader.
///
/// `research/normative/mcp-2026-07-28.md` §4 names `params.name` or
/// `params.uri` as the source, and the schema of the three methods that
/// require the header binds one of them each: `tools/call` and `prompts/get`
/// carry `name`, `resources/read` carries `uri`. Reading either for every
/// method would accept a `tools/call` whose params name a resource and answer
/// it as the tool the header claimed, which is the request-splitting this
/// header exists to prevent. The `params` member is passed in as the raw JSON
/// the base layer already isolated, so this reads one member of it rather
/// than re-deriving where it begins and ends.
fn nameFromParams(
    method: []const u8,
    params: jsonrpc.Params,
    scratch: []u8,
) DecodeError!?[]const u8 {
    const text = switch (params) {
        .absent, .null_value => return null,
        .value => |raw| raw,
    };
    const wanted = if (std.mem.eql(u8, method, "resources/read")) "uri" else "name";

    var reader = json.Reader.init(text);
    // An empty object names nothing, which the caller reports as a header
    // claiming a value the body does not carry. A `params` that is not an
    // object at all fails inside `beginObject`, and a malformed body must not
    // be reported as a header disagreement.
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, wanted)) {
            const value = try reader.string(scratch);
            return value;
        }
        try reader.skipValue(scratch);
    }
    return null;
}

/// The revision the body's `_meta` declares, or null when it declares none.
///
/// `research/normative/mcp-2026-07-28.md` §4 requires the value to match the
/// `MCP-Protocol-Version` header, and PROTOCOLS.md 4.3 names the key. The walk
/// reads one member of an object the base layer already isolated and stops at
/// the key rather than modelling the rest of `_meta`, which belongs to
/// `mcp.zig`.
fn metaRevision(params: jsonrpc.Params, scratch: []u8) DecodeError!?[]const u8 {
    const text = switch (params) {
        .absent, .null_value => return null,
        .value => |raw| raw,
    };

    var reader = json.Reader.init(text);
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |key| {
        if (!std.mem.eql(u8, key, "_meta")) {
            try reader.skipValue(scratch);
            continue;
        }
        // The key lives under `_meta`, so the walk goes on inside it rather
        // than back out to `params`.
        if (try reader.beginObject()) return null;
        while (try reader.nextKey(scratch)) |inner| {
            if (!std.mem.eql(u8, inner, mcp.meta_key.protocol_version)) {
                try reader.skipValue(scratch);
                continue;
            }
            const value = try reader.string(scratch);
            return value;
        }
        return null;
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

/// Read one line of an event stream, or null at the end of the stream.
///
/// The format ends a line with CR, LF or CRLF, and none of the three is part
/// of the line. `out` bounds the line, so a line longer than the caller's
/// event buffer is reported rather than truncated and the reader's own
/// buffer never becomes the bound.
///
/// A partial line the stream ended inside is not a line: the event stream
/// algorithm never dispatched it, so there is nothing to hand back.
fn readLine(reader: *Io.Reader, out: []u8) Error!?usize {
    var len: usize = 0;
    while (true) {
        // A byte is the least a fill can be asked for and the reader keeps
        // whatever else the stream sent with it, so the terminator is looked
        // for in what is buffered rather than a byte at a time.
        const buffered = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return error.Transport,
        };
        // CR, LF and CRLF each end a line and a stream mixes them, so the
        // search is for either and the length is where it was not found.
        const at = std.mem.indexOfAny(u8, buffered, "\r\n") orelse buffered.len;
        if (at > out.len - len) return error.BufferTooSmall;
        @memcpy(out[len..][0..at], buffered[0..at]);
        reader.toss(at);
        len += at;
        // Nothing in what is buffered ends the line, so it runs on into the
        // next fill.
        if (at == buffered.len) continue;

        // The terminator is part of the line and is consumed with it.
        // `Reader.streamDelimiter` stops on the delimiter and leaves it
        // buffered, and a reader that left its own terminator behind read
        // every line after the first as an empty one and then spun on it.
        reader.toss(1);
        if (buffered[at] == '\r') {
            // CRLF is one terminator and a CR alone is one terminator, so the
            // LF of a pair is taken with the CR, and a CR the stream ended on
            // stands as the terminator it is.
            const next = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return len,
                error.ReadFailed => return error.Transport,
            };
            if (next[0] == '\n') reader.toss(1);
        }
        return len;
    }
}

/// Read one event from a stream, or null at the end of the stream.
///
/// The SSE rules that matter for this transport: a line beginning `:` is a
/// comment, every field other than `data` is ignored, and several `data`
/// lines join with a newline into one event. `id` is ignored rather than
/// stored because `Last-Event-ID` and resumption were removed at
/// `2026-07-28`, so a stream that recorded event ids would imply a
/// capability this revision does not have.
///
/// An event whose data is empty is an event and not the end of the stream.
/// The algorithm dispatches it, so it comes back as `out[0..0]`; null is the
/// end of the stream and nothing else. That is what lets a stream whose first
/// event carries no data be read to its end rather than stopped on, which is
/// what a length of zero used to do.
pub fn readEvent(reader: *Io.Reader, out: []u8) Error!?[]const u8 {
    var len: usize = 0;
    // Where the next line is read to. It only moves forward and never falls
    // behind `len`, so a line and the event being built out of it can share
    // one caller buffer.
    var read_to: usize = 0;
    var saw_data = false;
    while (true) {
        const count = (try readLine(reader, out[read_to..])) orelse return null;
        const line = out[read_to..][0..count];
        read_to += count;

        if (line.len == 0) {
            // The dispatch. An event that carried no `data` line is a comment
            // or a bare field, and SSE does not deliver those, so the loop
            // continues rather than handing the caller an empty message.
            if (!saw_data) continue;
            // The data buffer holds the values joined by a newline, so a
            // trailing one is that join rather than the last byte of the
            // message, and the algorithm strips it before dispatching. Two
            // `data` lines with empty values are an event whose payload is
            // empty, not an event holding one newline.
            if (len != 0 and out[len - 1] == '\n') len -= 1;
            return out[0..len];
        }
        if (line[0] == ':') continue;

        // A line with no colon is a field whose value is empty, which is one
        // of the two ways a `data` line is written. Treating it as a line to
        // skip would make `data\n\n` invisible, and a dispatched event with
        // an empty value is one this reader has to hand back.
        var value: []const u8 = "";
        const field = if (std.mem.findScalar(u8, line, ':')) |colon| blk: {
            // One leading space after the colon is the field separator, not
            // part of the value.
            value = line[colon + 1 ..];
            // `value.len != 0` is the guard and it is the left operand of the
            // `and`: this arm is reached only for a line that carries a colon,
            // so `value` is a suffix of one, and a byte of it is read only
            // when it is not empty. The short circuit is the whole proof and
            // is not repeated here for an analyzer that does not follow it.
            // zwanzig-disable-next-line: slice-bounds-engine
            if (value.len != 0 and value[0] == ' ') value = value[1..];
            break :blk line[0..colon];
        } else line;
        if (!std.mem.eql(u8, field, "data")) continue;

        if (saw_data) {
            if (len == out.len) return error.BufferTooSmall;
            out[len] = '\n';
            len += 1;
        }
        // `value` lies inside the region the line was read to, and `len` never
        // passes it, so the copy is always forwards and may overlap.
        @memmove(out[len..][0..value.len], value);
        len += value.len;
        saw_data = true;
    }
}

// --- The client ----------------------------------------------------------------

/// The headers one POST carries beyond the ones the transport always sends.
pub const PostHeaders = struct {
    /// The value for `Mcp-Method`. Required by PROTOCOLS.md 4.2 from
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
    /// Sent verbatim, e.g. `Authorization: Bearer …`, which
    /// `research/normative/mcp-2026-07-28.md` §4 requires on every request.
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
    /// or the next event of a stream. Null means the reply is over.
    ///
    /// An empty slice is not that, and the two are kept apart deliberately: an
    /// event stream may dispatch an event carrying no data, and a reply that
    /// ended on it has not ended.
    pub fn nextMessage(self: *Exchange, out: []u8) Error!?[]const u8 {
        if (self.drained) return null;
        // The body reader is taken on the first read and kept, because
        // `std.http` allows it once. It is read through the field rather than
        // assigned and unwrapped, so the path that has to create it is the
        // same path that hands it back.
        const reader = self.body orelse created: {
            const fresh = self.response.reader(self.transfer);
            self.body = fresh;
            break :created fresh;
        };

        const message: ?[]const u8 = switch (self.kind) {
            .json => blk: {
                var writer = Io.Writer.fixed(out);
                const len = reader.streamRemaining(&writer) catch |err| switch (err) {
                    // A fixed writer that is full reports a write failure, so
                    // the body is larger than the buffer the caller sized.
                    error.WriteFailed => return error.BufferTooSmall,
                    error.ReadFailed => return error.Transport,
                };
                break :blk if (len == 0) null else out[0..len];
            },
            .event_stream => try readEvent(reader, out),
        };
        if (message == null) self.drained = true;
        return message;
    }

    /// Release the connection. The exchange cannot be used afterwards.
    pub fn close(self: *Exchange) void {
        self.request.deinit();
        // SAFETY: `close` is the last call on the exchange; no statement after its `defer` reads it.
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
    ///
    /// Empty when `answered` is false. No JSON-RPC message is ever zero
    /// bytes, so an empty one is unambiguous — but read `answered` rather than
    /// infer it, because that is what says the peer answered something this
    /// transport cannot read rather than nothing at all.
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
    /// Whether `message` is the JSON-RPC response to this call, or is empty
    /// because the peer answered with something this transport cannot read.
    ///
    /// A gateway that answers `502` with an HTML page has answered, and
    /// reporting that as a peer that never said anything throws the status
    /// away — the failure `status` exists to keep out of an error. So an
    /// unreadable body is a reply with an empty message and `answered` false,
    /// not an error. `error.NoResponse` stays the answer to a reply that
    /// carried no bytes at all.
    answered: bool,
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
        // `sendBodyUnflushed` above reached this same connection through the
        // same optional twice, in `sendHead` and in its own body, so the
        // request has one here or that call has already panicked. This file
        // does not add a check for a state a call it depends on cannot return.
        // zwanzig-disable-next-line: optional-unwrap
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
        // SAFETY: `post` fills every field before the `defer` that closes it can run.
        var exchange: Exchange = undefined;
        try self.post(&exchange, body, spec, head, buffers.transfer);
        defer exchange.close();

        while (true) {
            const message = try exchange.nextMessage(buffers.out) orelse return error.NoResponse;
            const decoded = jsonrpc.decode(message, buffers.decode) catch |err| switch (err) {
                // Padding and keep-alive whitespace are not messages, and
                // refusing them would fail a request the peer did answer. A
                // stream may carry either before the answer; a single body is
                // the whole of the answer, so there is nothing behind it to
                // step over to.
                error.Truncated, error.MalformedJson => switch (exchange.kind) {
                    .event_stream => continue,
                    .json => return .{
                        .status = exchange.status(),
                        .message = "",
                        .body = "",
                        .error_code = null,
                        .streamed = false,
                        .answered = false,
                    },
                },
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
                        .answered = true,
                    };
                },
            }
        }
    }
};

// --- The server ----------------------------------------------------------------

/// The shape a server answers a request with.
///
/// Both are legal for the same request.
/// `research/normative/mcp-2026-07-28.md` §4 requires the client to support
/// both, and `subscriptions/listen` is the case where the stream is the point:
/// its result arrives first and the notifications that justified the
/// subscription follow on the same reply.
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
        /// Backs the body decode in `checkPost`, which is the transport's own
        /// decode scratch.
        body_scratch: []u8,
        /// Backs the decode a handler performs on the request body.
        ///
        /// A separate array from `answer`, and a separate array from
        /// `body_scratch` as well. `Post.name` borrows `body_scratch` when the
        /// body's own string had to be unescaped, and the handler runs after
        /// the `Post` exists, so handing the handler the transport's scratch
        /// would pull the name out from under a caller that still holds the
        /// `Post`.
        decode_scratch: []u8,
        /// Receives the answer a handler composes, returned borrowed from it.
        answer: []u8,
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
    ///
    /// `decode_scratch` and `answer` are checked here to be different memory.
    /// They reach the handler as two arguments, so one array behind both of
    /// them is a caller fault that would put the answer over the decode it is
    /// being written from, and this is the one place that can see both before
    /// a request is on the wire. The check is an assert rather than an error
    /// because a peer cannot cause it: the bytes are the caller's own.
    pub fn init(in: *Io.Reader, out: *Io.Writer, buffers: Buffers) Server {
        std.debug.assert(!conn.overlaps(buffers.decode_scratch, buffers.answer));
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
        // taken off the socket, for the reason `checkPost` gives, and off the
        // same bit rather than a slot two headers share.
        if (headers.removed.session_id) return error.UnsupportedVersion;
        if (mediaType(headers.content_type orelse return error.MissingHeader) != .json) {
            return error.UnsupportedMediaType;
        }
        if (!parseAccept(headers.accept).isAcceptable()) return error.NotAcceptable;

        const body = try self.readBody(request);
        const post = try checkPost(headers, body, self.buffers.body_scratch);
        return post;
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
    /// `X-Accel-Buffering: no` is here because
    /// `research/normative/mcp-2026-07-28.md` §4 says a server SHOULD send it
    /// when it starts a stream: a reverse proxy that buffers the body would
    /// turn a subscription into one late delivery, which is the failure the
    /// header exists to prevent. No `Cache-Control` is sent, because none of
    /// the sources this library works from states one.
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
        // Two regions, and they are the two the caller sized as separate
        // arrays: the handler decodes into the first and composes its answer
        // into the second, so nothing it is comparing can land under the
        // bytes it is writing. [`Server.init`] is what proves they are
        // different memory, and this call site is where a reader sees that
        // they are handed over separately rather than carved from one buffer.
        // The frame it reads is a third region it only reads, and what is read
        // here after the call is `post.notification` and `post.accept`, neither
        // of which borrows a region, so a handler that fills both of the
        // regions it was given still leaves the answer intact.
        const response = try dispatch(
            handler.ctx,
            post.body,
            self.buffers.decode_scratch,
            self.buffers.answer,
        );

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
                stream.send(self.buffers.event, envelope) catch |fault| {
                    // Close only while a send failure unwinds. A cleanup failure
                    // must not replace that fault or retry a failed normal close.
                    // gate-reviewed-zlint-next-statement: suppressed-errors
                    // ziglint-ignore: Z026
                    // zwanzig-disable-next-line: empty-catch-engine
                    stream.close() catch {};
                    return fault;
                };
                try stream.close();
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
        // The buffer bound above proves this length fits usize on every target.
        const body = self.buffers.body[0..@intCast(length)];
        reader.readSliceAll(body) catch return error.Transport;
        return body;
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
    // PROTOCOLS.md 4.2 spells these two ways in the same document. A table keyed on
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
    try testing.expect(headers.removed.none());
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
    try testing.expect(headers.removed.session_id);
    // PROTOCOLS.md 4.2 says a peer that sends `Mcp-Session-Id` is not speaking
    // this revision, so the request is refused. The compatibility matrix in
    // the normative source asks for the opposite, and the two disagree, so
    // this is the refusal PROTOCOLS.md requires.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    try testing.expectError(error.UnsupportedVersion, checkPost(headers, body, &scratch));
}

test "the removed session id refuses the request whichever of the two headers came first" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"}}}";

    // One slot shared by the two removed headers made the verdict depend on
    // which line the peer wrote first, so a request carrying `Mcp-Session-Id`
    // was served whenever a `Last-Event-ID` reached the slot before it. The
    // two are separate bits for that reason, and both orders below are refused
    // for the same reason and with the same error.
    const last_event_first = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Last-Event-ID: 11\r\n" ++
        "Mcp-Session-Id: 5eed\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(last_event_first, &params, &scratch);
    // Both are recorded, so a caller can still see that the peer sent both.
    try testing.expect(headers.removed.session_id);
    try testing.expect(headers.removed.last_event_id);
    try testing.expectError(error.UnsupportedVersion, checkPost(headers, body, &scratch));

    const session_first = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Mcp-Session-Id: 5eed\r\n" ++
        "Last-Event-ID: 11\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const reversed = try readHeaders(session_first, &params, &scratch);
    try testing.expect(reversed.removed.session_id);
    try testing.expect(reversed.removed.last_event_id);
    try testing.expectError(error.UnsupportedVersion, checkPost(reversed, body, &scratch));
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
    try testing.expect(headers.removed.last_event_id);
    // PROTOCOLS.md 4.2 says of `Mcp-Session-Id` that a peer sending it is not
    // speaking this revision, and says no such thing of this header, so a
    // request that carried only this one is served. Nothing echoes it back and
    // there is no resumption to resume.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"}}}";
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
    // PROTOCOLS.md 4.2 makes a server validate the derived header against
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

test "a repeated Accept, Content-Type, Origin or Authorization is refused too" {
    var params: [2]ParamHeader = undefined;
    var scratch: [512]u8 = undefined;
    // The same rule as the headers above, for the same reason. RFC 9110 §5.3
    // would have the field lines joined in order, and reading only the last
    // made the verdict depend on the order they arrived in: the request below
    // was answered `406` and the same two lines the other way round was
    // served.
    const repeated = [_][2][]const u8{
        .{ "Accept", "application/json, text/event-stream" },
        .{ "Content-Type", "application/json" },
        .{ "Origin", "http://127.0.0.1:1234" },
        .{ "Authorization", "Bearer 5eed" },
    };
    for (repeated) |pair| {
        var head_buffer: [512]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &head_buffer,
            "POST /mcp HTTP/1.1\r\n" ++
                "MCP-Protocol-Version: 2026-07-28\r\n" ++
                "Mcp-Method: tools/list\r\n" ++
                "{s}: {s}\r\n" ++
                "{s}: {s}\r\n" ++
                "\r\n",
            .{ pair[0], pair[1], pair[0], pair[1] },
        );
        try testing.expectError(error.DuplicateHeader, readHeaders(head, &params, &scratch));
    }

    // One of each is read, so the refusal above is about the second and not
    // about a header this transport never accepts twice.
    const single = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Accept: application/json, text/event-stream\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Origin: http://127.0.0.1:1234\r\n" ++
        "Authorization: Bearer 5eed\r\n" ++
        "\r\n";
    const headers = try readHeaders(single, &params, &scratch);
    try testing.expectEqualStrings("Bearer 5eed", headers.authorization.?);
    try testing.expectEqualStrings("http://127.0.0.1:1234", headers.origin.?);
    try testing.expectEqualStrings("application/json, text/event-stream", headers.accept.?);
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
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"},\"name\":\"echo\"}}";
    try testing.expectError(error.MissingHeader, checkPost(headers, body, &scratch));

    // A method that names nothing does not get a header requirement invented
    // for it, or every notification POST would be refused.
    const list_head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const list_headers = try readHeaders(list_head, &params, &scratch);
    const list_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"}}}";
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
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"},\"name\":\"echo\"}}";
    try testing.expectError(error.HeaderMismatch, checkPost(headers, body, &scratch));
}

test "Mcp-Name is compared with the member the method's schema binds" {
    var params: [2]ParamHeader = undefined;
    var scratch: [256]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/call\r\n" ++
        "Mcp-Name: echo\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);

    // `CallToolRequestParams` carries `name` and `ReadResourceRequestParams`
    // carries `uri`, so this request named no tool at all. Reading either
    // member for every method let the header agree with the wrong one, and a
    // dispatcher keyed on `Post.name` would have looked up a tool the request
    // never addressed.
    try testing.expectError(error.HeaderMismatch, checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"},\"uri\":\"echo\"}}",
        &scratch,
    ));

    const read_head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: resources/read\r\n" ++
        "Mcp-Name: file:///notes.txt\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const read_headers = try readHeaders(read_head, &params, &scratch);
    try testing.expectError(error.HeaderMismatch, checkPost(
        read_headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/read\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"},\"name\":\"file:///notes.txt\"}}",
        &scratch,
    ));

    // The member each of them does bind is served, which the two refusals
    // above would also pass if this refused every name-bearing request.
    const tool = try checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"},\"name\":\"echo\"}}",
        &scratch,
    );
    try testing.expectEqualStrings("echo", tool.name.?);
    const resource = try checkPost(
        read_headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/read\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"},\"uri\":\"file:///notes.txt\"}}",
        &scratch,
    );
    try testing.expectEqualStrings("file:///notes.txt", resource.name.?);
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
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"},\"name\":\"städte\"}}";
    const post = try checkPost(headers, body, &body_scratch);
    try testing.expectEqualStrings("städte", post.name.?);
}

test "a revision the header and the body disagree on is a mismatch" {
    var params: [2]ParamHeader = undefined;
    var scratch: [512]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);

    // The header is what a gateway routes on and `_meta` is what a handler
    // reads, so a peer that declares two revisions is one request split in
    // two. Checked before this, the body was not read for the value at all
    // and the request was served at whichever revision the header named.
    try testing.expectError(error.HeaderMismatch, checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
            "\"params\":{\"cursor\":\"c\"," ++
            "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2025-11-25\"}}}",
        &scratch,
    ));

    // The same body declaring the revision the header named is served, and so
    // is one whose `_meta` carries members this transport does not read
    // alongside the one it does.
    const agreed = try checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/clientInfo\":" ++
            "{\"name\":\"c\",\"version\":\"1\"}," ++
            "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}",
        &scratch,
    );
    try testing.expectEqualStrings("tools/list", agreed.method);
    const unrelated = try checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
            "\"params\":{\"_meta\":{\"progressToken\":7," ++
            "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}",
        &scratch,
    );
    try testing.expectEqualStrings("tools/list", unrelated.method);
}

test "a request that does not declare the revision in _meta is refused" {
    var params: [2]ParamHeader = undefined;
    var scratch: [512]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);

    // PROTOCOLS.md 4.3 records `io.modelcontextprotocol/protocolVersion` as
    // carried "on every request" and PROTOCOLS.md 2 makes a required field the
    // peer omits a decode error, and
    // `research/normative/mcp-2026-07-28.md` §2 grades the key `Required: Yes`
    // with "Missing ⇒ `-32602` on HTTP `400 Bad Request`". Four ways of not
    // declaring it, one error: a body with no `params`, one with `params` but
    // no `_meta`, an empty `_meta`, and a `_meta` carrying only other keys.
    // Every one of them was served, on the reasoning that a value that is not
    // there has nothing to compare — which is true of the comparison and false
    // of the requirement.
    try testing.expectError(error.MissingField, checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
        &scratch,
    ));
    try testing.expectError(error.MissingField, checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}",
        &scratch,
    ));
    try testing.expectError(error.MissingField, checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
            "\"params\":{\"_meta\":{}}}",
        &scratch,
    ));
    try testing.expectError(error.MissingField, checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
            "\"params\":{\"_meta\":{\"progressToken\":7}}}",
        &scratch,
    ));

    // The key arriving is what changes the verdict and nothing else, so the
    // four refusals above are not a blanket refusal of bodies that do not
    // carry a `_meta` at all.
    try testing.expectEqualStrings("tools/list", (try checkPost(
        headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"}}}",
        &scratch,
    )).method);

    // A notification is not a request, and the normative table grades the key
    // on "every client request `_meta`", so a POST carrying one is not refused
    // for a `_meta` it never owed. A notification that declares a revision the
    // header disagrees with is still a disagreement, so both halves run
    // against a header naming the method the body declares.
    const progress_head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: notifications/progress\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const progress_headers = try readHeaders(progress_head, &params, &scratch);
    const progress = try checkPost(
        progress_headers,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"," ++
            "\"params\":{\"progress\":1}}",
        &scratch,
    );
    try testing.expect(progress.notification);
    try testing.expectError(error.HeaderMismatch, checkPost(
        progress_headers,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/" ++
            "protocolVersion\":\"2025-11-25\"}}}",
        &scratch,
    ));
}

test "a body scratch too small is the caller's shortage, not the peer's request" {
    var params: [2]ParamHeader = undefined;
    var scratch: [512]u8 = undefined;
    const head = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/list\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const headers = try readHeaders(head, &params, &scratch);

    // A body whose `params` carries a key that needs the caller's scratch to
    // decode. `jsonrpc.decode` steps over `params` as a raw value and never
    // writes, so this body decodes in a buffer of nothing and the shortage
    // belongs to the walk `checkPost` runs next.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"," ++
        "\"params\":{\"a\\u0020b\":1,\"_meta\":{\"io.modelcontextprotocol/" ++
        "protocolVersion\":\"2026-07-28\"}}}";
    // The same body with room to decode is served, so the assertion below is
    // about the buffer and not about the body.
    try testing.expectEqualStrings("tools/list", (try checkPost(headers, body, &scratch)).method);

    // The escape is in a key `metaRevision` reads, and a scratch of zero bytes
    // cannot decode it. Reported as `400 MalformedRequest` before this, which
    // blames the peer for a fault only the caller can fix: the shortage is the
    // caller's `Server.Buffers.body_scratch` being too small, and
    // `jsonrpc.decode` propagates the very same fault as `BufferTooSmall`.
    try testing.expectError(
        error.BufferTooSmall,
        checkPost(headers, body, scratch[0..0]),
    );

    // The same shortage in the `Mcp-Name` walk. `nameFromParams` reads every
    // key from the top of `params`, so the escaped key has to come after the
    // `_meta` that lets `metaRevision` return first — otherwise the walk above
    // would be the one that ran out.
    const named = "POST /mcp HTTP/1.1\r\n" ++
        "MCP-Protocol-Version: 2026-07-28\r\n" ++
        "Mcp-Method: tools/call\r\n" ++
        "Mcp-Name: echo\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n";
    const name_headers = try readHeaders(named, &params, &scratch);
    try testing.expectError(
        error.BufferTooSmall,
        checkPost(
            name_headers,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
                "\"params\":{\"_meta\":{\"io.modelcontextprotocol/" ++
                "protocolVersion\":\"2026-07-28\"},\"a\\u0020b\":1," ++
                "\"name\":\"echo\"}}",
            scratch[0..0],
        ),
    );
    // The same body with room to decode is served, so the walk above is what
    // ran out rather than the request.
    try testing.expectEqualStrings("echo", (try checkPost(
        name_headers,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/" ++
            "protocolVersion\":\"2026-07-28\"},\"a\\u0020b\":1," ++
            "\"name\":\"echo\"}}",
        &scratch,
    )).name.?);
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
    )) orelse return error.TestUnexpectedResult;
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
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"},\"name\":\"echo\",\"arguments\":{\"city\":\"Zürich\"}}}";
    const post = try checkPost(headers, body, &scratch);
    try testing.expectEqualStrings("Zürich", post.param("city").?);

    var converted: [mcp.param_value_max_len]u8 = undefined;
    var decode_scratch: [64]u8 = undefined;
    // The value the tool's own schema declares is what the header is checked
    // against, and the verdict is the one PROTOCOLS.md 4.2 names.
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
    // `research/normative/mcp-2026-07-28.md` §4 requires the client to list
    // both, so a client that lists one has narrowed the choice and a server
    // that answers with the other one sends a media type the client said it
    // cannot read.
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

test "the most specific Accept entry decides a type, and a wildcard cannot re-admit it" {
    // RFC 9110 §12.5.1: the most specific matching media range has precedence
    // and sets the quality of the type. Reading the list as a set of bits gave
    // `*/*` the last word, so a peer that refused the JSON body beside it was
    // answered with `Content-Type: application/json` anyway.
    const after_wildcard = parseAccept("*/*, application/json;q=0");
    try testing.expect(!after_wildcard.allows(.json));
    try testing.expect(after_wildcard.allows(.event_stream));
    try testing.expect(after_wildcard.isAcceptable());

    // Order does not decide it: the concrete type is ahead of `*/*` whichever
    // side of the list it arrived on.
    const before_wildcard = parseAccept("application/json;q=0, */*");
    try testing.expect(!before_wildcard.allows(.json));
    try testing.expect(before_wildcard.allows(.event_stream));

    // `type/*` is less specific than the type, so it cannot re-admit what the
    // type refused either.
    const major_wildcard = parseAccept("application/json;q=0, application/*");
    try testing.expect(!major_wildcard.allows(.json));
    try testing.expect(!major_wildcard.allows(.event_stream));

    const stream_refused = parseAccept("text/event-stream;q=0, */*");
    try testing.expect(!stream_refused.allows(.event_stream));
    try testing.expect(stream_refused.allows(.json));

    // A wildcard beside an entry that does not refuse is what it always was:
    // the more specific entry only decides, and it decides the same answer.
    const admitted = parseAccept("*/*, application/json");
    try testing.expect(admitted.allows(.json) and admitted.allows(.event_stream));
}

test "a * as the type is only a wildcard beside another *" {
    // RFC 9110 §12.5.1 spells the range that covers every media type `"*/*"`
    // literally rather than as `type "/" "*"`, and the text beside it names
    // `*/*` and `type/*` as the two wildcards there are. Reading any `*` in the
    // type position as `*/*` made `*/event-stream` answer a JSON body and
    // `*/json` answer a stream, each of which is the one media type the client
    // did not list.
    const stream_only = parseAccept("*/event-stream");
    try testing.expect(!stream_only.allows(.json));
    try testing.expect(!stream_only.isAcceptable());

    const json_only = parseAccept("*/json");
    try testing.expect(!json_only.allows(.event_stream));
    try testing.expect(!json_only.isAcceptable());

    // An entry that names no range decides nothing, so it cannot admit the one
    // media type a real entry beside it refused either. Before this, the `*` in
    // `*/json` decided `text/event-stream` at rank `*/*` and the request was
    // accepted for a stream it had not asked for.
    const beside = parseAccept("*/json, application/json;q=0");
    try testing.expect(!beside.allows(.json));
    try testing.expect(!beside.allows(.event_stream));
    try testing.expect(!beside.isAcceptable());

    // `*/*` and `type/*` are the two that are ranges, and neither changed.
    const everything = parseAccept("*/*");
    try testing.expect(everything.allows(.json) and everything.allows(.event_stream));
    const by_type = parseAccept("text/*");
    try testing.expect(!by_type.allows(.json));
    try testing.expect(by_type.allows(.event_stream));
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
    const event = (try readEvent(&reader, &out)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("{\"b\":2}", event);
}

test "several data lines are one event, and the stream may then end" {
    var out: [128]u8 = undefined;
    var reader = Io.Reader.fixed("data: {\"a\":\ndata: 1}\n\n");
    try testing.expectEqualStrings("{\"a\":\n1}", (try readEvent(&reader, &out)).?);

    // The next event is the next one, and the end of the stream is no event
    // at all rather than an error.
    try testing.expect((try readEvent(&reader, &out)) == null);
}

test "an event the stream ended inside is delivered as nothing" {
    var out: [128]u8 = undefined;
    var reader = Io.Reader.fixed("data: {\"a\":");
    // SSE discards an event that was never dispatched, so a peer that hangs up
    // mid-event produces no message rather than a truncated one that a caller
    // would try to parse.
    try testing.expect((try readEvent(&reader, &out)) == null);

    // The line arrived whole; the stream ended before the blank line that
    // dispatches the event, and a reader that delivered it anyway hands a
    // caller the last message of every stream a peer cut short.
    var undispatched = Io.Reader.fixed("data: {\"b\":2}\n");
    try testing.expect((try readEvent(&undispatched, &out)) == null);
}

test "an event with no data is an event, and the stream is not over" {
    var out: [128]u8 = undefined;
    var reader = Io.Reader.fixed(
        "data:\n\n" ++
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
    );
    // The algorithm dispatches an event whose data buffer is empty, so it
    // arrives with nothing in it and the stream carries on. Reported as a
    // length, the dispatched event and the end of the stream were the same
    // number, which is how a client stopped on an empty first event and read
    // nothing of what came after it.
    const empty = (try readEvent(&reader, &out)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        (try readEvent(&reader, &out)).?,
    );
    try testing.expect((try readEvent(&reader, &out)) == null);

    // The colon and one space are the same event: the space is the field
    // separator and the value behind it is empty.
    var spaced = Io.Reader.fixed("data: \n\ndata: 1\n\n");
    try testing.expectEqual(@as(usize, 0), (try readEvent(&spaced, &out)).?.len);
    try testing.expectEqualStrings("1", (try readEvent(&spaced, &out)).?);

    // Two empty data lines join with the newline between them, and the
    // algorithm strips that trailing newline before dispatching, so the
    // payload is empty rather than one byte of newline.
    var joined = Io.Reader.fixed("data:\ndata:\n\n");
    try testing.expectEqual(@as(usize, 0), (try readEvent(&joined, &out)).?.len);
}

test "a CR or CRLF framed stream reads the events an LF one does" {
    var out: [128]u8 = undefined;

    // A CRLF peer sends the terminator after the value it wrote, and a reader
    // that stops at LF alone copies the CR into the payload: the message is
    // no longer the bytes the peer wrote, and a body carrying a raw carriage
    // return is not JSON at all.
    var crlf = Io.Reader.fixed("data: {\"a\":\r\ndata: 1}\r\n\r\n");
    try testing.expectEqualStrings("{\"a\":\n1}", (try readEvent(&crlf, &out)).?);

    // Two events in a row is where a CR left behind shifts every line after
    // it, so the second event is read as an empty one.
    var pair = Io.Reader.fixed("data: 1\r\n\r\ndata: 2\r\n\r\n");
    try testing.expectEqualStrings("1", (try readEvent(&pair, &out)).?);
    try testing.expectEqualStrings("2", (try readEvent(&pair, &out)).?);
    try testing.expect((try readEvent(&pair, &out)) == null);

    // A CR-only peer never sends an LF at all. Reading to the LF means
    // reading until the caller's buffer is full, and that was reported to the
    // caller as its own buffer being too small — a conforming stream of any
    // length turned into a local fault.
    var cr = Io.Reader.fixed("data: {\"a\":1}\r\rdata: 2\r\r");
    try testing.expectEqualStrings("{\"a\":1}", (try readEvent(&cr, &out)).?);
    try testing.expectEqualStrings("2", (try readEvent(&cr, &out)).?);

    // The stream ended on the CR, so there is no LF behind it to decide the
    // terminator by, and the line it ended is still not dispatched without the
    // blank line that would have followed it.
    var cut = Io.Reader.fixed("data: 3\r");
    try testing.expect((try readEvent(&cut, &out)) == null);
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
    // SAFETY: `open` assigns it before `port`, `uri_text` or `close` can read it.
    address: Io.net.IpAddress = undefined,
    // SAFETY: `open` assigns it, and every test reaches `close` only past the `try open`.
    listener: Io.net.Server = undefined,
    // SAFETY: `bufPrint` fills it and `uri_text` holds nothing until that call returns.
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

/// How much one message read off a reply may occupy.
///
/// Named because two of these regions are live at once, so a caller that
/// expects a bigger message has one place to change.
const message_size: usize = 4096;

/// Every buffer one side of an exchange needs.
///
/// Caller-owned, so a leak in the transport shows up as a leak in the test
/// rather than being absorbed by an allocator the transport was handed.
const Side = struct {
    // SAFETY: `Stream.Reader.init` takes it as the fill buffer and reads back only what it filled.
    reader_buffer: [4096]u8 = undefined,
    // SAFETY: `Stream.Writer.init` takes it as the drain buffer and writes only what it holds.
    writer_buffer: [4096]u8 = undefined,
    // SAFETY: `Serve.run` assigns the accepted stream before the reader and writer borrow it.
    stream: Io.net.Stream = undefined,
    // SAFETY: `Serve.run` assigns it before `Server.init` reads its interface.
    stream_reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `Serve.run` assigns it before `Server.init` reads its interface.
    stream_writer: Io.net.Stream.Writer = undefined,

    // SAFETY: `readHeaders` fills each `ParamHeader` it hands back a slice into.
    params: [8]ParamHeader = undefined,
    // SAFETY: the base64 header decode writes it before the decoded value is read.
    head_scratch: [256]u8 = undefined,
    // SAFETY: `readBody` fills it and returns `[0..content_length]`, or `[0..0]` for none.
    body: [4096]u8 = undefined,
    // SAFETY: `checkPost` decodes into it and the decoded body is read back out of it.
    body_scratch: [1024]u8 = undefined,
    // SAFETY: the handler's own decode writes it before the parsed message is read from it.
    decode_scratch: [1024]u8 = undefined,
    // SAFETY: the handler composes its envelope in and returns that written slice.
    answer: [1024]u8 = undefined,
    // SAFETY: the chunk reader fills it as `readBody` transfers, and no read precedes a write.
    transfer: [64]u8 = undefined,
    // SAFETY: `writeEvent` frames each event in before `send` writes the framed slice out.
    event: [4096]u8 = undefined,
    // SAFETY: `respondStreaming` fills it and returns the writer bound to it.
    stream_buffer: [4096]u8 = undefined,
    // SAFETY: `Serve.run` assigns `Server.init`'s result before `receive` runs on it.
    server: Server = undefined,

    // SAFETY: `requestHeaders` fills the head before the request reads a header out of it.
    head: [16]http.Header = undefined,
    /// The message read first, or a whole response body.
    // SAFETY: `nextMessage` fills it and returns `[0..len]`, the reader's own count.
    out: [message_size]u8 = undefined,
    /// The message read after that one.
    ///
    /// A second field and not a second half of `out`, because both are live at
    /// once: the first message is still readable when the second arrives, and
    /// a caller reads both of them afterwards.
    // SAFETY: the second `nextMessage` fills it; the test reads `[0..second_len]`.
    next_out: [message_size]u8 = undefined,
    /// The message read after that one.
    ///
    /// A third field for the same reason as `next_out`: a caller reads the
    /// messages after the exchange is done, so a message it wants to read
    /// needs a region of its own to have landed in.
    // SAFETY: the third `nextMessage` fills it; the test reads `[0..third_len]`.
    third_out: [message_size]u8 = undefined,
    // SAFETY: `jsonrpc.decode` fills it and returns slices borrowed from what it wrote.
    decode: [1024]u8 = undefined,
};

/// Answers every request with a result, and records what it was asked.
const Answer = struct {
    calls: usize = 0,
    // SAFETY: `handle` copies into it and sets `method_len` before the test reads that slice.
    method_buffer: [64]u8 = undefined,
    method_len: usize = 0,

    fn handle(
        ctx: ?*anyopaque,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) conn.Error!?[]const u8 {
        // Every test below installs this handler as `.{ .ctx = &answer, .call
        // = Answer.handle }`, naming the `Answer` it belongs to on the same
        // line, so a null context is a test wired wrong rather than anything a
        // peer can bring about. It is deliberately not answered with a null
        // here: this handler returning null is how it declines a frame, and a
        // fixture with no fixture behind it would decline every request and
        // leave the test below it waiting on an answer never composed.
        // zwanzig-disable-next-line: optional-unwrap
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(frame, decode_scratch) catch return null;
        self.calls += 1;
        const name = message.method orelse return null;
        const n = @min(name.text.len, self.method_buffer.len);
        @memcpy(self.method_buffer[0..n], name.text[0..n]);
        self.method_len = n;
        if (message.id == null) return null;

        // The reply is a real JSON-RPC envelope carrying the request's own id,
        // which is the only thing a client can match an answer by. The two
        // regions are the caller's separate arrays, so writing the envelope
        // into `answer` cannot reach the decode above it. That is now
        // structural rather than a matter of the order of these statements, and
        // the order is kept anyway: a handler that reads everything it borrows
        // before it writes is correct whichever way the two regions are laid
        // out, and one that is correct only one way is a handler a reader has
        // to check rather than trust.
        var writer = json.Writer.init(answer);
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

    fn run(self: *Serve) void {
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
                .decode_scratch = &self.side.decode_scratch,
                .answer = &self.side.answer,
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

    fn run(self: *Call) void {
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

/// Which step of a socket exchange a harness task could not finish.
///
/// A `failed` flag on its own says that something stopped, and these tasks
/// run on a group beside each other, so a line printed by the one that
/// stopped is ordered against neither the other task's output nor the test
/// runner's own report. The test returns the member it was handed instead, so
/// the step lands in the report the runner prints for that test, beside that
/// test's name.
const GaveUp = error{
    /// The client never opened a connection to the endpoint.
    NoConnection,
    /// The POST did not go out.
    NoPost,
    /// Reading the reply failed, so the exchange stopped on the wire.
    NoMessage,
    /// A message was longer than the buffer the harness gave the reader.
    MessageTooLarge,
    /// No connection was ever accepted.
    NoAccept,
    /// The request could not be received.
    NoRequest,
    /// The peer closed the connection before a request arrived.
    ClosedEarly,
    /// The handler was built without a call, so nothing could be answered.
    NoHandler,
    /// The handler refused, so there was nothing to answer with.
    NoDispatch,
    /// The reply could not be opened as a stream.
    NoStream,
    /// The result did not reach the client.
    NoResultSent,
    /// A notification did not reach the client.
    NoNotificationSent,
    /// The stream was not ended, so the client could not see it close.
    StreamNotEnded,
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
    // SAFETY: the header copy fills it and sets `content_type_len`, zero until then.
    content_type: [64]u8 = undefined,
    content_type_len: usize = 0,
    /// Whether the reply carried a session identifier, which this revision
    /// removed and no compliant server may send.
    session_echoed: bool = false,
    /// The length of the first message, so a test can assert on it.
    first_len: usize = 0,
    /// The length of the second, for a stream that carries more than a result.
    second_len: usize = 0,
    /// The length of the third, for a stream that carries two notifications
    /// on top of a result.
    third_len: usize = 0,
    /// How many messages the reply held, and the count at the read that
    /// reported the reply over.
    messages: usize = 0,
    ended: usize = 0,
    got: *bool,
    failed: *bool,
    /// The step this task could not finish, or `null` while it is still
    /// reading. The test returns it as its own error.
    failure: ?GaveUp = null,

    fn run(self: *Listen) void {
        var client = openClient(self.http, self.endpoint) orelse {
            self.failed.* = true;
            self.failure = error.NoConnection;
            return;
        };
        // SAFETY: `post` fills every field before the `defer` that closes it can run.
        var exchange: Exchange = undefined;
        client.post(&exchange, self.body, self.spec, &self.side.head, &self.side.transfer) catch {
            self.failed.* = true;
            self.failure = error.NoPost;
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

        // The reply is read to its end rather than to a count, because a
        // reader that stops early is what breaks an exchange rather than what
        // observes one: releasing the exchange closes the connection, and the
        // write the peer had left to make then fails on a peer that has done
        // nothing wrong. A region of its own per read, because the messages
        // stay live: the lengths below go back to a test that reads their
        // bytes again after the exchange has ended.
        while (true) {
            const out: []u8 = switch (self.messages) {
                0 => &self.side.out,
                1 => &self.side.next_out,
                // The newest message lands in the last region, so a reply
                // longer than this does not overwrite one a test reads
                // afterwards.
                else => &self.side.third_out,
            };
            const message = exchange.nextMessage(out) catch |err| {
                self.failed.* = true;
                self.failure = switch (err) {
                    error.BufferTooSmall => error.MessageTooLarge,
                    else => error.NoMessage,
                };
                return;
            } orelse {
                // The reply is over. An event carrying no data is a message
                // the peer sent and is counted as one.
                self.ended = self.messages;
                break;
            };
            if (self.messages == 0) self.first_len = message.len;
            if (self.messages == 1) self.second_len = message.len;
            if (self.messages == 2) self.third_len = message.len;
            self.messages += 1;
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

    fn run(self: *Chunked) void {
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

        // A request after the refused one carries the `_meta` PROTOCOLS.md 4.3
        // requires, so what this test measures is the connection surviving the
        // refusal above and nothing else.
        const body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"}}}";
        self.answer = client.call(2, body, spec, &self.side.head, .{
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
    /// The step this task could not finish, or `null` while it is still
    /// running. The test returns it as its own error.
    failure: ?GaveUp = null,

    fn run(self: *Subscribe) void {
        const stream = self.listener.accept(self.io) catch {
            self.failed.* = true;
            self.failure = error.NoAccept;
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
                .decode_scratch = &self.side.decode_scratch,
                .answer = &self.side.answer,
                .transfer = &self.side.transfer,
                .event = &self.side.event,
                .stream = &self.side.stream_buffer,
            },
        );

        const post = self.side.server.receive() catch {
            self.failed.* = true;
            self.failure = error.NoRequest;
            return;
        } orelse {
            self.failed.* = true;
            self.failure = error.ClosedEarly;
            return;
        };
        const dispatch = self.handler.call orelse {
            self.failed.* = true;
            self.failure = error.NoHandler;
            return;
        };
        // The two regions are the server's own and are separate arrays, the
        // same pair `Server.answer` hands over, so the envelope this writes is
        // not written over the decode it was written from.
        const result = dispatch(
            self.handler.ctx,
            post.body,
            self.side.server.buffers.decode_scratch,
            self.side.server.buffers.answer,
        ) catch {
            self.failed.* = true;
            self.failure = error.NoDispatch;
            return;
        };
        var out = self.side.server.respondStream(post) catch {
            self.failed.* = true;
            self.failure = error.NoStream;
            return;
        };
        out.send(self.side.server.buffers.event, result orelse return) catch {
            self.failed.* = true;
            self.failure = error.NoResultSent;
            return;
        };
        self.sent.* = 1;

        for (self.notifications) |notification| {
            out.send(self.side.server.buffers.event, notification) catch {
                self.failed.* = true;
                self.failure = error.NoNotificationSent;
                return;
            };
            self.sent.* += 1;
        }
        out.close() catch {
            self.failed.* = true;
            self.failure = error.StreamNotEnded;
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
    defer group.cancel(io);
    // One group drives both sides. Two would deadlock: the client blocks
    // waiting for an answer only the server's task can produce.
    var serve: Serve = .{
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
    var call: Call = .{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"},\"name\":\"echo\"}}",
        .spec = .{ .method = "tools/call", .name = "echo" },
        .id = 7,
        .reply = &reply,
        .got = &got,
        .failed = &failed,
    };
    try group.concurrent(io, Serve.run, .{&serve});
    try group.concurrent(io, Call.run, .{&call});
    try group.await(io);

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
    defer group.cancel(io);
    var serve: Serve = .{
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
    var listen: Listen = .{
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
    try group.concurrent(io, Serve.run, .{&serve});
    try group.concurrent(io, Listen.run, .{&listen});
    try group.await(io);

    // The step the client reached is this test's own error, so the runner
    // reports which step stopped rather than a test that failed having said
    // nothing. `failed` is asserted after it because that flag is shared with
    // the server task, which reports no step of its own.
    if (listen.failure) |step| return step;
    try testing.expect(!failed);
    try testing.expect(got);
    try testing.expect(refused);
    // The request really did carry the removed header, so the refusal below is
    // about that header and not about something the peer never sent.
    const head = (server_side.server.request orelse return error.TestUnexpectedResult).head_buffer;
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
    defer group.cancel(io);
    var serve: Serve = .{
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
    var chunked: Chunked = .{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .failed = &failed,
    };
    try group.concurrent(io, Serve.run, .{&serve});
    try group.concurrent(io, Chunked.run, .{&chunked});
    try group.await(io);

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
    defer group.cancel(io);
    var serve: Serve = .{
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
    var listen: Listen = .{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"subscriptions/listen\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"}}}",
        .spec = .{ .method = "subscriptions/listen" },
        .status = .ok,
        .got = &got,
        .failed = &failed,
    };
    try group.concurrent(io, Serve.run, .{&serve});
    try group.concurrent(io, Listen.run, .{&listen});
    try group.await(io);

    if (listen.failure) |step| return step;
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

/// The bytes that end a chunked body: the last chunk is a zero-length one.
///
/// An event cannot carry them, because `writeEvent` refuses a message with a
/// CR in it and so no event payload holds one, and no chunk but the last is
/// zero-length. That is what lets a test name the bytes rather than the step
/// that writes them. A response head is a third possibility, and the test
/// below checks that one against the bytes rather than assuming it.
const chunk_terminator = "0\r\n\r\n";

test "a stream answer whose terminating chunk cannot be written is a transport fault" {
    // A buffered writer that records every byte the answer puts out and can
    // refuse the terminating chunk and nothing else. The staging buffer is
    // not optional here: `std.http` reserves room for a chunk header in the
    // writer it is given, and a writer with no room for one aborts.
    const Wire = struct {

        // The receiver alias every local fixture in this file uses: a struct
        // declared inside a function cannot name itself, so its own members
        // reach the container through this rather than through `Wire`.
        const Self = @This();

        // SAFETY: `bind` hands this to `writer.buffer` before `std.http`
        // writes through that writer, and it outlives the writer.
        staging: [1024]u8 = undefined,
        // SAFETY: `accept` writes each prefix before `len` grows; `written`
        // reads only that prefix.
        sent: [4096]u8 = undefined,
        len: usize = 0,
        // SAFETY: `record` writes each prefix before `refused_len` grows;
        // `refusedCall` reads only that prefix.
        refused: [1024]u8 = undefined,
        refused_len: usize = 0,
        refusals: usize = 0,
        /// Whether a write carrying the terminating chunk is refused.
        ///
        /// What it refuses on is `chunk_terminator`, a zero-length chunk: a
        /// size of `0` with the two CRLFs around it. No event can hold it,
        /// because `writeEvent` refuses a message with a CR in it and so no
        /// event payload carries one, and no chunk but the last is
        /// zero-length. The head this transport writes is checked by the test
        /// that uses this rather than assumed here.
        refuse_terminator: bool = false,
        writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

        /// Hand the writer the staging `std.http` reserves a chunk header in.
        fn bind(self: *Self) void {
            self.writer.buffer = self.staging[0..];
        }

        fn written(self: *const Self) []const u8 {
            return self.sent[0..self.len];
        }

        /// The bytes of the one call this writer refused.
        fn refusedCall(self: *const Self) []const u8 {
            return self.refused[0..self.refused_len];
        }

        // Consume staged bytes first. Only data-vector bytes contribute to the result.
        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const self: *Self = @fieldParentPtr("writer", w);
            const buffered = w.buffer[0..w.end];
            const prefix = data[0 .. data.len - 1];
            const last = data[data.len - 1];
            if (self.refuse_terminator and self.carries(buffered, data, splat)) {
                try self.record(buffered);
                for (prefix) |bytes| try self.record(bytes);
                for (0..splat) |_| try self.record(last);
                self.refusals += 1;
                return error.WriteFailed;
            }
            _ = try self.accept(buffered);
            w.end = 0;
            var count: usize = 0;
            for (prefix) |bytes| count += try self.accept(bytes);
            for (0..splat) |_| count += try self.accept(last);
            return count;
        }

        fn accept(self: *Self, bytes: []const u8) Io.Writer.Error!usize {
            if (bytes.len > self.sent.len - self.len) return error.WriteFailed;
            @memcpy(self.sent[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
            return bytes.len;
        }

        fn record(self: *Self, bytes: []const u8) Io.Writer.Error!void {
            if (bytes.len > self.refused.len - self.refused_len) return error.WriteFailed;
            @memcpy(self.refused[self.refused_len..][0..bytes.len], bytes);
            self.refused_len += bytes.len;
        }

        /// Whether any part of one call carries the terminating chunk. The
        /// bytes the writer has staged count as much as the ones handed to
        /// it, because that is where `std.http` builds a chunk header.
        fn carries(
            _: *const Self,
            buffered: []const u8,
            data: []const []const u8,
            splat: usize,
        ) bool {
            if (std.mem.indexOf(u8, buffered, chunk_terminator) != null) return true;
            for (data[0 .. data.len - 1]) |bytes| {
                if (std.mem.indexOf(u8, bytes, chunk_terminator) != null) return true;
            }
            return splat != 0 and std.mem.indexOf(u8, data[data.len - 1], chunk_terminator) != null;
        }
    };

    // Parse a real POST through std.http, then answer through the controlled writer.
    const Once = struct {
        // The same alias as `Wire` above, and for the same reason.
        const Self = @This();

        side: *Side,
        handler: conn.Handler,
        request: []const u8,
        wire: *Wire,

        fn run(self: *Self) !std.http.Status {
            var in = Io.Reader.fixed(self.request);
            var server = Server.init(&in, &self.wire.writer, .{
                .params = &self.side.params,
                .head_scratch = &self.side.head_scratch,
                .body = &self.side.body,
                .body_scratch = &self.side.body_scratch,
                .decode_scratch = &self.side.decode_scratch,
                .answer = &self.side.answer,
                .transfer = &self.side.transfer,
                .event = &self.side.event,
                .stream = &self.side.stream_buffer,
            });
            const post = (try server.receive()) orelse return error.TestUnexpectedResult;
            return server.answer(post, self.handler, .stream);
        }
    };

    const post_body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"subscriptions/listen\"," ++
        "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
        "\"2026-07-28\"}}}";
    // The head `Client.requestHeaders` composes, spelled out so this test
    // states the request rather than deriving it from a client it does not
    // run. The length is computed rather than written, so the header and the
    // body cannot drift apart.
    // SAFETY: `bufPrint` fills `request` and returns the slice it wrote.
    var request: [512]u8 = undefined;
    const wire_request = try std.fmt.bufPrint(&request, "POST /mcp HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        mcp.header_name.protocol_version ++ ": " ++ mcp.latest_protocol_version ++ "\r\n" ++
        mcp.header_name.method ++ ": subscriptions/listen\r\n" ++
        mcp.header_name.accept ++ ": " ++ accept_value ++ "\r\n" ++
        mcp.header_name.content_type ++ ": " ++ mcp.uri_and_media.json_media_type ++ "\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n" ++
        "{s}", .{ post_body.len, post_body });

    var side: Side = .{};
    var refusing_wire: Wire = .{ .refuse_terminator = true };
    var permissive_wire: Wire = .{};
    // The staging buffer is bound before either exchange runs, because
    // `std.http` reserves room for a chunk header in the writer it is handed.
    refusing_wire.bind();
    permissive_wire.bind();
    var answer: Answer = .{};
    var refusing: Once = .{
        .side = &side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .request = wire_request,
        .wire = &refusing_wire,
    };
    var permissive: Once = .{
        .side = &side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .request = wire_request,
        .wire = &permissive_wire,
    };

    try testing.expectError(error.Transport, refusing.run());
    try testing.expectEqual(std.http.Status.ok, try permissive.run());

    // Both answers reached the same handler and composed the same envelope, so
    // the two replies differ only in what the writer did with the bytes.
    try testing.expectEqual(@as(usize, 2), answer.calls);

    const envelope = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"resultType\":\"complete\"}}";
    const event = "data: " ++ envelope ++ "\n\n";
    const head = refusing_wire.written();

    // Exactly one write was refused and it was the terminating chunk, so the
    // fault is at the end of the stream and nowhere inside it.
    try testing.expectEqual(@as(usize, 1), refusing_wire.refusals);
    try testing.expect(std.mem.endsWith(u8, refusing_wire.refusedCall(), chunk_terminator));
    // The whole event is ahead of it on the wire, which is what says the send
    // completed and that what could not be written was the ending rather than
    // the message.
    try testing.expect(std.mem.indexOf(u8, head, event) != null);
    // The head the answer promised is there too, so the stream was opened
    // with the media type a client reads events from and the framing that
    // carries them.
    try testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 "));
    try testing.expect(std.ascii.findIgnoreCase(head, "content-type: " ++
        mcp.uri_and_media.event_stream_media_type ++ "\r\n") != null);
    try testing.expect(
        std.ascii.findIgnoreCase(head, "transfer-encoding: chunked\r\n") != null,
    );
    // No terminator reached the peer, so nothing was refused before the end
    // and no part of the event was lost along with it.
    try testing.expect(std.mem.indexOf(u8, head, chunk_terminator) == null);

    // The control: the same fixture refusing nothing ends the body on the
    // wire and answers `200 OK`. The refusal above is therefore the whole
    // difference between a clean answer and a fault.
    try testing.expectEqual(@as(usize, 0), permissive_wire.refusals);
    try testing.expect(std.mem.indexOf(u8, permissive_wire.written(), event) != null);
    try testing.expect(std.mem.endsWith(u8, permissive_wire.written(), chunk_terminator));
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
    defer group.cancel(io);
    var serve: Serve = .{
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
    var listen: Listen = .{
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
    try group.concurrent(io, Serve.run, .{&serve});
    try group.concurrent(io, Listen.run, .{&listen});
    try group.await(io);

    if (listen.failure) |step| return step;
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

        const Self = @This();

        fn run(self: *Self) void {
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
                    .decode_scratch = &self.side.decode_scratch,
                    .answer = &self.side.answer,
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
    defer group.cancel(io);
    var serve: Reject = .{
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

        const Self = @This();

        fn run(self: *Self) void {
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
    var probe: Probe = .{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .status = &status,
        .got = &got,
        .failed = &failed,
    };
    try group.concurrent(io, Reject.run, .{&serve});
    try group.concurrent(io, Probe.run, .{&probe});
    try group.await(io);

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
    defer group.cancel(io);
    var serve: Subscribe = .{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handler = .{ .ctx = &answer, .call = Answer.handle },
        .notifications = &notifications,
        .sent = &sent,
        .failed = &failed,
    };
    var listen: Listen = .{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"subscriptions/listen\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"},\"resourceSubscriptions\":[\"file:///a\"]}}",
        .spec = .{ .method = "subscriptions/listen" },
        .status = .ok,
        .got = &got,
        .failed = &failed,
    };
    try group.concurrent(io, Subscribe.run, .{&serve});
    try group.concurrent(io, Listen.run, .{&listen});
    try group.await(io);

    // Both tasks report the step they reached, the server's first: its step
    // is the one that says whether the result ever went out.
    if (serve.failure) |step| return step;
    if (listen.failure) |step| return step;
    try testing.expect(!failed);
    try testing.expect(got);
    // Three messages went out and all three came back, in order, and the
    // reply then ended. A server that answered once and closed would have
    // delivered the result and nothing else, which is the whole reason the
    // stream exists, and a server that kept one notification coming would
    // have delivered the first one twice.
    try testing.expectEqual(@as(usize, 3), sent);
    try testing.expectEqual(@as(usize, 3), listen.messages);
    // The count at the read that reported the reply over, so the third
    // message arrived on a stream that was ended and not on one the client
    // stopped reading.
    try testing.expectEqual(@as(usize, 3), listen.ended);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"resultType\":\"complete\"}}",
        client_side.out[0..listen.first_len],
    );
    try testing.expectEqualStrings(
        notifications[0],
        client_side.next_out[0..listen.second_len],
    );
    try testing.expectEqualStrings(
        notifications[1],
        client_side.third_out[0..listen.third_len],
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

        const Self = @This();

        fn run(self: *Self) void {
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
                    .decode_scratch = &self.side.decode_scratch,
                    .answer = &self.side.answer,
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
    defer group.cancel(io);
    var serve: Refuse = .{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .rejected = &rejected,
        .failed = &failed,
    };
    var reply: Reply = undefined;
    var client_failed = false;
    var call: Call = .{
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
    try group.concurrent(io, Refuse.run, .{&serve});
    try group.concurrent(io, Call.run, .{&call});
    try group.await(io);

    // The server refused the size and said so, and the client was told the
    // request went unanswered rather than being handed a truncated result.
    try testing.expect(rejected);
    try testing.expect(client_failed);
    try testing.expect(!got);
}

test "a reply this transport cannot read keeps its status instead of reading as no answer" {
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
    var reply: Reply = undefined;
    var got = false;
    var failed = false;
    var served = false;

    const Gateway = struct {
        io: Io,
        listener: *Io.net.Server,
        side: *Side,
        served: *bool,
        failed: *bool,

        const Self = @This();

        /// One POST, answered the way a peer in front of the endpoint answers
        /// one it cannot reach: a gateway's own status and a page of HTML
        /// rather than a JSON-RPC body.
        fn run(self: *Self) void {
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
                    .decode_scratch = &self.side.decode_scratch,
                    .answer = &self.side.answer,
                    .transfer = &self.side.transfer,
                    .event = &self.side.event,
                    .stream = &self.side.stream_buffer,
                },
            );
            // The request is served, so the answer below is a choice the
            // gateway made rather than a refusal this transport produced.
            const post = self.side.server.receive() catch {
                self.failed.* = true;
                return;
            } orelse {
                self.failed.* = true;
                return;
            };
            self.side.server.reject(.bad_gateway, "<html>502</html>") catch {
                self.failed.* = true;
                return;
            };
            self.served.* = post.method.len != 0;
        }
    };

    var group: Io.Group = .init;
    defer group.cancel(io);
    var serve: Gateway = .{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .served = &served,
        .failed = &failed,
    };
    var call: Call = .{
        .io = io,
        .http = &http_client,
        .endpoint = &endpoint,
        .side = &client_side,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\"," ++
            "\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":" ++
            "\"2026-07-28\"}}}",
        .spec = .{ .method = "tools/list" },
        .id = 4,
        .reply = &reply,
        .got = &got,
        .failed = &failed,
    };
    try group.concurrent(io, Gateway.run, .{&serve});
    try group.concurrent(io, Call.run, .{&call});
    try group.await(io);

    try testing.expect(!failed);
    try testing.expect(served);
    // The call returned a reply rather than `error.NoResponse`, so the caller
    // can read the status. Reported as an error, the `502` was thrown away and
    // the caller was told the peer never answered, which is the one thing
    // `Reply.status` exists not to do.
    try testing.expect(got);
    try testing.expectEqual(std.http.Status.bad_gateway, reply.status);
    // And the reply says so: there is no message, and no caller can mistake
    // the empty one for a JSON-RPC answer.
    try testing.expect(!reply.answered);
    try testing.expectEqual(@as(usize, 0), reply.message.len);
    try testing.expect(!reply.streamed);
}
