//! The A2A `1.0` unary JSON-RPC binding, over `std.http`.
//!
//! PROTOCOLS.md section 5 governs this file, and so does `research/normative/
//! a2a-1.0.0.md` where that document records the artifact's own words. Three
//! pieces are here and no more: [`select`] and [`discover`] read a peer's Agent
//! Card and choose an interface, [`Client`] sends one `SendMessage`, and
//! [`serve`] answers one request. A reply is either a `Task`, a `Message` or an
//! explicit JSON-RPC error, and the three are told apart rather than collapsed
//! into a flag.
//!
//! # What is deliberately not here
//!
//! No REST, no gRPC, no server-sent events, no push notification, no task store,
//! no signature verification and no authentication. A peer that needs any of
//! them is a peer this module refuses, which is a different answer from the one
//! it would give if it guessed. In particular nothing here follows a redirect:
//! a `SendMessage` whose body has already gone out cannot be replayed, and a
//! client that silently retried would be calling the method twice.
//!
//! # The endpoint is the advertised one
//!
//! The only URL this module ever POSTs to is the one a card advertises, with its
//! path and its query exactly as written. `/rpc` is never guessed, a relative
//! advertised URL is refused rather than resolved against the discovery origin,
//! and the discovery GET is always `a2a.discovery_path` on the caller's own
//! scheme, host and port, with the origin's path, query and fragment dropped. A
//! client that filled any of those in would be calling a peer on a request it
//! never named.
//!
//! # One version
//!
//! [`version`] is `1.0`, and the `A2A-Version` header carries the selected
//! interface's own `Major.Minor` on every request. Nothing here serves `0.3`:
//! `a2a.v0_3_method_aliases` is the codec's dispatch table for that revision,
//! and its presence does not mean a `0.3` method name or a `0.3` body is
//! accepted here. A request whose header is absent, empty (which the
//! specification reads as `0.3`), patched, or otherwise unsupported is refused
//! with `VersionNotSupportedError`.
//!
//! # An answer and an error are different things
//!
//! A peer's fault is answered on the wire, because the peer is the one waiting:
//! a refused version, an unknown method, invalid params, a malformed envelope,
//! an unknown path. The caller's own shortage is returned, because no answer
//! would be true of it: a body or a buffer that does not fit, and a handler that
//! failed. `error.BufferTooSmall` is never dressed up as a peer's fault, and a
//! handler that fails never becomes a success.
//!
//! Two peer faults are answered at the HTTP level rather than with a JSON-RPC
//! body, because no id has been read out of a body this module has not decoded:
//! a `Content-Type` that is not the JSON media type, and a body larger than the
//! caller's buffer.
//!
//! A `null` id is written only where JSON-RPC 2.0 writes one: on the answer to a
//! request this server could not identify. That is a parse error, where the
//! bytes are not JSON at all, and an invalid envelope whose id is absent or is
//! not an id value. A sound envelope with a legal integer or string id is
//! answered to that id whatever else is wrong with it, because a `null` there
//! would tell the peer its own id had been lost. That id is looked for on the
//! refusal path with `json.Reader`, the reader every decoder in this repository
//! walks with; there is no second parser here.
//!
//! # Ownership
//!
//! Every buffer is the caller's, on both sides, and no codec on this path
//! allocates: a `Task`, a `Message`, a card and every frame are composed into
//! memory the caller named. The one allocator in play is the borrowed
//! `std.http.Client`'s own, which spends it on its connection pool, and it is the
//! consumer's allocator and the consumer's pool. The `std.http.Client` is
//! borrowed, so its allocator, its executor and its connections stay the
//! consumer's; each entry point takes the `std.Io` it is to run on and
//! debug-asserts that it is the executor the borrowed client carries, because
//! two executors in one call is a call whose socket wait has no thread to run
//! on. [`Client.init`] and [`Client.sendMessage`] both take the `io` for that
//! reason and for no other.
//!
//! Nothing here copies on the caller's behalf: no returned value owns bytes of
//! its own. What a call hands back is a borrow, and a borrow lives until the
//! memory behind it is written again, not until the call returns. A [`Reply`]
//! borrows the buffers it was decoded from; a [`Discovery`] borrows the card
//! body and its arena, and through it a [`Binding`] and every [`Client`] built
//! on one do too. That is why `DiscoveryBuffers.body` and the card arena must
//! outlive the client: `Binding.uri` is the advertised URL itself, so a card
//! body written over takes the endpoint with it.
//!
//! The server's buffers are pairwise disjoint and `serve` proves it with
//! `conn.overlaps`, because each one is live at the same time as the answer
//! written over the next. `payload_out` is where the handler's answer is
//! composed and `envelope_out` is where the frame carrying it is written, and
//! the frame splices the first into the second, so one array behind both would
//! write the answer over itself. That proof is an assertion: live in `Debug`
//! and `ReleaseSafe`, compiled out in `ReleaseFast` and `ReleaseSmall`.
//!
//! # One request per call
//!
//! [`serve`] reads one head, answers it, and returns whether it answered one.
//! The bool is not a statement about the connection: whether another request may
//! follow is decided from the peer's own `Connection` and from this request's
//! framing, and a body that could not be drained takes it away. So the loop a
//! caller writes is "call again while it answered, hang up when it did not", and
//! a refusal counts as an answer — a `404` and a `405` are both a reply this
//! server wrote.
//!
//! # Scratch is reused exactly once
//!
//! The client decodes the JSON-RPC envelope into `SendBuffers.scratch`, checks
//! the id, the kind and the absence of an error, and only then decodes the typed
//! payload with the same buffer. That is safe because of what those three checks
//! leave behind: `jsonrpc.decode` borrows `result` out of the *input* and not
//! out of the scratch, and the only values it takes from the scratch are an
//! escaped `method`, an escaped string `id`, an escaped error `message` and
//! escaped object keys. After the checks the message is a response, so it carries
//! no `method`; its `id` was matched as an integer, so no string `id` was taken;
//! and it carries no `error`, so no error message was taken either. Nothing the
//! envelope decode left in the scratch is still live when the payload decode
//! overwrites it.
//!
//! # Where the sources disagree
//!
//! Three places, each resolved here in favour of the artifact this repository
//! pins, and each worth knowing about:
//!
//!   - The specification never writes the literal `A2A-Version: 1.0`: its
//!     examples are stale `0.3` and `0.5` values, while
//!     `AgentInterface.protocol_version` carries `1.0`. The header sent here is
//!     the selected interface's own `Major.Minor`, so a peer that advertises
//!     `1.0` is sent `1.0`.
//!   - Section 6.4's version-negotiation example is a bare RFC 9457
//!     problem-details object, which contradicts the `google.rpc.Status` shape
//!     section 11.6 uses for every other A2A error; the research document
//!     records the conflict as unresolved. This module answers with the JSON-RPC
//!     error the JSON-RPC binding is made of, and carries the normative
//!     `google.rpc.ErrorInfo` detail in its `data` member, because section 6.2
//!     requires that detail for A2A-specific errors and `data` is where a
//!     JSON-RPC error carries one.
//!   - PROTOCOLS.md section 5.6 maps each A2A error to an HTTP status, and
//!     `-32009` is `400`; an independent A2A implementation answers a refused
//!     call with `200` and the error in the body. The server follows
//!     PROTOCOLS.md, and the client reads the JSON-RPC error as the authority
//!     and keeps the status beside it, so a `200` answer and a `400` answer are
//!     the same fact to a caller of this module.

const std = @import("std");
const a2a = @import("a2a.zig");
const conn = @import("conn.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const root = @import("root.zig");

const Io = std.Io;
/// The standard library's HTTP, which is what this binding is written on.
/// `std.http` has no MCP-shaped gate to trip over: its `checkPost` analogue is
/// this file, and the rules it enforces are the ones PROTOCOLS.md section 5
/// states.
const wire = std.http;

const Self = @This();

const testing = std.testing;

// --- The binding ----------------------------------------------------------------

/// The one version this binding speaks.
///
/// `a2a.parseVersion` reads a card's `protocolVersion` and an `A2A-Version`
/// header into this shape, and the comparison is against this value, so the
/// version both ends speak has exactly one name in the file.
pub const version: a2a.Version = .{ .major = 1, .minor = 0 };

/// What this layer reports.
///
/// The codec errors are this library's own, so a caller that decodes bytes does
/// not have to know which protocol produced them. The rest are the transport
/// faults a caller has to tell apart: an answer that is not this call's answer
/// is not the same as an answer that is not JSON-RPC, and neither is the same as
/// no answer at all.
pub const Error = root.DecodeError || root.EncodeError || error{
    /// The socket failed, the peer hung up mid-reply, or the request never went
    /// out. Nothing about the call is known.
    Transport,
    /// The request is not one this server can answer: the head, the framing or
    /// the body is not a request.
    MalformedRequest,
    /// The reply is not a JSON-RPC message this client can read.
    MalformedResponse,
    /// A reply carried no bytes. No JSON-RPC message is zero bytes, so an empty
    /// body is not an empty result: nothing was answered.
    NoResponse,
    /// The message is a response to some other call: a different id, a string
    /// id, or no id at all.
    IdMismatch,
    /// A request or a notification arrived where this client was waiting for the
    /// response to its own call.
    UnexpectedMessage,
    /// A typed result arrived on a status that says the call failed.
    BadStatus,
    /// The reply's media type is not the one this binding uses, or the head
    /// carried it twice.
    UnsupportedMediaType,
    /// The body is larger than the buffer the caller sized. Refused rather than
    /// truncated: a truncated envelope is a different document.
    BodyTooLarge,
    /// The id space is exhausted. Ids are never wrapped and never reused.
    IdExhausted,
    /// A redirect where this client will not replay one: a `SendMessage` whose
    /// body has already gone out cannot be sent again.
    Redirected,
    /// The card advertises no interface this client speaks.
    UnsupportedInterface,
    /// An interface's `protocolVersion` is not a `Major.Minor` at all.
    MalformedVersion,
    /// An interface's URL is not a URL this binding can speak: it does not
    /// parse, or it names no host.
    MalformedUrl,
    /// An interface's URL is a URL this binding cannot speak: a scheme other
    /// than HTTP or HTTPS.
    UnsupportedScheme,
};

/// The `1.0` JSON-RPC method name for the one RPC this module serves, read out
/// of the codec's own service table rather than written beside it.
const send_method = rpcName("SendMessage");

/// The name the service table gives `name`, checked at compile time.
fn rpcName(comptime name: []const u8) []const u8 {
    for (a2a.rpcs) |rpc| {
        if (std.mem.eql(u8, rpc.name, name)) return rpc.name;
    }
    @compileError("the A2A service declares no RPC named " ++ name);
}

/// The `A2A-Version` value, written into a buffer the caller owns.
///
/// The header carries the selected interface's own `Major.Minor`, so a peer that
/// advertises `1.0` is sent `1.0`. The specification's own examples are stale
/// `0.3` and `0.5` values, which the research document records as such.
fn versionText(buffer: []u8) root.EncodeError![]const u8 {
    // `bufPrint` has one way to fail and this layer already has its name for
    // it: a buffer that cannot hold the header value is the caller's shortage,
    // reported as the codec's own rather than as a `std` detail.
    return std.fmt.bufPrint(buffer, "{d}.{d}", .{ version.major, version.minor }) catch
        error.BufferTooSmall;
}

/// Whether a `Content-Type` names the JSON media type of this binding.
///
/// The media type is compared without regard to case and without its
/// parameters, as RFC 9110 has it: a peer that adds `; charset=utf-8` is naming
/// the same type, and a client that compared the header text would refuse it.
fn isJsonMediaType(value: []const u8) bool {
    return isMediaType(value, a2a.jsonrpc_media_type);
}

/// Whether a `Content-Type` names a media type this protocol defines for a card.
///
/// A card is JSON, and the protocol registers two JSON media types for it: the
/// one the JSON-RPC binding uses and the REST one. A card served as either is a
/// card this client can read.
fn isCardMediaType(value: []const u8) bool {
    return isMediaType(value, a2a.jsonrpc_media_type) or
        isMediaType(value, a2a.rest_media_type);
}

fn isMediaType(value: []const u8, media_type: []const u8) bool {
    const end = std.mem.findScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), media_type);
}

/// The value of a header, matched without regard to case, or null.
fn firstHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// How many times a header appears, matched without regard to case.
///
/// A repeated `Content-Type` or `A2A-Version` is two answers to one question.
/// RFC 9110 allows a peer to send them and neither header has a rule saying
/// which one a reader may take, so both are refused rather than resolved by
/// order: the version decides which semantics apply, and the first one would let
/// a request be answered under a version its own second field contradicts.
fn headerCount(head: []const u8, name: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) count += 1;
    }
    return count;
}

/// The borrowed client and the call's `Io` must be the same executor.
///
/// Every wait `std.http` does runs on the executor its client carries, so a
/// caller that handed a different one has put two executors in a single call and
/// the socket wait has no thread to run on. An assert and not an error: it is a
/// caller's own mistake, made before anything is on the wire.
fn assertExecutor(io: Io, http_client: *wire.Client) void {
    std.debug.assert(io.userdata == http_client.io.userdata);
    std.debug.assert(io.vtable == http_client.io.vtable);
}

/// Map a `std.http` request failure onto this layer's, so a caller is not left
/// holding two spellings of one fault.
fn requestFailure(err: anyerror) Error {
    return switch (err) {
        error.UnsupportedUriScheme, error.UriMissingHost => error.UnsupportedScheme,
        else => error.Transport,
    };
}

// --- Selection -----------------------------------------------------------------

/// The endpoint a client will speak to, borrowed from the card that published
/// it.
///
/// It owns nothing and has no teardown, and it may be copied freely: a copy
/// names the same text on the same peer. `uri` holds slices into the card body
/// the caller decoded, so that body and its arena must outlive every copy and
/// every [`Client`] built from one.
pub const Binding = struct {
    /// The advertised URL, with its path and its query exactly as written. It
    /// borrows the card's own text, so the body it was decoded from must outlive
    /// it.
    uri: std.Uri,
    /// Which `supportedInterfaces` entry this is, so a caller can go back to the
    /// card for what the endpoint says about itself.
    interface_index: usize,
};

/// The first interface in `card` that this client speaks.
///
/// PROTOCOLS.md 5.3 makes the list ordered and the first supported entry the one
/// to use, so the walk is in the card's order and stops at the first match. An
/// entry this client does not speak, or speaks at another version, is skipped:
/// a card that lists a gRPC endpoint and a `0.3` one beside a `1.0` one is a card
/// with three interfaces, not a card that is unusable.
///
/// A malformed version or URL on a `JSONRPC` interface is a fault in the card
/// rather than an endpoint to move past. Skipping it would select a later
/// interface and answer a call against a document the peer did not offer for
/// this one, so both are errors and the caller is told which it was.
///
/// A relative URL is refused rather than resolved against the origin a client
/// discovered it on: the peer published no host, and filling one in is the guess
/// this module exists to refuse.
pub fn select(card: a2a.AgentCard) Error!Binding {
    for (card.supported_interfaces, 0..) |interface, index| {
        // The binding token is exact. `a2a.binding` holds the core identifiers,
        // which are bare tokens rather than URIs, and a custom binding URI is not
        // one of them.
        if (!std.mem.eql(u8, interface.protocol_binding, a2a.binding.jsonrpc)) continue;
        const advertised = a2a.parseVersion(interface.protocol_version) catch
            return error.MalformedVersion;
        if (advertised.major != version.major or advertised.minor != version.minor) continue;

        const uri = std.Uri.parse(interface.url) catch return error.MalformedUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
            !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedScheme;
        // An absolute URL with an empty authority parses without a host, and a
        // client with no host has nothing to connect to.
        if (uri.host == null) return error.MalformedUrl;
        return .{ .uri = uri, .interface_index = index };
    }
    return error.UnsupportedInterface;
}

// --- Discovery -----------------------------------------------------------------

/// Every buffer one discovery needs.
///
/// `transfer` and `body` must be different memory: the reader stages chunk data
/// through the first into the second, so one array behind both has a card
/// written over the bytes it is being copied out of. The rest are read and
/// written one at a time.
pub const DiscoveryBuffers = struct {
    /// Where `std.http` stages a chunked body. It must not be empty.
    transfer: []u8,
    /// The card, read whole.
    body: []u8,
    /// Backs the card decode, and any string in it that had to be unescaped.
    scratch: []u8,
};

/// A card, and the interface of it this client speaks to.
pub const Discovery = struct {
    /// The card as the peer wrote it, borrowed from `DiscoveryBuffers.body` and
    /// the arena.
    card: a2a.AgentCard,
    /// The endpoint to POST to, borrowed from the same body.
    binding: Binding,
};

/// Read a peer's Agent Card and choose an interface.
///
/// The request is a `GET` of `a2a.discovery_path` on the origin's own scheme,
/// host and port, with the origin's path, query and fragment dropped: a
/// discovery request that reused the caller's path would be asking a different
/// peer for a different document. The card is read whole into the caller's
/// buffer and decoded with `a2a.decodeAgentCard`, and the interface is chosen
/// from what the peer published.
///
/// The card's text, this scratch and the arena must all outlive the returned
/// binding and any client built from it, because the binding is that text.
///
/// The request is released before this returns, and nothing else is: every
/// buffer keeps whatever the peer sent, so an error leaves the caller with a
/// reusable buffer and no card. `error.BadStatus` is a peer that answered
/// something other than a card, and `error.BufferTooSmall` is the caller's own
/// storage rather than a fact about the peer's document.
///
/// This blocks on the socket for as long as the peer takes. No cancellation
/// point is inspected here, so a cancelled `Io` arrives as `error.Transport`.
pub fn discover(
    io: Io,
    http_client: *wire.Client,
    origin: std.Uri,
    buffers: DiscoveryBuffers,
    arena: *a2a.CardArena,
) Error!Discovery {
    assertExecutor(io, http_client);
    const target: std.Uri = .{
        .scheme = origin.scheme,
        .host = origin.host orelse return error.MalformedUrl,
        .port = origin.port,
        .path = .{ .raw = a2a.discovery_path },
        // The well-known path is absolute and carries no query of its own; the
        // origin's query belongs to whatever the caller was doing, not to
        // discovery.
        .query = null,
        .fragment = null,
    };

    var request = http_client.request(.GET, target, .{
        // No compressed variant of a card is defined, so advertising one would
        // only let a peer answer with something unreadable.
        .headers = .{ .accept_encoding = .omit },
        // A redirect is not followed. Discovery carries no body, so a redirect
        // could be replayed, and a client that followed one would be reading
        // whatever host the redirect named.
        .redirect_behavior = .not_allowed,
    }) catch |err| return requestFailure(err);
    // `std.http` points the response back into the request, so a request that
    // moved after the head arrived would leave that pointer aimed at a copy that
    // is gone.
    defer request.deinit();

    _ = request.sendBodiless() catch return error.Transport;
    const answered = try readAnswer(isCardMediaType, &request, buffers.transfer, buffers.body);
    // A card is a successful answer. A status that says the request failed and
    // a body that happens to parse are not a card, and reporting a decode
    // failure for one would name the wrong fault.
    if (answered.status.class() != .success) return error.BadStatus;
    const card = try a2a.decodeAgentCard(answered.body, arena, buffers.scratch);
    return .{ .card = card, .binding = try select(card) };
}

