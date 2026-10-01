//! Agent Client Protocol, wire version `1` with `2` gated.
//!
//! Values come from PROTOCOLS.md section 6, which selects from
//! `research/normative/acp-v1-v2.md`.
//!
//! ## Two versions that are not a flag
//!
//! PROTOCOLS.md section 6.4 is blunt: the v1 to v2 delta is "structural, not
//! additive". The Rust schema provides no cross-version conversion, v1 and v2
//! terminal models are ownership- and lifetime-incompatible, and the v1 and v2
//! `session/prompt` results share no required field. So a method is looked up
//! against an explicit `WireVersion`, and a method that exists only in the other
//! version is `error.UnknownMethod`.
//!
//! ## The safety rule this module exists to enforce
//!
//! PROTOCOLS.md section 6.6 quotes the sharpest clause in the protocol: an agent
//! that receives an outcome it does not understand **MUST NOT** treat it as
//! approval. Neither schema version declares a catch-all branch on
//! `RequestPermissionOutcome`, so an unknown outcome string is unparseable by
//! spec. `decodePermissionOutcome` therefore returns `error.UnknownTag` for one.
//! It never returns `.selected`, and there is no way to reach `.selected`
//! without an explicit `outcome` member naming it.
//!
//! ## Artifact versions are not wire versions
//!
//! PROTOCOLS.md section 6.1: the crate, the v1 schema artifact, and the v2
//! draft carried four different version numbers at the research date. None of
//! them is the wire version, and a library that conflated them would break on
//! every artifact release. Only `WireVersion` appears in this module.
//!
//! ## What a decoder must keep apart
//!
//! Two distinctions survive decoding because collapsing either one loses a
//! fact. An unrecognised `kind`, `mode` or `replayFrom` tag is an error at v1,
//! whose unions are closed, and a carried value at v2, whose unions declare the
//! catch-all; `classifyTag` is where that version rule lives. An unrecognised
//! *capability* is never an error in either version, so a decoded capability
//! records whether this library names the path and the caller decides what an
//! unknown one is worth.

const std = @import("std");
const root = @import("root.zig");
const json = @import("json.zig");

const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

// --- 6.1 Version negotiation ---------------------------------------------------

/// The wire versions this library implements.
///
/// The tags are the library's own; `number` is the wire spelling.
pub const WireVersion = enum(u16) {
    /// The stable wire version.
    stable = 1,
    /// The draft wire version, gated.
    draft = 2,

    pub fn fromNumber(value: u16) ?WireVersion {
        return switch (value) {
            1 => .stable,
            2 => .draft,
            else => null,
        };
    }

    pub fn number(self: WireVersion) u16 {
        return @intFromEnum(self);
    }
};

/// The result of the negotiation both sides run, section 6.1.
///
/// The agent echoes the requested version when it supports it and otherwise
/// returns its own highest. A client that cannot speak the returned version
/// SHOULD disconnect, which is why the outcome distinguishes those two cases
/// rather than collapsing to a single number.
pub const Negotiated = union(enum) {
    /// The agent supports the requested version and echoed it.
    echoed: WireVersion,
    /// The agent does not support the requested version and returned its own
    /// highest. The client SHOULD disconnect when it cannot speak this.
    downgraded: WireVersion,
    /// The agent implements no version at all, so the rule has no answer to
    /// give: there is no highest supported version to return. This is not a
    /// downgrade, and it is not the requested number either — that number is
    /// the client's, and reporting it back as the agent's answer would claim
    /// the agent speaks a version it does not.
    agent_supports_nothing,
    /// The agent answered with a version this library does not implement.
    ///
    /// Nothing in this library builds it and no decoder here produces it. The
    /// protocol layer reads a peer's `protocolVersion` into its own handshake
    /// record and reports `error.NotPermitted` for a number it cannot speak, so
    /// the agent's answer never reaches this union. A caller that keeps a
    /// `protocolVersion` itself builds this variant, because it is the only
    /// way to say "the agent answered, and the answer is not a version I
    /// implement" without dropping the number the agent sent.
    unsupported: u16,
};

/// Run the negotiation rule for `supported`, the versions the agent implements,
/// given the version the client requested.
///
/// An empty `supported` yields [`Negotiated.agent_supports_nothing`]: the rule
/// says answer with the latest version the agent supports, and an agent that
/// supports none has no such version to answer with.
pub fn negotiate(requested: u16, supported: []const WireVersion) Negotiated {
    // The rule is: echo when the requested version is one the agent supports,
    // otherwise answer with the agent's own highest. A version this library
    // does not implement is by definition one the agent does not support, so it
    // takes the second branch rather than short-circuiting.
    for (supported) |version| {
        if (version.number() != requested) continue;
        return .{ .echoed = version };
    }
    // An agent that implements no version cannot answer with "the latest
    // version it supports", because there is none. Reporting the client's own
    // request here would be the one answer the agent did not give.
    if (supported.len == 0) return .agent_supports_nothing;
    var highest = supported[0];
    for (supported) |version| {
        if (version.number() > highest.number()) highest = version;
    }
    return .{ .downgraded = highest };
}

// --- 6.2 Transport -------------------------------------------------------------

// stdio is the only normative transport, section 6.2, and Streamable HTTP over
// WebSocket or HTTP is still in discussion. No declaration here takes a
// transport argument: the framing below is the stdio framing, and `stdio` is
// the module that opens one.

/// The framing delimiter. Messages are newline-delimited and MUST NOT contain
/// embedded newlines, so a raw newline is unambiguous.
pub const frame_delimiter: u8 = '\n';

/// A frame taken from a stdio byte stream.
pub const Frame = struct {
    /// The message bytes, excluding the delimiter.
    bytes: []const u8,
    /// Everything after the delimiter, for the next call.
    rest: []const u8,
    /// True when the frame ended the input rather than a delimiter.
    unterminated: bool,
};

/// Take the next frame from `input`.
///
/// An embedded newline cannot appear inside a frame, because a newline is the
/// delimiter; a JSON string carrying one is escaped by the encoder, so the
/// framing stays unambiguous. Input that is not valid UTF-8 is rejected here
/// rather than at a later parse, because the specification requires UTF-8 and
/// a frame that cannot be text is not a message.
pub fn nextFrame(input: []const u8) DecodeError!Frame {
    const newline = std.mem.findScalar(u8, input, frame_delimiter);
    const bytes = if (newline) |at| input[0..at] else input;

    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;

    return .{
        .bytes = bytes,
        .rest = if (newline) |at| input[at + 1 ..] else input[input.len..],
        .unterminated = newline == null,
    };
}

/// Append a frame and its delimiter.
///
/// This is the exact inverse of [`nextFrame`], as PROTOCOLS.md section 2
/// requires: a byte sequence this accepts is one `nextFrame` reads back
/// unchanged, and a sequence this refuses is one `nextFrame` refuses too. The
/// bytes reach the wire, so a message this library itself could not decode is a
/// failure the peer discovers and this library cannot.
///
/// The UTF-8 check belongs here rather than being left to `json.Writer.string`,
/// which documents that an unvalidated value is a programming error. That
/// position holds for a decoded value, whose bytes a decoder already checked.
/// This function takes raw bytes rather than a decoded value, so there is no
/// such guarantee behind them and the encoder is the last place that can refuse.
///
/// Both refusals are `error.InvalidField`, which is what an `EncodeError` can
/// say: `error.InvalidUtf8` belongs to `DecodeError`, and a caller of this
/// function is asking what may be written, not what was read.
pub fn writeFrame(bytes: []const u8, writer: *json.Writer) EncodeError!void {
    // A caller that handed us a raw newline has already broken the framing, and
    // writing it would split one message into two on the wire.
    if (std.mem.findScalar(u8, bytes, frame_delimiter) != null) return error.InvalidField;
    // A frame that is not text is not a message, which is what `nextFrame`
    // already says. Both checks precede the first write, so a refusal leaves
    // the writer untouched and a caller can retry with a different buffer.
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidField;
    try writer.slice(bytes);
    try writer.byte(frame_delimiter);
}

// --- 6.3 and 6.4 Method registries ----------------------------------------------

/// Which side a method is called on.
pub const Side = enum {
    /// Called by the Client on the Agent.
    agent,
    /// Called by the Agent on the Client.
    client,
    /// Side-independent.
    protocol,
};

/// A method as one version's registry states it.
pub const MethodInfo = struct {
    name: []const u8,
    side: Side,
    /// A notification has no result, so JSON-RPC carries no `id` for it.
    notification: bool = false,
    /// The capability that gates it, as a dotted path. Empty means baseline.
    gate: []const u8 = "",
    /// A second capability that gates the method exactly as `gate` does.
    ///
    /// `elicitation/create` is the case the schema forces. PROTOCOLS.md
    /// section 6.5 gates it per mode, so form mode and URL mode each enable it;
    /// one gate field could name only one of them, and a peer advertising URL
    /// mode alone would be reported as not supporting a method it does support.
    /// The spelling differs by version: v1 paths are relative to the side's own
    /// capability object and v2 paths carry the shared `capabilities` root.
    /// Empty means a single gate.
    gate2: []const u8 = "",
    /// Whether the method is conditional on a non-empty `authMethods`.
    conditional_on_auth_methods: bool = false,
};

/// v1 `agentMethods`: 13 entries, Client to Agent.
pub const v1_agent_methods = [_]MethodInfo{
    .{ .name = "initialize", .side = .agent },
    .{ .name = "authenticate", .side = .agent },
    .{ .name = "session/new", .side = .agent },
    .{ .name = "session/load", .side = .agent, .gate = "loadSession" },
    .{ .name = "session/set_mode", .side = .agent },
    // Absent from both the baseline and the optional list in the prose. The
    // registry carries it, so the library does too, with no gate claimed.
    .{ .name = "session/set_config_option", .side = .agent },
    .{ .name = "session/prompt", .side = .agent },
    .{ .name = "session/cancel", .side = .agent, .notification = true },
    // PROTOCOLS.md section 6.5 spells these `session.*`; the deeper source
    // spells the same object `agentCapabilities.sessionCapabilities.*`. The
    // parent segment is dropped because PROTOCOLS.md is the authority, and it
    // names `auth.logout` the same abbreviated way. `v1_agent_capabilities`
    // uses these four spellings, so a gate and its capability agree.
    .{ .name = "session/list", .side = .agent, .gate = "session.list" },
    .{ .name = "session/delete", .side = .agent, .gate = "session.delete" },
    // The two sources name two different gates for this one method.
    // PROTOCOLS.md section 6.5 gives `loadSession` the pair `session/load`,
    // `session/resume`, while `research/normative/acp-v1-v2.md` line 67 gates
    // `session/resume` on `sessionCapabilities.resume` and line 64 restricts
    // `loadSession` to `session/load`. PROTOCOLS.md is the authority and the
    // conflict is recorded here: both spellings are read as alternatives, so a
    // peer that advertises either one is a peer this library does not report as
    // unable to resume.
    .{ .name = "session/resume", .side = .agent, .gate = "loadSession", .gate2 = "session.resume" },
    .{ .name = "session/close", .side = .agent, .gate = "session.close" },
    .{ .name = "logout", .side = .agent, .gate = "auth.logout" },
};

/// v1 `clientMethods`: 11 entries, Agent to Client.
pub const v1_client_methods = [_]MethodInfo{
    .{ .name = "session/request_permission", .side = .client },
    .{ .name = "session/update", .side = .client, .notification = true },
    .{ .name = "fs/write_text_file", .side = .client, .gate = "fs.writeTextFile" },
    .{ .name = "fs/read_text_file", .side = .client, .gate = "fs.readTextFile" },
    .{ .name = "terminal/create", .side = .client, .gate = "terminal" },
    .{ .name = "terminal/output", .side = .client, .gate = "terminal" },
    .{ .name = "terminal/release", .side = .client, .gate = "terminal" },
    .{ .name = "terminal/wait_for_exit", .side = .client, .gate = "terminal" },
    .{ .name = "terminal/kill", .side = .client, .gate = "terminal" },
    .{
        .name = "elicitation/create",
        .side = .client,
        .gate = "elicitation.form",
        .gate2 = "elicitation.url",
    },
    .{ .name = "elicitation/complete", .side = .client, .notification = true },
};

/// v2 `agentMethods`: 11 entries, Client to Agent.
pub const v2_agent_methods = [_]MethodInfo{
    .{ .name = "initialize", .side = .agent },
    .{ .name = "auth/login", .side = .agent, .conditional_on_auth_methods = true },
    .{ .name = "auth/logout", .side = .agent, .conditional_on_auth_methods = true },
    .{ .name = "session/new", .side = .agent },
    .{ .name = "session/set_config_option", .side = .agent },
    .{ .name = "session/prompt", .side = .agent },
    .{ .name = "session/cancel", .side = .agent, .notification = true },
    .{ .name = "session/list", .side = .agent },
    .{ .name = "session/delete", .side = .agent, .gate = "capabilities.session.delete" },
    .{ .name = "session/resume", .side = .agent },
    .{ .name = "session/close", .side = .agent },
};

/// v2 `clientMethods`: 4 entries, Agent to Client.
///
/// The v2 gates keep the `capabilities` root, as the agent gates do. Both
/// sides carry one `capabilities` member in v2, so a rootless path would be a
/// v1 path, and an adapter that reused a decoded v1 set against a v2 registry
/// would call that method supported on the strength of a message the peer
/// never sent.
pub const v2_client_methods = [_]MethodInfo{
    .{ .name = "session/request_permission", .side = .client },
    .{ .name = "session/update", .side = .client, .notification = true },
    .{
        .name = "elicitation/create",
        .side = .client,
        .gate = "capabilities.elicitation.form",
        .gate2 = "capabilities.elicitation.url",
    },
    .{ .name = "elicitation/complete", .side = .client, .notification = true },
};

/// The protocol methods, identical in both versions.
pub const protocol_methods = [_]MethodInfo{
    .{ .name = "$/cancel_request", .side = .protocol, .notification = true },
};

/// Look a method up, pinned to a wire version.
///
/// A method the other version removed is `error.UnknownMethod` rather than a
/// value the caller might send, which is the whole point of section 6.4: an
/// adapter must reject advertised v1 `fs` or `terminal` support when speaking v2
/// rather than silently dropping it.
pub fn lookupMethod(version: WireVersion, name: []const u8) DecodeError!MethodInfo {
    // Both registries are comptime globals, so taking their addresses here is
    // not a runtime pointer into a temporary.
    const v1_sets = [_][]const MethodInfo{ &v1_agent_methods, &v1_client_methods, &protocol_methods };
    const v2_sets = [_][]const MethodInfo{ &v2_agent_methods, &v2_client_methods, &protocol_methods };
    const sets: []const []const MethodInfo = switch (version) {
        .stable => &v1_sets,
        .draft => &v2_sets,
    };
    for (sets) |set| {
        for (set) |*info| {
            if (std.mem.eql(u8, info.name, name)) return info.*;
        }
    }
    return error.UnknownMethod;
}

/// Whether a peer advertising `advertised` may call `info`.
///
/// A method with no gate is baseline and always callable. A method with one
/// gate needs that capability. A method with two gates needs either of them,
/// because `gate2` is an alternative spelling of the same requirement rather
/// than a second one.
///
/// `elicitation/create` is the case the schema forces. PROTOCOLS.md section 6.5
/// gates it per mode, so form mode and URL mode each enable it; one gate field
/// could name only one of them, and a peer advertising URL mode alone would be
/// reported as not supporting a method it does support. `session/resume` is the
/// other, where the two sources name different gates for one method rather than
/// one gate covering two.
///
/// Omission means unsupported, so an empty `advertised` set supports only the
/// ungated methods.
pub fn isMethodSupported(info: MethodInfo, advertised: []const []const u8) bool {
    if (info.gate.len == 0) return true;
    if (contains(advertised, info.gate)) return true;
    if (info.gate2.len != 0 and contains(advertised, info.gate2)) return true;
    return false;
}

/// The `auth/login`, `auth/logout` and `authenticate` methods, which v1 and v2
/// spell differently, section 6.4.
pub fn authMethodName(version: WireVersion) struct { login: []const u8, logout: []const u8 } {
    return switch (version) {
        .stable => .{ .login = "authenticate", .logout = "logout" },
        .draft => .{ .login = "auth/login", .logout = "auth/logout" },
    };
}

/// Methods v1 offered and v2 removed, section 6.4.
///
/// The v2 terminal model is agent-owned and read-only, and the filesystem
/// surface is gone entirely. An adapter must reject these rather than drop them.
pub const v2_removed_methods = [_][]const u8{
    "fs/read_text_file",
    "fs/write_text_file",
    "terminal/create",
    "terminal/output",
    "terminal/release",
    "terminal/wait_for_exit",
    "terminal/kill",
    "session/load",
    "session/set_mode",
};

/// The v1 to v2 concept renames, section 6.4.
pub const v2_renames = struct {
    pub const client_info_v1 = "clientInfo";
    pub const client_info_v2 = "info";
    pub const agent_info_v1 = "agentInfo";
    pub const agent_info_v2 = "info";
    pub const client_capabilities_v1 = "clientCapabilities";
    pub const client_capabilities_v2 = "capabilities";
    pub const agent_capabilities_v1 = "agentCapabilities";
    pub const agent_capabilities_v2 = "capabilities";
    pub const session_capabilities_v1 = "sessionCapabilities";
    pub const session_capabilities_v2 = "capabilities.session";
    pub const prompt_capabilities_v1 = "promptCapabilities";
    pub const prompt_capabilities_v2 = "capabilities.session.prompt";
    pub const mcp_capabilities_v1 = "mcpCapabilities";
    pub const mcp_capabilities_v2 = "capabilities.session.mcp";
    pub const session_config_id_v1 = "id";
    pub const session_config_id_v2 = "configId";
};

// --- 6.5 Capabilities ----------------------------------------------------------

/// The v1 client capability gates.
///
/// v1 gates are JSON booleans for the filesystem and terminal, and `{}`
/// presence objects for the rest. Omission means unsupported.
pub const v1_client_capabilities = [_][]const u8{
    "fs.readTextFile",
    "fs.writeTextFile",
    "terminal",
    "auth.terminal",
    "elicitation.form",
    "elicitation.url",
    "session.configOptions.boolean",
};

/// The v1 agent capability gates.
///
/// PROTOCOLS.md section 6.5 states the `session.*` paths; the deeper source
/// spells the same object `agentCapabilities.sessionCapabilities.*` and names
/// three keys PROTOCOLS.md omits. The parent segment is dropped because
/// PROTOCOLS.md is the authority and it names `auth.logout` the same
/// abbreviated way, and the three omitted keys come from the deeper source so
/// that every gate in the v1 agent registry resolves.
pub const v1_agent_capabilities = [_][]const u8{
    "loadSession",
    "promptCapabilities.image",
    "promptCapabilities.audio",
    "promptCapabilities.embeddedContext",
    "mcpCapabilities.http",
    "mcpCapabilities.sse",
    "auth.logout",
    "session.delete",
    "session.additionalDirectories",
    "session.list",
    "session.resume",
    "session.close",
    // The binding's own key. The released v1 schema does not define it, and it
    // is listed because the RFD proposes it and `bridge` carries the path.
    "mcpCapabilities.acp",
};

/// v1 has no closed capability set: an unknown capability is not a decode
/// error, which is the documented non-breaking extension mechanism.
pub fn isKnownV1ClientCapability(path: []const u8) bool {
    for (v1_client_capabilities) |known| {
        if (std.mem.eql(u8, known, path)) return true;
    }
    return false;
}

pub fn isKnownV1AgentCapability(path: []const u8) bool {
    for (v1_agent_capabilities) |known| {
        if (std.mem.eql(u8, known, path)) return true;
    }
    return false;
}

/// Whether `path` names a v1 capability of either side.
///
/// v1 has no closed capability set, so this is a known-value check and not a
/// validation: an unknown path is an extension point, not an error.
pub fn isKnownV1Capability(path: []const u8) bool {
    return isKnownV1ClientCapability(path) or isKnownV1AgentCapability(path);
}

/// How a capability is represented on the wire in a given version.
pub const CapabilityForm = enum {
    /// v1: a JSON boolean. `false` and omission both mean unsupported.
    boolean,
    /// A `{}` object. Presence enables the feature, even when empty.
    presence_object,
};

/// The v1 capability domains whose members are JSON booleans.
///
/// A domain prefix alone is not enough to classify a path, so a prefix is only
/// consulted after [`isKnownV1Capability`]: `terminalFoo` is not in the
/// `terminal` domain and `mcpCapabilitiesX` is not in `mcpCapabilities`.
const v1_boolean_domains = [_][]const u8{
    "fs.",
    "promptCapabilities.",
    "mcpCapabilities.",
};

/// The v1 capabilities that are booleans and sit at the top of their object.
const v1_boolean_paths = [_][]const u8{
    "loadSession",
    "terminal",
    "auth.terminal",
};

/// The form each v1 gate uses, section 6.5.
///
/// v1 types the filesystem, the terminal, terminal-mode authentication,
/// session loading, the three prompt content kinds and everything under
/// `mcpCapabilities` as JSON booleans; every other gate is a `{}` presence
/// object. A path this library does not know has no form it can claim, and
/// reports the presence object because that form asserts the least: section
/// 6.5 makes an unknown capability an extension point, not an error.
pub fn v1CapabilityForm(path: []const u8) CapabilityForm {
    if (!isKnownV1Capability(path)) return .presence_object;
    for (v1_boolean_domains) |domain| {
        if (std.mem.startsWith(u8, path, domain)) return .boolean;
    }
    for (v1_boolean_paths) |exact| {
        if (std.mem.eql(u8, exact, path)) return .boolean;
    }
    return .presence_object;
}

