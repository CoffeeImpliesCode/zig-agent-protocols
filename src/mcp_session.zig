//! The MCP session: a client and a server on top of [`conn.Conn`].
//!
//! The connection knows JSON-RPC. This knows MCP, and the difference is almost
//! entirely about revision. PROTOCOLS.md 4.8 states that at `2026-07-28` there
//! is no handshake and capabilities ride per request in `_meta`, while at
//! `2025-11-25` they travel in `initialize`. Those two shapes are not
//! symmetric, which is why a session is pinned to one revision rather than
//! carrying a flag and branching at every call.
//!
//! ## What the client adds over the connection
//!
//! - A method is checked against the pinned revision *before* it goes on the
//!   wire, so a caller that asks for a method removed at `2026-07-28` learns so
//!   immediately instead of after a round trip to a peer that may or may not
//!   have removed it.
//! - A method is checked for arity and direction as well: a notification is
//!   never sent as a request, and a method the other side sends is never sent
//!   from here. A notification sent as a request leaves the caller waiting for
//!   an answer no conforming peer will send, and `mcp.lookupMethod` resolves
//!   one as readily as a request, so the pin alone does not refuse it.
//! - A notification goes out through [`Client.notify`], the same check read
//!   the other way round. PROTOCOLS.md 4.4 lists eight notifications and
//!   marks seven of them server-to-client, so a client may send one of them
//!   at `2026-07-28` and two at `2025-11-25`, the revision whose
//!   `notifications/initialized` is a method. The gate names the two
//!   directions a client may send rather than the one it may not: the
//!   complement of a pair is a pair, and taking it from the wrong end admits
//!   `notifications/progress` and the six notifications beside it.
//! - At the current revision every request carries the client capabilities in
//!   `_meta`, because there is no `initialize` to carry them in. A `params`
//!   that carries `_meta` of its own is merged with it rather than written
//!   beside it, because PROTOCOLS.md 4.7 puts `_meta` on a multi-round-trip
//!   retry as well as on the call that opens it.
//! - A result is classified as complete or `input_required` before the caller
//!   sees it, so an interim result is never mistaken for a final one.
//! - A peer that answered with an error comes back as a [`conn.Response`] whose
//!   `error_code` is set and whose `body` is the error object it sent. Reading
//!   `body` alone would report a failed call as a result.
//!
//! ## What the server adds
//!
//! [`Server`] is the other half, and it is the same pin read the other way
//! round. A handler asks [`Server.gate`] before it touches `params`, so a name
//! this revision removed never reaches one and the peer gets the `-32601` of
//! [`Server.methodNotFound`] instead of a guess. What the client sends, the
//! server reads, so [`Server.observe`] returns the method and the capabilities
//! one request carried from a single decode. What the server sends, the
//! server checks — but the checks are not here, because a result is a
//! document and what may be sent in one is not a fact about a connection:
//! `mcp.checkResult` refuses a result that leaves out a member PROTOCOLS.md
//! 4.6 requires, and `mcp.inputRequired` refuses an interim result on a
//! method 4.7 does not let answer with one. [`Server.gate`] refuses the
//! arities the client half does, so a handler is not entered for a message
//! that expects no answer or for one travelling the other way.
//!
//! The server half sends nothing at the top level, and there is no
//! `Server.notify` for it to send it with. PROTOCOLS.md 4.4 puts
//! `notifications/progress` and `notifications/message` on the originating
//! request's response stream, scopes the server's `notifications/cancelled` to
//! a `subscriptions/listen` teardown, and hands
//! `notifications/subscriptions/acknowledged` that stream's filter.
//! [`mcp.Direction`] carries none of that: it says who may send a name, not
//! where the name travels, and a gate read from it alone lets the first two
//! out as top-level frames. A second table here would say what `mcp` already
//! owns, so the half that has to know has no entry point until `mcp` models
//! where a notification travels.
//!
//! ## Allocating
//!
//! `ARCHITECTURE.md` section 4 lets this layer allocate where state is
//! genuinely dynamic. Here it does not need to: every buffer is the caller's.
//! One of them does two jobs, the frame buffer in [`Client.request`], which is
//! the scratch the `_meta` merge walks with because `conn.call` has not
//! written into it yet and a buffer that can hold the frame can hold the
//! member names of the params inside it.

const std = @import("std");
const conn = @import("conn.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const mcp = @import("mcp.zig");
const root = @import("root.zig");
const Io = std.Io;

/// What this layer reports, and what it borrows rather than re-declares.
///
/// `mcp.ResultError` is here because this layer calls [`mcp.classifyResult`]
/// and nothing else. The three result rules read a document rather than a
/// connection, so they moved down to the codec, and the faults they can
/// refuse arrive here from there. Naming one of those three again alongside
/// this would be two declarations of one value, and leaving one out would
/// leave a `try` across that call with no error to raise.
///
/// `NotAnObject` is the one result-shaped fault that stays, and it stays
/// because it is not about a result: it is a `params` the caller passed that
/// cannot carry a `_meta` wrapper, which is a fault of the call rather than of
/// anything a decoder read.
pub const Error = mcp.ResultError || error{
    /// The method is not part of the pinned revision, so it was not sent.
    ///
    /// Reported before the wire rather than as a peer's `-32601`, because the
    /// caller can fix it without a round trip and a peer on another revision
    /// may well still accept it.
    MethodNotInRevision,
    /// The method is part of the revision but is not a request: it is a
    /// notification, or it is a method the other side sends.
    ///
    /// A notification carries no id and is never answered, so one sent as a
    /// request leaves the caller waiting for an answer no conforming peer will
    /// send; a method the other side sends is not this side's to call, and
    /// answering one is as wrong as calling one. Reported before the wire
    /// rather than as a peer's `-32601`, because no revision of the method
    /// table makes one of these a request.
    ///
    /// Distinct from `MethodNotInRevision` because the caller's repair differs:
    /// a removed name is a method again at the other revision, and a
    /// notification never is.
    NotARequest,
    /// The method is part of the revision but is not a notification: it is a
    /// request, or it is a method the other side sends.
    ///
    /// The mirror of `NotARequest`, and reported before the wire for the same
    /// reason. A request sent as a notification reaches the peer as a message
    /// with no id, which is the whole of what makes one a notification, so
    /// the handler behind it runs and the peer sends nothing back: the call
    /// happened, with no result and no error, and nothing the caller can see
    /// says which of the two it is in.
    ///
    /// Distinct from `MethodNotInRevision` because the caller's repair differs:
    /// a removed name is a notification again at the other revision, and a
    /// request never is one at any revision.
    NotANotification,
    /// The `params` a caller passed are not a single JSON object, so `_meta`
    /// cannot be added to them.
    ///
    /// Also a `params` whose own `_meta` is not an object, which cannot be
    /// merged with. Distinct from `BufferTooSmall`: the object is what cannot
    /// be wrapped, not the buffer, so a caller that doubles the buffer and
    /// tries again gets this again.
    NotAnObject,
    /// The result carried a `resultType` this library does not define.
    UnknownResultType,
} || conn.Error;

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

    /// Send `method` and return what the peer answered.
    ///
    /// The answer is a [`conn.Response`], so a peer that answered with an
    /// error comes back as a failure the caller can read: `error_code` is the
    /// code it sent and `body` is its error object. Reading `body` alone
    /// reports a failed call as a result, which is what this return type
    /// exists to stop.
    ///
    /// `params` is the caller's own JSON object, or null. When this session
    /// has to add the `_meta` wrapper it builds one into `params_out` and sends
    /// that, leaving the caller's buffer untouched. A `params` that carries
    /// `_meta` of its own has the capabilities merged into it rather than
    /// written beside them, so PROTOCOLS.md 4.7's retry travels one `_meta`
    /// object. A `params` that is not a single JSON object is
    /// `error.NotAnObject` rather than `error.BufferTooSmall`, so a caller
    /// sizing a buffer is not sent looking for one.
    ///
    /// `out` does two jobs, the frame and the scratch the merge walks with.
    /// `conn.call` has not written into it yet, and a buffer that can hold the
    /// frame can hold the decoded width of every member name in the params it
    /// carries, so a call that fits never fails for want of scratch.
    ///
    /// A `params` this session adds nothing to is written as the caller built
    /// it. The convention the whole tree keeps is that a caller's own JSON is
    /// spliced verbatim and the framer, not the codec, is what refuses a body
    /// that does not parse; this layer only walks a `params` it has to rewrite
    /// anyway, which is what makes that walk free to refuse a malformed one.
    pub fn request(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
        params_out: []u8,
    ) Error!conn.Response {
        // Checked before the wire, so a removed method is refused locally and a
        // notification never goes on the wire as a request.
        _ = requestMethod(self.revision, method) catch |err| return err;

        const payload = if (self.capabilities) |caps| blk: {
            // At the previous revision the capabilities travel in `initialize`,
            // so wrapping every request would be sending something the peer
            // never asked for.
            if (self.revision != .current) break :blk params;
            // A call with no params of its own still carries `_meta`, so the
            // capabilities go on an empty object rather than on nothing.
            const text = params orelse "{}";
            break :blk injectMeta(text, caps, params_out, out) catch |err| switch (err) {
                // The object is what cannot be wrapped, not the buffer it was
                // offered in, so the two are reported apart.
                error.InvalidField => return error.NotAnObject,
                else => return error.BufferTooSmall,
            };
        } else params;

        const answer = try self.connection.call(method, payload, result, out);
        // Carried whole, so the code beside the body is what tells the caller a
        // peer error from a result.
        return answer;
    }

    /// Send a notification: a method with no id, which expects no answer.
    ///
    /// Gated the way [`Client.request`] is, read the other way round, and
    /// refused before the wire rather than as a peer's `-32601`: no revision
    /// of the method table makes a request a notification or sends a
    /// server-to-client name from here, so a peer has nothing to add to a
    /// refusal the caller can make without a round trip.
    ///
    /// One name goes out at `2026-07-28` and two at `2025-11-25`. That is
    /// [`notificationMethod`] deciding it rather than a list written here, and
    /// the two numbers move when the inventory in [`mcp.notifications`]
    /// does.
    ///
    /// `params` is spliced into the frame verbatim, as it is in
    /// [`Client.request`] and for the same reason: this layer walks a params
    /// only when it has to rewrite it, and a notification has nothing to
    /// rewrite. A params carrying a raw newline is `error.Framing` and leaves
    /// the connection usable, because those same bytes fail however often
    /// they are sent. Nothing here checks that it parses — the framer is what
    /// refuses a body that does not, and the peer's decoder is what reads it.
    ///
    /// No `_meta` is added, and there is no buffer to add it into. PROTOCOLS.md
    /// 4.8 makes the client capabilities a property of a request, and a
    /// notification is not one, so there is nothing here for the injection
    /// [`Client.request`] does and no `params_out` for it to do it into. A
    /// notification that has to carry a `_meta` of its own writes it into
    /// `params`, and it travels as it was written.
    pub fn notify(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        out: []u8,
    ) Error!void {
        _ = try notificationMethod(self.revision, method);
        return self.connection.notify(method, params, out);
    }

    /// Run one multi-round-trip exchange to completion.
    ///
    /// Sends `method`; while the answer is `input_required`, builds the retry
    /// from `answer_interim` and sends it under a *new* id, which the
    /// specification requires and the connection guarantees.
    ///
    /// An error answer ends the exchange there and comes back as the failure
    /// the peer reported. An MCP error object carries no `resultType`, so
    /// classifying one would read it as the `complete` that a peer on an
    /// earlier revision omits, and the caller would be handed the error object
    /// as the final result of a completed exchange.
    ///
    /// A method PROTOCOLS.md 4.7 does not let return an interim result is
    /// refused rather than answered, so a peer cannot buy an extra round trip
    /// by sending one. [`mcp.permitsMrtr`] is the only list of those methods.
    ///
    /// `params_out` does two jobs. `request` builds the `_meta` wrapper into
    /// it, and [`mcp.classifyResult`] then reads the answer with it as its
    /// scratch. That is safe because the wrapper is on the wire by then and the
    /// answer sits in the caller's `result` buffer.
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
    ) Error!conn.Response {
        const first = try self.request(method, params, result, out, params_out);
        // An error answer ends the exchange rather than being classified.
        if (first.failed()) return first;

        const kind = try mcp.classifyResult(first.body, params_out);
        if (kind.isComplete()) return first;
        // The value first, then the method. A `resultType` this library does
        // not define is a fault of its own whatever the method sent it, and
        // that is what a caller reading `UnknownResultType` needs to be told.
        if (kind.known() == null) return error.UnknownResultType;
        // The answer is a recognised interim result, so the method decides
        // whether one was allowed here at all.
        if (!mcp.permitsMrtr(method)) return error.InputRequiredUnexpected;

        const responses = answer_interim orelse return error.InputRequiredUnexpected;
        const retry = try self.request(method, responses, result, out, params_out);
        if (retry.failed()) return retry;

        // The retry is classified too, so an interim result is never handed
        // back as the final one. A second `input_required` is not answered here:
        // another round is the caller's to drive, with input this layer has no
        // business inventing.
        const retried = try mcp.classifyResult(retry.body, params_out);
        if (retried.isComplete()) return retry;
        // The value first, on this leg as on the first. A `resultType` the
        // revision does not define is a fault of the answer whichever leg it
        // arrived on, and reporting it as a second interim result would send
        // the caller to look for a method or an answer problem when the fault
        // is the value — the inversion the first leg's own comment rules out.
        if (retried.known() == null) return error.UnknownResultType;
        return error.InputRequiredUnexpected;
    }
};