/// A reply's status and its body, already read and checked.
const Answered = struct {
    status: wire.Status,
    body: []const u8,
};

/// Read the reply to `request`: its status, and exactly one bounded body.
///
/// The head is read before the body reader is taken, because taking it
/// invalidates the head's strings. `content-length` and a chunked body are read
/// the same way, so a peer that frames its answer in chunks is read as one body
/// rather than as two, and a body longer than the caller's buffer is refused
/// rather than truncated.
fn readAnswer(
    comptime accepts: fn ([]const u8) bool,
    request: *wire.Client.Request,
    transfer: []u8,
    body: []u8,
) Error!Answered {
    var response = request.receiveHead(&.{}) catch |err| switch (err) {
        error.TooManyHttpRedirects => return error.Redirected,
        else => return error.Transport,
    };
    if (headerCount(response.head.bytes, "content-type") > 1) return error.UnsupportedMediaType;
    const status = response.head.status;
    const declared = response.head.content_type orelse return error.UnsupportedMediaType;
    if (!accepts(declared)) return error.UnsupportedMediaType;

    const reader = response.reader(transfer);
    var sink = Io.Writer.fixed(body);
    // A full fixed writer and a read fault are told apart, and neither is a
    // short read: the writer is handed `body` and nothing else, so the first
    // byte it cannot hold is a byte this client will not read, and
    // `streamRemaining` stops there rather than truncating.
    const len = reader.streamRemaining(&sink) catch |err| switch (err) {
        error.WriteFailed => return error.BodyTooLarge,
        error.ReadFailed => return error.Transport,
    };
    return .{ .status = status, .body = body[0..len] };
}

// --- The client -----------------------------------------------------------------

/// What a `SendMessage` was answered with.
///
/// The two arms are the `payload` `oneof` of `SendMessageResponse`, and the third
/// is the JSON-RPC error a peer refused the call with. Keeping the refusal a
/// third arm is the point: a peer that refused a call and a call that succeeded
/// are two different facts, and a result carrying an error object inside it
/// would report a refusal as an answer.
pub const Outcome = union(enum) {
    /// A typed answer: exactly one arm of the response `oneof`.
    result: a2a.SendMessageResponse,
    /// The error the peer answered with, exactly as it sent it: an unknown code,
    /// an unknown message and any `data` stay as they arrived rather than being
    /// classified into a code this library happens to know.
    peer_error: jsonrpc.Error,
};

/// What one call was answered with.
///
/// The status is beside the outcome and not folded into it, because the two come
/// from different places: an independent implementation answers a refusal with
/// `200` and this library answers one with the status PROTOCOLS.md 5.6 gives
/// that code, and the JSON-RPC error is the fact in both. A typed result on a
/// failure status is refused rather than reported, so an outcome here is either
/// the peer's own error or a success the peer's status agreed with.
///
/// Every slice borrows the buffers the call was given, and none of them outlives
/// the buffer it points into: reuse that buffer and the reply is over.
pub const Reply = struct {
    /// The status the peer answered with. Kept beside the outcome rather than
    /// folded into it, because the two come from different places.
    status: wire.Status,
    /// What the peer said: a typed answer, or the JSON-RPC error it refused
    /// the call with. A peer error is a successful return here, not a fault.
    outcome: Outcome,
};

/// Every buffer one `sendMessage` needs.
pub const SendBuffers = struct {
    /// Where `std.http` stages a chunked body. It must not be empty.
    transfer: []u8,
    /// The reply.
    body: []u8,
    /// Backs the envelope decode, and then the payload decode. See the module
    /// documentation for why one buffer may hold both, in that order.
    scratch: []u8,
    /// The typed request, before it is wrapped in an envelope.
    params: []u8,
    /// The JSON-RPC request that carries it.
    envelope: []u8,
    /// Backs the base64 of a `Part.raw` the request carries.
    base64: []u8,
};

/// A client for one advertised A2A endpoint.
///
/// It owns nothing and has no teardown. The borrowed `std.http.Client` carries
/// the allocator, the `Io` and the connection pool, and all three stay the
/// consumer's; the endpoint is a [`Binding`] whose slices borrow the card text
/// the caller decoded, so that text and its arena must outlive this client; and
/// every buffer a call needs is handed in per call. Closing the borrowed
/// client is the consumer's, not this type's.
///
/// One `Client` owns one id space and is used by one thread at a time:
/// `sendMessage` takes `*Client` and advances `next_id` without a lock, so two
/// threads sharing one would hand the same id to two calls. Nor may a `Client`
/// be copied once it is in use: a copy carries its own `next_id`, and the two
/// would mint the same ids and could not tell each other's answers apart. A
/// caller that wants concurrency gives each thread its own.
pub const Client = struct {
    /// Borrowed, and it must outlive this client: its allocator, its executor
    /// and its connection pool all belong to the consumer.
    http: *wire.Client,
    /// The endpoint, borrowed from the card that published it.
    binding: Binding,
    /// The next id this client will use. Monotonic from one, and zero once the
    /// space is exhausted, which is how a wrapped id is kept impossible.
    ///
    /// It is this client's own and is not synchronized, and a copy of the
    /// struct carries its own; both are why the type is not shared and not
    /// copied. A caller that sets it by hand takes over the id space with it.
    next_id: i64 = 1,

    /// Bind to `binding`, using the borrowed client's executor.
    ///
    /// A binding a caller built by hand rather than one `select` returned is
    /// checked here and not trusted, because this client is about to POST to it
    /// and a URL it cannot speak is a configuration fault with a name.
    ///
    /// `io` must be the executor the borrowed client carries; the two are
    /// compared with an assertion rather than an error, which is live in
    /// `Debug` and `ReleaseSafe` and compiled out in `ReleaseFast` and
    /// `ReleaseSmall`. Nothing is opened, allocated or retained here, so there
    /// is nothing to release and nothing that can block. `binding.uri` keeps
    /// borrowing the card text, which must outlive the returned client.
    pub fn init(io: Io, http_client: *wire.Client, binding: Binding) Error!Client {
        assertExecutor(io, http_client);
        if (!std.ascii.eqlIgnoreCase(binding.uri.scheme, "http") and
            !std.ascii.eqlIgnoreCase(binding.uri.scheme, "https")) return error.UnsupportedScheme;
        if (binding.uri.host == null) return error.MalformedUrl;
        return .{ .http = http_client, .binding = binding };
    }

    /// The id this call will use, and the one after it.
    ///
    /// Ids are never wrapped and never reused: the last id that may be handed
    /// out is the largest `i64`, and the call after it is refused rather than
    /// sending an id some earlier call already used. A wrapped id would make a
    /// late answer look like the answer to a request made long ago.
    fn takeId(self: *Client) Error!i64 {
        if (self.next_id == 0) return error.IdExhausted;
        const id = self.next_id;
        self.next_id = if (id == std.math.maxInt(i64)) 0 else id + 1;
        return id;
    }

    /// Send one unary `SendMessage` to the advertised endpoint.
    ///
    /// The request is the typed value the caller composed, encoded with
    /// `a2a.encodeSendMessageRequest` and wrapped in a JSON-RPC envelope, POSTed
    /// to the advertised URI as it stands: the same path, the same query, no
    /// substitution and no default. It carries `Content-Type` and `Accept` of
    /// `application/json` and the `A2A-Version` header bound to the selected
    /// interface's `Major.Minor`, and no MCP header of any kind.
    ///
    /// The returned [`Reply`] makes no copy of its own: every slice in it
    /// borrows `buffers.body`, `buffers.scratch` or `arena`, and each is live
    /// until the caller writes the buffer behind it again, not merely until
    /// this call returns.
    ///
    /// On a failure the request has been written and the connection released,
    /// and every buffer keeps what it held: nothing is left for the caller to
    /// release, and `error.BufferTooSmall` is the caller's own storage rather
    /// than a fact about the peer. The call is not retried, because its id is
    /// spent either way.
    ///
    /// This blocks on the socket for as long as the peer takes. No cancellation
    /// point is inspected here, so a cancelled `Io` arrives as
    /// `error.Transport`.
    ///
    /// Each call takes a new id even when a later step of the same call fails,
    /// and a call is never retried. A redirect is refused rather than followed:
    /// the body is already out, and a client that silently retried would be
    /// calling the method twice.
    ///
    /// A reply is one of three things: a typed answer, a JSON-RPC error, or a
    /// failure. An answer to another id, a null id, a notification, a request, a
    /// reply with no body and a body that is not JSON-RPC are all failures, never
    /// fast successes, because each of them leaves the call this client made
    /// unanswered.
    pub fn sendMessage(
        self: *Client,
        io: Io,
        request: a2a.SendMessageRequest,
        buffers: SendBuffers,
        arena: *a2a.ContentArena,
    ) Error!Reply {
        assertExecutor(io, self.http);
        const id = try self.takeId();

        // The typed request, then the envelope that carries it. Both encoders
        // validate their whole value before the first byte, so a value either
        // one refuses leaves both buffers as they were and nothing half-framed
        // goes on the wire.
        var params = json.Writer.init(buffers.params);
        try a2a.encodeSendMessageRequest(request, &params, buffers.base64);
        var envelope = json.Writer.init(buffers.envelope);
        try jsonrpc.encode(.{
            .kind = .request,
            .id = .{ .integer = id },
            .method = .{ .text = send_method, .category = "", .action = "" },
            .params = .{ .value = params.written() },
        }, &envelope);

        var version_buffer: [16]u8 = undefined;
        var headers = [_]wire.Header{
            .{ .name = "Accept", .value = a2a.jsonrpc_media_type },
            .{ .name = a2a.version_parameter, .value = try versionText(&version_buffer) },
        };
        var sent = self.http.request(.POST, self.binding.uri, .{
            .extra_headers = &headers,
            .headers = .{
                .content_type = .{ .override = a2a.jsonrpc_media_type },
                // No compressed variant of this binding is defined, so
                // advertising one would only let a peer answer with something
                // this client cannot read.
                .accept_encoding = .omit,
            },
            .redirect_behavior = .not_allowed,
        }) catch |err| return requestFailure(err);
        defer sent.deinit();

        sent.transfer_encoding = .{ .content_length = envelope.written().len };
        var out = sent.sendBodyUnflushed(&.{}) catch return error.Transport;
        out.writer.writeAll(envelope.written()) catch return error.Transport;
        out.end() catch return error.Transport;
        // `sendBodyUnflushed` above took the connection off the pool and wrote
        // this request's head through it, and it unwraps this same field
        // itself before it does, so a request that reached here cannot have
        // released it. The unwrap is this std wiring's invariant, not a fact a
        // peer can influence.
        // zwanzig-disable-next-line: optional-unwrap
        sent.connection.?.flush() catch return error.Transport;

        const answered = try readAnswer(isJsonMediaType, &sent, buffers.transfer, buffers.body);
        const message = jsonrpc.decode(answered.body, buffers.scratch) catch |err| switch (err) {
            // The caller's scratch, and nobody else's shortage.
            error.BufferTooSmall => return error.BufferTooSmall,
            // An empty body is not an empty result: no JSON-RPC message is zero
            // bytes, so a reply carrying none answered nothing.
            error.Truncated => if (answered.body.len == 0)
                return error.NoResponse
            else
                return error.MalformedResponse,
            // Everything else is a document this client cannot read as an answer.
            else => return error.MalformedResponse,
        };
        // A response is the only thing this client can be waiting for. A
        // notification or a request is a peer speaking something other than what
        // it was asked, and neither can be matched to a call.
        if (message.kind != .response) return error.UnexpectedMessage;
        const answer = switch (message.id orelse return error.IdMismatch) {
            .integer => |value| value,
            // A string id is legal JSON-RPC and is not an id this client mints,
            // so it is not the answer to any call it made.
            .string => return error.IdMismatch,
        };
        if (answer != id) return error.IdMismatch;

        if (message.rpc_error) |object| {
            // A peer error is a fact about the call, and it is explicit whatever
            // status carried it.
            return .{ .status = answered.status, .outcome = .{ .peer_error = object } };
        }
        const result = message.result orelse return error.MalformedResponse;
        // A typed result on a failure status is a document that cannot happen:
        // the peer said the call failed and sent a result anyway, and reading it
        // as a success would report a refusal as an answer.
        if (answered.status.class() != .success) return error.BadStatus;

        // The scratch is free from here, and the module documentation is the
        // proof: `result` borrows the *body*, not the scratch, and the checks
        // above left nothing the envelope decode put in the scratch still live.
        // A response carries no `method`, its `id` was an integer, and it carries
        // no `error` message to have unescaped.
        return .{
            .status = answered.status,
            .outcome = .{ .result = try a2a.decodeSendMessageResponse(result, arena, buffers.scratch) },
        };
    }
};

// --- The server -----------------------------------------------------------------

/// The typed answer a `SendMessage` is answered with.
///
/// The handler composes the value and returns it; `serve` encodes it, checks it
/// and writes it. The value may borrow the handler's own storage, which is what
/// makes an answer cost nothing to produce: it is used before the next call, and
/// nothing is copied on the way out. It must not borrow any of
/// [`ServerBuffers`], which `serve` writes over.
pub const Handler = struct {
    /// The handler's own state, passed back unchanged. Null reaches `call` as
    /// null; this module never reads it and never frees it.
    ctx: ?*anyopaque = null,
    /// The `1.0` `SendMessage` handler. A failure is returned to the caller of
    /// `serve` and never answered as a result: this transport cannot name a
    /// cause only the handler knows, and the caller owns the hang-up.
    ///
    /// It is called at most once per `serve`, inline on the thread that called
    /// it, before that call returns, and only for a message this server
    /// dispatched. It must not call back into `serve` on this server: the
    /// request it would read is the one being answered, and `std.http` allows
    /// one reply per head.
    ///
    /// `request` borrows the caller's [`ServerBuffers.body`] and
    /// `payload_scratch`, and the content arena, and it is live for this call
    /// only: the next `serve` decodes over all three again. A handler that
    /// keeps a slice of it keeps bytes the next call overwrites. The `Outcome`
    /// it returns is validated and written before `serve` returns, and it may
    /// borrow the handler's own storage.
    ///
    /// `io` is passed through from `serve`; no executor equality check is made
    /// on this server path. Its backend must stay alive through `serve` and the
    /// callback. A callback that retains the capability extends that keepalive.
    call: *const fn (?*anyopaque, Io, a2a.SendMessageRequest) anyerror!Outcome,
};

/// Every buffer one served request needs.
///
/// **All seven must be pairwise disjoint**, and [`serve`] proves it with
/// `conn.overlaps` before a request is read. The pairs are not a preference:
/// each one is a pair that is live at the same time as the answer written over
/// the next, and the frame splices the payload out of one into the other. A
/// caller that hands one array for two of them has a handler writing its answer
/// over the bytes it is reading the request from.
///
/// - `payload_out` and `envelope_out` against `body`, `envelope_scratch`,
///   `payload_scratch` and `base64`. The typed request the handler is given
///   borrows the two body regions and the two scratches, and the arena, so all
///   of them are still live while the answer is encoded into `payload_out` and
///   the frame that splices it is written into `envelope_out`.
/// - `payload_out` against `envelope_out`, the splice itself.
/// - `transfer` against `body`: the reader stages chunk data through the first
///   into the second, and a drain after a short read uses them both again.
/// - `envelope_scratch` against `payload_scratch`, so the envelope's own
///   unescaped strings are not overwritten by the typed decode that follows it.
///
/// The check is an assertion, so it is live in `Debug` and `ReleaseSafe` and is
/// compiled out in `ReleaseFast` and `ReleaseSmall`. A caller that hands two
/// regions sharing a byte gets a trap where the check is compiled in, and in
/// the two modes that remove it an answer is composed over the request it was
/// composed from.
///
/// A zero-length region is no region: `conn.overlaps` ignores one, so an empty
/// field costs nothing here. Every other field has to be non-empty for the work
/// it names, and `transfer` is the one that says so here.
pub const ServerBuffers = struct {
    /// Where `std.http` stages a chunked body. It must not be empty.
    transfer: []u8,
    /// The request body.
    body: []u8,
    /// Backs the envelope decode, and any string in it that had to be unescaped:
    /// a string id, an error message, an escaped key.
    envelope_scratch: []u8,
    /// Backs the typed request decode, and any string in it that had to be
    /// unescaped. A separate array from `envelope_scratch`, because the decoded
    /// request is still live when the answer is composed, and from
    /// `payload_out`, because the answer is composed out of that one.
    payload_scratch: []u8,
    /// Where the handler's answer is composed, returned to `serve` as a typed
    /// value's bytes. Nothing here is live while the envelope is written.
    payload_out: []u8,
    /// Where the frame carrying that answer is composed.
    envelope_out: []u8,
    /// Backs the base64 of a `Part.raw` the answer carries.
    base64: []u8,
};

/// One request, and the state one answer needs besides the head.
const Session = struct {
    io: Io,
    request: *wire.Server.Request,
    handler: Handler,
    buffers: ServerBuffers,
    arena: *a2a.ContentArena,
    /// Whether the connection may carry another request after this answer.
    ///
    /// Two facts decide it, and both are about the wire rather than about this
    /// module. The peer has to have asked for a persistent connection, which
    /// `HTTP/1.1` does by default and `HTTP/1.0` does not. And this request's
    /// end has to be knowable, because a head parsed out of the middle of a
    /// body is a different document than the peer sent.
    ///
    /// A request with neither `content-length` nor `transfer-encoding` is
    /// knowable only when its method carries no body at all. A `GET` names no
    /// body, so nothing on the wire is ambiguous about where the next request
    /// begins, and closing after one would refuse a connection to a peer that
    /// asked nothing wrong: the discovery GET and the calls made through the
    /// endpoint it advertises are meant to share one connection. A `POST` with
    /// no framing is a different fact: its body ends only at the close, so
    /// nothing may follow it on the wire and the connection is dropped rather
    /// than left to a reader that would take the next request as this one's
    /// body.
    ///
    /// A body this server refused part way through is the other reason to
    /// close, and it is recorded here rather than assumed: `std.http` will
    /// happily say a connection may be reused while the rest of a body is
    /// still on the socket, and the next head would then be parsed out of body
    /// bytes.
    reusable: bool,

    /// Write one answer.
    fn respond(
        self: *const Session,
        body: []const u8,
        status: wire.Status,
        extra: []const wire.Header,
    ) Error!void {
        self.request.respond(body, .{
            .status = status,
            .extra_headers = extra,
            .keep_alive = self.reusable,
        }) catch return error.Transport;
    }

    /// The JSON-RPC answer to `id`, or the refusal to an id this server could
    /// not find.
    ///
    /// A `null` id is written only where JSON-RPC 2.0 writes one, and it is
    /// encoded through `jsonrpc.encode` because `encodeResponse` always has an
    /// id to echo. An id that was read from the request is echoed in the arm it
    /// arrived in, so an integer stays an integer and a string stays a string.
    fn refuse(
        self: *const Session,
        id: ?jsonrpc.Id,
        object: jsonrpc.Error,
    ) Error!void {
        var frame = json.Writer.init(self.buffers.envelope_out);
        if (id) |known| {
            try jsonrpc.encodeResponse(addressedTo(known), null, object, &frame);
        } else {
            try jsonrpc.encode(.{
                .kind = .response,
                .id_null = true,
                .rpc_error = object,
            }, &frame);
        }
        var headers = [_]wire.Header{.{ .name = "Content-Type", .value = a2a.jsonrpc_media_type }};
        try self.respond(frame.written(), errorStatus(object.code), &headers);
    }

    /// A refusal with no JSON-RPC body, because no id has been read yet.
    fn reject(self: *const Session, status: wire.Status, extra: []const wire.Header) Error!void {
        try self.respond("", status, extra);
    }
};

