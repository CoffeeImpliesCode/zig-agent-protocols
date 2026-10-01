//! The ACP session: a client and an agent on top of [`conn.Conn`].
//!
//! The connection knows JSON-RPC. This knows that ACP has two wire versions
//! whose method registries, capability spellings and permission request shapes
//! are related by no conversion the specification provides, and that the v1 and
//! v2 `session/request_permission` requests share no required member. So a
//! session is *pinned* to one [`acp.WireVersion`] for its whole life, and the
//! version is never inferred from a payload.
//!
//! ## What a session adds over the connection
//!
//! - **The version.** `initialize` is where it is settled and the answer
//!   decides the shape of everything after it. A client that cannot speak what
//!   the agent returned is told so, rather than handed a session pinned to a
//!   version it does not implement.
//! - **Capability gating.** PROTOCOLS.md 6.5 makes omission mean unsupported, so
//!   a gated method whose capability the peer never advertised is refused here.
//!   The caller learns it can fix that without a round trip, and a peer on
//!   another version is not asked to answer for a registry it never had.
//! - **Arity and side.** A notification is never sent as a request, a client
//!   method is never called by a client, and a method the *other* version
//!   removed is `error.MethodNotInVersion` rather than a name on the wire.
//!
//! ## The safety rule, and how it is made structural
//!
//! PROTOCOLS.md 6.6 carries the sharpest clause in ACP: an agent that receives
//! a permission outcome it does not understand **MUST NOT** treat it as
//! approval. Two halves of this file exist so that neither side of the exchange
//! can end up approving by accident, and neither is a rule the caller has to
//! remember:
//!
//! - **Answering** takes a [`PermissionAnswer`], a union with two arms. There is
//!   no `.approved`, no `.default` and no "carry on" arm, so there is no value a
//!   policy can return that means consent without a caller having chosen an
//!   option. [`autoDecide`] turns "no decision" into
//!   [`PermissionAnswer.cancelled`], because doing nothing is not a decision and
//!   the two must not be the same thing. [`answerPermission`] then checks the
//!   chosen id against the options *this* request offered, so an id carried over
//!   from another request answers nothing.
//!   [`answerPermissionRequest`] is the other door to the same answer, and it
//!   takes a [`ReadableOutcome`] rather than an option id: a decision, not a
//!   choice. A decision that grants names no option, and the `selected` outcome
//!   the specification states does, so that answer goes out as a refusal rather
//!   than as an approval. Consent still needs an option the user was shown.
//! - **Receiving** returns a [`PermissionDecision`], a union whose third arm is
//!   `unreadable`. An outcome this library cannot read never becomes
//!   `grants = true`: it becomes `unreadable`, carrying the decode error, and a
//!   two-arm `switch` over `grants` and `cancelled` does not compile against it.
//!   A wildcard arm is the agent's explicit decision to stop, which is the only
//!   decision 6.6 leaves it. [`Agent.requestPermission`] does the whole of that
//!   in one call: it sends the request the agent holds and reads the answer
//!   against that same request, so the option ids on the wire are the ids the
//!   answer is checked against. [`PermissionDecision.readable`] then takes the
//!   arms an agent may act on out as a [`ReadableOutcome`], which has no
//!   `unreadable` arm at all. That is the same rule the two-arm `switch`
//!   already enforces, stated once more in the type of an answer: an outcome
//!   this library could not read has no way to become the argument of
//!   [`answerPermissionRequest`], so the refusal 6.6 requires is a compile
//!   error rather than a check a caller might forget.
//!
//! The two directions are deliberately not symmetrical in what they refuse. The
//! answering side may name an option whose `kind` is a v2 catch-all, because the
//! caller offered that option to the user and knows what its button means. The
//! receiving side may not, because there `grants` is the one thing a peer must
//! not be trusted to imply.
//!
//! ## Batch arrays: this session declines them
//!
//! PROTOCOLS.md 6.2 records that v2 *permits* JSON-RPC batch arrays. This session
//! does not accept one, at either version, and [`accepts_batches`] is the single
//! place that says so.
//!
//! Three reasons, in the order they bind:
//!
//! 1. [`conn.Conn`] correlates one answer to one call by integer id inside one
//!    frame. A batch reply array carries N responses in a single frame, and the
//!    reader has no way to route them. Supporting it would mean copying the frame
//!    out of the framer buffer, which is the one allocation that layer refuses,
//!    and the framer buffer is the reader's only copy.
//! 2. The v2 batch rules require per-entry fan-out: a Response for each Request,
//!    none for a Notification, in any order, with an empty array answered by a
//!    single `Invalid Request` and an invalid entry answered on its own without
//!    failing the batch. None of that is a byte-copy change.
//! 3. The same table says clients and agents **SHOULD NOT** batch `initialize`,
//!    `auth/login`, `authenticate`, `session/new`, `session/resume` or
//!    `session/prompt`, which is the whole lifecycle of a session. A conforming
//!    peer loses nothing by never needing a batch.
//!
//! So a batch frame is *refused loudly* rather than dropped: [`classifyFrame`]
//! tells a transport to answer it with the specification's own `Invalid Request`,
//! which is observable to the peer. Letting `conn.Conn` fail to decode the frame
//! and discard it would leave a peer waiting for an answer that was already
//! refused, which is the one failure mode worse than an error.
//!
//! "Observable to the peer" is the whole claim, so it is carried the whole way.
//! The id of a refusal is `null`, which is what JSON-RPC 2.0 requires where the
//! id could not be determined from the Request, and `jsonrpc` reads that frame
//! back rather than refusing it as a value of the wrong type for an id. That
//! matters because `conn.Conn` decodes every inbound frame before it knows
//! whether anything will be matched against it: a codec that dropped the
//! refusal would have this library's own connection drop it, and the peer that
//! wrote it would never learn what became of the frame it sent.
//!
//! ## Allocating
//!
//! `ARCHITECTURE.md` section 4 lets the runtime allocate where state is
//! genuinely dynamic. A session holds none: every buffer, including the
//! capability path list, is the caller's.