/// A server bound to one revision.
///
/// The mirror of [`Client`]. Both halves hold the same pin and read it through
/// the same gate, so a name the client refuses to send is a name the server
/// refuses to answer, and the two sides agree on what exists without
/// exchanging a version to find out.
pub const Server = struct {
    /// The connection this server answers on.
    ///
    /// Nothing here reads or writes through it. Every builder below returns
    /// text the caller hands to that connection's handler, because the handler
    /// holds the frame and the scratch. The field is here so a server is one
    /// value with its connection, the way [`Client`] is.
    ///
    /// There is no `notify` to go with it, and that is the reason rather than
    /// an oversight. PROTOCOLS.md 4.4 puts two of the server-to-client
    /// notifications on the originating request's response stream and scopes
    /// two more to a `subscriptions/listen`, and [`mcp.Direction`] records
    /// only who may send a name, not where the name travels. A gate read from
    /// it alone would put a progress notification on the wire as a message of
    /// its own, so the half that has to know which is which has no entry point
    /// until `mcp` carries the distinction. A handler that has one to write
    /// returns the frame itself, which is what a [`conn.Handler`] already
    /// answers with.
    connection: *conn.Conn,
    revision: mcp.Revision,
    /// The capabilities object this server advertises in its `server/discover`
    /// result, or null to advertise none. Borrowed for the session's life and
    /// never copied.
    capabilities: ?[]const u8 = null,
    /// The revisions this server answers for. Borrowed for the session's life
    /// and never copied, so a caller that assembles the list holds it for as
    /// long as the session lives.
    supported_versions: []const []const u8 = &.{},
    /// The freshness hint the `server/discover` result advertises, in
    /// milliseconds, or null when this server has not chosen one.
    ///
    /// PROTOCOLS.md 4.6 makes `ttlMs` required on a cacheable result and 4.4
    /// marks `server/discover` one, so [`Server.discoverBody`] refuses without
    /// it.
    /// The type is `u64` because that is what [`mcp.decodeCacheable`] reads
    /// the field back as, and a negative count of milliseconds has no
    /// representation there.
    cache_ttl_ms: ?u64 = null,
    /// The caching scope the same result advertises, or null when this server
    /// has not chosen one.
    ///
    /// The tag is the wire spelling, so [`Server.discoverBody`] writes it with
    /// `@tagName` rather than keeping a second copy of the two literals
    /// [`mcp.parseCacheScope`] reads.
    cache_scope: ?mcp.CacheScope = null,

    pub fn init(connection: *conn.Conn, revision: mcp.Revision) Server {
        return .{ .connection = connection, .revision = revision };
    }

    /// The pinned revision's entry for a request this server may answer.
    ///
    /// `error.MethodNotInRevision` for a name the revision removed or never
    /// had, and `error.NotARequest` for one that is not a request at all: a
    /// notification, which expects no answer, or a method the client does not
    /// send, which is travelling the other way.
    ///
    /// A handler calls this before it reads `params`, so a name this revision
    /// removed costs the peer the `-32601` of [`Server.methodNotFound`] rather
    /// than whatever the handler would have guessed at for it, and a message
    /// that expects nothing never reaches a handler at all.
    pub fn gate(self: Server, method: []const u8) Error!mcp.MethodInfo {
        return requestMethod(self.revision, method);
    }

    /// What one request told the server, decided in one pass over it.
    pub const Observation = struct {
        revision: mcp.Revision,
        info: mcp.MethodInfo,
        /// The capabilities object the client sent in `_meta`, as raw JSON
        /// text, or null when it sent none. PROTOCOLS.md 4.8 lets a client
        /// advertise nothing, so an absent member is a fact and not a fault.
        ///
        /// The slice borrows `request.params` and copies nothing. `scratch`
        /// backs the unescaping of a key alone, so the value never lands in
        /// it.
        client_capabilities: ?[]const u8,
    };

    /// Answer both questions a handler asks of a request, from one decode.
    ///
    /// The method is checked against the pinned revision first, because a
    /// handler must not run for a name this revision removed. The client
    /// capabilities are read out of `params` second, under the `mcp.meta_key`
    /// name PROTOCOLS.md 4.8 gives them and with the walk
    /// [`json.memberText`] already provides.
    ///
    /// `_meta` is read at either revision, because a member that is there is
    /// a fact about the request whatever the specification requires of a peer
    /// on that revision. A client at `2025-11-25` carries its capabilities in
    /// `initialize` instead, and this reports the absence rather than going
    /// after them.
    pub fn observe(self: Server, request: jsonrpc.Request, scratch: []u8) Error!Observation {
        const info = try self.gate(request.method.text);
        var observation: Observation = .{
            .revision = self.revision,
            .info = info,
            .client_capabilities = null,
        };
        const params = switch (request.params) {
            .value => |text| text,
            // No object means no `_meta`, and 4.8 permits a client to send no
            // capabilities.
            else => return observation,
        };
        const meta = json.memberText(params, "_meta", scratch) orelse return observation;
        observation.client_capabilities =
            json.memberText(meta, mcp.meta_key.client_capabilities, scratch);
        return observation;
    }

    /// The whole `-32601` frame for a method this revision does not have.
    ///
    /// The envelope is [`conn.methodNotFound`]'s, not a second one written
    /// here. The connection keeps the builder that carries a result apart from
    /// the builder that carries an error, so a frame cannot come out holding
    /// both or neither.
    ///
    /// No session, because the frame does not depend on one: the code is
    /// JSON-RPC's and the id is the one the request carried. The error set
    /// here is [`conn.Error`], which has no member for "you asked me to refuse
    /// a method I do have", so a check on the revision would have nowhere to
    /// report itself. [`Server.gate`] is where the revision is read.
    pub fn methodNotFound(request: jsonrpc.Request, out: []u8) conn.Error![]const u8 {
        return conn.methodNotFound(request, out);
    }

    /// Write the `server/discover` result body.
    ///
    /// PROTOCOLS.md 4.6 puts `resultType` on every result and adds `ttlMs` and
    /// `cacheScope` to one the method table marks cacheable, and 4.4 marks
    /// `server/discover` cacheable. Those three come first, and the three 4.4
    /// names follow in the order the table lists them: `supportedVersions`
    /// from the session's own list, `capabilities` from its own object, and
    /// `instructions` when the caller has some. Every value is the caller's
    /// own, and nothing is invented for a caller that has none.
    ///
    /// A session with no caching values is refused rather than handed a body
    /// [`mcp.checkResult`] would refuse. A caller holding a body will send it,
    /// and a body refused on arrival has already travelled; refusing here
    /// leaves no frame to be wrong about.
    ///
    /// A session with no capabilities writes the literal `null`, which is the
    /// member present with no object in it. That is not the same as leaving
    /// the member out, and a caller reading the difference with
    /// [`json.memberText`] is right to.
    pub fn discoverBody(self: Server, instructions: ?[]const u8, out: []u8) Error![]const u8 {
        // Refused before a byte is written, so a server that cannot answer
        // `server/discover` learns so without a frame half-built in `out`.
        const ttl_ms = self.cache_ttl_ms orelse return error.NotAResult;
        const cache_scope = self.cache_scope orelse return error.NotAResult;
        var writer = json.Writer.init(out);
        writer.slice("{\"resultType\":\"" ++ mcp.result_type_value.complete ++
            "\",\"ttlMs\":") catch return error.BufferTooSmall;
        writeDecimal(&writer, ttl_ms) catch return error.BufferTooSmall;
        writer.slice(",\"cacheScope\":") catch return error.BufferTooSmall;
        writer.string(@tagName(cache_scope)) catch return error.BufferTooSmall;
        writer.slice(",\"supportedVersions\":[") catch return error.BufferTooSmall;
        for (self.supported_versions, 0..) |version, at| {
            if (at != 0) writer.byte(',') catch return error.BufferTooSmall;
            writer.string(version) catch return error.BufferTooSmall;
        }
        writer.slice("],\"capabilities\":") catch return error.BufferTooSmall;
        writer.slice(self.capabilities orelse "null") catch return error.BufferTooSmall;
        if (instructions) |text| {
            writer.slice(",\"instructions\":") catch return error.BufferTooSmall;
            writer.string(text) catch return error.BufferTooSmall;
        }
        writer.byte('}') catch return error.BufferTooSmall;
        return writer.written();
    }
};