/// The request an answer is addressed to.
///
/// `jsonrpc.encodeResponse` reads the id and nothing else, so a message this
/// server refused before it had a method is still answerable: the id is what a
/// peer matches on, and a method this server never dispatched is not part of an
/// answer.
fn addressedTo(id: jsonrpc.Id) jsonrpc.Request {
    return .{
        .id = id,
        .method = .{ .text = "", .category = "", .action = "" },
        .params = .absent,
    };
}

/// The HTTP status a JSON-RPC error code is answered on.
///
/// PROTOCOLS.md 5.6 gives every A2A error a status, and six of the nine share
/// `400`, so the code is what says which one this is. The standard codes are not
/// in that table: `-32603` is the internal error of the specification's own
/// category table and the rest are a call this server refused, which is a bad
/// request however it was spelled.
fn errorStatus(code: i32) wire.Status {
    if (a2a.A2aError.fromCode(code)) |known| return @fromBackingInt(@intCast(known.httpStatus()));
    return switch (code) {
        @backingInt(jsonrpc.StandardError.internal_error) => .internal_server_error,
        else => .bad_request,
    };
}

/// The `-32009` refusal, with the detail section 6.2 requires for an
/// A2A-specific code.
///
/// The detail is composed into the payload region, which is not live on a
/// refusal: the frame that splices it is written after, into the envelope
/// region, and the two are proven to be different memory before either is used.
fn refuseVersion(session: *const Session, id: ?jsonrpc.Id) Error!void {
    const reason = a2a.A2aError.version_not_supported;
    var detail = json.Writer.init(session.buffers.payload_out);
    try detail.slice("{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"domain\":\"");
    try detail.slice(a2a.error_domain);
    try detail.slice("\",\"reason\":\"");
    try detail.slice(reason.reason());
    try detail.slice("\"}");

    try session.refuse(id, .{
        .code = @backingInt(reason),
        .message = "Version not supported",
        .data = detail.written(),
    });
}

/// The standard refusal for `code`, with the message PROTOCOLS.md gives it.
fn refuseStandard(
    session: *const Session,
    id: ?jsonrpc.Id,
    code: jsonrpc.StandardError,
) Error!void {
    try session.refuse(id, .{
        .code = @backingInt(code),
        .message = switch (code) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
        },
    });
}

/// The id a message carries, read on the refusal path.
///
/// `jsonrpc.decode` refuses a whole message, so a request this server cannot
/// answer may still hold an id the peer is waiting to have echoed. The member
/// is found with `json.Reader.memberRaw`, which takes the first occurrence as
/// every decoder in this repository takes a repeated name, and the lexeme it
/// returns is read back with the same `json.Reader` a decoder would read it
/// with. There is no second walk here that could disagree with the decoders'
/// about which occurrence of a repeated name is the one.
///
/// That is the fallible form of the walk and not `json.memberText`, which
/// carries no error set and therefore reports every fault as an absent
/// member. A key carrying an escape has to be unescaped before its name can be
/// compared with `"id"`, and a buffer too narrow for one is this server's own
/// shortage: read as an absent member, the same bytes would answer a peer whose
/// id was right with a `null` one, and tell it its own identifier was lost.
///
/// A value that is not an id is no id: `null` is the specification's own
/// statement that there is none, and a float or an object is not something an
/// answer could be matched to.
///
/// `error.BufferTooSmall` is the caller's shortage and not a fact about the
/// peer's document, so it is passed on rather than read as "no id": an escaped
/// id, or an escaped spelling of the name that carries it, has to be unescaped
/// into the buffer the caller handed over, and a refusal here would report a
/// shortage of this server's own storage as a fault of a document this server
/// did read.
fn identifyId(raw: []const u8, scratch: []u8) error{BufferTooSmall}!?jsonrpc.Id {
    // The shared walk, in the one form of it that can say which faults are the
    // caller's. Everything else it reports is a fact about the document, and a
    // document this cannot read the members of holds no id to echo.
    var members = json.Reader.init(raw);
    const lexeme = (members.memberRaw("id", scratch) catch |err| switch (err) {
        error.BufferTooSmall => return error.BufferTooSmall,
        else => return null,
    }) orelse return null;
    // The lexeme borrows `raw` and not `scratch`, so a string read out of it
    // below either borrows the request or writes a region nothing still holds:
    // an escaped key the walk unescaped was compared and dropped, the reader
    // that held it is spent, and nothing here borrows the buffer above.
    var reader = json.Reader.init(lexeme);
    reader.skipWhitespace();
    const byte = reader.peek() orelse return null;
    if (byte == '"') {
        const text = reader.string(scratch) catch |err| switch (err) {
            error.BufferTooSmall => return error.BufferTooSmall,
            else => return null,
        };
        return .{ .string = text };
    }
    if (byte == '-' or (byte >= '0' and byte <= '9')) {
        const digits = reader.number() catch return null;
        // An id outside `i64` is no id this server can echo, and the document it
        // came from is refused either way. It is read as "no id" rather than as
        // a fault, because the fault is one of this library's widths and not
        // one of the peer's document.
        const value = std.fmt.parseInt(i64, digits, 10) catch return null;
        return .{ .integer = value };
    }
    return null;
}

/// Whether `raw` is one well-formed JSON document and nothing after it.
///
/// A decoder reports one error for "these bytes are not JSON" and for "this
/// value is not the type I read", and only the document itself says which of
/// the two a fault is. This is that distinction, drawn with the reader every
/// decoder in this repository walks with: one value skipped, then `atEnd`. No
/// parser is written here, no scratch is spent, because a skipped value
/// produces no slice, and no document this caller can decode is walked here
/// twice.
///
/// The escapes inside a string are checked on this walk as well, because
/// `json.Reader` checks them wherever they appear: a document whose only fault
/// is a lone surrogate is not JSON either, and is refused with the bytes.
fn wellFormed(raw: []const u8) bool {
    var reader = json.Reader.init(raw);
    var skipped: [0]u8 = undefined;
    reader.skipValue(skipped[0..]) catch return false;
    return reader.atEnd();
}

/// The typed `SendMessage` a message carries, or null when it is not one this
/// server can dispatch.
///
/// Null is not an error. On a request the caller answers `-32601` or `-32602`
/// with the id in hand, and on a notification there is no id and so no refusal
/// to send. The method and the `params` are read here so both paths agree on
/// what a dispatchable request is.
fn dispatchable(session: *const Session, message: jsonrpc.Message) Error!?a2a.SendMessageRequest {
    const method = message.method orelse return null;
    if (!std.mem.eql(u8, method.text, send_method)) return null;
    const params_text = switch (message.params) {
        .value => |text| text,
        .absent, .null_value => return null,
    };
    return a2a.decodeSendMessageRequest(
        params_text,
        session.arena,
        session.buffers.payload_scratch,
    ) catch |err| switch (err) {
        // The caller's scratch, not the peer's request.
        error.BufferTooSmall => return error.BufferTooSmall,
        // Every other refusal is a `params` body this server cannot read: a
        // wrong member name, a wrong type, a missing REQUIRED field.
        else => return null,
    };
}

/// Read the request body into the caller's buffer, bounded.
///
/// `content-length` and a chunked body are read the same way: the length the
/// peer gave is not the length this server can hold, and the bound is the
/// caller's buffer either way.
///
/// A `content-length` body that does not fit is refused before the reader is
/// taken, so `std.http`'s own `discardBody` drains it and the connection is
/// still reusable. A chunked body that does not fit has already been read part
/// way into when the writer fills, and `discardBody` does not drain a reader
/// that was taken: it reports the connection as reusable with the rest of the
/// body still on the socket, and the next `receiveHead` would parse it. So the
/// rest of that body is drained here, through the reader this call took.
///
/// A drain that does not finish is the other kind of answer, and it is not a
/// keep-alive one: the bytes it did not read are still on the socket, so a
/// head that follows would be parsed out of the middle of a body. The
/// connection is marked unusable in that case and the refusal closes it,
/// which is a fact about the wire rather than a promise this module cannot
/// keep.
fn readRequest(session: *Session) Error![]const u8 {
    const body = session.buffers.body;
    if (session.request.head.transfer_encoding == .none) {
        const length = session.request.head.content_length orelse return body[0..0];
        if (length > body.len) return error.BodyTooLarge;
        // A body of no bytes is read as no bytes, without asking the reader for
        // one: the reader is handed to `respond`'s own discard from here.
        if (length == 0) return body[0..0];
    }
    if (session.buffers.transfer.len == 0) return error.BufferTooSmall;
    const reader = session.request.server.reader.bodyReader(
        session.buffers.transfer,
        session.request.head.transfer_encoding,
        session.request.head.content_length,
    );
    var sink = Io.Writer.fixed(body);
    const len = reader.streamRemaining(&sink) catch |err| switch (err) {
        error.WriteFailed => {
            // The first byte this server will not hold ends the read. What is
            // left of the body is read past, through the reader this call
            // took, and a drain that does not finish leaves the connection
            // unusable rather than merely unread.
            if (reader.discardRemaining()) |_| {} else |_| {
                session.reusable = false;
            }
            return error.BodyTooLarge;
        },
        error.ReadFailed => return error.Transport,
    };
    return body[0..len];
}

/// Answer the card at the well-known path.
///
/// The card is written where a frame would have gone: no decode region is live
/// on this path, so the answer and the envelope are the same bytes at different
/// times rather than two regions at once.
fn answerCard(session: *const Session, card: a2a.AgentCard) Error!void {
    var payload = json.Writer.init(session.buffers.payload_out);
    try a2a.encodeAgentCard(card, &payload);
    var headers = [_]wire.Header{.{ .name = "Content-Type", .value = a2a.jsonrpc_media_type }};
    try session.respond(payload.written(), .ok, &headers);
}

/// Answer one `POST` to the configured endpoint.
///
/// The error set is inferred rather than named for the same reason `serve`'s
/// is: the handler's own failure reaches the caller as itself.
fn answerCall(session: *Session) !void {
    const head = session.request.head_buffer;

    // A media type this binding does not use is refused before the body is read,
    // and a `Content-Type` sent twice is refused rather than resolved: the head
    // parser keeps the first without saying so, so a server that trusted the
    // parsed field would be reading a header the peer did not mean to send last.
    if (headerCount(head, "content-type") > 1) {
        return session.reject(.unsupported_media_type, &.{});
    }
    const declared = session.request.head.content_type orelse
        return session.reject(.unsupported_media_type, &.{});
    if (!isJsonMediaType(declared)) return session.reject(.unsupported_media_type, &.{});

    // The version is read here and obeyed after the envelope is decoded, so an
    // id this server can determine is echoed rather than reported as lost.
    const claimed: ?a2a.Version = blk: {
        // Two version fields name no single version, which is the same fault as
        // naming one this server does not serve, and an absent value is `0.3` by
        // the specification's own rule. A value with a patch in it is not a
        // `Major.Minor` at all, and `parseVersion` refuses it rather than
        // truncating it.
        if (headerCount(head, a2a.version_parameter) != 1) break :blk null;
        const text = firstHeader(head, a2a.version_parameter) orelse break :blk null;
        const parsed = a2a.parseVersion(text) catch break :blk null;
        if (parsed.major != version.major or parsed.minor != version.minor) break :blk null;
        break :blk parsed;
    };

    const body = readRequest(session) catch |err| switch (err) {
        // A body this server will not hold is a peer's size, so it is answered
        // as one. The connection is reused only if `readRequest` could put the
        // body back where a head may follow it, and it says so itself.
        error.BodyTooLarge => return session.reject(.payload_too_large, &.{}),
        // The caller's storage, and nobody else's shortage.
        error.BufferTooSmall => return error.BufferTooSmall,
        else => return error.Transport,
    };

    const message = jsonrpc.decode(body, session.buffers.envelope_scratch) catch |err| switch (err) {
        error.BufferTooSmall => return error.BufferTooSmall,
        // A decoder reports one error for "these bytes are not JSON" and for
        // "this value is not the type I read", and only the document itself says
        // which of the two a fault is. PROTOCOLS.md table 3.1 answers the first
        // with `-32700` and the second with `-32600`, so a peer whose JSON was
        // read as not JSON has been told something false about a document it
        // wrote correctly. Which of the two this is is settled by the document
        // here, and only on this path: a message that decoded is never walked
        // a second time.
        error.Truncated, error.MalformedJson, error.InvalidUtf8 => {
            // Bytes that are not JSON name no id: there is no envelope to read
            // one from, and `-32700` is the answer to that.
            if (!wellFormed(body)) {
                const refused = try refuseStandard(session, null, .parse_error);
                return refused;
            }
            // JSON that is not a request this server can answer is what `-32600`
            // names, and the id is still in it.
            const invalid = try refuseStandard(
                session,
                try identifyId(body, session.buffers.payload_scratch),
                .invalid_request,
            );
            return invalid;
        },
        // The document is JSON and is not a request this server can answer. The
        // id may still be in it, so it is looked for rather than declared lost.
        else => {
            const invalid = try refuseStandard(
                session,
                try identifyId(body, session.buffers.payload_scratch),
                .invalid_request,
            );
            return invalid;
        },
    };

    switch (message.kind) {
        .request => {},
        // A notification has no answer to send, so there is nothing to put in a
        // frame: a frame that matched no id would be a message the peer is not
        // waiting for. What it does have is a method, and a method this server
        // implements is dispatched. A handler failure here is the caller's, as
        // it is for a request.
        .notification => {
            // A notification whose version this server does not serve is not
            // dispatched: the version decides which semantics apply, and a `0.3`
            // notification dispatched as `1.0` is the compatibility break the
            // version parameter exists to prevent. There is no id to refuse it
            // with, which is the same reason there is no answer.
            if (claimed != null) {
                if (try dispatchable(session, message)) |call| {
                    _ = try session.handler.call(session.handler.ctx, session.io, call);
                }
            }
            return session.reject(.accepted, &.{});
        },
        // A response posted to this endpoint is a peer speaking something other
        // than what it was asked.
        .response => {
            const refused = try refuseStandard(session, message.id, .invalid_request);
            return refused;
        },
    }

    // Past the switch above the message is a request, and `jsonrpc.decode`
    // derives `kind = .request` only where it also saw an `id`
    // (src/jsonrpc.zig:357), so the id the answer below is addressed to is
    // present. Reading it once here is what the refusals and the answer share.
    // zwanzig-disable-next-line: optional-unwrap
    const id = message.id.?;

    if (claimed == null) {
        const refused = try refuseVersion(session, id);
        return refused;
    }
    // Only `SendMessage` is served at `1.0` by this unary binding, and the `0.3`
    // aliases are not honoured: `a2a.v0_3_method_aliases` is the dispatch table
    // for that revision, and accepting a `0.3` method name would claim to
    // understand a `0.3` body this server never looked at.
    if (message.method) |method| {
        if (!std.mem.eql(u8, method.text, send_method)) {
            const refused = try refuseStandard(session, id, .method_not_found);
            return refused;
        }
    } else {
        const refused = try refuseStandard(session, id, .invalid_request);
        return refused;
    }
    // A `SendMessage` with no `params`, or with `null`, has no arguments to be
    // invalid, and a `params` body this server cannot read is `-32602` whichever
    // member was wrong.
    const call = try dispatchable(session, message) orelse {
        const refused = try refuseStandard(session, id, .invalid_params);
        return refused;
    };

    // The handler's failure is the caller's to see: it is returned rather than
    // turned into a result, and not dressed up as a wire error this transport
    // would have to invent a cause for.
    const outcome = try session.handler.call(session.handler.ctx, session.io, call);

    // The answer is validated before a byte of it is written. `payload_out` is
    // where the typed value is encoded and `envelope_out` is where the frame that
    // splices it is composed, so a value either encoder refuses leaves the
    // caller's buffers as they were and nothing half-written reaches the wire.
    var payload = json.Writer.init(session.buffers.payload_out);
    var frame = json.Writer.init(session.buffers.envelope_out);
    var status: wire.Status = .ok;
    switch (outcome) {
        .result => |value| {
            try a2a.encodeSendMessageResponse(value, &payload, session.buffers.base64);
            // The request's own id, read above, is the one the frame answers.
            try jsonrpc.encodeResponse(
                addressedTo(id),
                payload.written(),
                null,
                &frame,
            );
        },
        .peer_error => |object| {
            try jsonrpc.encodeResponse(addressedTo(id), null, object, &frame);
            // An A2A error is answered on the status its own table gives it, so a
            // peer that reads statuses reads the right one.
            status = errorStatus(object.code);
        },
    }
    var headers = [_]wire.Header{.{ .name = "Content-Type", .value = a2a.jsonrpc_media_type }};
    try session.respond(frame.written(), status, &headers);
}

