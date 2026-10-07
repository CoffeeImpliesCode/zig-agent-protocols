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
//! - **Receiving** returns a [`PermissionDecision`], a union whose third arm is
//!   `unreadable`. An outcome this library cannot read never becomes
//!   `grants = true`: it becomes `unreadable`, carrying the decode error, and a
//!   two-arm `switch` over `grants` and `cancelled` does not compile against it.
//!   A wildcard arm is the agent's explicit decision to stop, which is the only
//!   decision 6.6 leaves it.
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
//! ## Allocating
//!
//! `ARCHITECTURE.md` section 4 lets the runtime allocate where state is
//! genuinely dynamic. A session holds none: every buffer, including the
//! capability path list, is the caller's.

const std = @import("std");
const acp = @import("acp.zig");
const conn = @import("conn.zig");
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
    /// An `initialize` the pinned version cannot express: v2 requires `info`
    /// and no other member carries it.
    MissingInfo,
    /// A permission answer named an option the request did not offer.
    ///
    /// The option list is the only place a permission was ever defined, so an id
    /// from anywhere else answers nothing.
    UnknownPermissionOption,
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
    /// Neither an object nor an array, so the frame is not a JSON-RPC value.
    /// Report `Parse error` with a null id.
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
    return switch (trimmed[0]) {
        '{' => .dispatch,
        '[' => .refuse_batch,
        else => .refuse_parse,
    };
}