/// v2 replaces every remaining boolean with a presence object, so the
/// distinction disappears with the version.
pub const v2_capability_form: CapabilityForm = .presence_object;

// --- The catch-all rule, version 6.4 --------------------------------------------

/// Whether a version's schema gives an unrecognised discriminator a value.
///
/// PROTOCOLS.md section 6.4 records the v1 to v2 delta as "closed `oneOf`"
/// becoming "`anyOf` plus an `other` catch-all carrying a free `type` string",
/// and the deeper source shows the rewrite on every tagged union it touched.
/// The version therefore decides whether an unrecognised string is undefined by
/// the schema or defined by it, and a decoder has to keep the two apart: an
/// undefined value is an error the caller must see, and a defined one is a
/// value this library has to carry rather than drop.
pub const UnknownTagPolicy = enum {
    /// A closed `oneOf`: the string is not a value this protocol has.
    reject,
    /// An `anyOf` plus an `other` branch: the string is a value.
    catch_all,
};

pub fn unknownTagPolicy(version: WireVersion) UnknownTagPolicy {
    return switch (version) {
        .stable => .reject,
        .draft => .catch_all,
    };
}

/// Where a discriminator string lands once the schema's own rules are applied.
pub const TagClass = union(enum) {
    /// One of the values the schema names, at this index in that table.
    named: usize,
    /// Not named, but the schema declares the free-string `other` branch, so
    /// the value is defined and must be carried rather than refused.
    other,
    /// Neither named nor covered by an `other` branch. Reading one of these as
    /// anything in particular is the guess PROTOCOLS.md section 6.6 forbids for
    /// a permission outcome, so the caller is told instead.
    undefined_tag,
};

/// Classify `tag` against the named values of one version's union.
pub fn classifyTag(
    version: WireVersion,
    named: []const []const u8,
    tag: []const u8,
) TagClass {
    for (named, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, tag)) return .{ .named = index };
    }
    return switch (unknownTagPolicy(version)) {
        .reject => .undefined_tag,
        .catch_all => .other,
    };
}

/// Whether a free discriminator is the specification's reserved extension
/// spelling.
///
/// The stated convention is for v2 `sessionUpdate`: a value beginning with `_`
/// is an implementation-specific extension, while an unknown value without the
/// prefix is reserved for a future ACP variant. A proxy forwards the first and
/// may have to understand the second, so the two are not interchangeable.
pub fn isImplementationExtension(tag: []const u8) bool {
    return tag.len != 0 and tag[0] == '_';
}

/// Classify a `sessionUpdate` discriminator.
///
/// v1 declares eleven variants in a closed `oneOf`. v2 declares sixteen plus a
/// catch-all, which is the only way a peer can send a variant this library has
/// never read, and PROTOCOLS.md section 6.4 requires an agent to keep serving
/// such a peer rather than reject its output.
///
/// A v1 value that v2 removed lands in the v2 catch-all, because the schema
/// gives it no other home: the schema defines every unlisted string as `other`,
/// and which of those are retired rather than future is a fact about this
/// library's tables, not about the wire.
pub fn classifySessionUpdate(version: WireVersion, tag: []const u8) TagClass {
    return switch (version) {
        .stable => classifyTag(.stable, &v1_session_update_variants, tag),
        .draft => classifyTag(.draft, &v2_session_update_variants, tag),
    };
}

/// Classify the `state` discriminator of a `state_update` payload.
///
/// The tag is `state` rather than a `type`, but the union is the same `anyOf`
/// plus `other`. v1 has no `state_update` at all, so no state value is defined
/// there and every tag is undefined.
pub fn classifyStateUpdate(version: WireVersion, tag: []const u8) TagClass {
    return switch (version) {
        // v1 names no state value at all, so it classifies against an empty
        // table and every tag falls through to the v1 policy.
        .stable => classifyTag(.stable, &.{}, tag),
        .draft => classifyTag(.draft, &v2_state_variants, tag),
    };
}

/// The v2 `StopReason` values.
///
/// The same five strings as v1, in the union that gained the catch-all. v2
/// moved the reason out of the `session/prompt` result and into an idle
/// `state_update`, so a v2 reader meets a reason it has never seen where v1
/// would have met an undefined one.
pub const v2_stop_reasons = [_][]const u8{
    "end_turn",
    "max_tokens",
    "max_turn_requests",
    "refusal",
    "cancelled",
};

pub fn classifyStopReason(version: WireVersion, tag: []const u8) TagClass {
    return switch (version) {
        .stable => classifyTag(.stable, &v1_stop_reasons, tag),
        .draft => classifyTag(.draft, &v2_stop_reasons, tag),
    };
}

/// The v1 `SessionConfigOption` `type` union.
pub const v1_session_config_option_types = [_][]const u8{ "select", "boolean" };

/// The v2 `SessionConfigOption` `type` union: the same two values, in the
/// union that gained the catch-all.
pub const v2_session_config_option_types = [_][]const u8{ "select", "boolean" };

/// Classify a `SessionConfigOption` `type`.
pub fn classifySessionConfigOptionType(version: WireVersion, tag: []const u8) TagClass {
    return switch (version) {
        .stable => classifyTag(.stable, &v1_session_config_option_types, tag),
        .draft => classifyTag(.draft, &v2_session_config_option_types, tag),
    };
}

/// Classify an `elicitation/create` `mode`.
///
/// The two modes are the same in both versions, so the difference is again only
/// the catch-all: a mode outside the pair is undefined at v1 and the schema's
/// `other` branch at v2.
pub fn classifyElicitationMode(version: WireVersion, tag: []const u8) TagClass {
    return classifyTag(version, &elicitation_modes, tag);
}

// --- Session config options and `replayFrom`, section 6.4 -----------------------

/// The v2 `SessionConfigOptionCategory` values.
pub const session_config_option_category = struct {
    /// The category that carries a session mode. PROTOCOLS.md section 6.4:
    /// `session/set_mode`, the `SessionMode*` types and `current_mode_update`
    /// are all replaced by a config option carrying this category, so a v2
    /// reader looking for the v1 mode surface has to look here instead.
    pub const mode = "mode";
    pub const model = "model";
    pub const model_config = "model_config";
    pub const thought_level = "thought_level";
};

/// The v2 categories, in the order the schema lists them.
///
/// Only v2 establishes this set. The v1 `SessionConfigOption` has a `category`
/// member of the same type name, but the source gives no v1 values for it, so
/// this library claims none: a v1 category is an unestablished string, not one
/// of these.
pub const v2_session_config_categories = [_][]const u8{
    session_config_option_category.mode,
    session_config_option_category.model,
    session_config_option_category.model_config,
    session_config_option_category.thought_level,
};

/// Whether `category` is the category that replaced the v1 mode surface.
pub fn isSessionModeCategory(category: []const u8) bool {
    return std.mem.eql(u8, category, session_config_option_category.mode);
}

/// The `ReplayFrom` tag strings.
pub const replay_from_type = struct {
    /// Replay from the start of the session.
    pub const start = "start";
};

/// The v2 `ReplayFrom` union.
///
/// New in v2 and absent from v1, where `session/load` had no equivalent: a
/// `session/resume` request names where the replay begins. It is an `anyOf`, so
/// a `type` this library does not know is the schema's `other` branch and is
/// carried rather than refused. Unlike a permission outcome, no approval is
/// derived from a replay point, so the catch-all gives up nothing.
pub const ReplayFrom = union(enum) {
    /// `{"type": "start"}`, carrying nothing but optional `_meta`.
    start,
    /// Any other `type`. The rest of the object belongs to the peer that sent
    /// it and is not this library's to interpret.
    other: []const u8,
};

/// Decode a v2 `ReplayFrom` object.
pub fn decodeReplayFrom(raw: []const u8, scratch: []u8) DecodeError!ReplayFrom {
    var reader = json.Reader.init(raw);
    var tag: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "type")) {
            tag = try reader.string(scratch);
        } else {
            // `ReplayFromStart` carries only `_meta` and the `other` branch
            // sets `additionalProperties`, so no other member is required.
            try reader.skipValue(scratch);
        }
    }

    // A `ReplayFrom` is one JSON value. Bytes after the closing brace are a
    // second document the transport did not split, or a peer that disagrees
    // with it about where a frame ends, and `jsonrpc.decode` refuses them for
    // the same reason.
    if (!reader.atEnd()) return error.MalformedJson;

    const kind = tag orelse return error.MissingField;
    if (std.mem.eql(u8, kind, replay_from_type.start)) return .start;
    return .{ .other = kind };
}

/// Encode a v2 `ReplayFrom` object.
///
/// The exact inverse of [`decodeReplayFrom`]: the two agree on every value one
/// of them can reach, and a value this refuses is one the decoder could not
/// have returned.
///
/// One byte sequence the pair does not agree on, and it is the decoder's to
/// answer for. `ReplayFromStart` carries an optional `_meta` that this module
/// models nowhere, so a document with one decodes to a value that re-encodes
/// without it. Refusing the value would not help, because the metadata is
/// gone before any encoder sees the result; the member has to be carried by
/// [`ReplayFrom`] itself, and that is a change to the shape rather than to
/// this function.
pub fn encodeReplayFrom(value: ReplayFrom, writer: *json.Writer) EncodeError!void {
    switch (value) {
        .start => try writer.slice("{\"type\":\"" ++ replay_from_type.start ++ "\"}"),
        .other => |tag| {
            // Refused before a byte is written. `decodeReplayFrom` gives the
            // one named tag the `.start` arm, so writing the catch-all's text
            // here would emit a document that decodes as `.start`: the arm a
            // caller asked to encode is the one the wire cannot spell.
            if (std.mem.eql(u8, tag, replay_from_type.start)) return error.InvalidField;
            try writer.slice("{\"type\":");
            try writer.string(tag);
            try writer.byte('}');
        },
    }
}

// --- Capability objects, section 6.5 --------------------------------------------

/// The v2 agent capability gates.
///
/// The v2 draft merges both sides into one `capabilities` member, so these keep
/// that root, matching `v2_renames` and the v2 registry gate on `session/delete`.
/// The gates v2 promoted to baseline — `session/list`, `session/resume`,
/// `session/close` — are absent on purpose: those methods are no longer
/// conditional, so a peer that still advertises them must not look as though it
/// is unlocking anything.
pub const v2_agent_capabilities = [_][]const u8{
    "capabilities.session.prompt.image",
    "capabilities.session.prompt.audio",
    "capabilities.session.prompt.embeddedContext",
    "capabilities.session.mcp.stdio",
    "capabilities.session.mcp.http",
    "capabilities.session.delete",
    "capabilities.session.additionalDirectories",
    // The binding's own key, as `mcpCapabilities.acp` is at v1. The released
    // v2 schema does not define it either, and it is listed because the RFD
    // proposes it and `bridge` carries the path.
    "capabilities.session.mcp.acp",
};

/// The v2 client capability gates.
///
/// `fs` and `terminal` are gone in v2, and `auth.terminal` is an object marker
/// rather than a boolean, because v2 replaced every boolean with a presence
/// object.
pub const v2_client_capabilities = [_][]const u8{
    "capabilities.auth.terminal",
    "capabilities.elicitation.form",
    "capabilities.elicitation.url",
};

/// Whether `path` names a v2 capability of `side`.
///
/// v2 has no closed capability set either, so this is a known-value check and
/// not a validation, for the same reason as v1: a peer may advertise a feature
/// a newer draft added, and refusing to decode the message would end a session
/// that was working.
pub fn isKnownV2Capability(side: Side, path: []const u8) bool {
    return switch (side) {
        .client => contains(&v2_client_capabilities, path),
        .agent => contains(&v2_agent_capabilities, path),
        .protocol => false,
    };
}

/// One member of a capability object, as it arrived.
pub const Capability = struct {
    /// The dotted path in the spelling a [`MethodInfo`] gate uses, so a decoded
    /// set can be handed straight to [`isMethodSupported`]. A v1 path is
    /// relative to the side's own capability object, which is how PROTOCOLS.md
    /// section 6.5 spells its gates; a v2 path keeps the `capabilities` root,
    /// because that is the member both sides carry in v2. Keeping the root is
    /// what stops a v1 path and a v2 path for the same feature from being the
    /// same string across a version cutover.
    path: []const u8,
    /// Whether this library names the path.
    ///
    /// False is not a failure. Section 6.5 makes an unknown capability the
    /// documented non-breaking extension mechanism, so the entry is recorded
    /// with the flag off and the caller can tell a gate it may rely on from one
    /// it merely forwards.
    known: bool,
    /// The form the member had on the wire.
    form: CapabilityForm,
    /// The value of a boolean member, or null for a presence object, which
    /// asserts support by being there rather than by a value.
    value: ?bool,

    /// Whether this member advertises support.
    ///
    /// A presence object advertises by existing, which is why an empty object
    /// is the whole message. A `false` boolean is the v1 spelling of
    /// "unsupported", so the value has to be read rather than assumed from the
    /// member's presence.
    pub fn advertised(self: Capability) bool {
        return switch (self.form) {
            .presence_object => true,
            .boolean => self.value orelse false,
        };
    }
};

/// The leaves of one decoded capability object.
pub const CapabilitySet = struct {
    /// The entries, in wire order, in caller-owned storage.
    entries: []const Capability,
    /// Whether the capability member was on the wire at all. Omission means
    /// unsupported in both versions, so a caller can tell "advertised nothing"
    /// from "advertised an empty object".
    present: bool,
};

/// Flatten a decoded set into the path list [`isMethodSupported`] takes.
///
/// `out` is caller-owned and the result borrows it; nothing allocates. A buffer
/// too small is reported rather than truncated, because a truncated list reads
/// as a peer that advertised less than it did.
pub fn advertisedPaths(set: CapabilitySet, out: [][]const u8) DecodeError![]const []const u8 {
    var count: usize = 0;
    for (set.entries) |entry| {
        if (!entry.advertised()) continue;
        if (count == out.len) return error.BufferTooSmall;
        out[count] = entry.path;
        count += 1;
    }
    return out[0..count];
}

/// The buffers and counters one capability decode works through.
const CapabilityWalk = struct {
    version: WireVersion,
    side: Side,
    out: []Capability,
    paths: []u8,
    scratch: []u8,
    /// Bytes of `paths` written so far. It never rewinds, so every recorded
    /// path owns a region that no later path overwrites.
    end: usize = 0,
    /// Entries written to `out`.
    count: usize = 0,

    /// Append `parent`, a dot and `key`, and return the new path.
    fn appendPath(
        self: *CapabilityWalk,
        parent: []const u8,
        key: []const u8,
    ) DecodeError![]const u8 {
        const dot: usize = if (parent.len == 0) 0 else 1;
        const need = parent.len + dot + key.len;
        if (need > self.paths.len - self.end) return error.BufferTooSmall;
        @memcpy(self.paths[self.end..][0..parent.len], parent);
        if (dot != 0) self.paths[self.end + parent.len] = '.';
        @memcpy(self.paths[self.end + parent.len + dot ..][0..key.len], key);
        const path = self.paths[self.end..][0..need];
        self.end += need;
        return path;
    }

    /// Walk the members of an object whose own path is `parent`.
    fn walkMembers(
        self: *CapabilityWalk,
        reader: *json.Reader,
        parent: []const u8,
        depth: u32,
    ) DecodeError!void {
        while (try reader.nextKey(self.scratch)) |key| {
            // `_meta` is metadata on every type in both schemas and never a
            // capability, so it never becomes a path.
            if (std.mem.eql(u8, key, "_meta")) {
                try reader.skipValue(self.scratch);
                continue;
            }
            try self.walkMember(reader, parent, key, depth);
        }
    }

    /// Read the member named `key`, whose own path would be `parent.key`.
    ///
    /// The path is built only for a member that records one, because the value
    /// decides that and the record needs the path. A member that records
    /// nothing — an explicit `null`, a string, a number, an array — therefore
    /// costs the caller no region of `paths`, so a caller who sized that buffer
    /// by the paths the entries borrow is not asked for bytes no entry borrows.
    fn walkMember(
        self: *CapabilityWalk,
        reader: *json.Reader,
        parent: []const u8,
        key: []const u8,
        depth: u32,
    ) DecodeError!void {
        // The reader bounds its own containers at `json.max_depth`; this bounds
        // the walk, which recurses through the reader rather than inside it.
        if (depth > json.max_depth) return error.LimitExceeded;
        reader.skipWhitespace();
        const byte = reader.peek() orelse return error.Truncated;
        switch (byte) {
            'n' => {
                // An explicit `null` is the absent case for a nested capability
                // object, so it advertises nothing and gets no path.
                try reader.nullLiteral();
            },
            't', 'f' => {
                const value = try reader.boolean();
                try self.record(try self.appendPath(parent, key), .boolean, value);
            },
            '{' => {
                // A presence object advertises by being there, so it is
                // recorded whether or not it also carries members of its own.
                const path = try self.appendPath(parent, key);
                try self.record(path, .presence_object, null);
                if (try reader.beginObject()) return;
                try self.walkMembers(reader, childPath(self.version, path), depth + 1);
            },
            else => {
                // A string, a number or an array is not a capability form
                // either schema declares, so it is stepped over rather than
                // guessed at.
                try reader.skipValue(self.scratch);
            },
        }
    }

    /// Record one member, refusing a form its version does not declare for it.
    fn record(
        self: *CapabilityWalk,
        path: []const u8,
        form: CapabilityForm,
        value: ?bool,
    ) DecodeError!void {
        if (self.count == self.out.len) return error.BufferTooSmall;
        const known = self.isKnown(path);
        try self.checkForm(path, known, form);
        self.out[self.count] = .{
            .path = path,
            .known = known,
            .form = form,
            .value = value,
        };
        self.count += 1;
    }

    fn isKnown(self: *CapabilityWalk, path: []const u8) bool {
        return switch (self.version) {
            .stable => switch (self.side) {
                .client => isKnownV1ClientCapability(path),
                .agent => isKnownV1AgentCapability(path),
                .protocol => false,
            },
            .draft => isKnownV2Capability(self.side, path),
        };
    }

    /// Refuse a member whose form is not the one its version declares.
    fn checkForm(
        self: *CapabilityWalk,
        path: []const u8,
        known: bool,
        form: CapabilityForm,
    ) DecodeError!void {
        switch (self.version) {
            .stable => {
                // Only a path this library names is checked, because v1 has no
                // closed capability set and an unknown path is an extension
                // point that may take either form.
                if (!known) return;
                if (form != v1CapabilityForm(path)) return error.InvalidField;
            },
            .draft => {
                // v2 replaced every boolean with a presence object, so a
                // boolean anywhere in a v2 capability object is a shape the
                // draft does not define. Reading it as a `{}` would claim a
                // support the peer may have explicitly denied with `false`.
                if (form != v2_capability_form) return error.InvalidField;
            },
        }
    }
};

/// The v1 object the session gates are nested under, in both spellings.
///
/// The schema nests them under `sessionCapabilities` and PROTOCOLS.md
/// section 6.5 spells the gates `session.*`, so a decoded path crosses
/// between the two. The crossing happens in each direction — in
/// [`childPath`] on the way in and in `capabilityChildKey` on the way out —
/// so both spellings are named here. A rule with a caller on each side that
/// does not read the same table is a spelling that drifts.
const v1_session_capabilities = struct {
    /// The member name on the wire.
    const object = v2_renames.session_capabilities_v1;
    /// The spelling the decoded paths use for the object itself.
    const gate = "session";
    /// The same, as it prefixes a single gate.
    const gate_prefix = gate ++ ".";
};

/// The `capabilities` root every v2 capability path starts with, dot included.
///
/// `decodeCapabilityObject` writes the bare member name ahead of the first
/// path and the walk joins the rest with dots, so the two halves of the
/// spelling sit in different places. This is the joined form
/// `capabilityRootKey` takes the head off.
const v2_capabilities_root = v2_renames.client_capabilities_v2 ++ ".";

/// Whether `path` is one of the v1 session gates inside `parent`.
fn isV1SessionGate(parent: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, parent, v1_session_capabilities.object) and
        std.mem.startsWith(u8, path, v1_session_capabilities.gate_prefix);
}

/// The path spelling the children of `path` use.
///
/// PROTOCOLS.md section 6.5 spells the v1 session gates `session.*` while the
/// schema nests them under `sessionCapabilities`. The v1 registry uses the
/// abbreviated spelling, so the decoded paths use it too; otherwise a decoded
/// set could not answer `isMethodSupported` for the four session gates.
fn childPath(version: WireVersion, path: []const u8) []const u8 {
    if (version == .stable and std.mem.eql(u8, path, v1_session_capabilities.object)) {
        return v1_session_capabilities.gate;
    }
    return path;
}