const std = @import("std");
const acp = @import("acp.zig");
const conn = @import("conn.zig");
const framing = @import("framing.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const root = @import("root.zig");

const Io = std.Io;

pub const Error = error{
    /// The method is not in the pinned version's registry at all, so the other
    /// version removed it or never had it.
    ///
    /// Reported before the wire rather than as a remote `-32601`, because the
    /// caller can fix it without a round trip and a peer on another version may
    /// well still accept it.
    MethodNotInVersion,
    /// The method is on the other side of the exchange. A client calling a
    /// client method is a bug, and sending it would make the peer wait for an
    /// answer to a request it did not make.
    WrongSide,
    /// The method expects the other arity: a request sent as a notification
    /// leaves the caller waiting forever, and a notification sent as a request
    /// makes the peer answer a message that expected nothing.
    WrongArity,
    /// The method is gated on a capability the peer did not advertise, or on an
    /// `authMethods` array that is empty.
    ///
    /// PROTOCOLS.md 6.5 makes omission mean unsupported, so this is also the
    /// answer before `initialize` has run: an empty path list supports exactly
    /// the ungated methods.
    NotPermitted,
    /// The caller's `params` is not a JSON object, so nothing was sent.
    ///
    /// ACP params are objects in every version. Omitting the member instead
    /// would hand the peer a request the caller never wrote, so a non-object
    /// is refused here rather than framed without it.
    ParamsNotAnObject,
    /// An `initialize` the pinned version cannot express: v2 requires `info`
    /// and no other member carries it.
    MissingInfo,
    /// A permission answer named an option the request did not offer.
    ///
    /// The option list is the only place a permission was ever defined, so an id
    /// from anywhere else answers nothing.
    UnknownPermissionOption,
    /// A v2 permission request whose `subject` type this library does not model.
    ///
    /// The members a v2 catch-all carries are opaque here, so params built from
    /// one would ask the user about something other than what the agent meant.
    /// Refused rather than truncated, and nothing was sent. An agent that holds
    /// the full text sends it with [`Agent.request`] instead.
    SubjectNotModelled,
    /// A v2 command subject whose `cwd` is not an absolute path.
    ///
    /// `acp.decodePermissionSubject` refuses one with `error.InvalidField`, so
    /// writing it would put a request on the wire that this library's own
    /// decoder throws away. PROTOCOLS.md 6.6 requires the path to be absolute
    /// because a relative one resolves against whatever working directory the
    /// process that runs the command happens to have, so the user approving a
    /// command in one directory would approve it in another. Refused here for
    /// that reason, and nothing is sent.
    CwdNotAbsolute,
    /// The body a peer returned is not a value this layer can read. An
    /// `initialize` result without a usable `protocolVersion` lands here: there
    /// is no version to pin, and inventing one is what the pin exists to stop.
    NotAResult,
    /// A caller-supplied buffer was too small. Every builder here reports the
    /// failure rather than returning the bytes it managed to emit, so a short
    /// buffer can never leave a half-written approval in the caller's memory.
    BufferTooSmall,
} || conn.Error;

// --- Batch policy -------------------------------------------------------------

/// Whether this session accepts a JSON-RPC batch array.
///
/// False at every version, for the reasons in the module doc. This is a
/// statement about this session and not about ACP: `acp.permitsBatch` reports
/// what the specification allows and returns true at v2. The two are allowed to
/// disagree, and a transport obeys this one.
pub const accepts_batches = false;

/// What a transport must do with one frame.
pub const FrameAction = enum {
    /// A single JSON-RPC object. Hand it to the connection.
    dispatch,
    /// A batch array. Report `Invalid Request` with a null id, which is what the
    /// v2 batch rules require for an array this peer must not have sent.
    refuse_batch,
    /// A value that parsed and is not an object: `null`, `42`, `"hi"`, `true`.
    /// Report `Invalid Request` with a null id.
    ///
    /// Its own arm because PROTOCOLS.md 3.1 draws the line at what the peer
    /// sent rather than at the first byte: `-32700` is for a peer that sent
    /// invalid JSON, `-32600` is for one that sent valid JSON which is not a
    /// request object. A peer that sent `null` had its bytes read, and telling
    /// it its JSON was malformed would be a claim about its encoding that this
    /// layer has no way to make.
    refuse_request,
    /// Neither an object, an array, nor JSON at all. Report `Parse error` with
    /// a null id.
    refuse_parse,
};

/// What one frame holds, as this session reads it.
///
/// Version-independent on purpose: at v1 a batch is not a value the protocol has,
/// and at v2 it is a value this session declines, and the answer to "what do I
/// put on the wire" is the same byte string either way. A caller that wants the
/// specification's opinion as well has `acp.permitsBatch`.
pub fn classifyFrame(frame: []const u8) FrameAction {
    const trimmed = std.mem.trim(u8, frame, " \t\r\n");
    if (trimmed.len == 0) return .refuse_parse;
    switch (trimmed[0]) {
        '{' => return .dispatch,
        // Read from the constant rather than spelled out here, so the one
        // place that says what this session accepts and the answer it gives a
        // batch frame cannot drift apart when the constant is flipped.
        '[' => return if (accepts_batches) .dispatch else .refuse_batch,
        else => {},
    }
    // An object and an array are decided on the first byte, because either is
    // answered whatever else it holds. Every other frame has to be read to know
    // which of the two refusals it is, and reading it is the only way `null`
    // and `not json` come apart.
    //
    // No scratch is needed and none is taken, because `skipValue` writes none:
    // a skipped value produces no slice, so a frame of any width is decided
    // without a buffer. What follows the value is not part of it, which is what
    // `atEnd` is asked about.
    const no_scratch: [0]u8 = .{};
    var reader = json.Reader.init(trimmed);
    reader.skipValue(&no_scratch) catch return .refuse_parse;
    return if (reader.atEnd()) .refuse_request else .refuse_parse;
}

/// The JSON-RPC error body a transport sends for a frame it refused.
///
/// The id is `null`, and that is not a shape this library writes anywhere else.
/// JSON-RPC 2.0 requires Null for the id of an error response whose id could
/// not be determined from the Request, which is what all three of these are: a
/// batch array, a value that is not an object, and a frame that is not JSON.
/// None of them is a request, so none of them has an id to answer on.
///
/// `jsonrpc.decode` reads these bytes back, and that is not a formality. A
/// refusal this library could not decode would be invisible to a peer running
/// this library: `conn.Conn` decodes every inbound frame before it knows
/// whether anything will be matched against it, and a frame it cannot decode
/// is dropped, because there is no id to answer on and nothing to send. The
/// codec accepts a `null` id on a response carrying an `error` and nowhere
/// else, and `conn.Conn.setOrphanHandler` is where such a frame is told rather
/// than dropped. That hook is the connection's only report for a response that
/// matched no outstanding call, and this refusal is one of the three frames
/// that reach it: a `null` id, an id this connection never allocated, and an id
/// naming a call that has already returned.
///
/// A builder cannot produce this one. Every other answer in the tree is an
/// answer to a `jsonrpc.Request`, and a frame that is a batch, a value that is
/// not an object, or is not JSON at all is not one.
pub fn refusalBody(action: FrameAction, out: []u8) root.EncodeError![]const u8 {
    const code: []const u8, const message: []const u8 = switch (action) {
        .dispatch => return error.InvalidField,
        // The same answer for both, and PROTOCOLS.md 3.1 is what says so: a
        // batch array this session declines and a value that is not an object
        // are both valid JSON that is not a request object.
        .refuse_batch, .refuse_request => .{ "-32600", "Invalid Request" },
        .refuse_parse => .{ "-32700", "Parse error" },
    };
    var writer = json.Writer.init(out);
    try writer.slice("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":");
    try writer.slice(code);
    try writer.slice(",\"message\":");
    try writer.string(message);
    try writer.slice("}}");
    return writer.written();
}

// --- Gating -------------------------------------------------------------------

/// Whether a call expects an answer.
pub const Shape = enum {
    /// An `id`, and a `result` or an `error` in return.
    request,
    /// No `id` and no answer, as JSON-RPC 2.0 defines a notification.
    notification,
};

/// Check a method against a version's registry, gates, side and arity.
///
/// Exposed on its own because the gate is worth deciding without a connection,
/// and because a caller assembling a dispatch table wants the same answer this
/// layer would give.
///
/// `target` is the side the method *lives on*, which is how the registries spell
/// it: an `agentMethods` entry is called by the client on the agent, so a client
/// passes `.agent`, and a `clientMethods` entry is the other way round. A method
/// marked `.protocol` is on neither side and is callable from either, which is
/// what `x-side: "protocol"` on `$/cancel_request` means.
///
/// `advertised` is the dotted capability paths the peer sent in `initialize`, and
/// an empty list is a peer that advertised nothing, which PROTOCOLS.md 6.5 makes
/// mean unsupported for every gated method. `auth_methods` is whether the peer
/// sent a non-empty `authMethods` array, which is what gates `auth/login` and
/// `auth/logout` at v2.
pub fn checkCall(
    version: acp.WireVersion,
    method: []const u8,
    shape: Shape,
    target: acp.Side,
    advertised: []const []const u8,
    auth_methods: bool,
) Error!acp.MethodInfo {
    const info = acp.lookupMethod(version, method) catch return error.MethodNotInVersion;
    // The registry's side is the method's own, so a mismatch means the caller
    // reached for a method the other side owns. Sending it would make the peer
    // wait for an answer to a request it did not make.
    if (info.side != .protocol and info.side != target) return error.WrongSide;
    // `notification` and "expects an answer" are the same fact, so a mismatch is
    // a mismatch. A request on a notification name would wait forever for an
    // answer the peer will never send.
    if (info.notification == (shape == .request)) return error.WrongArity;
    if (info.conditional_on_auth_methods and !auth_methods) return error.NotPermitted;
    if (!acp.isMethodSupported(info, advertised)) return error.NotPermitted;
    return info;
}

/// Collect the dotted paths of a decoded capability set into caller storage.
///
/// A convenience, because the entries a caller decoded with
/// `acp.decodeCapabilityObject` name their paths in exactly the spelling a gate
/// uses, and a session stores the path list rather than the entries: the entries
/// come out of caller buffers of three different sizes, and keeping all of them
/// alive to answer a gate is a cost no gate needs.
pub fn capabilityPaths(
    set: acp.CapabilitySet,
    out: [][]const u8,
) Error![]const []const u8 {
    if (set.entries.len > out.len) return error.BufferTooSmall;
    for (set.entries, 0..) |entry, index| out[index] = entry.path;
    return out[0..set.entries.len];
}

// --- The client side ----------------------------------------------------------

/// A client bound to one negotiated wire version.
pub const Client = struct {
    connection: *conn.Conn,
    /// The version this session speaks. Set by `init` to the version the client
    /// asks for, and replaced by the one the agent answered with, so every later
    /// call is checked against what the two sides actually agreed on.
    version: acp.WireVersion,
    /// The agent's advertised capability paths, as produced by
    /// [`capabilityPaths`]. `initialize` does not fill this in: it reports the
    /// agent's capability object in [`Handshake.capabilities`] and leaves the
    /// recording to [`setAgentCapabilities`], because the paths a client keeps
    /// are the caller's own. Empty means every gated method is refused.
    agent_capabilities: []const []const u8 = &.{},
    /// Whether the agent advertised a non-empty `authMethods`, which is what
    /// makes `auth/login` and `auth/logout` callable at v2.
    auth_methods: bool = false,
    /// The capability paths *this* client advertised in its own `initialize`
    /// request, as produced by [`capabilityPaths`]. Used only to decide what the
    /// agent may call here, so a client never answers a method whose capability
    /// it never claimed.
    client_capabilities: []const []const u8 = &.{},

    pub fn init(connection: *conn.Conn, version: acp.WireVersion) Client {
        return .{ .connection = connection, .version = version };
    }

    /// The version number for the wire.
    pub fn versionNumber(self: Client) u16 {
        return self.version.number();
    }

    /// Record the capability paths the agent advertised.
    ///
    /// Borrowed: the slices must outlive the session. Pass the result of
    /// [`capabilityPaths`] over the entries decoded from the `initialize`
    /// response and keep both.
    pub fn setAgentCapabilities(self: *Client, paths: []const []const u8) void {
        self.agent_capabilities = paths;
    }

    /// Record the capability paths this client advertised.
    ///
    /// Borrowed: the slices must outlive the session. Pass the result of
    /// [`capabilityPaths`] over the entries decoded from the same capability
    /// object the client sent in `initialize`.
    pub fn setClientCapabilities(self: *Client, paths: []const []const u8) void {
        self.client_capabilities = paths;
    }

    /// Call an agent method, gated locally.
    ///
    /// The error code stays on the reply rather than becoming a Zig error: the
    /// ACP binding has its own error codes (PROTOCOLS.md section 7), a caller
    /// usually wants the message, and collapsing "the peer answered with an
    /// error" into a Zig error would make a remote `-32601` and a local
    /// `error.NotPermitted` indistinguishable at the call site.
    pub fn request(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
    ) Error!conn.Response {
        _ = try self.gate(method, .request);
        const answer = try self.connection.call(method, try requireObject(params), result, out);
        return .{ .body = answer.body, .error_code = answer.error_code };
    }

    /// Notify an agent method, gated locally.
    pub fn notify(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        out: []u8,
    ) Error!void {
        _ = try self.gate(method, .notification);
        return self.connection.notify(method, try requireObject(params), out);
    }

    /// Run the `initialize` handshake and pin the session to its outcome.
    ///
    /// `requested` is the highest version the client supports, and it decides the
    /// request's shape: at v2 `info` is required, at v1 `clientInfo` is optional.
    /// `info` and `capabilities` are the caller's own JSON objects.
    ///
    /// On success the session's `version` is the version the agent answered with,
    /// so a client that asked for v2 and got v1 does not go on calling v2 method
    /// names. `Handshake.version` is null when the agent answered with an error or
    /// with a version this library does not implement; check `error_code` first,
    /// and treat a null `version` with a null `error_code` as PROTOCOLS.md 6.1
    /// rule 3 says to: a client that cannot speak the returned version SHOULD
    /// disconnect.
    ///
    /// The capability object is read out of the answer under the name the
    /// *answered* version spells, so a downgrade the specification allows is
    /// read in the version it was answered in. A `scratch` too small to
    /// unescape a key of the answer is `error.BufferTooSmall` and not
    /// `error.NotAResult`, because the agent sent a version and the fault is
    /// the caller's buffer.
    pub fn initialize(
        self: *Client,
        requested: u16,
        info: ?[]const u8,
        capabilities: ?[]const u8,
        result: []u8,
        out: []u8,
        params_out: []u8,
        scratch: []u8,
    ) Error!Handshake {
        const asked = acp.WireVersion.fromNumber(requested) orelse
            return error.MethodNotInVersion;
        // Gated against the version being *asked for*, not the one currently
        // pinned: the two differ only on the very call that changes the pin, and
        // a session that checked against its stale pin would be deciding the
        // handshake with a version the handshake is about to replace.
        _ = try checkCall(asked, "initialize", .request, .agent, &.{}, false);

        const params = try initializeParams(asked, requested, info, capabilities, params_out);
        const answer = try self.connection.call("initialize", params, result, out);
        if (answer.error_code != null) {
            // The agent refused, so nothing was agreed and the refusal is
            // reported rather than a version invented for it. The session's own
            // pin is untouched and still holds the version `init` was given, so
            // a caller that goes on using this session sends that version's
            // method names to an agent that agreed to nothing: the null
            // `version` here is the only thing that says so, and the caller
            // must check it before the first call.
            return .{
                .version = null,
                .body = answer.body,
                .error_code = answer.error_code,
                .capabilities = null,
                .auth_methods = false,
            };
        }

        return readHandshake(self, answer, scratch);
    }

    /// The gate check this session applies, exposed so a caller can ask whether a
    /// call would be refused before it spends a buffer on it.
    pub fn gate(self: Client, method: []const u8, shape: Shape) Error!acp.MethodInfo {
        return checkCall(
            self.version,
            method,
            shape,
            .agent,
            self.agent_capabilities,
            self.auth_methods,
        );
    }

    /// Whether this client serves a method the agent called.
    ///
    /// The inbound direction, so the gate is the capability *this* client
    /// advertised. A client that never records them serves the ungated methods
    /// only, and every gated client method is refused rather than answered on a
    /// capability the client never claimed.
    ///
    /// `shape` is the arity of the frame that arrived, which a dispatcher reads
    /// off its id. PROTOCOLS.md 6.3 and 6.4 register `session/update` and
    /// `elicitation/complete` as client methods that are notifications, and
    /// `$/cancel_request` as a notification from either side, so asking about
    /// them as requests refuses every frame the protocol sends them on. The
    /// same question [`Client.gate`] answers on the outbound side, and this is
    /// that question on the inbound one.
    pub fn accepts(self: Client, method: []const u8, shape: Shape) bool {
        _ = checkCall(
            self.version,
            method,
            shape,
            .client,
            self.client_capabilities,
            true,
        ) catch return false;
        return true;
    }
};

/// What `initialize` settled on.
pub const Handshake = struct {
    /// The version both sides speak, or null when nothing was agreed: the agent
    /// refused, or answered with a version this library cannot speak.
    version: ?acp.WireVersion,
    /// The agent's `result` member, or its `error` member when it refused. Borrows
    /// the caller's result buffer.
    body: []const u8,
    /// The JSON-RPC error code, or null when the call succeeded.
    error_code: ?i32,
    /// The agent's capability object as raw JSON, ready for
    /// `acp.decodeCapabilityObject`, or null when the agent advertised none:
    /// no member at all, an explicit `null`, or a version this library cannot
    /// speak, which has no member name to read one under. Borrowed from
    /// `body`.
    capabilities: ?[]const u8,
    /// Whether the agent advertised a non-empty `authMethods`.
    auth_methods: bool,
};

// --- The agent side -----------------------------------------------------------

/// An agent bound to one negotiated wire version.
pub const Agent = struct {
    connection: *conn.Conn,
    /// The version this session speaks, pinned by `negotiate`.
    version: acp.WireVersion,
    /// The client's advertised capability paths, as produced by
    /// [`capabilityPaths`]. Empty means every gated client method is refused.
    client_capabilities: []const []const u8 = &.{},

    pub fn init(connection: *conn.Conn, version: acp.WireVersion) Agent {
        return .{ .connection = connection, .version = version };
    }

    /// Record the capability paths the client advertised.
    ///
    /// Borrowed: the slices must outlive the session.
    pub fn setClientCapabilities(self: *Agent, paths: []const []const u8) void {
        self.client_capabilities = paths;
    }

    /// Run the negotiation rule for the version the client asked for.
    ///
    /// `supported` is the versions this agent implements, in any order: the rule
    /// answers with the *highest* one, so the order is not the caller's to get
    /// wrong.
    ///
    /// On `echoed` and `downgraded` the session is pinned to the version the agent
    /// just answered with, because that is what the two sides agreed and the rest
    /// of the session has to act as it. `agent_supports_nothing` and
    /// `unsupported` leave the session on the version it was built with and
    /// report `error.NotPermitted`: there is no version to pin, and pinning the
    /// client's own number would claim the agent speaks something it does not.
    pub fn negotiate(
        self: *Agent,
        requested: u16,
        supported: []const acp.WireVersion,
    ) Error!acp.Negotiated {
        const outcome = acp.negotiate(requested, supported);
        switch (outcome) {
            .echoed => |version| self.version = version,
            .downgraded => |version| self.version = version,
            .agent_supports_nothing, .unsupported => return error.NotPermitted,
        }
        return outcome;
    }

    /// The `initialize` response body for the version this session speaks.
    ///
    /// The member names differ by version, which is the whole reason the response
    /// is built here rather than spliced by the caller: at v1 the capabilities and
    /// the implementation travel in `agentCapabilities` and `agentInfo`, and at v2
    /// both are `capabilities` and `info`, with `info` required.
    pub fn initializeBody(
        self: Agent,
        info: ?[]const u8,
        capabilities: ?[]const u8,
        auth_methods: ?[]const u8,
        out: []u8,
    ) Error![]const u8 {
        const caps_member: []const u8 = if (self.version == .stable)
            "agentCapabilities"
        else
            "capabilities";
        const info_member: []const u8 = if (self.version == .stable) "agentInfo" else "info";

        var writer = json.Writer.init(out);
        writer.slice("{\"protocolVersion\":") catch return error.BufferTooSmall;
        var digits: [8]u8 = undefined;
        const number = std.fmt.bufPrint(&digits, "{d}", .{self.version.number()}) catch
            return error.BufferTooSmall;
        writer.slice(number) catch return error.BufferTooSmall;
        if (capabilities) |value| {
            writer.slice(",\"") catch return error.BufferTooSmall;
            writer.slice(caps_member) catch return error.BufferTooSmall;
            writer.slice("\":") catch return error.BufferTooSmall;
            writer.slice(value) catch return error.BufferTooSmall;
        }
        if (info) |value| {
            writer.slice(",\"") catch return error.BufferTooSmall;
            writer.slice(info_member) catch return error.BufferTooSmall;
            writer.slice("\":") catch return error.BufferTooSmall;
            writer.slice(value) catch return error.BufferTooSmall;
        } else if (self.version == .draft) {
            // v2 requires `info` in the response as well as in the request, and
            // this is the one place the difference is not the client's problem to
            // discover.
            return error.MissingInfo;
        }
        if (auth_methods) |value| {
            writer.slice(",\"authMethods\":") catch return error.BufferTooSmall;
            writer.slice(value) catch return error.BufferTooSmall;
        }
        writer.byte('}') catch return error.BufferTooSmall;
        return writer.written();
    }

    /// Call a client method, gated locally against what the client advertised.
    ///
    /// The error code stays on the reply rather than becoming a Zig error: the
    /// ACP binding has its own error codes (PROTOCOLS.md section 7), a caller
    /// usually wants the message, and collapsing "the peer answered with an
    /// error" into a Zig error would make a remote `-32601` and a local
    /// `error.NotPermitted` indistinguishable at the call site.
    pub fn request(
        self: *Agent,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
    ) Error!conn.Response {
        _ = try self.gate(method, .request);
        const answer = try self.connection.call(method, try requireObject(params), result, out);
        return .{ .body = answer.body, .error_code = answer.error_code };
    }

    /// Ask the client for a permission, and read the answer against the request
    /// this agent sent.
    ///
    /// `permission` is the `acp.PermissionRequest` the agent means to ask with,
    /// and it is not the JSON-RPC request [`answerPermissionRequest`] answers:
    /// that one is the frame that arrived, this one is what the frame must say.
    /// `params` receives the `session/request_permission` body, built here from
    /// `permission`, and the answer is read against that same `permission`. So
    /// the option ids on the wire are the ids the answer is checked against:
    /// they line up because they are one set of ids, not because a caller
    /// handed over two texts it expected to agree. `permission` outlives this
    /// call, and the option ids in it must have been decoded into
    /// `request_scratch`.
    ///
    /// `request_scratch` and `outcome_scratch` must not share a byte, and a
    /// caller that hands over one buffer for both is refused before a byte goes
    /// out, for the reason [`readOutcome`] gives: the escape offset a
    /// `json.Reader` keeps is per reader and not per buffer, so the reader
    /// decoding this answer would start at offset 0 again and write an option id
    /// over one the request borrowed from that buffer, and `findOption` would
    /// then match an id against itself. That is a grant for an option the client
    /// never chose, so the call stops here rather than sending a request whose
    /// answer it may not be able to read.
    ///
    /// An outcome this library cannot parse is [`PermissionDecision.unreadable`]
    /// and not a Zig error, so the two-arm `switch` PROTOCOLS.md 6.6 requires
    /// still fails to compile without an `unreadable` arm. A client that
    /// answered with a JSON-RPC error is `unreadable` too: an error object
    /// carries no outcome, and reading one as an approval would be inventing it.
    pub fn requestPermission(
        self: *Agent,
        permission: *const acp.PermissionRequest,
        result: []u8,
        out: []u8,
        params: []u8,
        request_scratch: []u8,
        outcome_scratch: []u8,
    ) Error!PermissionDecision {
        if (conn.overlaps(request_scratch, outcome_scratch)) {
            return .{ .unreadable = error.InvalidField };
        }
        const body = try permissionParams(permission, params);
        const answer = try self.request("session/request_permission", body, result, out);
        return readOutcome(answer.body, permission, request_scratch, outcome_scratch);
    }

    /// Notify a client method, gated locally.
    pub fn notify(
        self: *Agent,
        method: []const u8,
        params: ?[]const u8,
        out: []u8,
    ) Error!void {
        _ = try self.gate(method, .notification);
        return self.connection.notify(method, try requireObject(params), out);
    }

    /// Whether a method the client called is one this agent serves at the pinned
    /// version, with the gates the client satisfied.
    ///
    /// `shape` is the arity of the frame that arrived, which a dispatcher reads
    /// off its id, and the same reason [`Client.accepts`] takes one. This agent
    /// serves client methods, and `session/update` and `elicitation/complete`
    /// are two of them that are notifications, so asking about them as requests
    /// refuses the frames the protocol sends them on. The same question
    /// [`Agent.gate`] answers, as a bool.
    pub fn accepts(self: Agent, method: []const u8, shape: Shape) bool {
        _ = self.gate(method, shape) catch return false;
        return true;
    }

    /// The gate check this session applies, exposed so a caller can ask whether a
    /// call would be refused before it spends a buffer on it.
    pub fn gate(self: Agent, method: []const u8, shape: Shape) Error!acp.MethodInfo {
        return checkCall(
            self.version,
            method,
            shape,
            .client,
            self.client_capabilities,
            // An agent does not gate its own outbound client calls on its
            // `authMethods`. That array says what the agent implements so a
            // client can authenticate to it, and PROTOCOLS.md 6.4 makes it the
            // agent's baseline obligation rather than a client capability.
            true,
        );
    }
};

// --- Permissions --------------------------------------------------------------

/// The answer a client has decided on for one permission request.
///
/// Two arms, and that is the point. There is no arm meaning "approved" that a
/// caller can reach without naming an option, and no arm meaning "the caller did
/// not care". [`autoDecide`] exists so a policy with no decision to make has
/// somewhere to go, and where it goes is `cancelled`.
pub const PermissionAnswer = union(enum) {
    /// `{"outcome":"cancelled"}`. The specification requires this answer to every
    /// permission request still pending when a `session/cancel` arrives, and it
    /// is the only answer this library produces unprompted.
    cancelled,
    /// The id of the option the user chose. Checked against the options the
    /// request actually offered before anything is written.
    selected: []const u8,
};

/// What an agent may act on, with the refusal taken out.
///
/// [`PermissionDecision`] carries a third arm so that a reader who only wants
/// the two arms a client could have meant must say what they do with the third.
/// This union says it once: an outcome this library could not read is absent
/// here, and an absent outcome has no way to become the argument of an answer.
/// That is the same rule a `switch` over `grants` and `cancelled` already
/// enforces on the decision, restated in the type of what a caller passes on.
pub const ReadableOutcome = union(enum) {
    /// The client chose an option this request offered, and that option's `kind`
    /// resolves to whether it grants.
    grants: bool,
    /// The client cancelled.
    cancelled,
};

/// What an agent may do with the outcome a client returned.
///
/// The `unreadable` arm is not decoration. PROTOCOLS.md 6.6 makes it normative
/// that an agent receiving an outcome it does not understand MUST NOT treat it
/// as approval, and the only way to make that hold in code rather than in a
/// review checklist is to make the refusal impossible to leave out: a `switch`
/// over `grants` and `cancelled` alone does not compile against this union.
pub const PermissionDecision = union(enum) {
    /// The outcome named an option the request offered, and that option's `kind`
    /// resolves to whether it grants.
    grants: bool,
    /// The client cancelled.
    cancelled,
    /// The outcome is not one this library can read, or names something the
    /// request never offered, or names an option whose `kind` has no `grants`
    /// because it is a v2 catch-all. Carries the reason.
    ///
    /// Never `grants = true`, and there is no way to make it so from the wire.
    unreadable: root.DecodeError,
    /// The arms an agent may act on, or null when the outcome was unreadable.
    ///
    /// Null rather than a value meaning "did not grant": PROTOCOLS.md 6.6 makes
    /// it normative that an outcome an agent does not understand MUST NOT be
    /// treated as approval, and a third arm here would carry the same consent
    /// `grants` carries. This is the same refusal a `switch` over `grants` and
    /// `cancelled` alone already forces, so an agent that ignores the wire can
    /// no more turn an unreadable outcome into an answer than it can leave the
    /// arm out.
    pub fn readable(self: PermissionDecision) ?ReadableOutcome {
        return switch (self) {
            .grants => |grants| .{ .grants = grants },
            .cancelled => .cancelled,
            .unreadable => null,
        };
    }
};

/// Read the outcome an agent received, without ever defaulting to approval.
///
/// `body` is the `result` member of the client's answer, so the nesting
/// `{"outcome":{...}}` that PROTOCOLS.md 6.6 specifies is peeled here rather
/// than demanded of the caller. `request` is the request the outcome answers,
/// and it is what the option id is checked against: the option list is the only
/// place a permission was defined, so an id that is not on it is consent to
/// nothing and is reported rather than read as a grant.
///
/// `request_scratch` and `outcome_scratch` must not share a byte, and a caller
/// that hands over one buffer for both is refused rather than believed. The
/// escape offset `json.Reader` keeps is per reader and not per buffer, so the
/// reader decoding this answer starts at offset 0 again and writes over
/// whatever the reader that decoded the request left there: an answer carrying
/// an escape in its option id lands exactly on an option id the request
/// borrowed from that buffer, `findOption` matches one id against itself, and
/// `grants` is true for an option the client never chose. The id is
/// peer-controlled, so that is a grant no user made.
pub fn readOutcome(
    body: []const u8,
    request: *const acp.PermissionRequest,
    request_scratch: []u8,
    outcome_scratch: []u8,
) PermissionDecision {
    if (conn.overlaps(request_scratch, outcome_scratch)) {
        return .{ .unreadable = error.InvalidField };
    }
    const outcome_text = json.memberText(body, "outcome", outcome_scratch) orelse
        return .{ .unreadable = error.MissingField };
    const outcome = acp.decodePermissionOutcome(outcome_text, outcome_scratch) catch |err| {
        return .{ .unreadable = err };
    };
    return switch (outcome) {
        .cancelled => .cancelled,
        .selected => |option_id| {
            const option = findOption(request, option_id) orelse
                return .{ .unreadable = error.InvalidField };
            // Null rather than false: a v2 catch-all kind is a value the schema
            // defines and this library does not, and `true` is the guess 6.6
            // forbids. It is not `false` either, which would claim the client
            // refused a choice it may well have made.
            const grants = option.grants() orelse
                return .{ .unreadable = error.UnknownTag };
            return .{ .grants = grants };
        },
    };
}

/// Build the JSON-RPC `result` value that answers a permission request.
///
/// The nesting is the specification's: the result is `{"outcome":{...}}`, so a
/// cancellation is `{"outcome":{"outcome":"cancelled"}}`. A `.selected` answer
/// naming an id the request did not offer is `error.UnknownPermissionOption` and
/// writes nothing, so a caller that mishandles the error cannot find an approval
/// already sitting in its buffer.
pub fn answerPermission(
    request: *const acp.PermissionRequest,
    answer: PermissionAnswer,
    out: []u8,
) Error![]const u8 {
    const outcome: acp.PermissionOutcome = switch (answer) {
        .cancelled => .cancelled,
        .selected => |option_id| selected: {
            _ = findOption(request, option_id) orelse
                return error.UnknownPermissionOption;
            break :selected .{ .selected = option_id };
        },
    };
    var writer = json.Writer.init(out);
    writer.slice("{\"outcome\":") catch return error.BufferTooSmall;
    acp.encodePermissionOutcome(outcome, &writer) catch return error.BufferTooSmall;
    writer.byte('}') catch return error.BufferTooSmall;
    return writer.written();
}

/// The whole response that answers a `session/request_permission` request.
///
/// A decision, not a choice. `decision` is what the client settled on, and it
/// carries no option id, so a cancellation is the one permission outcome the
/// specification states without one: `{"outcome":{"outcome":"cancelled"}}`.
/// The envelope around it is the connection's, because [`conn.respond`] echoes
/// the id the agent chose and refuses an answer with a result and no error
/// beside it.
///
/// A decision that grants is answered with a refusal rather than with a
/// `selected` outcome. PROTOCOLS.md 6.6 writes that outcome as
/// `{"outcome":{"outcome":"selected","optionId}}`, the id is required, and a
/// decision has none: naming an option here would choose for the user, which is
/// the consent [`PermissionAnswer`] exists to keep a caller from producing by
/// accident. So the grant goes out as the error the other of the connection's
/// two builders writes, and the agent that receives it reads `unreadable`
/// rather than an approval. A caller holding an option id answers with
/// [`answerPermission`] and [`conn.respond`], which is the path that can grant.
pub fn answerPermissionRequest(
    request: jsonrpc.Request,
    decision: ReadableOutcome,
    out: []u8,
) conn.Error![]const u8 {
    return switch (decision) {
        .cancelled => try conn.respond(
            request,
            "{\"outcome\":{\"outcome\":\"cancelled\"}}",
            out,
        ),
        .grants => try conn.errorResponse(
            request,
            .{
                .code = @intFromEnum(jsonrpc.StandardError.internal_error),
                .message = "a granting answer needs an option id",
            },
            out,
        ),
    };
}

/// A caller policy that may auto-decide a permission request.
pub const Policy = struct {
    ctx: ?*anyopaque = null,
    /// The option id the policy chose, or null for no decision.
    decide: ?*const fn (
        ctx: ?*anyopaque,
        request: *const acp.PermissionRequest,
    ) ?[]const u8 = null,
};

/// The answer a policy produces, which is a refusal whenever it has none.
///
/// The specification lets a client auto-decide by policy. A policy that has no
/// decision produces [`PermissionAnswer.cancelled`], because "the policy did not
/// fire" and "the policy allowed this" are different facts, and collapsing them is
/// how an auto-decider ends up approving.
pub fn autoDecide(
    policy: Policy,
    request: *const acp.PermissionRequest,
) PermissionAnswer {
    const decide = policy.decide orelse return .cancelled;
    const option = decide(policy.ctx, request) orelse return .cancelled;
    return .{ .selected = option };
}

fn findOption(request: *const acp.PermissionRequest, option_id: []const u8) ?acp.PermissionOption {
    const options: []const acp.PermissionOption = switch (request.*) {
        .stable => |value| value.options,
        .draft => |value| value.options,
    };
    for (options) |option| {
        if (std.mem.eql(u8, option.option_id, option_id)) return option;
    }
    return null;
}

// --- Bodies -------------------------------------------------------------------

fn initializeParams(
    version: acp.WireVersion,
    requested: u16,
    info: ?[]const u8,
    capabilities: ?[]const u8,
    out: []u8,
) Error![]const u8 {
    const caps_member: []const u8 = if (version == .stable)
        "clientCapabilities"
    else
        "capabilities";
    const info_member: []const u8 = if (version == .stable) "clientInfo" else "info";

    var writer = json.Writer.init(out);
    writer.slice("{\"protocolVersion\":") catch return error.BufferTooSmall;
    var digits: [8]u8 = undefined;
    const number = std.fmt.bufPrint(&digits, "{d}", .{requested}) catch
        return error.BufferTooSmall;
    writer.slice(number) catch return error.BufferTooSmall;
    if (capabilities) |value| {
        writer.slice(",\"") catch return error.BufferTooSmall;
        writer.slice(caps_member) catch return error.BufferTooSmall;
        writer.slice("\":") catch return error.BufferTooSmall;
        writer.slice(value) catch return error.BufferTooSmall;
    }
    if (info) |value| {
        writer.slice(",\"") catch return error.BufferTooSmall;
        writer.slice(info_member) catch return error.BufferTooSmall;
        writer.slice("\":") catch return error.BufferTooSmall;
        writer.slice(value) catch return error.BufferTooSmall;
    } else if (version == .draft) {
        return error.MissingInfo;
    }
    writer.byte('}') catch return error.BufferTooSmall;
    return writer.written();
}

/// The `session/request_permission` params for `request`, in `out`.
///
/// Built from the request rather than taken as text so that the request an agent
/// sends and the request it reads the answer against are one value. An option
/// id this body lost is then an id `readOutcome` never held, and it can be
/// matched against nothing: the alternative is a caller passing the text it is
/// about to send beside a decoded copy of a request that may not be the same
/// one, and a grant resolved against the wrong option list is a grant no user
/// chose.
///
/// Every member both versions require is written, and every member neither
/// declares is omitted rather than written `null`, because an omitted member and
/// a `null` one mean the same in both schemas.
fn permissionParams(
    request: *const acp.PermissionRequest,
    out: []u8,
) Error![]const u8 {
    const session_id: []const u8 = switch (request.*) {
        .stable => |value| value.session_id,
        .draft => |value| value.session_id,
    };
    const options: []const acp.PermissionOption = switch (request.*) {
        .stable => |value| value.options,
        .draft => |value| value.options,
    };
    var writer = json.Writer.init(out);
    writer.slice("{\"sessionId\":") catch return error.BufferTooSmall;
    writer.string(session_id) catch return error.BufferTooSmall;
    switch (request.*) {
        .stable => |value| {
            writer.slice(",\"toolCall\":") catch return error.BufferTooSmall;
            // Verbatim, because a `ToolCallUpdate` is not modelled here and this
            // is the one member an agent cannot afford to have re-shaped.
            writer.slice(value.tool_call) catch return error.BufferTooSmall;
        },
        .draft => |value| {
            writer.slice(",\"title\":") catch return error.BufferTooSmall;
            writer.string(value.title) catch return error.BufferTooSmall;
            if (value.description) |text| {
                writer.slice(",\"description\":") catch return error.BufferTooSmall;
                writer.string(text) catch return error.BufferTooSmall;
            }
            if (value.subject) |subject| {
                writer.slice(",\"subject\":") catch return error.BufferTooSmall;
                try writePermissionSubject(subject, &writer);
            }
        },
    }
    writer.slice(",\"options\":[") catch return error.BufferTooSmall;
    for (options, 0..) |option, index| {
        if (index != 0) writer.byte(',') catch return error.BufferTooSmall;
        writer.slice("{\"optionId\":") catch return error.BufferTooSmall;
        writer.string(option.option_id) catch return error.BufferTooSmall;
        writer.slice(",\"name\":") catch return error.BufferTooSmall;
        writer.string(option.name) catch return error.BufferTooSmall;
        writer.slice(",\"kind\":") catch return error.BufferTooSmall;
        switch (option.kind) {
            .known => |kind| {
                writer.string(kind.string()) catch return error.BufferTooSmall;
            },
            // The tag a v2 catch-all carries, written as it arrived. This library
            // named the four kinds, so it knows every other one by its text.
            .other => |text| {
                writer.string(text) catch return error.BufferTooSmall;
            },
        }
        writer.byte('}') catch return error.BufferTooSmall;
    }
    writer.slice("]}") catch return error.BufferTooSmall;
    return writer.written();
}

/// The v2 `subject` member, or the refusal to write one.
///
/// The two arms this library models carry every member the schema requires of
/// them, so each one decodes back to what it was built from. A command subject
/// whose `cwd` is relative is the one value of either arm that does not, and it
/// is refused here rather than written for a decoder to throw away.
fn writePermissionSubject(subject: acp.PermissionSubject, writer: *json.Writer) Error!void {
    switch (subject) {
        .tool_call => |call| {
            writer.slice(
                "{\"type\":\"" ++ acp.permission_subject_type.tool_call ++ "\",\"toolCall\":",
            ) catch return error.BufferTooSmall;
            writer.slice(call) catch return error.BufferTooSmall;
            writer.byte('}') catch return error.BufferTooSmall;
        },
        .command => |command| {
            // Refused before a byte is written, because
            // `acp.decodePermissionSubject` refuses the same subject with
            // `error.InvalidField` and a request this library cannot read back
            // is a request a peer has been asked to approve on words this
            // library will not stand behind. PROTOCOLS.md 6.6 makes the path
            // absolute because a relative one resolves against whatever
            // working directory the process that runs the command happens to
            // have, so the user approving a command in one directory would
            // approve it in another.
            if (!acp.isAbsolutePath(command.cwd)) return error.CwdNotAbsolute;
            writer.slice(
                "{\"type\":\"" ++ acp.permission_subject_type.command ++ "\",\"command\":",
            ) catch return error.BufferTooSmall;
            writer.string(command.command) catch return error.BufferTooSmall;
            writer.slice(",\"cwd\":") catch return error.BufferTooSmall;
            writer.string(command.cwd) catch return error.BufferTooSmall;
            if (command.tool_call_id) |id| {
                writer.slice(",\"toolCallId\":") catch return error.BufferTooSmall;
                writer.string(id) catch return error.BufferTooSmall;
            }
            if (command.terminal_id) |id| {
                writer.slice(",\"terminalId\":") catch return error.BufferTooSmall;
                writer.string(id) catch return error.BufferTooSmall;
            }
            writer.byte('}') catch return error.BufferTooSmall;
        },
        // Refused rather than written as the tag alone: the members a v2
        // catch-all carries were never decoded here, so a body without them
        // would ask the user about a permission the agent did not describe.
        .other => return error.SubjectNotModelled,
    }
}

/// Read the answer to `initialize` and pin the session to what it agreed.
///
/// Split out of [`Client.initialize`] so that everything an answer decides — the
/// version, the capability member, the `authMethods` gate — is one function a
/// test can drive with a body and no socket behind it. `answer` is what the
/// connection returned, so `body` is the `result` member in the caller's own
/// result buffer and `scratch` is the caller's.
fn readHandshake(client: *Client, answer: conn.Response, scratch: []u8) Error!Handshake {
    // Reported rather than guessed at: the version is what everything
    // downstream depends on, and a body this layer cannot read has none. A
    // scratch too small to unescape one key is the caller's own fault and not a
    // verdict on the peer, and `NotAResult` would say the agent sent no version
    // at all, so a caller sent looking for that protocol bug would never find
    // it, because the peer sent one.
    const number = readProtocolVersion(answer.body, scratch) catch |err| switch (err) {
        error.BufferTooSmall => return error.BufferTooSmall,
        else => return error.NotAResult,
    };
    const agreed = acp.WireVersion.fromNumber(number);

    // Recorded even when the version is unusable, because a caller logging a
    // refused handshake wants the whole answer and the gate decisions that
    // follow from it are the caller's to make.
    const auth_methods = json.memberText(answer.body, "authMethods", scratch);
    client.auth_methods = advertisesAuthMethods(auth_methods);

    // The member is named by the version the agent *answered with*, because that
    // is the version `Agent.initializeBody` wrote it under. PROTOCOLS.md 6.1
    // lets the agent answer with its own highest rather than with the one it
    // was asked for, and a downgrade is a specified outcome that
    // `Agent.negotiate` reports as one: a client that asked for v2 and was
    // answered v1 is reading a v1 body and has to look for the v1 spelling, or
    // every gated method is refused because the answer was read under the wrong
    // name.
    var advertised: ?[]const u8 = null;
    if (agreed) |version| {
        const caps_member: []const u8 = if (version == .stable)
            "agentCapabilities"
        else
            "capabilities";
        const text = json.memberText(answer.body, caps_member, scratch);
        // An explicit `null` is a peer that advertised nothing, and it is
        // reported as the absence it is: the same answer an omitted member
        // gives, and the only one a version this library cannot speak has,
        // because there is no member name to look for.
        if (text) |value| {
            if (!std.mem.eql(u8, value, "null")) advertised = value;
        }
    }
    if (agreed) |version| client.version = version else client.agent_capabilities = &.{};

    return .{
        .version = agreed,
        .body = answer.body,
        .error_code = null,
        .capabilities = advertised,
        .auth_methods = client.auth_methods,
    };
}

fn readProtocolVersion(body: []const u8, scratch: []u8) root.DecodeError!u16 {
    var reader = json.Reader.init(body);
    var number: ?u16 = null;
    if (try reader.beginObject()) return error.MissingField;
    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "protocolVersion")) {
            const lexeme = try reader.number();
            // A float, an exponent or an out-of-range integer is a shape the
            // schema does not declare for this member, not a version.
            number = std.fmt.parseInt(u16, lexeme, 10) catch return error.InvalidField;
        } else {
            try reader.skipValue(scratch);
        }
    }
    return number orelse error.MissingField;
}

