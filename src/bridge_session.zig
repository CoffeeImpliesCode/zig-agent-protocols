//! The `mcp-over-acp` binding, driven over a live connection.
//!
//! PROTOCOLS.md section 7: the only defined composition between these
//! protocols. A provider carries stateless MCP `2026-07-28` requests over an
//! existing ACP connection, using one method, `mcp/message`, in two
//! directions.
//!
//! ## The three ways this can go wrong
//!
//! - **An inner MCP error is a successful outer response.** It arrives in the
//!   outer `result` member as an `error` object, not as an outer `error`. A
//!   client that only looks at whether the outer call failed reports a tool
//!   failure as a transport failure, and then retries it, which is exactly
//!   what the binding's whole design exists to prevent.
//! - **The error spaces overlap.** `-32602` is both the JSON-RPC standard
//!   "invalid params" an MCP server returns inside a tool error and this
//!   binding's own outer `invalid_request`. Only the level tells them apart,
//!   which is why `bridge.isBindingFailure` takes one.
//! - **The binding is MCP `2026-07-28` only.** It does not emulate earlier
//!   revisions and performs no MCP handshake, so a caller pinned to another
//!   revision is refused here rather than downstream. The same pin fixes the
//!   method inventory: [`Client.call`] resolves its `method_name` through
//!   [`mcp.lookupMethod`] before it hands the envelope to the connection,
//!   which is the call `mcp_session.Client.request` makes, so a name
//!   `2026-07-28` removed as a top-level request never reaches the wire.
//!
//! ## Both directions
//!
//! [`Client`] carries a call out and [`Provider`] answers one that arrives.
//! [`Provider.bindingError`] writes the outer error a binding failure is, and
//! it is the only producer of one in this file. Neither side allocates: every
//! buffer belongs to the caller, and every slice returned borrows one of them
//! for the length of the call.

const std = @import("std");
const bridge = @import("bridge.zig");
const conn = @import("conn.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const mcp = @import("mcp.zig");
const root = @import("root.zig");
const Io = std.Io;

/// What a call, a served request or an outcome read can return here.
///
/// The five members below are this binding's own. The rest belong to the
/// codec and to the connection, which this file does not redefine, so an
/// `error.InvalidField` off [`Client.call`] says the envelope the caller
/// handed over is one this binding cannot carry: it is refused here, before
/// anything reaches the wire, rather than by the peer on the far side.
pub const Error = error{
    /// The binding carries MCP `2026-07-28` only, and the caller pinned a
    /// session to something else.
    UnsupportedMcpRevision,
    /// The inner MCP method is not one the bound revision carries, so it was
    /// not sent.
    ///
    /// PROTOCOLS.md 4.4 removes `initialize`, `roots/list`,
    /// `sampling/createMessage` and `elicitation/create` as top-level
    /// requests, and [`mcp.lookupMethod`] refuses every one of them. The same
    /// call `mcp_session.Client.request` makes on the same revision, so the
    /// binding and the MCP session layer cannot drift into two answers to one
    /// question.
    ///
    /// Reported here rather than left to the peer's inner `-32601`, because
    /// the caller can fix it without a round trip and because the other end of
    /// this same library refuses to answer it: a `Provider` is handed the
    /// method by its `Resolver` and answers `null`, which `serve` writes as
    /// that inner `-32601` inside a successful outer response. The knowledge
    /// belongs to the resolver, and only the client side knows it before a
    /// byte is sent.
    MethodNotInRevision,
    /// The peer refused this call with an outer error. Every outer refusal
    /// arrives this way whatever the code, because the connection is alive and
    /// carries the next call, and `refusal` says which refusal it was.
    /// `error.Transport` and `error.ConnectionClosed` are left to mean what
    /// `conn.Error` says: a connection that cannot be reused.
    PeerRefused,
    /// The outer response carried neither an inner result nor an inner error.
    NoInnerOutcome,
    /// A caller-supplied buffer was too small.
    BufferTooSmall,
} || root.EncodeError || conn.Error;

/// What a peer answered to a carried call it refused.
///
/// `code` is the number the peer sent and `body` is the error object the
/// connection re-serialised into the `inner` buffer `Client.call` was given.
/// `body` borrows that buffer, so a caller reads the peer's own message with
/// nothing allocated and nothing retained. `binding` says whether `code` is
/// one the binding allocates, which is the only thing that separates the
/// binding's own failures from an arbitrary peer's refusal, so it lives here
/// rather than in the error kind: the kind is what a caller switches on, and a
/// second kind would be a distinction to learn twice.
pub const Refusal = struct {
    code: i32,
    body: []const u8,
    binding: bool,
};

/// The one method this binding uses.
pub const method = "mcp/message";

/// A client that carries MCP calls over an ACP connection.
pub const Client = struct {
    /// The connection the call goes out on, which the caller owns and keeps
    /// alive. Every call this client makes travels over it.
    connection: *conn.Conn,
    /// The MCP revision carried inside. The binding is `2026-07-28` only.
    revision: mcp.Revision = .current,

    /// The peer's answer to the last call, when it refused. Set before `call`
    /// returns `error.PeerRefused` and cleared by every other outcome, so a
    /// caller reads it only after that error and never sees a stale refusal.
    refusal: ?Refusal = null,

    pub fn init(connection: *conn.Conn) Client {
        return .{ .connection = connection };
    }

    /// Pin the inner MCP revision.
    ///
    /// Refused rather than warned about: a binding that emulated `2025-11-25`
    /// would need an MCP handshake it does not perform, so every call on it
    /// would fail somewhere less obvious than here.
    pub fn setRevision(self: *Client, revision: mcp.Revision) Error!void {
        if (revision != .current) return error.UnsupportedMcpRevision;
        self.revision = revision;
    }

    /// Carry one MCP call and return its inner result.
    ///
    /// `server_id` names a server the provider declared and is never rebound;
    /// `request_id` is one per logical MCP request and survives proxies. The
    /// outer ACP id is this connection's own and a proxy may renumber it.
    ///
    /// The outer `result` body comes back for an inner result and for an
    /// inner error alike, because the outer call succeeded either way. An
    /// inner MCP error is therefore data and not an error return, and this
    /// function has no way to report one as a connection failure. Read the
    /// body with `readOutcome`, or with `classifyOutcome`, before acting on
    /// it: a caller that stopped here would report a tool failure as a
    /// success.
    ///
    /// An outer error is a refusal of this call and not a dead connection, so
    /// every one of them returns `error.PeerRefused` with `refusal` set, and
    /// `refusal.binding` tells the binding's own codes from an arbitrary
    /// peer's. `error.Transport` and `error.ConnectionClosed` reach a caller
    /// only when `connection.call` itself reports a connection that cannot be
    /// reused, which is what those two errors mean everywhere else.
    ///
    /// An envelope the binding cannot carry is refused here, before a byte
    /// reaches the connection. `bridge.encodeEnvelope` validates before it
    /// writes, so an empty `server_id`, `request_id` or `method_name` returns
    /// `error.InvalidField` with nothing encoded and nothing sent. The far
    /// side would answer the same envelope with an outer `-32602`, so writing
    /// it first would spend a round trip to learn what this side already
    /// knows, and would put a frame on the wire that the other end of this
    /// same library refuses to read.
    ///
    /// A method the bound revision does not carry is refused here too, as
    /// `error.MethodNotInRevision`, and before the connection is touched: the
    /// envelope is composed into the caller's own `envelope` buffer and no id
    /// is spent, no frame is written and no peer is asked. The binding carries
    /// MCP `2026-07-28`, and that revision removed `initialize`, `roots/list`,
    /// `sampling/createMessage` and `elicitation/create` as top-level
    /// requests, so a call naming one asks for an operation this wire has no
    /// answer for. A provider that does carry it answers with an inner
    /// `-32601` inside a successful outer response, and one that does not is
    /// entitled to; the round trip buys nothing, and the frame is one the
    /// other end of this same library refuses to answer.
    ///
    /// The two refusals are ordered the way their faults are: an envelope the
    /// binding cannot carry is condemned first, and an empty `method_name` is
    /// that fault rather than a method this revision removed.
    pub fn call(
        self: *Client,
        server_id: []const u8,
        request_id: []const u8,
        method_name: []const u8,
        params: ?[]const u8,
        inner: []u8,
        out: []u8,
        envelope: []u8,
    ) Error![]const u8 {
        // Cleared first, so a refusal from an earlier call cannot stand while
        // a later one succeeds.
        self.refusal = null;
        if (self.revision != .current) return error.UnsupportedMcpRevision;

        // One encoder for the binding, so the rule that a member is non-empty
        // is written down once, in `bridge.encodeEnvelope`, and enforced on
        // both sides of the boundary rather than once per call site.
        var writer = json.Writer.init(envelope);
        try bridge.encodeEnvelope(.{
            .server_id = server_id,
            .request_id = request_id,
            .inner_method = method_name,
            .inner_params = params,
            // Not a member of the params object: the outer message carries the
            // direction, and a call this client makes is a request.
            .direction = .agent_to_provider,
        }, &writer);
        const body = writer.written();
        // One rule for what a method may be, and it is the rule
        // `mcp_session.Client.request` reaches for on the same revision, so the
        // binding and the MCP session layer cannot drift into two answers to
        // one question. `self.revision` is `.current` here: the check above
        // refused every other value, which is what makes this
        // `mcp.lookupMethod(.current, method_name)`.
        //
        // After the encoder rather than before it, because the encoder owns
        // the rule that a member is non-empty and an empty `method_name` is
        // that fault rather than this one. Running it first would report a
        // bad envelope as a method this revision does not carry, which is the
        // second fault of a call the first already condemned.
        //
        // `lookupMethod` walks comptime tables and compares names, so it reads
        // no caller buffer and no member of `DecodeError` but `UnknownMethod`
        // can reach here. Collapsing the catch reports the refusal rather than
        // unwrapping a path that cannot happen into a panic.
        _ = mcp.lookupMethod(self.revision, method_name) catch
            return error.MethodNotInRevision;

        const answer = try self.connection.call(method, body, inner, out);
        if (answer.error_code) |code| {
            // Every outer error is the peer refusing this call, and all of them
            // are reported the same way, because the error kind is what a
            // caller switches on and both `error.Transport` and
            // `error.ConnectionClosed` mean a connection that cannot be reused.
            // The flag says whether the code is one the binding allocates, and
            // the binding takes its codes from outside both MCP ranges — the
            // implementation-defined -32000 to -32019 and the -32020 to -32099
            // the specification reserves — so an inner tool failure can never
            // be read as a binding failure at any level.
            self.refusal = .{
                .code = code,
                .body = answer.body,
                .binding = bridge.isBindingFailure(code, .outer),
            };
            return error.PeerRefused;
        }
        return answer.body;
    }

    /// Read an inner outcome out of a successful outer `result`.
    ///
    /// This is the step that keeps an inner failure from being mistaken for a
    /// success. It is a separate call rather than something `call` hides,
    /// because the caller has to look at both possibilities to answer
    /// correctly.
    pub fn readOutcome(outer_result: []const u8, scratch: []u8) Error!bridge.Outcome {
        return bridge.decodeOutcome(outer_result, scratch) catch |err| switch (err) {
            // A short scratch is the caller's own fault and not a verdict on
            // the peer. Reported as `NoInnerOutcome` it would say the answer
            // carried no inner outcome, and a caller sent looking for that
            // protocol bug would never find it, because the peer sent one.
            error.BufferTooSmall => error.BufferTooSmall,
            // Every other decode error means the body is not an inner outcome
            // this layer can read, which is what `NoInnerOutcome` says, and one
            // arm is deliberate: splitting these out would report a verdict on
            // the wire that this layer cannot make.
            else => error.NoInnerOutcome,
        };
    }
};

/// The body a provider returns for a carried MCP request.
///
/// Exactly one of the two members is set. `inner_error` is set for an MCP
/// error, which is still a successful outer response; a caller that reads
/// `inner_result` without checking this flag reports a tool failure as
/// success.
pub const Outcome = struct {
    inner_result: ?[]const u8 = null,
    inner_error: ?[]const u8 = null,

    /// Whether the carried MCP operation failed. The outer call succeeded
    /// either way.
    pub fn failed(self: Outcome) bool {
        return self.inner_error != null;
    }
};

/// Split a successful outer `result` into its two possible shapes.
pub fn classifyOutcome(outer_result: []const u8, scratch: []u8) Error!Outcome {
    const outcome = try Client.readOutcome(outer_result, scratch);
    return switch (outcome) {
        // The arm carries a `bridge.OutcomePayload`, and `text` is the inner
        // payload: the result a caller acts on, or the error object it has to
        // read. The carrier `_meta` beside it belongs to the binding rather
        // than to the outcome, and a caller that needs it reads the
        // `bridge.Outcome` [`Client.readOutcome`] returns.
        .result => .{ .inner_result = outcome.result.text },
        .@"error" => .{ .inner_error = outcome.@"error".text },
    };
}

/// The MCP operations a provider carries.
///
/// `out` is where the resolver writes the JSON text of the inner payload, and
/// the returned outcome borrows it. `bridge.encodeOutcome` splices that text
/// verbatim, so the `result` arm takes any JSON value at all and the `error`
/// arm takes an object with an integer `code` and a string `message`, which
/// is what `bridge.decodeOutcome` reads on the far side.
///
/// The return type is what keeps the two sides of the boundary apart. A
/// resolver answers with an MCP outcome or with nothing, and both land inside
/// a successful outer response, so the only two answers a resolver can reach
/// the wire through are the inner `-32601` a caller does not carry and the
/// outcome it brought back. No failure a resolver reports ever lands on the
/// outer message, which is the half of the mistake this binding exists to
/// prevent: a caller told the transport failed retries a tool failure.
///
/// A resolver that cannot run at all returns an error instead, and `serve`
/// propagates it without writing a frame. A failure to run the resolver is
/// the caller's own condition and not a protocol answer, and this binding
/// refuses to invent one for it.
///
/// Not a [`conn.Handler`], and the arity is what says so: the connection hands
/// a handler a raw frame, a decode region and an answer region, and it hands a
/// resolver an envelope `serve` has already decoded plus the one buffer the
/// payload goes into. A resolver is handed no frame and no id, so nothing it
/// writes can land on a value the connection is still reading.
pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (
        ctx: ?*anyopaque,
        envelope: bridge.Envelope,
        out: []u8,
    ) Error!?bridge.Outcome = null,
};