/// Decode a capability object into caller-owned entries.
///
/// `out` receives one entry per object or boolean member, `paths` is where the
/// dotted paths are built and `scratch` is the reader's escape buffer. Nothing
/// allocates, and every buffer belongs to the caller. `paths` must hold the sum
/// of every path recorded, not the longest one, because each entry borrows its
/// own region and no region is recycled; a buffer that cannot is
/// `error.BufferTooSmall`. At v2 it must also hold the `capabilities` root,
/// which is written ahead of the first member and forms the head of that
/// member's region rather than a path of its own. A member that records nothing
/// costs no region at all.
///
/// Every object member is recorded, not only the empty ones, because a presence
/// object advertises by existing: a `elicitation.form` object that also carries
/// an extension still advertises form mode, and the gate has to appear in the
/// list for the method to be callable.
///
/// A member in the wrong form for its version is refused. That is stricter than
/// the v1 extension rule on purpose: the rule keeps an unknown *capability*
/// legal, and a wrong form on a known one, or any boolean at v2, is a shape the
/// schema does not define rather than a capability this library has not read.
pub fn decodeCapabilityObject(
    version: WireVersion,
    side: Side,
    raw: []const u8,
    out: []Capability,
    paths: []u8,
    scratch: []u8,
) DecodeError!CapabilitySet {
    // Neither schema gives a capability object to a side-independent method.
    if (side == .protocol) return error.InvalidField;
    // A v2 path keeps the `capabilities` root, because that is the member both
    // sides carry there; a v1 path is relative to the side's own object, which
    // is how PROTOCOLS.md section 6.5 spells its gates.
    const prefix: []const u8 = if (version == .draft) v2_renames.client_capabilities_v2 else "";
    if (paths.len < prefix.len) return error.BufferTooSmall;
    @memcpy(paths[0..prefix.len], prefix);

    var reader = json.Reader.init(raw);
    var walk = CapabilityWalk{
        .version = version,
        .side = side,
        .out = out,
        .paths = paths,
        .scratch = scratch,
        .end = prefix.len,
    };
    // An empty object is a peer that advertises nothing, which is a fact
    // rather than an error, so it yields an empty set marked present. The
    // walk is skipped and the check below is not, because the check is the
    // one thing every path out of this function has to make.
    if (!(try reader.beginObject())) {
        try walk.walkMembers(&reader, paths[0..prefix.len], 1);
    }

    // A capability object is one JSON value. Bytes after the closing brace
    // are a second document, and reading the set as though only the walked
    // members had arrived describes a peer this library was not sent. No
    // encoder here would put those bytes back, so nothing downstream would
    // ever see the loss; `jsonrpc.decode` refuses the same document for the
    // same reason.
    if (!reader.atEnd()) return error.MalformedJson;

    return .{ .entries = out[0..walk.count], .present = true };
}

/// Refuse a member whose form its version does not declare for its path.
///
/// The rule `CapabilityWalk.checkForm` applies on the reading side, in one
/// place rather than written twice. An encoder that did not apply it would
/// advertise `terminal` as a `{}` at v1 or as a boolean at v2, and
/// `decodeCapabilityObject` refuses both: at v1 the form is the schema's,
/// and at v2 a boolean is a shape the draft does not define rather than a
/// capability this library has not read.
fn validateCapabilityEntry(version: WireVersion, entry: Capability) EncodeError!void {
    // The value is the wire spelling of the form and carries nothing else. A
    // boolean with no value has to be written `null`, and the walk reads an
    // explicit `null` as the absent case and records no member at all. A
    // presence object with one has nowhere to put it, because the schema
    // gives that arm no value to carry.
    if (entry.form == .boolean and entry.value == null) return error.InvalidField;
    if (entry.form == .presence_object and entry.value != null) return error.InvalidField;
    switch (version) {
        .stable => {
            // Only a path this library names is checked, because v1 has no
            // closed capability set and an unknown path is an extension
            // point that may take either form.
            if (!isKnownV1Capability(entry.path)) return;
            if (entry.form != v1CapabilityForm(entry.path)) return error.InvalidField;
        },
        .draft => {
            if (entry.form != v2_capability_form) return error.InvalidField;
        },
    }
}

/// Refuse a set the decoder for `version` and `side` could not have returned.
///
/// Separate from [`encodeCapabilityObject`] so that
/// `encodeInitializeCapabilities` can run it before it writes the member
/// name: a refusal that reached the caller after `{"capabilities":` had
/// landed in the buffer would leave a prefix that reads as a member and is
/// not a document.
fn validateCapabilitySet(
    version: WireVersion,
    side: Side,
    set: CapabilitySet,
) EncodeError!void {
    // Neither schema gives a capability object to a side-independent method,
    // and `decodeCapabilityObject` refuses that before it reads a byte.
    if (side == .protocol) return error.InvalidField;
    for (set.entries) |entry| try validateCapabilityEntry(version, entry);
}

/// The member name a top-level path takes inside the capability object.
///
/// A v2 path keeps the `capabilities` root, because that is the member both
/// sides carry there, and this function writes the contents of that member
/// rather than the member itself: the root is the member's name, which
/// `encodeInitializeCapabilities` writes. A v1 path is relative to the side's
/// own object already, so it is its own key.
fn capabilityRootKey(version: WireVersion, path: []const u8) []const u8 {
    if (version == .draft and std.mem.startsWith(u8, path, v2_capabilities_root)) {
        return path[v2_capabilities_root.len..];
    }
    return path;
}

/// The member name `path` takes inside the open object `parent`.
fn capabilityChildKey(
    version: WireVersion,
    parent: []const u8,
    path: []const u8,
) []const u8 {
    if (version == .stable and isV1SessionGate(parent, path)) {
        return path[v1_session_capabilities.gate_prefix.len..];
    }
    return path[parent.len + 1 ..];
}

/// Whether the object at `parent` is still open when `path` is written.
fn isCapabilityAncestor(
    version: WireVersion,
    parent: []const u8,
    path: []const u8,
) bool {
    if (path.len > parent.len and
        path[parent.len] == '.' and
        std.mem.startsWith(u8, path, parent))
    {
        return true;
    }
    // The v1 session gates are recorded under an object whose name is not the
    // head of the paths inside it, so the crossing `capabilityChildKey` makes
    // on the way out is the same crossing that has to be read on the way in.
    return version == .stable and isV1SessionGate(parent, path);
}

/// Encode a capability object into `writer`.
///
/// The exact inverse of [`decodeCapabilityObject`] over the set it returns. A
/// document the walk can produce re-encodes to the same bytes: the entries
/// are recorded parent first, so the nesting comes back in the order it went
/// out, and nothing is written for a member that recorded nothing.
///
/// The entries are expected in the order the walk recorded them, which is
/// what a decoded set carries. The nesting is read from the paths, so a
/// hand-built set whose paths are not a parent-then-child chain writes a
/// shape the walk would never have produced.
///
/// [`Capability.known`] is read from the path rather than written, because
/// the decoder derives it from the path and the version and it is not a fact
/// the wire carries. A caller that set it by hand gets the derived answer
/// back, which is the one the gate tables are built from.
pub fn encodeCapabilityObject(
    version: WireVersion,
    side: Side,
    set: CapabilitySet,
    writer: *json.Writer,
) EncodeError!void {
    // A capability object *is* the member, so an absent member is not a value
    // this can spell: `{}` would decode as a member that was there and
    // advertised nothing, which is `present = true`.
    if (!set.present) return error.InvalidField;
    try validateCapabilitySet(version, side, set);

    // The set is flat, so the nesting is rebuilt from the paths. The object
    // still open above an entry is its deepest ancestor, which is the last
    // one recorded before it: a prefix is shorter than what it prefixes, and
    // the walk records an ancestor before anything inside it. Anything else
    // has closed already, and closes here.
    var open: [json.max_depth + 1]usize = undefined;
    var depth: usize = 0;

    try writer.byte('{');
    for (set.entries, 0..) |entry, index| {
        while (depth != 0 and !isCapabilityAncestor(
            version,
            set.entries[open[depth - 1]].path,
            entry.path,
        )) {
            depth -= 1;
            try writer.byte('}');
        }
        // A member needs a comma before it when the one before it was not its
        // own ancestor, and that is the whole rule: an ancestor wrote the
        // object this one goes inside, so the object is already open and no
        // separator has been written since its brace. Anything else was a
        // sibling or the last member of a closed subtree, and both leave a
        // member already written in the object this one joins.
        if (index != 0 and !isCapabilityAncestor(
            version,
            set.entries[index - 1].path,
            entry.path,
        )) {
            try writer.byte(',');
        }
        // Bounded by the same depth `CapabilityWalk` refuses past, so a set
        // nested deeper than any decode can produce is reported rather than
        // written past the end of the stack. It is checked before the member
        // is written, so the refusal is the last thing a caller sees.
        if (entry.form == .presence_object and depth == open.len) {
            return error.BufferTooSmall;
        }
        const key = if (depth == 0) capabilityRootKey(version, entry.path) else capabilityChildKey(
            version,
            set.entries[open[depth - 1]].path,
            entry.path,
        );
        try writer.string(key);
        try writer.byte(':');
        switch (entry.form) {
            .boolean => try writer.slice(if (entry.value.?) "true" else "false"),
            .presence_object => {
                open[depth] = index;
                depth += 1;
                try writer.byte('{');
            },
        }
    }
    while (depth != 0) : (depth -= 1) try writer.byte('}');
    try writer.byte('}');
}

/// The wire member that carries `side`'s capabilities.
fn capabilityMemberName(version: WireVersion, side: Side) DecodeError![]const u8 {
    return switch (version) {
        // v1 gave the two sides two members, which is where the two gate
        // vocabularies come from.
        .stable => switch (side) {
            .client => v2_renames.client_capabilities_v1,
            .agent => v2_renames.agent_capabilities_v1,
            .protocol => error.InvalidField,
        },
        // v2 merged them into one member for both sides.
        .draft => switch (side) {
            .client, .agent => v2_renames.client_capabilities_v2,
            .protocol => error.InvalidField,
        },
    };
}

/// Decode the capability member of an `initialize` request or response.
///
/// The member is optional in every version, so an initialize that advertises
/// nothing decodes to an absent set rather than an error: section 6.5 makes
/// omission mean unsupported, which is a set of no paths.
pub fn decodeInitializeCapabilities(
    version: WireVersion,
    side: Side,
    raw: []const u8,
    out: []Capability,
    paths: []u8,
    scratch: []u8,
) DecodeError!CapabilitySet {
    const member = try capabilityMemberName(version, side);
    var reader = json.Reader.init(raw);
    var capabilities: ?[]const u8 = null;
    // The member is carried out of the loop rather than returned from inside
    // it, so the reader is walked to the closing brace and the check below is
    // one every path out of this function makes. The first occurrence wins,
    // as it did when the loop returned on it.
    if (!(try reader.beginObject())) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, member) and capabilities == null) {
                // The nested decode runs on a borrowed slice of this document,
                // so it costs no scratch and the outer reader is left alone.
                // The keys it read are dead by then, which is why both may
                // share one buffer.
                capabilities = try reader.rawValue(scratch);
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    // The `initialize` body is one JSON value, and so is the capability
    // member inside it. Bytes after the outer closing brace are a second
    // document the transport did not split, and `jsonrpc.decode` refuses them
    // for the same reason.
    if (!reader.atEnd()) return error.MalformedJson;

    if (capabilities) |lexeme| {
        return decodeCapabilityObject(version, side, lexeme, out, paths, scratch);
    }
    return .{ .entries = out[0..0], .present = false };
}

/// Encode the capability member of an `initialize` request or response.
///
/// The inverse of [`decodeInitializeCapabilities`] over the value it returns:
/// the body written here decodes back to `set`, under the member name this
/// version gives `side`. It is not the inverse of the whole `initialize`
/// body, which also carries a protocol version and an info object this
/// module does not model, so a caller writing one composes the two around
/// this rather than calling it alone.
pub fn encodeInitializeCapabilities(
    version: WireVersion,
    side: Side,
    set: CapabilitySet,
    writer: *json.Writer,
) EncodeError!void {
    // The one error `capabilityMemberName` returns is `error.InvalidField`,
    // and that error is in both sets, so the translation drops nothing.
    const member = capabilityMemberName(version, side) catch return error.InvalidField;
    // An absent set is written as an absent member rather than an empty one.
    // Omission is what the decoder reads back as `present = false`, while an
    // empty member decodes as present and advertising nothing: that tells a
    // peer the object was built and the answer was no, where omission says
    // there was no question.
    if (!set.present) {
        try writer.slice("{}");
        return;
    }
    // Ahead of the member name rather than left to the nested call, so a
    // refused set leaves the buffer untouched rather than holding
    // `{"capabilities":`.
    try validateCapabilitySet(version, side, set);
    try writer.byte('{');
    try writer.string(member);
    try writer.byte(':');
    try encodeCapabilityObject(version, side, set, writer);
    try writer.byte('}');
}

// --- 6.6 Permission options ----------------------------------------------------

/// The `kind` of a permission option, verbatim from the specification.
pub const PermissionOptionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,

    pub fn fromString(text: []const u8) ?PermissionOptionKind {
        inline for (@typeInfo(PermissionOptionKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) {
                return @field(PermissionOptionKind, field.name);
            }
        }
        return null;
    }

    pub fn string(self: PermissionOptionKind) []const u8 {
        return @tagName(self);
    }

    /// Whether acting on this option grants the action.
    pub fn grants(self: PermissionOptionKind) bool {
        return switch (self) {
            .allow_once, .allow_always => true,
            .reject_once, .reject_always => false,
        };
    }
};

/// A decoded `RequestPermissionOutcome`.
///
/// There is deliberately no catch-all variant. The specification requires that
/// an unrecognised outcome never be treated as approval, and a `rejected` or
/// `unknown` default would be a guess that could be read as consent.
pub const PermissionOutcome = union(enum) {
    /// The client cancelled. The v1 specification requires this response to
    /// every pending permission request when a `session/cancel` arrives.
    cancelled,
    /// The client chose the option named by `option_id`.
    selected: []const u8,
};

/// Decode a `RequestPermissionOutcome` object.
///
/// An `outcome` the library does not know is `error.UnknownTag`. That is the
/// whole point: PROTOCOLS.md section 6.6 requires an agent receiving an
/// unrecognised outcome to refuse to treat it as approval, and the only safe
/// surface for that is an error the caller must handle.
pub fn decodePermissionOutcome(
    raw: []const u8,
    scratch: []u8,
) DecodeError!PermissionOutcome {
    var reader = json.Reader.init(raw);
    var branch: ?enum { cancelled, selected } = null;
    var option_id: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "outcome")) {
            const text = try reader.string(scratch);
            if (std.mem.eql(u8, text, "cancelled")) {
                branch = .cancelled;
            } else if (std.mem.eql(u8, text, "selected")) {
                branch = .selected;
            } else {
                // Not a catch-all. Neither schema version declares a third
                // branch, so an unknown outcome is undefined by spec, and the
                // specification forbids reading it as approval.
                return error.UnknownTag;
            }
        } else if (std.mem.eql(u8, key, "optionId")) {
            option_id = try reader.string(scratch);
        } else {
            try reader.skipValue(scratch);
        }
    }

    // An outcome is one JSON value, and this is the one decoder in this file
    // with a matching encoder. Bytes behind the closing brace would be
    // dropped by `encodePermissionOutcome` on the way back out, so accepting
    // them breaks `encode(decode(b)) == b` silently: the truncated bytes
    // still decode. `jsonrpc.decode` refuses the same document for the same
    // reason.
    if (!reader.atEnd()) return error.MalformedJson;

    const resolved = branch orelse return error.MissingField;
    if (resolved == .cancelled) {
        // A cancelled outcome naming an option contradicts itself.
        if (option_id != null) return error.InvalidField;
        return .cancelled;
    }
    return .{ .selected = option_id orelse return error.MissingField };
}

/// The v2 permission subject, section 6.6.
///
/// The subject is optional on the request, and an omitted or `null` subject
/// means approval with no structured content. Unlike
/// [`decodePermissionOutcome`] this is *not* a closed set: v2 replaced the
/// `oneOf` with an `anyOf` and a free-`type` catch-all, so an unknown type is
/// defined by the schema and lands in [`PermissionSubject.other`] rather than
/// being an error.
pub const PermissionSubject = union(enum) {
    /// Carries a required `toolCall`, as borrowed JSON text.
    ///
    /// The library does not model `ToolCallUpdate`, so the object is carried
    /// verbatim instead of being flattened into fields this module would then
    /// have to keep in step with the schema.
    tool_call: []const u8,
    /// Carries a required `command` and a required **absolute** `cwd`.
    command: CommandSubject,
    /// Any other `type` string. The other members of the object are opaque.
    other: []const u8,
};

/// The `command` arm of a v2 permission subject.
pub const CommandSubject = struct {
    /// The command line, required.
    command: []const u8,
    /// The working directory, required and **absolute**.
    cwd: []const u8,
    /// The tool call this command belongs to, when the agent named one.
    tool_call_id: ?[]const u8 = null,
    /// The terminal this command runs in, when the agent named one.
    terminal_id: ?[]const u8 = null,
};

/// The v2 permission subject discriminator strings.
pub const permission_subject_type = struct {
    pub const tool_call = "tool_call";
    pub const command = "command";
};

/// Whether `path` is an absolute POSIX path.
///
/// The v2 `CommandPermissionSubject.cwd` is an `AbsolutePath`, so a relative
/// `cwd` is a value the schema does not permit. It matters beyond the schema:
/// a relative path would resolve against whatever working directory the
/// process that runs the command happens to have, so the user approving a
/// command in one directory would approve it in another.
pub fn isAbsolutePath(path: []const u8) bool {
    return path.len != 0 and path[0] == '/';
}

/// Read a nullable string member, where an absent member and `null` agree.
fn nullableString(reader: *json.Reader, scratch: []u8) DecodeError!?[]const u8 {
    reader.skipWhitespace();
    if (reader.peek() == 'n') {
        try reader.nullLiteral();
        return null;
    }
    const value = try reader.string(scratch);
    return value;
}

/// Decode a v2 `RequestPermissionSubject` object.
///
/// The `type` member is required and selects the arm. A missing or malformed
/// required member of a known arm is a decode error; an unknown `type` is not,
/// because the v2 schema defines the catch-all that receives it.
pub fn decodePermissionSubject(
    raw: []const u8,
    scratch: []u8,
) DecodeError!PermissionSubject {
    var reader = json.Reader.init(raw);
    var tag: ?[]const u8 = null;
    var tool_call: ?[]const u8 = null;
    var subject: CommandSubject = .{ .command = "", .cwd = "" };
    var saw_command = false;
    var saw_cwd = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "type")) {
            tag = try reader.string(scratch);
        } else if (std.mem.eql(u8, key, "toolCall")) {
            tool_call = try reader.rawValue(scratch);
        } else if (std.mem.eql(u8, key, "command")) {
            subject.command = try reader.string(scratch);
            saw_command = true;
        } else if (std.mem.eql(u8, key, "cwd")) {
            subject.cwd = try reader.string(scratch);
            saw_cwd = true;
        } else if (std.mem.eql(u8, key, "toolCallId")) {
            subject.tool_call_id = try nullableString(&reader, scratch);
        } else if (std.mem.eql(u8, key, "terminalId")) {
            subject.terminal_id = try nullableString(&reader, scratch);
        } else {
            try reader.skipValue(scratch);
        }
    }

    // A subject is one JSON value, and the arms above borrowed their lexemes
    // out of it, so a tail behind the closing brace is bytes this function
    // has read and not part of the document. The check is here rather than in
    // the loop so that a document carrying a lexeme member refuses it too.
    // `jsonrpc.decode` refuses the same document for the same reason.
    if (!reader.atEnd()) return error.MalformedJson;

    const kind = tag orelse return error.MissingField;
    if (std.mem.eql(u8, kind, permission_subject_type.tool_call)) {
        const call = tool_call orelse return error.MissingField;
        // `ToolCallUpdate` is an object. A `null` here is a missing tool call
        // wearing a key, and the caller would read it as a permission prompt.
        if (call.len == 0 or call[0] != '{') return error.InvalidField;
        return .{ .tool_call = call };
    }
    if (std.mem.eql(u8, kind, permission_subject_type.command)) {
        if (!saw_command or !saw_cwd) return error.MissingField;
        if (!isAbsolutePath(subject.cwd)) return error.InvalidField;
        return .{ .command = subject };
    }
    return .{ .other = kind };
}

/// Whether `text` is exactly one JSON value, and that value is an object.
///
/// Both halves are the checks `decodePermissionSubject` makes on a `toolCall`
/// lexeme: `rawValue` proved the value was complete when it took the lexeme,
/// and the arm's own test is that it is an object. Checking the opening byte
/// alone would let `{"a":1} {"b":2}` through and splice a second document
/// into the middle of the member, which the decoder then refuses.
fn isJsonObject(text: []const u8) bool {
    var reader = json.Reader.init(text);
    reader.skipWhitespace();
    if (reader.peek() != @as(?u8, '{')) return false;
    // `skipValue` is never written to and takes the scratch only so that one
    // buffer serves every read, so the empty slice here is a buffer nobody
    // has to size.
    reader.skipValue(&.{}) catch return false;
    return reader.atEnd();
}

/// Whether `tag` names one of the two arms `PermissionSubject` models.
fn isNamedSubjectType(tag: []const u8) bool {
    return std.mem.eql(u8, tag, permission_subject_type.tool_call) or
        std.mem.eql(u8, tag, permission_subject_type.command);
}

