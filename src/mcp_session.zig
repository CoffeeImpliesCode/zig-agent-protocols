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
//! - At the current revision every request carries the client capabilities in
//!   `_meta`, because there is no `initialize` to carry them in.
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
//! server checks, so [`Server.checkResult`] refuses a cacheable result that
//! leaves out a field PROTOCOLS.md 4.6 requires, and
//! [`Server.inputRequired`] refuses an interim result on a method 4.7 does not
//! let answer with one.
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
const Io = std.Io;

pub const Error = error{
    /// The method is not part of the pinned revision, so it was not sent.
    ///
    /// Reported before the wire rather than as a peer's `-32601`, because the
    /// caller can fix it without a round trip and a peer on another revision
    /// may well still accept it.
    MethodNotInRevision,
    /// The `params` a caller passed are not a JSON object, so `_meta` cannot
    /// be added to them.
    ///
    /// Distinct from `BufferTooSmall`: the object is what cannot be wrapped,
    /// not the buffer, so a caller that doubles the buffer and tries again
    /// gets this again.
    NotAnObject,
    /// A body is not a result this layer can pass on.
    ///
    /// A peer's body that does not decode as one, or one this revision does
    /// not define for the method that must carry it. PROTOCOLS.md 4.6 makes
    /// three members required on the results it covers, so a body missing one
    /// is refused whichever side wrote it.
    NotAResult,
    /// An interim result arrived where none could be answered: the method is
    /// one PROTOCOLS.md 4.7 does not let return one, or the caller supplied
    /// no answer to the one it did.
    InputRequiredUnexpected,
    /// The result carried a `resultType` this library does not define.
    UnknownResultType,
    /// A caller-supplied buffer was too small.
    BufferTooSmall,
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
    /// that, leaving the caller's buffer untouched. A `params` that is not an
    /// object is `error.NotAnObject` rather than `error.BufferTooSmall`, so a
    /// caller sizing a buffer is not sent looking for one.
    pub fn request(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
        params_out: []u8,
    ) Error!conn.Response {
        // Checked before the wire, so a removed method is refused locally.
        _ = mcp.lookupMethod(self.revision, method) catch return error.MethodNotInRevision;

        const payload = if (self.capabilities) |caps| blk: {
            // At the previous revision the capabilities travel in `initialize`,
            // so wrapping every request would be sending something the peer
            // never asked for.
            if (self.revision != .current) break :blk params;
            if (params) |text| {
                break :blk injectMeta(text, caps, params_out) catch |err| switch (err) {
                    // The object is what cannot be wrapped, not the buffer it
                    // was offered in, so the two are reported apart.
                    error.InvalidField => return error.NotAnObject,
                    else => return error.BufferTooSmall,
                };
            } else {
                break :blk emptyParamsWithMeta(caps, params_out) catch
                    return error.BufferTooSmall;
            }
        } else params;

        const answer = try self.connection.call(method, payload, result, out);
        // Carried whole, so the code beside the body is what tells the caller a
        // peer error from a result.
        return answer;
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
    /// it, and [`Client.classify`] then reads the answer with it as its
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

        const kind = try Client.classify(first.body, params_out);
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
        const retried = try Client.classify(retry.body, params_out);
        if (retried.isComplete()) return retry;
        return error.InputRequiredUnexpected;
    }
};