/// Whether the peer advertised any authentication method.
///
/// The gate is the *emptiness* of `authMethods`, not its presence: v1 gives the
/// member a schema default of `[]`, and an agent that implements no login supports
/// no `auth/login`. `null` and `[]` are both nothing.
fn advertisesAuthMethods(text: ?[]const u8) bool {
    const value = std.mem.trim(u8, text orelse return false, " \t\r\n");
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "null")) return false;
    if (std.mem.eql(u8, value, "[]")) return false;
    return true;
}

/// The params a call is allowed to send, or `error.ParamsNotAnObject`.
///
/// ACP params are objects in every version; a batch array is the one thing this
/// session refuses, and it is refused above, before a body is built. Checking
/// here means an array, a string or a number cannot reach the connection. A
/// refusal rather than a null, because the connection omits an absent `params`
/// member entirely: the peer would answer a request the caller never wrote.
fn requireObject(params: ?[]const u8) error{ParamsNotAnObject}!?[]const u8 {
    const value = params orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return error.ParamsNotAnObject;
    return value;
}

// --- Tests --------------------------------------------------------------------

const testing = std.testing;

test "a session is refused a method the pinned version does not have" {
    const v1: Client = .{ .connection = undefined, .version = .stable };
    try testing.expectError(error.MethodNotInVersion, v1.gate("auth/login", .request));
    // The other direction: v2 removed the whole filesystem and terminal surface,
    // and an adapter that kept sending `fs/read_text_file` would be claiming
    // support for a method the draft does not have.
    const v2: Client = .{ .connection = undefined, .version = .draft };
    try testing.expectError(error.MethodNotInVersion, v2.gate("fs/read_text_file", .request));
    try testing.expectError(error.MethodNotInVersion, v2.gate("session/load", .request));
    // The version that is not implemented at all is not a shape to send.
    try testing.expect(acp.WireVersion.fromNumber(3) == null);
}