/// Refuse a subject `decodePermissionSubject` could not have returned.
///
/// The two modelled arms carry every member the schema requires of them, so
/// each one decodes back to what it was built from. The catch-all is the
/// exception: `type` selects the arm, so a tag that names a modelled arm is
/// a request for that arm without the members it needs, and it decodes as
/// `error.MissingField`.
fn validatePermissionSubject(subject: PermissionSubject) EncodeError!void {
    switch (subject) {
        .tool_call => |call| {
            if (!isJsonObject(call)) return error.InvalidField;
        },
        .command => |command| {
            // Refused before a byte is written, because
            // `decodePermissionSubject` refuses the same subject with
            // `error.InvalidField`, and a request this library cannot read
            // back is a request a peer has been asked to approve on words
            // this library will not stand behind. PROTOCOLS.md 6.6 makes the
            // path absolute because a relative one resolves against whatever
            // working directory the process that runs the command happens to
            // have, so the user approving a command in one directory would
            // approve it in another.
            if (!isAbsolutePath(command.cwd)) return error.InvalidField;
        },
        .other => |tag| {
            if (isNamedSubjectType(tag)) return error.InvalidField;
        },
    }
}

/// Encode a v2 `RequestPermissionSubject` object.
///
/// The exact inverse of [`decodePermissionSubject`], and it refuses the three
/// subjects its decoder refuses before it writes either.
///
/// The catch-all arm writes the `type` and nothing else, because the other
/// members of such an object belong to the peer and this module models none
/// of them. `acp_session.writePermissionSubject` takes the opposite line and
/// refuses the arm outright, because there the missing members would be a
/// request the agent never described. Here the caller holds a
/// `PermissionSubject` and asked for a subject, so the discriminator is what
/// it named and the round trip through it is exact.
pub fn encodePermissionSubject(
    subject: PermissionSubject,
    writer: *json.Writer,
) EncodeError!void {
    try validatePermissionSubject(subject);
    switch (subject) {
        .tool_call => |call| {
            try writer.slice(
                "{\"type\":\"" ++ permission_subject_type.tool_call ++ "\",\"toolCall\":",
            );
            try writer.slice(call);
            try writer.byte('}');
        },
        .command => |command| {
            try writer.slice(
                "{\"type\":\"" ++ permission_subject_type.command ++ "\",\"command\":",
            );
            try writer.string(command.command);
            try writer.slice(",\"cwd\":");
            try writer.string(command.cwd);
            if (command.tool_call_id) |id| {
                try writer.slice(",\"toolCallId\":");
                try writer.string(id);
            }
            if (command.terminal_id) |id| {
                try writer.slice(",\"terminalId\":");
                try writer.string(id);
            }
            try writer.byte('}');
        },
        .other => |tag| {
            try writer.slice("{\"type\":");
            try writer.string(tag);
            try writer.byte('}');
        },
    }
}

/// Encode a permission outcome.
pub fn encodePermissionOutcome(outcome: PermissionOutcome, writer: *json.Writer) EncodeError!void {
    switch (outcome) {
        .cancelled => try writer.slice("{\"outcome\":\"cancelled\"}"),
        .selected => |option_id| {
            try writer.slice("{\"outcome\":\"selected\",\"optionId\":");
            try writer.string(option_id);
            try writer.byte('}');
        },
    }
}

/// The `kind` of one option as it arrives, with the two versions' openness
/// kept apart.
///
/// [`PermissionOptionKind`] is the four named values in both versions. What
/// differs is whether a fifth string is a value at all: v1 declares a closed
/// `oneOf` and v2 an `anyOf` plus an `other` branch. One struct reports the
/// unknown kind at v1 and carries it at v2, so a caller cannot read a v2
/// extension as if it were one of the four.
pub const PermissionOptionKindValue = union(enum) {
    /// One of the four named kinds.
    known: PermissionOptionKind,
    /// A kind the library does not name, which only v2 can deliver.
    other: []const u8,
};

/// One `PermissionOption` of a request.
///
/// `required: ["optionId", "name", "kind"]` in both versions, and the v2
/// request adds no member to it. These three are what the user reads and what
/// an outcome names back, so the decoder keeps them apart instead of collapsing
/// the option into its kind.
pub const PermissionOption = struct {
    option_id: []const u8,
    name: []const u8,
    kind: PermissionOptionKindValue,

    /// Whether choosing this option grants the action, or null when the kind is
    /// one this library does not name.
    ///
    /// Null rather than false, because v2's catch-all means a kind can arrive
    /// that the schema defines and this library does not, and answering "does
    /// not grant" for it would be the same guess as answering "grants".
    pub fn grants(self: PermissionOption) ?bool {
        return switch (self.kind) {
            .known => |kind| kind.grants(),
            .other => null,
        };
    }
};

/// The v1 `session/request_permission` request.
pub const PermissionRequestV1 = struct {
    session_id: []const u8,
    /// The `ToolCallUpdate`, carried as borrowed JSON text. This module does
    /// not model a tool call, so flattening the object would create a second
    /// definition to keep in step with the schema.
    tool_call: []const u8,
    /// The offered choices. v1 puts no `minItems` on the array, so an empty one
    /// is well formed.
    options: []const PermissionOption,
};

/// The v2 `session/request_permission` request.
pub const PermissionRequestV2 = struct {
    session_id: []const u8,
    /// Required in v2: the prompt the user reads before choosing. v1 has no
    /// such member, and the tool call moves out of the request root and into
    /// the subject.
    title: []const u8,
    description: ?[]const u8,
    /// Omitted and `null` both mean no structured subject, so the two agree.
    subject: ?PermissionSubject,
    /// The offered choices. v2 adds `"minItems": 1`, so an empty array is a
    /// request the user cannot answer.
    options: []const PermissionOption,
};

/// A permission request of one wire version.
///
/// The tag is the wire version rather than a library enum, because the two
/// requests share no required member: v1 requires `toolCall` and v2 requires
/// `title`. One struct carrying both would invite a reader to accept a request
/// the peer never sent.
pub const PermissionRequest = union(WireVersion) {
    stable: PermissionRequestV1,
    draft: PermissionRequestV2,
};

/// Decode `session/request_permission` for `version`.
///
/// `out_options` is the caller's array of options and `scratch` is the
/// reader's escape buffer. Nothing allocates, and a request with more options
/// than the caller reserved is reported rather than truncated: a truncated
/// choice list would hide the option the user wanted to pick.
pub fn decodePermissionRequest(
    version: WireVersion,
    raw: []const u8,
    out_options: []PermissionOption,
    scratch: []u8,
) DecodeError!PermissionRequest {
    var reader = json.Reader.init(raw);
    var session_id: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var tool_call: ?[]const u8 = null;
    var subject_text: ?[]const u8 = null;
    var option_count: usize = 0;
    var saw_options = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "sessionId")) {
            session_id = try reader.string(scratch);
        } else if (std.mem.eql(u8, key, "title")) {
            title = try reader.string(scratch);
        } else if (std.mem.eql(u8, key, "description")) {
            description = try nullableString(&reader, scratch);
        } else if (std.mem.eql(u8, key, "toolCall")) {
            // v1 only, and borrowed raw text, so it costs no scratch.
            tool_call = try reader.rawValue(scratch);
        } else if (std.mem.eql(u8, key, "subject")) {
            subject_text = try reader.rawValue(scratch);
        } else if (std.mem.eql(u8, key, "options")) {
            option_count = try decodePermissionOptions(version, &reader, out_options, scratch);
            saw_options = true;
        } else {
            // A v2 request carries no `toolCall` and a v1 request no `title`,
            // so a peer that sends the other version's member is extending the
            // request rather than making it malformed.
            try reader.skipValue(scratch);
        }
    }

    // A request is one JSON value, and the `toolCall` and `subject` lexemes
    // above are sub-slices of it, so a tail behind the closing brace is a
    // second document this function would answer as though it had not
    // arrived. The check is here rather than in the loop for that reason.
    // `jsonrpc.decode` refuses the same document for the same reason.
    if (!reader.atEnd()) return error.MalformedJson;

    const id = session_id orelse return error.MissingField;
    if (!saw_options) return error.MissingField;
    const options = out_options[0..option_count];

    if (version == .stable) {
        const call = tool_call orelse return error.MissingField;
        // `ToolCallUpdate` is an object. A `null` here is a missing tool call
        // wearing a key, and the caller would show the user a permission prompt
        // for nothing.
        if (call.len == 0 or call[0] != '{') return error.InvalidField;
        return .{ .stable = .{
            .session_id = id,
            .tool_call = call,
            .options = options,
        } };
    }

    // v2 names `minItems: 1`, so an empty array is not a request at all.
    if (options.len == 0) return error.InvalidField;
    return .{ .draft = .{
        .session_id = id,
        .title = title orelse return error.MissingField,
        .description = description,
        .subject = try decodeSubjectMember(subject_text, &reader, scratch),
        .options = options,
    } };
}

/// Refuse an option the decoder for `version` would not return.
///
/// The three members an option requires are all written, so the kind is the
/// only thing left to refuse. v1 declares a closed `oneOf`, so a fifth kind is
/// undefined by the schema and `decodePermissionOptionKind` reports it; v2's
/// `other` branch makes it a value, and the text is written as it arrived.
fn validatePermissionOption(version: WireVersion, option: PermissionOption) EncodeError!void {
    switch (option.kind) {
        .known => {},
        .other => {
            if (unknownTagPolicy(version) == .reject) return error.UnknownTag;
        },
    }
}

/// Write one element of the `options` array.
fn encodePermissionOption(option: PermissionOption, writer: *json.Writer) EncodeError!void {
    try writer.slice("{\"optionId\":");
    try writer.string(option.option_id);
    try writer.slice(",\"name\":");
    try writer.string(option.name);
    try writer.slice(",\"kind\":");
    switch (option.kind) {
        .known => |kind| try writer.string(kind.string()),
        .other => |text| try writer.string(text),
    }
    try writer.byte('}');
}

/// Encode `session/request_permission` for the version the value's own tag names.
///
/// The exact inverse of [`decodePermissionRequest`]: the two agree on every
/// value one of them can reach, and every value this refuses is one the
/// decoder could not have returned.
///
/// The whole request is checked before the first byte is written. A refusal
/// halfway through would leave `{"sessionId":"s1","title":"t` in the caller's
/// buffer, which is neither a request nor nothing, so a caller that sized the
/// buffer for the refusal would have to discard what it holds rather than
/// read it.
pub fn encodePermissionRequest(
    request: PermissionRequest,
    writer: *json.Writer,
) EncodeError!void {
    const session_id: []const u8 = switch (request) {
        .stable => |value| value.session_id,
        .draft => |value| value.session_id,
    };
    const options: []const PermissionOption = switch (request) {
        .stable => |value| value.options,
        .draft => |value| value.options,
    };
    switch (request) {
        .stable => |value| {
            // `ToolCallUpdate` is an object, and `null` here is a missing
            // tool call wearing a key.
            if (!isJsonObject(value.tool_call)) return error.InvalidField;
            for (value.options) |option| try validatePermissionOption(.stable, option);
        },
        .draft => |value| {
            // v2 names `minItems: 1`, so a request the user cannot answer is
            // not a request at all.
            if (options.len == 0) return error.InvalidField;
            if (value.subject) |subject| try validatePermissionSubject(subject);
            for (value.options) |option| try validatePermissionOption(.draft, option);
        },
    }

    try writer.slice("{\"sessionId\":");
    try writer.string(session_id);
    switch (request) {
        .stable => |value| {
            // Verbatim, because a `ToolCallUpdate` is not modelled here and
            // this is the one member an agent cannot afford to have
            // re-shaped.
            try writer.slice(",\"toolCall\":");
            try writer.slice(value.tool_call);
        },
        .draft => |value| {
            try writer.slice(",\"title\":");
            try writer.string(value.title);
            // Omitted rather than written `null`, because an omitted member
            // and a `null` one mean the same in both schemas and
            // `decodePermissionRequest` reads them as one.
            if (value.description) |text| {
                try writer.slice(",\"description\":");
                try writer.string(text);
            }
            if (value.subject) |subject| {
                try writer.slice(",\"subject\":");
                try encodePermissionSubject(subject, writer);
            }
        },
    }
    try writer.slice(",\"options\":[");
    for (options, 0..) |option, index| {
        if (index != 0) try writer.byte(',');
        try encodePermissionOption(option, writer);
    }
    try writer.slice("]}");
}

/// Read the `options` array into caller-owned storage, returning the count.
fn decodePermissionOptions(
    version: WireVersion,
    reader: *json.Reader,
    out: []PermissionOption,
    scratch: []u8,
) DecodeError!usize {
    var count: usize = 0;
    if (try reader.beginArray()) return count;
    while (try reader.nextArrayElement()) {
        if (count == out.len) return error.BufferTooSmall;
        out[count] = try decodePermissionOption(version, reader, scratch);
        count += 1;
    }
    return count;
}

/// Decode one element of the `options` array.
fn decodePermissionOption(
    version: WireVersion,
    reader: *json.Reader,
    scratch: []u8,
) DecodeError!PermissionOption {
    var option: PermissionOption = .{
        .option_id = "",
        .name = "",
        .kind = .{ .known = .reject_once },
    };
    var saw_id = false;
    var saw_name = false;
    var saw_kind = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "optionId")) {
            option.option_id = try reader.string(scratch);
            saw_id = true;
        } else if (std.mem.eql(u8, key, "name")) {
            option.name = try reader.string(scratch);
            saw_name = true;
        } else if (std.mem.eql(u8, key, "kind")) {
            option.kind = try decodePermissionOptionKind(version, reader, scratch);
            saw_kind = true;
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!saw_id or !saw_name or !saw_kind) return error.MissingField;
    return option;
}

/// Decode one `kind`, keeping the two versions' openness apart.
fn decodePermissionOptionKind(
    version: WireVersion,
    reader: *json.Reader,
    scratch: []u8,
) DecodeError!PermissionOptionKindValue {
    const text = try reader.string(scratch);
    if (PermissionOptionKind.fromString(text)) |kind| return .{ .known = kind };
    // v1's closed `oneOf` leaves a fifth string undefined by the schema, so it
    // is reported. v2's `other` branch makes it a value the caller can show
    // without this library guessing what choosing it would do.
    if (unknownTagPolicy(version) == .catch_all) return .{ .other = text };
    return error.UnknownTag;
}

/// Resolve the optional `subject` member once the request has been read.
///
/// The nested decode runs last and starts its own high-water mark, so it is
/// given the unread tail of `scratch`: reusing the whole buffer would land the
/// subject's strings on top of the ones already handed out for `sessionId`,
/// `title` and the options, which is the aliasing the scratch contract exists
/// to prevent.
fn decodeSubjectMember(
    subject_text: ?[]const u8,
    reader: *const json.Reader,
    scratch: []u8,
) DecodeError!?PermissionSubject {
    const text = subject_text orelse return null;
    // `null` is the absent case, not a member holding a subject.
    if (std.mem.eql(u8, text, "null")) return null;
    // The optional is never null here: both absent cases returned above.
    const subject: ?PermissionSubject = try decodePermissionSubject(text, scratch[reader.bump..]);
    return subject;
}

// --- 6.7 Elicitation -----------------------------------------------------------

/// The elicitation `mode` values, in the spelling the classify tables take.
///
/// This is the only place the pair is written. [`classifyElicitationMode`] reads
/// it, `ElicitationMode.fromString` scans it and `ElicitationMode.string`
/// indexes it, so a mode added to the enum is classified and encoded without a
/// second list to keep in step. The check below is what makes the indexing
/// sound: it fails the build rather than reading past the end of the table.
pub const elicitation_modes = [_][]const u8{ "form", "url" };

/// The elicitation `mode` values.
///
/// ACP deliberately diverges from MCP: each supported mode must be advertised
/// explicitly, and `{}` is **not** form-only support. An adapter translating
/// between them must not pass an empty ACP capability set through as an MCP
/// form-only capability.
pub const ElicitationMode = enum {
    form,
    url,

    pub fn fromString(text: []const u8) ?ElicitationMode {
        for (elicitation_modes, 0..) |name, index| {
            if (std.mem.eql(u8, text, name)) return @enumFromInt(index);
        }
        return null;
    }

    pub fn string(self: ElicitationMode) []const u8 {
        return elicitation_modes[@intFromEnum(self)];
    }
};

comptime {
    if (elicitation_modes.len != @typeInfo(ElicitationMode).@"enum".fields.len) {
        @compileError("elicitation_modes and ElicitationMode must name the same modes");
    }
}

/// The elicitation response actions.
pub const ElicitationAction = enum {
    accept,
    decline,
    cancel,

    pub fn fromString(text: []const u8) ?ElicitationAction {
        if (std.mem.eql(u8, text, "accept")) return .accept;
        if (std.mem.eql(u8, text, "decline")) return .decline;
        if (std.mem.eql(u8, text, "cancel")) return .cancel;
        return null;
    }

    pub fn string(self: ElicitationAction) []const u8 {
        return @tagName(self);
    }
};

/// Whether `currency` is a `Cost.currency` value at v2.
///
/// The v2 schema types `Cost.currency` as a string with the pattern
/// `^[A-Z]{3}$`; v1 leaves the member unconstrained, which is why the rule
/// takes no version argument. PROTOCOLS.md section 6 does not carry `Cost`, so
/// the pattern is the deeper source's. It is written here rather than kept
/// beside the scan as a second constant, because a string nothing reads and a
/// scan that has a caller drift apart with nothing to tie them.
pub fn isValidV2Currency(currency: []const u8) bool {
    if (currency.len != 3) return false;
    for (currency) |byte| {
        if (byte < 'A' or byte > 'Z') return false;
    }
    return true;
}

/// The v2 `sessionUpdate` variant strings: 16 named, plus a catch-all.
pub const v2_session_update_variants = [_][]const u8{
    "user_message_chunk",
    "user_message",
    "agent_message_chunk",
    "agent_message",
    "agent_thought_chunk",
    "agent_thought",
    "state_update",
    "tool_call_content_chunk",
    "tool_call_update",
    "terminal_update",
    "terminal_output_chunk",
    "plan_update",
    "available_commands_update",
    "config_option_update",
    "session_info_update",
    "usage_update",
};

/// The v1 `sessionUpdate` variants: 11, a closed set.
pub const v1_session_update_variants = [_][]const u8{
    "user_message_chunk",
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "tool_call_update",
    "plan",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
    "session_info_update",
    "usage_update",
};

/// The v2 `state_update.state` variants.
pub const v2_state_variants = [_][]const u8{
    "running",
    "idle",
    "requires_action",
};

/// The v1 `StopReason` values, a closed set of five.
pub const v1_stop_reasons = [_][]const u8{
    "end_turn",
    "max_tokens",
    "max_turn_requests",
    "refusal",
    "cancelled",
};

/// Whether a version admits a batch array on the wire.
///
/// v2 permits batch arrays and v1 does not. The one-entry minimum a v2 batch
/// carries is a fact about a batch decoder, and this module has none: it does
/// not decode a batch, does not count its entries and does not decide what an
/// empty array answers, so a constant here would bound nothing. The only batch
/// decision this module makes is the one below, and [`no_batch_methods`] is
/// advice to a caller rather than a rule anything here applies.
pub fn permitsBatch(version: WireVersion) bool {
    return version == .draft;
}

/// The state-changing methods the specification says not to batch.
pub const no_batch_methods = [_][]const u8{
    "initialize",
    "auth/login",
    "authenticate",
    "session/new",
    "session/resume",
    "session/prompt",
};

pub fn advisesAgainstBatching(name: []const u8) bool {
    for (no_batch_methods) |method| {
        if (std.mem.eql(u8, method, name)) return true;
    }
    return false;
}

const testing = std.testing;

test "wire versions map to the two stated numbers" {
    try testing.expectEqual(WireVersion.stable, WireVersion.fromNumber(1).?);
    try testing.expectEqual(WireVersion.draft, WireVersion.fromNumber(2).?);
    try testing.expectEqual(@as(?WireVersion, null), WireVersion.fromNumber(3));
    try testing.expectEqual(@as(u16, 1), WireVersion.stable.number());
    try testing.expectEqual(@as(u16, 2), WireVersion.draft.number());
}

test "negotiation echoes a supported version and downgrades an unsupported one" {
    const both = [_]WireVersion{ .stable, .draft };

    const echoed = negotiate(2, &both);
    try testing.expect(echoed == .echoed);
    try testing.expectEqual(WireVersion.draft, echoed.echoed);

    const downgraded = negotiate(3, &both);
    try testing.expect(downgraded == .downgraded);
    // The agent answers with its own highest, which is the draft.
    try testing.expectEqual(WireVersion.draft, downgraded.downgraded);
}

test "an agent that supports no version has no answer to give" {
    const none: [0]WireVersion = .{};
    // The rule is "respond with the latest version it supports". With no
    // supported version there is no such latest, so this is neither an echo
    // nor a downgrade. Reporting the client's own request back as the agent's
    // answer would claim the agent speaks a version it does not, and version
    // 2 is one this library implements.
    for ([_]u16{ 1, 2, 3 }) |requested| {
        const outcome = negotiate(requested, &none);
        try testing.expect(outcome == .agent_supports_nothing);
    }

    // One supported version is enough to answer with, even when it is not the
    // one requested.
    const stable_only = [_]WireVersion{.stable};
    const answered = negotiate(2, &stable_only);
    try testing.expectEqual(WireVersion.stable, answered.downgraded);
}

test "an artifact version is not a wire version" {
    // The crate was 1.9.1 and the v1 schema artifact was v1.23.0 at the
    // research date. Neither is the wire version 1.
    try testing.expectEqual(@as(?WireVersion, null), WireVersion.fromNumber(191));
    try testing.expectEqual(@as(?WireVersion, null), WireVersion.fromNumber(1230));
    try testing.expectEqual(@as(?WireVersion, null), WireVersion.fromNumber(20));
}