/// Answer one request on `server`, or report that there was none to answer.
///
/// The returned bool says **whether this call answered a request**, not
/// whether the connection can be used again. `true` means a request head was
/// read and a reply was written for it, whatever that reply was — the card, a
/// result, a refusal, a `405`, or a `404`. `false` means no head was read, so
/// nothing was answered and the connection is finished for this caller.
///
/// Reusability is decided elsewhere and is not reported: it comes from the
/// peer's own `Connection` header and from this request's framing, and a body
/// that could not be drained lowers it.
///
/// A caller that needs to know may keep its own rule, and the safe one is: call
/// again after a `true`, and hang up after a `false`, an error, or a `true`
/// this caller knows left the connection closed.
///
/// A half-sent request is not a hang-up, and a peer that began one and did not
/// finish it is reported as a malformed request rather than as a connection
/// that closed politely.
///
/// Two endpoints are served and no third is invented: the well-known path
/// answers the card, and the endpoint is exactly the target the caller
/// configured, query included, because the caller chose it out of the card this
/// server publishes. A path this server does not serve is `404`, and a known
/// path with the wrong method is `405` with the methods it does serve on it.
///
/// The error set is the one this body can produce, which is wider than
/// [`Error`]: a handler may fail with anything at all, and that failure
/// reaches the caller as itself. Naming it would mean either refusing a cause
/// the handler knows or turning it into a transport fault, and both are lies
/// about what happened.
///
/// One request is answered per call, and a caller that wants the next one on
/// the same connection calls again until this returns false. Nothing is
/// allocated and nothing is released here: the buffers and the arena keep what
/// they held, the reply has already been written, and the caller closes the
/// connection itself.
///
/// This blocks on the socket for as long as the peer takes. The check that
/// [`ServerBuffers`] requires is an assertion, live in `Debug` and
/// `ReleaseSafe` and compiled out in `ReleaseFast` and `ReleaseSmall`.
pub fn serve(
    io: Io,
    server: *wire.Server,
    card: a2a.AgentCard,
    rpc_target: []const u8,
    handler: Handler,
    buffers: ServerBuffers,
    arena: *a2a.ContentArena,
) !bool {
    // Every pair of these seven, which is what the doc on `ServerBuffers` says
    // and why: the handler's request borrows the body and the two scratches
    // while its answer is composed and framed, and the frame splices the
    // payload out of one into the other. `conn.overlaps` is the predicate
    // every other disjointness check in this repository uses, and an assert and
    // not an error: these are the caller's own buffers, and no peer can have
    // arranged them. It is live in `Debug` and `ReleaseSafe` and compiled out
    // in `ReleaseFast` and `ReleaseSmall`.
    const regions = [_][]const u8{
        buffers.transfer,
        buffers.body,
        buffers.envelope_scratch,
        buffers.payload_scratch,
        buffers.payload_out,
        buffers.envelope_out,
        buffers.base64,
    };
    for (regions, 0..) |left, index| {
        for (regions[index + 1 ..]) |right| {
            std.debug.assert(!conn.overlaps(left, right));
        }
    }

    // Mutable, because an answer is written through a pointer to it.
    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return false,
        // A half-sent request is a peer that began one and did not finish it,
        // which is not a connection that closed politely.
        else => return error.MalformedRequest,
    };
    var session: Session = .{
        .io = io,
        .request = &request,
        .handler = handler,
        .buffers = buffers,
        .arena = arena,
        // Whether a head may follow this one, from the peer's own answer about
        // persistence and from this request's framing. A request with no body
        // is not by itself a reason to drop the connection: the discovery GET
        // that precedes every call would otherwise close the connection the
        // calls are meant to travel on, and the peer answering it has more to
        // send. `readRequest` lowers this for the case that really does leave
        // bytes of a body on the socket.
        .reusable = request.head.keep_alive and
            (request.head.transfer_encoding != .none or
                request.head.content_length != null or
                !request.head.method.requestHasBody()),
    };

    const target = request.head.target;
    if (std.mem.eql(u8, target, a2a.discovery_path)) {
        if (request.head.method != .GET) {
            const refused = try refuseMethod(&session, "GET");
            return refused;
        }
        try answerCard(&session, card);
        return true;
    }
    if (std.mem.eql(u8, target, rpc_target)) {
        if (request.head.method != .POST) {
            const refused = try refuseMethod(&session, "POST");
            return refused;
        }
        try answerCall(&session);
        return true;
    }
    try session.reject(.not_found, &.{});
    return true;
}

/// `405` with the methods this server does serve on that path.
fn refuseMethod(session: *const Session, allow: []const u8) Error!bool {
    var headers = [_]wire.Header{.{ .name = "Allow", .value = allow }};
    try session.reject(.method_not_allowed, &headers);
    return true;
}

// --- Fixtures -------------------------------------------------------------------

/// The card around a `supportedInterfaces` list, as one text.
///
/// Both halves are named so that a card composed at run time, around an
/// endpoint whose port the kernel only chose once, is the same document the
/// comptime fixtures build.
const card_head =
    "{\"name\":\"echo\",\"description\":\"An agent that echoes.\",\"supportedInterfaces\":";
const card_tail =
    ",\"version\":\"1.0\",\"capabilities\":{},\"defaultInputModes\":[]," ++
    "\"defaultOutputModes\":[],\"skills\":[]}";

/// The smallest legal card with the `supportedInterfaces` a test names, and
/// every other REQUIRED member present.
fn cardWith(comptime interfaces: []const u8) []const u8 {
    return card_head ++ interfaces ++ card_tail;
}

/// The same card, composed around an interface list only known at run time.
fn cardAround(buffer: []u8, interfaces: []const u8) Error![]const u8 {
    var out = Io.Writer.fixed(buffer);
    out.writeAll(card_head) catch return error.BufferTooSmall;
    out.writeAll(interfaces) catch return error.BufferTooSmall;
    out.writeAll(card_tail) catch return error.BufferTooSmall;
    return out.buffered();
}

/// The one interface these tests advertise, with a path and a query that are
/// both the peer's own, so an assertion about either cannot pass by accident.
const one_interface =
    "{\"url\":\"http://127.0.0.1:8080/agents/echo/a2a-v1?tenant=acme\"," ++
    "\"protocolBinding\":\"JSONRPC\",\"protocolVersion\":\"1.0\"}";

/// That same interface as a whole `supportedInterfaces` list.
const one_endpoint = "[" ++ one_interface ++ "]";

/// The same one interface, at the port a real peer is listening on.
///
/// A test that drives a socket has to advertise where the socket is: a card
/// naming a port nothing is listening on would have the client connect
/// somewhere else, or nowhere, and the endpoint it did reach would not be the
/// one the card published. It is written through a writer rather than through
/// a format string because the document is full of braces a format string
/// would want as escapes.
fn advertisedEndpoint(buffer: []u8, port: u16) Error![]const u8 {
    var out = Io.Writer.fixed(buffer);
    out.writeAll("[{\"url\":\"http://127.0.0.1:") catch return error.BufferTooSmall;
    out.print("{d}", .{port}) catch return error.BufferTooSmall;
    out.writeAll(
        "/agents/echo/a2a-v1?tenant=acme\"," ++
            "\"protocolBinding\":\"JSONRPC\",\"protocolVersion\":\"1.0\"}]",
    ) catch return error.BufferTooSmall;
    return out.buffered();
}

/// The endpoint `cardWith(one_endpoint)` advertises, which every test that
/// serves a slice configures as the target. It is the peer's own path and
/// query rather than one a client would guess.
const test_rpc_target = "/agents/echo/a2a-v1?tenant=acme";

/// Storage for one card decode, which is the nine arrays the arena fills.
const CardStorage = struct {
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    interfaces: [4]a2a.AgentInterface = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    skills: [2]a2a.AgentSkill = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    extensions: [2]a2a.AgentExtension = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    signatures: [2]a2a.AgentCardSignature = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    security_schemes: [2]a2a.SecuritySchemeEntry = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    security_requirements: [2]a2a.SecurityRequirement = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    requirement_entries: [4]a2a.SecurityRequirementEntry = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    scopes: [4]a2a.OAuthScope = undefined,
    // SAFETY: `init` points the arena at it; a decoded string is copied in before it is read.
    strings: [32][]const u8 = undefined,
    /// The document, as a caller would hold it: an interface URL is read out of
    /// here and not out of the scratch.
    // SAFETY: `decode` copies the document in and hands back only the run it copied.
    raw: [4096]u8 = undefined,
    // SAFETY: `decode` hands it to the decoder as the unescape region, written before read.
    scratch: [1024]u8 = undefined,
    // SAFETY: `init` assigns it over the arrays above before any `decode` call uses them.
    arena: a2a.CardArena = undefined,

    fn init(self: *CardStorage) void {
        self.arena = a2a.CardArena.init(
            &self.interfaces,
            &self.skills,
            &self.extensions,
            &self.signatures,
            &self.security_schemes,
            &self.security_requirements,
            &self.requirement_entries,
            &self.scopes,
            &self.strings,
        );
    }

    /// Copy `text` into the document buffer and decode it, so what the card
    /// borrows is memory this test owns rather than a string in rodata.
    fn decode(self: *CardStorage, text: []const u8) !a2a.AgentCard {
        if (text.len > self.raw.len) return error.BufferTooSmall;
        @memcpy(self.raw[0..text.len], text);
        return a2a.decodeAgentCard(self.raw[0..text.len], &self.arena, &self.scratch);
    }
};

/// Storage for one `SendMessage` payload decode, which is five arrays.
const ContentStorage = struct {
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    parts: [8]a2a.Part = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    artifacts: [2]a2a.Artifact = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    messages: [8]a2a.Message = undefined,
    // SAFETY: `init` points the arena at it; a decoded string is copied in before it is read.
    strings: [16][]const u8 = undefined,
    // SAFETY: `init` points the arena at it; a decoded run is copied in before it is read.
    bytes: [256]u8 = undefined,
    // SAFETY: `init` assigns it over the arrays above before any decode call uses them.
    arena: a2a.ContentArena = undefined,

    fn init(self: *ContentStorage) void {
        self.arena = a2a.ContentArena.init(
            &self.parts,
            &self.artifacts,
            &self.messages,
            &self.strings,
            &self.bytes,
        );
    }
};

/// Every buffer one client call needs, and the arena its answer is decoded into.
const SendFixture = struct {
    // SAFETY: `buffers` hands it to the client, which fills it on every call.
    transfer: [256]u8 = undefined,
    // SAFETY: `buffers` hands it to the client, which fills it on every call.
    body: [4096]u8 = undefined,
    // SAFETY: `buffers` hands it to the client as decode scratch, written before read.
    scratch: [2048]u8 = undefined,
    // SAFETY: `buffers` hands it to the client, which encodes the params into it.
    params: [1024]u8 = undefined,
    // SAFETY: `buffers` hands it to the client, which encodes the envelope into it.
    envelope: [2048]u8 = undefined,
    // SAFETY: `buffers` hands it to the client as the base64 run it encodes into.
    base64: [256]u8 = undefined,
    storage: ContentStorage = .{},

    fn init(self: *SendFixture) void {
        self.storage.init();
    }

    fn buffers(self: *SendFixture) Self.SendBuffers {
        return .{
            .transfer = &self.transfer,
            .body = &self.body,
            .scratch = &self.scratch,
            .params = &self.params,
            .envelope = &self.envelope,
            .base64 = &self.base64,
        };
    }
};

/// One request the client sends, as a typed value over static storage.
const ask: a2a.SendMessageRequest = .{
    .message = .{
        .message_id = "m-1",
        .role = .user,
        .parts = &.{.{ .content = .{ .text = "ping" } }},
    },
};

/// Which arm of the answer the test agent gives, so one handler covers all three.
const Arm = enum { message, task, peer_error };

/// The agent the server tests answer with, and the storage its answers borrow.
///
/// An answer borrows this struct, which is the handler contract: the value is
/// composed here, it is used before the next call, and nothing is copied on the
/// way out. `seen` is filled from the request's own text, so an assertion can
/// show that the typed request really crossed the socket, and every part array
/// an answer names is a field here rather than a temporary in `handle`, because
/// `serve` encodes the answer after the handler has returned.
const Agent = struct {
    arm: Arm = .message,
    fail: bool = false,
    calls: usize = 0,
    // SAFETY: `handle` copies the request text in and sets `seen_len` from that count.
    seen: [256]u8 = undefined,
    seen_len: usize = 0,
    // SAFETY: each arm of `handle` assigns element 0 before returning the outcome naming it.
    parts: [1]a2a.Part = undefined,
    // SAFETY: the task arm assigns element 0 before building the history entry borrowing it.
    history_parts: [1]a2a.Part = undefined,
    // SAFETY: the task arm assigns element 0 before the answer's `history` slice names it.
    history: [1]a2a.Message = undefined,

    // The parameter order is `Handler.call`'s own, and that function-pointer
    // type is a frozen part of this module's published surface, so the
    // executor stays where the type puts it rather than moving ahead of the
    // context the same type hands back.
    fn handle(
        ctx: ?*anyopaque,
        // `Handler.call` fixes this order; moving Io would break its callers.
        // ziglint-ignore: Z023
        io: Io,
        request: a2a.SendMessageRequest,
    ) anyerror!Self.Outcome {
        _ = io;
        const self: *Agent = @ptrCast(@alignCast(ctx orelse return error.NoAgent));
        self.calls += 1;
        const text = if (request.message.parts.len == 0) "" else switch (request.message.parts[0].content) {
            .text => |value| value,
            else => "",
        };
        self.seen_len = @min(text.len, self.seen.len);
        @memcpy(self.seen[0..self.seen_len], text[0..self.seen_len]);

        if (self.fail) return error.AgentUnavailable;

        return switch (self.arm) {
            .peer_error => .{ .peer_error = .{
                .code = @backingInt(a2a.A2aError.unsupported_operation),
                .message = "Unsupported operation",
            } },
            .message => blk: {
                self.parts[0] = .{ .content = .{ .text = self.seen[0..self.seen_len] } };
                break :blk .{ .result = .{ .message = .{
                    .message_id = "agent-1",
                    .role = .agent,
                    .parts = &self.parts,
                } } };
            },
            .task => blk: {
                self.history_parts[0] = .{ .content = .{ .text = self.seen[0..self.seen_len] } };
                self.history[0] = .{
                    .message_id = request.message.message_id,
                    .role = .user,
                    .parts = &self.history_parts,
                };
                self.parts[0] = .{ .content = .{ .text = self.seen[0..self.seen_len] } };
                break :blk .{ .result = .{ .task = .{
                    .id = "t-1",
                    .status = .{ .state = .working, .message = self.history[0] },
                    .history = self.history[0..1],
                } } };
            },
        };
    }
};

/// Storage for one server connection, and the two ways it can be attached: a
/// slice of bytes, which is deterministic, or a real accepted socket, which is
/// the wire.
const ServerFixture = struct {
    // SAFETY: `buffers` hands it to `serve`, which reads chunk lengths into it per request.
    transfer: [256]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve`, which fills it before parsing the answer.
    body: [4096]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve` as scratch it decodes into before using.
    envelope_scratch: [2048]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve` as scratch it decodes into before using.
    payload_scratch: [2048]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve`, which encodes the answer into it.
    payload_out: [4096]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve`, which encodes the reply envelope into it.
    envelope_out: [8192]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve` as the base64 run it encodes into.
    base64: [256]u8 = undefined,

    // SAFETY: `socket` hands this array to the stream reader it assigns below.
    reader_buffer: [8192]u8 = undefined,
    // SAFETY: `socket` hands this array to the stream writer it assigns below.
    writer_buffer: [8192]u8 = undefined,
    // SAFETY: `socket` assigns it; the `slice` path never reads it, and builds `http` on `reader`.
    stream_reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `socket` assigns it; the `slice` path never reads it, and builds `http` on `out`.
    stream_writer: Io.net.Stream.Writer = undefined,
    // SAFETY: `slice` assigns it, and only that path builds the server out of it.
    reader: Io.Reader = undefined,
    // SAFETY: `slice` assigns it, and every read of it is behind the `owns_out` flag it sets.
    out: Io.Writer.Allocating = undefined,
    owns_out: bool = false,
    // SAFETY: `slice` and `socket` each assign it before either serves a request.
    http: wire.Server = undefined,

    storage: ContentStorage = .{},

    fn init(self: *ServerFixture) void {
        self.storage.init();
    }

    /// Serve `requests`, which are the bytes a client put on the wire.
    fn slice(self: *ServerFixture, requests: []const u8) void {
        self.reader = .fixed(requests);
        self.out = .init(testing.allocator);
        self.owns_out = true;
        self.http = wire.Server.init(&self.reader, &self.out.writer);
    }

    /// Serve an accepted connection, whose reader and writer are fields because
    /// `wire.Server` keeps pointers to both.
    fn socket(self: *ServerFixture, io: Io, stream: Io.net.Stream) void {
        self.stream_reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.stream_writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.http = wire.Server.init(&self.stream_reader.interface, &self.stream_writer.interface);
    }

    /// Release the writer `slice` took, if this fixture took one.
    ///
    /// `socket` never owns a writer, so the flag is what says there is
    /// something to release, and clearing it is what makes this repeatable: a
    /// second call has nothing to free, and `answered` then reads nothing
    /// rather than bytes a released writer left behind.
    // Z030 wants a hardcoded lifecycle field; the lifecycle here is the writer
    // this fixture owns. `slice` takes one and `socket` attaches a stream
    // writer it does not own, so `owns_out` is that ownership: clearing it is
    // the teardown, and `answered` then reads no bytes rather than bytes a
    // released writer left behind.
    // ziglint-ignore: Z030
    fn deinit(self: *ServerFixture) void {
        if (self.owns_out) self.out.deinit();
        self.owns_out = false;
        self.out = undefined;
    }

    fn buffers(self: *ServerFixture) Self.ServerBuffers {
        return .{
            .transfer = &self.transfer,
            .body = &self.body,
            .envelope_scratch = &self.envelope_scratch,
            .payload_scratch = &self.payload_scratch,
            .payload_out = &self.payload_out,
            .envelope_out = &self.envelope_out,
            .base64 = &self.base64,
        };
    }

    /// Every byte the server has written so far, which is the whole of a
    /// keep-alive conversation.
    fn answered(self: *ServerFixture) []const u8 {
        if (!self.owns_out) return "";
        return self.out.written();
    }
};

/// One response, split out of a run of keep-alive answers.
const Frame = struct {
    /// The HTTP status.
    code: u16,
    /// The head, up to the blank line.
    head: []const u8,
    /// The body, read by its own `content-length`.
    body: []const u8,
    /// Everything after this one.
    rest: []const u8,
};

/// The first response in `bytes`, or null when there is none left.
fn nextFrame(bytes: []const u8) ?Frame {
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    const head = bytes[0..end];
    const length = std.fmt.parseInt(u16, header(head, "content-length") orelse return null, 10) catch
        return null;
    return .{
        .code = statusCode(head),
        .head = head,
        .body = bytes[end + 4 ..][0..length],
        .rest = bytes[end + 4 + length ..],
    };
}

/// The status code of a head, or 0.
fn statusCode(head: []const u8) u16 {
    const line_end = std.mem.findScalar(u8, head, '\r') orelse return 0;
    const line = head[0..line_end];
    const first = std.mem.findScalar(u8, line, ' ') orelse return 0;
    const second = std.mem.findScalarPos(u8, line, first + 1, ' ') orelse return 0;
    return std.fmt.parseInt(u16, line[first + 1 .. second], 10) catch 0;
}

/// The value of the named header in a raw head, matched without regard to case
/// as HTTP requires. Null when the head does not carry one.
fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// The request line of a raw head: the method, the target and the version.
fn requestLine(head: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    return head[0..end];
}