/// Write a `u64` as decimal digits, with no sign and no separator.
///
/// A `u64` is at most twenty decimal digits, so the buffer cannot fill before
/// the number does and the only thing this can fail on is a short `out`.
fn writeDecimal(writer: *json.Writer, value: u64) root.EncodeError!void {
    var digits: [20]u8 = undefined;
    var at: usize = digits.len;
    // A local and not the parameter, because the number is divided down as
    // the digits come out: this is an accumulator, and the caller's value is
    // still the number that was handed over.
    var remaining = value;
    while (true) {
        at -= 1;
        digits[at] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) break;
    }
    try writer.slice(digits[at..]);
}

/// The pinned revision's entry for a request this side may send.
///
/// A name the revision does not have is `MethodNotInRevision`; a name it has
/// that is not a request is `NotARequest`. The two are apart because the
/// caller's repair differs: a removed name is a method again at the other
/// revision, and a notification never is one at any revision.
fn requestMethod(revision: mcp.Revision, method: []const u8) Error!mcp.MethodInfo {
    const info = mcp.lookupMethod(revision, method) catch return error.MethodNotInRevision;
    // The arity, first. `mcp.lookupMethod` searches the request table and the
    // notification table alike, so a notification resolves as readily as a
    // request and the pin alone does not refuse it.
    if (isNotification(method)) return error.NotARequest;
    // The direction, second. A method the other side sends is not this side's
    // to call, and a server answering one is as wrong as a client calling one.
    if (info.direction != .client_to_server) return error.NotARequest;
    return info;
}

/// Whether `name` is a notification at either revision.
///
/// The union of both inventories rather than the one the revision resolves,
/// because a name removed at `2026-07-28` is a method again at `2025-11-25`
/// and a caller must not learn that by sending one as a request. The wider
/// union costs no precision at the current revision: a removed name is
/// refused by [`requestMethod`] as `MethodNotInRevision` before this decides
/// anything about it.
fn isNotification(name: []const u8) bool {
    for (mcp.notifications) |notification| {
        if (std.mem.eql(u8, notification.name, name)) return true;
    }
    for (mcp.removed_methods) |removed| {
        if (removed.notification and std.mem.eql(u8, removed.name, name)) return true;
    }
    return false;
}

/// The pinned revision's entry for a notification a client may send.
///
/// The mirror of [`requestMethod`], and the two are one walk read the other
/// way round: a name the revision does not have is `MethodNotInRevision`, and
/// a name it has that is not a notification, or that travels the other way, is
/// `NotANotification`.
fn notificationMethod(revision: mcp.Revision, method: []const u8) Error!mcp.MethodInfo {
    const info = mcp.lookupMethod(revision, method) catch return error.MethodNotInRevision;
    // The arity, first, and for the reason `requestMethod` gives: the pin
    // resolves a request as readily as a notification, so nothing but this
    // tells the two apart.
    if (!isNotification(method)) return error.NotANotification;
    // The direction, second, and named as the two a client may send. The gate
    // that reads it from the other end — refuse `client_to_server` and let the
    // rest through — is the same two lines with the sides swapped, and it
    // admits `notifications/progress` and the six notifications beside it.
    if (sendsFromClient(info.direction)) return info;
    return error.NotANotification;
}

/// Whether a client may send a method with this direction.
///
/// Every arm written out, so a `Direction` member added later is a compile
/// error here rather than a direction this decides by falling out of the
/// switch.
fn sendsFromClient(direction: mcp.Direction) bool {
    return switch (direction) {
        .client_to_server, .bidirectional => true,
        .server_to_client, .server_to_client_mrtr_only => false,
    };
}

/// Add `_meta` to a params object, keeping the caller's members.
///
/// The caller's own `_meta` is merged into the one this writes rather than
/// written beside it, because two members of one name in one object have no
/// single meaning: [`json.memberText`] resolves the first and a peer that
/// resolves the last reads the other, so a duplicate either hides the
/// caller's `_meta` or hides the capabilities. PROTOCOLS.md 4.7 puts `_meta`
/// on a multi-round-trip retry as well as on the call that opens it, and 4.3
/// excepts `progressToken` as a bare `_meta` key, so the case is a retry that
/// correlates progress rather than an exotic one.
///
/// The members are re-emitted, so the bytes may differ from the ones that were
/// passed while the members do not: a name comes back from the walk decoded
/// and is written escaped again, whitespace between members is dropped, and
/// every value is copied as the wire carried it. That walk is also what
/// decides the params are an object, so a value that is not one, or one with
/// anything after it, is refused rather than mangled.
///
/// `scratch` backs the unescaping of the member names, so it has to hold the
/// decoded width of every name in the object. [`Client.request`] passes the
/// frame buffer, which `conn.call` has not written into yet and which is
/// wider than the params it will carry.
fn injectMeta(
    params: []const u8,
    caps: []const u8,
    out: []u8,
    scratch: []u8,
) root.EncodeError![]const u8 {
    // The wrapper comes first, and the walk below cannot know where the
    // caller's own `_meta` is until it has been read, so the params are walked
    // twice: once for that member and once for the rest. One pass would either
    // close `_meta` before a member the caller put after it, which lands the
    // rest inside the capabilities object, or write the wrapper last, which is
    // a different object from the one this layer has always written. Reading
    // the caller's `_meta` first also means a params that is not an object is
    // refused before a byte of output exists rather than half-built in it.
    const own_meta = findMeta(params, scratch) catch |err| return readFailure(err);

    var reader = json.Reader.init(params);
    var writer = json.Writer.init(out);
    try writer.slice("{\"_meta\":{\"");
    try writer.slice(mcp.meta_key.client_capabilities);
    try writer.slice("\":");
    try writer.slice(caps);
    if (own_meta) |raw| try mergeMeta(raw, &writer, scratch);
    // Close `_meta` before the caller's other members, or they land inside the
    // capabilities object instead of beside it.
    try writer.byte('}');

    // Everything else the caller sent, beside the wrapper. Padded params need
    // no trim of their own: the reader skips whitespace before and after the
    // object, and the sibling layer in `acp_session.zig` accepts the padded
    // form.
    if (!(reader.beginObject() catch |err| return readFailure(err))) {
        while (true) {
            const next = reader.nextKey(scratch) catch |err| return readFailure(err);
            const key = next orelse break;
            const value = reader.rawValue(scratch) catch |err| return readFailure(err);
            // Its own `_meta` is the one merged above, and writing it again is
            // the duplicate this whole walk exists to avoid.
            if (std.mem.eql(u8, key, "_meta")) continue;
            try writer.byte(',');
            try writeMember(key, value, &writer);
        }
    }
    // Anything after the object is not part of it, and a splice would have
    // carried it onto the wire behind a valid object.
    if (!reader.atEnd()) return error.InvalidField;
    try writer.byte('}');
    return writer.written();
}

/// The caller's own top-level `_meta`, as the raw text it was sent as, or null
/// when it sent none.
///
/// A walk of the object rather than a search of the text, because a `_meta`
/// nested inside another member is not a top-level one, and the first match is
/// the member every reader of this layer resolves.
fn findMeta(params: []const u8, scratch: []u8) root.EncodeError!?[]const u8 {
    var reader = json.Reader.init(params);
    if (reader.beginObject() catch |err| return readFailure(err)) return null;
    while (true) {
        const next = reader.nextKey(scratch) catch |err| return readFailure(err);
        const key = next orelse break;
        const value = reader.rawValue(scratch) catch |err| return readFailure(err);
        if (std.mem.eql(u8, key, "_meta")) return value;
    }
    return null;
}

/// Write the caller's own `_meta` members beside the capabilities.
///
/// One member is the precedence this merge defines: a `_meta` that carries
/// the capabilities key of its own loses it, because
/// [`Client.capabilities`] is what this layer defines those capabilities to
/// be, and a second copy beside it is the same ambiguity the merge exists to
/// remove. Every other member is the caller's and is written as it is.
fn mergeMeta(raw: []const u8, writer: *json.Writer, scratch: []u8) root.EncodeError!void {
    var reader = json.Reader.init(raw);
    // A `_meta` that is not an object cannot be merged with, and splicing it
    // would put its value beside the capabilities under the one name.
    if (reader.beginObject() catch |err| return readFailure(err)) return;
    while (true) {
        const next = reader.nextKey(scratch) catch |err| return readFailure(err);
        const key = next orelse break;
        const value = reader.rawValue(scratch) catch |err| return readFailure(err);
        if (std.mem.eql(u8, key, mcp.meta_key.client_capabilities)) continue;
        try writer.byte(',');
        try writeMember(key, value, writer);
    }
}

/// Write one member the caller sent, as `"name":value`.
fn writeMember(key: []const u8, value: []const u8, writer: *json.Writer) root.EncodeError!void {
    // The name the walk decoded, escaped again: `{"na\u006de":1}` comes back as
    // `{"name":1}`, which is the member the peer reads either way.
    try writer.string(key);
    try writer.byte(':');
    try writer.slice(value);
}