test "framing splits on newline and rejects invalid UTF-8" {
    const first = try nextFrame("{\"a\":1}\n{\"b\":2}\n");
    try testing.expectEqualStrings("{\"a\":1}", first.bytes);
    try testing.expect(!first.unterminated);

    const second = try nextFrame(first.rest);
    try testing.expectEqualStrings("{\"b\":2}", second.bytes);
    try testing.expectEqualStrings("", second.rest);

    try testing.expectError(error.InvalidUtf8, nextFrame("\xff\xfe\n"));
}

test "a trailing frame without a delimiter is reported as unterminated" {
    const frame = try nextFrame("{\"a\":1}");
    try testing.expectEqualStrings("{\"a\":1}", frame.bytes);
    try testing.expect(frame.unterminated);
}

test "a message written as a frame cannot contain a raw newline" {
    var buffer: [64]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, writeFrame("{\"a\":1}\n", &writer));
    try testing.expectEqual(@as(usize, 0), writer.len);

    // A JSON-escaped newline is fine: the encoder escapes it, so the frame
    // delimiter stays unambiguous.
    try writeFrame("{\"a\":\"\\n\"}", &writer);
    try testing.expectEqualStrings("{\"a\":\"\\n\"}\n", writer.written());
}

test "writeFrame and nextFrame accept and refuse the same byte sequences" {
    // Each case is a delimiter-free byte sequence, which is what one message
    // is; a raw delimiter would split it in two before either function could
    // read it, and the test above covers that one refusal.
    const cases = [_][]const u8{
        "",
        "{}",
        "{\"a\":1}",
        // Text that is not ASCII is text, so the two-byte sequence survives the
        // round trip rather than being refused for not being ASCII.
        "{\"a\":\"caf\xc3\xa9\"}",
        // An escaped newline is a delimiter in neither direction.
        "{\"a\":\"\\n\"}",
        // 0xff never appears in well-formed UTF-8 and starts no sequence.
        "\xff}",
        // A lead byte that promises two more and does not deliver them.
        "\xe2\x82",
        // A surrogate half, which no well-formed UTF-8 encodes.
        "\xed\xa0\x80",
        // An over-long spelling of `/`, the byte every ASCII text starts with.
        "\xc0\xaf",
        // A lone continuation byte where a lead byte belongs.
        "{\"a\":\"\x80\"}",
    };
    for (cases) |message| {
        var buffer: [64]u8 = undefined;
        var writer = json.Writer.init(&buffer);

        if (nextFrame(message)) |_| {
            // Readable, so writable: bytes put on the wire have to read back as
            // the same message, because a peer failing on what this library
            // emitted is the failure PROTOCOLS.md section 2 rules out.
            try writeFrame(message, &writer);
            const again = try nextFrame(writer.written());
            try testing.expectEqualStrings(message, again.bytes);
            try testing.expect(!again.unterminated);
            try testing.expectEqualStrings("", again.rest);
        } else |_| {
            // Unreadable, so unwritable: bytes this library refuses to decode
            // must not reach the wire, and the refusal comes before the first
            // write, so the writer is left untouched.
            try testing.expectError(error.InvalidField, writeFrame(message, &writer));
            try testing.expectEqual(@as(usize, 0), writer.len);
        }
    }
}

test "the v1 registry names exactly the methods section 6.3 lists" {
    // Sections 6.3 and 6.4 introduce both columns "verbatim", so the table is
    // the contract and a count is not a check on it: a renamed method, a
    // dropped one, and a dropped one paired with a filler all leave the count
    // standing and all break a peer that answers to the name in the table.
    try testing.expect(namesAre(
        &v1_agent_methods,
        &[_][]const u8{
            "initialize",
            "authenticate",
            "session/new",
            "session/load",
            "session/set_mode",
            "session/set_config_option",
            "session/prompt",
            "session/cancel",
            "session/list",
            "session/delete",
            "session/resume",
            "session/close",
            "logout",
        },
    ));
    try testing.expect(namesAre(
        &v1_client_methods,
        &[_][]const u8{
            "session/request_permission",
            "session/update",
            "fs/write_text_file",
            "fs/read_text_file",
            "terminal/create",
            "terminal/output",
            "terminal/release",
            "terminal/wait_for_exit",
            "terminal/kill",
            "elicitation/create",
            "elicitation/complete",
        },
    ));
    try testing.expect(namesAre(&protocol_methods, &[_][]const u8{"$/cancel_request"}));
}

test "the v2 registry names exactly the methods section 6.4 lists" {
    // The same check on the draft's own table, which is a different list: the
    // v2 delta renames the auth methods and drops `fs`, `terminal`,
    // `session/load` and `session/set_mode`, so agreeing with v1 is not a
    // property this library has.
    try testing.expect(namesAre(
        &v2_agent_methods,
        &[_][]const u8{
            "initialize",
            "auth/login",
            "auth/logout",
            "session/new",
            "session/set_config_option",
            "session/prompt",
            "session/cancel",
            "session/list",
            "session/delete",
            "session/resume",
            "session/close",
        },
    ));
    try testing.expect(namesAre(
        &v2_client_methods,
        &[_][]const u8{
            "session/request_permission",
            "session/update",
            "elicitation/create",
            "elicitation/complete",
        },
    ));
    // The draft table carries the same one side-independent method, and it is
    // a separate table from the v1 one, so it is checked twice.
    try testing.expect(namesAre(&protocol_methods, &[_][]const u8{"$/cancel_request"}));
}

test "the three registries are disjoint in wire names, in both versions" {
    // `lookupMethod` searches the three sets in order and answers with the
    // first match, so two sets sharing a name would answer with whichever side
    // came first. The rule is disjointness "within a version", and v2 is a
    // version: it reuses nine of the v1 agent names and all four of the v1
    // client names, so a cross-version check would fail and a per-version one
    // is what the rule asks for.
    for ([_]WireVersion{ .stable, .draft }) |version| {
        const v1_sets = [_][]const MethodInfo{ &v1_agent_methods, &v1_client_methods, &protocol_methods };
        const v2_sets = [_][]const MethodInfo{ &v2_agent_methods, &v2_client_methods, &protocol_methods };
        const sets: []const []const MethodInfo = switch (version) {
            .stable => &v1_sets,
            .draft => &v2_sets,
        };
        for (sets, 0..) |outer, i| {
            for (sets, 0..) |inner, j| {
                if (i >= j) continue;
                for (outer) |a| {
                    for (inner) |b| {
                        try testing.expect(!std.mem.eql(u8, a.name, b.name));
                    }
                }
            }
        }
    }
}

test "session/cancel and session/update are notifications in both versions" {
    for ([_]WireVersion{ .stable, .draft }) |version| {
        try testing.expect((try lookupMethod(version, "session/cancel")).notification);
        try testing.expect((try lookupMethod(version, "session/update")).notification);
        try testing.expect((try lookupMethod(version, "elicitation/complete")).notification);
        try testing.expect((try lookupMethod(version, "$/cancel_request")).notification);
        // initialize is a request, not a notification.
        try testing.expect(!(try lookupMethod(version, "initialize")).notification);
    }
}

test "a method removed in v2 is UnknownMethod at v2, valid at v1" {
    for (v2_removed_methods) |name| {
        try testing.expectError(error.UnknownMethod, lookupMethod(.draft, name));
        try testing.expect((try lookupMethod(.stable, name)).name.len > 0);
    }
}

test "authenticate and logout are renamed, not aliased" {
    const v1 = authMethodName(.stable);
    const v2 = authMethodName(.draft);
    try testing.expectEqualStrings("authenticate", v1.login);
    try testing.expectEqualStrings("logout", v1.logout);
    try testing.expectEqualStrings("auth/login", v2.login);
    try testing.expectEqualStrings("auth/logout", v2.logout);

    // The v1 spelling is not a v2 method, and vice versa.
    try testing.expectError(error.UnknownMethod, lookupMethod(.draft, "authenticate"));
    try testing.expectError(error.UnknownMethod, lookupMethod(.stable, "auth/login"));
}

test "v2 makes auth methods conditional on a non-empty authMethods" {
    try testing.expect((try lookupMethod(.draft, "auth/login")).conditional_on_auth_methods);
    try testing.expect((try lookupMethod(.draft, "auth/logout")).conditional_on_auth_methods);
}

test "the version-2 renames use the specified spellings" {
    try testing.expectEqualStrings("clientInfo", v2_renames.client_info_v1);
    try testing.expectEqualStrings("info", v2_renames.client_info_v2);
    try testing.expectEqualStrings("agentInfo", v2_renames.agent_info_v1);
    try testing.expectEqualStrings("info", v2_renames.agent_info_v2);
    try testing.expectEqualStrings("id", v2_renames.session_config_id_v1);
    try testing.expectEqualStrings("configId", v2_renames.session_config_id_v2);
    try testing.expectEqualStrings("sessionCapabilities", v2_renames.session_capabilities_v1);
    try testing.expectEqualStrings("capabilities.session", v2_renames.session_capabilities_v2);
    try testing.expectEqualStrings("promptCapabilities", v2_renames.prompt_capabilities_v1);
    try testing.expectEqualStrings("capabilities.session.prompt", v2_renames.prompt_capabilities_v2);
}

test "v1 gates are booleans where the schema says so, objects elsewhere" {
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("fs.readTextFile"));
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("fs.writeTextFile"));
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("terminal"));
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("auth.terminal"));
    try testing.expectEqual(
        CapabilityForm.presence_object,
        v1CapabilityForm("elicitation.form"),
    );
    try testing.expectEqual(CapabilityForm.presence_object, v2_capability_form);
}

test "v1 types loadSession and the prompt capabilities as booleans" {
    // The v1 AgentCapabilities schema types all four as boolean with a false
    // default, and the prompt kinds as booleans inside promptCapabilities. A
    // presence object is the wrong read: an agent advertising `false` is
    // saying "unsupported", not "unsupported, but the key is here".
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("loadSession"));
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("promptCapabilities.image"));
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("promptCapabilities.audio"));
    try testing.expectEqual(
        CapabilityForm.boolean,
        v1CapabilityForm("promptCapabilities.embeddedContext"),
    );
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("mcpCapabilities.http"));
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("mcpCapabilities.sse"));
    try testing.expectEqual(CapabilityForm.boolean, v1CapabilityForm("mcpCapabilities.acp"));
}

test "every known v1 capability keeps its stated form" {
    // The client booleans are the filesystem, the terminal, and terminal-mode
    // authentication; every other client gate is a `{}` presence object.
    for (v1_client_capabilities) |path| {
        const boolean = std.mem.startsWith(u8, path, "fs.") or
            std.mem.eql(u8, path, "terminal") or
            std.mem.eql(u8, path, "auth.terminal");
        const want: CapabilityForm = if (boolean) .boolean else .presence_object;
        try testing.expectEqual(want, v1CapabilityForm(path));
    }
    // The agent booleans are loadSession, the three prompt kinds and
    // everything under mcpCapabilities; the session and auth gates are `{}`.
    for (v1_agent_capabilities) |path| {
        const boolean = std.mem.eql(u8, path, "loadSession") or
            std.mem.startsWith(u8, path, "promptCapabilities.") or
            std.mem.startsWith(u8, path, "mcpCapabilities.");
        const want: CapabilityForm = if (boolean) .boolean else .presence_object;
        try testing.expectEqual(want, v1CapabilityForm(path));
    }
}

test "a path that is not a capability is not a boolean capability" {
    // The domain prefix is not a namespace on its own: `terminalFoo` is not in
    // the `terminal` domain, and a capability the library does not know is an
    // extension point rather than a typed gate.
    for ([_][]const u8{
        "terminalFoo",
        "mcpCapabilitiesX",
        "mcpCapabilities.",
        "fs.readTextFileX",
        "promptCapabilities.video",
        "vendor.custom",
    }) |path| {
        try testing.expect(!isKnownV1Capability(path));
        try testing.expectEqual(CapabilityForm.presence_object, v1CapabilityForm(path));
    }
}

test "an unknown v1 capability is not a decode error" {
    // The documented non-breaking extension mechanism.
    try testing.expect(!isKnownV1ClientCapability("vendor.custom"));
    try testing.expect(isKnownV1ClientCapability("fs.readTextFile"));
    try testing.expect(isKnownV1AgentCapability("mcpCapabilities.http"));
}

test "every gated v1 method names a capability its own side declares" {
    // A gate that no known-capability list contains can never be advertised,
    // so the method would be permanently unavailable. Both sides are checked:
    // a client method is gated on a client capability.
    for (v1_agent_methods) |info| {
        if (info.gate.len == 0) continue;
        try testing.expect(isKnownV1AgentCapability(info.gate));
        if (info.gate2.len == 0) continue;
        try testing.expect(isKnownV1AgentCapability(info.gate2));
    }
    for (v1_client_methods) |info| {
        if (info.gate.len == 0) continue;
        try testing.expect(isKnownV1ClientCapability(info.gate));
        if (info.gate2.len == 0) continue;
        try testing.expect(isKnownV1ClientCapability(info.gate2));
    }
    // The other spelling of the session gates is what the deeper source uses.
    // PROTOCOLS.md section 6.5 is the authority and spells them `session.*`,
    // so the other form is not a capability this library accepts.
    try testing.expect(!isKnownV1AgentCapability("sessionCapabilities.delete"));
    try testing.expect(isKnownV1AgentCapability("session.delete"));
}

test "v1 session/resume answers to either gate the two sources give it" {
    // PROTOCOLS.md section 6.5 gives `loadSession` the pair `session/load`,
    // `session/resume`. `research/normative/acp-v1-v2.md` line 67 gates
    // `session/resume` on `sessionCapabilities.resume` and line 64 restricts
    // `loadSession` to `session/load`. PROTOCOLS.md is the authority and the
    // conflict is recorded in the registry, so either spelling enables the
    // method: a peer that advertises one of them does resume.
    const info = try lookupMethod(.stable, "session/resume");
    try testing.expectEqualStrings("loadSession", info.gate);
    try testing.expectEqualStrings("session.resume", info.gate2);

    try testing.expect(isMethodSupported(info, &[_][]const u8{"loadSession"}));
    try testing.expect(isMethodSupported(info, &[_][]const u8{"session.resume"}));
    try testing.expect(isMethodSupported(info, &v1_agent_capabilities));

    // Neither gate is no resume, and a capability that belongs to another
    // method is not this gate by accident.
    try testing.expect(!isMethodSupported(info, &[_][]const u8{}));
    try testing.expect(!isMethodSupported(info, &[_][]const u8{"session.list"}));
    try testing.expect(!isMethodSupported(info, &[_][]const u8{"promptCapabilities.image"}));

    // The alternative is confined to this method. The other three session
    // gates have one spelling each, so none of them grew a second.
    for ([_][]const u8{ "session/list", "session/delete", "session/close" }) |name| {
        const sibling = try lookupMethod(.stable, name);
        try testing.expectEqualStrings("", sibling.gate2);
    }
}

test "elicitation/create is gated per mode, not on one mode alone" {
    // PROTOCOLS.md section 6.5 lists both modes as gates on the same method.
    // The v1 spelling is relative to the client's own capability object and the
    // v2 one carries the `capabilities` root that both sides share, so each
    // version is pinned to its own spelling.
    const per_version = [_]struct { version: WireVersion, form: []const u8, url: []const u8 }{
        .{ .version = .stable, .form = "elicitation.form", .url = "elicitation.url" },
        .{
            .version = .draft,
            .form = "capabilities.elicitation.form",
            .url = "capabilities.elicitation.url",
        },
    };
    for (per_version) |each| {
        const info = try lookupMethod(each.version, "elicitation/create");
        try testing.expectEqualStrings(each.form, info.gate);
        try testing.expectEqualStrings(each.url, info.gate2);

        // A peer advertising URL mode alone supports the method.
        const singleton = [_][]const u8{each.url};
        const form_only = [_][]const u8{each.form};
        try testing.expect(isMethodSupported(info, &singleton));
        try testing.expect(isMethodSupported(info, &form_only));
        const every: []const []const u8 = switch (each.version) {
            .stable => &v1_client_capabilities,
            .draft => &v2_client_capabilities,
        };
        try testing.expect(isMethodSupported(info, every));

        // A peer advertising neither mode does not, and neither does one that
        // advertises something unrelated.
        try testing.expect(!isMethodSupported(info, &[_][]const u8{}));
        try testing.expect(!isMethodSupported(info, &[_][]const u8{"terminal"}));
    }
}

test "a single-gate method still needs its one capability" {
    const read = try lookupMethod(.stable, "fs/read_text_file");
    try testing.expectEqualStrings("fs.readTextFile", read.gate);
    try testing.expectEqualStrings("", read.gate2);
    try testing.expect(isMethodSupported(read, &[_][]const u8{"fs.readTextFile"}));
    try testing.expect(!isMethodSupported(read, &[_][]const u8{"fs.writeTextFile"}));

    // An ungated method is baseline, so omission of every capability keeps it.
    const initialize = try lookupMethod(.stable, "initialize");
    try testing.expect(isMethodSupported(initialize, &[_][]const u8{}));
}

test "permission option kinds are the four stated values" {
    try testing.expectEqual(PermissionOptionKind.allow_always, PermissionOptionKind.fromString("allow_always").?);
    try testing.expectEqual(PermissionOptionKind.reject_once, PermissionOptionKind.fromString("reject_once").?);
    try testing.expectEqual(@as(?PermissionOptionKind, null), PermissionOptionKind.fromString("allow"));
    try testing.expect(PermissionOptionKind.allow_once.grants());
    try testing.expect(!PermissionOptionKind.reject_always.grants());

    // `string` renders the spelling the `kind` member carries, and section 6.6
    // names the four values verbatim. A renderer that emitted `allowOnce` would
    // write a value its own `fromString` rejects, and nothing in the library
    // called it, so Zig never type-checked it.
    try testing.expectEqualStrings("allow_once", PermissionOptionKind.allow_once.string());
    try testing.expectEqualStrings("allow_always", PermissionOptionKind.allow_always.string());
    try testing.expectEqualStrings("reject_once", PermissionOptionKind.reject_once.string());
    try testing.expectEqualStrings("reject_always", PermissionOptionKind.reject_always.string());
    inline for (@typeInfo(PermissionOptionKind).@"enum".fields) |field| {
        const value: PermissionOptionKind = @field(PermissionOptionKind, field.name);
        try testing.expectEqual(value, PermissionOptionKind.fromString(value.string()).?);
    }
}

test "an unrecognised permission outcome is UnknownTag, never approval" {
    var scratch: [128]u8 = undefined;
    // The safety rule. An outcome the agent does not understand must not be
    // treated as approval, and neither schema declares a catch-all.
    try testing.expectError(error.UnknownTag, decodePermissionOutcome(
        \\{"outcome":"approved"}
    , &scratch));
    try testing.expectError(error.UnknownTag, decodePermissionOutcome(
        \\{"outcome":"allow_once","optionId":"opt-1"}
    , &scratch));
    try testing.expectError(error.UnknownTag, decodePermissionOutcome(
        \\{"outcome":""}
    , &scratch));
}

test "a missing outcome member is MissingField, not a default" {
    var scratch: [128]u8 = undefined;
    try testing.expectError(error.MissingField, decodePermissionOutcome(
        \\{"optionId":"opt-1"}
    , &scratch));
    try testing.expectError(error.MissingField, decodePermissionOutcome(
        \\{}
    , &scratch));
}

test "selected without an optionId is MissingField" {
    var scratch: [128]u8 = undefined;
    try testing.expectError(error.MissingField, decodePermissionOutcome(
        \\{"outcome":"selected"}
    , &scratch));
}

test "cancelled must not carry an optionId" {
    var scratch: [128]u8 = undefined;
    const cancelled = try decodePermissionOutcome(
        \\{"outcome":"cancelled"}
    , &scratch);
    try testing.expect(cancelled == .cancelled);

    // A cancelled outcome naming an option is a contradictory message.
    try testing.expectError(error.InvalidField, decodePermissionOutcome(
        \\{"outcome":"cancelled","optionId":"opt-1"}
    , &scratch));
}

test "selected carries the chosen option id" {
    var scratch: [128]u8 = undefined;
    const outcome = try decodePermissionOutcome(
        \\{"outcome":"selected","optionId":"opt-1"}
    , &scratch);
    try testing.expect(outcome == .selected);
    try testing.expectEqualStrings("opt-1", outcome.selected);
}

test "a permission outcome round-trips through the encoder" {
    var scratch: [128]u8 = undefined;
    const source = "{\"outcome\":\"selected\",\"optionId\":\"opt-1\"}";
    const outcome = try decodePermissionOutcome(source, &scratch);

    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodePermissionOutcome(outcome, &writer);
    try testing.expectEqualStrings(source, writer.written());

    // The decoded value of the re-encoded bytes is the same.
    const again = try decodePermissionOutcome(writer.written(), &scratch);
    try testing.expectEqualStrings(outcome.selected, again.selected);
}