/// One scripted HTTP peer on a real loopback socket.
///
/// It answers raw bytes rather than going through a peer library, because the
/// cases below are the ones a conforming peer library would not produce: an
/// answer to another id, a notification where a response belongs, a media type
/// with a parameter, a repeated header and a chunked body. The test body opens
/// the connection before the group starts, which is what makes this task's
/// `accept` a call that returns rather than one that waits for a client that may
/// never come. The peer answers exactly as many requests as it was given, so a
/// test that makes fewer never leaves this task waiting for one more.
///
/// The peer is a task on the caller's group, and so is the client that talks
/// to it: `Io.Group` runs its members when the group is joined, so a client
/// driven from the body that would join it is waiting on a peer the group has
/// not started yet. `joinBounded` is the only place any of these groups is
/// joined, and it joins it under a deadline.
const Peer = struct {
    // SAFETY: `listen` assigns it, and every test calls `listen` before queueing `run`.
    listener: Io.net.Server = undefined,
    // SAFETY: `run` hands this array to the stream reader it assigns below.
    reader_buffer: [8192]u8 = undefined,
    // SAFETY: `run` hands this array to the stream writer it assigns below.
    writer_buffer: [8192]u8 = undefined,
    // SAFETY: `run` assigns it from the accepted stream before any request is read.
    stream_reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `run` assigns it from the accepted stream before any answer is written.
    stream_writer: Io.net.Stream.Writer = undefined,
    // SAFETY: `run` hands it to `bodyReader`, which fills it before reading through it.
    transfer: [256]u8 = undefined,
    // SAFETY: `run` builds it from the two fields above before it reads a request.
    http: wire.Server = undefined,

    /// The answers, one per request, in the order the client makes them.
    responses: []const []const u8,
    /// The head and the body of each request, as the bytes that arrived.
    // SAFETY: `run` copies the head in and sets `head_lens` from that same copy.
    heads: [4][4096]u8 = undefined,
    head_lens: [4]usize = @splat(0),
    // SAFETY: `run` fills it through `bodyReader` and sets `body_lens` from that count.
    bodies: [4][4096]u8 = undefined,
    body_lens: [4]usize = @splat(0),
    served: usize = 0,
    failed: bool = false,

    fn listen(self: *Peer, io: Io) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.listener = try address.listen(io, .{});
    }

    fn port(self: *const Peer) u16 {
        return self.listener.socket.address.getPort();
    }

    /// The head the `index`th request carried.
    fn head(self: *const Peer, index: usize) []const u8 {
        return self.heads[index][0..self.head_lens[index]];
    }

    /// The body the `index`th request carried.
    fn body(self: *const Peer, index: usize) []const u8 {
        return self.bodies[index][0..self.body_lens[index]];
    }

    fn run(self: *Peer, io: Io) void {
        const stream = self.listener.accept(io) catch {
            self.failed = true;
            return;
        };
        // `shutdown` before `close`. Every answer this peer gives has been
        // written and flushed before the loop ends, so the only bytes that
        // follow them on the wire are the client's own, already read here; a
        // plain `close` would end a socket whose peer has not drained its
        // receive queue, and a reset would discard the answers the client has
        // not read yet.
        defer {
            // A shutdown that failed changes nothing: `close` below ends the socket anyway.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            stream.shutdown(io, .both) catch {};
            stream.close(io);
        }
        self.stream_reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.stream_writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.http = wire.Server.init(&self.stream_reader.interface, &self.stream_writer.interface);

        for (self.responses) |response| {
            const index = self.served;
            const request = self.http.receiveHead() catch {
                self.failed = true;
                return;
            };
            const head_len = @min(request.head_buffer.len, self.heads[index].len);
            @memcpy(self.heads[index][0..head_len], request.head_buffer[0..head_len]);
            self.head_lens[index] = head_len;

            // A request with no body is not read, and taking the reader for
            // one is not a no-op: `bodyReader` hands back the raw stream when
            // nothing on the wire says where the body ends, and reading that
            // to the end is a wait for the peer's own hang-up. The discovery
            // GET is exactly that request, so a peer that read it as a body
            // would sit in the read and never write the card it was asked for.
            // Its body is zero bytes, which is what it is.
            if (request.head.transfer_encoding != .none or
                request.head.content_length != null)
            {
                const body_reader = self.http.reader.bodyReader(
                    &self.transfer,
                    request.head.transfer_encoding,
                    request.head.content_length,
                );
                var sink = Io.Writer.fixed(&self.bodies[index]);
                self.body_lens[index] = body_reader.streamRemaining(&sink) catch {
                    self.failed = true;
                    return;
                };
            }

            self.stream_writer.interface.writeAll(response) catch {
                self.failed = true;
                return;
            };
            self.stream_writer.interface.flush() catch {
                self.failed = true;
                return;
            };
            self.served += 1;
        }
        // The connection is closed on the way out, after the last answer has
        // been flushed: a client that made fewer calls than this peer was
        // scripted for still finds the end of them, and the client's own
        // `wire.Client` releases its end when the test body tears it down.
    }
};

/// The binding a socket test's client speaks to: this peer's own card, naming
/// the port the kernel gave it.
///
/// The card is decoded into `storage`, so the endpoint the binding borrows
/// outlives every call made through it.
fn peerBinding(peer: *const Peer, storage: *CardStorage) Error!Self.Binding {
    var endpoint: [128]u8 = undefined;
    var document: [512]u8 = undefined;
    return Self.select(try storage.decode(try cardAround(
        &document,
        try advertisedEndpoint(&endpoint, peer.port()),
    )));
}

/// A JSON reply from the peer, with the framing a conforming peer sends.
fn jsonReply(buffer: []u8, status: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "HTTP/1.1 {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ status, body.len, body },
    );
}

/// A JSON-RPC envelope carrying `result` under `id`, as a peer answers one
/// `SendMessage`.
///
/// One is composed per scripted call, because the id is the call's: this client
/// mints ids in order from one, and an answer that names any other id is
/// `error.IdMismatch` rather than an answer to it. A script that reused one id
/// across several steps would be exercising that check instead of whatever the
/// steps are for.
fn answerWithId(buffer: []u8, id: i64, result: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
        .{ id, result },
    );
}

/// A `params` object a `1.0` `SendMessage` decodes from.
const valid_params =
    "{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\"," ++
    "\"parts\":[{\"text\":\"ping\"}]}}";

/// A completed task, as a peer answers one.
const task_result =
    "{\"task\":{\"id\":\"t-1\",\"status\":{\"state\":\"TASK_STATE_COMPLETED\"}}}";

/// A message, as a peer answers one.
const message_result =
    "{\"message\":{\"messageId\":\"agent-1\",\"role\":\"ROLE_AGENT\"," ++
    "\"parts\":[{\"text\":\"pong\"}]}}";

/// How long one live exchange may take before its join reports a failure.
///
/// A test that hangs is a run the suite's own timeout ends, which says nothing
/// about what broke. Every group below is joined under a deadline, so a peer
/// that never answers is a failing assertion rather than a process somebody
/// has to kill. The bound is generous for a loopback exchange: it is there to
/// stop a wait, not to time anything.
const exchange_budget: Io.Duration = .fromSeconds(10);

/// Which of the two ended a join: the group drained, or the budget ran out.
const Join = union(enum) {
    drained: void,
    expired: void,
};

fn joinDrained(io: Io, group: *Io.Group) void {
    // This is the branch that reports the group having drained, and the fact
    // it returns is that report rather than the await's outcome. A join that
    // was cancelled means the deadline branch won, which the caller reads from
    // the tag, so there is nothing here that could turn the cancelation into a
    // different answer.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    group.await(io) catch {};
}

fn joinExpired(io: Io, budget: Io.Duration) void {
    // A sleep this task cannot finish still ends the wait, because the only
    // thing that can cancel it is the group having drained first. The
    // cancelation is the answer the caller wanted, not a fault to report.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    std.Io.sleep(io, budget, .awake) catch {};
}

/// Join `group`, bounded by `exchange_budget`. True when the budget was what
/// ended the wait.
///
/// `Io.Group` has one awaiter and one canceller at a time, and this is the
/// only place either happens: the select's group task is the awaiter, and
/// cancelling it is the canceller. Whichever of the two finished first, the
/// other is cancelled, so a deadline unwinds every task in the group rather
/// than leaving one parked on a socket.
///
/// That unwind is a join and not a notice, which is what makes it safe to read
/// a fixture's buffers once this returns. `Io.Select.cancelDiscard` cancels the
/// tasks the select owns and then blocks until they have all finished, and
/// `Io.Group.await` under cancellation passes the request on to every member
/// and still waits for the group to complete before it returns `error.Canceled`.
/// So when the budget wins, `cancelDiscard` is still waiting on a `joinDrained`
/// that is still waiting inside `Group.await`: every task the group held has
/// run its last line before the caller owns the stack again, and the buffers
/// that task was writing into are free of it.
fn joinBounded(io: Io, group: *Io.Group) Io.ConcurrentError!bool {
    var slots: [2]Join = undefined;
    var joining: Io.Select(Join) = .init(io, &slots);
    defer joining.cancelDiscard();
    try joining.concurrent(.drained, joinDrained, .{ io, group });
    try joining.concurrent(.expired, joinExpired, .{ io, exchange_budget });
    const first = joining.await() catch {
        // Only reachable if the caller's own scope is cancelled underneath
        // this, which nothing here does. Reporting the budget keeps a bounded
        // failure bounded.
        return true;
    };
    return switch (first) {
        .drained => false,
        .expired => true,
    };
}

/// What one scripted `SendMessage` is expected to be answered with.
///
/// The three wire outcomes are the three, and `failure` is this library's own
/// refusal, which is not an answer at all. A call the client could not
/// complete leaves the peer's request unmatched, and recording it as one of
/// the three would turn a transport fault into a success.
const Expect = union(enum) {
    task: void,
    message: void,
    peer_error: void,
    failure: anyerror,
};

/// Which of the three arrived, or `none` when the call was not answered.
const Arrived = enum { none, task, message, peer_error };

/// One scripted call, and what it was actually answered with.
///
/// The client task records both and the body that joined the group reads the
/// record: an assertion cannot be made from inside a task, and an answer that
/// borrows the task's own buffers is only readable while that task's storage
/// is still what it was decoded from.
const Step = struct {
    expect: Expect,
    /// The reply body to read into, where the whole buffer is not what the
    /// call needs. Zero is the whole of it, which is what every call but a
    /// deliberately undersized one wants.
    body_len: usize = 0,
    arrived: Arrived = .none,
    /// The refusal, when the call failed instead of being answered.
    failure: ?anyerror = null,
    /// The HTTP status the call was answered on.
    status: u16 = 0,
    /// A typed answer's id, and a task's state.
    // SAFETY: `makeCall` keeps an id in and stores the length `idText` slices with.
    id: [64]u8 = undefined,
    id_len: usize = 0,
    state: a2a.TaskState = .unspecified,
    /// A typed message answer's text.
    // SAFETY: `makeCall` keeps the part text in and stores the length `textOf` slices with.
    text: [128]u8 = undefined,
    text_len: usize = 0,
    /// A peer error, as the peer sent it.
    code: i32 = 0,
    // SAFETY: `makeCall` keeps the peer message and stores the length `messageText` slices.
    message: [128]u8 = undefined,
    message_len: usize = 0,
    // SAFETY: `makeCall` keeps the `data` member and stores the length `dataText` slices.
    data: [128]u8 = undefined,
    data_len: usize = 0,

    // The four accessors below and `matched` take the record by pointer, and
    // the slice ones are why. A by-value parameter is a copy the callee owns:
    // a slice handed back out of it does not outlive the call, so `steps[n]
    // .idText()` read the copy after it was gone and answered from whatever
    // the next call left on the stack. `keep` had done its work and the id was
    // in the record the test owns; only the way it was handed back was wrong.
    // A pointer receiver borrows that record, which is what a caller means.
    fn idText(self: *const Step) []const u8 {
        return self.id[0..self.id_len];
    }

    fn textOf(self: *const Step) []const u8 {
        return self.text[0..self.text_len];
    }

    fn messageText(self: *const Step) []const u8 {
        return self.message[0..self.message_len];
    }

    fn dataText(self: *const Step) []const u8 {
        return self.data[0..self.data_len];
    }

    /// Whether the call was answered the way the script said it would be.
    fn matched(self: *const Step) bool {
        return switch (self.expect) {
            .task => self.arrived == .task,
            .message => self.arrived == .message,
            .peer_error => self.arrived == .peer_error,
            .failure => |wanted| self.failure != null and self.failure.? == wanted,
        };
    }
};

/// The client half of a live exchange, as one task on the caller's group.
///
/// It owns the discovery GET, the calls and every buffer they need, and it
/// records what each call was answered with rather than asserting on it: a
/// task on a group has no way to fail the test that joined it, and an answer
/// that borrows this struct's own buffers expires when the test body moves on.
const Caller = struct {
    io: Io,
    /// The borrowed client, and with it the connection this task owns. It is
    /// a field of this task rather than of the body that queued it, because
    /// the task is what has to hang up on its peer: a server that serves
    /// until the connection ends is waiting for a close, and a client
    /// released after the join is a close the join has already waited for.
    // SAFETY: every construction sets this field, so `run` and its `deinit` both see it.
    http: wire.Client = undefined,
    /// The origin a discovery GET asks, or empty when this exchange has none
    /// because the test chose the endpoint itself.
    origin: []const u8 = "",
    /// The endpoint to POST to when there is no discovery.
    binding: ?Self.Binding = null,
    /// The card's own buffers, and not the call's: a binding a discovery
    /// returns is the card's own text, so the array the card went into has to
    /// outlive every call made through it. One array behind both the card and
    /// the first reply would POST to whatever the reply wrote there.
    // SAFETY: `discover` hands it to the library, which fills it on every discovery.
    card_transfer: [256]u8 = undefined,
    // SAFETY: `discover` hands it to the library, which fills it on every discovery.
    card_body: [4096]u8 = undefined,
    // SAFETY: `discover` hands it to the decoder, which unescapes into it before reading.
    card_scratch: [2048]u8 = undefined,
    card_storage: CardStorage = .{},
    /// Buffers for every call, reused between them, which is the discipline
    /// the module documents: nothing an earlier call decoded is still live
    /// once the next one starts.
    send: SendFixture = .{},
    /// The calls to make, in order, and where each is recorded.
    steps: []Step,
    /// What the discovery chose, and the name it read.
    found: ?Self.Binding = null,
    // SAFETY: `discover` keeps the name in and stores the length `name` slices with.
    card_name: [64]u8 = undefined,
    card_name_len: usize = 0,
    /// Set when the exchange could not be completed at all, so a fault inside
    /// a task reaches the body that joined the group.
    failed: bool = false,

    fn name(self: *const Caller) []const u8 {
        return self.card_name[0..self.card_name_len];
    }

    fn run(self: *Caller) void {
        // Every path out of this task closes the connection, so a peer
        // serving until the hang-up is released on the way out of all of them
        // rather than only on the one that succeeds.
        defer self.http.deinit();
        self.card_storage.init();
        self.send.init();
        if (self.origin.len != 0 and !self.discover()) return;
        const binding = self.binding orelse self.found orelse {
            self.failed = true;
            return;
        };
        var client = Self.Client.init(self.io, &self.http, binding) catch {
            self.failed = true;
            return;
        };
        for (self.steps) |*step| self.makeCall(&client, step);
        // An exchange that produced anything other than what each call was
        // told to expect has failed, wherever in the sequence it went wrong: a
        // refusal a call asked for is one answer, and any other is not.
        for (self.steps) |*step| {
            if (!step.matched()) self.failed = true;
        }
    }

    /// Read the card and keep the endpoint it publishes.
    fn discover(self: *Caller) bool {
        const origin = std.Uri.parse(self.origin) catch {
            self.failed = true;
            return false;
        };
        const found = Self.discover(self.io, &self.http, origin, .{
            .transfer = &self.card_transfer,
            .body = &self.card_body,
            .scratch = &self.card_scratch,
        }, &self.card_storage.arena) catch {
            self.failed = true;
            return false;
        };
        self.found = found.binding;
        self.card_name_len = keep(&self.card_name, found.card.name);
        return true;
    }

    /// One call, recorded in `step`.
    fn makeCall(self: *Caller, client: *Self.Client, step: *Step) void {
        var buffers = self.send.buffers();
        if (step.body_len != 0) buffers.body = self.send.body[0..step.body_len];
        const reply = client.sendMessage(
            self.io,
            ask,
            buffers,
            &self.send.storage.arena,
        ) catch |err| {
            step.failure = err;
            return;
        };
        step.status = @backingInt(reply.status);
        switch (reply.outcome) {
            .result => |value| switch (value) {
                .task => |task| {
                    step.arrived = .task;
                    step.id_len = keep(&step.id, task.id);
                    step.state = task.status.state;
                },
                .message => |message| {
                    step.arrived = .message;
                    step.id_len = keep(&step.id, message.message_id);
                    const text = if (message.parts.len == 0) "" else switch (message.parts[0].content) {
                        .text => |part| part,
                        else => "",
                    };
                    step.text_len = keep(&step.text, text);
                },
            },
            .peer_error => |object| {
                step.arrived = .peer_error;
                step.code = object.code;
                step.message_len = keep(&step.message, object.message);
                step.data_len = keep(&step.data, object.data orelse "");
            },
        }
    }
};

/// Keep a slice the client was handed, which borrows its own buffers, and
/// report how much of it fitted.
fn keep(destination: []u8, value: []const u8) usize {
    const len = @min(value.len, destination.len);
    @memcpy(destination[0..len], value[0..len]);
    return len;
}

/// Open the one connection a live exchange runs on, and hand it back to the
/// caller's pool before any task starts.
///
/// The connection is opened here rather than by the client task so that the
/// peer's `accept` is a call that returns: from the moment `connectTcp` has
/// answered, the kernel holds the connection and a peer that has not begun to
/// run yet still has something to accept. The pool counts it as in use until
/// it is released, and the first request made through the client is what
/// takes it from there.
fn connectPeer(io: Io, wire_client: *wire.Client, port: u16) !void {
    const host = try Io.net.HostName.init("127.0.0.1");
    wire_client.connection_pool.release(try wire_client.connectTcp(host, port, .plain), io);
}

// --- Tests ----------------------------------------------------------------------

test "the first JSONRPC interface at 1.0 is chosen, in the order the card lists them" {
    var storage: CardStorage = .{};
    storage.init();

    // Four interfaces and only the last is one this client speaks: a gRPC
    // endpoint, a JSON-RPC endpoint at a version this client does not
    // implement, one at `0.3`, the revision this runtime does not serve, and
    // the one that answers. PROTOCOLS.md 5.3 makes the list ordered and the
    // first supported entry the one to use, so a client that took the third
    // would be calling a revision it does not speak.
    const card = try storage.decode(cardWith(
        "[{\"url\":\"https://example.com/grpc\",\"protocolBinding\":\"GRPC\"," ++
            "\"protocolVersion\":\"1.0\"}," ++
            "{\"url\":\"https://example.com/two\",\"protocolBinding\":\"JSONRPC\"," ++
            "\"protocolVersion\":\"2.0\"}," ++
            "{\"url\":\"https://example.com/old\",\"protocolBinding\":\"JSONRPC\"," ++
            "\"protocolVersion\":\"0.3\"}," ++
            one_interface ++ "]",
    ));

    const binding = try Self.select(card);
    try testing.expectEqual(@as(usize, 3), binding.interface_index);

    // The advertised URL is used as it stands, path and query both, because
    // the query is the tenant this endpoint answers for and a client that
    // dropped it would be calling a different endpoint.
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("http", binding.uri.scheme);
    try testing.expectEqualStrings("127.0.0.1", try binding.uri.host.?.toRaw(&buffer));
    try testing.expectEqual(@as(?u16, 8080), binding.uri.port);
    try testing.expectEqualStrings("/agents/echo/a2a-v1", try binding.uri.path.toRaw(&buffer));
    try testing.expectEqualStrings("tenant=acme", try binding.uri.query.?.toRaw(&buffer));
}