/// One carried request a provider is serving now.
///
/// The pair identifies the request, because the outer ACP id identifies one
/// hop and a proxy is free to renumber it. A provider therefore refuses a
/// second call for a pair it is still holding, and serves the same pair once
/// it has answered.
pub const Active = struct {
    /// The server the call went to, so two servers may carry the same
    /// `requestId` at once.
    server_id: []const u8 = &.{},
    /// The caller's own identifier for the logical MCP request.
    request_id: []const u8 = &.{},
    /// Whether any call holds this entry.
    used: bool = false,
};

/// A provider that answers carried MCP requests over an ACP connection.
///
/// PROTOCOLS.md 7 makes a provider the side that declares servers and serves
/// `mcp/message` travelling agent to provider. [`serve`] answers one such
/// request and returns the frame to write, or null for a message the provider
/// declines. The connection, the reader and the handler stay the caller's,
/// because `conn.Conn` already owns that machinery and a handler must run on
/// the reader task rather than beside it.
///
/// ## What each failure is
///
/// Every answer `serve` gives lands on one side of the boundary, and which
/// side is the whole content of the binding:
///
/// - A message this binding does not carry is declined, so the answer is
///   whatever else the provider does with it and never a `mcp/message`
///   result the caller would read as a carried call.
/// - A malformed envelope, an undeclared `serverId`, a pair the provider is
///   already holding, and a table with no free slot are failures of the
///   binding, so all four are outer errors.
/// - A method the resolver does not carry is the tool's failure rather than
///   the transport's, so it is an inner `-32601` inside a successful outer
///   response. An outer error there would invite a retry that cannot fix it.
/// - Anything else is a successful outer response carrying exactly one inner
///   outcome, which is what [`Client.call`] reads back.
///
/// ## Concurrency
///
/// `serve` runs inline on the reader task, so one connection carries one
/// served carried request at a time and `active` needs no mutex. A caller
/// that serves from several tasks at once owns that with whatever it already
/// uses to share its buffers.
pub const Provider = struct {
    /// The connection this provider answers on. Nothing in `serve` reads it,
    /// and it is carried so one value holds both the transport and the
    /// binding rules that apply over it.
    connection: *conn.Conn,
    /// The server ids this provider declared. An envelope naming anything
    /// else is a `server_registration_unavailable` refusal, because only the
    /// provider's own declaration says a `serverId` names a server.
    servers: []const []const u8 = &.{},
    /// Storage for the carried requests this provider is serving at once.
    /// The caller hands it over because its length is the bound, so a peer
    /// that opens requests faster than the caller sized for is refused rather
    /// than given a slot another call is holding.
    ///
    /// The provider owns the entries. It clears the one it takes before it
    /// returns and never reads an entry it has not taken, so the array needs
    /// no initialising where the caller declares it.
    active: []Active = &.{},
    /// Where the next slot is: the index `serve` claims, and the count of the
    /// entries below it the provider owns.
    ///
    /// Zero on a provider `init` returned and zero on one the caller gave an
    /// `active` array, so the same value is right for both, and every claim
    /// and every release moves it by one.
    free: usize = 0,

    pub fn init(connection: *conn.Conn) Provider {
        return .{ .connection = connection };
    }

    /// Answer one carried request, and return the frame that answers it.
    ///
    /// Null is a decline rather than a failure, and a caller has to do three
    /// things with it:
    ///
    /// - Return it to the connection unchanged. `null` is what `conn.Handler`
    ///   already means by "no answer" and `conn.Conn` writes nothing for it,
    ///   so a caller that hands `serve`'s result straight back has nothing to
    ///   do at all.
    /// - Leave it null. An empty slice is a frame with no content, the framer
    ///   writes it, and the peer's reader drops a frame that will not parse,
    ///   so that spelling turns a decline into a wire fault.
    /// - Expect the peer to wait. A declined request is unanswered until the
    ///   provider's own dispatcher answers it, which is the bargain every
    ///   handler in `conn.Conn` makes.
    ///
    /// A notification is not a `jsonrpc.Request` at all, because a message
    /// with no id has no answer to give, and PROTOCOLS.md 7 makes the
    /// provider-to-agent direction one. So the direction never reaches this
    /// function as a case of its own: `bridge.decodeEnvelope` reads it from
    /// the id `request` carries, and that id is `agent_to_provider` for every
    /// request.
    ///
    /// The answers, in the order `serve` tries them, are the binding:
    ///
    /// 1. A method that is not `mcp/message`: null.
    /// 2. An envelope that will not decode, or no params object to decode one
    ///    from: an outer `invalid_request`.
    /// 3. A `serverId` this provider never declared: an outer
    ///    `server_registration_unavailable`.
    /// 4. A `(serverId, requestId)` pair this provider is already serving:
    ///    an outer `invalid_request`, or an outer `resource_limit_exceeded`
    ///    when the caller's table has no slot left at all.
    /// 5. A resolver that answers nothing: an inner `-32601` inside a
    ///    successful outer response.
    /// 6. Otherwise: the resolver's own outcome, as one successful outer
    ///    response.
    ///
    /// Each buffer backs one step and is borrowed for the length of the call.
    /// `envelope_scratch` backs the decoded envelope, `inner` is the buffer
    /// the resolver writes its payload into and backs the refusal payload when
    /// the resolver carries no such method, `outcome_scratch` holds the
    /// outcome `bridge.encodeOutcome` writes around that payload, and `out`
    /// receives the outer frame. One `outcome_scratch` and one `out` for both
    /// branches, because the branches differ in the payload and in nothing
    /// else.
    ///
    /// Every failure `serve` has of its own is a `conn.Error` member, and an
    /// answer that does not fit is `ResponseTooLarge` whichever of the four
    /// buffers was short, because one answer for a short answer is the only
    /// one a caller can act on. A resolver that returns an error propagates
    /// here unchanged and writes no frame.
    pub fn serve(
        self: *Provider,
        request: jsonrpc.Request,
        resolver: Resolver,
        envelope_scratch: []u8,
        outcome_scratch: []u8,
        inner: []u8,
        out: []u8,
    ) Error!?[]const u8 {
        // Another method is not this binding's, and answering it here would
        // put a `mcp/message` result on a call this provider never read.
        if (!std.mem.eql(u8, request.method.text, method)) return null;

        // An envelope is a params object, so a message carrying none, or one
        // carrying an explicit `null`, is a malformed envelope rather than a
        // request with no arguments to carry.
        const params = switch (request.params) {
            .value => |text| text,
            else => {
                const refusal = try Provider.bindingError(
                    request,
                    .invalid_request,
                    "mcp/message carries no params object",
                    out,
                );
                return refusal;
            },
        };

        // A malformed envelope is this binding's fault and not the carried
        // operation's, so the refusal rides on the outer message.
        const envelope = bridge.decodeEnvelope(params, envelope_scratch, request.id) catch {
            const refusal = try Provider.bindingError(
                request,
                .invalid_request,
                "the mcp/message envelope will not decode",
                out,
            );
            return refusal;
        };

        // Only the provider's own declaration says a `serverId` names a
        // server, so nothing else on this connection can vouch for one.
        for (self.servers) |declared| {
            if (std.mem.eql(u8, declared, envelope.server_id)) break;
        } else {
            const refusal = try Provider.bindingError(
                request,
                .server_registration_unavailable,
                "no such MCP server",
                out,
            );
            return refusal;
        }

        // The pair, and not the outer id: a proxy renumbers that, so the two
        // claims below are about one logical MCP request and not one hop.
        for (self.active[0..self.free]) |*claimed| {
            if (!claimed.used) continue;
            if (std.mem.eql(u8, claimed.server_id, envelope.server_id) and
                std.mem.eql(u8, claimed.request_id, envelope.request_id))
            {
                const refusal = try Provider.bindingError(
                    request,
                    .invalid_request,
                    "that requestId is already active for this server",
                    out,
                );
                return refusal;
            }
        }
        // A table with no free slot is a binding limit and the caller set it,
        // so it is reported rather than papered over by serving a request out
        // of a slot another call is holding.
        if (self.free >= self.active.len) {
            const refusal = try Provider.bindingError(
                request,
                .resource_limit_exceeded,
                "no free slot for another carried request",
                out,
            );
            return refusal;
        }
        const slot = &self.active[self.free];
        slot.* = .{
            .server_id = envelope.server_id,
            .request_id = envelope.request_id,
            .used = true,
        };
        self.free += 1;
        // Released on every way out, because a provider that kept the pair
        // after answering would refuse the caller's retry.
        defer {
            slot.* = .{};
            self.free -= 1;
        }

        // A resolver that answers nothing carries no such MCP method. Its
        // error arm propagates instead, so the two answers below are all a
        // resolver can reach the wire through.
        const outcome: ?bridge.Outcome = if (resolver.call) |call|
            try call(resolver.ctx, envelope, inner)
        else
            null;

        // One place writes the inner outcome and one place answers it, so the
        // two branches cannot disagree about the shape a caller reads. A
        // refusal goes through the same encoder as a result for exactly that
        // reason: the object under the `error` member is not the outcome, and
        // written as though it were, it produced a result carrying neither a
        // `result` member nor an `error` member. That is well formed JSON and
        // unreadable as an outcome, so the one error this binding exists to
        // keep readable was the one a hand-written shape broke.
        var writer = json.Writer.init(outcome_scratch);
        if (outcome) |carried| {
            bridge.encodeOutcome(carried, &writer) catch return error.ResponseTooLarge;
        } else {
            // `inner` is the resolver's buffer and the resolver wrote nothing,
            // so it backs the payload here and nothing reads it afterwards.
            const payload = methodNotCarried(envelope.inner_method, inner) catch
                return error.ResponseTooLarge;
            bridge.encodeOutcome(.{ .@"error" = .{ .text = payload } }, &writer) catch
                return error.ResponseTooLarge;
        }
        const answered = try conn.respond(request, writer.written(), out);
        return answered;
    }

    /// Write the outer error a binding failure answers `request` with.
    ///
    /// This is the only producer of an outer error in this file, and it is a
    /// function rather than a branch inside `serve` so that a caller can also
    /// write the two codes `serve` has no cause for: `operation_cancelled`
    /// when the provider's own work was cancelled, and `backend_failed` when
    /// the backend a carried request resolved against failed without
    /// producing an MCP outcome. `serve` writes the other three, and together
    /// they are every value `bridge.BindingError` has.
    ///
    /// The refusal goes in the outer `error` member, so the peer reads a
    /// failure of the binding rather than an inner outcome inside a result.
    /// That is the whole difference between this `-32602` and the `-32602` a
    /// tool returns inside a successful outer response: the level, and only
    /// the level, tells them apart.
    pub fn bindingError(
        request: jsonrpc.Request,
        binding: bridge.BindingError,
        message: []const u8,
        out: []u8,
    ) conn.Error![]const u8 {
        return conn.errorResponse(request, .{
            .code = @intFromEnum(binding),
            .message = message,
        }, out);
    }
};