/// The JSON-RPC error body a transport sends for a frame it refused.
///
/// The id is `null` because the specification says so for both refusals, and
/// because a frame that is not a request has no id to answer on. This library's
/// own decoder refuses a `null` id on a message it is *matching* a call against,
/// which is a different thing: a refusal is never matched, it is written.
pub fn refusalBody(action: FrameAction, out: []u8) root.EncodeError![]const u8 {
    const code: []const u8, const message: []const u8 = switch (action) {
        .dispatch => return error.InvalidField,
        .refuse_batch => .{ "-32600", "Invalid Request" },
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

/// What a call came back with.
///
/// The error code stays on the reply rather than becoming a Zig error: the ACP
/// binding has its own error codes (PROTOCOLS.md section 7), a caller usually
/// wants the message, and collapsing "the peer answered with an error" into a Zig
/// error would make a remote `-32601` and a local `error.NotPermitted`
/// indistinguishable at the call site.
pub const Reply = struct {
    /// The `result` member as raw JSON, or the `error` member as raw JSON when
    /// the peer answered with an error. Borrows the caller's result buffer.
    body: []const u8,
    /// The JSON-RPC error code, or null when the call succeeded.
    error_code: ?i32,

    /// Whether the peer answered with an error rather than a result.
    pub fn failed(self: Reply) bool {
        return self.error_code != null;
    }
};

// --- The client side ----------------------------------------------------------

/// A client bound to one negotiated wire version.
pub const Client = struct {
    connection: *conn.Conn,
    /// The version this session speaks. Set by `init` to the version the client
    /// asks for, and replaced by the one the agent answered with, so every later
    /// call is checked against what the two sides actually agreed on.
    version: acp.WireVersion,
    /// The agent's advertised capability paths, as produced by
    /// [`capabilityPaths`]. Empty until the handshake, and empty means every
    /// gated method is refused.
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
    pub fn request(
        self: *Client,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
    ) Error!Reply {
        _ = try self.gate(method, .request);
        const answer = try self.connection.call(method, requireObject(params), result, out);
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
        return self.connection.notify(method, requireObject(params), out);
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
            // The agent refused. Nothing is pinned, because nothing was agreed,
            // and reporting the refusal beats inventing a version.
            return .{
                .version = null,
                .body = answer.body,
                .error_code = answer.error_code,
                .capabilities = null,
                .auth_methods = false,
            };
        }

        // Reported rather than guessed at: the version is what everything
        // downstream depends on, and a body this layer cannot read has none.
        const number = readProtocolVersion(answer.body, scratch) catch
            return error.NotAResult;
        const agreed = acp.WireVersion.fromNumber(number);
        const caps_member: []const u8 = if (asked == .stable)
            "agentCapabilities"
        else
            "capabilities";

        // Recorded even when the version is unusable, because a caller logging a
        // refused handshake wants the whole answer and the gate decisions that
        // follow from it are the caller's to make.
        self.auth_methods = advertisesAuthMethods(memberText(answer.body, "authMethods", scratch));
        const advertised = memberText(answer.body, caps_member, scratch);
        if (agreed) |version| self.version = version else self.agent_capabilities = &.{};

        return .{
            .version = agreed,
            .body = answer.body,
            .error_code = null,
            .capabilities = advertised,
            .auth_methods = self.auth_methods,
        };
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
    pub fn accepts(self: Client, method: []const u8) bool {
        _ = checkCall(
            self.version,
            method,
            .request,
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
    /// `acp.decodeCapabilityObject`, or null when the agent advertised none.
    /// Borrowed from `body`.
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
    /// of the session has to act as it. `agent_supports_nothing` leaves the
    /// session unpinned and reports `error.NotPermitted`: there is no version to
    /// pin, and pinning the client's own number would claim the agent speaks
    /// something it does not.
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
    pub fn request(
        self: *Agent,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
    ) Error!Reply {
        _ = try self.gate(method, .request);
        const answer = try self.connection.call(method, requireObject(params), result, out);
        return .{ .body = answer.body, .error_code = answer.error_code };
    }

    /// Notify a client method, gated locally.
    pub fn notify(
        self: *Agent,
        method: []const u8,
        params: ?[]const u8,
        out: []u8,
    ) Error!void {
        _ = try self.gate(method, .notification);
        return self.connection.notify(method, requireObject(params), out);
    }

    /// Whether a method the client called is one this agent serves at the pinned
    /// version, with the gates the client satisfied.
    pub fn accepts(self: Agent, method: []const u8) bool {
        _ = self.gate(method, .request) catch return false;
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
};

/// Read the outcome an agent received, without ever defaulting to approval.
///
/// `body` is the `result` member of the client's answer, so the nesting
/// `{"outcome":{...}}` that PROTOCOLS.md 6.6 specifies is peeled here rather than
/// demanded of the caller. `request` is the request the outcome answers, and it
/// is what the option id is checked against: the option list is the only place a
/// permission was defined, so an id that is not on it is consent to nothing and is
/// reported rather than read as a grant.
pub fn readOutcome(
    body: []const u8,
    request: *const acp.PermissionRequest,
    scratch: []u8,
) PermissionDecision {
    const outcome_text = memberText(body, "outcome", scratch) orelse
        return .{ .unreadable = error.MissingField };
    const outcome = acp.decodePermissionOutcome(outcome_text, scratch) catch |err| {
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

/// The error body an agent sends for a method it does not have at this version,
/// or a gate the caller did not satisfy.
pub fn methodNotFound(id: jsonrpc.Id, out: []u8) root.EncodeError![]const u8 {
    var writer = json.Writer.init(out);
    try writer.slice("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(id, &writer);
    try writer.slice(",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    return writer.written();
}

fn writeId(id: jsonrpc.Id, writer: *json.Writer) root.EncodeError!void {
    switch (id) {
        .integer => |value| {
            var digits: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch
                return error.BufferTooSmall;
            try writer.slice(text);
        },
        .string => |text| try writer.string(text),
    }
}

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

/// A member's value as raw JSON, or null when the object does not carry a usable
/// one.
///
/// An explicit `null` is null too: every caller here wants to know whether there
/// is a value to read, and a `null` member is the schema's way of saying there is
/// not one.
fn memberText(body: []const u8, name: []const u8, scratch: []u8) ?[]const u8 {
    var reader = json.Reader.init(body);
    if (reader.beginObject() catch return null) return null;
    var found: ?[]const u8 = null;
    while (reader.nextKey(scratch) catch return null) |key| {
        if (std.mem.eql(u8, key, name)) {
            const value = reader.rawValue(scratch) catch return null;
            if (std.mem.eql(u8, value, "null")) return null;
            found = value;
        } else {
            reader.skipValue(scratch) catch return null;
        }
    }
    return found;
}

/// The params a call is allowed to send.
///
/// ACP params are objects in every version; a batch array is the one thing this
/// session refuses, and it is refused above, before a body is built. Checking
/// here means an array cannot reach the connection and become a frame the peer
/// fails to decode three layers away.
fn requireObject(params: ?[]const u8) ?[]const u8 {
    const value = params orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
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
    try testing.expect(!bare.accepts("elicitation/create"));
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
    try testing.expect(agent.accepts("terminal/create"));
    try testing.expect(agent.accepts("terminal/release"));
    // A capability the client never advertised is refused, whatever the method
    // is: both terminal methods are gated on the same `terminal` boolean, so
    // one of them answering would mean the gate is not per-method.
    try testing.expect(!agent.accepts("fs/write_text_file"));
    try testing.expect(!agent.accepts("session/load"));
}

test "an outcome this library cannot read is never approval" {
    var options: [2]acp.PermissionOption = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_once\"}," ++
            "{\"optionId\":\"no\",\"name\":\"No\",\"kind\":\"reject_once\"}]}",
        &options,
    );
    var scratch: [256]u8 = undefined;

    // The shapes a newer or hostile client could send. None may read as a grant,
    // and each carries the reason so an agent can log why it stopped.
    for ([_][]const u8{
        "{\"outcome\":{\"outcome\":\"approved\"}}",
        "{\"outcome\":{\"outcome\":\"allow_once\",\"optionId\":\"yes\"}}",
        "{\"outcome\":{\"outcome\":\"selected\"}}",
        "{\"outcome\":{}}",
        "{\"outcome\":[]}",
        "{\"outcome\":null}",
    }) |body| {
        const decision = readOutcome(body, &request, &scratch);
        switch (decision) {
            .unreadable => |err| try testing.expect(err != error.BufferTooSmall),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "an outcome naming an option the request never offered is consent to nothing" {
    var options: [1]acp.PermissionOption = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_once\"}]}",
        &options,
    );
    var scratch: [256]u8 = undefined;

    // An `allow_once` option was on the table somewhere, so a caller could
    // plausibly reach for an id from another request. It is not this request's
    // option, and answering it would be consent granted for a choice nobody was
    // shown.
    const wrong = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"other-request"}}
    , &request, &scratch);
    try testing.expect(wrong == .unreadable);

    // The same shape, naming the option this request did offer, does grant. So
    // the refusal is about the id and not about the decoder failing.
    const right = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"yes"}}
    , &request, &scratch);
    try testing.expectEqual(true, right.grants);
}

test "a v2 catch-all option kind is unreadable, not a grant and not a refusal" {
    var options: [2]acp.PermissionOption = undefined;
    const source = "{\"sessionId\":\"s1\",\"title\":\"Run\",\"subject\":null,\"options\":[" ++
        "{\"optionId\":\"a\",\"name\":\"Run\",\"kind\":\"allow_once\"}," ++
        "{\"optionId\":\"ext\",\"name\":\"Always via policy\",\"kind\":\"_vendor\"}]}";
    const request = try decodeRequest(.draft, source, &options);
    var scratch: [512]u8 = undefined;

    // The schema defines the fifth string, so the option is real and a client may
    // legitimately offer it. What the library may not do is claim what choosing
    // it means: `grants` is the one value 6.6 forbids inferring, and `false`
    // would claim the client refused a choice it made.
    const decision = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"ext"}}
    , &request, &scratch);
    switch (decision) {
        .unreadable => |err| try testing.expectEqual(@as(root.DecodeError, error.UnknownTag), err),
        else => return error.TestUnexpectedResult,
    }

    // The named option next to it still resolves, so the refusal is about the
    // kind and not about the request.
    const known = readOutcome(
        \\{"outcome":{"outcome":"selected","optionId":"a"}}
    , &request, &scratch);
    try testing.expectEqual(true, known.grants);
}

test "a cancellation is read as a cancellation and never as a grant" {
    var options: [1]acp.PermissionOption = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_always\"}]}",
        &options,
    );
    var scratch: [256]u8 = undefined;
    try testing.expect(readOutcome(
        \\{"outcome":{"outcome":"cancelled"}}
    , &request, &scratch) == .cancelled);
}