test "a malformed version and a URL that is not absolute HTTP are errors, not skips" {
    var storage: CardStorage = .{};
    storage.init();

    // A patch component is not a `Major.Minor` at all, on an interface whose
    // binding this client does speak. It is a fault in the card rather than
    // an endpoint to move past: skipping it would select some later
    // interface and answer a call against a document the peer did not offer
    // for this one.
    {
        const card = try storage.decode(cardWith(
            "[{\"url\":\"http://127.0.0.1:8080/a2a\",\"protocolBinding\":\"JSONRPC\"," ++
                "\"protocolVersion\":\"1.0.0\"}]",
        ));
        try testing.expectError(error.MalformedVersion, Self.select(card));
    }
    // A relative URL is not something a client may resolve on its own: the
    // peer published no host, and filling one in from the discovery origin
    // would be the guess this module exists to refuse.
    {
        const card = try storage.decode(cardWith(
            "[{\"url\":\"/agents/echo/a2a-v1\",\"protocolBinding\":\"JSONRPC\"," ++
                "\"protocolVersion\":\"1.0\"}]",
        ));
        try testing.expectError(error.MalformedUrl, Self.select(card));
    }
    // A well-formed URL this binding cannot speak is a different fact from a
    // malformed one, and the two are told apart so a caller can say which
    // it was.
    {
        const card = try storage.decode(cardWith(
            "[{\"url\":\"ftp://127.0.0.1/agents\",\"protocolBinding\":\"JSONRPC\"," ++
                "\"protocolVersion\":\"1.0\"}]",
        ));
        try testing.expectError(error.UnsupportedScheme, Self.select(card));
    }
}

test "a card with no interface this client speaks is refused" {
    var storage: CardStorage = .{};
    storage.init();
    try testing.expectError(error.UnsupportedInterface, Self.select(try storage.decode(cardWith("[]"))));

    // And an interface at `0.3`, which the codec knows and this runtime does
    // not serve, is refused for the same reason. The codec's alias table is
    // a `0.3` dispatch table, and a client that honoured it here would
    // claim to speak a revision it does not.
    const old = try storage.decode(cardWith(
        "[{\"url\":\"http://127.0.0.1:8080/old\",\"protocolBinding\":\"JSONRPC\"," ++
            "\"protocolVersion\":\"0.3\"}]",
    ));
    try testing.expectError(error.UnsupportedInterface, Self.select(old));
}

test "the binding borrows the advertised text and not the decode scratch" {
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));
    const binding = try Self.select(card);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("/agents/echo/a2a-v1", try binding.uri.path.toRaw(&buffer));

    // The endpoint is the card's own text, and the scratch is where a
    // decoder puts the strings it had to unescape. This binding holds no
    // scratch region, so overwriting all of it cannot change the endpoint; a
    // binding that had copied an unescaped string out of the scratch would
    // change here, and a caller that reused its scratch would then POST to
    // whatever bytes landed there next.
    @memset(&storage.scratch, 0xaa);
    try testing.expectEqualStrings("/agents/echo/a2a-v1", try binding.uri.path.toRaw(&buffer));
    try testing.expectEqualStrings("tenant=acme", try binding.uri.query.?.toRaw(&buffer));
    try testing.expectEqualStrings("http", binding.uri.scheme);
}

test "discovery reads the well-known path of the origin and binds what the card advertises" {
    const io = testing.io;
    const document = cardWith(one_endpoint);
    var reply: [4096]u8 = undefined;
    const answer = try jsonReply(&reply, "200 OK", document);

    var peer: Peer = .{ .responses = &.{answer} };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    // The origin carries the peer's own port and a path and a query besides.
    // Discovery asks for the well-known path on the same scheme, host and port
    // and for nothing else, because a discovery request that reused the
    // caller's path would be asking a different peer for a different document.
    var origin_text: [64]u8 = undefined;
    // No calls: this exchange is the discovery GET on its own, and a caller
    // with nothing to send is still a client that opened a connection.
    var steps: [0]Step = .{};
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .origin = try std.fmt.bufPrint(
            &origin_text,
            "http://127.0.0.1:{d}/ignored/path?dropped=1",
            .{peer.port()},
        ),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    // Both ends are on one caller-owned group and the body only joins it: a
    // client driven from here would be waiting on a peer the group has not
    // started, and the join is bounded so a peer that never answers fails the
    // test rather than the run.
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));

    try testing.expect(!peer.failed);
    try testing.expect(!caller.failed);
    try testing.expectEqual(@as(usize, 1), peer.served);
    try testing.expectEqualStrings(
        "GET /.well-known/agent-card.json HTTP/1.1",
        requestLine(peer.head(0)),
    );

    // The card decoded into the caller's arena, and the binding is the
    // endpoint the card published rather than one derived from the origin.
    try testing.expectEqualStrings("echo", caller.name());
    const found = caller.found orelse return error.TestUnexpectedResult;
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "/agents/echo/a2a-v1",
        try found.uri.path.toRaw(&buffer),
    );
    try testing.expectEqualStrings("tenant=acme", try found.uri.query.?.toRaw(&buffer));
    // The endpoint is the one the card published, port and all: a binding built
    // out of the origin would have called the peer's port rather than the
    // 8080 this card names.
    try testing.expectEqual(@as(?u16, 8080), found.uri.port);
}

test "a send posts the advertised endpoint, the bound version, and nothing else" {
    const io = testing.io;
    var reply: [512]u8 = undefined;
    const answer = try jsonReply(&reply, "200 OK", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":" ++ task_result ++ "}");

    var peer: Peer = .{ .responses = &.{answer} };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    var storage: CardStorage = .{};
    storage.init();
    var steps = [_]Step{.{ .expect = .task }};
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .binding = try peerBinding(&peer, &storage),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));
    try testing.expect(!peer.failed);
    try testing.expect(steps[0].matched());

    // The method line is the advertised path with its query, the version is
    // the selected interface's own `Major.Minor`, and the body is the typed
    // request inside a `1.0` JSON-RPC envelope.
    try testing.expectEqualStrings(
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1",
        requestLine(peer.head(0)),
    );
    try testing.expectEqualStrings("1.0", header(peer.head(0), "a2a-version").?);
    try testing.expectEqualStrings("application/json", header(peer.head(0), "content-type").?);
    try testing.expectEqualStrings("application/json", header(peer.head(0), "accept").?);
    // This binding is A2A and not MCP, so no MCP header may appear on it,
    // whatever a peer has learned to expect.
    try testing.expectEqual(@as(usize, 0), headerCount(peer.head(0), "mcp-protocol-version"));
    try testing.expectEqual(@as(usize, 0), headerCount(peer.head(0), "mcp-session-id"));

    const sent = peer.body(0);
    try testing.expect(std.mem.indexOf(u8, sent, "\"method\":\"SendMessage\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"messageId\":\"m-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"role\":\"ROLE_USER\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "{\"text\":\"ping\"}") != null);
}

test "a task answer, a message answer and a peer error are told apart by what arrived" {
    const io = testing.io;
    var buffer: [3][512]u8 = undefined;
    const answers = [_][]const u8{
        try jsonReply(&buffer[0], "200 OK", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":" ++ task_result ++ "}"),
        try jsonReply(&buffer[1], "200 OK", "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":" ++ message_result ++ "}"),
        try jsonReply(&buffer[2], "200 OK", "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-31999," ++
            "\"message\":\"no such thing\",\"data\":{\"why\":\"unknown\"}}}"),
    };

    var peer: Peer = .{ .responses = &answers };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    var storage: CardStorage = .{};
    storage.init();
    var steps = [_]Step{
        .{ .expect = .task },
        .{ .expect = .message },
        .{ .expect = .peer_error },
    };
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .binding = try peerBinding(&peer, &storage),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));
    try testing.expect(!peer.failed);
    for (&steps) |*step| try testing.expect(step.matched());

    // A task and a message are the two arms of one `oneof`, so the arm is
    // the answer and not a flag beside it, and the task's own members survive
    // the trip rather than being restated by the reader.
    try testing.expectEqual(@as(u16, 200), steps[0].status);
    try testing.expectEqualStrings("t-1", steps[0].idText());
    try testing.expectEqual(a2a.TaskState.completed, steps[0].state);

    // The message arm keeps its own members, and a text part stays the text
    // the peer wrote rather than something reinterpreted on the way in.
    try testing.expectEqual(@as(u16, 200), steps[1].status);
    try testing.expectEqualStrings("agent-1", steps[1].idText());
    try testing.expectEqualStrings("pong", steps[1].textOf());

    // A peer error is a fact about the call and not a failure of the
    // transport, and it carries the code, the message and the data the peer
    // sent. A code this library does not classify stays exactly as it
    // arrived: re-labelling it would invent a cause the peer did not name.
    try testing.expectEqual(@as(i32, -31999), steps[2].code);
    try testing.expectEqualStrings("no such thing", steps[2].messageText());
    try testing.expectEqualStrings("{\"why\":\"unknown\"}", steps[2].dataText());
    try testing.expect(a2a.A2aError.fromCode(steps[2].code) == null);
    try testing.expectEqual(@as(usize, 3), peer.served);
}

test "a peer error is explicit whatever status carried it, and a result on a failure status is not a result" {
    const io = testing.io;
    var buffer: [2][512]u8 = undefined;
    const refused = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":" ++
        "{\"code\":-32009,\"message\":\"Version not supported\"}}";
    const answers = [_][]const u8{
        // An independent implementation answers a refusal on `200` and this
        // library answers one on `400`. The JSON-RPC error is the fact in
        // both, and the status is reported beside it rather than deciding
        // whether there was an answer at all.
        try jsonReply(&buffer[0], "400 Bad Request", refused),
        // The other direction, and the one this test is named for: a typed
        // result carried on a status that says the call failed. The status is
        // the whole of what is refused, so the scripted one has to be a
        // failure status; a `200` beside this body would be a success and
        // there would be nothing here to refuse.
        try jsonReply(&buffer[1], "400 Bad Request", "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":" ++
            task_result ++ "}"),
    };

    var peer: Peer = .{ .responses = &answers };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    var storage: CardStorage = .{};
    storage.init();
    var steps = [_]Step{
        .{ .expect = .peer_error },
        .{ .expect = .{ .failure = error.BadStatus } },
    };
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .binding = try peerBinding(&peer, &storage),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));
    try testing.expect(!peer.failed);
    for (&steps) |*step| try testing.expect(step.matched());

    try testing.expectEqual(@as(u16, 400), steps[0].status);
    try testing.expectEqual(
        a2a.A2aError.version_not_supported,
        a2a.A2aError.fromCode(steps[0].code).?,
    );
    // A typed result carried on a failure status is a document that cannot
    // happen: the peer said the call failed and sent a result anyway, and
    // reading it as a success would report a refusal as an answer. The second
    // call reached the wire and was not answered as a success, which is what
    // its `BadStatus` says and where `arrived` is still `none`.
    try testing.expectEqual(Arrived.none, steps[1].arrived);
    try testing.expectEqual(@as(usize, 2), peer.served);
}

test "an answer to another id, a notification, a request and an empty body are all errors" {
    const io = testing.io;
    var buffer: [4][512]u8 = undefined;
    const answers = [_][]const u8{
        try jsonReply(&buffer[0], "200 OK", "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":" ++ task_result ++ "}"),
        try jsonReply(&buffer[1], "200 OK", "{\"jsonrpc\":\"2.0\",\"method\":\"SendMessage\"}"),
        try jsonReply(&buffer[2], "200 OK", "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"GetTask\"}"),
        try jsonReply(&buffer[3], "200 OK", ""),
    };

    var peer: Peer = .{ .responses = &answers };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    var storage: CardStorage = .{};
    storage.init();
    var steps = [_]Step{
        // An answer to another id is not this call's answer, and it is not a
        // fast success either: nothing this client asked was answered.
        .{ .expect = .{ .failure = error.IdMismatch } },
        // A notification where a response belongs cannot be matched to a call
        // this client made, and a request where an answer belongs is a peer
        // speaking something other than what it was asked.
        .{ .expect = .{ .failure = error.UnexpectedMessage } },
        .{ .expect = .{ .failure = error.UnexpectedMessage } },
        // An empty body is not an empty result. No JSON-RPC message is zero
        // bytes, so a reply that carries none answered nothing.
        .{ .expect = .{ .failure = error.NoResponse } },
    };
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .binding = try peerBinding(&peer, &storage),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));
    try testing.expect(!peer.failed);
    // Each of the four was refused by name, and none of them was recorded as
    // an answer: a document this client cannot match is a failure of the call,
    // not a fourth kind of reply.
    for (&steps) |*step| {
        try testing.expect(step.matched());
        try testing.expectEqual(Arrived.none, step.arrived);
    }
    try testing.expectEqual(@as(usize, 4), peer.served);
}

test "a reply larger than the caller's buffer is refused rather than truncated" {
    const io = testing.io;
    // A reply whose body is longer than the buffer the caller sized, and a
    // legal one: the padding is the text of a real part, so the document this
    // client refuses is a document it would otherwise have answered. A
    // truncated envelope is a different document, and one that happened to
    // close cleanly would be a silent wrong answer.
    var padding: [512]u8 = @splat('x');
    var document: [2048]u8 = undefined;
    var writer = json.Writer.init(&document);
    try writer.slice("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"message\":{\"messageId\":");
    try writer.string("agent-1");
    try writer.slice(",\"role\":\"ROLE_AGENT\",\"parts\":[{\"text\":\"");
    try writer.slice(&padding);
    try writer.slice("\"}]}}}");
    var answer: [4096]u8 = undefined;
    const framed = try std.fmt.bufPrint(
        &answer,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ writer.written().len, writer.written() },
    );

    var peer: Peer = .{ .responses = &.{framed} };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    var storage: CardStorage = .{};
    storage.init();
    // The same call with the caller's own body buffer, which is a quarter of
    // what the reply needs.
    var steps = [_]Step{.{ .expect = .{ .failure = error.BodyTooLarge }, .body_len = 256 }};
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .binding = try peerBinding(&peer, &storage),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));
    try testing.expect(!peer.failed);
    try testing.expect(steps[0].matched());
    // A refusal is not a truncated answer: nothing was decoded, so there is no
    // arm to have arrived and no status read off a body the client refused to
    // finish reading.
    try testing.expectEqual(Arrived.none, steps[0].arrived);
    try testing.expectEqual(@as(usize, 1), peer.served);
}

test "the JSON media type is read through its parameter and its casing, and a repeated one is refused" {
    const io = testing.io;
    // Each answer carries the id of the call it answers, one per step and in
    // the order the client mints them. Reusing the first id across all three
    // would leave the second and third calls refused as `IdMismatch`, which is
    // a true statement about this script and says nothing about the media
    // type these heads are here for.
    var envelope: [3][256]u8 = undefined;
    const first = try answerWithId(&envelope[0], 1, task_result);
    const second = try answerWithId(&envelope[1], 2, task_result);
    const third = try answerWithId(&envelope[2], 3, task_result);
    var buffer: [3][512]u8 = undefined;
    // A parameter on the media type and a differently-cased one are the same
    // media type as RFC 9110 has it, and a client that compared the header
    // text would refuse a conforming peer over a charset.
    const answers = [_][]const u8{
        try std.fmt.bufPrint(
            &buffer[0],
            "HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: {d}\r\n\r\n{s}",
            .{ first.len, first },
        ),
        try std.fmt.bufPrint(
            &buffer[1],
            "HTTP/1.1 200 OK\r\nContent-Type: APPLICATION/JSON\r\ncontent-length: {d}\r\n\r\n{s}",
            .{ second.len, second },
        ),
        // A second `Content-Type` is two answers to one question. The head
        // parser keeps the first without saying so, and a client that
        // trusted the parsed one would be reading a field the peer did not
        // mean to send last.
        try std.fmt.bufPrint(
            &buffer[2],
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" ++
                "content-type: text/html\r\ncontent-length: {d}\r\n\r\n{s}",
            .{ third.len, third },
        ),
    };

    var peer: Peer = .{ .responses = &answers };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    var storage: CardStorage = .{};
    storage.init();
    var steps = [_]Step{
        .{ .expect = .task },
        .{ .expect = .task },
        .{ .expect = .{ .failure = error.UnsupportedMediaType } },
    };
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        // The endpoint is the peer's own, taken from the card it answers the
        // discovery with, port and all. A binding naming some other port
        // would not reach the peer at all: `std.http.Client` keys its pool by
        // authority, so a call to a port nothing is listening on opens a second
        // connection instead of taking the one already opened here, and the
        // peer is then waiting on a request that never comes. What this test
        // is about is the head the peer answers with, so the call has to be
        // answered by that head rather than by a refused connection.
        .binding = try peerBinding(&peer, &storage),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));
    try testing.expect(!peer.failed);
    for (&steps) |*step| try testing.expect(step.matched());
    // A parameter and a differently-cased media type are the same type, and a
    // second one is refused rather than resolved by order.
    try testing.expectEqualStrings("t-1", steps[0].idText());
    try testing.expectEqualStrings("t-1", steps[1].idText());
    try testing.expectEqual(Arrived.none, steps[2].arrived);
    try testing.expectEqual(@as(usize, 3), peer.served);
}

test "a chunked answer is read as one body, and two sends get two ids" {
    const io = testing.io;
    // Each answer carries the id of the call it answers. The second send mints
    // the second id, and an answer still naming the first one would be
    // `IdMismatch` rather than the second answer: the two ids are what this
    // test is about, so the script has to carry the same two.
    var envelope: [2][256]u8 = undefined;
    const first = try answerWithId(&envelope[0], 1, task_result);
    const second = try answerWithId(&envelope[1], 2, task_result);
    // The whole body arrives in two chunks, which is legal framing and not two
    // bodies. A client that read one `content-length` worth and stopped would
    // decode half an envelope and report a malformed answer, and a peer that
    // ended the chunked body at the first chunk would be sending the truncated
    // document instead: the second chunk is the rest of the envelope, and the
    // terminator only follows it.
    const half = first.len / 2;
    var chunked_buffer: [512]u8 = undefined;
    const chunked = try std.fmt.bufPrint(
        &chunked_buffer,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" ++
            "transfer-encoding: chunked\r\n\r\n" ++
            "{x}\r\n{s}\r\n{x}\r\n{s}\r\n0\r\n\r\n",
        .{ half, first[0..half], first.len - half, first[half..] },
    );

    var answered_buffer: [512]u8 = undefined;
    const answered = try jsonReply(&answered_buffer, "200 OK", second);
    var peer: Peer = .{ .responses = &.{ chunked, answered } };
    try peer.listen(io);
    defer peer.listener.deinit(io);

    var storage: CardStorage = .{};
    storage.init();
    var steps = [_]Step{
        .{ .expect = .task },
        .{ .expect = .task },
    };
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .binding = try peerBinding(&peer, &storage),
        .steps = &steps,
    };
    try connectPeer(io, &caller.http, peer.port());

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Peer.run, .{ &peer, io });
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));
    try testing.expect(!peer.failed);
    for (&steps) |*step| try testing.expect(step.matched());
    // The first answer arrived in two chunks and is still one typed body.
    try testing.expectEqualStrings("t-1", steps[0].idText());
    try testing.expectEqual(a2a.TaskState.completed, steps[0].state);

    // Each call gets its own id, in order, and the second is never the
    // first: an id reused across calls is an answer this client could have
    // matched to the wrong call.
    try testing.expect(std.mem.indexOf(u8, peer.body(0), "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, peer.body(1), "\"id\":2") != null);
    try testing.expect(std.mem.indexOf(u8, peer.body(1), "\"id\":1") == null);
    try testing.expectEqual(@as(usize, 2), peer.served);
}