/// The MCP error object a method this provider does not carry is refused
/// with, written into `out`.
///
/// This is the payload under the outcome's `error` member and not the outcome
/// itself. `bridge.encodeOutcome` wraps it and `bridge.decodeOutcome` reads it
/// back through that wrapper, so a caller never sees the bare object.
///
/// The method rides in `data`, escaped, because it arrived off the wire and a
/// quote or a newline in it would otherwise end the string it sits in.
fn methodNotCarried(
    inner_method: []const u8,
    out: []u8,
) root.EncodeError![]const u8 {
    var writer = json.Writer.init(out);
    try writer.slice("{\"code\":");
    var digits: [16]u8 = undefined;
    const code = std.fmt.bufPrint(&digits, "{d}", .{
        @intFromEnum(jsonrpc.StandardError.method_not_found),
    }) catch return error.BufferTooSmall;
    try writer.slice(code);
    try writer.slice(",\"message\":");
    try writer.string("Method not found");
    try writer.slice(",\"data\":{\"method\":");
    try writer.string(inner_method);
    try writer.slice("}}");
    return writer.written();
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

/// A transport that refuses every byte written to it, over a reader with
/// nothing on it.
///
/// A call that reaches this connection ends at the write with
/// `error.Transport` instead of waiting for an answer no peer will send. The
/// message is already in the `out` buffer the caller handed `conn.Conn.call`,
/// because the connection encodes and frames a request before it writes it,
/// so `lastEncodedLen` is how much of that buffer the frame occupies.
///
/// A writer that cannot write is a connection that is finished, so the failed
/// write marks it dead and the next call on it is refused in `open` with
/// `error.Closed` before it claims a slot, takes an id or frames anything.
/// That is the second half of what this transport measures, and it is the
/// better of the two signals: `error.Transport` says this write failed, and
/// `error.Closed` says the connection is done, which is what a caller needs
/// in order to stop using it.
///
/// This is what a refusal is measured against. A call the binding accepts
/// reaches the writer and reports `error.Transport`; a call it refuses
/// reports `error.InvalidField` and the writer never sees a byte.
const DeadTransport = struct {
    reader: Io.Reader,
    writer: Io.Writer = Io.Writer.failing,

    fn connection(self: *DeadTransport, side: *Side) conn.Error!conn.Conn {
        return conn.Conn.init(testing.io, &self.reader, &self.writer, .{
            .frame_buffer = &side.frame_buffer,
            .pending = &side.pending,
            .decode_scratch = &side.decode_scratch,
            .answer = &side.answer,
        });
    }
};

test "a carried call puts the three envelope members on the wire" {
    // The params object `Client.call` builds is the one the provider's own
    // `bridge.decodeEnvelope` reads, so this is the frame it has to be: the
    // three members the binding names, and the inner params beside them when
    // there are any. Read from the buffer the connection framed it into,
    // because that is the byte sequence the peer sees.
    var side: Side = .{};
    var inner: [256]u8 = undefined;
    var out: [512]u8 = undefined;
    var envelope: [256]u8 = undefined;
    var transport: DeadTransport = .{ .reader = Io.Reader.fixed("") };
    var connection = try transport.connection(&side);
    var client = Client.init(&connection);

    // The write is refused, so the call ends there and the frame is in `out`.
    try testing.expectError(error.Transport, client.call(
        "project-tools:7a72",
        "req-1",
        "tools/call",
        "{\"name\":\"echo\"}",
        &inner,
        &out,
        &envelope,
    ));
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"mcp/message\",\"params\":" ++
            "{\"serverId\":\"project-tools:7a72\",\"requestId\":\"req-1\"," ++
            "\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}}",
        out[0..connection.lastEncodedLen()],
    );

    // That failed write marked the connection dead, and the next call on it
    // says so. `error.Closed` rather than a second `error.Transport` is the
    // answer a caller can act on: the first would read as a write that failed
    // again, and a caller that believes that retries on a writer that cannot
    // write, while `error.Closed` is this library's own documented way of
    // saying the connection cannot be reused and belongs to no other fault.
    //
    // The id did not move either. A call refused in `open` is refused before it
    // claims a slot and takes an id, so the sequence holds at the id the
    // refused call would have used and the caller's own ids stay predictable.
    try testing.expectError(error.Closed, client.call(
        "project-tools:7a72",
        "req-2",
        "subscriptions/listen",
        null,
        &inner,
        &out,
        &envelope,
    ));
    try testing.expectEqual(@as(i64, 2), connection.nextId());
    // And nothing was framed for it, so the bytes still standing in `out` are
    // the first call's and the refused one put nothing where a peer could read
    // it.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"mcp/message\",\"params\":" ++
            "{\"serverId\":\"project-tools:7a72\",\"requestId\":\"req-1\"," ++
            "\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}}",
        out[0..connection.lastEncodedLen()],
    );

    // The same call with no inner params, where the member is absent rather
    // than null, on a connection of its own. It needs one: the first is
    // finished, and a call on a finished connection is refused before it is
    // framed, so it would put these bytes nowhere. The id starts again on a
    // fresh connection, which is what the wire says.
    var second_side: Side = .{};
    var second_transport: DeadTransport = .{ .reader = Io.Reader.fixed("") };
    var second_connection = try second_transport.connection(&second_side);
    var second_client = Client.init(&second_connection);
    try testing.expectError(error.Transport, second_client.call(
        "project-tools:7a72",
        "req-2",
        "subscriptions/listen",
        null,
        &inner,
        &out,
        &envelope,
    ));
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"mcp/message\",\"params\":" ++
            "{\"serverId\":\"project-tools:7a72\",\"requestId\":\"req-2\"," ++
            "\"method\":\"subscriptions/listen\"}}",
        out[0..second_connection.lastEncodedLen()],
    );
}