test "a gated method is refused until the capability is advertised" {
    // An empty path list is what a client holds before `initialize` completes:
    // PROTOCOLS.md 6.5 makes omission mean unsupported, so every gated method is
    // refused rather than sent and rediscovered.
    var client: Client = .{ .connection = undefined, .version = .stable };
    try testing.expectError(error.NotPermitted, client.gate("session/load", .request));

    const advertised = [_][]const u8{"loadSession"};
    client.setAgentCapabilities(&advertised);
    const info = try client.gate("session/load", .request);
    try testing.expectEqualStrings("session/load", info.name);
    // Still refused without it: an agent that advertised one session capability
    // did not advertise them all.
    try testing.expectError(error.NotPermitted, client.gate("session/delete", .request));
    // And an ungated baseline method was never gated at all.
    _ = try client.gate("session/new", .request);
}

test "either of the two elicitation gates enables the method" {
    // `elicitation/create` is a client method, so the agent is the caller and
    // the gate is on what the client advertised.
    var agent: Agent = .{ .connection = undefined, .version = .stable };
    const url_only = [_][]const u8{"elicitation.url"};
    agent.setClientCapabilities(&url_only);
    // A client advertising URL mode alone supports form-or-URL elicitation, so
    // reporting otherwise would refuse a method the client does serve. The gate
    // the registry names first is `form`; the second is what this exercises.
    const info = try agent.gate("elicitation/create", .request);
    try testing.expectEqualStrings("elicitation.form", info.gate);
    try testing.expectEqualStrings("elicitation.url", info.gate2);

    // A client that advertised neither mode supports neither, and the method is
    // refused rather than sent to find out.
    const bare: Agent = .{ .connection = undefined, .version = .stable };
    try testing.expectError(error.NotPermitted, bare.gate("elicitation/create", .request));
    try testing.expect(!bare.accepts("elicitation/create", .request));
}

test "auth/login is gated on a non-empty authMethods, at v2 only" {
    var client: Client = .{ .connection = undefined, .version = .draft };
    try testing.expectError(error.NotPermitted, client.gate("auth/login", .request));
    client.auth_methods = true;
    _ = try client.gate("auth/login", .request);
    _ = try client.gate("auth/logout", .request);

    // The schema default for v1 is `[]`, and an agent that implements no login
    // advertises no method, so the same emptiness is the answer either way.
    try testing.expect(!advertisesAuthMethods(null));
    try testing.expect(!advertisesAuthMethods("[]"));
    try testing.expect(!advertisesAuthMethods("  null "));
    try testing.expect(advertisesAuthMethods("[{\"id\":\"oauth\"}]"));
}

test "arity and side are checked against the registry" {
    const client: Client = .{ .connection = undefined, .version = .stable };
    // `session/cancel` is a notification. Sending it as a request would leave the
    // client waiting for an answer the agent will never send.
    try testing.expectError(error.WrongArity, client.gate("session/cancel", .request));
    _ = try client.gate("session/cancel", .notification);
    // `session/new` is a request. Sending it as a notification would make the
    // agent answer a message that expects nothing, and the session id would be
    // lost with no way to notice.
    try testing.expectError(error.WrongArity, client.gate("session/new", .notification));
    // A client method is not a client's to call.
    try testing.expectError(error.WrongSide, client.gate("session/request_permission", .request));
    try testing.expectError(error.WrongSide, client.gate("session/update", .notification));
    // The one side-independent method is callable from either side.
    _ = try client.gate("$/cancel_request", .notification);

    // A client method is an agent's to send, and a gated one only once the
    // client advertised the capability.
    var agent: Agent = .{ .connection = undefined, .version = .stable };
    _ = try agent.gate("session/request_permission", .request);
    try testing.expectError(error.NotPermitted, agent.gate("terminal/create", .request));
    const advertised = [_][]const u8{"terminal"};
    agent.setClientCapabilities(&advertised);
    _ = try agent.gate("terminal/create", .request);
    try testing.expect(agent.accepts("terminal/create", .request));
    try testing.expect(agent.accepts("terminal/release", .request));
    // A capability the client never advertised is refused, whatever the method
    // is: both terminal methods are gated on the same `terminal` boolean, so
    // one of them answering would mean the gate is not per-method.
    try testing.expect(!agent.accepts("fs/write_text_file", .request));
    try testing.expect(!agent.accepts("session/load", .request));
}

test "a session is pinned to the version it was built with" {
    var connection: conn.Conn = undefined;
    // The pin is what every later gate is decided against, so a constructor
    // sets it rather than leaving a session to settle on its first call.
    const client = Client.init(&connection, .stable);
    try testing.expectEqual(acp.WireVersion.stable, client.version);
    try testing.expectEqual(@as(u16, 1), client.versionNumber());

    // The other version, and the number the wire actually carries.
    const v2 = Client.init(&connection, .draft);
    try testing.expectEqual(@as(u16, 2), v2.versionNumber());

    // The agent pins the same way, and its gate reads the pin alone: a v1
    // method the draft removed is refused without a round trip.
    const agent = Agent.init(&connection, .draft);
    try testing.expectEqual(acp.WireVersion.draft, agent.version);
    try testing.expect(agent.accepts("session/request_permission", .request));
    try testing.expect(!agent.accepts("terminal/create", .request));
}

test "the inbound client-side gate is the capability this client claimed" {
    var client: Client = .{ .connection = undefined, .version = .stable };
    // Nothing claimed yet, so every gated client method is refused. An agent
    // that asks for a terminal this client never advertised support for must
    // not be answered by a session that pretends otherwise.
    try testing.expect(!client.accepts("terminal/create", .request));

    const claimed = [_][]const u8{"terminal"};
    client.setClientCapabilities(&claimed);
    try testing.expect(client.accepts("terminal/create", .request));
    try testing.expect(client.accepts("terminal/release", .request));
    // One capability claimed is not all of them, so the gate stays per method.
    try testing.expect(!client.accepts("fs/write_text_file", .request));
    try testing.expect(!client.accepts("elicitation/create", .request));
    // An ungated client method was never gated at all.
    try testing.expect(client.accepts("session/request_permission", .request));
}

test "a notification is served, and the arity it arrived in is what is asked about" {
    // PROTOCOLS.md 6.3 and 6.4 register four of these as notifications, and say
    // `$/cancel_request` arrives from either side. Asked as requests every one
    // of them is a message the peer will never answer, so a dispatcher that
    // asked with one shape refused frames the protocol requires it to serve.
    var client: Client = .{ .connection = undefined, .version = .stable };
    try testing.expect(client.accepts("session/update", .notification));
    try testing.expect(client.accepts("elicitation/complete", .notification));
    try testing.expect(client.accepts("$/cancel_request", .notification));
    // The other shape is still refused, because the arity is not a detail a
    // `bool` may drop: a request where a notification was expected waits for an
    // answer that will never come.
    try testing.expect(!client.accepts("session/update", .request));
    try testing.expect(!client.accepts("session/request_permission", .notification));
    try testing.expect(!client.accepts("terminal/create", .notification));

    var agent: Agent = .{ .connection = undefined, .version = .stable };
    // An agent serves client methods, so the notifications it is sent are these
    // three and not the ones a client sends.
    try testing.expect(agent.accepts("session/update", .notification));
    try testing.expect(agent.accepts("elicitation/complete", .notification));
    try testing.expect(agent.accepts("$/cancel_request", .notification));
    // `session/cancel` is the client's own call, so nothing serves it in this
    // direction. The side decides that, not the arity, and both shapes say so.
    try testing.expect(!agent.accepts("session/cancel", .notification));
    try testing.expect(!agent.accepts("session/cancel", .request));
    // Nor does the other shape open a capability or a side.
    try testing.expect(!agent.accepts("terminal/create", .request));
    try testing.expect(!agent.accepts("session/request_permission", .notification));
}