/// A server bound to one revision.
///
/// The mirror of [`Client`]. Both halves hold the same pin and reach
/// [`mcp.lookupMethod`] through [`Server.gate`], so a name the client refuses
/// to send is a name the server refuses to answer, and the two sides agree on
/// what exists without exchanging a version to find out.
pub const Server = struct {
    /// The connection this server answers on.
    ///
    /// Nothing below reads or writes through it. Every builder here returns
    /// text the caller hands to that connection's handler, because the handler
    /// holds the frame and the scratch. The field is here so a server is one
    /// value with its connection, the way [`Client`] is.
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

    /// The pinned revision's entry for `method`, or `error.MethodNotInRevision`.
    ///
    /// A handler calls this before it reads `params`, so a name this revision
    /// removed costs the peer the `-32601` of [`Server.methodNotFound`] rather
    /// than whatever the handler would have guessed at for it.
    pub fn gate(self: Server, method: []const u8) Error!mcp.MethodInfo {
        return mcp.lookupMethod(self.revision, method) catch |err| switch (err) {
            error.UnknownMethod => error.MethodNotInRevision,
            // `lookupMethod` walks comptime tables and compares names, so it
            // reads no caller buffer and no other member of `DecodeError` can
            // reach here. Reporting the refusal rather than unwrapping keeps a
            // path that cannot happen from becoming a panic.
            else => error.MethodNotInRevision,
        };
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

    /// Refuse a result that breaks the rule `info` carries, and accept the rest.
    ///
    /// PROTOCOLS.md 4.6 makes `ttlMs` and `cacheScope` required on a result
    /// the method table marks cacheable, so a handler calls this on the body
    /// it built and learns from a return value whether the body may be sent,
    /// rather than from a review of whether it remembered the two fields.
    ///
    /// No session, because the rule does not depend on one. PROTOCOLS.md 4.6
    /// binds the two caching fields to the method, and [`mcp.lookupMethod`]
    /// returns the same entry at both revisions for every method it resolves,
    /// so re-deriving `info` from a session could not change one outcome. A
    /// caller already holding `info` from [`Server.gate`] passes it on
    /// unchanged.
    pub fn checkResult(info: mcp.MethodInfo, result: []const u8, scratch: []u8) Error!void {
        if (!info.cacheable) return;
        // `mcp.decodeCacheable` is the one implementation of the rule, and
        // this is where it becomes reachable.
        _ = mcp.decodeCacheable(result, scratch) catch |err| switch (err) {
            error.BufferTooSmall => return error.BufferTooSmall,
            // Both fields are required, so an absent one and a value of the
            // wrong type are one fault to a server: the body it built is not a
            // result this method may answer with.
            else => return error.NotAResult,
        };
    }

    /// Write the interim result body for `method`, or refuse the method.
    ///
    /// PROTOCOLS.md 4.7 lets `tools/call`, `resources/read` and `prompts/get`
    /// answer with an interim result, and [`mcp.permitsMrtr`] is that list. A
    /// server that wants one on any other method is refused here rather than
    /// on the wire, because a peer has to treat such a result as invalid.
    ///
    /// What comes back is the body and not the frame. The caller wraps it with
    /// [`conn.respond`], so the id the answer echoes is the one the
    /// connection decoded rather than one written here.
    ///
    /// `requests` is spliced as written, because it is a JSON object the
    /// caller built and keyed by the server-assigned ids. `request_state` is
    /// a string and not an object, so it is written as a JSON string literal
    /// with the escapes JSON requires, and what the peer reads back decodes
    /// to the characters that were passed in. Splicing it would have ended
    /// the member at the first quote in it and handed the peer a different
    /// state. It is opaque and attacker controlled besides, and PROTOCOLS.md
    /// 4.7 requires a server to integrity-protect it wherever it influences
    /// authorization.
    ///
    /// No session, because [`mcp.permitsMrtr`] reads a name and no revision:
    /// the 4.7 list is the same at both revisions, so a session would have
    /// nothing to add to the decision.
    pub fn inputRequired(
        method: []const u8,
        requests: []const u8,
        request_state: []const u8,
        out: []u8,
    ) Error![]const u8 {
        if (!mcp.permitsMrtr(method)) return error.InputRequiredUnexpected;
        var writer = json.Writer.init(out);
        // `resultType` first, because PROTOCOLS.md 4.6 puts it on every
        // result, then the two members 4.7 names beside it in the order the
        // table lists them. Every write below can fail for want of room and
        // for no other reason: the writer escapes a string rather than
        // refusing one.
        writer.slice("{\"resultType\":\"" ++ mcp.result_type_value.input_required ++
            "\",\"inputRequests\":") catch return error.BufferTooSmall;
        writer.slice(requests) catch return error.BufferTooSmall;
        writer.slice(",\"requestState\":") catch return error.BufferTooSmall;
        writer.string(request_state) catch return error.BufferTooSmall;
        writer.byte('}') catch return error.BufferTooSmall;
        return writer.written();
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
    /// [`Server.checkResult`] would refuse. A caller holding a body will send
    /// it, and a body refused on arrival has already travelled; refusing here
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

/// Add `_meta` to a params object, keeping the caller's members.
fn injectMeta(
    params: []const u8,
    caps: []const u8,
    out: []u8,
) root.EncodeError![]const u8 {
    // Trimmed before the braces are read. A caller that built its object out of
    // a frame or a file brings the padding with it, and the sibling layer in
    // `acp_session.zig` accepts the padded form, so the same bytes must not be
    // refused here. A value that is not an object is `InvalidField` rather than
    // `BufferTooSmall`, because the caller's object is what cannot be wrapped,
    // not the size of the buffer it offered.
    const trimmed = std.mem.trim(u8, params, " \t\r\n");
    if (trimmed.len < 2) return error.InvalidField;
    if (trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.InvalidField;
    // The wrapper goes in front of the caller's own members. Parsing and
    // re-emitting the object would need a decode the caller has already done,
    // and splicing keeps the caller's bytes exactly as written. Trimmed again
    // inside, so an object holding only whitespace gains no trailing comma.
    const body = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");

    var writer = json.Writer.init(out);
    try writer.slice("{\"_meta\":{\"");
    try writer.slice(mcp.meta_key.client_capabilities);
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
    try writer.slice(mcp.meta_key.client_capabilities);
    try writer.slice("\":");
    try writer.slice(caps);
    try writer.slice("}}");
    return writer.written();
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
    try testing.expectError(error.InvalidField, injectMeta("[1,2]", "{}", &out));
    try testing.expectError(error.InvalidField, injectMeta("nope", "{}", &out));
    try testing.expectError(error.InvalidField, injectMeta("", "{}", &out));
}

test "params padded with whitespace wrap, as the sibling layer allows" {
    // `acp_session.requireObject` trims before it looks for a brace, so an
    // object it accepts must not be refused here for the whitespace around it.
    var out: [256]u8 = undefined;
    const params = try injectMeta(" \n{\"name\":\"echo\"}\t", "{\"tools\":{}}", &out);
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
    try testing.expectEqualStrings(
        "{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{}}}",
        try injectMeta("{ }", "{}", &out),
    );
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
        // session pinned there does not refuse a call the peer still has.
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

test "the three methods that live only inside inputRequests pass no gate" {
    // PROTOCOLS.md 4.4 removes `elicitation/create`, `sampling/createMessage`
    // and `roots/list` as top-level requests and keeps their types inside
    // `InputRequiredResult.inputRequests`. `mcp.lookupMethod` models none of
    // them at any revision, so no pin decides this: the position does.
    const only_inside = [_][]const u8{
        "elicitation/create",
        "roots/list",
        "sampling/createMessage",
    };
    for ([_]mcp.Revision{ .current, .previous }) |revision| {
        const server: Server = .{ .connection = undefined, .revision = revision };
        for (only_inside) |name| {
            try testing.expectError(error.MethodNotInRevision, server.gate(name));
            // `mcp.lookupInputRequest` is where they went, and the only entry
            // point that finds them at all. The refusal is about the position
            // a name was found in and not about the name.
            try testing.expectEqualStrings(name, (try mcp.lookupInputRequest(name)).name);
        }
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

test "a cacheable result missing a required field is refused by the call" {
    var scratch: [256]u8 = undefined;
    const server: Server = .{ .connection = undefined, .revision = .current };

    const listing = try server.gate("tools/list");
    try testing.expect(listing.cacheable);
    try Server.checkResult(
        listing,
        "{\"ttlMs\":1000,\"cacheScope\":\"private\",\"tools\":[]}",
        &scratch,
    );

    // PROTOCOLS.md 4.6 requires both fields, so leaving out either one is the
    // same fault, and neither is a value a caller may fill in later.
    try testing.expectError(
        error.NotAResult,
        Server.checkResult(listing, "{\"tools\":[]}", &scratch),
    );
    try testing.expectError(
        error.NotAResult,
        Server.checkResult(listing, "{\"tools\":[],\"ttlMs\":1000}", &scratch),
    );
    try testing.expectError(
        error.NotAResult,
        Server.checkResult(listing, "{\"tools\":[],\"cacheScope\":\"private\"}", &scratch),
    );
    // A body that is not an object never was a result, whatever it carries.
    try testing.expectError(error.NotAResult, Server.checkResult(listing, "[1,2]", &scratch));

    // A method whose result carries no caching hints is not read at all: the
    // rule does not apply to it, and reading it would refuse a result the
    // specification allows.
    const call = try server.gate("tools/call");
    try testing.expect(!call.cacheable);
    try Server.checkResult(call, "{\"resultType\":\"complete\",\"content\":[]}", &scratch);
    try Server.checkResult(call, "{\"resultType\":\"complete\"}", &scratch);
}

test "an interim result is written only for a method PROTOCOLS.md 4.7 allows" {
    var scratch: [256]u8 = undefined;
    var out: [512]u8 = undefined;
    const requests = "{\"e1\":{\"method\":\"elicitation/create\"}}";

    // `tools/list` is not one of the three, so the refusal lands before any
    // body is written.
    try testing.expectError(
        error.InputRequiredUnexpected,
        Server.inputRequired("tools/list", requests, "st", &out),
    );

    const body = try Server.inputRequired("tools/call", requests, "st", &out);
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
        Server.inputRequired("prompts/get", requests, "st", &tiny),
    );

    // A state carrying a quote and a backslash round-trips to the same
    // characters. Spliced as written it would have ended the member at the
    // first quote, and the peer would have read a shorter state than the one
    // the server meant to send.
    const awkward_state = "a\"b\\c";
    var escaped: [512]u8 = undefined;
    const read_back = try mcp.decodeInputRequiredResult(
        try Server.inputRequired("resources/read", requests, awkward_state, &escaped),
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
        Server.inputRequired("prompts/get", requests, long_state, &short_out),
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
    try Server.checkResult(info, try server.discoverBody("be careful", &out), &scratch);

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
    /// each round trip of a multi-round-trip exchange is a new call.
    ids: [3]i64 = .{ 0, 0, 0 },
    /// Whether the peer's first `tools/call` carried the capabilities in
    /// `_meta`, and whether the caller's own members survived beside them.
    meta_on_wire: bool = false,
    members_kept: bool = false,

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
    const request = jsonrpc.decodeRequest(frame, decode_scratch) catch return null;
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
        // Two interim answers and then a final one, so a caller that stops
        // after one round trip is caught handing back an interim result.
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
        if (exchange.tool_calls < 3) {
            return conn.respond(request, interim_result, answer) catch null;
        }
        return conn.respond(request, final_result, answer) catch null;
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

    // Four refusals, four reasons, one case each.
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
    // the final result, and the exchange finished on the third round trip.
    try testing.expect(exchange.retry_refused);
    try testing.expect(!exchange.final_failed);
    try testing.expectEqualStrings(
        "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"echoed\"}]}",
        exchange.final_body[0..exchange.final_body_len],
    );
    try testing.expectEqual(@as(usize, 3), exchange.tool_calls);

    // Every round trip was a new call, as PROTOCOLS.md 4.7 requires.
    try testing.expect(exchange.ids[0] != exchange.ids[1]);
    try testing.expect(exchange.ids[1] != exchange.ids[2]);
    try testing.expect(exchange.ids[0] < exchange.ids[2]);

    // The capabilities rode on the request in `_meta`, with the caller's own
    // members beside them.
    try testing.expect(exchange.meta_on_wire);
    try testing.expect(exchange.members_kept);

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