test "an envelope with an empty member is refused before a byte is written" {
    // `bridge.decodeEnvelope` refuses an empty `serverId`, `requestId` or
    // inner method, and `Provider.serve` answers such an envelope with an
    // outer `-32602`. An encoder that wrote one would put a frame on the wire
    // that the far side of this same library refuses to read, and the caller
    // would learn it from the peer instead of from the call that made it.
    //
    // The transport is the one above, so a call that reached it would report
    // `error.Transport`. `error.InvalidField` is the envelope refused before
    // the connection was touched, and the sentinel in the envelope buffer
    // says the encoder wrote none of the object either.
    var side: Side = .{};
    var inner: [256]u8 = undefined;
    var out: [512]u8 = undefined;
    var envelope: [256]u8 = undefined;
    @memset(&envelope, 0xa5);
    var transport: DeadTransport = .{ .reader = Io.Reader.fixed("") };
    var connection = try transport.connection(&side);
    var client = Client.init(&connection);

    // Each of the three members the binding names, empty in turn.
    try testing.expectError(error.InvalidField, client.call(
        "",
        "req-1",
        "tools/list",
        null,
        &inner,
        &out,
        &envelope,
    ));
    try testing.expectError(error.InvalidField, client.call(
        "project-tools:7a72",
        "",
        "tools/list",
        null,
        &inner,
        &out,
        &envelope,
    ));
    try testing.expectError(error.InvalidField, client.call(
        "project-tools:7a72",
        "req-1",
        "",
        null,
        &inner,
        &out,
        &envelope,
    ));

    // Nothing was encoded and nothing was framed: every byte of the buffer
    // the encoder writes into is still the sentinel, and the connection built
    // no message to write.
    for (&envelope) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
    try testing.expectEqual(@as(usize, 0), connection.lastEncodedLen());
}

test "a method removed at 2026-07-28 is refused before a byte is written" {
    // PROTOCOLS.md 4.4 removes these four as top-level requests, and
    // `mcp.lookupMethod(.current, …)` refuses every one of them: `initialize`
    // because the revision dropped it, and the other three because a server may
    // only send them inside `InputRequiredResult.inputRequests`, never as a
    // request a client makes. The binding is `2026-07-28` only, so all four
    // are names with no meaning on this wire.
    //
    // The transport is the one the empty-member test above uses, so a call
    // that reached the connection would report `error.Transport`, and the
    // connection counts what it framed. `error.MethodNotInRevision` is the
    // refusal, and a framed length of zero across the four says the connection
    // was never asked: no id spent, no slot taken, no peer troubled. A
    // conforming provider answers such a call with an inner `-32601` inside a
    // successful outer response, so sending it costs a whole round trip to
    // learn what this side already knows.
    var side: Side = .{};
    var inner: [256]u8 = undefined;
    var out: [512]u8 = undefined;
    var envelope: [256]u8 = undefined;
    var transport: DeadTransport = .{ .reader = Io.Reader.fixed("") };
    var connection = try transport.connection(&side);
    var client = Client.init(&connection);

    for ([_][]const u8{
        "initialize",
        "roots/list",
        "sampling/createMessage",
        "elicitation/create",
    }) |removed| {
        try testing.expectError(error.MethodNotInRevision, client.call(
            "project-tools:7a72",
            "req-1",
            removed,
            null,
            &inner,
            &out,
            &envelope,
        ));
    }
    // The connection framed nothing at all across the four, so a caller that
    // reached this gate has not spent an id or a slot either. And no refusal is
    // recorded: the peer refused nothing, so there is nothing to read.
    try testing.expectEqual(@as(usize, 0), connection.lastEncodedLen());
    try testing.expect(client.refusal == null);

    // A method the revision does carry goes out, so the gate is the method
    // and not a closed client: the write is refused by the transport, which
    // is the answer the empty-member test above already reads.
    try testing.expectError(error.Transport, client.call(
        "project-tools:7a72",
        "req-2",
        "tools/list",
        null,
        &inner,
        &out,
        &envelope,
    ));
}

test "a carried result is a success, not a failure" {
    var scratch: [256]u8 = undefined;
    const outcome = try classifyOutcome(
        "{\"result\":{\"resultType\":\"complete\"}}",
        &scratch,
    );
    try testing.expect(!outcome.failed());
    try testing.expect(outcome.inner_error == null);
    try testing.expect(outcome.inner_result != null);
}

test "an inner MCP error is a failure even though the outer call succeeded" {
    // This is the case the binding exists to get right. The outer response
    // carried `result`, so an outer-only check reports success; the inner
    // error is the failure.
    var scratch: [256]u8 = undefined;
    const outcome = try classifyOutcome(
        "{\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}",
        &scratch,
    );
    try testing.expect(outcome.failed());
    try testing.expect(outcome.inner_result == null);
    try testing.expect(std.mem.indexOf(u8, outcome.inner_error.?, "unknown tool") != null);
}

test "the error spaces stay apart across the boundary" {
    // -32602 is the one number both spaces use. Only the level separates an
    // MCP tool failure from a binding failure, so a caller that drops the
    // level would retry a tool failure as though it were a transport failure.
    try testing.expect(!bridge.isBindingFailure(-32602, .inner));
    try testing.expect(bridge.isBindingFailure(-32602, .outer));

    // The binding allocates outside both MCP code ranges, the
    // implementation-defined -32000 to -32019 and the -32020 to -32099 the
    // specification reserves, so no inner code can ever be read as a binding
    // failure.
    for ([_]i32{ -32000, -32019, -32020, -32022, -32601, -32602 }) |code| {
        try testing.expect(!bridge.isBindingFailure(code, .inner));
    }
}

test "an outer result with no inner outcome is refused" {
    var scratch: [256]u8 = undefined;
    try testing.expectError(
        error.NoInnerOutcome,
        classifyOutcome("{}", &scratch),
    );
}

test "a scratch too short for the inner message is BufferTooSmall" {
    // The message carries a JSON escape, so it has to be unescaped into the
    // caller's scratch and one byte cannot hold it. The peer did send an inner
    // outcome, so `NoInnerOutcome` here would send the caller hunting a
    // protocol bug that is in its own buffer sizing.
    var scratch: [1]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        classifyOutcome(
            "{\"error\":{\"code\":-32602,\"message\":\"unknown\\ntool\"}}",
            &scratch,
        ),
    );
}

test "the binding refuses an MCP revision it cannot carry" {
    // The binding performs no MCP handshake, so emulating 2025-11-25 would
    // fail somewhere far less obvious than at the call that asked for it.
    var client = Client.init(undefined);
    try testing.expectError(error.UnsupportedMcpRevision, client.setRevision(.previous));
    try client.setRevision(.current);
    try testing.expectEqual(mcp.Revision.current, client.revision);
}

/// A resolver that carries nothing, so every method it is handed is one this
/// provider does not have.
///
/// A [`Resolver`] callback and not a [`conn.Handler`]: it is called with an
/// envelope and one buffer, never with a frame, so it holds no decoded value
/// that writing could land on.
fn refuseAll(_: ?*anyopaque, _: bridge.Envelope, _: []u8) Error!?bridge.Outcome {
    return null;
}

test "the refusal for a method this provider does not carry is a readable outcome" {
    // A bare JSON-RPC error object is well formed JSON and is not an inner MCP
    // outcome. Written as the whole body it produces an outer result carrying
    // neither a `result` member nor an `error` member, and
    // `bridge.decodeOutcome` refuses it, so the one error this file exists to
    // keep inside the result was the one a caller could not read. Read it back
    // through the decoder rather than counting bytes: the broken body was the
    // right number of bytes.
    var provider = Provider.init(undefined);
    var active: [1]Active = undefined;
    provider.active = &active;
    // `serve` checks the declared servers before it consults the resolver, so
    // a fixture that leaves `servers` empty never reaches the refusal this
    // test is about: it takes the undeclared-server path and answers with an
    // outer `-33001` instead.
    const servers = [_][]const u8{bridge.server_declaration.server_id};
    provider.servers = &servers;

    var params: [256]u8 = undefined;
    var envelope_scratch: [256]u8 = undefined;
    var outcome_scratch: [512]u8 = undefined;
    var inner: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var message_scratch: [512]u8 = undefined;
    var read_scratch: [512]u8 = undefined;

    var params_writer = json.Writer.init(&params);
    try bridge.encodeEnvelope(.{
        .server_id = bridge.server_declaration.server_id,
        .request_id = "req-1",
        .inner_method = "resources/list",
        .inner_params = null,
        .direction = .agent_to_provider,
    }, &params_writer);

    const request: jsonrpc.Request = .{
        .id = .{ .integer = 7 },
        .method = jsonrpc.Method.split(method),
        .params = .{ .value = params_writer.written() },
    };
    const frame = (try provider.serve(
        request,
        .{ .call = refuseAll },
        &envelope_scratch,
        &outcome_scratch,
        &inner,
        &out,
    )).?;

    // The outer call succeeded, because the MCP operation failed and the
    // exchange did not. An outer error here would tell the agent the transport
    // failed and invite a retry that cannot fix it.
    const message = try jsonrpc.decode(frame, &message_scratch);
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    try testing.expect(message.rpc_error == null);
    try testing.expect(message.result != null);

    // And the result is an outcome on its error arm, read back rather than
    // matched, with the method this provider does not carry named in `data`.
    const outcome = try bridge.decodeOutcome(message.result.?, &read_scratch);
    try testing.expect(outcome == .@"error");
    try testing.expect(std.mem.indexOf(u8, outcome.@"error".text, "\"code\":-32601") != null);
    try testing.expect(
        std.mem.indexOf(u8, outcome.@"error".text, "\"method\":\"resources/list\"") != null,
    );

    // The provider released the pair when it answered, so the same call again
    // is served rather than refused as a duplicate.
    try testing.expectEqual(@as(usize, 0), provider.free);
}