test "a notification is sent as a notification and a request as a request" {
    var connection: conn.Conn = undefined;
    var out: [128]u8 = undefined;
    var result: [128]u8 = undefined;
    var client: Client = .{ .connection = &connection, .version = .stable };
    var agent: Agent = .{ .connection = &connection, .version = .stable };

    // Each is refused by the arity check alone, so the connection is never
    // reached: a notification sent as a request leaves the sender waiting for
    // an answer the peer will never send, and a request sent as a notification
    // loses the session id with nothing to notice it.
    try testing.expectError(
        error.WrongArity,
        client.notify("session/new", "{\"cwd\":\"/tmp\"}", &out),
    );
    try testing.expectError(
        error.WrongArity,
        client.request("session/cancel", "{\"sessionId\":\"s1\"}", &result, &out),
    );
    try testing.expectError(
        error.WrongArity,
        agent.notify("session/request_permission", "{\"sessionId\":\"s1\"}", &out),
    );
    try testing.expectError(
        error.WrongArity,
        agent.request("session/update", "{\"sessionId\":\"s1\"}", &result, &out),
    );
}

test "an outcome this library cannot read is never approval" {
    var options: [2]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_once\"}," ++
            "{\"optionId\":\"no\",\"name\":\"No\",\"kind\":\"reject_once\"}]}",
        &options,
        &request_scratch,
    );
    var outcome_scratch: [256]u8 = undefined;

    // The shapes a newer or hostile client could send. None may read as a grant,
    // and each carries the reason so an agent can log why it stopped.
    for ([_][]const u8{
        "{\"outcome\":{\"outcome\":\"approved\"}}",
        "{\"outcome\":{\"outcome\":\"allow_once\",\"optionId\":\"yes\"}}",
        "{\"outcome\":{\"outcome\":\"selected\"}}",
        "{\"outcome\":{}}",
        "{\"outcome\":[]}",
        "{\"outcome\":null}",
        // What `answerPermissionRequest` writes for a decision that grants: an
        // error object, which carries no outcome at all.
        "{\"code\":-32603,\"message\":\"a granting answer needs an option id\"}",
    }) |body| {
        const decision = readOutcome(body, &request, &request_scratch, &outcome_scratch);
        switch (decision) {
            .unreadable => |err| try testing.expect(err != error.BufferTooSmall),
            else => return error.TestUnexpectedResult,
        }

        // The refusal is not decoration, and it is not a value an answer can
        // take: there is nothing to hand on from an outcome nobody could read.
        try testing.expectEqual(@as(?ReadableOutcome, null), decision.readable());
    }
}

test "the outcome that is read is the first one the client sent" {
    // RFC 8259 section 4 says the names in an object should be unique and does
    // not forbid a repeat, so a peer can send `outcome` twice. The first is what
    // the body reads as and what every other walk in the tree resolves, and a
    // walk that kept the last would let a client answer `cancelled` and then
    // append the option it wanted: the grant would be the one read, and the user
    // saw the other.
    var options: [1]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(.stable, permission_params, &options, &request_scratch);
    var outcome_scratch: [256]u8 = undefined;
    const twice = readOutcome(
        \\{"outcome":{"outcome":"cancelled"},"outcome":{"outcome":"selected","optionId":"yes"}}
    , &request, &request_scratch, &outcome_scratch);
    try testing.expect(twice == .cancelled);
}

test "an outcome naming an option the request never offered is consent to nothing" {
    var options: [1]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_once\"}]}",
        &options,
        &request_scratch,
    );
    var outcome_scratch: [256]u8 = undefined;

    // An `allow_once` option was on the table somewhere, so a caller could
    // plausibly reach for an id from another request. It is not this request's
    // option, and answering it would be consent granted for a choice nobody was
    // shown.
    const wrong = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"other-request"}}
    , &request, &request_scratch, &outcome_scratch);
    try testing.expect(wrong == .unreadable);
    // Which is the whole of the refusal in its type: an outcome naming an id
    // this request never offered cannot become the argument of an answer.
    try testing.expectEqual(@as(?ReadableOutcome, null), wrong.readable());

    // The same shape, naming the option this request did offer, does grant. So
    // the refusal is about the id and not about the decoder failing.
    const right = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"yes"}}
    , &request, &request_scratch, &outcome_scratch);
    try testing.expectEqual(true, right.grants);
    try testing.expectEqual(ReadableOutcome{ .grants = true }, right.readable().?);
}

test "an answer read through the request's own buffer is refused, not granted" {
    // An option id carrying an escape is the one value a decoded request
    // borrows from the caller's buffer rather than from the input, and the
    // first one starts at offset 0. Without the escape below the request would
    // borrow this fixture and the test would prove nothing.
    var options: [2]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"\\u0041LLOW\",\"name\":\"Yes\",\"kind\":\"allow_once\"}," ++
            "{\"optionId\":\"never\",\"name\":\"No\",\"kind\":\"reject_once\"}]}",
        &options,
        &request_scratch,
    );
    var outcome_scratch: [256]u8 = undefined;

    // The answer names an id the request never offered, and read through its
    // own region that is a refusal: consent to an option nobody was shown.
    try testing.expect(readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"\u0061LLLW"}}
    , &request, &request_scratch, &outcome_scratch) == .unreadable);

    // Read through the buffer the request was decoded into, the same answer is
    // still a refusal and never a grant. The escape offset is per reader, so
    // this decode starts at 0 again and its five bytes land on the first
    // option's five, leaving `findOption` comparing one id with itself. The
    // reason travels with the refusal, so an agent can log why it stopped.
    const reason: root.DecodeError = error.InvalidField;
    switch (readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"\u0061LLLW"}}
    , &request, &request_scratch, &request_scratch)) {
        .unreadable => |err| try testing.expectEqual(reason, err),
        else => return error.TestUnexpectedResult,
    }
}

test "one buffer for both scratches is refused before a byte is sent" {
    // The connection is `undefined` on purpose: the refusal happens before the
    // agent reaches it, so a caller that got past it would fault here rather
    // than quietly reading an answer it cannot trust.
    var agent: Agent = .{ .connection = undefined, .version = .stable };
    var options: [1]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(.stable, permission_params, &options, &request_scratch);
    var result: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var params: [512]u8 = undefined;

    // The same request, and one buffer for both scratches. The escape offset a
    // `json.Reader` keeps is per reader and not per buffer, so the reader
    // decoding the answer would start at offset 0 again and write an option id
    // over one this request borrowed from there: `findOption` would then match
    // an id against itself and read a refusal as a grant. So nothing is sent,
    // the reason travels with the refusal, and there is nothing to turn into an
    // answer.
    const reason: root.DecodeError = error.InvalidField;
    const decision = try agent.requestPermission(
        &request,
        &result,
        &out,
        &params,
        &request_scratch,
        &request_scratch,
    );
    switch (decision) {
        .unreadable => |err| try testing.expectEqual(reason, err),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(?ReadableOutcome, null), decision.readable());
}

test "a v2 catch-all option kind is unreadable, not a grant and not a refusal" {
    var options: [2]acp.PermissionOption = undefined;
    const source = "{\"sessionId\":\"s1\",\"title\":\"Run\",\"subject\":null,\"options\":[" ++
        "{\"optionId\":\"a\",\"name\":\"Run\",\"kind\":\"allow_once\"}," ++
        "{\"optionId\":\"ext\",\"name\":\"Always via policy\",\"kind\":\"_vendor\"}]}";
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(.draft, source, &options, &request_scratch);
    var outcome_scratch: [256]u8 = undefined;

    // The schema defines the fifth string, so the option is real and a client may
    // legitimately offer it. What the library may not do is claim what choosing
    // it means: `grants` is the one value 6.6 forbids inferring, and `false`
    // would claim the client refused a choice it made.
    const decision = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"ext"}}
    , &request, &request_scratch, &outcome_scratch);
    switch (decision) {
        .unreadable => |err| try testing.expectEqual(@as(root.DecodeError, error.UnknownTag), err),
        else => return error.TestUnexpectedResult,
    }
    // The same refusal in its type: an option whose kind this library cannot
    // resolve to a direction is nothing an answer could be built from either.
    try testing.expectEqual(@as(?ReadableOutcome, null), decision.readable());

    // The named option next to it still resolves, so the refusal is about the
    // kind and not about the request.
    const known = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"a"}}
    , &request, &request_scratch, &outcome_scratch);
    try testing.expectEqual(true, known.grants);
}

test "a cancellation is read as a cancellation and never as a grant" {
    var options: [1]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_always\"}]}",
        &options,
        &request_scratch,
    );
    var outcome_scratch: [256]u8 = undefined;
    const decision = readOutcome(
        \\{"outcome":{"outcome":"cancelled"}}
    , &request, &request_scratch, &outcome_scratch);
    try testing.expect(decision == .cancelled);
    // An agent may act on it, and what it may act on is the cancellation: the
    // arms a `ReadableOutcome` has are exactly the ones 6.6 leaves it.
    try testing.expectEqual(ReadableOutcome{ .cancelled = {} }, decision.readable().?);
}

test "answering a permission request writes the nested outcome the spec states" {
    var options: [2]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_once\"}," ++
            "{\"optionId\":\"no\",\"name\":\"No\",\"kind\":\"reject_once\"}]}",
        &options,
        &request_scratch,
    );
    var out: [128]u8 = undefined;

    // PROTOCOLS.md 6.6: the response is `{outcome: {outcome: "cancelled"}}`.
    const refused = try answerPermission(&request, .cancelled, &out);
    try testing.expectEqualStrings("{\"outcome\":{\"outcome\":\"cancelled\"}}", refused);

    const granted = try answerPermission(&request, .{ .selected = "yes" }, &out);
    try testing.expectEqualStrings(
        "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"yes\"}}",
        granted,
    );

    // A rejection option answers too, and says so. The encoding never guesses
    // which direction a chosen option points.
    const denied = try answerPermission(&request, .{ .selected = "no" }, &out);
    try testing.expectEqualStrings(
        "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"no\"}}",
        denied,
    );

    // An id from another request answers nothing, and writes nothing: a caller
    // that mishandles the error must not find an approval already in its buffer.
    try testing.expectError(
        error.UnknownPermissionOption,
        answerPermission(&request, .{ .selected = "stale" }, &out),
    );
    try testing.expectError(
        error.BufferTooSmall,
        answerPermission(&request, .cancelled, out[0..8]),
    );
}

test "the answer frame is the connection's, and it refuses a grant it cannot name" {
    // The shape a handler receives: a decoded request, which is what an answer
    // is built against.
    var key_scratch: [256]u8 = undefined;
    const call = try jsonrpc.decodeRequest(
        \\{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s9"}}
    , &key_scratch);
    var out: [256]u8 = undefined;

    // The cancellation, in the envelope the connection writes: the id the agent
    // chose, echoed by the shared builder rather than assembled here.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"outcome\":" ++
            "{\"outcome\":\"cancelled\"}}}",
        try answerPermissionRequest(call, .cancelled, &out),
    );

    // A decision that grants names no option, and the protocol's grant is a
    // `selected` outcome that carries one. So the answer is the other of the two
    // shapes `jsonrpc.encodeResponse` accepts: a result with no error, or an
    // error with no result. This one is the error.
    const refused = try answerPermissionRequest(call, .{ .grants = true }, &out);
    try testing.expect(std.mem.indexOf(u8, refused, "\"result\"") == null);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32603," ++
            "\"message\":\"a granting answer needs an option id\"}}",
        refused,
    );

    // And an agent that receives it reads a refusal rather than an approval: an
    // error object carries no outcome, so there is nothing there to be one.
    var options: [1]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(.stable, permission_params, &options, &request_scratch);
    var outcome_scratch: [256]u8 = undefined;
    const decision = readOutcome(refused, &request, &request_scratch, &outcome_scratch);
    try testing.expectEqual(@as(?ReadableOutcome, null), decision.readable());

    // A short buffer is the caller's own fault, and it is reported rather than
    // leaving half an answer behind.
    try testing.expectError(
        error.ResponseTooLarge,
        answerPermissionRequest(call, .cancelled, out[0..8]),
    );
}

test "the request an agent sends is the one the answer is checked against" {
    // Typed, the way an agent builds one, so nothing here is a text a caller has
    // to keep in step by hand.
    var options = [_]acp.PermissionOption{
        .{ .option_id = "yes", .name = "Yes", .kind = .{ .known = .allow_once } },
        .{ .option_id = "no", .name = "No", .kind = .{ .known = .reject_once } },
    };
    const request: acp.PermissionRequest = .{ .stable = .{
        .session_id = "s9",
        .tool_call = "{\"toolCallId\":\"t1\"}",
        .options = &options,
    } };

    var params: [256]u8 = undefined;
    const body = try permissionParams(&request, &params);

    // A client reads back what the agent holds, so an option id the params lost
    // is an id nothing can match. Both of them, in the order they were offered.
    var read_back: [2]acp.PermissionOption = undefined;
    var scratch: [256]u8 = undefined;
    const sent = try acp.decodePermissionRequest(.stable, body, &read_back, &scratch);
    try testing.expectEqual(@as(usize, 2), sent.stable.options.len);
    try testing.expectEqualStrings("yes", sent.stable.options[0].option_id);
    try testing.expectEqualStrings("no", sent.stable.options[1].option_id);

    // A short buffer writes nothing at all, so a caller that mishandles the
    // error cannot find a request already sitting in its own memory.
    var small: [8]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, permissionParams(&request, &small));
}

test "a v2 permission request keeps its subject and refuses one it cannot rebuild" {
    var options = [_]acp.PermissionOption{
        .{ .option_id = "a", .name = "Run", .kind = .{ .known = .allow_once } },
    };
    const call_text = "{\"toolCallId\":\"t1\"}";
    var out: [512]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var read_back: [1]acp.PermissionOption = undefined;

    // A command subject carries every member the schema requires of it, so it
    // comes back whole: the user is asked about the same command in the same
    // directory, or not at all.
    const command: acp.PermissionRequest = .{ .draft = .{
        .session_id = "s9",
        .title = "Run a command",
        .description = "before the build",
        .subject = .{ .command = .{
            .command = "ls -l",
            .cwd = "/tmp",
            .tool_call_id = "t1",
            .terminal_id = null,
        } },
        .options = &options,
    } };
    const body = try permissionParams(&command, &out);
    const sent = try acp.decodePermissionRequest(.draft, body, &read_back, &scratch);
    try testing.expectEqualStrings("Run a command", sent.draft.title);
    try testing.expectEqualStrings("before the build", sent.draft.description.?);
    switch (sent.draft.subject orelse return error.TestUnexpectedResult) {
        .command => |value| {
            try testing.expectEqualStrings("ls -l", value.command);
            try testing.expectEqualStrings("/tmp", value.cwd);
            try testing.expectEqualStrings("t1", value.tool_call_id.?);
        },
        else => return error.TestUnexpectedResult,
    }

    // A tool call subject is carried as raw text, because a `ToolCallUpdate` is
    // not modelled here and an agent cannot afford to have it re-shaped.
    const call: acp.PermissionRequest = .{ .draft = .{
        .session_id = "s9",
        .title = "Run",
        .description = null,
        .subject = .{ .tool_call = call_text },
        .options = &options,
    } };
    const call_body = try permissionParams(&call, &out);
    const seen = try acp.decodePermissionRequest(.draft, call_body, &read_back, &scratch);
    switch (seen.draft.subject orelse return error.TestUnexpectedResult) {
        .tool_call => |value| try testing.expectEqualStrings(call_text, value),
        else => return error.TestUnexpectedResult,
    }

    // A catch-all `type` carries members this library never decoded, and a
    // request without them would ask the user about a permission the agent did
    // not describe. Nothing is sent.
    const other: acp.PermissionRequest = .{ .draft = .{
        .session_id = "s9",
        .title = "Run",
        .description = null,
        .subject = .{ .other = "_vendor" },
        .options = &options,
    } };
    try testing.expectError(error.SubjectNotModelled, permissionParams(&other, &out));
}