/// How a walk failure reaches a caller of [`injectMeta`], whose error set is
/// the encode one.
///
/// A scratch too small for an escaped member name is `BufferTooSmall` and the
/// caller's buffer grew, so it says so. Every other failure is the params
/// themselves: they are not the object this layer has to rewrite, and a
/// caller that doubles its output buffer and tries again gets the same answer.
fn readFailure(err: root.DecodeError) root.EncodeError {
    return switch (err) {
        error.BufferTooSmall => error.BufferTooSmall,
        else => error.InvalidField,
    };
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

/// Whether `name` is one of `set`, for the lists a test states literally.
///
/// The set is written out in the test rather than derived from
/// [`mcp.notifications`], and this is what compares the two. A set computed
/// from the same table the gate reads would agree with the gate whatever that
/// table said, which is the agreement that hides a change.
fn contains(set: []const []const u8, name: []const u8) bool {
    for (set) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

test "the current revision wraps params in _meta and keeps the caller's members" {
    var out: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    const params = try injectMeta("{\"name\":\"echo\"}", "{\"tools\":{}}", &out, &scratch);
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"tools\":{}}},\"name\":\"echo\"}",
        params,
    );
}

test "a call with no params still carries _meta" {
    var out: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    // The path `Client.request` takes for a null `params`: the capabilities go
    // on an empty object rather than on nothing, which is one call rather than
    // two.
    const params = try injectMeta("{}", "{\"tools\":{}}", &out, &scratch);
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"tools\":{}}}}",
        params,
    );
}

test "a multi-round-trip retry keeps its own _meta beside the capabilities" {
    // PROTOCOLS.md 4.7's retry, which carries `_meta` beside the members that
    // answer the interim result. Written twice before the fix — the
    // capabilities in front and the caller's own behind them — so a reader
    // that resolves the first saw no progress token and a reader that
    // resolved the last saw no capabilities.
    var out: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;
    const retry = "{\"name\":\"echo\",\"arguments\":{},\"inputResponses\":{}," ++
        "\"requestState\":\"st\",\"_meta\":{\"progressToken\":\"t1\"}}";
    const params = try injectMeta(retry, "{\"tools\":{}}", &out, &scratch);
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"tools\":{}}," ++
            "\"progressToken\":\"t1\"},\"name\":\"echo\",\"arguments\":{}," ++
            "\"inputResponses\":{},\"requestState\":\"st\"}",
        params,
    );
    // One member of that name, which is what the merge is for: two of them in
    // one object have no single meaning.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, params, "\"_meta\""));
    // Read back through the walk this layer and its peer share, so both
    // members are visible rather than one of them depending on which the
    // reader resolves first.
    const meta = json.memberText(params, "_meta", &scratch).?;
    try testing.expectEqualStrings(
        "{\"tools\":{}}",
        json.memberText(meta, mcp.meta_key.client_capabilities, &scratch).?,
    );
    try testing.expectEqualStrings(
        "\"t1\"",
        json.memberText(meta, mcp.meta_key.progress_token, &scratch).?,
    );
}

test "the server half reads the capabilities and the progress token off one request" {
    // The same merge, through the frame it travels in and the handler that
    // reads it. Before the fix the capabilities were what `Server.observe`
    // saw and the progress token was in a second `_meta` it never read.
    var out: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;
    var frame: [1024]u8 = undefined;
    const params = try injectMeta(
        "{\"name\":\"echo\",\"_meta\":{\"progressToken\":\"t1\"}}",
        "{\"tools\":{}}",
        &out,
        &scratch,
    );
    var writer = json.Writer.init(&frame);
    try writer.slice("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":");
    try writer.slice(params);
    try writer.byte('}');

    const server: Server = .{ .connection = undefined, .revision = .current };
    const request = try jsonrpc.decodeRequest(writer.written(), &scratch);
    const seen = try server.observe(request, &scratch);
    try testing.expectEqualStrings("tools/call", seen.info.name);
    try testing.expectEqualStrings("{\"tools\":{}}", seen.client_capabilities.?);
    // The progress token is in the same `_meta` object and not in a second
    // member of the same name beside it.
    const sent = switch (request.params) {
        .value => |text| text,
        else => return error.TestUnexpectedResult,
    };
    const meta = json.memberText(sent, "_meta", &scratch).?;
    try testing.expectEqualStrings(
        "\"t1\"",
        json.memberText(meta, mcp.meta_key.progress_token, &scratch).?,
    );
}

test "a caller's own copy of the capabilities key is not written beside the session's" {
    // The one precedence the merge defines: `Client.capabilities` is what this
    // layer defines the capabilities to be, and a second member of that name
    // beside it is the duplicate the merge exists to remove. Everything else
    // in the caller's `_meta` is the caller's and survives.
    var out: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;
    const params = try injectMeta(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"roots\":{}}," ++
            "\"progressToken\":\"t1\"}}",
        "{\"tools\":{}}",
        &out,
        &scratch,
    );
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"tools\":{}}," ++
            "\"progressToken\":\"t1\"}}",
        params,
    );
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, params, mcp.meta_key.client_capabilities),
    );
}

test "a member name carrying an escape is walked and written decoded" {
    // The walk decodes the name into the scratch and the writer escapes it
    // again, so `{"na\u006de":1}` travels as `{"name":1}`; the value is copied
    // as the wire carried it, its own escape and all.
    var out: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{}}," ++
            "\"name\":\"echo\",\"arguments\":{\"a\\tb\":1}}",
        try injectMeta(
            "{\"na\\u006de\":\"echo\",\"arguments\":{\"a\\tb\":1}}",
            "{}",
            &out,
            &scratch,
        ),
    );
    // A scratch too small to decode the name is the short-buffer error rather
    // than a refusal: the caller's buffer grew and the same call works again.
    var tiny_out: [256]u8 = undefined;
    var tiny_scratch: [1]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        injectMeta("{\"na\\u006de\":\"echo\"}", "{}", &tiny_out, &tiny_scratch),
    );
}

test "params that are not an object are refused rather than mangled" {
    var out: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    // Splicing assumes an object. A caller that passed an array would
    // otherwise get a silent rewrite into something the peer never sent.
    try testing.expectError(error.InvalidField, injectMeta("[1,2]", "{}", &out, &scratch));
    try testing.expectError(error.InvalidField, injectMeta("nope", "{}", &out, &scratch));
    try testing.expectError(error.InvalidField, injectMeta("", "{}", &out, &scratch));
    // A first byte and a last byte are not an object. `{}}` came out as a
    // valid object with a brace hanging off it and `{]}` framed a params the
    // peer's framer drops, so the caller waited for an answer to a message
    // that was never a request.
    try testing.expectError(error.InvalidField, injectMeta("{}}", "{}", &out, &scratch));
    try testing.expectError(error.InvalidField, injectMeta("{]}", "{}", &out, &scratch));
    try testing.expectError(error.InvalidField, injectMeta("{\"a\":1} x", "{}", &out, &scratch));
    // A member the walk cannot read is refused for the same reason, and so is
    // a `_meta` that cannot be merged with.
    try testing.expectError(error.InvalidField, injectMeta("{\"a\":}", "{}", &out, &scratch));
    try testing.expectError(error.InvalidField, injectMeta("{\"_meta\":7}", "{}", &out, &scratch));
}

test "params padded with whitespace wrap, as the sibling layer allows" {
    // `acp_session.requireObject` trims before it looks for a brace, so an
    // object it accepts must not be refused here for the whitespace around it.
    // The walk skips that whitespace itself, which is what the trim was for.
    var out: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    const params = try injectMeta(" \n{\"name\":\"echo\"}\t", "{\"tools\":{}}", &out, &scratch);
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{\"tools\":{}}},\"name\":\"echo\"}",
        params,
    );
}

test "an object holding only whitespace gains no trailing comma" {
    // The comma separates `_meta` from a member that exists, so `{ }` must come
    // out as an object with two members rather than one with a dangling
    // separator the peer cannot parse.
    var out: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{}}}",
        try injectMeta("{ }", "{}", &out, &scratch),
    );
}

test "a method the pinned revision removed never reaches the wire" {
    // The connection is `undefined` because the refusal happens before it is
    // touched: a method this revision removed must cost the caller no round
    // trip.
    var client: Client = .{ .connection = undefined, .revision = .current };
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var params_out: [256]u8 = undefined;
    try testing.expectError(
        error.MethodNotInRevision,
        client.request("initialize", null, &result, &out, &params_out),
    );
}

test "a notification is never sent as a request, and a request still passes" {
    // Both halves refuse before the wire, so the connection is `undefined`: a
    // notification sent as a request leaves the caller waiting for an answer
    // no conforming peer will send, which is what this rule is for.
    var client: Client = .{ .connection = undefined, .revision = .current };
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var params_out: [256]u8 = undefined;
    const server: Server = .{ .connection = undefined, .revision = .current };

    // Every notification PROTOCOLS.md 4.4 lists. `notifications/cancelled` is
    // the one either side may send, so the direction alone would have let it
    // through; the rest are a server-to-client method besides.
    for (mcp.notifications) |notification| {
        try testing.expectError(
            error.NotARequest,
            client.request(notification.name, null, &result, &out, &params_out),
        );
        // The same rule read the other way round, so a handler is not entered
        // for a message that expects no answer or for one travelling the other
        // way.
        try testing.expectError(error.NotARequest, server.gate(notification.name));
    }

    // A request the client does send passes the gate on both sides.
    try testing.expectEqualStrings("tools/call", (try server.gate("tools/call")).name);
    try testing.expectEqualStrings("tools/call", (try requestMethod(.current, "tools/call")).name);

    // A notification the current revision removed is a method again at the
    // previous one, and is still refused there: it takes no id at any revision,
    // and the direction it does carry is the client's, so the arity is the only
    // thing left to refuse it on.
    const before: Server = .{ .connection = undefined, .revision = .previous };
    try testing.expectError(error.NotARequest, before.gate("notifications/initialized"));
    // A removed method that is a request is a request at the previous revision,
    // so nothing but the pin refuses it there.
    try testing.expectEqualStrings("ping", (try before.gate("ping")).name);
}