test "the binding carries both outcomes and two refusals over a real socket" {
    // The tests above decide what a carried answer means. Only a real socket
    // shows that an inner MCP error arrives inside a successful outer
    // `result` and never as a connection failure, which is the mistake this
    // binding exists to prevent: a caller that saw one would report a tool
    // failure as a broken transport and retry it.
    //
    // The same exchange carries two outer refusals, because a wire is the only
    // place the other half shows: a peer answers a method it does not carry
    // with `-32601` and a server it does not have with the binding's own
    // `-33001`, and it leaves the connection to carry the next call either
    // way.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    var address = try listenOn(io, &path_buffer, 0x5eed_0201);
    // Unlinked after the listener closes, not before: a path removed while
    // the server is still bound can no longer be connected to.
    defer std.Io.Dir.cwd().deleteFile(io, address.path) catch {};
    defer address.server.deinit(io);

    var state: State = .{};
    var provider_endpoint: Endpoint = .{};
    var caller_endpoint: Endpoint = .{};
    var provider_double: CarriedPeer = .{ .state = &state };

    // One group drives both sides. Two would deadlock: the caller blocks
    // waiting for an answer only the provider's task can produce.
    var group: Io.Group = .init;
    var serving = ProviderTask{
        .io = io,
        .group = &group,
        .server = &address.server,
        .endpoint = &provider_endpoint,
        .provider = &provider_double,
    };
    var calling = Caller{
        .io = io,
        .group = &group,
        .address = &address.address,
        .endpoint = &caller_endpoint,
        .state = &state,
    };
    group.async(io, ProviderTask.run, .{&serving});
    group.async(io, Caller.run, .{&calling});
    group.await(io) catch {};

    // The group joined because both sides hung up on their own. Nothing here
    // waits on a timer, so the exchange is over before these assertions run.
    try testing.expect(!state.failed);

    // The inner result arrived as a success, byte for byte as the provider
    // wrote it, so the envelope crossed the boundary intact.
    try testing.expectEqualStrings("{\"tools\":[{\"name\":\"echo\"}]}", state.listed_result);

    // The inner error arrived inside a successful outer response: the outer
    // call returned, and the body reads as a failure with no result beside
    // it. Its code is still the inner one, and `-32602` at this level is not
    // a binding failure, so a caller that classifies it here retries nothing.
    try testing.expect(state.refused_failed);
    try testing.expect(!state.refused_has_result);
    try testing.expect(std.mem.indexOf(u8, state.refused_error, "-32602") != null);
    try testing.expect(std.mem.indexOf(u8, state.refused_error, "unknown tool") != null);

    // Both outer refusals arrive as the binding's one refusal error, whatever
    // the code. `error.Transport` and `error.ConnectionClosed` each say a
    // connection cannot be reused, and a caller reading either per its
    // documented meaning tears this connection down over a refusal it could
    // act on.
    try testing.expectEqual(@as(?anyerror, error.PeerRefused), state.refusals[0].returned);
    try testing.expectEqual(@as(?anyerror, error.PeerRefused), state.refusals[1].returned);
    // Each carries the code the peer sent and the peer's own message, so a
    // caller can show the message rather than only the number.
    const peer_refusal = state.refusals[0].refusal.?;
    const binding_refusal = state.refusals[1].refusal.?;
    try testing.expectEqual(@as(i32, -32601), peer_refusal.code);
    try testing.expectEqual(@as(i32, -33001), binding_refusal.code);
    try testing.expect(std.mem.indexOf(u8, peer_refusal.body, "method not found") != null);
    try testing.expect(std.mem.indexOf(u8, binding_refusal.body, "unknown server") != null);
    // The flag tells the binding's own code from an arbitrary peer's, so the
    // two read apart without a second error kind to learn.
    try testing.expect(!peer_refusal.binding);
    try testing.expect(binding_refusal.binding);

    // And the connection carried a call after both refusals, so nothing about
    // it died.
    try testing.expectEqualStrings(
        "{\"result\":{\"tools\":[{\"name\":\"echo\"}]}}",
        state.after_refusal,
    );

    // The provider answered every carried call and nothing else, so the fifth
    // answer is the fifth call's and not the first one read twice.
    try testing.expectEqual(@as(usize, 5), state.answered);
}

test "a provider answers each carried request on the side its failure belongs to" {
    // The exchange above decides what a carried answer means to a client. This
    // one decides which side of the boundary each refusal lands on, because a
    // provider that put a tool failure on the outer message would look
    // identical to one that worked from every wire an agent can see.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    var address = try listenOn(io, &path_buffer, 0x5eed_0202);
    defer std.Io.Dir.cwd().deleteFile(io, address.path) catch {};
    defer address.server.deinit(io);

    var state: Served = .{};
    var provider_endpoint: Endpoint = .{};
    var caller_endpoint: Endpoint = .{};
    var peer = ServedPeer{ .state = &state, .provider = .init(undefined) };
    // Handed over here and not at the declaration, because the provider holds
    // a pointer to it and a pointer into a temporary would dangle.
    peer.provider.active = &peer.active;
    // One server, so a carried request naming anything else is the
    // `server_registration_unavailable` refusal rather than a call. The
    // declaration is a local of this frame, which outlives the join.
    const declared = [_][]const u8{bridge.server_declaration.server_id};
    peer.provider.servers = &declared;

    // One group drives both sides. Two would deadlock: the caller blocks
    // waiting for an answer only the provider's task can produce.
    var group: Io.Group = .init;
    var serving = ServedTask{
        .io = io,
        .group = &group,
        .server = &address.server,
        .endpoint = &provider_endpoint,
        .peer = &peer,
    };
    var calling = ServedCaller{
        .io = io,
        .group = &group,
        .address = &address.address,
        .endpoint = &caller_endpoint,
        .state = &state,
    };
    group.async(io, ServedTask.run, .{&serving});
    group.async(io, ServedCaller.run, .{&calling});
    group.await(io) catch {};

    // The group joined because both sides hung up on their own. Nothing here
    // waits on a timer, so the exchange is over before these assertions run.
    //
    // The diagnosis prints before either flag is asserted. A flag on its own
    // cannot say which of the nine steps stopped the caller or what it hit,
    // and a rerun to find that out is one too many.
    if (state.failed or state.handler_error != null) {
        std.debug.print("\nprovider exchange stopped at \"{s}\"\n", .{state.step});
        if (state.reason) |err| {
            std.debug.print("  the caller returned: {s}\n", .{@errorName(err)});
        }
        if (state.handler_error) |err| {
            std.debug.print("  the handler first failed with: {s}\n", .{@errorName(err)});
        }
        std.debug.print(
            "  answered {d}, declined {d}, notifications {d}, resolver calls {d}\n",
            .{ state.answered, state.declined, state.notifications, state.resolved },
        );
    }
    try testing.expect(state.handler_error == null);
    try testing.expect(!state.failed);

    // The provider answered every carried request it accepted and drew no
    // frame at all for the two messages that carry no answer: a method that is
    // not this binding's, and a notification.
    try testing.expectEqual(@as(usize, 2), state.declined);
    try testing.expectEqual(@as(usize, 4), state.resolved);

    // Seven carried requests reached `serve` and every one drew a frame. This
    // is the assertion that catches a step declining a request it should
    // accept, because a decline is a null and a null leaves the caller waiting
    // rather than misreading the answer. The nested frame from the duplicate
    // pair is not counted: it never came back through the handler.
    try testing.expectEqual(@as(usize, 7), state.answered);

    // A method that is not this binding's is answered by the provider's own
    // dispatcher, so the code is the peer's and not the binding's, and the
    // resolver was never reached for it.
    try testing.expectEqual(@as(?i32, -32601), state.foreign.code);
    try testing.expect(!state.foreign.binding);

    // A `mcp/message` with no params, and a params object that is not an
    // envelope: both are failures of the binding, and both ride on the outer
    // message as the binding's own `-32602`.
    try testing.expectEqual(@as(?i32, -32602), state.no_params.code);
    try testing.expect(state.no_params.binding);
    try testing.expectEqual(@as(?i32, -32602), state.malformed.code);
    try testing.expect(state.malformed.binding);

    // A server the provider never declared is `-33001`, and the message is
    // the provider's own, so this refusal reads apart from the peer's `-32601`
    // above.
    try testing.expectEqual(@as(?i32, -33001), state.unknown_server.code);
    try testing.expect(state.unknown_server.binding);
    try testing.expect(
        std.mem.indexOf(u8, state.unknown_server.body, "no such MCP server") != null,
    );

    // A carried request this provider serves: the outer call succeeded and the
    // inner outcome is the result the resolver wrote, byte for byte.
    try testing.expectEqual(@as(?i32, null), state.carried.code);
    try testing.expect(!state.carried.failed);
    try testing.expectEqualStrings("{\"tools\":[{\"name\":\"echo\"}]}", state.carried.inner);

    // The duplicate rule, keyed on the pair and not on the outer id: the
    // resolver served the same pair a second time under outer id 99, and the
    // frame came back refused on the outer message with no result beside it.
    var duplicate_scratch: [1024]u8 = undefined;
    const duplicate = try jsonrpc.decode(state.duplicate, &duplicate_scratch);
    try testing.expectEqual(jsonrpc.Kind.response, duplicate.kind);
    try testing.expect(duplicate.id != null);
    try testing.expectEqual(@as(i64, 99), duplicate.id.?.integer);
    try testing.expect(duplicate.result == null);
    try testing.expect(duplicate.rpc_error != null);
    try testing.expectEqual(@as(i32, -32602), duplicate.rpc_error.?.code);
    try testing.expect(bridge.isBindingFailure(duplicate.rpc_error.?.code, .outer));

    // The same pair once the first call answered, so the provider released it
    // and the caller's retry is served rather than refused again.
    try testing.expectEqual(@as(?i32, null), state.repeated.code);
    try testing.expectEqualStrings("{\"tools\":[{\"name\":\"echo\"}]}", state.repeated.inner);

    // A carried method the resolver does not carry is the tool's failure and
    // not the transport's, so the outer call succeeded and the failure is
    // inside its result. A caller that read the outer call alone would report
    // it as a success and never retry, and a caller that read the inner code
    // alone would see a number that is not a binding failure at this level.
    try testing.expectEqual(@as(?i32, null), state.refused.code);
    try testing.expect(state.refused.failed);
    try testing.expect(std.mem.indexOf(u8, state.refused.inner, "-32601") != null);
    try testing.expect(std.mem.indexOf(u8, state.refused.inner, "\"resources/list\"") != null);
    try testing.expect(!bridge.isBindingFailure(-32601, .inner));

    // The notification before it drew no frame, and the connection carried the
    // call after it. The count is its own, so this does not rest on the
    // foreign method's decline above: one frame arrived as a notification and
    // the provider answered it with nothing.
    try testing.expectEqual(@as(usize, 1), state.notifications);
    try testing.expectEqual(@as(?i32, null), state.after_notification.code);
    try testing.expectEqualStrings(
        "{\"tools\":[{\"name\":\"echo\"}]}",
        state.after_notification.inner,
    );
}