test "the id space is monotonic and is never reused" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const binding = try Self.select(try storage.decode(cardWith(one_endpoint)));
    var wire_client: wire.Client = .{ .allocator = testing.allocator, .io = io };
    defer wire_client.deinit();
    var client = try Self.Client.init(io, &wire_client, binding);

    // Ids are handed out in order from one, and the space is never wrapped:
    // the last id that may be used is the largest `i64`, and the call after
    // it is refused rather than sending an id some earlier call already
    // used. A wrapped id would make a late answer look like the answer to a
    // request this client made long ago.
    try testing.expectEqual(@as(i64, 1), try client.takeId());
    try testing.expectEqual(@as(i64, 2), try client.takeId());
    try testing.expectEqual(@as(i64, 3), try client.takeId());

    client.next_id = std.math.maxInt(i64);
    try testing.expectEqual(std.math.maxInt(i64), try client.takeId());
    try testing.expectError(error.IdExhausted, client.takeId());
}

test "the well-known GET answers the encoded card" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();
    fixture.slice("GET /.well-known/agent-card.json HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n");

    var agent: Agent = .{};
    try testing.expect(try Self.serve(io, &fixture.http, card, "/agents/echo/a2a-v1?tenant=acme", .{
        .ctx = &agent,
        .call = Agent.handle,
    }, fixture.buffers(), &fixture.storage.arena));

    const frame = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 200), frame.code);
    try testing.expectEqualStrings("application/json", header(frame.head, "content-type").?);

    // The card that comes back is the one the server was given, so a client
    // that discovers it learns the endpoint this server answers on rather
    // than a default.
    const served = try a2a.decodeAgentCard(frame.body, &storage.arena, &storage.scratch);
    try testing.expectEqualStrings(card.name, served.name);
    try testing.expectEqual(@as(usize, 1), served.supported_interfaces.len);
    try testing.expectEqualStrings(
        card.supported_interfaces[0].url,
        served.supported_interfaces[0].url,
    );
    // And the discovery GET never reaches the handler.
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a SendMessage is answered with the handler's result and the id echoed, escapes and all" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    // The id carries an escaped quote, so the answer has to unescape it to
    // match the request and escape it again to write it back. An id that
    // came back with the escape processed, or one that came back escaped
    // twice, would be a different id from the one the caller sent and the
    // caller would never match its own answer.
    // The envelope is composed first and the head declares its own length,
    // because `content-length` is the length of the body and the body here is
    // the whole envelope rather than the `params` it carries. A head that
    // declared the `params` alone would hand this server a truncated body, and
    // a truncated envelope is a different document: this test would be about
    // a parse error instead of about an echoed id.
    var body_buffer: [4096]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"SendMessage\",\"params\":{s}}}",
        .{valid_params},
    );
    var buffer: [4096]u8 = undefined;
    fixture.slice(try std.fmt.bufPrint(
        &buffer,
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ));

    var agent: Agent = .{};
    try testing.expect(try Self.serve(io, &fixture.http, card, "/agents/echo/a2a-v1?tenant=acme", .{
        .ctx = &agent,
        .call = Agent.handle,
    }, fixture.buffers(), &fixture.storage.arena));

    const frame = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 200), frame.code);
    try testing.expect(std.mem.indexOf(u8, frame.body, "\"id\":\"a\\\"b\"") != null);

    // The frame is a JSON-RPC response to that id whose result is the typed
    // payload the handler returned.
    const message = jsonrpc.decode(frame.body, &fixture.envelope_scratch) catch
        return error.TestUnexpectedResult;
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    try testing.expectEqualStrings("a\"b", message.id.?.string);
    try testing.expectEqual(@as(?jsonrpc.Error, null), message.rpc_error);

    const payload = a2a.decodeSendMessageResponse(
        // The frame above is this test's own handler's answer, encoded and
        // written by `serve`, so it carries the `result` the test is reading.
        // zwanzig-disable-next-line: optional-unwrap
        message.result.?,
        &fixture.storage.arena,
        &fixture.payload_scratch,
    ) catch return error.TestUnexpectedResult;
    switch (payload) {
        .message => |value| {
            try testing.expectEqualStrings("agent-1", value.message_id);
            try testing.expectEqualStrings("ping", value.parts[0].content.text);
        },
        .task => return error.TestUnexpectedResult,
    }

    // The handler really was reached, and the typed text crossed the socket
    // and came back inside the answer.
    try testing.expectEqual(@as(usize, 1), agent.calls);
    try testing.expectEqualStrings("ping", agent.seen[0..agent.seen_len]);
}

test "an unknown method and an invalid params body are refused with their own codes" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    const target = "/agents/echo/a2a-v1?tenant=acme";
    const head = "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
        "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: ";
    // Three requests on one connection. `message/send` is the `0.3` alias of
    // `SendMessage` and it is refused as an unknown method: this runtime
    // serves `1.0` only, and honouring the alias would claim to accept a
    // `0.3` body it never looked at.
    const bodies = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"NoSuchMethod\",\"params\":" ++ valid_params ++ "}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"message/send\",\"params\":" ++ valid_params ++ "}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"SendMessage\",\"params\":" ++
            "{\"message\":{\"messageId\":\"\",\"role\":\"nope\"}}}",
    };
    var joined: [8192]u8 = undefined;
    var total: usize = 0;
    for (bodies) |body| {
        total += (try std.fmt.bufPrint(joined[total..], "{s}{d}\r\n\r\n{s}", .{
            head,
            body.len,
            body,
        })).len;
    }
    fixture.slice(joined[0..total]);

    var agent: Agent = .{};
    const handler: Self.Handler = .{ .ctx = &agent, .call = Agent.handle };
    for ([_]usize{ 0, 1, 2 }) |_| {
        try testing.expect(try Self.serve(
            io,
            &fixture.http,
            card,
            target,
            handler,
            fixture.buffers(),
            &fixture.storage.arena,
        ));
    }

    const expected = [_]i32{
        @backingInt(jsonrpc.StandardError.method_not_found),
        @backingInt(jsonrpc.StandardError.method_not_found),
        @backingInt(jsonrpc.StandardError.invalid_params),
    };
    var rest = fixture.answered();
    var scratch: [1024]u8 = undefined;
    for (expected, 0..) |code, index| {
        const frame = nextFrame(rest) orelse return error.TestUnexpectedResult;
        rest = frame.rest;
        const decoded = jsonrpc.decode(frame.body, &scratch) catch return error.TestUnexpectedResult;
        try testing.expectEqual(jsonrpc.Kind.response, decoded.kind);
        try testing.expectEqual(code, decoded.rpc_error.?.code);
        try testing.expectEqual(@as(?[]const u8, null), decoded.result);
        // Each refusal is answered to the id that asked, so a client can
        // tell which of several calls on one connection was refused.
        try testing.expectEqual(@as(i64, @intCast(index + 1)), decoded.id.?.integer);
    }
    // The handler never saw a request it could not answer.
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a version this server does not serve is refused, and so is an absent, empty or patched one" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    const envelope = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":" ++
        valid_params ++ "}";
    // Four requests on one connection: an empty value, which the
    // specification reads as `0.3`; a version this runtime does not
    // implement; a patched value, which is not a `Major.Minor` at all; and
    // the header missing altogether.
    const heads = [_][]const u8{
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: \r\n",
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 0.3\r\n",
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0.0\r\n",
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\n",
    };
    var joined: [8192]u8 = undefined;
    var total: usize = 0;
    for (heads) |head| {
        total += (try std.fmt.bufPrint(joined[total..], "{s}content-length: {d}\r\n\r\n{s}", .{
            head,
            envelope.len,
            envelope,
        })).len;
    }
    fixture.slice(joined[0..total]);

    var agent: Agent = .{};
    const handler: Self.Handler = .{ .ctx = &agent, .call = Agent.handle };
    for ([_]usize{ 0, 1, 2, 3 }) |_| {
        try testing.expect(try Self.serve(
            io,
            &fixture.http,
            card,
            "/agents/echo/a2a-v1?tenant=acme",
            handler,
            fixture.buffers(),
            &fixture.storage.arena,
        ));
    }

    // Every one of them is `-32009` with the id echoed, over the HTTP status
    // PROTOCOLS.md 5.6 gives that error. A server that ignored the header
    // would answer `1.0` semantics to a `0.3` client, which is the
    // compatibility break the version parameter exists to prevent.
    var rest = fixture.answered();
    var scratch: [1024]u8 = undefined;
    for ([_]usize{ 0, 1, 2, 3 }) |_| {
        const frame = nextFrame(rest) orelse return error.TestUnexpectedResult;
        rest = frame.rest;
        try testing.expectEqual(@as(u16, 400), frame.code);
        const decoded = jsonrpc.decode(frame.body, &scratch) catch return error.TestUnexpectedResult;
        try testing.expectEqual(
            @backingInt(a2a.A2aError.version_not_supported),
            decoded.rpc_error.?.code,
        );
        try testing.expectEqual(@as(?[]const u8, null), decoded.result);
        try testing.expectEqual(@as(i64, 1), decoded.id.?.integer);
    }
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a repeated version header is refused rather than resolved, and so is a repeated content type" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    const envelope = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":" ++
        valid_params ++ "}";
    // Two `A2A-Version` fields name two versions. RFC 9110 lets a peer send
    // them and this protocol does not say which one a reader may take, so
    // the request is refused rather than resolved by order: the version
    // decides which semantics apply, and taking the first would answer a
    // request under a version its own second field contradicts.
    var first_buffer: [1024]u8 = undefined;
    const repeated = try std.fmt.bufPrint(
        &first_buffer,
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\na2a-version: 0.3\r\n" ++
            "content-length: {d}\r\n\r\n{s}",
        .{ envelope.len, envelope },
    );
    // Two `Content-Type` fields are the same problem one layer down, and
    // they are refused at the HTTP level because the body has not been
    // decoded and so carries no id to answer with.
    var second_buffer: [1024]u8 = undefined;
    const typed = try std.fmt.bufPrint(
        &second_buffer,
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\ncontent-type: text/plain\r\n" ++
            "a2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ envelope.len, envelope },
    );
    var joined: [2048]u8 = undefined;
    @memcpy(joined[0..repeated.len], repeated);
    @memcpy(joined[repeated.len..][0..typed.len], typed);
    fixture.slice(joined[0 .. repeated.len + typed.len]);

    var agent: Agent = .{};
    const handler: Self.Handler = .{ .ctx = &agent, .call = Agent.handle };
    const target = "/agents/echo/a2a-v1?tenant=acme";
    try testing.expect(try Self.serve(
        io,
        &fixture.http,
        card,
        target,
        handler,
        fixture.buffers(),
        &fixture.storage.arena,
    ));
    try testing.expect(try Self.serve(
        io,
        &fixture.http,
        card,
        target,
        handler,
        fixture.buffers(),
        &fixture.storage.arena,
    ));

    const first = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    const first_body = jsonrpc.decode(first.body, &fixture.envelope_scratch) catch
        return error.TestUnexpectedResult;
    try testing.expectEqual(
        @backingInt(a2a.A2aError.version_not_supported),
        first_body.rpc_error.?.code,
    );
    // The id was identifiable, so it is echoed: a null id here would tell
    // the peer this server had lost the request it was holding.
    try testing.expectEqual(@as(i64, 1), first_body.id.?.integer);

    const second = nextFrame(first.rest) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 415), second.code);
    try testing.expectEqual(@as(usize, 0), second.body.len);
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a notification is answered 202 with no JSON-RPC message" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    // A notification is a method with no id, and it has no answer to send.
    // Answering one with a JSON-RPC message would put a response on the
    // wire that matches nothing, while the peer that sent it is waiting for
    // nothing at all.
    const envelope = "{\"jsonrpc\":\"2.0\",\"method\":\"SendMessage\",\"params\":" ++
        valid_params ++ "}";
    var buffer: [4096]u8 = undefined;
    fixture.slice(try std.fmt.bufPrint(
        &buffer,
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ envelope.len, envelope },
    ));

    var agent: Agent = .{};
    try testing.expect(try Self.serve(io, &fixture.http, card, "/agents/echo/a2a-v1?tenant=acme", .{
        .ctx = &agent,
        .call = Agent.handle,
    }, fixture.buffers(), &fixture.storage.arena));

    const frame = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 202), frame.code);
    try testing.expectEqual(@as(usize, 0), frame.body.len);
    // The method was the one this server implements, so it was dispatched;
    // what a notification has no answer for is the notification itself.
    try testing.expectEqual(@as(usize, 1), agent.calls);
}

test "malformed JSON is a parse error with a null id, and an invalid request with an id echoes it" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    // Two requests on one connection. The first is not JSON at all, so
    // there is nothing to identify and JSON-RPC 2.0 answers a parse error
    // with `id: null`. The second is JSON and carries an id, but it is a
    // response rather than a request, so the id is determinable and must be
    // echoed: `null` there would tell the peer its own id had been lost.
    const bodies = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,",
        "{\"jsonrpc\":\"2.0\",\"id\":\"x-1\",\"result\":{}}",
    };
    var joined: [4096]u8 = undefined;
    var total: usize = 0;
    for (bodies) |body| {
        total += (try std.fmt.bufPrint(
            joined[total..],
            "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
                "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
            .{ body.len, body },
        )).len;
    }
    fixture.slice(joined[0..total]);

    var agent: Agent = .{};
    const handler: Self.Handler = .{ .ctx = &agent, .call = Agent.handle };
    for ([_]usize{ 0, 1 }) |_| {
        try testing.expect(try Self.serve(
            io,
            &fixture.http,
            card,
            "/agents/echo/a2a-v1?tenant=acme",
            handler,
            fixture.buffers(),
            &fixture.storage.arena,
        ));
    }

    var scratch: [1024]u8 = undefined;
    const first = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    const parse_failure = jsonrpc.decode(first.body, &scratch) catch return error.TestUnexpectedResult;
    try testing.expectEqual(
        @backingInt(jsonrpc.StandardError.parse_error),
        parse_failure.rpc_error.?.code,
    );
    try testing.expect(parse_failure.id_null);
    try testing.expectEqual(@as(?jsonrpc.Id, null), parse_failure.id);

    const second = nextFrame(first.rest) orelse return error.TestUnexpectedResult;
    const invalid = jsonrpc.decode(second.body, &scratch) catch return error.TestUnexpectedResult;
    try testing.expectEqual(
        @backingInt(jsonrpc.StandardError.invalid_request),
        invalid.rpc_error.?.code,
    );
    try testing.expectEqualStrings("x-1", invalid.id.?.string);
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a document that parses but is not a request is an invalid request, not a parse error" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    // Six requests on one connection, every one of them JSON. A decoder that
    // cannot model a member reports one error for "these bytes are not JSON"
    // and for "this value is not of the type I read", and only the document
    // itself says which of the two it is: JSON-RPC 2.0 answers the first with
    // `-32700` and the second with `-32600`, so a peer whose JSON was read as
    // not JSON has been told something false about a document it wrote
    // correctly.
    const bodies = [_][]const u8{
        // A well-formed array. A JSON-RPC message is an object, so this is a
        // request object that is not there, and it carries no id.
        "[]",
        // A legal `id` shape carrying a value no id can be. An id this server
        // cannot recover is reported as no id rather than echoed as `true`.
        "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"SendMessage\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":false,\"method\":\"SendMessage\"}",
        // A legal integer id beside a `method` that is not a string. The id is
        // determinable and must be echoed: a `null` there would tell the peer
        // its own id had been lost.
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":false}",
        // An escaped legal id beside the same fault, so the id survives the
        // unescaping and the re-escaping rather than arriving mangled.
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":false}",
        // A repeated `id` is one name the grammar permits, and the first
        // occurrence is the one every decoder in this repository takes. A
        // second legal id must not replace the one the peer led with.
        "{\"jsonrpc\":\"2.0\",\"id\":\"first\",\"id\":9,\"method\":false}",
    };
    var joined: [8192]u8 = undefined;
    var total: usize = 0;
    for (bodies) |body| {
        total += (try std.fmt.bufPrint(
            joined[total..],
            "POST {s} HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
                "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
            .{ test_rpc_target, body.len, body },
        )).len;
    }

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();
    fixture.slice(joined[0..total]);

    var agent: Agent = .{};
    const handler: Self.Handler = .{ .ctx = &agent, .call = Agent.handle };
    for (bodies) |_| {
        try testing.expect(try Self.serve(
            io,
            &fixture.http,
            card,
            test_rpc_target,
            handler,
            fixture.buffers(),
            &fixture.storage.arena,
        ));
    }

    // Every one of the six is `-32600`: each of them is JSON, and a JSON-RPC
    // document that is not a request is what `-32600` names. The three whose
    // id cannot be read are answered with a `null` id, and the three whose id
    // can be are answered to that id in the arm it arrived in.
    const recovered = [_]?jsonrpc.Id{
        null,
        null,
        null,
        .{ .integer = 1 },
        .{ .string = "a\"b" },
        .{ .string = "first" },
    };
    var rest = fixture.answered();
    var scratch: [1024]u8 = undefined;
    for (recovered) |id| {
        const frame = nextFrame(rest) orelse return error.TestUnexpectedResult;
        rest = frame.rest;
        const decoded = jsonrpc.decode(frame.body, &scratch) catch
            return error.TestUnexpectedResult;
        try testing.expectEqual(
            @backingInt(jsonrpc.StandardError.invalid_request),
            decoded.rpc_error.?.code,
        );
        try testing.expectEqual(@as(?[]const u8, null), decoded.result);
        if (id) |want| {
            // The recovered id is the peer's own, in the arm it arrived in: an
            // integer is not answered as a string, an escaped one is unescaped
            // and re-escaped rather than arriving mangled, and a repeated name
            // is answered to the occurrence the peer led with rather than to a
            // later one.
            try testing.expect(!decoded.id_null);
            const got = decoded.id orelse return error.TestUnexpectedResult;
            switch (want) {
                .integer => |value| switch (got) {
                    .integer => |answered| try testing.expectEqual(value, answered),
                    .string => return error.TestUnexpectedResult,
                },
                .string => |value| switch (got) {
                    .string => |answered| try testing.expectEqualStrings(value, answered),
                    .integer => return error.TestUnexpectedResult,
                },
            }
        } else {
            try testing.expect(decoded.id_null);
            try testing.expectEqual(@as(?jsonrpc.Id, null), decoded.id);
        }
    }
    // None of the six was dispatched: a document this server refused to read
    // is not a request it can answer.
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a shortage while recovering an id is the caller's, not a refused call" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();
    // The envelope decode has a scratch of its own and is given one, so this
    // document gets as far as the refusal path. Recovering its escaped id does
    // not: that id has to be unescaped into the caller's own buffer, and a
    // buffer that cannot hold it is the caller's shortage rather than a fact
    // about the peer's document.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":false}";
    var buffer: [4096]u8 = undefined;
    fixture.slice(try std.fmt.bufPrint(
        &buffer,
        "POST {s} HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ test_rpc_target, body.len, body },
    ));

    var agent: Agent = .{};
    try testing.expectError(error.BufferTooSmall, Self.serve(io, &fixture.http, card, test_rpc_target, .{
        .ctx = &agent,
        .call = Agent.handle,
    }, .{
        .transfer = &fixture.transfer,
        .body = &fixture.body,
        .envelope_scratch = &fixture.envelope_scratch,
        .payload_scratch = fixture.payload_scratch[0..0],
        .payload_out = &fixture.payload_out,
        .envelope_out = &fixture.envelope_out,
        .base64 = &fixture.base64,
    }, &fixture.storage.arena));

    // Nothing was written: a shortage on this side of the wire has no answer
    // that would be true of it, and a refusal here would report a fact about
    // the peer's document that is a fact about the caller's buffer.
    try testing.expectEqual(@as(usize, 0), fixture.answered().len);
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a shortage while recovering an id under an escaped key is the caller's too" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();
    // The same shortage as the test above, one step earlier in the walk: this
    // document spells the member's own name with an escape, and a name has to
    // be unescaped before it can be compared with `id`. The bytes the escape
    // costs are this server's storage, so a buffer that cannot hold them is the
    // caller's shortage and not a document that carries no id at all. Read as
    // an absent member, the answer would be a `null` id, which tells a peer
    // whose id was spelled this way that its own identifier was lost.
    const body = "{\"jsonrpc\":\"2.0\",\"\\u0069d\":\"a\",\"method\":false}";
    var buffer: [4096]u8 = undefined;
    fixture.slice(try std.fmt.bufPrint(
        &buffer,
        "POST {s} HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ test_rpc_target, body.len, body },
    ));

    var agent: Agent = .{};
    try testing.expectError(error.BufferTooSmall, Self.serve(io, &fixture.http, card, test_rpc_target, .{
        .ctx = &agent,
        .call = Agent.handle,
    }, .{
        .transfer = &fixture.transfer,
        .body = &fixture.body,
        .envelope_scratch = &fixture.envelope_scratch,
        .payload_scratch = fixture.payload_scratch[0..0],
        .payload_out = &fixture.payload_out,
        .envelope_out = &fixture.envelope_out,
        .base64 = &fixture.base64,
    }, &fixture.storage.arena));

    // Nothing was written, for the reason the test above gives: a `null` id on
    // the wire would have been the one answer about this document that is not
    // true of it.
    try testing.expectEqual(@as(usize, 0), fixture.answered().len);
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a chunked request body is read as one bounded body" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    // A body in two chunks is one body. Refusing chunked framing would
    // refuse a legal `SendMessage`, and the read has to end at the end of
    // the body rather than at a chunk boundary.
    const envelope = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":" ++
        valid_params ++ "}";
    const half = envelope.len / 2;
    var buffer: [4096]u8 = undefined;
    fixture.slice(try std.fmt.bufPrint(
        &buffer,
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\n" ++
            "transfer-encoding: chunked\r\n\r\n" ++
            "{x}\r\n{s}\r\n{x}\r\n{s}\r\n0\r\n\r\n",
        .{
            @as(usize, half),
            envelope[0..half],
            @as(usize, envelope.len - half),
            envelope[half..],
        },
    ));

    var agent: Agent = .{};
    try testing.expect(try Self.serve(io, &fixture.http, card, "/agents/echo/a2a-v1?tenant=acme", .{
        .ctx = &agent,
        .call = Agent.handle,
    }, fixture.buffers(), &fixture.storage.arena));

    try testing.expectEqual(@as(usize, 1), agent.calls);
    try testing.expectEqualStrings("ping", agent.seen[0..agent.seen_len]);
    const frame = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 200), frame.code);
    try testing.expect(std.mem.indexOf(u8, frame.body, "\"result\":{\"message\"") != null);
}