test "a command subject with a relative cwd is refused rather than written" {
    // PROTOCOLS.md 6.6 makes the path absolute, and
    // `acp.decodePermissionSubject` refuses a relative one with
    // `error.InvalidField`, so writing it would put on the wire a request this
    // library cannot read back. The path is the whole of the disagreement: a
    // relative one resolves against whatever working directory the process
    // that runs the command happens to have, so the user approving a command in
    // one directory would approve it in another.
    var options = [_]acp.PermissionOption{
        .{ .option_id = "a", .name = "Run", .kind = .{ .known = .allow_once } },
    };
    const request: acp.PermissionRequest = .{ .draft = .{
        .session_id = "s9",
        .title = "Run a command",
        .description = null,
        .subject = .{ .command = .{
            .command = "ls",
            .cwd = "build",
            .tool_call_id = null,
            .terminal_id = null,
        } },
        .options = &options,
    } };
    var out: [512]u8 = undefined;
    try testing.expectError(error.CwdNotAbsolute, permissionParams(&request, &out));
}

test "a policy with no decision refuses rather than approves" {
    var options: [1]acp.PermissionOption = undefined;
    var request_scratch: [512]u8 = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_always\"}]}",
        &options,
        &request_scratch,
    );

    // No policy at all, and a policy that declines. Neither may reach a
    // `.selected`, which is the only way an approval is spelled at all.
    try testing.expect(autoDecide(.{}, &request) == .cancelled);
    try testing.expect(autoDecide(
        .{ .ctx = @constCast(&request), .decide = decline },
        &request,
    ) == .cancelled);

    // A policy that does choose still names an option id, which
    // `answerPermission` checks against the request before anything is written.
    const chosen = autoDecide(
        .{ .ctx = @constCast(&request), .decide = choose },
        &request,
    );
    try testing.expect(chosen == .selected);
    var out: [128]u8 = undefined;
    try testing.expectError(
        error.UnknownPermissionOption,
        answerPermission(&request, .{ .selected = "not-on-the-table" }, &out),
    );
}

test "an initialize is shaped by the version it asks for" {
    var out: [256]u8 = undefined;

    // v1: two optional members, spelled the v1 way.
    const v1 = try initializeParams(.stable, 1, "{\"name\":\"a\"}", "{\"fs\":{}}", &out);
    try testing.expectEqualStrings(
        "{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{}}," ++
            "\"clientInfo\":{\"name\":\"a\"}}",
        v1,
    );
    // v1 requires only the version.
    try testing.expectEqualStrings(
        "{\"protocolVersion\":1}",
        try initializeParams(.stable, 1, null, null, &out),
    );

    // v2: `info` is required and the capabilities member is renamed.
    const v2 = try initializeParams(.draft, 2, "{\"name\":\"a\"}", "{\"session\":{}}", &out);
    try testing.expectEqualStrings(
        "{\"protocolVersion\":2,\"capabilities\":{\"session\":{}},\"info\":{\"name\":\"a\"}}",
        v2,
    );
    try testing.expectError(error.MissingInfo, initializeParams(.draft, 2, null, null, &out));
}

test "an agent answers initialize in its own version's spelling" {
    var connection: conn.Conn = undefined;
    var out: [256]u8 = undefined;

    const v1: Agent = .{ .connection = &connection, .version = .stable };
    const v1_body = try v1.initializeBody(
        "{\"name\":\"agent\"}",
        "{\"loadSession\":true}",
        null,
        &out,
    );
    try testing.expectEqualStrings(
        "{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true}," ++
            "\"agentInfo\":{\"name\":\"agent\"}}",
        v1_body,
    );
    // v1 lets the implementation go unmentioned, so a minimal answer is legal.
    try testing.expectEqualStrings(
        "{\"protocolVersion\":1}",
        try v1.initializeBody(null, null, null, &out),
    );

    const v2: Agent = .{ .connection = &connection, .version = .draft };
    const v2_body = try v2.initializeBody(
        "{\"name\":\"agent\"}",
        "{\"session\":{}}",
        "[{\"id\":\"oauth\"}]",
        &out,
    );
    try testing.expectEqualStrings(
        "{\"protocolVersion\":2,\"capabilities\":{\"session\":{}}," ++
            "\"info\":{\"name\":\"agent\"},\"authMethods\":[{\"id\":\"oauth\"}]}",
        v2_body,
    );
    // v2 requires `info` in the response as well as in the request.
    try testing.expectError(
        error.MissingInfo,
        v2.initializeBody(null, "{\"session\":{}}", null, &out),
    );
}

test "a downgrade is read in the version the agent answered with" {
    // PROTOCOLS.md 6.1: the agent echoes the version it was asked for or
    // returns its own highest. A client that asked for v2 and was answered v1 is
    // reading a v1 body, and the capability member in it is the v1 spelling —
    // the one `Agent.initializeBody` writes, because `negotiate` pinned the
    // agent to what it answered. Read under the v2 name the answer carries no
    // capabilities at all, and every gated method is refused.
    var client: Client = .{ .connection = undefined, .version = .draft };
    var scratch: [256]u8 = undefined;
    const body = "{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true}}";
    const handshake = try readHandshake(&client, .{ .body = body, .error_code = null }, &scratch);
    try testing.expectEqual(acp.WireVersion.stable, handshake.version.?);
    try testing.expectEqual(acp.WireVersion.stable, client.version);

    // `loadSession` is the gate on `session/load` and on `session/resume`, and
    // both are open because the answer was read under the name its own version
    // spells. A capability the answer did not carry is still refused, so what
    // is being checked is the member the agent wrote and not a gate left open.
    var entries: [4]acp.Capability = undefined;
    var paths_buffer: [128]u8 = undefined;
    var list: [4][]const u8 = undefined;
    const set = try acp.decodeCapabilityObject(
        .stable,
        .agent,
        handshake.capabilities orelse return error.TestUnexpectedResult,
        &entries,
        &paths_buffer,
        &scratch,
    );
    client.setAgentCapabilities(try capabilityPaths(set, &list));
    _ = try client.gate("session/load", .request);
    _ = try client.gate("session/resume", .request);
    try testing.expectError(error.NotPermitted, client.gate("session/delete", .request));

    // The echo, which is the other half of the same rule: the member is the one
    // the answered version spells, whichever way the negotiation went.
    const v2 = "{\"protocolVersion\":2,\"capabilities\":{\"session\":{}}}";
    const echoed = try readHandshake(&client, .{ .body = v2, .error_code = null }, &scratch);
    try testing.expectEqual(acp.WireVersion.draft, echoed.version.?);
    try testing.expect(echoed.capabilities != null);

    // A version this library cannot speak has no member name to look for, so
    // the answer reports none rather than guessing at a spelling: the body is
    // the caller's to read, and the session keeps no paths.
    const unknown = "{\"protocolVersion\":9,\"capabilities\":{}}";
    const unheld = try readHandshake(&client, .{ .body = unknown, .error_code = null }, &scratch);
    try testing.expect(unheld.version == null);
    try testing.expect(unheld.capabilities == null);

    // An explicit `null` is a peer that advertised nothing, and it is reported
    // as the absence it is rather than as the four bytes a decoder refuses.
    const none = "{\"protocolVersion\":1,\"agentCapabilities\":null}";
    const bare = try readHandshake(&client, .{ .body = none, .error_code = null }, &scratch);
    try testing.expect(bare.capabilities == null);
}

test "a short scratch is the caller's fault and not a verdict on the peer" {
    // An answer that carries a version, and a key the caller's scratch cannot
    // unescape. The peer did nothing wrong, and `NotAResult` would say it sent
    // no version at all, so a caller sent looking for that protocol bug would
    // never find it, because the peer sent one.
    var client: Client = .{ .connection = undefined, .version = .draft };
    const body = "{\"protocolVersion\":1,\"agentCapabilit\\u0069es\":{}}";
    var small: [2]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        readHandshake(&client, .{ .body = body, .error_code = null }, &small),
    );
    // The pin did not move, because nothing was read.
    try testing.expectEqual(acp.WireVersion.draft, client.version);

    // The same answer through a scratch that fits reads, and reads as the v1
    // member it is: the fault was the buffer and not the peer.
    var roomy: [64]u8 = undefined;
    const handshake = try readHandshake(&client, .{ .body = body, .error_code = null }, &roomy);
    try testing.expectEqual(acp.WireVersion.stable, handshake.version.?);
    try testing.expect(handshake.capabilities != null);
}

test "negotiation pins the session and refuses to invent a version" {
    var connection: conn.Conn = undefined;
    const both = [_]acp.WireVersion{ .stable, .draft };

    // The client asked for the draft, so the draft is what the session speaks
    // from here on, whatever the agent started pinned to.
    var agent: Agent = .{ .connection = &connection, .version = .stable };
    try testing.expectEqual(acp.WireVersion.draft, (try agent.negotiate(2, &both)).echoed);
    try testing.expectEqual(acp.WireVersion.draft, agent.version);

    // A client that asked for a version the agent does not have gets the agent's
    // own highest, and the session follows the answer rather than the request.
    var other: Agent = .{ .connection = &connection, .version = .draft };
    const stable_only = [_]acp.WireVersion{.stable};
    try testing.expectEqual(acp.WireVersion.stable, (try other.negotiate(1, &stable_only)).echoed);
    try testing.expectEqual(acp.WireVersion.stable, other.version);
    try testing.expectEqual(
        acp.WireVersion.stable,
        (try other.negotiate(2, &stable_only)).downgraded,
    );
    try testing.expectEqual(acp.WireVersion.stable, other.version);

    // An agent that implements no version at all has no answer to give: the rule
    // says answer with the latest version the agent supports, and there is none.
    // Pinning the client's own number would claim a version the agent does not
    // speak, so the session refuses and stays where it was.
    const none: []const acp.WireVersion = &.{};
    var silent: Agent = .{ .connection = &connection, .version = .stable };
    try testing.expectError(error.NotPermitted, silent.negotiate(1, none));
    // Refusing must not have moved the session: it is still the version the agent
    // implements, and every later answer is still that version's.
    try testing.expectEqual(acp.WireVersion.stable, silent.version);
    // A downgrade is not a refusal: the client gets the agent's own highest, and
    // PROTOCOLS.md 6.1 leaves disconnecting to the client, which is why the
    // outcome names the version rather than being an error.
    try testing.expectEqual(
        acp.WireVersion.stable,
        (try silent.negotiate(2, &stable_only)).downgraded,
    );
}

test "a batch frame is refused loudly, at either version" {
    // The specification permits a batch at v2 and has none at v1; this session
    // accepts neither, and the refusal is the same byte string either way.
    try testing.expect(!accepts_batches);
    try testing.expect(acp.permitsBatch(.draft));
    try testing.expectEqual(FrameAction.refuse_batch, classifyFrame("[{\"jsonrpc\":\"2.0\"}]"));
    try testing.expectEqual(FrameAction.dispatch, classifyFrame("{\"jsonrpc\":\"2.0\"}"));
    try testing.expectEqual(FrameAction.dispatch, classifyFrame("  {\"jsonrpc\":\"2.0\"}\n"));
    try testing.expectEqual(FrameAction.refuse_parse, classifyFrame("not json"));
    try testing.expectEqual(FrameAction.refuse_parse, classifyFrame(""));
    try testing.expectEqual(FrameAction.refuse_parse, classifyFrame("\n"));

    var out: [128]u8 = undefined;
    // The id is null because the specification says so, and a frame that is not a
    // request has no id to answer on.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600," ++
            "\"message\":\"Invalid Request\"}}",
        try refusalBody(.refuse_batch, &out),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700," ++
            "\"message\":\"Parse error\"}}",
        try refusalBody(.refuse_parse, &out),
    );

    // The refusal this session writes is a frame this library's own decoder
    // reads, which is what makes it observable rather than merely correct: a
    // peer running this library decodes every inbound frame in `conn.Conn`
    // before it knows whether anything will be matched against it, and one it
    // cannot decode is dropped with no id to answer on. The socket test below
    // is the same claim with a peer on the other end.
    const batch_refusal = try refusalBody(.refuse_batch, &out);
    var scratch: [128]u8 = undefined;
    const refusal = try jsonrpc.decode(batch_refusal, &scratch);
    try testing.expectEqual(jsonrpc.Kind.response, refusal.kind);
    try testing.expect(refusal.id_null);
    try testing.expectEqual(@as(?jsonrpc.Id, null), refusal.id);
    try testing.expectEqual(@as(i32, -32600), refusal.rpc_error.?.code);
    try testing.expectEqualStrings("Invalid Request", refusal.rpc_error.?.message);
    // And it is a value this library holds rather than text it happens to
    // write: PROTOCOLS.md section 2 asks for `encode(decode(b)) == b`, and the
    // bytes come back the same way round, member for member.
    var again: [128]u8 = undefined;
    var writer = json.Writer.init(&again);
    try jsonrpc.encode(refusal, &writer);
    try testing.expectEqualStrings(batch_refusal, writer.written());

    // There is no body for a frame that is dispatched: the connection writes that
    // one, and a transport that also wrote one would double-answer.
    try testing.expectError(error.InvalidField, refusalBody(.dispatch, &out));
}

test "a frame that parsed and is not an object is not a parse error" {
    // PROTOCOLS.md 3.1 draws the line at what the peer sent: `-32700` is invalid
    // JSON, `-32600` is valid JSON which is not a request object. Every one of
    // these parsed, and every one of them is a frame to answer rather than
    // drop, because a peer is waiting to hear what became of what it wrote.
    for ([_][]const u8{ "null", "42", "\"hi\"", "true", "false", " -1.5e3 " }) |frame| {
        try testing.expectEqual(FrameAction.refuse_request, classifyFrame(frame));
    }
    // These did not, so the two refusals do not collapse into one another. A
    // peer told its JSON was malformed when it wrote it correctly would be told
    // the same about bytes that were not, and would look for the fault in its
    // own encoder. None of them begins with a brace or a bracket: an object and
    // an array are decided on that one byte, and what is inside an object is
    // the connection's to decode.
    for ([_][]const u8{ "tru", "\"hi", "42x", "nul", "-", "" }) |frame| {
        try testing.expectEqual(FrameAction.refuse_parse, classifyFrame(frame));
    }

    var out: [128]u8 = undefined;
    // The answer a batch gets, and a different one from a parse error.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600," ++
            "\"message\":\"Invalid Request\"}}",
        try refusalBody(.refuse_request, &out),
    );
}