/// What the exchange proved, reported back after the group is joined.
///
/// Every slice borrows the caller's own buffers, which outlive the join, so
/// the test reads the bytes that came back rather than a copy of them.
const State = struct {
    /// Set by whichever task could not finish, so a failure surfaces as an
    /// assertion and not as a silently empty result.
    failed: bool = false,
    listed_result: []const u8 = "",
    refused_failed: bool = false,
    refused_has_result: bool = false,
    refused_error: []const u8 = "",
    /// The two outer refusals, in the order the caller made them. Both arrive
    /// as the same error, so the test tells them apart by the code and the
    /// flag rather than by the kind.
    refusals: [2]Refused = .{ .{}, .{} },
    /// The body a call carried out after both refusals, which is what says the
    /// connection outlived them.
    after_refusal: []const u8 = "",
    /// The carried calls the provider answered.
    answered: usize = 0,
};

/// One outer refusal, as the caller saw it, read after the group is joined.
const Refused = struct {
    /// What `call` returned. Null means the call went through, which is the one
    /// outcome this test does not accept for a call the provider refused.
    returned: ?anyerror = null,
    /// What the client recorded, or null when the peer did not refuse.
    refusal: ?Refusal = null,
    /// The body a provider that carried the call anyway brought back, which
    /// makes the exchange a failure rather than a refusal.
    carried: []const u8 = "",
};

/// A listening Unix socket, with the address that reaches it.
///
/// A Unix socket rather than a TCP port: there is no race over which port the
/// kernel handed out, so the test is deterministic under parallel runs, and
/// there is no port to leak when the process dies.
///
/// `Io.net.UnixAddress` borrows its path, so the path buffer belongs to the
/// caller and must outlive both halves. A path built in a helper's own frame
/// would be dead the moment the helper returned.
const Socket = struct {
    address: Io.net.UnixAddress,
    server: Io.net.Server,
    path: []const u8,
};

fn listenOn(io: Io, path_buffer: []u8, tag: u64) !Socket {
    const path = try std.fmt.bufPrint(
        path_buffer,
        "/tmp/zig-agent-proto-bridge-session-{x}.sock",
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

/// The provider the caller carries MCP calls to.
///
/// It answers `tools/list`, and it has no tools, so a carried `tools/call`
/// is a tool it does not have. Both answers go back inside a successful outer
/// `result`, which is the point: a provider that answered the second call
/// with an outer error would be testing the error path instead of this
/// binding. Two carried calls are refused on the outer message instead, one per
/// code space, because an outer refusal is a different failure and a caller
/// has to be able to tell it from the outcomes above.
const CarriedPeer = struct {
    state: *State,
    /// Separate from the connection's decode region, which `jsonrpc.decode`
    /// has already spent by the time the carried envelope is decoded. The
    /// escape offset a reader keeps is per reader and not per buffer, so a
    /// second decode into the same buffer starts at offset zero again.
    envelope_scratch: [1024]u8 = undefined,

    /// Runs inline on the reader task, so it answers and returns. It makes no
    /// call of its own: the reader is the only task on this side, so a call
    /// made here would wait for an answer that task cannot deliver.
    ///
    /// The two regions come from `conn.Conn`, which owns both and hands this
    /// handler one of each: the frame is decoded into `decode_scratch` and
    /// every frame below is composed in `answer`. An id a refusal echoes can
    /// carry a JSON escape, and a decoded id lives in `decode_scratch`, so one
    /// region for both would have the writer's first bytes land on the value
    /// it is about to read.
    fn handle(
        ctx: ?*anyopaque,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) conn.Error!?[]const u8 {
        const self: *CarriedPeer = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(frame, decode_scratch) catch return null;
        if (message.kind != .request) return null;
        const id = message.id orelse return null;
        const name = message.method orelse return null;
        // Another method is not this binding's, and answering it would put a
        // `mcp/message` answer on a call this provider never read.
        if (!std.mem.eql(u8, name.text, method)) return null;
        const params = switch (message.params) {
            .value => |text| text,
            else => return null,
        };
        // The carried envelope decodes off the wire, which is how the provider
        // tells the carried methods apart.
        const envelope = bridge.decodeEnvelope(params, &self.envelope_scratch, id) catch return null;

        // Two refusals on the outer message, one per code space. A carried
        // method this provider does not carry is what an ACP agent without the
        // binding answers, and a carried server it does not have is the
        // binding's own `server_registration_unavailable`. The connection that
        // carried either one is the caller's still.
        if (std.mem.eql(u8, envelope.inner_method, "resources/list")) {
            var refusal = json.Writer.init(answer);
            jsonrpc.encode(.{
                .kind = .response,
                .id = id,
                .rpc_error = .{ .code = -32601, .message = "method not found" },
            }, &refusal) catch return null;
            self.state.answered += 1;
            return refusal.written();
        }

        if (!std.mem.eql(u8, envelope.server_id, "project-tools:7a72")) {
            var refusal = json.Writer.init(answer);
            jsonrpc.encode(.{
                .kind = .response,
                .id = id,
                .rpc_error = .{ .code = -33001, .message = "unknown server" },
            }, &refusal) catch return null;
            self.state.answered += 1;
            return refusal.written();
        }

        const body: []const u8 = if (std.mem.eql(u8, envelope.inner_method, "tools/list"))
            "{\"result\":{\"tools\":[{\"name\":\"echo\"}]}}"
        else
            "{\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}";

        // `answer` belongs to this connection and lives for the length of the
        // write, so the frame can borrow it. Nothing the decode left in
        // `decode_scratch` is read after this point, and nothing here writes
        // there.
        var writer = json.Writer.init(answer);
        jsonrpc.encode(.{ .kind = .response, .id = id, .result = body }, &writer) catch return null;
        self.state.answered += 1;
        return writer.written();
    }
};

/// Accepts the one connection and leaves its reader to the group, so this
/// task has nothing left to do.
const ProviderTask = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    provider: *CarriedPeer,

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch return;
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = self.provider,
            .call = CarriedPeer.handle,
        }) catch {
            // The descriptor is released on that path, so the caller's next
            // call comes back instead of waiting for a reader that was never
            // started.
            self.provider.state.failed = true;
            return;
        };
    }
};

/// One outer answer, or the absence of one.
///
/// `code` is null when the peer answered with a result, and that is the
/// failure for every call the provider exchange expects to be refused.
const OuterAnswer = struct {
    code: ?i32 = null,
    /// Whether the binding allocates `code`. Only the level separates the two
    /// error spaces, so this flag is read at the outer message and nowhere
    /// else.
    binding: bool = false,
    /// The body the peer sent, borrowed from the result buffer it was read
    /// into.
    body: []const u8 = "",
};

/// One carried call's answer, split by which side of the boundary it landed
/// on.
///
/// A null `code` is a successful outer response, and `failed` then says
/// whether the inner outcome inside it is a failure. The two together are the
/// distinction the binding exists to keep, so no assertion reads one without
/// the other.
const Carried = struct {
    code: ?i32 = null,
    binding: bool = false,
    body: []const u8 = "",
    /// Whether the inner outcome is an MCP failure.
    failed: bool = false,
    /// The inner outcome as the agent reads it: the result, or the error
    /// object.
    inner: []const u8 = "",
};

/// What the provider exchange proved, read after the group is joined.
const Served = struct {
    /// Set by whichever task could not finish, so a failure surfaces as an
    /// assertion and not as a silently empty result.
    failed: bool = false,
    /// The step the caller was on when it could not finish. A flag on its own
    /// cannot tell a provider that refused the first case from one that
    /// refused the seventh.
    step: []const u8 = "connect",
    /// The error the caller returned, so the step and the reason arrive
    /// together instead of one run at a time.
    reason: ?anyerror = null,
    /// The first error `serve` returned inside the handler. Recorded because a
    /// handler that declines writes no frame, and a caller left waiting on one
    /// says nothing about why.
    handler_error: ?anyerror = null,
    /// Frames the provider composed and returned, so a run that stops short
    /// still shows how far it got.
    answered: usize = 0,
    /// Frames the provider answered nothing: a method that is not this
    /// binding's, and a notification.
    declined: usize = 0,
    /// Of those, the ones that arrived as notifications. Counted apart so the
    /// test can say the notification drew no frame rather than share one
    /// count with the foreign method.
    notifications: usize = 0,
    /// Resolver calls, one per carried request that reached the resolver.
    resolved: usize = 0,
    foreign: OuterAnswer = .{},
    no_params: OuterAnswer = .{},
    malformed: OuterAnswer = .{},
    unknown_server: OuterAnswer = .{},
    carried: Carried = .{},
    repeated: Carried = .{},
    refused: Carried = .{},
    after_notification: Carried = .{},
    /// The frame the nested call with an active pair brought back, borrowed
    /// from the provider's own buffer.
    duplicate: []const u8 = "",
};