test "a body over the server's buffer is refused and the connection still answers" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    const envelope = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":" ++
        valid_params ++ "}";
    // `metadata` is a borrowed ProtoJSON `Struct`, so the padding is an
    // object member: a request this server refuses for its size has to be a
    // request whose only fault is its size.
    var padding: [2048]u8 = @splat('x');
    const oversized = envelope[0 .. envelope.len - 1] ++
        ",\"metadata\":{\"pad\":\"" ++ padding[0..] ++ "\"}}";
    var joined: [8192]u8 = undefined;
    const first_len = (try std.fmt.bufPrint(
        &joined,
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ oversized.len, oversized },
    )).len;
    const second_len = (try std.fmt.bufPrint(
        joined[first_len..],
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ envelope.len, envelope },
    )).len;
    fixture.slice(joined[0 .. first_len + second_len]);

    var agent: Agent = .{};
    const handler: Self.Handler = .{ .ctx = &agent, .call = Agent.handle };
    const target = "/agents/echo/a2a-v1?tenant=acme";
    // A body buffer a fraction of what the first request needs.
    const buffers: Self.ServerBuffers = .{
        .transfer = &fixture.transfer,
        .body = fixture.body[0..512],
        .envelope_scratch = &fixture.envelope_scratch,
        .payload_scratch = &fixture.payload_scratch,
        .payload_out = &fixture.payload_out,
        .envelope_out = &fixture.envelope_out,
        .base64 = &fixture.base64,
    };

    // Both requests are answered before either frame is read, and each frame
    // is taken from `fixture.answered()` again. That buffer is the writer's
    // own, and the second answer was appended into it: a `Frame` split out
    // before it was describes a region the writer has since grown or replaced,
    // and its `rest` would end before the second answer rather than after it.
    try testing.expect(try Self.serve(io, &fixture.http, card, target, handler, buffers, &fixture.storage.arena));
    try testing.expect(try Self.serve(io, &fixture.http, card, target, handler, buffers, &fixture.storage.arena));

    // The oversized request is answered as an HTTP refusal, and the connection
    // answers the next one: a peer that sent a large body does not have to
    // open a second connection to be answered at all.
    const refused = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 413), refused.code);
    const answered = nextFrame(refused.rest) orelse return error.TestUnexpectedResult;
    const decoded = jsonrpc.decode(answered.body, &fixture.envelope_scratch) catch
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 1), decoded.id.?.integer);
    try testing.expectEqual(@as(?jsonrpc.Error, null), decoded.rpc_error);
    try testing.expectEqual(@as(usize, 1), agent.calls);
}

test "an oversized chunked body is refused and the connection is closed, because the rest of it is still on the wire" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));
    const target = "/agents/echo/a2a-v1?tenant=acme";
    const chunked_head = "POST " ++ target ++ " HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
        "content-type: application/json\r\na2a-version: 1.0\r\ntransfer-encoding: chunked\r\n\r\n";
    // A chunk that announces four times what the server's body buffer holds.
    // The padding is the body itself rather than a member of it, so the only
    // fault this request has is its size.
    var padding: [2048]u8 = @splat('x');

    // The first half of the difference. A `content-length` body of the same
    // size is refused before the reader is taken, so the connection can put
    // the body back and answer what follows it.
    var sized: [4096]u8 = undefined;
    var sized_writer = Io.Writer.fixed(&sized);
    try sized_writer.print(
        "POST {s} HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\n" ++
            "a2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n",
        .{ target, padding.len },
    );
    try sized_writer.writeAll(&padding);
    try sized_writer.writeAll(
        "POST " ++ target ++ " HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: 2\r\n\r\n{}",
    );

    var sized_fixture: ServerFixture = .{};
    defer sized_fixture.deinit();
    sized_fixture.init();
    sized_fixture.slice(sized_writer.buffered());
    const sized_buffers = narrowBuffers(&sized_fixture);

    var sized_agent: Agent = .{};
    try testing.expect(try Self.serve(io, &sized_fixture.http, card, target, .{
        .ctx = &sized_agent,
        .call = Agent.handle,
    }, sized_buffers, &sized_fixture.storage.arena));
    // The whole of that body went back down the reader, so the connection
    // carries the request that follows it and answers that one too.
    try testing.expect(try Self.serve(io, &sized_fixture.http, card, target, .{
        .ctx = &sized_agent,
        .call = Agent.handle,
    }, sized_buffers, &sized_fixture.storage.arena));
    // Both answers are on the wire before either frame is split out, for the
    // reason the other test gives: the split borrows the writer's own buffer,
    // which the second answer was appended into.
    const sized_refusal = nextFrame(sized_fixture.answered()) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 413), sized_refusal.code);
    try testing.expectEqual(@as(?[]const u8, null), header(sized_refusal.head, "connection"));
    const after_refusal = nextFrame(sized_refusal.rest) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 400), after_refusal.code);

    // The second half. A chunked body that does not fit is read part way in
    // before the writer fills, so the rest of it is still on the socket: the
    // refusal says the connection is closed rather than promising a head this
    // server would parse out of the middle of a body.
    //
    // The chunk announces 2048 bytes and the peer sends half of them and stops
    // there, which is what makes the rest of the body unreachable rather than
    // merely unread. That is the case the rule is about: a body this server
    // can still drain to its own end is a body it has put back where a head
    // may follow, and that connection stays usable, so a peer that sent all
    // 2048 would be answered on the same connection and this refusal would
    // have nothing to close. Here the drain cannot finish, so it closes.
    var chunked: [4096]u8 = undefined;
    var chunked_writer = Io.Writer.fixed(&chunked);
    try chunked_writer.writeAll(chunked_head);
    try chunked_writer.writeAll("800\r\n");
    try chunked_writer.writeAll(padding[0 .. padding.len / 2]);

    var chunked_fixture: ServerFixture = .{};
    defer chunked_fixture.deinit();
    chunked_fixture.init();
    chunked_fixture.slice(chunked_writer.buffered());
    const chunked_buffers = narrowBuffers(&chunked_fixture);

    var chunked_agent: Agent = .{};
    try testing.expect(try Self.serve(io, &chunked_fixture.http, card, target, .{
        .ctx = &chunked_agent,
        .call = Agent.handle,
    }, chunked_buffers, &chunked_fixture.storage.arena));
    const refusal = nextFrame(chunked_fixture.answered()) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 413), refusal.code);
    try testing.expectEqualStrings("close", header(refusal.head, "connection").?);
    // A body this server refused part way through is never handed to the
    // handler: what it dispatched would be a prefix of a request.
    try testing.expectEqual(@as(usize, 0), chunked_agent.calls);
    try testing.expectEqual(@as(usize, 0), sized_agent.calls);
}

/// Every buffer of `fixture` except the body, which is narrowed to the
/// quarter of a chunk a test wants refused.
fn narrowBuffers(fixture: *ServerFixture) Self.ServerBuffers {
    return .{
        .transfer = &fixture.transfer,
        .body = fixture.body[0..512],
        .envelope_scratch = &fixture.envelope_scratch,
        .payload_scratch = &fixture.payload_scratch,
        .payload_out = &fixture.payload_out,
        .envelope_out = &fixture.envelope_out,
        .base64 = &fixture.base64,
    };
}

test "another path is 404 and another method on a known path is 405" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();
    fixture.slice(
        "GET /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n" ++
            "POST /somewhere/else HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n" ++
            "POST /.well-known/agent-card.json HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n",
    );

    var agent: Agent = .{};
    const handler: Self.Handler = .{ .ctx = &agent, .call = Agent.handle };
    for ([_]usize{ 0, 1, 2 }) |_| {
        try testing.expect(try Self.serve(
            io,
            &fixture.http,
            card,
            "/agents/echo/a2a-v1?tenant=acme",
            handler,
            fixture.buffers(),
            &fixture.storage.arena,
        ));
    }

    // A path this server does not serve is 404, and a known path with the
    // wrong method is 405 with the methods it does serve there. No normative
    // path is invented: the only two are the well-known one and the one the
    // caller configured.
    const first = nextFrame(fixture.answered()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 405), first.code);
    try testing.expectEqualStrings("POST", header(first.head, "allow").?);
    const second = nextFrame(first.rest) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 404), second.code);
    const third = nextFrame(second.rest) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 405), third.code);
    try testing.expectEqualStrings("GET", header(third.head, "allow").?);
    try testing.expectEqual(@as(usize, 0), agent.calls);
}

test "a handler that fails is reported to the caller and never answered as a success" {
    const io = testing.io;
    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(cardWith(one_endpoint));

    var fixture: ServerFixture = .{};
    defer fixture.deinit();
    fixture.init();

    const envelope = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"SendMessage\",\"params\":" ++
        valid_params ++ "}";
    var buffer: [4096]u8 = undefined;
    fixture.slice(try std.fmt.bufPrint(
        &buffer,
        "POST /agents/echo/a2a-v1?tenant=acme HTTP/1.1\r\nhost: 127.0.0.1\r\n" ++
            "content-type: application/json\r\na2a-version: 1.0\r\ncontent-length: {d}\r\n\r\n{s}",
        .{ envelope.len, envelope },
    ));

    var agent: Agent = .{ .fail = true };
    try testing.expectError(error.AgentUnavailable, Self.serve(
        io,
        &fixture.http,
        card,
        "/agents/echo/a2a-v1?tenant=acme",
        .{
            .ctx = &agent,
            .call = Agent.handle,
        },
        fixture.buffers(),
        &fixture.storage.arena,
    ));

    // The failure is the caller's to see. It is not turned into a result and
    // nothing is written at all, because this transport cannot name a cause
    // only the handler knows.
    try testing.expectEqual(@as(usize, 0), fixture.answered().len);
    try testing.expectEqual(@as(usize, 1), agent.calls);
}

test "a client and a server over one real socket complete the exchange" {
    const io = testing.io;
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    // The card this server serves advertises the endpoint the kernel chose,
    // so the client that discovers it has to read the card to find where to
    // POST: a hard-coded path would pass on a port nothing published.
    // The card is written through a writer rather than through a format
    // string: the document is full of braces a format string would want as
    // escapes, and one wrong escape is a card that decodes into something
    // else.
    var document: [4096]u8 = undefined;
    var card_writer = Io.Writer.fixed(&document);
    try card_writer.writeAll(
        "{\"name\":\"echo\",\"description\":\"An agent that echoes.\",\"supportedInterfaces\":" ++
            "[{\"url\":\"http://127.0.0.1:",
    );
    try card_writer.print("{d}", .{port});
    try card_writer.writeAll(
        "/agents/echo/a2a-v1?tenant=acme\",\"protocolBinding\":\"JSONRPC\"," ++
            "\"protocolVersion\":\"1.0\"}],\"version\":\"1.0\",\"capabilities\":{}," ++
            "\"defaultInputModes\":[],\"defaultOutputModes\":[],\"skills\":[]}",
    );
    const card_text = card_writer.buffered();

    var storage: CardStorage = .{};
    storage.init();
    const card = try storage.decode(card_text);
    const target = "/agents/echo/a2a-v1?tenant=acme";

    var server: ServerFixture = .{};
    defer server.deinit();
    server.init();

    const Endpoint = struct {
        io: Io,
        listener: *Io.net.Server,
        fixture: *ServerFixture,
        card: a2a.AgentCard,
        target: []const u8,
        agent: *Agent,
        failed: bool = false,

        // Zig resolves `Self` through the container root, and this file's root
        // already names itself `Self`, so a nested struct that redeclares the
        // name is ambiguous rather than shadowed: `const Self = @This()` here
        // fails to compile with the shadowing error (143). The receivers below
        // therefore name `EndpointState`, while `Self.serve` stays a file-root
        // dispatch so the fixture drives the same `pub fn serve` entry point
        // that production callers use.
        // ziglint-ignore: Z022
        const EndpointState = @This();

        fn run(self: *EndpointState) void {
            const stream = self.listener.accept(self.io) catch {
                self.failed = true;
                return;
            };
            defer {
                // `shutdown` before `close`: a close on a socket whose peer
                // still holds unread bytes answers with a reset, and the
                // reset discards them.
                stream.shutdown(self.io, .both) catch {};
                stream.close(self.io);
            }
            self.fixture.socket(self.io, stream);
            while (true) {
                const answered = Self.serve(self.io, &self.fixture.http, self.card, self.target, .{
                    .ctx = self.agent,
                    .call = Agent.handle,
                }, self.fixture.buffers(), &self.fixture.storage.arena) catch {
                    self.failed = true;
                    return;
                };
                if (!answered) return;
            }
        }
    };

    var agent: Agent = .{ .arm = .task };
    var endpoint: Endpoint = .{
        .io = io,
        .listener = &listener,
        .fixture = &server,
        .card = card,
        .target = target,
        .agent = &agent,
    };

    // The server serves until the connection ends, so the client has to be
    // the one that ends it: both ends are tasks on one caller-owned group, the
    // client releases its connection as its own task returns, and the body
    // only joins the group under a deadline.
    var origin_text: [64]u8 = undefined;
    var steps = [_]Step{.{ .expect = .task }};
    var caller: Caller = .{
        .io = io,
        .http = .{ .allocator = testing.allocator, .io = io },
        .origin = try std.fmt.bufPrint(&origin_text, "http://127.0.0.1:{d}", .{port}),
        .steps = &steps,
    };
    // The connection is opened before the group starts, so the server's
    // `accept` is a call that returns rather than one that waits.
    try connectPeer(io, &caller.http, port);

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Endpoint.run, .{&endpoint});
    try group.concurrent(io, Caller.run, .{&caller});
    try testing.expect(!(try joinBounded(io, &group)));

    // The discovery GET reached this server and was answered with the card,
    // and the endpoint the client picked is the one the card advertised.
    try testing.expect(!endpoint.failed);
    try testing.expect(!caller.failed);
    try testing.expect(steps[0].matched());
    try testing.expectEqualStrings("echo", caller.name());
    var buffer: [128]u8 = undefined;
    const found = caller.found orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/agents/echo/a2a-v1", try found.uri.path.toRaw(&buffer));
    try testing.expectEqualStrings("tenant=acme", try found.uri.query.?.toRaw(&buffer));

    // The typed answer really crossed the socket, and the handler really saw
    // the request that asked for it: the agent's own counter is the server's
    // report, not the client's.
    try testing.expectEqual(@as(u16, 200), steps[0].status);
    try testing.expectEqualStrings("t-1", steps[0].idText());
    try testing.expectEqual(a2a.TaskState.working, steps[0].state);
    try testing.expect(!endpoint.failed);
    try testing.expectEqual(@as(usize, 1), agent.calls);
}