test "a client sends one notification at the current revision and two at the previous" {
    // The count on its own, and first, because the set below cannot say what
    // changed if the table does. A ninth name, or an eighth marked the other
    // way round, is a decision somebody made on purpose, and this number is
    // where it shows up rather than a set that quietly agrees with it.
    try testing.expectEqual(@as(usize, 8), mcp.notifications.len);
    // PROTOCOLS.md 4.4 marks seven of the eight server-to-client and
    // `notifications/cancelled` the one either side may send. That split is
    // what makes the counts at the bottom one and two rather than a
    // coincidence, and the seven are what a gate read from the wrong end of
    // the pair lets out.
    var server_to_client: usize = 0;
    for (mcp.notifications) |notification| {
        if (notification.direction == .server_to_client) server_to_client += 1;
    }
    try testing.expectEqual(@as(usize, 7), server_to_client);

    // The sets, written out rather than derived from the table the gate reads.
    const at_current = [_][]const u8{"notifications/cancelled"};
    const at_previous = [_][]const u8{ "notifications/cancelled", "notifications/initialized" };

    // Both connections are `undefined` throughout: a refusal is decided before
    // anything reaches one, so a gate that let a name through would fault here
    // rather than pass quietly.
    var now: Client = .{ .connection = undefined, .revision = .current };
    var then: Client = .{ .connection = undefined, .revision = .previous };
    var out: [256]u8 = undefined;

    var accepted_now: usize = 0;
    var accepted_before: usize = 0;
    for (mcp.notifications) |notification| {
        if (contains(&at_current, notification.name)) {
            accepted_now += 1;
        } else {
            try testing.expectError(
                error.NotANotification,
                now.notify(notification.name, null, &out),
            );
        }
        if (contains(&at_previous, notification.name)) {
            accepted_before += 1;
        } else {
            try testing.expectError(
                error.NotANotification,
                then.notify(notification.name, null, &out),
            );
        }
    }
    try testing.expectEqual(at_current.len, accepted_now);
    // The one name the current revision removed is a notification a client does
    // send at `2025-11-25` and not at `2026-07-28`, and it is not in
    // `mcp.notifications`, so the loop above never saw it and the count carries
    // it by hand.
    try testing.expectEqual(at_previous.len, accepted_before + 1);

    // Named rather than only counted, so the two numbers above are attached to
    // these and not to whatever the table happens to hold.
    try testing.expectEqualStrings(
        "notifications/cancelled",
        (try notificationMethod(.current, "notifications/cancelled")).name,
    );
    try testing.expectEqualStrings(
        "notifications/initialized",
        (try notificationMethod(.previous, "notifications/initialized")).name,
    );
    try testing.expectError(
        error.MethodNotInRevision,
        now.notify("notifications/initialized", null, &out),
    );
}

test "notify refuses a request and a notification the direction forbids" {
    // The two faults behind `NotANotification`, with the revision one beside
    // them. The connection is `undefined`: a refusal is decided before anything
    // reaches it, so a gate that let one of these through would fault here.
    var client: Client = .{ .connection = undefined, .revision = .current };
    var out: [256]u8 = undefined;

    // A request, which is not a notification at any revision. Sent as one it
    // reaches the peer with no id, so the handler behind it runs and nothing
    // comes back: the call happened and nothing the caller can see says it did.
    try testing.expectError(error.NotANotification, client.notify("tools/call", null, &out));
    // A name this revision removed, which is a notification the other one still
    // has. A different fault with a different repair, and a gate that reported
    // it as an arity would send the caller to look for a method that is there.
    try testing.expectError(
        error.MethodNotInRevision,
        client.notify("notifications/initialized", null, &out),
    );
    try testing.expectError(
        error.MethodNotInRevision,
        client.notify("notifications/nope", null, &out),
    );
    // The one that reads as a bug. `notifications/progress` is a notification
    // and the table marks it server-to-client, so a gate written as "refuse
    // `client_to_server`" admits it and the six beside it — and PROTOCOLS.md
    // 4.4 has this one travel on the originating request's response stream
    // rather than as a message of its own.
    try testing.expectError(
        error.NotANotification,
        client.notify("notifications/progress", null, &out),
    );
}

test "a request whose params are not an object never reaches the wire" {
    // Its own error, and not the short-buffer one: a caller that doubled
    // `params_out` and called again would get this again, because the object it
    // handed over is what cannot carry `_meta`.
    var client: Client = .{ .connection = undefined, .revision = .current };
    client.capabilities = "{\"tools\":{}}";
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var params_out: [256]u8 = undefined;
    try testing.expectError(
        error.NotAnObject,
        client.request("tools/list", "[1,2]", &result, &out, &params_out),
    );
    // The two a first byte and a last byte used to let through: `{}}` came out
    // as an object with a brace hanging off it, and `{]}` framed a params the
    // peer's framer drops, so the caller waited for an answer to a message
    // that was never a request.
    try testing.expectError(
        error.NotAnObject,
        client.request("tools/list", "{}}", &result, &out, &params_out),
    );
    try testing.expectError(
        error.NotAnObject,
        client.request("tools/list", "{]}", &result, &out, &params_out),
    );
}

test "a _meta wrapper that does not fit is reported before the wire" {
    var client: Client = .{ .connection = undefined, .revision = .current };
    client.capabilities = "{\"tools\":{}}";
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var params_out: [8]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        client.request("tools/list", null, &result, &out, &params_out),
    );
}

// --- The server half -------------------------------------------------------------

test "the two halves refuse the same name on both sides of a removal" {
    // Every name PROTOCOLS.md 4.4 lists as removed at `2026-07-28`. A session
    // is pinned because the two revisions disagree about them, and the client
    // half of this file reaches the same table this one does.
    const removed = [_][]const u8{
        "initialize",
        "logging/setLevel",
        "notifications/elicitation/complete",
        "notifications/initialized",
        "notifications/roots/list_changed",
        "ping",
        "resources/subscribe",
        "resources/unsubscribe",
    };
    // Both connections are `undefined` because a refusal is decided before
    // anything reaches them.
    const now: Server = .{ .connection = undefined, .revision = .current };
    const before: Server = .{ .connection = undefined, .revision = .previous };
    var client: Client = .{ .connection = undefined, .revision = .current };
    var result: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var params_out: [256]u8 = undefined;

    for (removed) |name| {
        try testing.expectError(error.MethodNotInRevision, now.gate(name));
        // The property the two halves exist for: the name a client would not
        // send is the name a server will not answer.
        try testing.expectError(
            error.MethodNotInRevision,
            client.request(name, null, &result, &out, &params_out),
        );
        // At the previous revision the same name is a method again, so a
        // session pinned there does not refuse a call the peer still has. A
        // notification is the exception and is refused for its arity instead,
        // which is a different fault with a different error: a loop that read
        // the two as one would pass with either half broken.
        if (isNotification(name)) {
            try testing.expectError(error.NotARequest, before.gate(name));
            continue;
        }
        const info = try before.gate(name);
        try testing.expectEqualStrings(name, info.name);
        try testing.expect(!info.present_at_current);
        try testing.expect(info.deprecated);
    }

    // A name neither revision has is refused on both rather than answered on
    // one of them for resembling a removed one.
    try testing.expectError(error.MethodNotInRevision, now.gate("tools/nope"));
    try testing.expectError(error.MethodNotInRevision, before.gate("tools/nope"));
}

test "the three methods that live only inside inputRequests pass no gate now" {
    // PROTOCOLS.md 4.4 removes `elicitation/create`, `sampling/createMessage`
    // and `roots/list` as top-level requests and keeps their types inside
    // `InputRequiredResult.inputRequests`. What decides a top-level name is
    // the position and the revision together: at `2026-07-28` none of the
    // three resolves as one, and at `2025-11-25` each was the
    // client-to-server request that revision's own document defines, so
    // `mcp.previous_top_level_requests` carries them and a session pinned
    // there answers them as it answers any other request.
    const only_inside = [_][]const u8{
        "elicitation/create",
        "roots/list",
        "sampling/createMessage",
    };
    const now: Server = .{ .connection = undefined, .revision = .current };
    const before: Server = .{ .connection = undefined, .revision = .previous };
    for (only_inside) |name| {
        try testing.expectError(error.MethodNotInRevision, now.gate(name));
        // `mcp.lookupInputRequest` is where they live inside a result, and it
        // finds them at every revision: being a value an interim result
        // carries and being a top-level name are two positions, and 4.4
        // removed the second without touching the first.
        try testing.expectEqualStrings(name, (try mcp.lookupInputRequest(name)).name);

        // The previous revision, where the top-level name is a request again
        // and neither half refuses it. The direction is the point: what was
        // removed is the position, and the side that sent it is the client's.
        const found = try before.gate(name);
        try testing.expectEqualStrings(name, found.name);
        try testing.expectEqual(mcp.Direction.client_to_server, found.direction);
        try testing.expect(!found.present_at_current);
        try testing.expect(found.deprecated);
    }
}

test "observe returns the method and the capabilities the request carried" {
    var scratch: [512]u8 = undefined;
    const server: Server = .{ .connection = undefined, .revision = .current };

    // No `_meta` at all. PROTOCOLS.md 4.8 lets a client advertise nothing, so
    // the method is reported and the capabilities are null.
    const bare = try jsonrpc.decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"c"}}
    , &scratch);
    const without = try server.observe(bare, &scratch);
    try testing.expectEqualStrings("tools/list", without.info.name);
    try testing.expectEqual(mcp.Revision.current, without.revision);
    try testing.expect(without.client_capabilities == null);

    // With `_meta`, and with the caller's own member beside it.
    const carried = try jsonrpc.decodeRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","_meta":{"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true}}}}}
    , &scratch);
    const seen = try server.observe(carried, &scratch);
    try testing.expectEqualStrings("tools/call", seen.info.name);
    try testing.expectEqualStrings(
        "{\"roots\":{\"listChanged\":true}}",
        seen.client_capabilities.?,
    );

    // `json.memberText` is the walk behind that answer, and it is the walk a
    // caller reaches for as well. Driven here so the two are visibly one
    // mechanism and not two parsers that happen to agree today.
    var walk: [512]u8 = undefined;
    const params = switch (carried.params) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const meta = json.memberText(params, "_meta", &walk).?;
    try testing.expectEqualStrings(
        seen.client_capabilities.?,
        json.memberText(meta, mcp.meta_key.client_capabilities, &walk).?,
    );
}

test "observe refuses a request whose method this revision removed" {
    // The refusal is a return value, so a handler is never entered for a name
    // the revision dropped and never has to check for one itself.
    var scratch: [256]u8 = undefined;
    const server: Server = .{ .connection = undefined, .revision = .current };
    const request = try jsonrpc.decodeRequest(
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    , &scratch);
    try testing.expectError(error.MethodNotInRevision, server.observe(request, &scratch));
}

test "the refusal frame is a JSON-RPC error carrying -32601 and no result" {
    var scratch: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    const request = try jsonrpc.decodeRequest(
        \\{"jsonrpc":"2.0","id":7,"method":"ping"}
    , &scratch);

    const frame = try Server.methodNotFound(request, &out);
    const message = try jsonrpc.decode(frame, &scratch);
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    // A refusal is not a result with nothing in it. The connection keeps the
    // two apart, so exactly one of the members may be here and here it is the
    // error.
    try testing.expect(message.result == null);
    const failure = message.rpc_error orelse return error.TestUnexpectedResult;
    try testing.expectEqual(
        @as(i32, @intFromEnum(jsonrpc.StandardError.method_not_found)),
        failure.code,
    );
    // The id is the one the request carried, because the shared builder wrote
    // the envelope rather than this layer re-hand-writing it.
    try testing.expectEqual(@as(i64, 7), message.id.?.integer);
}