test "a permission outcome with a second document behind it is refused" {
    var scratch: [128]u8 = undefined;
    // This is the one decoder in this file with a matching encoder, so the
    // tail here is a real `encode(decode(b)) != b` rather than only a
    // validation hole, and the loss is silent: what the encoder writes still
    // decodes, so nothing downstream would report it.
    const tailed = "{\"outcome\":\"selected\",\"optionId\":\"opt-1\"} trailing";
    try testing.expectError(error.MalformedJson, decodePermissionOutcome(tailed, &scratch));
    try testing.expectError(error.MalformedJson, decodePermissionOutcome(
        \\{"outcome":"cancelled"} trailing
    , &scratch));

    // The accepted document round-trips byte for byte, and the encoder cannot
    // reach the tail, which is what makes refusing it the only way to keep
    // `encode(decode(b)) == b` for every accepted input.
    const source = "{\"outcome\":\"selected\",\"optionId\":\"opt-1\"}";
    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodePermissionOutcome(try decodePermissionOutcome(source, &scratch), &writer);
    try testing.expectEqualStrings(source, writer.written());
    try testing.expect(writer.written().len < tailed.len);
}

test "an absolute path starts at the root" {
    try testing.expect(isAbsolutePath("/"));
    try testing.expect(isAbsolutePath("/srv/work"));
    try testing.expect(isAbsolutePath("/srv/work/../work"));
    try testing.expect(!isAbsolutePath(""));
    try testing.expect(!isAbsolutePath("build"));
    try testing.expect(!isAbsolutePath("./build"));
    try testing.expect(!isAbsolutePath("../build"));
    try testing.expect(!isAbsolutePath("C:/work"));
}

test "a command subject carries its command and an absolute cwd" {
    var scratch: [256]u8 = undefined;
    const subject = try decodePermissionSubject(
        \\{"type":"command","command":"rm -rf build","cwd":"/srv/work","toolCallId":"t1"}
    , &scratch);
    try testing.expect(subject == .command);
    try testing.expectEqualStrings("rm -rf build", subject.command.command);
    try testing.expectEqualStrings("/srv/work", subject.command.cwd);
    try testing.expectEqualStrings("t1", subject.command.tool_call_id.?);
    try testing.expectEqual(@as(?[]const u8, null), subject.command.terminal_id);

    // An explicit `null` is the absent case, not a member holding text.
    const nulled = try decodePermissionSubject(
        \\{"type":"command","command":"ls","cwd":"/w","toolCallId":null,"terminalId":null}
    , &scratch);
    try testing.expectEqual(@as(?[]const u8, null), nulled.command.tool_call_id);
    try testing.expectEqual(@as(?[]const u8, null), nulled.command.terminal_id);

    // A relative cwd would resolve against whatever working directory the
    // process running the command happens to have, so the schema forbids it
    // and so does the decoder.
    try testing.expectError(error.InvalidField, decodePermissionSubject(
        \\{"type":"command","command":"ls","cwd":"build"}
    , &scratch));
    try testing.expectError(error.InvalidField, decodePermissionSubject(
        \\{"type":"command","command":"ls","cwd":""}
    , &scratch));
    try testing.expectError(error.MissingField, decodePermissionSubject(
        \\{"type":"command","command":"ls"}
    , &scratch));
    try testing.expectError(error.MissingField, decodePermissionSubject(
        \\{"type":"command","cwd":"/w"}
    , &scratch));
}

test "a tool call subject carries its toolCall" {
    var scratch: [256]u8 = undefined;
    const subject = try decodePermissionSubject(
        \\{"type":"tool_call","toolCall":{"toolCallId":"t1","title":"Build"}}
    , &scratch);
    try testing.expect(subject == .tool_call);
    try testing.expectEqualStrings(
        "{\"toolCallId\":\"t1\",\"title\":\"Build\"}",
        subject.tool_call,
    );

    try testing.expectError(error.MissingField, decodePermissionSubject(
        \\{"type":"tool_call"}
    , &scratch));
    // A null toolCall is a missing tool call wearing a key.
    try testing.expectError(error.InvalidField, decodePermissionSubject(
        \\{"type":"tool_call","toolCall":null}
    , &scratch));
}

test "an unknown subject type is the schema's catch-all, not an error" {
    var scratch: [256]u8 = undefined;
    // v2 replaced the closed oneOf with an anyOf and a free-type catch-all, so
    // a type this library does not know is defined rather than undefined.
    const future = try decodePermissionSubject(
        \\{"type":"review","note":"whatever the next version adds"}
    , &scratch);
    try testing.expect(future == .other);
    try testing.expectEqualStrings("review", future.other);

    // The discriminator itself is required, so an object without one is not a
    // subject at all.
    try testing.expectError(error.MissingField, decodePermissionSubject(
        \\{"toolCall":{"toolCallId":"t1"}}
    , &scratch));
    try testing.expectError(error.MissingField, decodePermissionSubject(
        \\{}
    , &scratch));
}

test "a permission subject with a second document behind it is refused" {
    var scratch: [256]u8 = undefined;
    // Both arms that carry a lexeme are exercised here, because a check
    // placed inside the member loop would pass as soon as the member it
    // guards had parsed and the tail would slip through behind it.
    try testing.expectError(error.MalformedJson, decodePermissionSubject(
        \\{"type":"tool_call","toolCall":{"toolCallId":"t1","title":"Build"}} trailing
    , &scratch));
    try testing.expectError(error.MalformedJson, decodePermissionSubject(
        \\{"type":"command","command":"rm -rf build","cwd":"/srv/work"} trailing
    , &scratch));
    // The catch-all arm reads the same document and refuses the same tail.
    try testing.expectError(error.MalformedJson, decodePermissionSubject(
        \\{"type":"review"} trailing
    , &scratch));
}

test "elicitation modes and actions are the stated sets" {
    try testing.expectEqual(ElicitationMode.form, ElicitationMode.fromString("form").?);
    try testing.expectEqual(ElicitationMode.url, ElicitationMode.fromString("url").?);
    try testing.expectEqual(@as(?ElicitationMode, null), ElicitationMode.fromString("Form"));

    try testing.expectEqual(ElicitationAction.accept, ElicitationAction.fromString("accept").?);
    try testing.expectEqual(ElicitationAction.decline, ElicitationAction.fromString("decline").?);
    try testing.expectEqual(ElicitationAction.cancel, ElicitationAction.fromString("cancel").?);
    try testing.expectEqual(@as(?ElicitationAction, null), ElicitationAction.fromString("abort"));

    // `string` renders the spelling the `mode` and action members carry, and
    // section 6.7 names the two modes and the three actions verbatim. A
    // renderer that emitted `Accept` would write a value its own `fromString`
    // rejects, and nothing in the library called either one.
    try testing.expectEqualStrings("form", ElicitationMode.form.string());
    try testing.expectEqualStrings("url", ElicitationMode.url.string());
    inline for (@typeInfo(ElicitationMode).@"enum".fields) |field| {
        const value: ElicitationMode = @field(ElicitationMode, field.name);
        try testing.expectEqual(value, ElicitationMode.fromString(value.string()).?);
    }
    try testing.expectEqualStrings("accept", ElicitationAction.accept.string());
    try testing.expectEqualStrings("decline", ElicitationAction.decline.string());
    try testing.expectEqualStrings("cancel", ElicitationAction.cancel.string());
    inline for (@typeInfo(ElicitationAction).@"enum".fields) |field| {
        const value: ElicitationAction = @field(ElicitationAction, field.name);
        try testing.expectEqual(value, ElicitationAction.fromString(value.string()).?);
    }
}

test "the elicitation mode table and the typed set are one set" {
    // `classifyElicitationMode` reads the table `ElicitationMode` is built
    // from, so every mode the type names is a mode the classifier names at the
    // same index. While the two were separate, a mode added to the enum would
    // have been classified as `undefined_tag` at v1 and as `other` at v2 — the
    // exact reading the version rule is about.
    for (elicitation_modes, 0..) |name, index| {
        const mode = ElicitationMode.fromString(name).?;
        try testing.expectEqual(name, mode.string());
        try testing.expectEqual(mode, @as(ElicitationMode, @enumFromInt(index)));
        for ([_]WireVersion{ .stable, .draft }) |version| {
            switch (classifyElicitationMode(version, name)) {
                .named => |found| try testing.expectEqual(index, found),
                else => return error.TestUnexpectedResult,
            }
        }
    }
    // Outside the pair the version rule still applies, so the classifier is not
    // simply reporting every mode as named.
    try testing.expect(classifyElicitationMode(.stable, "markdown") == .undefined_tag);
    try testing.expect(classifyElicitationMode(.draft, "markdown") == .other);
}

test "a v2 currency is three upper-case letters and nothing else" {
    // The v2 `Cost.currency` pattern, `^[A-Z]{3}$`. A scanner that accepted a
    // fourth character, a digit or a lower-case letter would take a value the
    // schema does not define, and one that accepted a short code would take
    // one a cost report cannot be read back from.
    try testing.expect(isValidV2Currency("USD"));
    try testing.expect(isValidV2Currency("EUR"));
    try testing.expect(!isValidV2Currency("usd"));
    try testing.expect(!isValidV2Currency("EURO"));
    try testing.expect(!isValidV2Currency("US"));
    try testing.expect(!isValidV2Currency("US1"));
    try testing.expect(!isValidV2Currency(""));
}

test "v1 has 11 sessionUpdate variants and v2 has 16 plus a catch-all" {
    try testing.expectEqual(@as(usize, 11), v1_session_update_variants.len);
    try testing.expectEqual(@as(usize, 16), v2_session_update_variants.len);
    // current_mode_update is gone in v2; terminal_update is new.
    try testing.expect(!contains(&v2_session_update_variants, "current_mode_update"));
    try testing.expect(contains(&v2_session_update_variants, "terminal_update"));
    // tool_call is replaced by an upsert in v2.
    try testing.expect(contains(&v1_session_update_variants, "tool_call"));
    try testing.expect(!contains(&v2_session_update_variants, "tool_call"));
}

test "only v2 admits batch arrays" {
    try testing.expect(!permitsBatch(.stable));
    try testing.expect(permitsBatch(.draft));
    try testing.expect(advisesAgainstBatching("initialize"));
    try testing.expect(advisesAgainstBatching("session/prompt"));
    try testing.expect(!advisesAgainstBatching("session/list"));
}

test "a v1 permission request carries its tool call and every option" {
    var scratch: [256]u8 = undefined;
    var options: [2]PermissionOption = undefined;
    // The document is written as three fragments only to keep the lines inside
    // the width budget; the JSON is one object.
    const source = "{\"sessionId\":\"s1\",\"toolCall\":{\"toolCallId\":\"t1\",\"title\":\"Build\"}," ++
        "\"options\":[{\"optionId\":\"a\",\"name\":\"Allow\",\"kind\":\"allow_once\"}," ++
        "{\"optionId\":\"b\",\"name\":\"Deny\",\"kind\":\"reject_always\"}]}";
    const request = try decodePermissionRequest(.stable, source, &options, &scratch);
    try testing.expect(request == .stable);
    try testing.expectEqualStrings("s1", request.stable.session_id);
    // The tool call is carried verbatim, because this module does not model it.
    try testing.expectEqualStrings(
        "{\"toolCallId\":\"t1\",\"title\":\"Build\"}",
        request.stable.tool_call,
    );
    try testing.expectEqual(@as(usize, 2), request.stable.options.len);
    try testing.expectEqualStrings("a", request.stable.options[0].option_id);
    try testing.expectEqual(PermissionOptionKind.allow_once, request.stable.options[0].kind.known);
    try testing.expectEqual(@as(?bool, true), request.stable.options[0].grants());
    try testing.expectEqualStrings("Deny", request.stable.options[1].name);
    try testing.expectEqual(
        PermissionOptionKind.reject_always,
        request.stable.options[1].kind.known,
    );
    try testing.expectEqual(@as(?bool, false), request.stable.options[1].grants());
}

test "a v1 permission request needs its three required members" {
    var scratch: [256]u8 = undefined;
    var options: [1]PermissionOption = undefined;
    // v1 puts no `minItems` on `options`, so an empty array is well formed.
    const none_offered = try decodePermissionRequest(.stable,
        \\{"sessionId":"s1","toolCall":{},"options":[]}
    , &options, &scratch);
    try testing.expectEqual(@as(usize, 0), none_offered.stable.options.len);

    // A request with no tool call is not a permission prompt for one.
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{"sessionId":"s1","options":[]}
    , &options, &scratch));
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{"toolCall":{},"options":[]}
    , &options, &scratch));
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{"sessionId":"s1","toolCall":{}}
    , &options, &scratch));
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{}
    , &options, &scratch));
    // A `null` tool call is a missing tool call wearing a key.
    try testing.expectError(error.InvalidField, decodePermissionRequest(.stable,
        \\{"sessionId":"s1","toolCall":null,"options":[]}
    , &options, &scratch));
    // A tool call that is not an object is not a tool call.
    try testing.expectError(error.InvalidField, decodePermissionRequest(.stable,
        \\{"sessionId":"s1","toolCall":"t1","options":[]}
    , &options, &scratch));
}

test "a permission request with a second document behind it is refused" {
    var scratch: [256]u8 = undefined;
    var options: [1]PermissionOption = undefined;
    // v1 takes its tool call as a lexeme and v2 its subject, so both arms
    // borrow bytes out of the document the tail sits behind.
    try testing.expectError(error.MalformedJson, decodePermissionRequest(.stable,
        \\{"sessionId":"s1","toolCall":{},"options":[]} trailing
    , &options, &scratch));
    const draft = "{\"sessionId\":\"s1\",\"title\":\"t\",\"options\":[" ++
        "{\"optionId\":\"a\",\"name\":\"A\",\"kind\":\"allow_once\"}]} trailing";
    try testing.expectError(error.MalformedJson, decodePermissionRequest(
        .draft,
        draft,
        &options,
        &scratch,
    ));
}

test "an option needs its optionId, its name and its kind" {
    var scratch: [256]u8 = undefined;
    var options: [1]PermissionOption = undefined;
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{"sessionId":"s","toolCall":{},"options":[{"name":"A","kind":"allow_once"}]}
    , &options, &scratch));
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{"sessionId":"s","toolCall":{},"options":[{"optionId":"a","kind":"allow_once"}]}
    , &options, &scratch));
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{"sessionId":"s","toolCall":{},"options":[{"optionId":"a","name":"A"}]}
    , &options, &scratch));
    try testing.expectError(error.MissingField, decodePermissionRequest(.stable,
        \\{"sessionId":"s","toolCall":{},"options":[{}]}
    , &options, &scratch));
}

test "more options than the caller reserved is BufferTooSmall" {
    var scratch: [256]u8 = undefined;
    var one: [1]PermissionOption = undefined;
    const source = "{\"sessionId\":\"s\",\"toolCall\":{}," ++
        "\"options\":[{\"optionId\":\"a\",\"name\":\"A\",\"kind\":\"allow_once\"}," ++
        "{\"optionId\":\"b\",\"name\":\"B\",\"kind\":\"reject_once\"}]}";
    // A truncated choice list would hide the option the user wanted.
    try testing.expectError(
        error.BufferTooSmall,
        decodePermissionRequest(.stable, source, &one, &scratch),
    );
}

test "a v2 permission request requires a title and one option at least" {
    var scratch: [512]u8 = undefined;
    var options: [2]PermissionOption = undefined;
    const source = "{\"sessionId\":\"s1\",\"title\":\"Run rm -rf\",\"description\":null," ++
        "\"subject\":{\"type\":\"command\",\"command\":\"rm -rf build\"," ++
        "\"cwd\":\"/srv/work\"},\"options\":[{\"optionId\":\"a\",\"name\":\"Run\"," ++
        "\"kind\":\"allow_once\"}]}";
    const request = try decodePermissionRequest(.draft, source, &options, &scratch);
    try testing.expect(request == .draft);
    try testing.expectEqualStrings("s1", request.draft.session_id);
    try testing.expectEqualStrings("Run rm -rf", request.draft.title);
    // An explicit `null` description is the absent case.
    try testing.expectEqual(@as(?[]const u8, null), request.draft.description);
    try testing.expect(request.draft.subject.? == .command);
    try testing.expectEqualStrings("rm -rf build", request.draft.subject.?.command.command);
    try testing.expectEqualStrings("/srv/work", request.draft.subject.?.command.cwd);
    try testing.expectEqual(@as(usize, 1), request.draft.options.len);

    // v2 names `minItems: 1`, so a request the user cannot answer is not one.
    try testing.expectError(error.InvalidField, decodePermissionRequest(.draft,
        \\{"sessionId":"s1","title":"t","options":[]}
    , &options, &scratch));
    // The v1 shape is not a v2 request: `title` is required, and the tool call
    // moved into the subject.
    try testing.expectError(error.MissingField, decodePermissionRequest(.draft,
        \\{"sessionId":"s1","toolCall":{},"options":[{"optionId":"a","name":"A","kind":"allow_once"}]}
    , &options, &scratch));
    // The v2 command subject still has to name an absolute working directory.
    const relative = "{\"sessionId\":\"s1\",\"title\":\"t\"," ++
        "\"subject\":{\"type\":\"command\",\"command\":\"ls\",\"cwd\":\"build\"}," ++
        "\"options\":[{\"optionId\":\"a\",\"name\":\"A\",\"kind\":\"allow_once\"}]}";
    try testing.expectError(
        error.InvalidField,
        decodePermissionRequest(.draft, relative, &options, &scratch),
    );
}

test "an absent subject and an explicit null subject agree" {
    var scratch: [512]u8 = undefined;
    var options: [1]PermissionOption = undefined;
    const omitted = try decodePermissionRequest(.draft,
        \\{"sessionId":"s1","title":"t","options":[{"optionId":"a","name":"A","kind":"reject_once"}]}
    , &options, &scratch);
    try testing.expect(omitted.draft.subject == null);

    const nulled = try decodePermissionRequest(.draft,
        \\{"sessionId":"s1","title":"t","subject":null,"options":[{"optionId":"a","name":"A","kind":"reject_once"}]}
    , &options, &scratch);
    try testing.expect(nulled.draft.subject == null);
}

test "the subject's strings do not land on the request's" {
    var scratch: [512]u8 = undefined;
    var options: [1]PermissionOption = undefined;
    // Every string here needs an escape, so every one of them comes from the
    // scratch buffer rather than from the input. The subject is decoded last
    // and borrows the unread tail, so the nested decode cannot overwrite the
    // session id, the title or the options.
    const source = "{\"sessionId\":\"s\\u00e9\",\"title\":\"t\\u00e9\"," ++
        "\"subject\":{\"type\":\"command\",\"command\":\"ls \\u00e9\"," ++
        "\"cwd\":\"/w\"},\"options\":[{\"optionId\":\"a\",\"name\":\"A\"," ++
        "\"kind\":\"reject_once\"}]}";
    const request = try decodePermissionRequest(.draft, source, &options, &scratch);
    // A `\uXXXX` escape on the wire decodes to the character; the expectation
    // spells that character directly, because a Zig string literal's own `\u`
    // is written literally rather than expanded.
    try testing.expectEqualStrings("sé", request.draft.session_id);
    try testing.expectEqualStrings("té", request.draft.title);
    try testing.expectEqualStrings("ls é", request.draft.subject.?.command.command);
    try testing.expectEqualStrings("/w", request.draft.subject.?.command.cwd);
}

test "an unknown option kind is reported at v1 and carried at v2" {
    var scratch: [256]u8 = undefined;
    var options: [1]PermissionOption = undefined;
    // v1 declares a closed `oneOf`, so the string is undefined by the schema.
    try testing.expectError(error.UnknownTag, decodePermissionRequest(.stable,
        \\{"sessionId":"s","toolCall":{},"options":[{"optionId":"a","name":"A","kind":"allow_maybe"}]}
    , &options, &scratch));
    // v2 declares the catch-all branch, so the same string is a value.
    const request = try decodePermissionRequest(.draft,
        \\{"sessionId":"s","title":"t","options":[{"optionId":"a","name":"A","kind":"allow_maybe"}]}
    , &options, &scratch);
    const option = request.draft.options[0];
    try testing.expect(option.kind == .other);
    try testing.expectEqualStrings("allow_maybe", option.kind.other);
    // A kind the library cannot name grants nothing it can answer for.
    try testing.expectEqual(@as(?bool, null), option.grants());
}

test "v1 refuses a tag that v2 carries in its catch-all" {
    try testing.expectEqual(UnknownTagPolicy.reject, unknownTagPolicy(.stable));
    try testing.expectEqual(UnknownTagPolicy.catch_all, unknownTagPolicy(.draft));

    // The session update union is closed at v1 and open at v2.
    try testing.expect(classifySessionUpdate(.stable, "usage_update") == .named);
    try testing.expect(classifySessionUpdate(.stable, "agent_reasoning_chunk") == .undefined_tag);
    try testing.expect(classifySessionUpdate(.draft, "agent_reasoning_chunk") == .other);
    // `current_mode_update` went the other way, and the schema gives a removed
    // value no home but the catch-all.
    try testing.expect(classifySessionUpdate(.stable, "current_mode_update") == .named);
    try testing.expect(classifySessionUpdate(.draft, "current_mode_update") == .other);

    // The stop reason is the same five strings in both unions, and v2 is the
    // one that accepts a sixth.
    try testing.expect(classifyStopReason(.draft, "refusal") == .named);
    try testing.expect(classifyStopReason(.stable, "future_reason") == .undefined_tag);
    try testing.expect(classifyStopReason(.draft, "future_reason") == .other);

    try testing.expect(classifySessionConfigOptionType(.draft, "select") == .named);
    try testing.expect(classifySessionConfigOptionType(.stable, "slider") == .undefined_tag);
    try testing.expect(classifySessionConfigOptionType(.draft, "slider") == .other);

    try testing.expect(classifyElicitationMode(.draft, "url") == .named);
    try testing.expect(classifyElicitationMode(.stable, "markdown") == .undefined_tag);
    try testing.expect(classifyElicitationMode(.draft, "markdown") == .other);

    // v1 has no `state_update`, so no state value is defined there.
    try testing.expect(classifyStateUpdate(.draft, "idle") == .named);
    try testing.expect(classifyStateUpdate(.stable, "idle") == .undefined_tag);
    try testing.expect(classifyStateUpdate(.draft, "stalled") == .other);

    // The `_` prefix is reserved for implementation-specific extensions.
    try testing.expect(isImplementationExtension("_acp_dev"));
    try testing.expect(!isImplementationExtension("usage_update"));
    try testing.expect(!isImplementationExtension(""));
}