test "params that are not an object are refused before they are framed" {
    // Every one of these is a refusal rather than an absent member, because the
    // connection omits an absent `params` entirely and the peer would then
    // answer a request the caller never wrote.
    try testing.expectError(error.ParamsNotAnObject, requireObject("[1,2]"));
    try testing.expectError(error.ParamsNotAnObject, requireObject("\"a string\""));
    try testing.expectError(error.ParamsNotAnObject, requireObject("7"));
    try testing.expectError(error.ParamsNotAnObject, requireObject(""));
    // An absent params member is a request that declares none, which is a
    // request the schema allows and the connection writes as written.
    try testing.expectEqual(@as(?[]const u8, null), try requireObject(null));
    try testing.expectEqualStrings("{\"a\":1}", (try requireObject("{\"a\":1}")).?);
    try testing.expectEqualStrings(" {\"a\":1} ", (try requireObject(" {\"a\":1} ")).?);
}

test "a non-object params is refused at the entry point, before a byte is written" {
    var connection: conn.Conn = undefined;
    const blank: [128]u8 = [_]u8{0} ** 128;
    var out: [128]u8 = blank;
    var result: [128]u8 = blank;
    var client: Client = .{ .connection = &connection, .version = .stable };
    var agent: Agent = .{ .connection = &connection, .version = .stable };

    // Each method is one this side may send in the shape this side sends it in,
    // so the gate passes and the refusal is the params and nothing else. The
    // connection is never reached, which is what leaves the peer without a
    // request the caller never wrote.
    try testing.expectError(
        error.ParamsNotAnObject,
        client.request("session/new", "[1,2]", &result, &out),
    );
    try testing.expectError(
        error.ParamsNotAnObject,
        client.notify("session/cancel", "\"cancelled\"", &out),
    );
    try testing.expectError(
        error.ParamsNotAnObject,
        agent.request("session/request_permission", "7", &result, &out),
    );
    try testing.expectError(
        error.ParamsNotAnObject,
        agent.notify("session/update", "[]", &out),
    );
    // Both buffers are as the test left them: a refused call writes nothing, so
    // a caller that mishandles the error cannot find a half-framed request
    // already sitting in its memory.
    try testing.expectEqualSlices(u8, &blank, &out);
    try testing.expectEqualSlices(u8, &blank, &result);
}

test "capability paths are collected in the spelling a gate uses" {
    const entries = [_]acp.Capability{
        .{ .path = "loadSession", .known = true, .form = .boolean, .value = true },
        .{ .path = "session.list", .known = true, .form = .presence_object, .value = null },
    };
    const set: acp.CapabilitySet = .{ .entries = &entries, .present = true };
    var out: [2][]const u8 = undefined;
    const paths = try capabilityPaths(set, &out);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("loadSession", paths[0]);

    // The paths are what a gate consumes, so a session can decide from them
    // without keeping the entries alive.
    const info = try acp.lookupMethod(.stable, "session/list");
    try testing.expect(acp.isMethodSupported(info, paths));

    // Too small a list is refused rather than truncated: a truncated list would
    // report a gate the peer advertised as one it did not.
    var one: [1][]const u8 = undefined;
    try testing.expectError(error.BufferTooSmall, capabilityPaths(set, &one));
}

/// A policy with no decision, for the auto-decide test.
fn decline(_: ?*anyopaque, _: *const acp.PermissionRequest) ?[]const u8 {
    return null;
}

/// A policy that chooses the only option on the table.
fn choose(_: ?*anyopaque, request: *const acp.PermissionRequest) ?[]const u8 {
    const options: []const acp.PermissionOption = switch (request.*) {
        .stable => |value| value.options,
        .draft => |value| value.options,
    };
    if (options.len == 0) return null;
    return options[0].option_id;
}

/// Decode a permission request into a scratch the caller owns.
///
/// The result borrows that buffer wherever a value carries an escape, so a
/// buffer declared in this helper's own frame would be dead before the first
/// option id was read. A test whose fixture holds an escape needs a scratch
/// that outlives the request.
fn decodeRequest(
    version: acp.WireVersion,
    raw: []const u8,
    out_options: []acp.PermissionOption,
    scratch: []u8,
) !acp.PermissionRequest {
    return acp.decodePermissionRequest(version, raw, out_options, scratch);
}

// --- The loopback exchange ----------------------------------------------------

/// The params the agent sends for its permission request. The agent decodes this
/// same text to read the answer back, so the option ids an answer names are the
/// ones the agent actually offered.
const permission_params =
    "{\"sessionId\":\"s9\",\"toolCall\":{},\"options\":[" ++
    "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_once\"}]}";

/// The buffers one side needs. Caller-owned, so the test cannot hide an
/// allocation behind the session.
const Side = struct {
    frame_buffer: [8192]u8 = undefined,
    pending: [4]conn.Slot = undefined,
    /// Where an inbound frame is decoded into, and the region `conn.Conn` lends
    /// a handler to decode into.
    decode_scratch: [1024]u8 = undefined,
    /// Where a handler writes its answer, and the region `conn.Conn` lends a
    /// handler to write into. `init` refuses a pair that shares a byte with
    /// `decode_scratch`, and neither handler below carves either one.
    answer: [4096]u8 = undefined,
    /// The client's permission request, decoded beside the two regions above
    /// rather than inside one of them.
    ///
    /// The handler decodes twice — the JSON-RPC envelope and the permission
    /// request inside it — and the envelope's id is echoed after the request's
    /// option ids have been read, so both borrows are live at once. One decode
    /// region cannot hold both: the escape offset is per reader, so the second
    /// decode starts at offset 0 and writes over what the first left there.
    permission_request: [1024]u8 = undefined,
    /// The outcome the client composes, beside `answer` rather than inside it.
    ///
    /// `conn.respond` writes the envelope's first bytes into the answer region
    /// before it splices the outcome in, so an outcome written at the head of
    /// that region is gone before it is read, and the frame says nothing about
    /// what the user chose.
    permission_outcome: [256]u8 = undefined,
    out: [1024]u8 = undefined,
    result: [1024]u8 = undefined,
    params: [1024]u8 = undefined,
    /// The agent's own outbound call, kept apart from `out` so a test assertion
    /// on the bytes the *client* sent is not overwritten by the agent's request.
    call_out: [1024]u8 = undefined,
    call_result: [1024]u8 = undefined,
    /// Caller-owned storage for the capability decode, so the paths the client
    /// gates on outlive the call that produced them.
    cap_entries: [8]acp.Capability = undefined,
    cap_paths: [256]u8 = undefined,
    cap_scratch: [1024]u8 = undefined,
    cap_list: [8][]const u8 = undefined,
};

const Endpoint = struct {
    side: Side = .{},
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    /// Held here rather than as locals: the connection keeps raw pointers to both
    /// interfaces, and a local would dangle before the first read.
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,
    stream: Io.net.Stream = undefined,
    connection: conn.Conn = undefined,
    /// Whether this endpoint's descriptor is gone already.
    ///
    /// The task that owns the endpoint hangs up itself, and the pump hangs up
    /// after it, so the two can both reach for the same stream.
    closed: bool = false,

    /// Take the stream and hand it to a connection over `Side`'s buffers.
    ///
    /// Whatever `conn.Conn.init` refuses is refused here: the buffers are the
    /// test's own, so there is no caller to grow one and a task reports it as a
    /// failed test rather than as a fault the peer committed.
    ///
    /// The orphan hook is installed here rather than by the caller afterwards,
    /// because `open` spawns the reader task: a peer that answers the instant
    /// it is connected would be heard by nobody, which is the fault the hook
    /// exists to remove.
    fn open(
        self: *Endpoint,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
        orphan: ?conn.OrphanHandler,
    ) conn.Error!void {
        self.adopt(io, stream);
        self.connection = try conn.Conn.init(io, &self.reader.interface, &self.writer.interface, .{
            .frame_buffer = &self.side.frame_buffer,
            .pending = &self.side.pending,
            .decode_scratch = &self.side.decode_scratch,
            .answer = &self.side.answer,
        });
        if (handler) |h| self.connection.setHandler(h);
        if (orphan) |h| self.connection.setOrphanHandler(h);
        // Spawned on the group the test joins, because `Io.Group.async` does not
        // promise to run its task until the group is awaited or cancelled.
        group.async(io, pump, .{self});
    }

    /// Take the stream and its two interfaces, with no connection over them.
    ///
    /// A transport that only writes needs the stream and the framing and
    /// nothing else. A connection over it would park a reader on a socket no
    /// peer is writing to, and the group would wait for a task with nothing to
    /// do.
    fn adopt(self: *Endpoint, io: Io, stream: Io.net.Stream) void {
        self.stream = stream;
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
    }

    /// Hang up, and release the descriptor once.
    ///
    /// `shutdown` before `close`: closing a descriptor does not interrupt a read
    /// already blocked on it, so the peer's pump would sit on an open
    /// description and the group would never finish. The flag is the guard: the
    /// endpoint's own task hangs up and then waits for the group, so the pump
    /// must not close a descriptor that task already released.
    fn hangUp(self: *Endpoint, io: Io) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.shutdown(io, .both) catch {};
        self.stream.close(io);
    }

    /// Drive the connection, then release the descriptor it drained.
    ///
    /// A pump that returns has seen the end of the stream, and a descriptor left
    /// to the process at exit is one the peer has nothing to shut down: in the
    /// permission exchange the serving side hangs up and then waits for the
    /// group, so a pump that only returned would leave the group waiting on a
    /// descriptor nobody had released. `hangUp` is idempotent, so an endpoint
    /// whose task already hung up is not closed twice.
    fn pump(self: *Endpoint) void {
        self.connection.pump();
        self.hangUp(self.connection.io);
    }
};

/// What a side reports back to the test after its exchange.
const Outcome = struct {
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Set by the side that makes the outbound call, so the serving side can
    /// hang up without racing a call that is still in flight.
    done: bool = false,
    failed: bool = false,
    /// The version the client's `initialize` settled on.
    negotiated: ?acp.WireVersion = null,
    /// The agent's advertised capability path, as the client stored it.
    agent_path: []const u8 = "",
    /// What `session/load` came back with.
    loaded: []const u8 = "",
    /// How many requests the agent's handler answered.
    agent_calls: usize = 0,
    /// The client's refusal of `session/delete`.
    delete_refused: bool = false,
    /// The permission exchange, agent to client.
    permission_version: ?acp.WireVersion = null,
    permission: PermissionDecision = .{ .unreadable = error.MissingField },

    fn set(self: *Outcome, io: Io) void {
        self.mutex.lock(io) catch return;
        self.done = true;
        self.condition.broadcast(io);
        self.mutex.unlock(io);
    }

    /// Block until the calling side has finished. A barrier rather than a sleep:
    /// the test passes when the exchange finished, not when it waited long enough
    /// to look finished.
    fn wait(self: *Outcome, io: Io) void {
        self.mutex.lock(io) catch return;
        while (!self.done) self.condition.wait(io, &self.mutex) catch return;
        self.mutex.unlock(io);
    }
};

/// The agent's handler: answers `initialize` with a real response envelope
/// carrying the request's own id, and counts everything it is asked.
fn agentHandler(
    ctx: ?*anyopaque,
    frame: []const u8,
    decode_scratch: []u8,
    answer: []u8,
) conn.Error!?[]const u8 {
    const state: *Outcome = @ptrCast(@alignCast(ctx.?));
    // The two regions the connection lends are the whole of what this handler
    // needs, so neither is carved: the frame is decoded into one and the answer
    // is composed into the other. A handler that decoded into the region it
    // wrote its answer into would have the writer's first bytes land on the
    // method name it is about to compare, because the escape offset
    // `json.Reader` keeps is per reader and not per buffer.
    //
    // The request shape, so the answer carries the id the client chose and the
    // envelope is the shared builder's. A response is not a request and never
    // reaches a builder.
    const request = jsonrpc.decodeRequest(frame, decode_scratch) catch return null;
    state.agent_calls += 1;

    if (std.mem.eql(u8, request.method.text, "initialize")) {
        // `loadSession` and nothing else, so exactly one gated method is open
        // to the client and exactly one is refused.
        return conn.respond(
            request,
            "{\"protocolVersion\":1," ++
                "\"agentCapabilities\":{\"loadSession\":true}," ++
                "\"agentInfo\":{\"name\":\"test-agent\"}}",
            answer,
        ) catch null;
    }
    return conn.respond(request, "{\"sessionId\":\"s9\"}", answer) catch null;
}

/// The client answers the agent's permission request. Runs inline on the client's
/// reader task, so it may encode a body but must not call back on the same
/// connection.
///
/// `ctx` is the side's own [`Side`], which owns the two regions the connection
/// does not lend. Four regions are live at once: the frame's borrows, the
/// decoded permission request, the outcome, and the envelope. The first and the
/// last are the parameters and neither is carved; the two in between are
/// fields, because the escape offset `json.Reader` keeps is per reader and not
/// per buffer, so a second decode into one region starts at offset 0 again and
/// writes over what the first left there.
fn clientPermissionHandler(
    ctx: ?*anyopaque,
    frame: []const u8,
    decode_scratch: []u8,
    answer: []u8,
) conn.Error!?[]const u8 {
    const side: *Side = @ptrCast(@alignCast(ctx.?));

    // The request shape, so the answer carries the id the agent chose and the
    // envelope is the shared builder's rather than an assembly of members here.
    const call = jsonrpc.decodeRequest(frame, decode_scratch) catch return null;
    if (!std.mem.eql(u8, call.method.text, "session/request_permission")) return null;
    const params: []const u8 = switch (call.params) {
        .value => |value| value,
        else => return null,
    };

    // The params the agent built from the request it holds, read the way a
    // client reads them. The option answered here is named by an id that
    // arrived over the socket, so an agent whose own copy of the request
    // disagreed with these bytes would find no such option and would read the
    // answer as unreadable rather than as a grant.
    var options: [4]acp.PermissionOption = undefined;
    const request = acp.decodePermissionRequest(
        .stable,
        params,
        &options,
        &side.permission_request,
    ) catch return null;
    if (request.stable.options.len == 0) return null;

    // Composed beside the answer and not inside it. `conn.respond` writes the
    // envelope's opening bytes into the answer region before it splices the
    // outcome in, so an outcome written at the head of that region is gone
    // before it is read, and the frame says nothing about what the user chose.
    const outcome = answerPermission(
        &request,
        .{ .selected = request.stable.options[0].option_id },
        &side.permission_outcome,
    ) catch return null;
    return conn.respond(call, outcome, answer) catch null;
}