test "a result missing a required field is refused by the call" {
    var scratch: [256]u8 = undefined;
    const server: Server = .{ .connection = undefined, .revision = .current };

    const listing = try server.gate("tools/list");
    try testing.expect(listing.cacheable);
    try mcp.checkResult(
        listing,
        "{\"resultType\":\"complete\",\"ttlMs\":1000,\"cacheScope\":\"private\",\"tools\":[]}",
        &scratch,
    );

    // PROTOCOLS.md 4.6 makes `resultType` required on every result and the two
    // caching fields required on a cacheable one, so leaving out any of the
    // three is the same fault and none is a value a caller may fill in later.
    // The caching pair alone is not a result 4.6 describes.
    try testing.expectError(
        error.NotAResult,
        mcp.checkResult(listing, "{\"tools\":[]}", &scratch),
    );
    try testing.expectError(
        error.NotAResult,
        mcp.checkResult(
            listing,
            "{\"ttlMs\":1000,\"cacheScope\":\"private\",\"tools\":[]}",
            &scratch,
        ),
    );
    try testing.expectError(
        error.NotAResult,
        mcp.checkResult(listing, "{\"resultType\":\"complete\",\"tools\":[]}", &scratch),
    );
    try testing.expectError(
        error.NotAResult,
        mcp.checkResult(listing, "{\"tools\":[],\"ttlMs\":1000}", &scratch),
    );
    try testing.expectError(
        error.NotAResult,
        mcp.checkResult(listing, "{\"tools\":[],\"cacheScope\":\"private\"}", &scratch),
    );
    // A body that is not an object never was a result, whatever it carries,
    // and neither was one whose `resultType` is not a string.
    try testing.expectError(error.NotAResult, mcp.checkResult(listing, "[1,2]", &scratch));
    try testing.expectError(
        error.NotAResult,
        mcp.checkResult(
            listing,
            "{\"resultType\":5,\"ttlMs\":1,\"cacheScope\":\"public\"}",
            &scratch,
        ),
    );

    // A method whose result carries no caching hints is not read for the two:
    // that rule does not apply to it, and reading it would refuse a result the
    // specification allows. `resultType` is required either way, because 4.6
    // makes it a property of results rather than of the method. The read side
    // is where an absent one is tolerated, and `mcp.classifyResult` is that
    // — a peer on an earlier revision omits it and the client treats it as
    // `complete`, while a body this server built may not leave it out.
    const call = try server.gate("tools/call");
    try testing.expect(!call.cacheable);
    try mcp.checkResult(call, "{\"resultType\":\"complete\",\"content\":[]}", &scratch);
    try mcp.checkResult(call, "{\"resultType\":\"complete\"}", &scratch);
    try testing.expectError(
        error.NotAResult,
        mcp.checkResult(call, "{\"content\":[]}", &scratch),
    );
}

test "an interim result is written only for a method PROTOCOLS.md 4.7 allows" {
    var scratch: [256]u8 = undefined;
    var out: [512]u8 = undefined;
    const requests = "{\"e1\":{\"method\":\"elicitation/create\"}}";

    // `tools/list` is not one of the three, so the refusal lands before any
    // body is written.
    try testing.expectError(
        error.InputRequiredUnexpected,
        mcp.inputRequired("tools/list", requests, "st", &out),
    );

    const body = try mcp.inputRequired("tools/call", requests, "st", &out);
    try testing.expectEqualStrings(
        "{\"resultType\":\"input_required\"," ++
            "\"inputRequests\":{\"e1\":{\"method\":\"elicitation/create\"}}," ++
            "\"requestState\":\"st\"}",
        body,
    );
    // The body the server writes is the one the client half reads, so the two
    // halves agree on what an interim result is.
    const decoded = try mcp.decodeInputRequiredResult(body, &scratch);
    try testing.expectEqualStrings(requests, decoded.input_requests.?);
    try testing.expectEqualStrings("st", decoded.request_state.?);
    try testing.expectEqual(mcp.KnownResultType.input_required, decoded.result_type.known().?);

    var tiny: [8]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        mcp.inputRequired("prompts/get", requests, "st", &tiny),
    );

    // A state carrying a quote and a backslash round-trips to the same
    // characters. Spliced as written it would have ended the member at the
    // first quote, and the peer would have read a shorter state than the one
    // the server meant to send.
    const awkward_state = "a\"b\\c";
    var escaped: [512]u8 = undefined;
    const read_back = try mcp.decodeInputRequiredResult(
        try mcp.inputRequired("resources/read", requests, awkward_state, &escaped),
        &scratch,
    );
    try testing.expectEqualStrings(awkward_state, read_back.request_state.?);

    // A state too long for `out` is reported rather than cut short. A caller
    // that grew its buffer and called again gets the whole body; one sent on
    // the truncated prefix would hand the peer a state the server never chose,
    // and the retry that comes back would key off it.
    const long_state = "x" ** 200;
    var short_out: [120]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        mcp.inputRequired("prompts/get", requests, long_state, &short_out),
    );
}

test "the discover body carries every member 4.4 and 4.6 name, in that order" {
    var out: [512]u8 = undefined;
    var server: Server = .{ .connection = undefined, .revision = .current };
    server.supported_versions =
        &[_][]const u8{ mcp.latest_protocol_version, mcp.previous_protocol_version };
    server.capabilities = "{\"tools\":{}}";
    server.cache_ttl_ms = 1000;
    server.cache_scope = .private;

    try testing.expectEqualStrings(
        "{\"resultType\":\"complete\",\"ttlMs\":1000,\"cacheScope\":\"private\"," ++
            "\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\"]," ++
            "\"capabilities\":{\"tools\":{}},\"instructions\":\"be careful\"}",
        try server.discoverBody("be careful", &out),
    );

    // The body this layer writes is one its own sibling accepts. 4.4 is what
    // marks `server/discover` cacheable and 4.6 is what puts the two fields on
    // a cacheable result, so this is where the two rules meet.
    var scratch: [256]u8 = undefined;
    const info = try server.gate("server/discover");
    try testing.expect(info.cacheable);
    try mcp.checkResult(info, try server.discoverBody("be careful", &out), &scratch);

    // The body is an object a reader walks, and `instructions` is the string
    // the caller passed rather than its own escaping of something else.
    var reader = json.Reader.init(try server.discoverBody("be careful", &out));
    const empty = try reader.beginObject();
    try testing.expect(!empty);
    var read_instructions = false;
    while (try reader.nextKey(&scratch)) |key| {
        if (!std.mem.eql(u8, key, "instructions")) {
            try reader.skipValue(&scratch);
            continue;
        }
        read_instructions = true;
        try testing.expectEqualStrings("be careful", try reader.string(&scratch));
    }
    try testing.expect(read_instructions);
}

test "a discover body omits instructions and writes null for no capabilities" {
    var out: [512]u8 = undefined;
    var server: Server = .{ .connection = undefined, .revision = .current };
    server.supported_versions = &[_][]const u8{mcp.latest_protocol_version};
    server.cache_ttl_ms = 0;
    server.cache_scope = .public;

    // 4.4 marks `instructions` optional and the other two members not, so a
    // server with nothing to say leaves the member out rather than writing an
    // empty string a peer would read as advice. A `ttlMs` of zero is written
    // rather than dropped, because 4.6 requires the member on a cacheable
    // result and zero is what "immediately stale" means.
    try testing.expectEqualStrings(
        "{\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"public\"," ++
            "\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":null}",
        try server.discoverBody(null, &out),
    );

    var tiny: [16]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, server.discoverBody(null, &tiny));
}

test "a server with no caching values cannot write a discover body at all" {
    // 4.6 makes both fields required on a cacheable result, so a body without
    // them is not a result this revision defines. Refusing here means the
    // caller never holds a body its own sibling would reject.
    var out: [512]u8 = undefined;
    var server: Server = .{ .connection = undefined, .revision = .current };
    server.supported_versions = &[_][]const u8{mcp.latest_protocol_version};
    server.capabilities = "{\"tools\":{}}";

    try testing.expectError(error.NotAResult, server.discoverBody(null, &out));
    server.cache_ttl_ms = 500;
    try testing.expectError(error.NotAResult, server.discoverBody(null, &out));
    server.cache_scope = .public;
    server.cache_ttl_ms = null;
    try testing.expectError(error.NotAResult, server.discoverBody(null, &out));
}

// --- The loopback exchange ----------------------------------------------------

/// The buffers one side needs. Caller-owned, so the test cannot hide an
/// allocation behind the session.
const Side = struct {
    frame_buffer: [8192]u8 = undefined,
    pending: [4]conn.Slot = undefined,
    /// Where a frame is decoded, and the region a handler decodes one into. An
    /// array of its own rather than a slice of the one below, because the two
    /// must not share a byte.
    decode_scratch: [1024]u8 = undefined,
    /// Where a handler writes its answer. Not an offset into the region above:
    /// a handler that decoded into what it writes has the envelope it is
    /// building land on the value it is about to read.
    answer: [8192]u8 = undefined,
    out: [2048]u8 = undefined,
    result: [4096]u8 = undefined,
    params: [2048]u8 = undefined,
};