test "the v2 session config categories are the four the schema names" {
    try testing.expectEqual(@as(usize, 4), v2_session_config_categories.len);
    try testing.expectEqualStrings("mode", session_config_option_category.mode);
    try testing.expectEqualStrings("model", session_config_option_category.model);
    try testing.expectEqualStrings("model_config", session_config_option_category.model_config);
    try testing.expectEqualStrings("thought_level", session_config_option_category.thought_level);

    for (v2_session_config_categories) |category| {
        switch (classifyTag(.draft, &v2_session_config_categories, category)) {
            .named => {},
            else => return error.TestUnexpectedResult,
        }
        // `mode` is the category that replaced `session/set_mode` and
        // `current_mode_update`, and it is the only one of the four that is.
        const is_mode: bool = std.mem.eql(u8, category, session_config_option_category.mode);
        try testing.expectEqual(is_mode, isSessionModeCategory(category));
    }
    // A category a later draft adds is the catch-all, not an error.
    try testing.expect(classifyTag(.draft, &v2_session_config_categories, "mood") == .other);
}

test "replayFrom is start or the schema's catch-all" {
    var scratch: [64]u8 = undefined;
    const start = try decodeReplayFrom(
        \\{"type":"start"}
    , &scratch);
    try testing.expect(start == .start);

    const future = try decodeReplayFrom(
        \\{"type":"checkpoint","cursor":42}
    , &scratch);
    try testing.expect(future == .other);
    try testing.expectEqualStrings("checkpoint", future.other);

    // `_meta` is the only member `ReplayFromStart` carries, and it is optional.
    const with_meta = try decodeReplayFrom(
        \\{"_meta":{"trace":1},"type":"start"}
    , &scratch);
    try testing.expect(with_meta == .start);

    // The discriminator is required, so an object without one is not a
    // `ReplayFrom` at all.
    try testing.expectError(error.MissingField, decodeReplayFrom(
        \\{}
    , &scratch));
    try testing.expectError(error.MissingField, decodeReplayFrom(
        \\{"cursor":42}
    , &scratch));
}

test "a second document behind a replayFrom is refused" {
    var scratch: [64]u8 = undefined;
    // A JSON document is one value. Nothing here encodes a replay point, so
    // there is no second chance to put the bytes back, and the caller would
    // be handed a replay position the peer did not send.
    try testing.expectError(error.MalformedJson, decodeReplayFrom(
        \\{"type":"start"} trailing
    , &scratch));
    // The catch-all arm reads the same document the same way.
    try testing.expectError(error.MalformedJson, decodeReplayFrom(
        \\{"type":"checkpoint","cursor":42} trailing
    , &scratch));
}

test "a paths buffer sized to the recorded paths is enough" {
    // `need` is exactly the sum of the path lengths the entries borrow, plus
    // the `capabilities` root at v2, which is written ahead of the first
    // member and forms the head of that member's region. A member that records
    // nothing is not a capability — an explicit `null` is the absent case for a
    // nested object, and a string, a number or an array is a form neither
    // schema declares — so it must cost the caller nothing: a buffer that does
    // not stretch reports `BufferTooSmall` for bytes no entry borrows.
    const cases = [_]struct {
        version: WireVersion,
        side: Side,
        source: []const u8,
        need: usize,
        entries: usize,
    }{
        // One boolean, one path of eight bytes.
        .{ .version = .stable, .side = .client, .source = "{\"terminal\":true}", .need = 8, .entries = 1 },
        // An explicit `null` records nothing, so it needs no bytes at all.
        .{ .version = .stable, .side = .client, .source = "{\"fs\":null}", .need = 0, .entries = 0 },
        // A value neither schema declares is stepped over, and costs nothing.
        .{ .version = .stable, .side = .client, .source = "{\"vendor\":[\"a\"]}", .need = 0, .entries = 0 },
        // A member that records nothing must not eat into the one after it.
        .{
            .version = .stable,
            .side = .client,
            .source = "{\"fs\":null,\"terminal\":true}",
            .need = 8,
            .entries = 1,
        },
        // A presence object records itself and then its own members: `fs` and
        // `fs.readTextFile`.
        .{
            .version = .stable,
            .side = .client,
            .source = "{\"fs\":{\"readTextFile\":true}}",
            .need = 2 + 16,
            .entries = 2,
        },
        // v2 keeps the `capabilities` root in the head of every path, and the
        // caller has to have paid for that root before the first member.
        .{
            .version = .draft,
            .side = .agent,
            .source = "{\"session\":{\"delete\":{}}}",
            .need = 12 + 20 + 27,
            .entries = 2,
        },
    };
    inline for (cases) |each| {
        var paths: [each.need]u8 = undefined;
        var out: [4]Capability = undefined;
        var scratch: [128]u8 = undefined;
        const set = try decodeCapabilityObject(
            each.version,
            each.side,
            each.source,
            &out,
            &paths,
            &scratch,
        );
        try testing.expect(set.present);
        try testing.expectEqual(each.entries, set.entries.len);
        // Every entry still borrows a region of its own, so a caller can hold
        // them all at once and read each path after the decode has returned.
        for (set.entries) |entry| {
            const start = @intFromPtr(entry.path.ptr) - @intFromPtr(paths[0..].ptr);
            try testing.expect(start + entry.path.len <= each.need);
            try testing.expectEqualStrings(entry.path, paths[start..][0..entry.path.len]);
        }
    }

    // One byte short of the bound is one byte short, and nothing a caller
    // already holds is the reason.
    var paths: [7]u8 = undefined;
    var out: [4]Capability = undefined;
    var scratch: [128]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, decodeCapabilityObject(
        .stable,
        .client,
        "{\"terminal\":true}",
        &out,
        &paths,
        &scratch,
    ));
}

test "a v1 client capability object decodes to known and unknown members" {
    var scratch: [512]u8 = undefined;
    var paths: [256]u8 = undefined;
    var out: [12]Capability = undefined;
    const source = "{\"fs\":{\"readTextFile\":true,\"writeTextFile\":false}," ++
        "\"terminal\":true,\"auth\":{\"terminal\":true}," ++
        "\"elicitation\":{\"form\":{},\"url\":null},\"vendor\":{\"custom\":{}}}";
    const set = try decodeCapabilityObject(.stable, .client, source, &out, &paths, &scratch);
    try testing.expect(set.present);

    const read = findCapability(set, "fs.readTextFile").?;
    try testing.expect(read.known);
    try testing.expectEqual(CapabilityForm.boolean, read.form);
    try testing.expectEqual(@as(?bool, true), read.value);
    try testing.expect(read.advertised());

    const write = findCapability(set, "fs.writeTextFile").?;
    try testing.expect(write.known);
    try testing.expectEqual(@as(?bool, false), write.value);
    // A `false` boolean is the v1 spelling of "unsupported": the member is on
    // the wire and it still advertises nothing.
    try testing.expect(!write.advertised());

    const mode = findCapability(set, "elicitation.form").?;
    try testing.expect(mode.known);
    try testing.expectEqual(CapabilityForm.presence_object, mode.form);
    try testing.expectEqual(@as(?bool, null), mode.value);
    try testing.expect(mode.advertised());

    // An explicit `null` is the absent case, so it is not a member at all.
    try testing.expect(findCapability(set, "elicitation.url") == null);

    // v1 has no closed capability set, so an extension is carried with the
    // known flag off rather than refused.
    const vendor = findCapability(set, "vendor.custom").?;
    try testing.expect(!vendor.known);
    try testing.expect(vendor.advertised());
}

test "a capability sent in a form its version does not declare is refused" {
    var scratch: [512]u8 = undefined;
    var paths: [256]u8 = undefined;
    var out: [12]Capability = undefined;
    // `terminal` is a boolean at v1.
    try testing.expectError(error.InvalidField, decodeCapabilityObject(.stable, .client,
        \\{"terminal":{}}
    , &out, &paths, &scratch));
    // `elicitation.form` is a `{}` presence object at v1.
    try testing.expectError(error.InvalidField, decodeCapabilityObject(.stable, .client,
        \\{"elicitation":{"form":true}}
    , &out, &paths, &scratch));
    // v2 replaced every boolean with a presence object, so a boolean there is a
    // shape the draft does not define, on a known path or an unknown one.
    try testing.expectError(error.InvalidField, decodeCapabilityObject(.draft, .agent,
        \\{"session":{"delete":true}}
    , &out, &paths, &scratch));
    try testing.expectError(error.InvalidField, decodeCapabilityObject(.draft, .client,
        \\{"vendor":{"flag":false}}
    , &out, &paths, &scratch));
}

test "a second document behind a capability object is refused" {
    var scratch: [512]u8 = undefined;
    var paths: [256]u8 = undefined;
    var out: [12]Capability = undefined;
    // No encoder writes a capability set back, so nothing downstream would
    // ever see the bytes go missing: the set would name the walked members
    // and read as though the peer had advertised those alone.
    try testing.expectError(error.MalformedJson, decodeCapabilityObject(.stable, .client,
        \\{"terminal":true} trailing
    , &out, &paths, &scratch));
    // An empty object leaves the walk before it runs, and it refuses the same
    // tail rather than returning ahead of the check.
    try testing.expectError(error.MalformedJson, decodeCapabilityObject(.stable, .client,
        \\{} trailing
    , &out, &paths, &scratch));
}

test "a v2 capability object is spelled from the capabilities root" {
    var scratch: [512]u8 = undefined;
    // Every recorded path owns its own region of this buffer, so it has to
    // hold all of them, not the longest one.
    var paths: [512]u8 = undefined;
    var out: [12]Capability = undefined;
    const source = "{\"session\":{\"prompt\":{\"image\":{},\"audio\":{}}," ++
        "\"mcp\":{\"http\":{},\"stdio\":{}},\"delete\":{}," ++
        "\"additionalDirectories\":{}},\"auth\":{}}";
    const set = try decodeCapabilityObject(.draft, .agent, source, &out, &paths, &scratch);

    const image = findCapability(set, "capabilities.session.prompt.image").?;
    try testing.expect(image.known);
    try testing.expectEqual(CapabilityForm.presence_object, image.form);
    try testing.expect(image.advertised());
    try testing.expect(findCapability(set, "capabilities.session.mcp.http").?.known);
    try testing.expect(findCapability(set, "capabilities.session.mcp.stdio").?.known);
    try testing.expect(findCapability(set, "capabilities.session.delete").?.known);
    try testing.expect(findCapability(set, "capabilities.session.additionalDirectories").?.known);
    // `auth` is an object marker with no members of its own on the agent side.
    try testing.expect(findCapability(set, "capabilities.auth") != null);

    // The gates v2 promoted to baseline are not capabilities, so a peer that
    // still advertises them reads as an extension rather than a new gate.
    try testing.expect(!isKnownV2Capability(.agent, "capabilities.session.resume"));
    try testing.expect(!isKnownV2Capability(.agent, "capabilities.session.close"));
    try testing.expect(!isKnownV2Capability(.agent, "capabilities.session.list"));
    // One `capabilities` member does not make the two sides share a gate list.
    try testing.expect(!isKnownV2Capability(.client, "capabilities.session.delete"));
    try testing.expect(isKnownV2Capability(.client, "capabilities.elicitation.form"));
    // Neither schema gives a capability object to a side-independent method.
    try testing.expectError(error.InvalidField, decodeCapabilityObject(.draft, .protocol,
        \\{}
    , &out, &paths, &scratch));
}

test "a decoded v1 agent set answers isMethodSupported" {
    var scratch: [512]u8 = undefined;
    var paths: [192]u8 = undefined;
    var out: [10]Capability = undefined;
    const source = "{\"loadSession\":true,\"promptCapabilities\":{\"image\":true}," ++
        "\"mcpCapabilities\":{\"http\":false}," ++
        "\"sessionCapabilities\":{\"delete\":{},\"list\":{}}}";
    const set = try decodeCapabilityObject(.stable, .agent, source, &out, &paths, &scratch);
    // The schema nests the session gates under `sessionCapabilities` and
    // PROTOCOLS.md section 6.5 spells them `session.*`, so the decoded path uses
    // the abbreviated spelling and the two are never both present.
    try testing.expect(findCapability(set, "session.delete").?.known);
    try testing.expect(findCapability(set, "session.list").?.known);
    try testing.expect(findCapability(set, "sessionCapabilities.delete") == null);
    // A `false` boolean is still a known capability: the library knows the gate
    // and knows the peer advertised it as unsupported.
    const http = findCapability(set, "mcpCapabilities.http").?;
    try testing.expect(http.known);
    try testing.expect(!http.advertised());

    var advertised: [10][]const u8 = undefined;
    const list = try advertisedPaths(set, &advertised);
    try testing.expect(isMethodSupported(try lookupMethod(.stable, "session/delete"), list));
    try testing.expect(isMethodSupported(try lookupMethod(.stable, "session/list"), list));
    try testing.expect(isMethodSupported(try lookupMethod(.stable, "session/load"), list));
    // `mcpCapabilities.http` is false, so it is not in the advertised list,
    // and `session/close` was never sent.
    try testing.expect(!contains(list, "mcpCapabilities.http"));
    try testing.expect(!isMethodSupported(try lookupMethod(.stable, "session/close"), list));
}

test "a decoded v2 client set answers isMethodSupported" {
    var scratch: [512]u8 = undefined;
    var paths: [128]u8 = undefined;
    var out: [8]Capability = undefined;
    const modes = try decodeCapabilityObject(.draft, .client,
        \\{"elicitation":{"form":{},"url":{}}}
    , &out, &paths, &scratch);
    var advertised: [8][]const u8 = undefined;
    const list = try advertisedPaths(modes, &advertised);
    const create = try lookupMethod(.draft, "elicitation/create");
    try testing.expect(isMethodSupported(create, list));
    // A short buffer is reported rather than truncated, because a truncated
    // list reads as a peer that advertised less than it did.
    var one: [1][]const u8 = undefined;
    try testing.expectError(error.BufferTooSmall, advertisedPaths(modes, &one));

    // A client that advertises only terminal authentication does not support
    // form mode. Its own buffers, because the first set's paths borrow theirs.
    var other_scratch: [512]u8 = undefined;
    var other_paths: [128]u8 = undefined;
    var other_out: [8]Capability = undefined;
    const terminal_only = try decodeCapabilityObject(.draft, .client,
        \\{"auth":{"terminal":{}}}
    , &other_out, &other_paths, &other_scratch);
    var other_advertised: [8][]const u8 = undefined;
    const other = try advertisedPaths(terminal_only, &other_advertised);
    try testing.expect(!isMethodSupported(create, other));
}

test "the initialize capability member is optional in every version" {
    var scratch: [512]u8 = undefined;
    var paths: [128]u8 = undefined;
    var out: [8]Capability = undefined;
    // v1 spells the member `clientCapabilities`; v2 spells it `capabilities`
    // for both sides.
    const v1 = try decodeInitializeCapabilities(.stable, .client,
        \\{"protocolVersion":1,"clientInfo":{"name":"c","version":"1"},"clientCapabilities":{"terminal":true}}
    , &out, &paths, &scratch);
    try testing.expect(v1.present);
    try testing.expect(findCapability(v1, "terminal").?.advertised());

    var v2_paths: [128]u8 = undefined;
    var v2_out: [8]Capability = undefined;
    const v2 = try decodeInitializeCapabilities(.draft, .agent,
        \\{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"delete":{}}}}
    , &v2_out, &v2_paths, &scratch);
    try testing.expect(v2.present);
    try testing.expect(findCapability(v2, "capabilities.session.delete").?.known);

    var empty_paths: [128]u8 = undefined;
    var empty_out: [8]Capability = undefined;
    const absent = try decodeInitializeCapabilities(.stable, .agent,
        \\{"protocolVersion":1}
    , &empty_out, &empty_paths, &scratch);
    // Omission means unsupported, so an initialize that advertises nothing is
    // not an error and advertises nothing.
    try testing.expect(!absent.present);
    try testing.expectEqual(@as(usize, 0), absent.entries.len);

    try testing.expectError(error.InvalidField, decodeInitializeCapabilities(.stable, .protocol,
        \\{}
    , &empty_out, &empty_paths, &scratch));
}

test "a second document behind an initialize body is refused" {
    var scratch: [512]u8 = undefined;
    var paths: [128]u8 = undefined;
    var out: [8]Capability = undefined;
    // The capability member is read and the loop breaks rather than returning
    // from inside it, so the refusal does not depend on the member being
    // there: a body that carries it and a body that does not refuse the same
    // tail.
    try testing.expectError(error.MalformedJson, decodeInitializeCapabilities(.stable, .client,
        \\{"protocolVersion":1,"clientCapabilities":{"terminal":true}} trailing
    , &out, &paths, &scratch));
    try testing.expectError(error.MalformedJson, decodeInitializeCapabilities(.stable, .client,
        \\{"protocolVersion":1} trailing
    , &out, &paths, &scratch));
}

test "every gated v2 method names a capability its own side declares" {
    for (v2_agent_methods) |info| {
        if (info.gate.len == 0) continue;
        try testing.expect(isKnownV2Capability(.agent, info.gate));
        try testing.expectEqualStrings("", info.gate2);
    }
    for (v2_client_methods) |info| {
        if (info.gate.len == 0) continue;
        try testing.expect(isKnownV2Capability(.client, info.gate));
        if (info.gate2.len == 0) continue;
        try testing.expect(isKnownV2Capability(.client, info.gate2));
    }
    // The binding's own key is listed at both versions, so one RFD path
    // classifies at both.
    try testing.expect(isKnownV1AgentCapability("mcpCapabilities.acp"));
    try testing.expect(isKnownV2Capability(.agent, "capabilities.session.mcp.acp"));
}

test "trailing whitespace is not a second document" {
    // `json.Reader.atEnd` skips the four bytes JSON calls whitespace before it
    // answers, so a document with a space, a tab, a carriage return or a
    // newline behind it still decodes. What the six decoders above refuse is a
    // second value, and a frame delimiter is not one: the stdio framing of
    // section 6.2 hands a frame its bytes with the delimiter already stripped.
    var scratch: [512]u8 = undefined;
    var paths: [256]u8 = undefined;
    var out: [12]Capability = undefined;
    var options: [1]PermissionOption = undefined;
    var buffer: [128]u8 = undefined;

    for ([_][]const u8{ "", " ", "\t", "\r", "\n", " \t\r\n" }) |tail| {
        const replay = try std.fmt.bufPrint(&buffer, "{{\"type\":\"start\"}}{s}", .{tail});
        try testing.expect((try decodeReplayFrom(replay, &scratch)) == .start);

        const outcome = try std.fmt.bufPrint(&buffer, "{{\"outcome\":\"cancelled\"}}{s}", .{tail});
        try testing.expect((try decodePermissionOutcome(outcome, &scratch)) == .cancelled);

        const subject = try std.fmt.bufPrint(
            &buffer,
            "{{\"type\":\"tool_call\",\"toolCall\":{{\"toolCallId\":\"t1\"}}}}{s}",
            .{tail},
        );
        try testing.expect((try decodePermissionSubject(subject, &scratch)) == .tool_call);

        const request = try std.fmt.bufPrint(
            &buffer,
            "{{\"sessionId\":\"s1\",\"toolCall\":{{}},\"options\":[]}}{s}",
            .{tail},
        );
        const decoded = try decodePermissionRequest(.stable, request, &options, &scratch);
        try testing.expect(decoded == .stable);

        const object = try std.fmt.bufPrint(&buffer, "{{\"terminal\":true}}{s}", .{tail});
        const walked = try decodeCapabilityObject(.stable, .client, object, &out, &paths, &scratch);
        try testing.expect(walked.present);

        const initialize = try std.fmt.bufPrint(
            &buffer,
            "{{\"protocolVersion\":1,\"clientCapabilities\":{{\"terminal\":true}}}}{s}",
            .{tail},
        );
        const advertised = try decodeInitializeCapabilities(
            .stable,
            .client,
            initialize,
            &out,
            &paths,
            &scratch,
        );
        try testing.expect(advertised.present);
    }
}

test "a replay point round-trips through the encoder" {
    var scratch: [64]u8 = undefined;
    var buffer: [64]u8 = undefined;
    // The discriminator is the only member this shape models, so a document
    // carrying only that is one the pair reproduces byte for byte.
    const source = "{\"type\":\"start\"}";
    var writer = json.Writer.init(&buffer);
    try encodeReplayFrom(try decodeReplayFrom(source, &scratch), &writer);
    try testing.expectEqualStrings(source, writer.written());

    // The catch-all keeps the tag it arrived with, which is the member this
    // library is able to write back. The `cursor` beside it belongs to the
    // peer and has no arm to land in, so the re-encoded document is the tag.
    const future = "{\"type\":\"checkpoint\"}";
    var other = json.Writer.init(&buffer);
    try encodeReplayFrom(
        try decodeReplayFrom(
            \\{"type":"checkpoint","cursor":42}
        , &scratch),
        &other,
    );
    try testing.expectEqualStrings(future, other.written());
    // And the shorter document decodes as the same arm, so the round trip is
    // a round trip rather than a shorter string that happens to parse.
    try testing.expect((try decodeReplayFrom(other.written(), &scratch)) == .other);
}