test "the client's answer is composed beside the outcome it splices in" {
    // The frame as an agent sends it. Both of the values a decode borrows into
    // a region of its own carry an escape: the string id, which the answer
    // echoes, and the option id, which the answer names. An escape is the one
    // thing that makes a reader write rather than borrow, and the first write a
    // reader makes starts at offset 0 again. So a request decoded into the
    // region the frame was decoded into leaves the answer echoing the option id
    // where the id was, and an outcome composed at the head of the answer is
    // gone before the envelope splices it in.
    const params =
        "{\"sessionId\":\"s9\",\"toolCall\":{},\"options\":[" ++
        "{\"optionId\":\"\\u0079es\",\"name\":\"Yes\",\"kind\":\"allow_once\"}]}";
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":\"p\\u0031\"," ++
        "\"method\":\"session/request_permission\",\"params\":" ++ params ++ "}";

    var side: Side = .{};
    const answered = try clientPermissionHandler(&side, frame, &side.decode_scratch, &side.answer);
    const envelope = answered orelse return error.TestUnexpectedResult;

    // The frame is a whole answer, which it is only if the outcome was composed
    // into bytes the envelope did not overwrite on its way to the splice.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"result\":" ++
            "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"yes\"}}}",
        envelope,
    );
    // And the outcome the client composed is still there, beside the answer
    // rather than under it.
    try testing.expect(std.mem.startsWith(
        u8,
        side.permission_outcome[0..],
        "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"yes\"}}",
    ));

    // Read back the way an agent reads it: the same params into the agent's own
    // request region, and this answer through a third. The escaped id arrives
    // unescaped on both sides, so the option the client named is the option the
    // agent offered, and the answer is the grant rather than an id that matched
    // itself.
    var agent_options: [1]acp.PermissionOption = undefined;
    var agent_request: [512]u8 = undefined;
    const asked = try decodeRequest(.stable, params, &agent_options, &agent_request);
    var envelope_scratch: [512]u8 = undefined;
    var outcome_region: [256]u8 = undefined;
    const result = json.memberText(envelope, "result", &envelope_scratch) orelse
        return error.TestUnexpectedResult;
    const decision = readOutcome(result, &asked, &agent_request, &outcome_region);
    try testing.expectEqual(@as(?ReadableOutcome, .{ .grants = true }), decision.readable());
}

test "a client negotiates and gates against an agent over a real socket" {
    // The unit tests above decide what a session *would* do. Only a real socket
    // shows that the reader task runs and that a locally refused call never
    // reaches the peer.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    var address = try listenOn(io, &path_buffer, 0x5eed_0101);
    defer address.server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, address.path) catch {};

    var state: Outcome = .{};
    var agent_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};

    // One group drives both sides. Two would deadlock: the client blocks waiting
    // for an answer only the peer's task can produce, so awaiting the client
    // group first would never let the peer run.
    var group: Io.Group = .init;
    var server_task = ServerTask{
        .io = io,
        .group = &group,
        .server = &address.server,
        .endpoint = &agent_endpoint,
        .state = &state,
    };
    var client_task = ClientTask{
        .io = io,
        .group = &group,
        .address = &address.address,
        .endpoint = &client_endpoint,
        .state = &state,
    };
    group.async(io, ServerTask.run, .{&server_task});
    group.async(io, ClientTask.run, .{&client_task});
    group.await(io) catch {};

    try testing.expect(!state.failed);
    // The handshake agreed on the stable version, and the agent's advertised
    // capability is the client's to gate on from then on.
    try testing.expectEqual(acp.WireVersion.stable, state.negotiated.?);
    try testing.expectEqualStrings("loadSession", state.agent_path);

    // The gated call the agent advertised came back with the agent's own result,
    // over the socket, and the agent answered exactly the two requests the client
    // was allowed to send.
    try testing.expectEqualStrings("{\"sessionId\":\"s9\"}", state.loaded);
    try testing.expectEqual(@as(usize, 2), state.agent_calls);

    // The gated call the agent did not advertise never left the client.
    try testing.expect(state.delete_refused);
}

test "an agent reads a permission outcome a client returned over a real socket" {
    // The other direction, and the one the safety rule lives in. The agent asks
    // for a permission, the client answers with an option id it read off the
    // wire, and the agent reads what came back as a grant. It can only read it as
    // a grant because the request it sent and the request it checks the answer
    // against are the same value.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    var address = try listenOn(io, &path_buffer, 0x5eed_0102);
    defer address.server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, address.path) catch {};

    var state: Outcome = .{};
    var agent_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};

    var group: Io.Group = .init;
    var asking = PermissionCaller{
        .io = io,
        .group = &group,
        .server = &address.server,
        .endpoint = &agent_endpoint,
        .state = &state,
    };
    var serving = PermissionServer{
        .io = io,
        .group = &group,
        .address = &address.address,
        .endpoint = &client_endpoint,
        .state = &state,
    };
    group.async(io, PermissionCaller.run, .{&asking});
    group.async(io, PermissionServer.run, .{&serving});
    group.await(io) catch {};

    try testing.expect(!state.failed);
    try testing.expectEqual(acp.WireVersion.stable, state.permission_version.?);
    // The option the agent offered was one that grants, and the id the client
    // named came back out of the params the agent built for it. An agent that
    // sent a request other than the one it holds would have found no such option
    // and read this as unreadable rather than as approval.
    try testing.expectEqual(true, state.permission.grants);
    try testing.expectEqual(ReadableOutcome{ .grants = true }, state.permission.readable().?);
}

test "a peer running this library is told of a refusal it sent with a null id" {
    // The whole round trip the refusal depends on, over a real socket. A peer
    // sends a batch array; this session's transport classifies it and answers
    // with the specification's own `Invalid Request` under a `null` id; and a
    // peer running this library's own reader has to hear it. It did not, and
    // not because the refusal was suppressed: `jsonrpc` refused the frame as a
    // value of the wrong type for an id, so `conn.Conn` dropped it in `route`
    // exactly as it drops any frame it cannot decode, and the peer that wrote
    // it learned nothing at all.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buffer: [128]u8 = undefined;
    var address = try listenOn(io, &path_buffer, 0x5eed_0103);
    defer address.server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, address.path) catch {};

    var seen: OrphanSeen = .{ .io = io };
    var agent_endpoint: Endpoint = .{};
    var client_endpoint: Endpoint = .{};

    var group: Io.Group = .init;
    var refusing = RefusingServer{
        .io = io,
        .server = &address.server,
        .endpoint = &agent_endpoint,
        .seen = &seen,
    };
    var listening = RefusingClient{
        .io = io,
        .group = &group,
        .address = &address.address,
        .endpoint = &client_endpoint,
        .seen = &seen,
    };
    group.async(io, RefusingServer.run, .{&refusing});
    group.async(io, RefusingClient.run, .{&listening});
    group.await(io) catch {};

    // Told once, with the code and the message the peer actually wrote rather
    // than with a guess at which request it belonged to. There is no such
    // guess here: the id is `null` because the peer could not determine one.
    try testing.expectEqual(@as(usize, 1), seen.calls);
    try testing.expectEqual(@as(i32, -32600), seen.code);
    try testing.expectEqualStrings("Invalid Request", seen.text());
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
        "/tmp/zig-agent-proto-acp-session-{x}.sock",
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

/// Serves the client's calls and returns, so the client's reader is the only
/// task left on this side.
const ServerTask = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    state: *Outcome,

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch {
            self.state.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = self.state,
            .call = agentHandler,
        }, null) catch {
            self.state.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
    }
};

const ClientTask = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    state: *Outcome,

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch {
            self.state.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null, null) catch {
            self.state.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };

        const side = &self.endpoint.side;
        var client: Client = .{ .connection = &self.endpoint.connection, .version = .stable };

        const handshake = client.initialize(
            1,
            "{\"name\":\"test-client\"}",
            "{\"terminal\":true}",
            &side.result,
            &side.out,
            &side.params,
            &side.decode_scratch,
        ) catch {
            self.state.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
        self.state.negotiated = handshake.version;

        // Decode the capability paths the agent advertised and adopt them. An
        // empty advertised set would report `loadSession` unsupported and the
        // gated call below would be refused, so this is also the assertion that
        // the handshake carried capabilities at all.
        const paths = blk: {
            const set = acp.decodeCapabilityObject(
                .stable,
                .agent,
                handshake.capabilities orelse "{}",
                &side.cap_entries,
                &side.cap_paths,
                &side.cap_scratch,
            ) catch {
                self.state.failed = true;
                break :blk side.cap_list[0..0];
            };
            break :blk capabilityPaths(set, &side.cap_list) catch side.cap_list[0..0];
        };
        if (paths.len != 0) self.state.agent_path = paths[0];
        client.setAgentCapabilities(paths);

        const loaded = client.request(
            "session/load",
            "{\"sessionId\":\"s9\"}",
            &side.result,
            &side.out,
        ) catch {
            self.state.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
        self.state.loaded = loaded.body;

        // A gated method the agent never advertised is refused here, and the
        // agent's handler never sees it.
        const refused = client.request(
            "session/delete",
            "{\"sessionId\":\"s9\"}",
            &side.result,
            &side.out,
        );
        if (refused) |_| {
            self.state.failed = true;
        } else |err| {
            self.state.delete_refused = err == error.NotPermitted;
        }

        self.endpoint.hangUp(self.io);
    }
};

/// Accepts one connection and asks the client for a permission, then reads the
/// answer and hangs up.
const PermissionCaller = struct {
    io: Io,
    group: *Io.Group,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    state: *Outcome,

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch {
            self.state.failed = true;
            self.state.set(self.io);
            return;
        };
        self.endpoint.open(self.io, self.group, stream, null, null) catch {
            self.state.failed = true;
            self.state.set(self.io);
            self.endpoint.hangUp(self.io);
            return;
        };

        const side = &self.endpoint.side;
        var agent: Agent = .{ .connection = &self.endpoint.connection, .version = .stable };

        // The request the agent means to ask with, decoded once and held. The
        // two scratches are regions of their own, so the option ids the answer
        // is checked against cannot be written over by the answer's own decode.
        var options: [1]acp.PermissionOption = undefined;
        var request_scratch: [512]u8 = undefined;
        const sent = acp.decodePermissionRequest(
            .stable,
            permission_params,
            &options,
            &request_scratch,
        ) catch {
            self.state.failed = true;
            self.state.set(self.io);
            self.endpoint.hangUp(self.io);
            return;
        };
        var outcome_scratch: [256]u8 = undefined;
        self.state.permission_version = agent.version;
        // One call sends the request and reads the answer against it, so the
        // option ids the client named are the ids this agent checks.
        self.state.permission = agent.requestPermission(
            &sent,
            &side.call_result,
            &side.call_out,
            &side.params,
            &request_scratch,
            &outcome_scratch,
        ) catch {
            self.state.failed = true;
            self.state.set(self.io);
            self.endpoint.hangUp(self.io);
            return;
        };
        self.endpoint.hangUp(self.io);
        self.state.set(self.io);
    }
};

/// Connects, answers whatever the agent asks, and waits for the agent to hang
/// up before closing its own end.
const PermissionServer = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    state: *Outcome,

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch {
            self.state.failed = true;
            return;
        };
        self.endpoint.open(self.io, self.group, stream, .{
            .ctx = &self.endpoint.side,
            .call = clientPermissionHandler,
        }, null) catch {
            self.state.failed = true;
            self.endpoint.hangUp(self.io);
            return;
        };
        // The agent's call is in flight on the other side of this socket, and
        // closing now would race it: the answer would arrive at a connection that
        // no longer existed.
        self.state.wait(self.io);
        self.endpoint.hangUp(self.io);
    }
};

/// What the client saw of a response that matched no call.
///
/// Its own type because the hook is handed the decoded message and nothing
/// else: there is no `Io` to lock with, and the connection's is not reachable
/// from here. The code and the message are copied out of the connection's
/// decode region, which the next frame overwrites, so keeping a slice of it
/// would name whatever was decoded after.
const OrphanSeen = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    calls: usize = 0,
    code: i32 = 0,
    message: [64]u8 = undefined,
    message_len: usize = 0,

    fn told(ctx: ?*anyopaque, message: jsonrpc.Message) void {
        const self: *OrphanSeen = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        // Only a refusal carries an error. The hook is handed every response
        // that matched no call, and an id naming a call that has already
        // returned is the ordinary shape of a subscription's second response,
        // so a frame carrying no `error` is counted and not unwrapped.
        if (message.rpc_error) |object| {
            const n = @min(object.message.len, self.message.len);
            @memcpy(self.message[0..n], object.message[0..n]);
            self.message_len = n;
            self.code = object.code;
        }
        self.calls += 1;
        self.condition.broadcast(self.io);
    }

    /// Block until a response has been told. A barrier rather than a sleep: the
    /// test passes when the frame arrived, not when it waited long enough to
    /// look as though it had.
    fn wait(self: *OrphanSeen) void {
        self.mutex.lock(self.io) catch return;
        while (self.calls == 0) self.condition.wait(self.io, &self.mutex) catch return;
        self.mutex.unlock(self.io);
    }

    fn text(self: *const OrphanSeen) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// Refuses the one frame it is sent, which is what a transport does with a
/// batch array this session declines.
///
/// It reads nothing and answers nothing: the frame it refuses is a constant and
/// the part under test is what the peer does with the answer. The
/// classification still runs, because a transport that wrote a refusal for an
/// action it had not reached would be testing a frame nobody classified.
const RefusingServer = struct {
    io: Io,
    server: *Io.net.Server,
    endpoint: *Endpoint,
    seen: *OrphanSeen,

    const batch = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\"}]";

    fn run(self: *@This()) void {
        const stream = self.server.accept(self.io) catch return;
        self.endpoint.adopt(self.io, stream);
        // Every path out of here releases the descriptor, because a client
        // waiting on a refusal is waiting on a socket this side holds.
        defer self.endpoint.hangUp(self.io);

        var out: [128]u8 = undefined;
        const body = refusalBody(classifyFrame(batch), &out) catch return;
        framing.writeFrame(body, &self.endpoint.writer.interface) catch return;
        self.endpoint.writer.interface.flush() catch return;
        // The client's reader has the frame by the time the hook fires, and
        // closing before that would race a reader that has not looked at the
        // bytes yet.
        self.seen.wait();
    }
};

/// Connects, and waits for the refusal it is about to be sent.
const RefusingClient = struct {
    io: Io,
    group: *Io.Group,
    address: *const Io.net.UnixAddress,
    endpoint: *Endpoint,
    seen: *OrphanSeen,

    fn run(self: *@This()) void {
        const stream = self.address.connect(self.io) catch return;
        // No handler: the frame that arrives is a response, and a connection
        // with no handler installed answers nobody, which is the point.
        self.endpoint.open(self.io, self.group, stream, null, .{
            .ctx = self.seen,
            .call = OrphanSeen.told,
        }) catch {
            self.endpoint.hangUp(self.io);
            return;
        };

        self.seen.wait();
        self.endpoint.hangUp(self.io);
    }
};