/// One end of the socket, with the connection that borrows its reader and its
/// writer.
const Endpoint = struct {
    side: Side = .{},
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    /// Held here rather than as locals: the connection keeps raw pointers to
    /// both interfaces, and a local would dangle before the first read.
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    stream: Io.net.Stream = undefined,
    connection: conn.Conn = undefined,

    /// Hand the endpoint its connection, or the reason it cannot have one.
    ///
    /// A region with no room and a pair that share a byte are wiring faults,
    /// and the peer never shows them: the connection runs and the answers it
    /// writes are wrong. `conn.Conn.init` refuses both before it touches the
    /// slot table, so a refused endpoint leaves `side` as it was handed over.
    fn open(
        self: *Endpoint,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) conn.Error!void {
        self.stream = stream;
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = try conn.Conn.init(io, &self.reader.interface, &self.writer.interface, .{
            .frame_buffer = &self.side.frame_buffer,
            .pending = &self.side.pending,
            .decode_scratch = &self.side.decode_scratch,
            .answer = &self.side.answer,
        });
        if (handler) |h| self.connection.setHandler(h);
        // Spawned on the group the test joins, because `Io.Group.async` does not
        // promise to run its task until the group is awaited or cancelled.
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

/// A listening Unix socket, with the address that reaches it.
///
/// A Unix socket rather than a TCP port: there is no race over which port the
/// kernel handed out, so the test is deterministic under parallel runs, and
/// there is no port to leak when the process dies.
///
/// `Io.net.UnixAddress` borrows its path, so the path buffer belongs to the
/// caller and must outlive both halves. A path built in a helper's own frame
/// would be dead the moment the helper returned, and `connect` would then be
/// asking for a socket whose name no longer exists.
const Socket = struct {
    address: Io.net.UnixAddress,
    server: Io.net.Server,
    path: []const u8,
};

fn listenOn(io: Io, path_buffer: []u8, tag: u64) !Socket {
    const path = try std.fmt.bufPrint(
        path_buffer,
        "/tmp/zig-agent-proto-mcp-session-{x}.sock",
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

/// What a multi-round-trip retry carries: the `inputResponses` keyed by the ids
/// the server assigned, and the `requestState` it sent. PROTOCOLS.md 4.7.
const answers = "{\"inputResponses\":{},\"requestState\":\"st\"}";

/// An interim result as a peer sends it. The same answer serves a method that
/// may return one and a method that may not, so a refusal to it is about the
/// method and not about the value. The body rather than the envelope, because
/// the answer is built by the shared builder, which writes the members round
/// it.
const interim_result =
    "{\"resultType\":\"input_required\",\"inputRequests\":{}," ++
    "\"requestState\":\"st\"}";

/// The final answer to the same `tools/call` exchange.
const final_result =
    "{\"resultType\":\"complete\"," ++
    "\"content\":[{\"type\":\"text\",\"text\":\"echoed\"}]}";

/// What both sides report back to the test once the group has finished.
const Exchange = struct {
    /// Set when a call failed in a way the script does not call for.
    failed: bool = false,

    // What the peer was asked, so the round trips are checkable.
    read_calls: usize = 0,
    list_calls: usize = 0,
    prompt_calls: usize = 0,
    tool_calls: usize = 0,
    resource_list_calls: usize = 0,
    /// The ids the peer saw on its `tools/call` requests. PROTOCOLS.md 4.7:
    /// each round trip of a multi-round-trip exchange is a new call. Five
    /// slots for two exchanges of three round trips and two of two.
    ids: [5]i64 = .{ 0, 0, 0, 0, 0 },
    /// Whether the peer's first `tools/call` carried the capabilities in
    /// `_meta`, and whether the caller's own members survived beside them.
    meta_on_wire: bool = false,
    members_kept: bool = false,

    /// How many notifications the peer saw. A notification carries no id, so
    /// nothing answers it and no return value reaches the client: the peer's
    /// own count is the only evidence the frame left at all.
    notified: usize = 0,
    /// The method and params it read off that notification, copied because the
    /// next frame is decoded over the region they were read into.
    notified_method: [64]u8 = undefined,
    notified_method_len: usize = 0,
    notified_params: [128]u8 = undefined,
    notified_params_len: usize = 0,

    /// The name the peer unescaped into the region it decodes into, copied
    /// because the next frame is decoded over it long before the test reads it.
    prompt_name: [32]u8 = undefined,
    prompt_name_len: usize = 0,

    // What the client read back. Each body is a copy, because it borrows the
    // client's `result` buffer and the next call overwrites that.
    read_failed: bool = false,
    read_code: ?i32 = null,
    read_body: [256]u8 = undefined,
    read_body_len: usize = 0,
    answered_failed: bool = false,
    answered_code: ?i32 = null,
    list_refused: bool = false,
    prompt_refused: bool = false,
    resource_list_refused: bool = false,
    retry_refused: bool = false,
    /// A retry that came back with a `resultType` the revision does not
    /// define, which is the value's fault on this leg as on the first.
    retry_value_refused: bool = false,
    final_failed: bool = false,
    final_body: [256]u8 = undefined,
    final_body_len: usize = 0,
};

/// Copy a borrowed value out of a buffer the next call overwrites: the
/// client's result buffer, or the region the peer decoded a name into. A value
/// longer than the slot is dropped rather than truncated, so the assertion
/// fails instead of comparing half of it.
fn keepBody(slot: []u8, length: *usize, body: []const u8) void {
    if (body.len > slot.len) return;
    @memcpy(slot[0..body.len], body);
    length.* = body.len;
}

/// The peer's script: five methods, four different answers.
///
/// Runs inline on the reader task, so it encodes into the buffer the
/// connection lends and never calls back on the same connection.
fn scriptedHandler(
    ctx: ?*anyopaque,
    frame: []const u8,
    decode_scratch: []u8,
    answer: []u8,
) conn.Error!?[]const u8 {
    const exchange: *Exchange = @ptrCast(@alignCast(ctx.?));
    // The request shape, so the answer carries the id the peer chose and the
    // envelope is the shared builder's. A notification and a response are not
    // requests, so neither of them reaches a builder here.
    //
    // Decoded into `decode_scratch` and answered into `answer`, because the
    // escape offset `json.Reader` keeps is per reader and not per buffer. A
    // handler that decoded into the region it writes its answer into has the
    // envelope's first bytes land on the value it is about to read, and the
    // answer that comes back is wrong rather than missing. Both regions are the
    // connection's, neither is a local, and the answer stays readable for the
    // write the connection does next.
    const request = jsonrpc.decodeRequest(frame, decode_scratch) catch {
        // A notification is not a `Request`: JSON-RPC gives it a method and no
        // id, and the id is what that projection keeps. Looked for here, after
        // the refusal rather than before it, so the request path decodes
        // exactly as it did. It has to be looked for at all, because a
        // notification is the one frame of this exchange nothing answers and
        // the count below is the only record of it.
        const message = jsonrpc.decode(frame, decode_scratch) catch return null;
        if (message.kind != .notification) return null;
        const sent_method = message.method orelse return null;
        const params = switch (message.params) {
            .value => |text| text,
            else => "",
        };
        exchange.notified += 1;
        keepBody(&exchange.notified_method, &exchange.notified_method_len, sent_method.text);
        keepBody(&exchange.notified_params, &exchange.notified_params_len, params);
        return null;
    };
    const method = request.method;

    if (std.mem.eql(u8, method.text, "resources/read")) {
        // A failure at the JSON-RPC level, so what the client reads back is the
        // error object and not a result. It is a different builder from the
        // one every branch below uses, so it cannot land inside a `result`.
        exchange.read_calls += 1;
        return conn.errorResponse(request, .{
            .code = @intFromEnum(jsonrpc.StandardError.invalid_params),
            .message = "unknown resource",
        }, answer) catch null;
    } else if (std.mem.eql(u8, method.text, "tools/list")) {
        // A `resultType` outside the two the specification defines. A method
        // 4.7 does not let answer that way either, so this case is about the
        // value, and `resources/list` below is about the method.
        exchange.list_calls += 1;
        return conn.respond(request, "{\"resultType\":\"weird\"}", answer) catch null;
    } else if (std.mem.eql(u8, method.text, "prompts/get")) {
        // An interim result the client supplies no answer to.
        exchange.prompt_calls += 1;
        // The one read in this script that lands in `decode_scratch` rather
        // than in the frame: the client sent the name with a JSON escape, and
        // only an unescape puts bytes in the region the two-region contract is
        // about. A read that borrowed the frame would prove nothing.
        const name = readName(request.params, decode_scratch);
        const written = conn.respond(request, interim_result, answer) catch null;
        // Read after the write. The answer went into `answer` and this reads
        // what is left in `decode_scratch`, which is the whole point: handed
        // one region for both, the envelope would be sitting on the name here.
        keepBody(&exchange.prompt_name, &exchange.prompt_name_len, name);
        return written;
    } else if (std.mem.eql(u8, method.text, "resources/list")) {
        // An interim result, well formed, on a method PROTOCOLS.md 4.7 does
        // not let answer that way. The value is one this library knows, so the
        // only thing left to refuse it on is the method.
        exchange.resource_list_calls += 1;
        return conn.respond(request, interim_result, answer) catch null;
    } else if (std.mem.eql(u8, method.text, "tools/call")) {
        // Five answers across two exchanges, and which one a call gets is the
        // fault the call is there to provoke: a caller that stops after one
        // round trip is caught handing back an interim result, and a retry that
        // comes back with a value the revision does not define is caught
        // reporting it as a second interim result.
        exchange.tool_calls += 1;
        if (exchange.tool_calls <= exchange.ids.len) {
            // A `Request` admits a string id as well as an integer one, and this
            // script only ever sees the integers this library mints, so the arm
            // is answered rather than unwrapped.
            exchange.ids[exchange.tool_calls - 1] = switch (request.id) {
                .integer => |value| value,
                .string => 0,
            };
        }
        if (exchange.tool_calls == 1) {
            // Read here, where the frame is still live: `params` borrows the
            // peer's framer buffer, which the next frame overwrites.
            const params = switch (request.params) {
                .value => |value| value,
                else => "",
            };
            exchange.meta_on_wire = std.mem.startsWith(u8, params, "{\"_meta\":{\"") and
                std.mem.indexOf(u8, params, mcp.meta_key.client_capabilities) != null;
            exchange.members_kept = std.mem.indexOf(u8, params, "\"name\":\"echo\"") != null;
        }
        return conn.respond(request, switch (exchange.tool_calls) {
            1, 2, 4 => interim_result,
            3 => final_result,
            // The answer to the retry of the second exchange.
            else => "{\"resultType\":\"weird\"}",
        }, answer) catch null;
    }
    return null;
}

/// The `name` member of a `prompts/get` request, unescaped into `scratch`.
///
/// A walk of its own rather than [`json.memberText`], because that one hands a
/// member's raw text back and unescapes nothing: the name would stay in the
/// frame and the two regions would have nothing to say about each other.
///
/// A params that is not an object, or one this cannot walk, reports no name
/// rather than a fault. The script answers such a request all the same, and a
/// peer that sent one has not broken the exchange.
fn readName(params: jsonrpc.Params, scratch: []u8) []const u8 {
    return readNameIn(params, scratch) catch "";
}

fn readNameIn(params: jsonrpc.Params, scratch: []u8) root.DecodeError![]const u8 {
    const raw = switch (params) {
        .value => |value| value,
        else => return "",
    };
    var reader = json.Reader.init(raw);
    _ = try reader.beginObject();
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "name")) return reader.string(scratch);
        try reader.skipValue(scratch);
    }
    return "";
}

/// Accepts one connection and lets its reader answer the client.
const Serving = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    exchange: *Exchange,

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch {
            self.exchange.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = self.exchange,
            .call = scriptedHandler,
        }) catch {
            // Hung up rather than left open, because a peer that never comes
            // up leaves the client waiting on an answer for ever and the group
            // the test awaits never finishes.
            self.exchange.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
    }
};