test "a replay point the decoder could not return is refused" {
    var buffer: [64]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    // `decodeReplayFrom` gives the one named tag the `.start` arm, so the
    // catch-all holding that text re-encodes as a document decoding as the
    // other arm, and the bytes look fine while saying the opposite.
    try testing.expectError(
        error.InvalidField,
        encodeReplayFrom(.{ .other = replay_from_type.start }, &writer),
    );
    // Nothing was written, so a caller sizing a buffer for the refusal is not
    // holding the prefix of a document.
    try testing.expectEqual(@as(usize, 0), writer.written().len);

    // Any other tag is the arm the wire spells, and it is written.
    var other = json.Writer.init(&buffer);
    try encodeReplayFrom(.{ .other = "checkpoint" }, &other);
    try testing.expectEqualStrings("{\"type\":\"checkpoint\"}", other.written());
}

test "a capability object round-trips through the encoder" {
    var scratch: [512]u8 = undefined;
    var paths: [256]u8 = undefined;
    var out: [12]Capability = undefined;
    var buffer: [512]u8 = undefined;
    // Every member here is one the walk records, and the document carries no
    // whitespace, so the re-encoded bytes are the source less the members
    // that record nothing: an explicit `null` is the absent case, and a value
    // no schema declares is stepped over.
    const source = "{\"fs\":{\"readTextFile\":true,\"writeTextFile\":false}," ++
        "\"terminal\":true,\"auth\":{\"terminal\":true}," ++
        "\"elicitation\":{\"form\":{},\"url\":null},\"vendor\":{\"custom\":{}}}";
    const set = try decodeCapabilityObject(.stable, .client, source, &out, &paths, &scratch);
    var writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .client, set, &writer);
    try testing.expectEqualStrings(
        "{\"fs\":{\"readTextFile\":true,\"writeTextFile\":false}," ++
            "\"terminal\":true,\"auth\":{\"terminal\":true}," ++
            "\"elicitation\":{\"form\":{}},\"vendor\":{\"custom\":{}}}",
        writer.written(),
    );

    // The set the re-encoded bytes decode to is the set they came from, which
    // is the half of the round trip a byte comparison cannot see.
    var again_paths: [256]u8 = undefined;
    var again_out: [12]Capability = undefined;
    const again = try decodeCapabilityObject(
        .stable,
        .client,
        writer.written(),
        &again_out,
        &again_paths,
        &scratch,
    );
    try testing.expectEqual(set.entries.len, again.entries.len);
    for (set.entries, again.entries) |first, second| {
        try testing.expectEqualStrings(first.path, second.path);
        try testing.expectEqual(first.known, second.known);
        try testing.expectEqual(first.form, second.form);
        try testing.expectEqual(first.value, second.value);
    }
}

test "a v2 capability object round-trips under the capabilities root" {
    var scratch: [512]u8 = undefined;
    var paths: [512]u8 = undefined;
    var out: [12]Capability = undefined;
    var buffer: [512]u8 = undefined;
    // A v2 path keeps the `capabilities` root that is the member's own name,
    // and this writes the contents of that member, so the root comes off the
    // head of every top-level key. Left on, the document would nest a member
    // named `capabilities` inside the one already called `capabilities`.
    const source = "{\"session\":{\"prompt\":{\"image\":{}},\"mcp\":{\"http\":{}}}," ++
        "\"auth\":{}}";
    const set = try decodeCapabilityObject(.draft, .agent, source, &out, &paths, &scratch);
    var writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.draft, .agent, set, &writer);
    try testing.expectEqualStrings(source, writer.written());
}

test "the v1 session gates re-encode under the object the schema nests them in" {
    var scratch: [512]u8 = undefined;
    var paths: [192]u8 = undefined;
    var out: [10]Capability = undefined;
    var buffer: [512]u8 = undefined;
    // The decoded paths spell these gates `session.*` while the member on the
    // wire is `sessionCapabilities`, and `childPath` is where a decode crosses
    // that. Writing the children at the root instead re-encodes as
    // `{"sessionCapabilities":{},"session":{...}}`, which decodes as a set
    // with one entry more than it had: a `session` capability this peer
    // never advertised and no side of this library names.
    const source = "{\"sessionCapabilities\":{\"delete\":{},\"list\":{}}}";
    const set = try decodeCapabilityObject(.stable, .agent, source, &out, &paths, &scratch);
    try testing.expect(findCapability(set, "session.delete") != null);

    var writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .agent, set, &writer);
    try testing.expectEqualStrings(source, writer.written());
}

test "a capability member the decoder would refuse is not written" {
    var buffer: [512]u8 = undefined;
    var refuser = json.Writer.init(&buffer);
    // `terminal` is a boolean at v1, and a `{}` here is the form the decoder
    // refuses for a path it names.
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.stable, .client, .{
        .entries = &.{.{
            .path = "terminal",
            .known = true,
            .form = .presence_object,
            .value = null,
        }},
        .present = true,
    }, &refuser));
    // v2 replaced every boolean with a presence object, on a known path and
    // on an unknown one.
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.draft, .agent, .{
        .entries = &.{
            .{
                .path = "capabilities.session.delete",
                .known = true,
                .form = .boolean,
                .value = true,
            },
        },
        .present = true,
    }, &refuser));
    // Neither schema gives a capability object to a side-independent method.
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.draft, .protocol, .{
        .entries = &.{},
        .present = true,
    }, &refuser));
    // A capability object is the member itself, so an absent member is not a
    // value this can spell.
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.stable, .client, .{
        .entries = &.{},
        .present = false,
    }, &refuser));
    // A boolean with no value has to be written `null`, which the walk reads
    // as the absent case and records as no member at all.
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.stable, .client, .{
        .entries = &.{.{ .path = "terminal", .known = true, .form = .boolean, .value = null }},
        .present = true,
    }, &refuser));
    // A presence object with a value has nowhere to put it: the schema gives
    // that arm no value to carry.
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.stable, .client, .{
        .entries = &.{
            .{ .path = "elicitation.form", .known = true, .form = .presence_object, .value = true },
        },
        .present = true,
    }, &refuser));
    // Nothing refused above reached the buffer, so a caller that sized it for
    // the refusal is not holding the prefix of a document.
    try testing.expectEqual(@as(usize, 0), refuser.written().len);

    // An unknown v1 path may take either form, so it is the one thing the
    // form check does not refuse. The set here is the one a walk over
    // `{"vendor":{"flag":true}}` records: the object and then its member.
    var writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .client, .{
        .entries = &.{
            .{ .path = "vendor", .known = false, .form = .presence_object, .value = null },
            .{ .path = "vendor.flag", .known = false, .form = .boolean, .value = true },
        },
        .present = true,
    }, &writer);
    try testing.expectEqualStrings("{\"vendor\":{\"flag\":true}}", writer.written());

    // A dotted path with no recorded object above it is its own key, because
    // the walk records every object it steps through and this one has none.
    // That is also the member a peer spells flat, so the pair agrees on it.
    var flat = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .client, .{
        .entries = &.{.{ .path = "vendor.flag", .known = false, .form = .boolean, .value = true }},
        .present = true,
    }, &flat);
    try testing.expectEqualStrings("{\"vendor.flag\":true}", flat.written());
    var flat_scratch: [64]u8 = undefined;
    var flat_paths: [64]u8 = undefined;
    var flat_out: [2]Capability = undefined;
    const flat_set = try decodeCapabilityObject(
        .stable,
        .client,
        flat.written(),
        &flat_out,
        &flat_paths,
        &flat_scratch,
    );
    try testing.expectEqual(@as(usize, 1), flat_set.entries.len);
    try testing.expectEqualStrings("vendor.flag", flat_set.entries[0].path);
}

test "the initialize capability member round-trips through the encoder" {
    var scratch: [512]u8 = undefined;
    var paths: [128]u8 = undefined;
    var out: [8]Capability = undefined;
    var buffer: [512]u8 = undefined;
    // v1 spells the member `clientCapabilities` and v2 spells it
    // `capabilities` for both sides, so the same set goes out under two names.
    const v1 = try decodeInitializeCapabilities(.stable, .client,
        \\{"protocolVersion":1,"clientCapabilities":{"terminal":true}}
    , &out, &paths, &scratch);
    var v1_writer = json.Writer.init(&buffer);
    try encodeInitializeCapabilities(.stable, .client, v1, &v1_writer);
    try testing.expectEqualStrings(
        "{\"clientCapabilities\":{\"terminal\":true}}",
        v1_writer.written(),
    );

    var v2_paths: [128]u8 = undefined;
    var v2_out: [8]Capability = undefined;
    const v2 = try decodeInitializeCapabilities(.draft, .agent,
        \\{"protocolVersion":2,"capabilities":{"session":{"delete":{}}}}
    , &v2_out, &v2_paths, &scratch);
    var v2_writer = json.Writer.init(&buffer);
    try encodeInitializeCapabilities(.draft, .agent, v2, &v2_writer);
    try testing.expectEqualStrings(
        "{\"capabilities\":{\"session\":{\"delete\":{}}}}",
        v2_writer.written(),
    );

    // The body written here decodes back to the set it was built from, which
    // is the half a byte comparison against a longer source cannot show.
    var again_out: [8]Capability = undefined;
    var again_paths: [128]u8 = undefined;
    const again = try decodeInitializeCapabilities(
        .draft,
        .agent,
        v2_writer.written(),
        &again_out,
        &again_paths,
        &scratch,
    );
    try testing.expectEqual(v2.entries.len, again.entries.len);
    try testing.expect(findCapability(again, "capabilities.session.delete") != null);
}

test "an initialize that advertises nothing writes no member" {
    var scratch: [512]u8 = undefined;
    var paths: [128]u8 = undefined;
    var out: [8]Capability = undefined;
    var buffer: [512]u8 = undefined;
    // Omission means unsupported, so the absent member is written as an
    // absent member. An empty one would decode as present and advertising
    // nothing, which tells a peer the question was asked and answered no.
    const set = try decodeInitializeCapabilities(.stable, .agent,
        \\{"protocolVersion":1}
    , &out, &paths, &scratch);
    try testing.expect(!set.present);
    var writer = json.Writer.init(&buffer);
    try encodeInitializeCapabilities(.stable, .agent, set, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    var again_out: [8]Capability = undefined;
    var again_paths: [128]u8 = undefined;
    const again = try decodeInitializeCapabilities(
        .stable,
        .agent,
        writer.written(),
        &again_out,
        &again_paths,
        &scratch,
    );
    try testing.expect(!again.present);

    // Neither schema gives a capability member to a side-independent method.
    var refuser = json.Writer.init(&buffer);
    try testing.expectError(
        error.InvalidField,
        encodeInitializeCapabilities(.stable, .protocol, set, &refuser),
    );
    // The form rules reach the member as well: a v2 boolean under
    // `capabilities` is the shape the draft does not define.
    const boolean_set: CapabilitySet = .{
        .entries = &.{
            .{
                .path = "capabilities.session.delete",
                .known = true,
                .form = .boolean,
                .value = true,
            },
        },
        .present = true,
    };
    try testing.expectError(
        error.InvalidField,
        encodeInitializeCapabilities(.draft, .agent, boolean_set, &refuser),
    );
    try testing.expectEqual(@as(usize, 0), refuser.written().len);
}

test "a permission subject round-trips through the encoder" {
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;
    // The tool call is carried as the lexeme it arrived as, so it is written
    // back byte for byte and is the one member here that is not re-spelled.
    const call_source = "{\"type\":\"tool_call\"," ++
        "\"toolCall\":{\"toolCallId\":\"t1\",\"title\":\"Build\"}}";
    var call_writer = json.Writer.init(&buffer);
    try encodePermissionSubject(
        try decodePermissionSubject(call_source, &scratch),
        &call_writer,
    );
    try testing.expectEqualStrings(call_source, call_writer.written());

    // Every member the command arm models is written, in the order the writer
    // puts them, and the optional ones are omitted when absent rather than
    // written `null`, which the decoder reads back as the same absent.
    const command_source = "{\"type\":\"command\",\"command\":\"rm -rf build\"," ++
        "\"cwd\":\"/srv/work\",\"toolCallId\":\"t1\",\"terminalId\":\"term-1\"}";
    var command_writer = json.Writer.init(&buffer);
    try encodePermissionSubject(
        try decodePermissionSubject(command_source, &scratch),
        &command_writer,
    );
    try testing.expectEqualStrings(command_source, command_writer.written());

    const bare = "{\"type\":\"command\",\"command\":\"ls\",\"cwd\":\"/w\"}";
    var bare_writer = json.Writer.init(&buffer);
    try encodePermissionSubject(try decodePermissionSubject(bare, &scratch), &bare_writer);
    try testing.expectEqualStrings(bare, bare_writer.written());
}

test "a permission subject the decoder would refuse is not written" {
    var buffer: [256]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    // A relative `cwd` resolves against whatever working directory the
    // process that runs the command happens to have, so the user approving a
    // command in one directory would approve it in another. PROTOCOLS.md 6.6
    // types the member `AbsolutePath` and `decodePermissionSubject` refuses
    // the same value with `error.InvalidField`, so writing it would put a
    // request on the wire that this library will not read back.
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .command = .{ .command = "rm -rf build", .cwd = "build" },
    }, &writer));
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .command = .{ .command = "ls", .cwd = "./build" },
    }, &writer));
    // An empty path is not absolute either, and it is what a caller gets from
    // a `CommandSubject` it filled in only partly.
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .command = .{ .command = "ls", .cwd = "" },
    }, &writer));

    // A `toolCall` that is not an object is a missing tool call wearing a
    // key. The second case is the one a first-byte test would miss: a lexeme
    // with a second value behind it splices a second document into the middle
    // of the member, and the third is a lexeme the reader never finished.
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .tool_call = "null",
    }, &writer));
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .tool_call = "",
    }, &writer));
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .tool_call = "{\"toolCallId\":\"t1\"} {\"toolCallId\":\"t2\"}",
    }, &writer));
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .tool_call = "{\"toolCallId\":\"t1\"",
    }, &writer));

    // The catch-all may not name a modelled arm. `type` selects the arm, so a
    // tag naming one is a request for that arm without the members it needs,
    // and it decodes as `error.MissingField`.
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .other = permission_subject_type.command,
    }, &writer));
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{
        .other = permission_subject_type.tool_call,
    }, &writer));

    // Nothing refused above reached the buffer, so a caller that sized it for
    // the refusal is not holding the prefix of a document.
    try testing.expectEqual(@as(usize, 0), writer.written().len);

    // The one command this accepts is the one the existing body writer in
    // `acp_session` also accepts, and the two write the same bytes.
    var command_writer = json.Writer.init(&buffer);
    try encodePermissionSubject(.{
        .command = .{ .command = "ls", .cwd = "/srv/work" },
    }, &command_writer);
    try testing.expectEqualStrings(
        "{\"type\":\"command\",\"command\":\"ls\",\"cwd\":\"/srv/work\"}",
        command_writer.written(),
    );
}

test "a permission request round-trips through the encoder" {
    var scratch: [512]u8 = undefined;
    var options: [2]PermissionOption = undefined;
    var buffer: [512]u8 = undefined;
    // v1 carries the tool call as a lexeme and no title, and every member
    // comes back in the order the writer puts them, which is the order the
    // decoder reads them in either.
    const v1_source = "{\"sessionId\":\"s1\",\"toolCall\":{\"toolCallId\":\"t1\"}," ++
        "\"options\":[{\"optionId\":\"a\",\"name\":\"Allow\",\"kind\":\"allow_once\"}," ++
        "{\"optionId\":\"b\",\"name\":\"Deny\",\"kind\":\"reject_always\"}]}";
    var v1_writer = json.Writer.init(&buffer);
    try encodePermissionRequest(
        try decodePermissionRequest(.stable, v1_source, &options, &scratch),
        &v1_writer,
    );
    try testing.expectEqualStrings(v1_source, v1_writer.written());

    // v2 requires a title, allows a subject, and refuses an empty choice list.
    var draft_options: [1]PermissionOption = undefined;
    const v2_source = "{\"sessionId\":\"s1\",\"title\":\"Run rm -rf\",\"description\":null," ++
        "\"subject\":{\"type\":\"command\",\"command\":\"rm -rf build\",\"cwd\":\"/srv/work\"}," ++
        "\"options\":[{\"optionId\":\"a\",\"name\":\"Run\",\"kind\":\"allow_once\"}]}";
    var v2_writer = json.Writer.init(&buffer);
    try encodePermissionRequest(
        try decodePermissionRequest(.draft, v2_source, &draft_options, &scratch),
        &v2_writer,
    );
    // An explicit `null` description is the absent case, so it is omitted
    // rather than written, and the two agree by design.
    try testing.expectEqualStrings(
        "{\"sessionId\":\"s1\",\"title\":\"Run rm -rf\"," ++
            "\"subject\":{\"type\":\"command\",\"command\":\"rm -rf build\"," ++
            "\"cwd\":\"/srv/work\"}," ++
            "\"options\":[{\"optionId\":\"a\",\"name\":\"Run\",\"kind\":\"allow_once\"}]}",
        v2_writer.written(),
    );

    // And a v2 request with no subject and no description writes neither.
    var bare_options: [1]PermissionOption = undefined;
    const bare_source = "{\"sessionId\":\"s1\",\"title\":\"t\"," ++
        "\"options\":[{\"optionId\":\"a\",\"name\":\"A\",\"kind\":\"reject_once\"}]}";
    var bare_writer = json.Writer.init(&buffer);
    try encodePermissionRequest(
        try decodePermissionRequest(.draft, bare_source, &bare_options, &scratch),
        &bare_writer,
    );
    try testing.expectEqualStrings(bare_source, bare_writer.written());
}

test "a permission request the decoder would refuse is not written" {
    var buffer: [512]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    const options = [_]PermissionOption{.{
        .option_id = "a",
        .name = "Allow",
        .kind = .{ .known = .allow_once },
    }};

    // v1 declares a closed `oneOf` on `kind`, so a fifth value is undefined by
    // the schema and `decodePermissionOptionKind` reports it rather than
    // carrying it.
    try testing.expectError(error.UnknownTag, encodePermissionRequest(.{
        .stable = .{
            .session_id = "s1",
            .tool_call = "{}",
            .options = &.{.{
                .option_id = "a",
                .name = "Allow",
                .kind = .{ .other = "allow_later" },
            }},
        },
    }, &writer));
    // v2 names `minItems: 1`, so a request the user cannot answer is not one.
    try testing.expectError(error.InvalidField, encodePermissionRequest(.{
        .draft = .{
            .session_id = "s1",
            .title = "Run",
            .description = null,
            .subject = null,
            .options = &.{},
        },
    }, &writer));
    // A tool call that is not an object is a missing tool call wearing a key.
    try testing.expectError(error.InvalidField, encodePermissionRequest(.{
        .stable = .{ .session_id = "s1", .tool_call = "null", .options = &options },
    }, &writer));
    // The subject's rules reach the request. A relative `cwd` is the refusal
    // this function and `acp_session` now share.
    try testing.expectError(error.InvalidField, encodePermissionRequest(.{
        .draft = .{
            .session_id = "s1",
            .title = "Run",
            .description = null,
            .subject = .{ .command = .{ .command = "ls", .cwd = "build" } },
            .options = &options,
        },
    }, &writer));
    // And so does a catch-all naming a modelled arm.
    try testing.expectError(error.InvalidField, encodePermissionRequest(.{
        .draft = .{
            .session_id = "s1",
            .title = "Run",
            .description = null,
            .subject = .{ .other = permission_subject_type.command },
            .options = &options,
        },
    }, &writer));

    // Nothing refused above reached the buffer, so a caller that sized it for
    // the refusal is not holding the prefix of a document that reads as one.
    try testing.expectEqual(@as(usize, 0), writer.written().len);

    // v2's catch-all makes the same fifth kind a value, and its text is
    // written as it arrived. This is the write the refused cases above sit
    // either side of, so a caller can go on using the buffer afterwards.
    var draft_writer = json.Writer.init(&buffer);
    try encodePermissionRequest(.{
        .draft = .{
            .session_id = "s1",
            .title = "Run",
            .description = null,
            .subject = null,
            .options = &.{.{
                .option_id = "a",
                .name = "Allow",
                .kind = .{ .other = "allow_later" },
            }},
        },
    }, &draft_writer);
    try testing.expectEqualStrings(
        "{\"sessionId\":\"s1\",\"title\":\"Run\"," ++
            "\"options\":[{\"optionId\":\"a\",\"name\":\"Allow\",\"kind\":\"allow_later\"}]}",
        draft_writer.written(),
    );
}

fn contains(set: []const []const u8, needle: []const u8) bool {
    for (set) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// Whether `set` holds exactly the names `expected` lists.
///
/// Both directions, so a duplicate in either list is a failure too. The
/// registries are transcribed from the specification's own tables, and a count
/// cannot check that: a renamed method and a dropped one paired with a filler
/// both leave the count standing.
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

/// The entry with this path, for the tests that assert on a decoded set.
fn findCapability(set: CapabilitySet, path: []const u8) ?Capability {
    for (set.entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}