/// Read one outer answer, or the absence of one.
fn readOuter(received: conn.Response) OuterAnswer {
    const code = received.error_code orelse return .{ .body = received.body };
    return .{
        .code = code,
        .binding = bridge.isBindingFailure(code, .outer),
        .body = received.body,
    };
}

/// Read one successful outer result as the inner outcome it carries.
///
/// An outer code is recorded instead, because a call the peer refused has no
/// inner outcome at all, and a caller that went looking for one there would be
/// reading a transport failure in the place a tool failure belongs.
fn readCarried(received: conn.Response, scratch: []u8) Error!Carried {
    if (received.error_code) |code| {
        return .{
            .code = code,
            .binding = bridge.isBindingFailure(code, .outer),
            .body = received.body,
        };
    }
    const outcome = try classifyOutcome(received.body, scratch);
    if (outcome.inner_error) |text| {
        return .{ .body = received.body, .failed = true, .inner = text };
    }
    return .{ .body = received.body, .inner = outcome.inner_result orelse "" };
}

/// The provider under test: every carried request goes to `Provider.serve`.
///
/// The resolver carries `tools/list` and nothing else, and it serves the pair
/// it is holding a second time on its first call, which is the only way one
/// reader can hold two calls for one pair.
const ServedPeer = struct {
    state: *Served,
    /// Built by the caller, because `init` needs a connection and the
    /// endpoint that holds one does not exist until the listener accepts.
    provider: Provider,
    /// Storage for the carried requests this provider serves at once, handed
    /// over where the peer itself lives so the pointer does not dangle. The
    /// provider never reads an entry before it claims it, so `undefined` is
    /// all the table needs.
    active: [4]Active = undefined,
    /// Separate from the connection's decode region, which `jsonrpc.decode`
    /// has already spent by the time the carried envelope is decoded. The
    /// escape offset a reader keeps is per reader and not per buffer, so a
    /// second decode into the same buffer starts at offset zero again.
    envelope_scratch: [1024]u8 = undefined,
    outcome_scratch: [2048]u8 = undefined,
    inner: [2048]u8 = undefined,
    out: [4096]u8 = undefined,
    /// The nested call's own buffers, because the outer call's escaped
    /// envelope is still live inside the resolver.
    nested_params: [1024]u8 = undefined,
    nested_envelope: [1024]u8 = undefined,
    nested_outcome: [1024]u8 = undefined,
    nested_inner: [1024]u8 = undefined,
    nested_out: [1024]u8 = undefined,
    /// Whether the nested call has happened.
    reentered: bool = false,

    /// Serve one carried request, and answer everything else as itself.
    ///
    /// The two regions come from `conn.Conn`, which owns both and hands this
    /// handler one of each: the frame is decoded into `decode_scratch` and the
    /// frame that answers it is composed in `answer`. `init` refuses a pair
    /// that shares a byte, so what this handler used to do is not something it
    /// can do now. It decoded into the region it then wrote its refusals into,
    /// and `conn.errorResponse` and `conn.methodNotFound` below filled the
    /// region the id they echo had been decoded into. An id carrying a JSON
    /// escape is scratch, so the writer's first bytes landed on the value it
    /// was about to read and the refusal went out echoing its own punctuation.
    /// Nothing reported it: the connection ran, the peer got a frame, and the
    /// frame was wrong.
    ///
    /// The refusals are what a live socket puts that to. "A provider answers
    /// each carried request on the side its failure belongs to" takes the
    /// foreign method through `methodNotFound` below and reads its `-32601`
    /// back off the wire, and `serve` reports a failure of its own into the
    /// same `answer`.
    fn handle(
        ctx: ?*anyopaque,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) conn.Error!?[]const u8 {
        const self: *ServedPeer = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(frame, decode_scratch) catch {
            self.state.declined += 1;
            return null;
        };
        // A message with no id has no answer to give, and PROTOCOLS.md 7 makes
        // the provider-to-agent direction one. This provider declines it, and
        // the connection writes nothing for a decline.
        if (message.kind != .request) {
            self.state.declined += 1;
            self.state.notifications += 1;
            return null;
        }
        const request: jsonrpc.Request = .{
            .id = message.id orelse return null,
            .method = message.method orelse return null,
            .params = message.params,
        };
        if (std.mem.eql(u8, request.method.text, method)) {
            const composed = self.provider.serve(
                request,
                .{ .ctx = self, .call = resolve },
                &self.envelope_scratch,
                &self.outcome_scratch,
                &self.inner,
                &self.out,
            ) catch |err| {
                // `serve` reports a short answer as `ResponseTooLarge`, and it
                // writes every frame through `conn.respond` and
                // `conn.errorResponse`, so that is the only fault of its own
                // that reaches here. A resolver that returns an error
                // propagates out of `serve` instead, and this peer has none.
                if (err == error.Transport) return error.Transport;
                if (err == error.ResponseTooLarge) return error.ResponseTooLarge;
                if (err == error.Framing) return error.Framing;
                // Record it and answer rather than declining. A handler that
                // declines writes no frame, so the caller waits for an answer
                // that will not come and the reason never reaches the test.
                self.state.handler_error = err;
                const refusal = try conn.errorResponse(request, .{
                    .code = -32603,
                    .message = "the provider could not serve the request",
                }, answer);
                return refusal;
            };
            if (composed != null) self.state.answered += 1;
            return composed;
        }

        // Another method is not this binding's, so this provider's own
        // dispatcher answers it. A `mcp/message` result here would tell the
        // caller this provider carried a request it never read.
        //
        // `request` borrows the frame or `decode_scratch`, and `answer` is a
        // region of its own, so the id this refusal echoes is still the
        // caller's id after the write. One region would have made the two the
        // same bytes.
        self.state.declined += 1;
        const refusal = try conn.methodNotFound(request, answer);
        return refusal;
    }

    /// Serve the pair this provider is holding a second time, under an outer
    /// id a proxy is free to have written.
    ///
    /// No resolver is passed, so a call that got this far would answer an
    /// inner `-32601` and the frame would carry no `-32602` to find. A provider
    /// that keyed its table on the outer id would serve this one, because the
    /// id differs, and that is the fault the pair rule exists to prevent.
    fn reenter(self: *ServedPeer, envelope: bridge.Envelope) Error!void {
        var writer = json.Writer.init(&self.nested_params);
        try bridge.encodeEnvelope(envelope, &writer);
        const nested: jsonrpc.Request = .{
            .id = .{ .integer = 99 },
            .method = jsonrpc.Method.split(method),
            .params = .{ .value = writer.written() },
        };
        const frame = try self.provider.serve(
            nested,
            .{},
            &self.nested_envelope,
            &self.nested_outcome,
            &self.nested_inner,
            &self.nested_out,
        );
        self.state.duplicate = frame orelse "";
    }
};

/// The MCP operations this provider carries: `tools/list`, and nothing else.
///
/// A [`Resolver`] callback and not a [`conn.Handler`], so the arity stays an
/// envelope and one buffer: the connection never hands this one a frame, a
/// decode region or an answer region, and `envelope` is already decoded by
/// the time it arrives.
fn resolve(ctx: ?*anyopaque, envelope: bridge.Envelope, out: []u8) Error!?bridge.Outcome {
    const self: *ServedPeer = @ptrCast(@alignCast(ctx.?));
    self.state.resolved += 1;
    if (!self.reentered) {
        self.reentered = true;
        try self.reenter(envelope);
    }
    if (!std.mem.eql(u8, envelope.inner_method, "tools/list")) return null;
    const body = "{\"tools\":[{\"name\":\"echo\"}]}";
    if (out.len < body.len) return error.BufferTooSmall;
    @memcpy(out[0..body.len], body);
    return .{ .result = .{ .text = out[0..body.len] } };
}

/// Accepts the one connection and leaves its reader to the group, so this
/// task has nothing left to do.
const ServedTask = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    peer: *ServedPeer,

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch return;
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = self.peer,
            .call = ServedPeer.handle,
        }) catch {
            // As above: no connection means no pump to notice the peer hanging
            // up, so `open` released the descriptor itself.
            self.peer.state.failed = true;
            return;
        };
        // The connection exists only once `open` built it, and the group's
        // task does not run until the group is awaited. Nothing in `serve`
        // reads this field, so the write cannot race with a frame the pump
        // routes here.
        self.peer.provider.connection = &self.endpoint.connection;
    }
};