test "answering a permission request writes the nested outcome the spec states" {
    var options: [2]acp.PermissionOption = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_once\"}," ++
            "{\"optionId\":\"no\",\"name\":\"No\",\"kind\":\"reject_once\"}]}",
        &options,
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

test "a policy with no decision refuses rather than approves" {
    var options: [1]acp.PermissionOption = undefined;
    const request = try decodeRequest(
        .stable,
        "{\"sessionId\":\"s1\",\"toolCall\":{},\"options\":[" ++
            "{\"optionId\":\"yes\",\"name\":\"Yes\",\"kind\":\"allow_always\"}]}",
        &options,
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
    // There is no body for a frame that is dispatched: the connection writes that
    // one, and a transport that also wrote one would double-answer.
    try testing.expectError(error.InvalidField, refusalBody(.dispatch, &out));
}

test "params that are not an object are refused before they are framed" {
    try testing.expectEqual(@as(?[]const u8, null), requireObject("[1,2]"));
    try testing.expectEqual(@as(?[]const u8, null), requireObject("\"a string\""));
    try testing.expectEqual(@as(?[]const u8, null), requireObject(""));
    try testing.expectEqual(@as(?[]const u8, null), requireObject(null));
    try testing.expectEqualStrings("{\"a\":1}", requireObject("{\"a\":1}").?);
    try testing.expectEqualStrings(" {\"a\":1} ", requireObject(" {\"a\":1} ").?);
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

test "method-not-found is a well-formed JSON-RPC error" {
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7," ++
            "\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        try methodNotFound(.{ .integer = 7 }, &out),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"error\":{\"code\":-32601," ++
            "\"message\":\"Method not found\"}}",
        try methodNotFound(.{ .string = "abc" }, &out),
    );
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

/// Decode a permission request with a scratch of the test's own.
fn decodeRequest(
    version: acp.WireVersion,
    raw: []const u8,
    out_options: []acp.PermissionOption,
) !acp.PermissionRequest {
    var scratch: [512]u8 = undefined;
    return acp.decodePermissionRequest(version, raw, out_options, &scratch);
}

// --- The loopback exchange ----------------------------------------------------
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
    decode_scratch: [1024]u8 = undefined,
    handler_scratch: [4096]u8 = undefined,
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

    fn open(
        self: *Endpoint,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
    ) void {
        self.stream = stream;
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = conn.Conn.init(io, &self.reader.interface, &self.writer.interface, .{
            .frame_buffer = &self.side.frame_buffer,
            .pending = &self.side.pending,
            .decode_scratch = &self.side.decode_scratch,
            .handler_scratch = &self.side.handler_scratch,
        });
        if (handler) |h| self.connection.setHandler(h);
        // Spawned on the group the test joins, because `Io.Group.async` does not
        // promise to run its task until the group is awaited or cancelled.
        group.async(io, pump, .{&self.connection});
    }

    /// Hang up. `shutdown` before `close`: closing a descriptor does not interrupt
    /// a read already blocked on it, so the peer's pump would sit on an open
    /// description and the group would never finish.
    fn hangUp(self: *Endpoint, io: Io) void {
        self.stream.shutdown(io, .both) catch {};
        self.stream.close(io);
    }
};

fn pump(c: *conn.Conn) void {
    c.pump();
}

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
fn agentHandler(ctx: ?*anyopaque, frame: []const u8, scratch: []u8) conn.Error!?[]const u8 {
    const state: *Outcome = @ptrCast(@alignCast(ctx.?));
    // The answer is built in the buffer the connection lends the handler, not in
    // a local. That is the region `conn.Conn` passes for exactly this, and it is
    // the one the write it performs the moment the handler returns is certain to
    // be able to read.
    const key_scratch = scratch[0..128];
    const body = scratch[128..];
    const message = jsonrpc.decode(frame, key_scratch) catch return null;
    if (message.kind != .request) return null;
    state.agent_calls += 1;

    const id = message.id orelse return null;
    var writer = json.Writer.init(body);
    writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
    var digits: [24]u8 = undefined;
    const id_text = std.fmt.bufPrint(&digits, "{d}", .{id.integer}) catch return null;
    writer.slice(id_text) catch return null;
    if (message.method) |method| {
        if (std.mem.eql(u8, method.text, "initialize")) {
            // `loadSession` and nothing else, so exactly one gated method is open
            // to the client and exactly one is refused.
            writer.slice(
                ",\"result\":{\"protocolVersion\":1," ++
                    "\"agentCapabilities\":{\"loadSession\":true}," ++
                    "\"agentInfo\":{\"name\":\"test-agent\"}}}",
            ) catch return null;
        } else {
            writer.slice(",\"result\":{\"sessionId\":\"s9\"}}") catch return null;
        }
    }
    // The connection writes the body before returning from the dispatch, so a
    // stack buffer is enough and the handler allocates nothing.
    return writer.written();
}

/// The client answers the agent's permission request. Runs inline on the client's
/// reader task, so it may encode a body but must not call back on the same
/// connection.
fn clientPermissionHandler(
    ctx: ?*anyopaque,
    frame: []const u8,
    scratch: []u8,
) conn.Error!?[]const u8 {
    const state: *Outcome = @ptrCast(@alignCast(ctx.?));
    // Four regions of the buffer the connection lends, none of them a local. The
    // decoded message, the request and the answer are all live at once, and the
    // answer has to stay readable for the write the connection does next.
    const key_scratch = scratch[0..128];
    const request_scratch = scratch[128..1152];
    const outcome_buffer = scratch[1152..1280];
    const body = scratch[1280..];

    const message = jsonrpc.decode(frame, key_scratch) catch return null;
    if (message.kind != .request) return null;
    const method = message.method orelse return null;
    if (!std.mem.eql(u8, method.text, "session/request_permission")) return null;
    const params: []const u8 = switch (message.params) {
        .value => |value| value,
        else => return null,
    };

    var options: [4]acp.PermissionOption = undefined;
    const request = acp.decodePermissionRequest(.stable, params, &options, request_scratch) catch
        return null;

    // The one answer this test's client will make without asking anyone, and it
    // is a refusal. Reaching an approval here would take a chosen option id, and
    // no branch supplies one.
    const outcome = answerPermission(&request, .cancelled, outcome_buffer) catch return null;

    const id = message.id orelse return null;
    var writer = json.Writer.init(body);
    writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
    var digits: [24]u8 = undefined;
    const id_text = std.fmt.bufPrint(&digits, "{d}", .{id.integer}) catch return null;
    writer.slice(id_text) catch return null;
    writer.slice(",\"result\":") catch return null;
    writer.slice(outcome) catch return null;
    writer.byte('}') catch return null;
    state.permission = readOutcome(outcome, &request, request_scratch);
    return writer.written();
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
    // for a permission, the client answers it without being asked, and the agent
    // reads what came back as a cancellation rather than as approval.
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
    // The option the agent offered was one that grants, so a cancellation here is
    // a decision the client made and not the only word this library has for it.
    try testing.expect(state.permission == .cancelled);
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
        "/tmp/zig-agent-protocols-acp-session-{x}.sock",
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
        });
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
        self.endpoint.open(self.io, self.group, stream, null);

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
        self.endpoint.open(self.io, self.group, stream, null);

        const side = &self.endpoint.side;
        var agent: Agent = .{ .connection = &self.endpoint.connection, .version = .stable };
        const reply = agent.request(
            "session/request_permission",
            permission_params,
            &side.call_result,
            &side.call_out,
        ) catch {
            self.state.failed = true;
            self.state.set(self.io);
            self.endpoint.hangUp(self.io);
            return;
        };

        // Read the answer against the request the agent actually sent, so the
        // option ids line up and a grant would be recognised if one arrived.
        var options: [1]acp.PermissionOption = undefined;
        var scratch: [512]u8 = undefined;
        const sent = acp.decodePermissionRequest(
            .stable,
            permission_params,
            &options,
            &scratch,
        ) catch {
            self.state.failed = true;
            self.state.set(self.io);
            self.endpoint.hangUp(self.io);
            return;
        };
        self.state.permission_version = agent.version;
        self.state.permission = readOutcome(reply.body, &sent, &scratch);
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
            .ctx = self.state,
            .call = clientPermissionHandler,
        });
        // The agent's call is in flight on the other side of this socket, and
        // closing now would race it: the answer would arrive at a connection that
        // no longer existed.
        self.state.wait(self.io);
        self.endpoint.hangUp(self.io);
    }
};