/// Drives the script from the client's side and records what each call decided.
const Calling = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    exchange: *Exchange,

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch {
            self.exchange.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null) catch {
            self.exchange.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };

        const side = &self.endpoint.side;
        // A session pinned to the current revision. There is no handshake here,
        // so the capabilities ride on each request in `_meta`, which is what
        // the peer checks on the wire.
        var session = Client.init(&self.endpoint.connection, .current);
        session.capabilities = "{\"tools\":{}}";

        // A notification, and the one frame of this exchange that nothing
        // answers. It goes out before the first call because the peer reads
        // frames in the order they were written and dispatches each on its
        // reader task, so the answer to the `resources/read` below is written
        // only after this has been counted. The count is read long after that
        // answer, which is what makes it true here without a sleep.
        session.notify("notifications/cancelled", "{\"requestId\":0}", &side.out) catch {
            self.exchange.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };

        // A peer error, read once. The code beside the body is the only thing
        // that tells the caller this call failed.
        const read = session.request(
            "resources/read",
            "{\"uri\":\"file:///nope\"}",
            &side.result,
            &side.out,
            &side.params,
        ) catch {
            self.exchange.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
        self.exchange.read_failed = read.failed();
        self.exchange.read_code = read.error_code;
        keepBody(&self.exchange.read_body, &self.exchange.read_body_len, read.body);

        // The same peer error through the multi-round-trip driver. It ends the
        // exchange there, so the peer is asked twice in all across the two
        // calls and never once for a retry.
        const answered = session.respond(
            "resources/read",
            "{\"uri\":\"file:///nope\"}",
            &side.result,
            &side.out,
            &side.params,
            answers,
        ) catch {
            self.exchange.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
        self.exchange.answered_failed = answered.failed();
        self.exchange.answered_code = answered.error_code;

        // A `resultType` the specification does not define, refused rather than
        // guessed at. `tools/list` is not a method that may answer that way
        // either, so this case is about the value; the `resources/list` call
        // below is the case about the method.
        if (session.respond(
            "tools/list",
            null,
            &side.result,
            &side.out,
            &side.params,
            answers,
        )) |_| {
            self.exchange.failed = true;
        } else |err| {
            self.exchange.list_refused = err == error.UnknownResultType;
        }

        // An interim result with no answer to give ends the exchange here. The
        // name carries a JSON escape, so the peer has to unescape it into the
        // region it decodes into rather than borrow it from the frame, and the
        // copy of it the test checks below is what says the two regions stayed
        // apart.
        if (session.respond(
            "prompts/get",
            "{\"name\":\"a\\tb\"}",
            &side.result,
            &side.out,
            &side.params,
            null,
        )) |_| {
            self.exchange.failed = true;
        } else |err| {
            self.exchange.prompt_refused = err == error.InputRequiredUnexpected;
        }

        // A well-formed interim result on a method PROTOCOLS.md 4.7 does not
        // let answer that way, refused with an answer in hand. The value is one
        // this library knows, so the method is the only thing left to refuse
        // it on, and a refusal here is not a round trip spent.
        if (session.respond(
            "resources/list",
            null,
            &side.result,
            &side.out,
            &side.params,
            answers,
        )) |_| {
            self.exchange.failed = true;
        } else |err| {
            self.exchange.resource_list_refused = err == error.InputRequiredUnexpected;
        }

        // A retry that is still interim is a refusal and not a final answer.
        if (session.respond(
            "tools/call",
            "{\"name\":\"echo\"}",
            &side.result,
            &side.out,
            &side.params,
            answers,
        )) |_| {
            self.exchange.failed = true;
        } else |err| {
            self.exchange.retry_refused = err == error.InputRequiredUnexpected;
        }

        // The next round trip is the one that completes the exchange.
        const finished = session.respond(
            "tools/call",
            "{\"name\":\"echo\"}",
            &side.result,
            &side.out,
            &side.params,
            answers,
        ) catch {
            self.exchange.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
        self.exchange.final_failed = finished.failed();
        keepBody(&self.exchange.final_body, &self.exchange.final_body_len, finished.body);

        // A second exchange, whose retry comes back with a `resultType` outside
        // the two the specification defines. The value is the answer's fault
        // whichever leg it arrived on, so it is reported as the value and not
        // as a second interim result the caller has to answer.
        if (session.respond(
            "tools/call",
            "{\"name\":\"echo\"}",
            &side.result,
            &side.out,
            &side.params,
            answers,
        )) |_| {
            self.exchange.failed = true;
        } else |err| {
            self.exchange.retry_value_refused = err == error.UnknownResultType;
        }

        self.endpoint.hangUp(self.io);
    }
};

test "a peer error is a failure and an interim result is never the final one" {
    // The unit tests above decide what a session would do with bytes it never
    // sent. Only a real socket shows the case this file has to get right: a
    // peer's error arrives as a response whose `body` is the error object, and
    // nothing but the code beside it says the call failed.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    var address = try listenOn(io, &path_buffer, 0x5eed_0301);
    defer address.server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, address.path) catch {};

    var exchange: Exchange = .{};
    var peer_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};

    // One group drives both sides. Two would deadlock: the client blocks on an
    // answer only the peer's task can produce.
    var group: Io.Group = .init;
    var serving = Serving{
        .io = io,
        .group = &group,
        .server = &address.server,
        .endpoint = &peer_endpoint,
        .exchange = &exchange,
    };
    var calling = Calling{
        .io = io,
        .group = &group,
        .address = &address.address,
        .endpoint = &client_endpoint,
        .exchange = &exchange,
    };
    group.async(io, Serving.run, .{&serving});
    group.async(io, Calling.run, .{&calling});
    group.await(io) catch {};

    try testing.expect(!exchange.failed);

    // The peer's error is a failure, and what came back is its code and its
    // message rather than a result with nothing in it.
    try testing.expect(exchange.read_failed);
    try testing.expectEqual(@as(?i32, -32602), exchange.read_code);
    try testing.expectEqualStrings(
        "{\"code\":-32602,\"message\":\"unknown resource\"}",
        exchange.read_body[0..exchange.read_body_len],
    );

    // The driver hands that failure back instead of answering it: two calls
    // reached the peer and neither of them cost a retry.
    try testing.expect(exchange.answered_failed);
    try testing.expectEqual(@as(?i32, -32602), exchange.answered_code);
    try testing.expectEqual(@as(usize, 2), exchange.read_calls);

    // Five refusals, five reasons, one case each.
    //
    // The value: a `resultType` outside the two the specification defines.
    try testing.expect(exchange.list_refused);
    try testing.expectEqual(@as(usize, 1), exchange.list_calls);

    // The caller: a real interim result and no answer to give.
    try testing.expect(exchange.prompt_refused);
    try testing.expectEqual(@as(usize, 1), exchange.prompt_calls);

    // The method: a well-formed interim result on a request PROTOCOLS.md 4.7
    // does not let answer that way. The peer was asked once and not again, so
    // the refusal cost no round trip.
    try testing.expect(exchange.resource_list_refused);
    try testing.expectEqual(@as(usize, 1), exchange.resource_list_calls);

    // One retry was not enough, so it was refused rather than handed back as
    // the final result, and that exchange finished on the third round trip.
    try testing.expect(exchange.retry_refused);
    try testing.expect(!exchange.final_failed);
    try testing.expectEqualStrings(
        "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"echoed\"}]}",
        exchange.final_body[0..exchange.final_body_len],
    );

    // A retry answered with a value the revision does not define, on the leg
    // where a second interim result is what the caller is otherwise told. The
    // value is the answer's fault, so it is reported as the value and the
    // exchange stops there: the peer was asked five times in all and not once
    // more than a round trip costs.
    try testing.expect(exchange.retry_value_refused);
    try testing.expectEqual(@as(usize, 5), exchange.tool_calls);

    // Every round trip was a new call, as PROTOCOLS.md 4.7 requires, across
    // both exchanges.
    try testing.expect(exchange.ids[0] != exchange.ids[1]);
    try testing.expect(exchange.ids[1] != exchange.ids[2]);
    try testing.expect(exchange.ids[0] < exchange.ids[2]);
    try testing.expect(exchange.ids[2] != exchange.ids[3]);
    try testing.expect(exchange.ids[3] != exchange.ids[4]);
    try testing.expect(exchange.ids[2] < exchange.ids[4]);

    // The capabilities rode on the request in `_meta`, with the caller's own
    // members beside them.
    try testing.expect(exchange.meta_on_wire);
    try testing.expect(exchange.members_kept);

    // The notification reached the peer as a message with no id, which is the
    // whole of what makes one a notification: the handler saw it through
    // `jsonrpc.decode`'s own classification, had no id to answer on, and
    // returned nothing. Its params are the caller's own bytes, spliced the way
    // `Client.request` splices a params it has no `_meta` to add to.
    try testing.expectEqual(@as(usize, 1), exchange.notified);
    try testing.expectEqualStrings(
        "notifications/cancelled",
        exchange.notified_method[0..exchange.notified_method_len],
    );
    try testing.expectEqualStrings(
        "{\"requestId\":0}",
        exchange.notified_params[0..exchange.notified_params_len],
    );

    // The peer read a name back out of the region it decodes into, after it
    // had written its answer into the other one. Handed a single region, the
    // envelope it wrote would have been sitting on the name, and this is the
    // name the client sent.
    try testing.expectEqualStrings("a\tb", exchange.prompt_name[0..exchange.prompt_name_len]);
}

test "the two regions a handler is handed cannot share a byte" {
    // The fault the pair of names exists for. A handler given one region for
    // both still runs and still answers, and the answer is wrong rather than
    // absent, so the connection refuses the pair where the caller can see it.
    var frame_buffer: [64]u8 = undefined;
    var pending: [2]conn.Slot = undefined;
    var shared: [64]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&.{});

    try testing.expectError(error.OverlappingBuffers, conn.Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = shared[0..32],
        .answer = shared[16..],
    }));

    // The other half of the same contract, and the failure `Endpoint.open`
    // above hands back for a side that was sized wrong: a region with no room
    // refuses the first thing that needs it, which is too late to be useful.
    try testing.expectError(error.UnusableBuffer, conn.Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = shared[0..32],
        .answer = shared[0..0],
    }));
}