/// Carries one of each message a carried request can fail on, over one
/// connection, and records which side of the boundary each answer landed on.
const ServedCaller = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    state: *Served,

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch |err| {
            self.state.failed = true;
            self.state.reason = err;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null) catch |err| {
            self.state.failed = true;
            self.state.reason = err;
            return;
        };
        self.exchange() catch |err| {
            self.state.failed = true;
            self.state.reason = err;
        };
        self.endpoint.hangUp(self.io);
    }

    fn exchange(self: *@This()) Error!void {
        const state = self.state;
        const side = &self.endpoint.side;
        const connection = &self.endpoint.connection;

        // A method that is not this binding's. The provider's own dispatcher
        // answers it, so the code is the peer's and not the binding's, and
        // the resolver was never reached.
        state.step = "a method that is not this binding's";
        state.foreign = readOuter(try connection.call(
            "session/new",
            null,
            &side.result,
            &side.out,
        ));

        // A `mcp/message` with no params at all. There is no envelope to
        // decode, so the refusal is the binding's and rides on the outer
        // message.
        state.step = "a mcp/message with no params";
        state.no_params = readOuter(try connection.call(
            method,
            null,
            &side.second_result,
            &side.out,
        ));

        // A params object that is not an envelope: `requestId` and `method`
        // are both missing. Same code, and it reaches the peer the same way.
        state.step = "a params object that is not an envelope";
        state.malformed = readOuter(try connection.call(
            method,
            "{\"serverId\":\"project-tools:7a72\"}",
            &side.third_result,
            &side.out,
        ));

        // A server the provider never declared, over an envelope this file
        // encoded itself.
        state.step = "a server the provider never declared";
        state.unknown_server = readOuter(try self.carry(
            "project-tools:0000",
            "req-1",
            "tools/list",
            null,
            &side.fourth_result,
        ));

        // A carried request this provider serves. Its resolver serves the same
        // pair once more under another outer id, which is what the duplicate
        // rule has to catch.
        state.step = "a carried tools/list, with the duplicate pair re-entered";
        state.carried = try readCarried(try self.carry(
            "project-tools:7a72",
            "req-1",
            "tools/list",
            null,
            &side.fifth_result,
        ), &side.outcome_scratch);

        // The same pair once the first call answered, so the provider
        // released it.
        state.step = "the same pair a second time";
        state.repeated = try readCarried(try self.carry(
            "project-tools:7a72",
            "req-1",
            "tools/list",
            null,
            &side.result,
        ), &side.second_outcome_scratch);

        // A carried method the resolver does not carry, on a pair of its own.
        state.step = "a carried method the resolver does not carry";
        state.refused = try readCarried(try self.carry(
            "project-tools:7a72",
            "req-2",
            "resources/list",
            null,
            &side.second_result,
        ), &side.third_outcome_scratch);

        // A `mcp/message` notification draws no frame at all, because a
        // message with no id has no answer to give and this direction is one.
        state.step = "the mcp/message notification";
        var notification_writer = json.Writer.init(&side.envelope);
        try bridge.encodeEnvelope(.{
            .server_id = "project-tools:7a72",
            .request_id = "req-2",
            .inner_method = "tools/list",
            .inner_params = null,
            // A notification is the other direction of the binding, and the
            // direction is not a member of the params object either way.
            .direction = .provider_to_agent,
        }, &notification_writer);
        try connection.notify(method, notification_writer.written(), &side.out);

        // And the connection carried the call after it, so the notification
        // cost a frame the provider read and nothing more.
        state.step = "the call after the notification";
        state.after_notification = try readCarried(try self.carry(
            "project-tools:7a72",
            "req-2",
            "tools/list",
            null,
            &side.third_result,
        ), &side.outcome_scratch);
    }

    /// Send one carried request and wait for its answer.
    ///
    /// The envelope goes out through the connection rather than through
    /// `Client`, because two of the messages this exchange sends are ones
    /// `Client` cannot build: a `mcp/message` with no params at all, and a
    /// params object that is not an envelope.
    fn carry(
        self: *@This(),
        server_id: []const u8,
        request_id: []const u8,
        inner_method: []const u8,
        params: ?[]const u8,
        result: []u8,
    ) Error!conn.Response {
        var writer = json.Writer.init(&self.endpoint.side.envelope);
        try bridge.encodeEnvelope(.{
            .server_id = server_id,
            .request_id = request_id,
            .inner_method = inner_method,
            .inner_params = params,
            .direction = .agent_to_provider,
        }, &writer);
        return self.endpoint.connection.call(
            method,
            writer.written(),
            result,
            &self.endpoint.side.out,
        );
    }
};

/// Carries five calls over one connection and records what each one answered.
const Caller = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    state: *State,

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch {
            self.state.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null) catch {
            self.state.failed = true;
            return;
        };
        self.exchange() catch {
            self.state.failed = true;
        };
        // Hangs up last, so the exchange is over before the peer's reader
        // sees end of file.
        self.endpoint.hangUp(self.io);
    }

    fn exchange(self: *@This()) Error!void {
        const side = &self.endpoint.side;
        var client = Client.init(&self.endpoint.connection);

        // A carried `tools/list`. The inner MCP answer is a result, so the
        // outer `result` body is a success and reads as one.
        const listed = try client.call(
            "project-tools:7a72",
            "req-1",
            "tools/list",
            null,
            &side.result,
            &side.out,
            &side.envelope,
        );
        const listed_outcome = try classifyOutcome(listed, &side.outcome_scratch);
        if (listed_outcome.inner_error != null) self.state.failed = true;
        self.state.listed_result = listed_outcome.inner_result orelse "";

        // A carried `tools/call` for a tool the provider does not have. The
        // outer call still succeeds, `call` returns the outer `result` body
        // either way, and the inner error is visible only once that body is
        // read.
        const refused = try client.call(
            "project-tools:7a72",
            "req-2",
            "tools/call",
            "{\"name\":\"missing\"}",
            &side.second_result,
            &side.out,
            &side.envelope,
        );
        const refused_outcome = try classifyOutcome(refused, &side.second_outcome_scratch);
        self.state.refused_failed = refused_outcome.failed();
        self.state.refused_has_result = refused_outcome.inner_result != null;
        self.state.refused_error = refused_outcome.inner_error orelse "";

        // Two carried calls the provider refuses on the outer message, one per
        // code space. Both are recorded the same way, because the binding
        // reports both the same way, and the connection survives both.
        const refusals = [_]struct {
            server_id: []const u8,
            request_id: []const u8,
            method: []const u8,
            answer: []u8,
        }{
            // A peer that does not implement `mcp/message` answers `-32601`.
            .{
                .server_id = "project-tools:7a72",
                .request_id = "req-3",
                .method = "resources/list",
                .answer = &side.third_result,
            },
            // A server the provider does not have is the binding's own
            // `server_registration_unavailable`, which PROTOCOLS.md 7 puts on
            // the outer message as `-33001`.
            .{
                .server_id = "project-tools:0000",
                .request_id = "req-4",
                .method = "tools/list",
                .answer = &side.fourth_result,
            },
        };
        for (refusals, 0..) |refusal, index| {
            const carried = client.call(
                refusal.server_id,
                refusal.request_id,
                refusal.method,
                null,
                refusal.answer,
                &side.out,
                &side.envelope,
            ) catch |err| {
                self.state.refusals[index] = .{
                    .returned = err,
                    .refusal = client.refusal,
                };
                continue;
            };
            // A provider that carried a call it was asked to refuse refused
            // nothing, so this exchange proves the opposite of what the test
            // claims.
            self.state.failed = true;
            self.state.refusals[index].carried = carried;
        }

        // The same connection, one call after both refusals. A caller that
        // read either as a dead transport would have torn this down and
        // reconnected, and the peer refuses the same carried calls on the new
        // connection too.
        self.state.after_refusal = client.call(
            "project-tools:7a72",
            "req-5",
            "tools/list",
            null,
            &side.fifth_result,
            &side.out,
            &side.envelope,
        ) catch {
            self.state.failed = true;
            return;
        };
    }
};

/// The buffers one side needs, all caller-owned, so the test cannot hide an
/// allocation behind the binding.
const Side = struct {
    frame_buffer: [4096]u8 = undefined,
    pending: [4]conn.Slot = undefined,
    decode_scratch: [1024]u8 = undefined,
    /// Where a handler composes the frame it returns, and its own region: the
    /// connection hands it over per call and overwrites it for the next one.
    /// Separate from `decode_scratch` because a handler decodes into one and
    /// writes into the other, and `init` refuses a pair that shares a byte.
    answer: [2048]u8 = undefined,
    /// The envelope `call` builds, the bytes it puts on the wire, and the
    /// answer it reads back.
    envelope: [1024]u8 = undefined,
    out: [1024]u8 = undefined,
    result: [1024]u8 = undefined,
    outcome_scratch: [1024]u8 = undefined,
    /// The second call gets its own answer buffers. An outcome borrows the
    /// body it was read from, so one shared result buffer would leave the
    /// first answer pointing at bytes the second call overwrote.
    second_result: [1024]u8 = undefined,
    second_outcome_scratch: [1024]u8 = undefined,
    /// The two refusals and the call after them keep their own buffers for the
    /// same reason: the test reads what each of them brought back after the
    /// join.
    third_result: [1024]u8 = undefined,
    fourth_result: [1024]u8 = undefined,
    fifth_result: [1024]u8 = undefined,
    /// A third outcome scratch, because an outcome borrows the body it was
    /// read from and the provider exchange keeps three of them alive across
    /// the join.
    third_outcome_scratch: [1024]u8 = undefined,
};

/// One end of the connection: the buffers, and the connection over them.
const Endpoint = struct {
    side: Side = .{},
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned.
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    stream: Io.net.Stream = undefined,
    connection: conn.Conn = undefined,
    /// Set once this side's descriptor is closed, by `hangUp` or by the pump,
    /// so neither path closes it twice.
    released: bool = false,

    /// Open a side over `stream`, or report why there is no connection to
    /// open.
    ///
    /// `init` refuses a region with no room and a pair that shares a byte, and
    /// both are wiring faults in this file rather than conditions a run can
    /// hit. The descriptor is released on that path, because no pump runs
    /// without a connection and the peer would otherwise sit on a read that
    /// never returns.
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
        self.connection = conn.Conn.init(io, &self.reader.interface, &self.writer.interface, .{
            .frame_buffer = &self.side.frame_buffer,
            .pending = &self.side.pending,
            .decode_scratch = &self.side.decode_scratch,
            .answer = &self.side.answer,
        }) catch |err| {
            self.hangUp(io);
            return err;
        };
        if (handler) |h| self.connection.setHandler(h);
        // Spawned on the group the test joins, because `Io.Group.async` does
        // not promise to run its task until the group is awaited or cancelled.
        group.async(io, Endpoint.pump, .{self});
    }

    /// Hang up. `shutdown` before `close`: closing a descriptor does not
    /// interrupt a read already blocked on it, so the peer's pump would sit on
    /// an open description and the group would never finish.
    fn hangUp(self: *Endpoint, io: Io) void {
        self.released = true;
        self.stream.shutdown(io, .both) catch {};
        self.stream.close(io);
    }

    /// Pump until the peer hangs up, then release the descriptor.
    ///
    /// The accepted side has no caller to hang up on its behalf, so nothing
    /// else closes it and the process would release it at exit instead. Close
    /// alone is right here, because the read has already returned and no
    /// reader is left blocked on it. A descriptor `hangUp` released is left
    /// alone, because that path closed it already.
    fn pump(self: *Endpoint) void {
        self.connection.pump();
        if (self.released) return;
        self.released = true;
        self.stream.close(self.connection.io);
    }
};
