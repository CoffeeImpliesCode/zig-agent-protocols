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
//!
//! ## What this module does not do
//!
//! It parses and writes ACP messages and holds the two registries, the
//! capability vocabularies and the discriminator tables the rest of the tree
//! asks about. It opens no transport, owns no allocator and keeps nothing past
//! a call: `framing` and `stdio` carry bytes, `conn` frames and matches
//! them, and the whole decode/encode surface below borrows buffers the caller
//! supplies. It models no batch array, no HTTP binding and no `ToolCallUpdate`
//! or `_meta` object; each of those is carried as the borrowed lexeme it
//! arrived as, and the sections below say which members that costs. The
//! admission rules for a call — the method's version, its side, whether it
//! expects an answer, and the conditional `authMethods` rule — are not decided
//! here either; see `acp_session.checkCall`.
//!
//! ## What the encoders guarantee
//!
//! The round trip this module publishes is over modelled values and presence,
//! not over bytes. Every decoder here is total and returns a `DecodeError`; no
//! decode path in this file asserts a caller precondition, so there is no check
//! here that is present in Debug or ReleaseSafe and unchecked in ReleaseFast
//! or ReleaseSmall — a refusal is always a returned tag rather than a mode
//! dependent abort. Every encoder refuses the values its own decoder could not
//! have returned, and it decides those refusals before it writes a byte, so an
//! `error.InvalidField` or `error.UnknownTag` leaves the caller's buffer
//! untouched. What survives `decode` then `encode` is the value: the same tag,
//! the same fields, the same presence, and the same first-wins reading of a
//! repeated member, so the re-encoded document decodes back to that value.
//!
//! **Byte identity is not part of that promise.** Three things are re-spelled
//! even when a document carries nothing this module fails to model: whitespace
//! is dropped, a string is written with the escapes this library chooses rather
//! than the ones the peer spelled, and a member order is the encoder's wherever
//! the schema does not fix one. So `{"a": 1}` and `{"a":"A"}` both come back as
//! `{"a":"A"}`-style output, and a caller must not compare bytes. What the
//! tests in this file do instead is pin the *losses* — the member that records
//! nothing, the repeat that is spent, the member of the other version — and a
//! few canonical documents where the re-encode does reproduce the source
//! exactly. Each encoder names its own classes, and `writeFrame` is the one
//! entry point where bytes are reproduced verbatim, because it copies the
//! caller's bytes rather than composing a document.
//!
//! The one error that can arrive after a write is `error.BufferTooSmall`, and
//! every encoder here says what the caller's buffer holds on that path. A
//! prefix is never a document a peer can be sent, so a caller that mishandles
//! the error must not find a half-written message already in its memory.
//!
//! ## Encoded string fields are the caller's UTF-8 obligation
//!
//! Every encoder here writes its strings through `json.Writer.string`, which
//! documents that the text must already be valid UTF-8, escapes what the
//! grammar forbids, passes every other byte through unchanged, and checks
//! nothing in any optimize mode. This module does not add a check behind it:
//! there is no `std.debug.assert` on these paths, so a string that is not valid
//! UTF-8 is not refused in Debug either — it is written, and this library's own
//! reader then refuses the document with `error.InvalidUtf8` on the far side of
//! the wire. A string that arrived through a decoder is already valid, because
//! `json.Reader.string` validates it; a string a caller built by hand is not,
//! and validating it is the caller's. Every encoder that writes a caller-supplied
//! string says so on its own declaration — a replay `type`, an option id, a
//! `toolCall` lexeme, a session id, a title, a description, an option's id,
//! name and kind, a subject's tag, command, `cwd` and ids, and a capability
//! path's member names.
//!
//! Two members are written with `json.Writer.slice` rather than `string`, and
//! they carry their own obligation instead. A `toolCall` lexeme and a
//! `subject` are spliced in verbatim, so what they must be is exactly one
//! complete JSON value, and the encoders check that; the frame bytes
//! [`writeFrame`] takes are checked for UTF-8 by that function itself.

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

    /// The version this library speaks for the wire number `value`, or `null`
    /// for every other number.
    ///
    /// Total and allocation-free. `null` covers a version this library has not
    /// read and a version number that is not a wire version at all, which are
    /// the same answer for a caller: it cannot hand this number to a registry,
    /// a capability table or a discriminator table without naming a version
    /// this library does not implement. A caller that keeps a peer's
    /// `protocolVersion` rather than speaking it is what wants the `null`, and
    /// [`Negotiated.unsupported`] is the variant that carries the number on.
    pub fn fromNumber(value: u16) ?WireVersion {
        return switch (value) {
            1 => .stable,
            2 => .draft,
            else => null,
        };
    }

    /// The wire number for this version, the inverse of [`WireVersion.fromNumber`]
    /// over both tags.
    ///
    /// Total, allocation-free and comptime-known per tag, so a handshake or a
    /// dispatch key can be computed from a value with no branch.
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

/// One frame split out of a byte buffer, as [`nextFrame`] returns it.
///
/// Every field borrows the `input` that was passed, at the offsets that field
/// names: `bytes` and `rest` are two views of one buffer and never overlap,
/// and `rest` begins one byte past the delimiter that ended `bytes`. Nothing
/// here is copied and nothing is owned, so the whole value dies with `input`:
/// overwriting or releasing the buffer invalidates both slices, and a `Frame`
/// kept across the call that wrote the next message reads bytes that are no
/// longer the frame it names. Copying a `Frame` copies the two views, not the
/// bytes, so a copy is not a second owner and there is nothing to release.
///
/// `bytes` is the message in the message namespace, so it is what a JSON
/// decoder takes next; `rest` is the byte-stream remainder and belongs to the
/// caller's next [`nextFrame`].
pub const Frame = struct {
    /// The message bytes, excluding the delimiter. Empty when the input began
    /// with the delimiter, which is a blank line rather than a message; the
    /// JSON layer refuses it, and it is reported here as an empty frame rather
    /// than as the end of the input.
    bytes: []const u8,
    /// Everything after the delimiter, for the next call. Empty when
    /// `unterminated`, and it borrows the tail of `input` rather than a
    /// separate allocation, so it never needs releasing.
    rest: []const u8,
    /// True when the frame ended the input rather than a delimiter.
    ///
    /// The input may be a partial arrival rather than the whole message, so
    /// this is what tells a caller the bytes it holds are not yet a frame: a
    /// caller that streams must wait for the delimiter instead of handing
    /// `bytes` on. `framing.Framer` is the route for bytes that arrive in
    /// pieces, and it reports the same fact through `next` returning `null`.
    unterminated: bool,
};

/// Take the next frame from `input`, splitting at the first [`frame_delimiter`].
///
/// The returned [`Frame`] borrows `input`; nothing allocates and nothing is
/// copied, so the frame is valid exactly as long as `input` is unchanged.
///
/// ## Which delimiter, and which bytes belong to the frame
///
/// An embedded newline cannot appear inside a frame, because a newline is the
/// delimiter; a JSON string carrying one is escaped by the encoder, so the
/// framing stays unambiguous. The split is on `'\n'` and on nothing else, so a
/// peer that sends CRLF leaves its carriage return at the end of `bytes` rather
/// than losing it: JSON calls `'\r'` insignificant whitespace, so the message
/// still decodes. `framing.Framer.next` is the other supported route and
/// makes the opposite choice, because a byte stream is a different namespace
/// from a message and there the `'\r'` belongs to the line ending, so it is
/// stripped before the frame is handed over. A caller holding a complete
/// message uses this pair; a caller receiving bytes in pieces uses the framer.
/// Both reach the same message text and neither depends on the other.
///
/// ## Partial input
///
/// With no delimiter in `input`, `bytes` is the whole of `input`, `rest` is
/// empty and `unterminated` is true. That is a partial arrival, not a malformed
/// frame and not a refusal: the bytes may be the start of a larger message and
/// this function cannot tell. Nothing is consumed and no state is held, so a
/// streaming caller calls again with `input` plus the bytes that arrived since.
///
/// ## Errors
///
/// `error.InvalidUtf8` when `bytes` is not valid UTF-8, which the specification
/// requires and which is why the check is here rather than at a later parse: a
/// frame that cannot be text is not a message. The refusal happens before any
/// result value exists, so a caller learns the frame is unusable rather than
/// holding a half-built one, and `input` is untouched and still its own. A
/// second document behind the delimiter is not an error here: that is a second
/// frame, and the next call reads it.
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

/// Append `bytes` as one frame and the delimiter behind it.
///
/// ## The two namespaces
///
/// This writes the delimiter [`nextFrame`] splits on and nothing else, so the
/// two agree on where a frame boundary is. No carriage return is appended,
/// because in the message namespace a CR is not a line ending: the only CR a
/// caller writes is one the peer sent inside `bytes`, and that one is passed
/// through, because JSON calls it insignificant whitespace. The stream
/// namespace is the other route, and `framing.Framer` is where a line ending
/// is a transport fact a reader strips from every frame.
///
/// ## What the pair agrees on
///
/// The agreement is over frame values rather than over bytes. A byte sequence
/// [`nextFrame`] accepts is one this writes and `nextFrame` reads back as the
/// same message; a sequence this refuses is one `nextFrame` refuses too. What
/// the call adds is the delimiter, so the buffer afterwards holds the message
/// plus one `'\n'`, and a caller that wants the message alone reads it back
/// out of that. Nothing here parses JSON: these bytes reach the wire, so a
/// message this library could not decode is a failure the peer discovers and
/// this library cannot. The pair is about framing.
///
/// ## Errors, and what is left behind
///
/// `error.InvalidField` for a `bytes` carrying an embedded delimiter, and for a
/// `bytes` that is not valid UTF-8. Both refusals precede the first write, so
/// they leave `writer` exactly as it was and a caller may retry with different
/// bytes in the same buffer. The one tag for both is what an `EncodeError` can
/// say, where `error.InvalidUtf8` would be the reading tag: a caller of this
/// function is asking what may be written, not what was read.
///
/// `error.BufferTooSmall` comes from `writer`, and `json.Writer.slice` is
/// all-or-nothing: it either copies all of `bytes` or writes none of them. So
/// the buffer afterwards is either untouched — too small for the message — or
/// holds all of `bytes` with no delimiter behind it, because the one byte that
/// did not fit was the delimiter. Both are neither a frame nor a message, so a
/// caller must discard what it holds rather than send or parse it, and retrying
/// means starting a fresh writer over a larger buffer. Nothing here allocates,
/// and `bytes` is only read.
///
/// The UTF-8 check belongs here rather than being left to
/// `json.Writer.string`, which documents that an unvalidated value is a
/// programming error. That position holds for a decoded value, whose bytes a
/// decoder already checked. This function takes raw bytes rather than a
/// decoded value, so there is no such guarantee behind them and the encoder is
/// the last place that can refuse.
pub fn writeFrame(bytes: []const u8, writer: *json.Writer) EncodeError!void {
    // A caller that handed us a raw newline has already broken the framing, and
    // writing it would split one message into two on the wire.
    if (std.mem.findScalar(u8, bytes, frame_delimiter) != null) return error.InvalidField;
    // A frame that is not text is not a message, which is what `nextFrame`
    // already says. The two checks stay ahead of the first write: moving one
    // below it would make a refusal leave a prefix behind.
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
///
/// Every field is a wire fact read out of a comptime table, so a value copied
/// out of one is a value and not a handle: copies are independent, nothing here
/// owns anything, and there is nothing to release. The string fields point at
/// the registry's own static storage rather than at anything a caller passed,
/// so they stay valid for the life of the program.
///
/// The fields are what the registries are transcribed from, and reading them is
/// how a caller builds a dispatch table. None of them is a decision: the gates
/// say what a peer has to advertise, and turning them into "this call may go
/// out" also needs the side, the arity and the version checks that
/// [`isMethodSupported`] names and `acp_session.checkCall` applies.
pub const MethodInfo = struct {
    /// The wire spelling, and the only name a call is looked up or sent under.
    /// It is not borrowed from a caller's slice: [`lookupMethod`] returns the
    /// registry's own string, so the entry outlives whatever was passed in.
    name: []const u8,
    /// The side the method *lives on*, which is how the registries spell it: an
    /// `.agent` entry is called by the client on the agent, so a client asks
    /// about `.agent` and the agent asks about `.client`. `.protocol` is on
    /// neither side and is callable from either.
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

/// Look `name` up in `version`'s registries and return that entry, or
/// `error.UnknownMethod` when no registry for `version` carries it.
///
/// A method the other version removed is `error.UnknownMethod` rather than a
/// value the caller might send, which is the whole point of section 6.4: an
/// adapter must reject advertised v1 `fs` or `terminal` support when speaking
/// v2 rather than silently dropping it.
///
/// The result is a copy of one comptime table entry, so it is readable after
/// this returns and copies of it are copies of a value rather than of an
/// owner: nothing here needs releasing. Its `name` points at the registry's
/// own static string, not at `name`, so it stays valid whatever the caller
/// does with the bytes it passed. The side-independent table is searched on
/// both versions, and the first entry whose name matches wins; no two
/// registries in a version carry the same name, and a test holds that.
///
/// This is a lookup and nothing more. It applies no gate, so the entry it
/// returns is not a decision that the call may be made: the capability gate
/// ([`isMethodSupported`]), the side, the arity and the auth-methods rule are
/// four separate checks, and `acp_session.checkCall` is where all of them are
/// applied together.
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

/// Whether `advertised` carries the capability `info` is gated on. This is
/// the gate check alone.
///
/// A method with no gate is baseline and always answers true. A method with
/// one gate needs that capability. A method with two gates needs either of
/// them, because `gate2` is an alternative spelling of the same requirement
/// rather than a second one; an `info` with an empty `gate` and a non-empty
/// `gate2` is therefore baseline here, which is what both shipped registries
/// mean, and no entry in either has that shape.
///
/// `elicitation/create` is the case the schema forces. PROTOCOLS.md section 6.5
/// gates it per mode, so form mode and URL mode each enable it; one gate field
/// could name only one of them, and a peer advertising URL mode alone would be
/// reported as not supporting a method it does support. `session/resume` is the
/// other, where the two sources name different gates for one method rather than
/// one gate covering two.
///
/// Omission means unsupported, so an empty `advertised` set answers true for
/// the ungated methods and false for every gated one.
///
/// ## What this does not decide
///
/// A true answer is not admission, and `info` arrives by value, so nothing here
/// says where it came from. Three further obligations live elsewhere, and a
/// caller that reads this function as the whole gate has skipped all of them:
///
/// - **The version.** `info` must have come from [`lookupMethod`] for the
///   negotiated version. A `MethodInfo` copied out of the other version's
///   registry answers this function happily, and a v1 `fs/read_text_file` is
///   gated by a capability an adapter may still be holding from an old
///   handshake.
/// - **The side and the arity.** `info.side` must be the side the call is made
///   on, and `info.notification` must agree with whether the caller expects an
///   answer. Neither is reachable from these two arguments.
/// - **`conditional_on_auth_methods`.** The v2 auth methods are gated on the
///   peer having sent a non-empty `authMethods` array, which is not a
///   capability path and so cannot appear in `advertised`. The flag is on
///   [`MethodInfo`] and this function does not read it.
///
/// `acp_session.checkCall` is what enforces all four together: it calls
/// [`lookupMethod`] first — so the version is settled before anything is read
/// out of the entry — then applies the side, the arity and the auth-methods
/// tests, and reaches this function last. A caller dispatching its own calls
/// wants those four in that order.
///
/// Total and allocation-free. `advertised` is compared by exact byte equality,
/// so it has to hold the paths in the spelling [`Capability.path`] records — a
/// v1 path relative to that side's own capability object, a v2 path carrying
/// the `capabilities` root — and a path in any other spelling simply does not
/// match. [`advertisedPaths`] produces such a list from a decoded set.
pub fn isMethodSupported(info: MethodInfo, advertised: []const []const u8) bool {
    if (info.gate.len == 0) return true;
    if (contains(advertised, info.gate)) return true;
    if (info.gate2.len != 0 and contains(advertised, info.gate2)) return true;
    return false;
}

/// The two auth method names for `version`, which v1 and v2 spell
/// differently, section 6.4.
///
/// `login` is the method that authenticates and `logout` the one that ends the
/// session; a caller pairs them with its own registry entry rather than with a
/// literal, so a dispatch table does not carry two spellings per site. Both
/// returned slices point at static storage inside this file and are never
/// released; the struct is returned by value, so a copy costs nothing and owns
/// nothing. The v2 names are the two methods [`MethodInfo`] marks
/// `conditional_on_auth_methods`, which is why they are named together: the
/// gate a caller has to check for both is the peer's `authMethods` array and
/// not a capability path.
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
///
/// Each name appears as a `_v1` / `_v2` pair, and the pair is the fact: a
/// concept keeps its meaning and changes the member or member path it lives
/// under, so a caller translating between the versions reads both sides rather
/// than deriving one from the other. The v2 side is not always the v1 side
/// with a prefix — `clientInfo` becomes `info`, and the two capability members
/// collapse onto one shared `capabilities` — so the pairs are written out
/// rather than computed.
///
/// Every value is a wire spelling inside a comptime struct, so nothing here is
/// allocated and nothing is released; a caller may hold any of them for as
/// long as it likes.
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
    // is listed because the RFD proposes it and `bridge` carries the path. One
    // released SDK declares the key from a schema snapshot that is not a
    // released artifact and marks it unstable; PROTOCOLS.md 6.5.1 has both.
    "mcpCapabilities.acp",
};

/// Whether `path` is one of the v1 gates the *client* capability object
/// declares, spelled the way [`Capability.path`] records them: relative to
/// that object, so `fs.readTextFile` rather than
/// `clientCapabilities.fs.readTextFile`.
///
/// v1 has no closed capability set: an unknown capability is not a decode
/// error, which is the documented non-breaking extension mechanism. So a
/// `false` here is never a rejection — it is the answer "this library does not
/// name it", and the caller decides what an unrecognised path is worth. A
/// `true` is stronger and means the path is one this library will form-check
/// on the way in and on the way out.
///
/// Per side, and the side is the point: the same path can be a client gate and
/// not an agent gate. Reading it against the wrong side's table would report
/// a capability the peer never advertised under that object, so
/// [`isKnownCapability`] is the one dispatch both versions and both sides go
/// through.
///
/// Total and allocation-free, over a comptime table of static strings.
pub fn isKnownV1ClientCapability(path: []const u8) bool {
    for (v1_client_capabilities) |known| {
        if (std.mem.eql(u8, known, path)) return true;
    }
    return false;
}

/// Whether `path` is one of the v1 gates the *agent* capability object
/// declares, spelled the way [`Capability.path`] records them: relative to
/// that object, so `loadSession` and `session.delete` rather than
/// `agentCapabilities.sessionCapabilities.delete`.
///
/// Everything [`isKnownV1ClientCapability`] says applies here unchanged — a
/// `false` is an unrecognised path rather than a rejection, the table is
/// comptime and static, and the comparison is exact byte equality — with the
/// agent's own table behind it. The two tables are disjoint in the entries the
/// registries gate on, and a path outside both is an extension point on either
/// side.
pub fn isKnownV1AgentCapability(path: []const u8) bool {
    for (v1_agent_capabilities) |known| {
        if (std.mem.eql(u8, known, path)) return true;
    }
    return false;
}

/// Whether `path` names a v1 capability of either side, without saying which.
///
/// v1 has no closed capability set, so this is a known-value check and not a
/// validation: an unknown path is an extension point, not an error.
///
/// It also drops the side, which is deliberate and is what makes it the wrong
/// question to ask when a path comes off the wire. A decoder must ask per side,
/// because that is what decides whether the member is form-checked: a client
/// object carrying `promptCapabilities.image` names no client capability, and
/// under this function it would read as known. [`isKnownCapability`] takes the
/// version and the side and is the one a decode or an encode should ask;
/// [`v1CapabilityForm`] is per side for the same reason.
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

/// The form the v1 schema gives the gate at `path`, section 6.5.
///
/// v1 types the filesystem, the terminal, terminal-mode authentication,
/// session loading, the three prompt content kinds and everything under
/// `mcpCapabilities` as JSON booleans; every other gate is a `{}` presence
/// object. A path this library does not know has no form it can claim, and
/// reports the presence object because that form asserts the least: section
/// 6.5 makes an unknown capability an extension point, not an error.
///
/// The question is asked of `path` alone, so it drops the side, and that is the
/// same limitation [`isKnownV1Capability`] has. For the boolean domains and
/// paths in this file the two sides' answers coincide, because none of them
/// appears on both tables; where they did not, this would answer for a
/// capability of the other side. A decoder and an encoder therefore do not ask
/// this — they ask [`isKnownCapability`] for the side first and consult the
/// form only for a path that side names — and this function is here for a
/// caller holding a path and nothing else. Total, allocation-free, and it
/// borrows nothing.
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

/// The answer [`classifyTag`] gives a discriminator string that is in none of
/// the named values, for `version`.
///
/// One rule, read off the version: v1's unions are closed and the string is
/// not a value this protocol has, v2's declare the free-string `other` branch
/// and the string is one. Total and allocation-free, and it consults nothing
/// but the tag.
///
/// This is the version rule alone. It does not say a caller may act on either
/// answer: `RequestPermissionOutcome` has no catch-all branch in either
/// version, so an unrecognised outcome there is `error.UnknownTag` regardless
/// of what this returns, and PROTOCOLS.md section 6.6 forbids reading it as
/// approval. The unions that actually gained a catch-all are the ones the
/// `classify*` functions below enumerate.
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

/// Classify `tag` against `named`, the values one version's union declares.
///
/// A string equal to one of `named` is `.{ .named = index }` with that entry's
/// index in `named`, so the caller reads the table it already holds rather than
/// re-matching the string. Anything else is decided by the version alone:
/// `.{ .other }` where the schema declares the catch-all, and
/// `.{ .undefined_tag }` where its unions are closed.
///
/// `named` is compared by exact byte equality in the order given, and `tag`
/// points at the caller's bytes; neither is copied and neither is retained, so
/// the answer is a tag and an index and nothing that needs releasing. Nothing
/// allocates. A `named` table with a duplicate entry answers with the lower
/// index, which is why every table in this file is checked for that.
///
/// The result is a classification and not a decision: `.{ .other }` says the
/// schema defines the value, not that this library knows what it means. A
/// union with no catch-all answers `.{ .undefined_tag }` at v1 even when its
/// table is empty, which is what a v1 `state_update` gets.
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
///
/// Only the first byte is read, so an empty `tag` is `false` rather than an
/// error: it names no variant and so is not an extension of one. Total,
/// allocation-free, and nothing is retained — this is a classification the
/// caller acts on, and the tag itself is what a caller keeps, because "which
/// arm of the catch-all is this" is not decided here.
///
/// This is about the *spelling*. Whether the schema gives an unrecognised
/// string a value at all is [`classifySessionUpdate`], and at v1 the answer to
/// that is `.{ .undefined_tag }` for this tag too: the prefix is a v2
/// convention, not a v1 one.
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

/// Classify a `StopReason` string at `version`, against that version's own
/// table.
///
/// The two tables carry the same five strings in the same order, so the
/// `.{ .named = index }` answer means the same thing at both versions and the
/// index can be used against [`v1_stop_reasons`] or [`v2_stop_reasons`]
/// without knowing which one produced it. The versions differ in what happens
/// to a string in neither table: `.{ .undefined_tag }` at v1, whose `StopReason`
/// union is closed, and `.{ .other }` at v2, whose is not. That difference is
/// the whole point of taking the version, and it is why a v2 reader has to be
/// ready for a reason it has never seen rather than assuming the v1 vocabulary
/// is closed.
///
/// v2 also moved the reason: at v1 it ends the `session/prompt` result, at v2
/// it arrives in an idle `state_update`. The classification is the same; where
/// the string was found is not, and a caller that has to tell a finished prompt
/// from an idle session has to look at the message rather than at this answer.
///
/// Total, allocation-free, and nothing is retained: `tag` is compared against
/// a comptime table of static strings and the result is a tag and an index. A
/// `.named` answer is this library's reading of the string and not a decision
/// to end the session; what a caller does with `cancelled` versus `end_turn` is
/// the session layer's rule, not this function's.
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

/// Classify a `SessionConfigOption` `type` at `version`, against that
/// version's own table.
///
/// The two tables carry the same two values in the same order, so the
/// `.{ .named = index }` answer means the same thing at both versions. They
/// differ in what a string outside the pair is: `.{ .undefined_tag }` at v1,
/// whose union is closed, and `.{ .other }` at v2, whose is not.
///
/// Total, allocation-free, and nothing is retained: `tag` is compared against
/// a comptime table of static strings and the result is a tag and an index. A
/// `type` is a spelling of the option's own kind and not to be confused with
/// [`PermissionOptionKindValue`], which is what a `kind` member decodes to and
/// which has its own four values.
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
///
/// This is a name-holder over static wire spellings: it owns nothing, allocates
/// nothing and is never released. The v2 side of the version difference is
/// what these names are for, so a v1 reader should ask
/// [`isSessionModeCategory`] rather than matching one of them.
pub const session_config_option_category = struct {
    /// The category that carries a session mode. PROTOCOLS.md section 6.4:
    /// `session/set_mode`, the `SessionMode*` types and `current_mode_update`
    /// are all replaced by a config option carrying this category, so a v2
    /// reader looking for the v1 mode surface has to look here instead.
    pub const mode = "mode";
    /// The category that names the model the session runs on.
    pub const model = "model";
    /// The category that names the configuration applied to that model.
    pub const model_config = "model_config";
    /// The category that names how much reasoning the session shows.
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

/// Whether `category` is the one that replaced the v1 mode surface.
///
/// `mode` is the only category that means this, so the answer is "is this
/// category a session mode?" rather than "is this a category?". The comparison
/// is exact and case-sensitive. There is no absent case: an unrecognised
/// category is simply not this one, and a v1 reader has no established
/// category set at all, which is why the question is only worth asking once the
/// version is known. Total and allocation-free, and `category` is only read.
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
///
/// The `.start` arm is a tag with no borrow. The `.other` arm is a tag and a
/// borrow of the peer's own text, so a copy is a copy of the handle rather
/// than of the string, nothing is allocated or released, and an `.other` value
/// read from a document is valid exactly as long as the buffer it was decoded
/// into.
pub const ReplayFrom = union(enum) {
    /// `{"type": "start"}`, carrying nothing but optional `_meta`. The `_meta`
    /// is not modelled, so a document carrying one re-encodes without it; the
    /// arm is still the one place the wire can spell this point.
    start,
    /// Any other `type`. The rest of the object belongs to the peer that sent
    /// it and is not this library's to interpret: neither arm carries it, so
    /// a document with members beside `type` re-encodes without them.
    /// [`encodeReplayFrom`] records that loss and what closing it would take.
    ///
    /// The value cannot be `replay_from_type.start`, which the decoder gives
    /// the `.start` arm and the encoder refuses here, so a tag on this arm and
    /// a decoded document always agree on which arm the wire spells.
    other: []const u8,
};

/// Decode a v2 `ReplayFrom` object out of `raw`, using `scratch` for keys and
/// for the `type` string.
///
/// `.{ .other }`'s tag borrows `raw` where the string carried no escape and
/// `scratch` where it did, so both buffers must stay alive and unmodified while
/// the value is read. `.{ .start }` borrows nothing. Nothing allocates and
/// there is nothing to release.
///
/// `error.MissingField` when the object carries no `type`, `error.MalformedJson`
/// for a second value behind the closing brace, and the reader's own tags for
/// everything else; `error.BufferTooSmall` is the caller's scratch being too
/// narrow for a key or an escaped `type`. On every one of those `raw` and
/// `scratch` are the caller's still, so the same buffers can be reused for the
/// next document.
///
/// A `type` this library does not name is not an error here, because the v2
/// schema defines the catch-all that receives it — the opposite of
/// [`decodePermissionOutcome`], whose union has none in either version.
pub fn decodeReplayFrom(raw: []const u8, scratch: []u8) DecodeError!ReplayFrom {
    var reader = json.Reader.init(raw);
    var tag: ?[]const u8 = null;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "type")) {
            // The first occurrence of a repeated member wins, as in every
            // other walk in this library. `start` and a vendor tag are
            // different positions to resume at, so a peer that sends both must
            // not be able to choose the one the session takes. The repeat is
            // stepped over rather than read, so the first occurrence's text
            // stays live in the caller's scratch.
            if (tag != null) {
                try reader.skipValue(scratch);
            } else {
                tag = try reader.string(scratch);
            }
        } else {
            // `ReplayFromStart` carries only `_meta` and the `other` branch
            // sets `additionalProperties`, so no other member is required.
            // None of them is carried, which `encodeReplayFrom` records.
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

/// Write `value` as a v2 `ReplayFrom` object, with no leading or trailing
/// bytes.
///
/// Every value [`decodeReplayFrom`] can return is written, and a value this
/// refuses is one that decoder could not have returned: `.other` holding
/// `replay_from_type.start`, which would be a document that decodes as the
/// other arm — the arm the caller asked to encode is the one the wire cannot
/// spell.
///
/// ## What the round trip does not carry
///
/// The guarantee is over the replay point, not over the document it arrived
/// in, and there is one class of input the pair reads differently.
/// `ReplayFromStart` carries an optional `_meta` that this module models
/// nowhere, and the `other` branch sets `additionalProperties`, so a document
/// carrying members beside `type` of either kind decodes to a value that
/// re-encodes to `{"type":"…"}`. Refusing the value would not help, because the
/// members are gone before any encoder sees the result; they have to be carried
/// by [`ReplayFrom`] itself, and that is a change to the shape rather than to
/// this function. Carrying them means a borrowed lexeme beside the tag on both
/// arms, and `src/acp_session.zig` and `src/testkit.zig` both match on and
/// construct those arms.
///
/// Everything else survives: the same arm, the same tag, and no members beyond
/// `type`, so the bytes here decode back to the value that was written. They
/// are not the source bytes in general — whitespace is dropped and the tag is
/// re-escaped — and only the canonical `{"type":"…"}` spelling the tests pin
/// comes back exactly.
///
/// ## The caller's UTF-8
///
/// An `.other` tag is written through `json.Writer.string`, which requires
/// valid UTF-8 and checks nothing in any optimize mode. A tag from
/// [`decodeReplayFrom`] is valid, because `json.Reader.string` validated it; a
/// tag a caller built by hand is its own to validate, and an invalid one is
/// written rather than refused, leaving this library's own reader to reject the
/// document with `error.InvalidUtf8`. There is no assert on this path, so
/// nothing catches it in Debug either.
///
/// ## Errors, and what is left behind
///
/// `error.InvalidField` is decided before the first write, so it leaves
/// `writer` untouched. `error.BufferTooSmall` is the only tag that arrives
/// mid-document: `writer` then holds a prefix of the object, which is not one,
/// so a caller discards it and retries with a larger buffer.
///
/// `value` is only read: nothing is allocated, nothing is retained, and an
/// `.other` tag has to outlive the call rather than the value.
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
    // proposes it and `bridge` carries the path. A released SDK declares it
    // from a snapshot it marks unstable; PROTOCOLS.md 6.5.1 records that.
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
///
/// A decoded entry borrows. `path` is a region of the `paths` buffer
/// [`decodeCapabilityObject`] was given, so writing that buffer again or
/// releasing it invalidates every entry at once. Nothing here is allocated and
/// nothing needs releasing; a copy is a copy of the handle rather than of the
/// path, so both copies name the same bytes and both die with them. That is why
/// a session that has to keep answering gates keeps the path list
/// ([`advertisedPaths`]) and drops the entries rather than the other way round.
pub const Capability = struct {
    /// The dotted path in the spelling a [`MethodInfo`] gate uses, so a decoded
    /// set can be handed straight to [`isMethodSupported`]. A v1 path is
    /// relative to the side's own capability object, which is how PROTOCOLS.md
    /// section 6.5 spells its gates; a v2 path keeps the `capabilities` root,
    /// because that is the member both sides carry in v2. Keeping the root is
    /// what stops a v1 path and a v2 path for the same feature from being the
    /// same string across a version cutover. A hand-built entry has to carry the
    /// root too, or the encoder refuses it rather than writing a member name
    /// the walk would read back as a different path.
    path: []const u8,
    /// Whether this library names the path.
    ///
    /// False is not a failure. Section 6.5 makes an unknown capability the
    /// documented non-breaking extension mechanism, so the entry is recorded
    /// with the flag off and the caller can tell a gate it may rely on from one
    /// it merely forwards.
    known: bool,
    /// The form the member had on the wire, and the one fact about the member
    /// that decides whether it advertises: the two forms assert support
    /// differently, and a boolean's value has to be read on top of it.
    form: CapabilityForm,
    /// The value of a boolean member, or null for a presence object, which
    /// asserts support by being there rather than by a value.
    ///
    /// `null` on a `.boolean` member is not a wire value: the walk reads one as
    /// a missing member and records no entry at all, and
    /// [`encodeCapabilityObject`] refuses to write it. It appears only in a
    /// hand-built entry, where it means "there is no boolean here to write",
    /// and the encoder answers that with `error.InvalidField` rather than
    /// guessing `false` — which would say a member it cannot spell advertises
    /// "unsupported".
    value: ?bool,

    /// Whether this member advertises support.
    ///
    /// A presence object advertises by existing, which is why an empty object
    /// is the whole message. A `false` boolean is the v1 spelling of
    /// "unsupported", so the value has to be read rather than assumed from the
    /// member's presence. A `.boolean` member with no value answers false,
    /// which matches the one thing this library writes for it: a member the
    /// walk could not read as a capability at all.
    ///
    /// Total and allocation-free. The entry arrives by value, so this borrows
    /// nothing and retains nothing; it is safe to call from any thread.
    pub fn advertised(self: Capability) bool {
        return switch (self.form) {
            .presence_object => true,
            .boolean => self.value orelse false,
        };
    }
};

/// The leaves of one decoded capability object.
///
/// A pure borrow: `entries` is a slice of the caller's own array and every
/// `Capability.path` inside it points into the caller's `paths` buffer, so a
/// set owns nothing, allocates nothing and needs no release. Copying a set
/// copies the slice header rather than the entries, so a copy names the same
/// storage and dies with it. A hand-built set is a supported value — the
/// encoders take one — and then both obligations are the builder's: the paths
/// have to come from somewhere that outlives the write, and they have to carry
/// the spelling the encoder writes from.
///
/// The order of `entries` is what [`encodeCapabilityObject`] reads to rebuild
/// the nesting, so a set built by hand has to reproduce the parent-then-child
/// order a decode produces.
pub const CapabilitySet = struct {
    /// The entries, in wire order, in caller-owned storage. Every member the
    /// object carried is represented: the ones that recorded, as entries, and
    /// the ones that recorded nothing — an explicit `null`, a value no schema
    /// declares — as nothing at all. `out[0..entries.len]` is what the walk
    /// wrote, and a slot past it belongs to the walk's own bookkeeping rather
    /// than to this set.
    entries: []const Capability,
    /// Whether the capability member was on the wire at all. Omission means
    /// unsupported in both versions, so a caller can tell "advertised nothing"
    /// from "advertised an empty object". The two are written differently:
    /// `false` produces no member and `true` produces `{}`, so a set carrying
    /// this flag round-trips through the encoder.
    present: bool,
};

/// Flatten a decoded set into the path list [`isMethodSupported`] takes.
///
/// Only members that advertise are copied, so the list is the peer's support
/// and not merely its vocabulary: a v1 boolean answered `false` is a member on
/// the wire and no support here. A capability this library does not name is
/// included — whether it is worth anything is the caller's judgment — so a
/// vendor path reaches a gate the caller chose to gate on it.
///
/// `out` is caller-owned and the result borrows it; nothing allocates and
/// nothing is copied, so the returned paths still point into whatever
/// `set.entries` pointed into and the list is valid exactly as long as both
/// that buffer and `out` are unchanged. `out` past the returned length keeps
/// whatever the caller had put there.
///
/// `error.BufferTooSmall` is the caller's own array being too short, and it is
/// reported rather than truncated: a truncated list reads as a peer that
/// advertised less than it did, which is the one answer a caller may not
/// invent. On that path the first `out.len` slots hold paths that are real, but
/// no count is returned, so a caller must discard them and retry with a bigger
/// array. There is no other error.
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

/// Whether `path` is the path `key` takes inside `parent`.
///
/// A recorded path is compared rather than rebuilt, because a repeat must not
/// cost the caller a region of `paths` that the first occurrence has already
/// paid for. The comparison is by segments rather than by a joined copy for the
/// same reason: a second copy of the joined spelling would be a second region
/// per member, and no caller reads one.
fn isPathOf(path: []const u8, parent: []const u8, key: []const u8) bool {
    // A v1 path at the top of its object is the bare key, so there is no parent
    // segment and no dot to match.
    if (parent.len == 0) return std.mem.eql(u8, path, key);
    return path.len == parent.len + 1 + key.len and
        std.mem.eql(u8, path[0..parent.len], parent) and
        path[parent.len] == '.' and
        std.mem.eql(u8, path[parent.len + 1 ..], key);
}

/// What an earlier occurrence of a member name decided.
///
/// Three answers rather than one, because a member is decided whether or not it
/// recorded: a name the walk recorded is found in the entries, a name whose
/// occurrence recorded nothing is found in the claims, and a name it has not
/// seen is neither.
const First = union(enum) {
    /// The name is new in this object, so this occurrence decides it.
    free,
    /// The name is a recorded path, and that path is the one a form check on
    /// this occurrence is asked about. Reusing it is what lets a repeat of a
    /// recorded member cost the caller no region of `paths`.
    recorded: []const u8,
    /// The name is claimed by an occurrence that recorded nothing. No path
    /// exists for it — a member that records nothing costs no region of
    /// `paths` — so a form check on this occurrence has to build one.
    unrecorded,
};

/// The buffers and counters one capability decode works through.
///
/// `out` carries two things. The entries the caller is handed are written from
/// the front, and the claims — the names of members whose occurrence decided
/// nothing — are written from the back, so the one can never be read as the
/// other. Every write checks that the two have not met before it makes one, and
/// running out of room is `error.BufferTooSmall` about the caller's own array,
/// which is whose fault it is.
const CapabilityWalk = struct {
    version: WireVersion,
    side: Side,
    out: []Capability,
    paths: []u8,
    scratch: []u8,
    /// Bytes of `paths` written so far. It never rewinds, so every recorded
    /// path owns a region that no later path overwrites.
    end: usize = 0,
    /// Entries written to the front of `out`.
    count: usize = 0,
    /// Claims written to the back of `out`. They are the whole record of a
    /// member whose occurrence recorded nothing, and they are what a later
    /// occurrence of the same name is answered by.
    claims: usize = 0,

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

    /// The claim at `index`, counted from the back of `out`.
    fn claimAt(self: *CapabilityWalk, index: usize) *Capability {
        return &self.out[self.out.len - 1 - index];
    }

    /// Whether an earlier occurrence of `parent.key` already decided this name.
    ///
    /// A repeated member resolves first-wins, as it does in every other member
    /// walk in this library, and this walk needs two memories to apply the rule
    /// where a walk over a fixed shape carries one flag per member. A capability
    /// object is an open object: v1 has no closed capability set and v2 replaced
    /// the set with a documented extension point, so "have I seen this name" is
    /// a question about a set rather than about a bit, and the set has to be
    /// somewhere the caller already owns.
    ///
    /// A recorded member is its own record. The entries carry the whole path, so
    /// a member of another object cannot answer for this one, and neither can a
    /// member that is an ancestor of the path or a child of it. An occurrence
    /// that recorded nothing left no entry behind, so the name it decided is
    /// claimed in the claims instead, and `base` is where this object's claims
    /// begin: the claims of an object that has closed are spent with it, so the
    /// same name at two levels stays two members.
    fn claimed(
        self: *CapabilityWalk,
        parent: []const u8,
        key: []const u8,
        base: usize,
    ) First {
        for (self.out[0..self.count]) |entry| {
            if (isPathOf(entry.path, parent, key)) return .{ .recorded = entry.path };
        }
        var index = base;
        while (index < self.claims) : (index += 1) {
            if (std.mem.eql(u8, self.claimAt(index).path, key)) return .unrecorded;
        }
        return .free;
    }

    /// Claim the name of a member whose occurrence decided nothing.
    ///
    /// An explicit `null` is the member missing and wearing a key, and a value
    /// neither schema declares is not a capability at all, so neither records
    /// anything. Both are still the first occurrence of the name, and the rule
    /// is about the name: a peer that answered `null` and then `true` for
    /// `loadSession` did not advertise session loading, and a walk that let the
    /// second occurrence through would hand `acp_session` a capability the peer
    /// refused in its own `initialize`. This is the case a guard written as
    /// "is this path already in the entries" leaves open, and it is why the
    /// claims are not the entries.
    ///
    /// A claim costs a slot of `out` and no region of `paths`, because a member
    /// that records nothing costs the caller no region of that buffer, and the
    /// bare name is all there is to compare, because a claim belongs to the
    /// object it was made in: a name at another level is never asked of it.
    fn claim(self: *CapabilityWalk, key: []const u8) DecodeError!void {
        if (self.count + self.claims == self.out.len) return error.BufferTooSmall;
        self.claimAt(self.claims).* = .{
            .path = key,
            // Neither field is a fact about a claim: a claim has no path to ask
            // the tables about and no form the wire carried. They are written
            // so that the pair is one `validateCapabilityEntry` refuses, which
            // is the same answer the walk gives a boolean with no value, so a
            // claim cannot be read as a capability even if one ever escaped the
            // claims.
            .known = false,
            .form = .boolean,
            .value = null,
        };
        self.claims += 1;
    }

    /// The path a form check on a repeated member is asked about.
    ///
    /// A recorded member's own path is the answer, so a repeat the entries
    /// matched costs the caller no region of `paths`. A name whose first
    /// occurrence recorded nothing has no path behind it, so one is built for
    /// the check and spent with the value. `.free` cannot reach here: a name no
    /// earlier occurrence claimed is walked rather than spent.
    fn repeatPath(
        self: *CapabilityWalk,
        parent: []const u8,
        key: []const u8,
        first: First,
    ) DecodeError![]const u8 {
        return switch (first) {
            .free, .unrecorded => try self.appendPath(parent, key),
            .recorded => |path| path,
        };
    }

    /// Spend a member whose name an earlier occurrence decided.
    ///
    /// The value is stepped over whole, so nothing inside it is interpreted: a
    /// repeat supplies neither a capability of its own nor one for a child of a
    /// name the first occurrence settled. `skipValue` reads what it steps over,
    /// so a peer cannot hide a syntax error in the slot a name already used.
    ///
    /// The form is checked before the value is spent, and on a repeat as well as
    /// on a first occurrence, for the reason `bridge.decodeEnvelope` gives for
    /// `params`: the first occurrence is the one that is carried, and a document
    /// whose second `loadSession` is a presence object is malformed whatever the
    /// first one said. A value that is not a form is spent without a check,
    /// which is what a first occurrence of one does too — the schema declares no
    /// form for it, so there is nothing to ask the table.
    fn spendRepeat(
        self: *CapabilityWalk,
        reader: *json.Reader,
        parent: []const u8,
        key: []const u8,
        first: First,
    ) DecodeError!void {
        reader.skipWhitespace();
        const byte = reader.peek() orelse return error.Truncated;
        switch (byte) {
            't', 'f' => try self.checkFormAt(try self.repeatPath(parent, key, first), .boolean),
            '{' => try self.checkFormAt(try self.repeatPath(parent, key, first), .presence_object),
            else => {},
        }
        try reader.skipValue(self.scratch);
    }

    /// Walk the members of an object whose own path is `parent`.
    ///
    /// `base` is where this object's claims begin, so a name a member of it
    /// decided is not answered for by a name a member of an object inside it
    /// claimed and has since spent.
    fn walkMembers(
        self: *CapabilityWalk,
        reader: *json.Reader,
        parent: []const u8,
        depth: u32,
        base: usize,
    ) DecodeError!void {
        while (try reader.nextKey(self.scratch)) |key| {
            // `_meta` is metadata on every type in both schemas and never a
            // capability, so it never becomes a path. It needs no claim
            // either: a repeat of it is spent by the same `skipValue` that
            // spent the first, and there is no path for a later occurrence to
            // be answered with.
            if (std.mem.eql(u8, key, "_meta")) {
                try reader.skipValue(self.scratch);
                continue;
            }
            // First-wins, for the reason the doc above gives. The repeat is
            // spent rather than walked, so a later occurrence of a name cannot
            // become the answer, and it is shape-checked first, for the reason
            // `spendRepeat` gives.
            const first = self.claimed(parent, key, base);
            switch (first) {
                .free => try self.walkMember(reader, parent, key, depth),
                else => try self.spendRepeat(reader, parent, key, first),
            }
        }
    }

    /// Read the member named `key`, whose own path would be `parent.key`.
    ///
    /// The path is built only for a member that records one, because the value
    /// decides that and the record needs the path. A member that records
    /// nothing — an explicit `null`, a string, a number, an array — therefore
    /// costs the caller no region of `paths`, so a caller who sized that buffer
    /// by the paths the entries borrow is not asked for bytes no entry borrows.
    /// It costs a slot of `out` instead, because it is still the first
    /// occurrence of the name and the walk has to be able to answer a later one
    /// from it.
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
                // object, so it advertises nothing and gets no path. The name
                // is claimed, because the member is missing rather than
                // undecided, and a later occurrence of a missing member does
                // not make it present.
                try reader.nullLiteral();
                try self.claim(key);
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
                // The claims of the object that just closed are spent with it.
                // A name inside it said nothing about a member of this object,
                // and one of those is a different path even where the spelling
                // is the same, so carrying them would answer for a member that
                // was never sent.
                const inner = self.claims;
                try self.walkMembers(reader, childPath(self.version, path), depth + 1, inner);
                self.claims = inner;
            },
            else => {
                // A string, a number or an array is not a capability form
                // either schema declares, so it is stepped over rather than
                // guessed at. It is still the first occurrence of the name, so
                // it is claimed like the `null` beside it.
                try reader.skipValue(self.scratch);
                try self.claim(key);
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
        // The entries and the claims share `out`, so the room left is what the
        // claims have not taken. Reporting it as `BufferTooSmall` is honest: it
        // is the caller's own output array, and it is the array the walk ran
        // out of.
        if (self.count + self.claims == self.out.len) return error.BufferTooSmall;
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
        return isKnownCapability(self.version, self.side, path);
    }

    /// Refuse a form no version declares for a path the walk did not record.
    ///
    /// The repeated member this is asked for is spent rather than carried, so
    /// the entry that would hold the path is not written and the question is
    /// asked of a path borrowed from the first occurrence instead.
    fn checkFormAt(self: *CapabilityWalk, path: []const u8, form: CapabilityForm) DecodeError!void {
        try self.checkForm(path, self.isKnown(path), form);
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

/// Whether this library names `path` as a capability of `side` at `version`.
///
/// The one place the answer is written. `CapabilityWalk.record` reads it on the
/// way in and `validateCapabilityEntry` reads it on the way out, because a
/// rule with a copy on each side that does not read the same table is a
/// spelling that drifts. It did: the walk asked per `side` and the validator
/// asked side-independently, so it form-checked a path the walk had already
/// let through as an extension point and refused a value
/// `decodeCapabilityObject` had returned.
///
/// Public for the same reason, one level out: a caller that builds a
/// [`CapabilitySet`] by hand is asked the same question, and
/// [`encodeCapabilityObject`] is where it is told to ask. Reassembling this
/// answer from the three per-side tables below is the dispatch this function
/// exists to be. The tables stay public in their own right, because a caller
/// holding a path and nothing else still has a question about one side.
pub fn isKnownCapability(version: WireVersion, side: Side, path: []const u8) bool {
    return switch (version) {
        .stable => switch (side) {
            .client => isKnownV1ClientCapability(path),
            .agent => isKnownV1AgentCapability(path),
            .protocol => false,
        },
        .draft => isKnownV2Capability(side, path),
    };
}

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
/// `out` receives one slot per member the object carries, `paths` is where the
/// dotted paths are built and `scratch` is the reader's escape buffer. Nothing
/// allocates, and every buffer belongs to the caller. `paths` must hold the sum
/// of every path recorded, not the longest one, because each entry borrows its
/// own region and no region is recycled; a buffer that cannot is
/// `error.BufferTooSmall`. At v2 it must also hold the `capabilities` root,
/// which is written ahead of the first member and forms the head of that
/// member's region rather than a path of its own. A member that records nothing
/// costs no region of it at all.
///
/// It does cost a slot of `out`, because an occurrence is the first occurrence
/// of a name whether or not it recorded and a later one has to be answered from
/// it — see `CapabilityWalk.claim`. The entries are written from the front of
/// `out` and the claims from the back, so `out` has to hold every member of the
/// object, and the entries handed back are the members that recorded. The one
/// case where a member that recorded nothing reaches `paths` is a repeat whose
/// first occurrence recorded nothing: the form check is asked of a path, so one
/// is built for it and spent with the value.
///
/// Every object member is recorded, not only the empty ones, because a presence
/// object advertises by existing: a `elicitation.form` object that also carries
/// an extension still advertises form mode, and the gate has to appear in the
/// list for the method to be callable.
///
/// A member a peer spells twice resolves first-wins, as it does in every other
/// member walk in this library, so a refusal cannot be overwritten by a claim
/// the peer appended behind it. The repeat's form is still checked wherever it
/// stands, and a repeat's value is stepped over whole, so nothing inside it is
/// interpreted.
///
/// A member in the wrong form for its version is refused. That is stricter than
/// the v1 extension rule on purpose: the rule keeps an unknown *capability*
/// legal, and a wrong form on a known one, or any boolean at v2, is a shape the
/// schema does not define rather than a capability this library has not read.
///
/// ## What comes back, and what it borrows
///
/// The result is a [`CapabilitySet`] over `out`: `entries` is the front of that
/// array and every `Capability.path` in it is a region of `paths`, so the whole
/// set is valid exactly as long as the caller leaves `paths` and `out` alone.
/// Writing `paths` again, or releasing it, invalidates every path in the set at
/// once — which is why the encoder takes the paths with it rather than copying
/// them. `scratch` is spent on keys and is dead the moment the walk returns;
/// nothing in the result points into it. `present` is true on every successful
/// return, including for an empty object, because an empty object is a peer
/// that advertised nothing rather than an absent member;
/// `decodeInitializeCapabilities` is where the absent case is distinguished.
///
/// ## Errors, and what is left behind
///
/// `error.BufferTooSmall` is the caller's own shortage in all three buffers and
/// nothing else, and on that path the entries already written into `out[0..n]`
/// and the regions already built in `paths` must be discarded: no count is
/// returned, so a caller cannot tell a truncated set from a whole one.
/// `error.LimitExceeded` is a document nested past `json.max_depth`, and
/// `error.MalformedJson` is a second value behind the object's closing brace or
/// a syntax error inside it. `error.InvalidField` is a `.protocol` side or a
/// member in a form its version does not declare. `error.MissingField`,
/// `error.Truncated`, `error.InvalidUtf8` and the reader's own tags come from
/// the JSON walk. On every one of them `raw` is untouched, so the same buffers
/// can be handed to the next document.
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
    var walk: CapabilityWalk = .{
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
        try walk.walkMembers(&reader, paths[0..prefix.len], 1, 0);
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

/// Refuse a member whose form its version does not declare for its path, and a
/// v2 path the walk could not have recorded.
///
/// The rule `CapabilityWalk.checkForm` applies on the reading side, asked the
/// same way: per `side`, through [`isKnownCapability`]. An encoder that did
/// not apply it would advertise `terminal` as a `{}` at v1 or as a boolean at
/// v2, and `decodeCapabilityObject` refuses both: at v1 the form is the
/// schema's, and at v2 a boolean is a shape the draft does not define rather
/// than a capability this library has not read. A validator that asked
/// side-independently would go further than its decoder and refuse a value the
/// decoder had returned.
///
/// The v2 root is the same kind of rule and the same reason: the walk writes
/// the root into `paths` before the first member, so a recorded path always
/// carries it and a path that does not is one no walk produced. The comparison
/// is against `capabilities.` with the dot in it, so it is a whole leading path
/// component and not a prefix match: `capabilitiesFoo.bar` does not begin with
/// `capabilities.`, and neither does a bare `capabilities`. v1 is untouched by
/// this rule, because a v1 path is relative to the side's own object and
/// carries no root.
fn validateCapabilityEntry(
    version: WireVersion,
    side: Side,
    entry: Capability,
) EncodeError!void {
    // The value is the wire spelling of the form and carries nothing else. A
    // boolean with no value has to be written `null`, and the walk reads an
    // explicit `null` as the absent case and records no member at all. A
    // presence object with one has nowhere to put it, because the schema
    // gives that arm no value to carry.
    if (entry.form == .boolean and entry.value == null) return error.InvalidField;
    if (entry.form == .presence_object and entry.value != null) return error.InvalidField;
    switch (version) {
        .stable => {
            // Only a path this library names *for this side* is checked,
            // because v1 has no closed capability set and an unknown path is
            // an extension point that may take either form. The other side's
            // table is not consulted: a client object carrying
            // `promptCapabilities.image` names no client capability, and the
            // walk recorded it as one that may take either form.
            if (!isKnownCapability(.stable, side, entry.path)) return;
            if (entry.form != v1CapabilityForm(entry.path)) return error.InvalidField;
        },
        .draft => {
            // The root is written into `paths` ahead of the first member, so a
            // path the walk recorded always begins with it and the member name
            // this writes is what is left after the root comes off. A path that
            // does not begin with the root has no member name this function can
            // take: it would be written as one name containing dots, which the
            // walk would read back as that name with the root prepended — a
            // different path, from a document no walk produced. Refusing it
            // keeps what this writes and what this reads the same value. The
            // constant carries the dot, so this is a leading path *component*:
            // `capabilitiesFoo.bar` and a bare `capabilities` are refused too,
            // because neither is a path the walk could have recorded.
            if (!std.mem.startsWith(u8, entry.path, v2_capabilities_root)) {
                return error.InvalidField;
            }
            if (entry.form != v2_capability_form) return error.InvalidField;
        },
    }
}

/// The container levels already spent above the capability object that
/// [`encodeCapabilityObject`] writes: none. The object that call writes is the
/// whole document, so the capability object itself is the seed: a level spent
/// ahead of every presence object, because it is the container they sit inside.
const capability_object_depth = 1;

/// The container levels already spent above that same object inside the body
/// [`encodeInitializeCapabilities`] writes.
///
/// The budget is over the document rather than over the member, and this is a
/// whole document: `decodeInitializeCapabilities` opens the body with
/// `json.Reader.beginObject` and then reads the member with `rawValue`, which
/// spends a level on the object the member carries. So the same set is one
/// level shallower here than it is on its own, and it is the *document* the
/// bound is about rather than the part of it this library spells.
const initialize_body_depth = capability_object_depth + 1;

/// Refuse a set the decoder for `version` and `side` could not have returned
/// in a document `base_depth` says the set is written into.
///
/// Separate from the writers so that a caller can run this before it writes
/// anything: a refusal that reached the caller after `{"capabilities":` had
/// landed in the buffer would leave a prefix that reads as a member and is not
/// a document. How deep a set may nest is one of those same facts — no decode
/// returns a set past `json.max_depth` — so [`validateCapabilityDepth`] is
/// asked here too, rather than left to the writer's own array.
///
/// `base_depth` is how much of that budget the containers around the set have
/// already spent: [`capability_object_depth`] for a set written on its own and
/// [`initialize_body_depth`] for the `initialize` member, which is a whole
/// body carrying the object as one of its members. It is passed rather than
/// assumed because the two writers are at different depths over the same
/// entries, and a validator that picked one of them would refuse a set the
/// other can write.
fn validateCapabilitySet(
    version: WireVersion,
    side: Side,
    set: CapabilitySet,
    base_depth: usize,
) EncodeError!void {
    // Neither schema gives a capability object to a side-independent method,
    // and `decodeCapabilityObject` refuses that before it reads a byte.
    if (side == .protocol) return error.InvalidField;
    for (set.entries) |entry| try validateCapabilityEntry(version, side, entry);
    try validateCapabilityDepth(version, set, base_depth);
}

/// Refuse a set nested deeper than any decode could have produced in a
/// document `base_depth` says the set is written into.
///
/// The bound is `json.max_depth`, charged the way the decoder charges it, and
/// `base_depth` is how much of it is already spent before the first presence
/// object: the capability object is a container because it is the member and
/// `decodeCapabilityObject` opens it with `json.Reader.beginObject` before it
/// reads a member of it, and the `initialize` body around it is a container
/// because it is the document. So a set carrying `json.max_depth - base_depth`
/// presence objects below the capability object is the deepest any decode
/// admits — the members of the last one sit at walk depth `json.max_depth`,
/// which is the level `CapabilityWalk.walkMember` still accepts, and the
/// object above them is the last whose `enterContainer` has a level left to
/// spend. One presence object more is `error.InvalidField` here, where nothing
/// has been written, rather than a document no decode could read back. A
/// boolean spends no level, because `enterContainer` is never asked for one, so
/// a scalar inside the deepest admissible object is an ordinary member.
///
/// The walk below is the write loop of [`writeCapabilityObject`] with the
/// bytes left out: the same entries in the same order, the same
/// [`capabilityClosedLevels`] closing what `path` is not inside, and the same
/// [`isCapabilityAncestor`] deciding that. A deep branch followed by a sibling
/// therefore unwinds rather than sums, and only the deepest branch is charged;
/// a bound derived any other way would refuse a set the writer can spell or
/// admit one the decoder refuses, which is the drift this shares its
/// unwinding to prevent.
///
/// Allocation-free and off the writer's buffer: the open objects are entry
/// indices in an array of this frame, bounded before an index is stored
/// rather than after.
fn validateCapabilityDepth(
    version: WireVersion,
    set: CapabilitySet,
    base_depth: usize,
) EncodeError!void {
    // The containers `base_depth` counts are spent on every entry and are not
    // presence objects, so their levels are a constant charged here rather
    // than indices: the decoder spends them opening the objects around the set
    // and never gives them back.
    //
    // Indexed by `depth`, which the check below bounds by
    // `json.max_depth - base_depth`, so the array is never indexed out of
    // range — and `base_depth` is at least `capability_object_depth`, so that
    // bound is inside the array rather than one past it.
    var open: [json.max_depth]usize = undefined;
    var depth: usize = 0;
    for (set.entries, 0..) |entry, index| {
        depth -= capabilityClosedLevels(version, set.entries, open[0..depth], entry.path);
        // A boolean spends no level: `json.Reader.enterContainer` is never
        // asked for one, so a scalar inside the deepest admissible object is
        // read and recorded like any other member.
        if (entry.form != .presence_object) continue;
        // Checked before the index is stored, so `open[depth]` is written at
        // most at `json.max_depth - 1 - base_depth`.
        if (depth + base_depth >= json.max_depth) return error.InvalidField;
        open[depth] = index;
        depth += 1;
    }
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

/// How many of the objects in `open` `path` is not inside.
///
/// `open` holds the entries of the presence objects still open, oldest first,
/// which is what makes the deepest one the last recorded: a prefix is shorter
/// than what it prefixes, and the walk records an ancestor before anything
/// inside it. Each object the test does not answer for has closed already, so
/// the count is how many closing braces the writer owes before the member
/// `path` takes — and, in [`validateCapabilityDepth`], how many levels the
/// entry gives back.
///
/// The write loop and the depth pass both ask this instead of running an
/// unwinding of their own. A bound counted against one shape and a document
/// written from another is the drift the shared question exists to stop.
fn capabilityClosedLevels(
    version: WireVersion,
    entries: []const Capability,
    open: []const usize,
    path: []const u8,
) usize {
    var closed: usize = 0;
    while (closed < open.len and !isCapabilityAncestor(
        version,
        entries[open[open.len - 1 - closed]].path,
        path,
    )) {
        closed += 1;
    }
    return closed;
}

/// Write `set` as a capability object, with no leading or trailing bytes.
///
/// ## What the round trip guarantees
///
/// The agreement is over the set, not over the bytes. A document
/// [`decodeCapabilityObject`] accepted re-encodes to a document that decodes
/// back to the same entries: the same paths, the same forms, the same values,
/// the same `present`, and the same nesting, because the entries are recorded
/// parent first and the nesting is rebuilt from the paths. The bytes are not
/// the source bytes in general: whitespace is dropped and a member name that
/// needed an escape is written with this library's escapes, so
/// `{"terminal": true}` comes back as `{"terminal":true}` and only the
/// canonical spellings the tests pin reproduce their source exactly.
///
/// Two classes of member do not come back, and both are losses the decoder
/// made on the way in rather than choices this function makes:
/// nothing is written for a member that recorded nothing — an explicit `null`,
/// a string, a number, an array — and a member a peer spelled twice is one the
/// walk spent, so the re-encoded document carries the occurrence that was read
/// and not the one that was dropped. That is the same loss every other member
/// walk in this library already makes.
///
/// ## The caller's UTF-8
///
/// Member names are written through `json.Writer.string`, which requires valid
/// UTF-8 and checks nothing in any optimize mode. A name taken off a decoded
/// wire is valid, because `json.Reader.string` validated it; a name inside a
/// hand-built path is the builder's to validate, and an invalid one is written
/// rather than refused, leaving this library's own reader to reject the
/// document with `error.InvalidUtf8`. There is no assert on this path, so
/// nothing catches it in Debug either.
///
/// ## The shape the entries have to have
///
/// `set.entries` is read as a parent-then-child chain in the order the walk
/// recorded it, which is what a decoded set carries and what a hand-built set
/// has to reproduce: every entry that is a descendant of an earlier one comes
/// before any entry that is not. The nesting, the separators and the member
/// names are all read off the paths, so an ordering that is not a chain does
/// not fail — it writes a different document, and one the walk would not have
/// produced. A caller building a set by hand therefore owns that obligation,
/// and the cheapest way to meet it is to decode rather than to spell.
///
/// A v2 `path` must begin with the `capabilities` root, because the root is
/// the member's own name and this function writes the contents of that member.
/// That is `error.InvalidField` rather than a document with dots in a member
/// name: the walk would read such a name back as a path with the root
/// prepended, so the two would disagree about the value.
///
/// [`Capability.known`] is neither read nor written. It is a fact about this
/// library's tables rather than about the wire, so the decoder derives it with
/// [`isKnownCapability`] and the encoder has nothing to say about it. A set
/// built by hand keeps the flag its caller gave it, so a caller that wants the
/// derived answer has to ask [`isKnownCapability`] itself.
///
/// ## Errors, and what is left behind
///
/// Every refusal of the set itself — a `.protocol` side, an entry whose form
/// its version does not declare, a boolean with no value, a presence object
/// with one, a v2 path with no root — is `error.InvalidField` or
/// `error.UnknownTag` and is decided before the first byte is written, so
/// those leave `writer` untouched. A `present = false` set is refused the same
/// way: a capability object *is* the member, and `{}` would decode as a member
/// that was there and advertised nothing, which is `present = true`.
///
/// Nesting is a fact about the set rather than a shortage, so it is refused
/// before the first byte: the capability object is a container too, and
/// [`validateCapabilityDepth`] charges it as one through
/// `capability_object_depth`. That makes a set carrying `json.max_depth - 1`
/// presence objects below the root the deepest this library can read — its
/// members sit at walk depth `json.max_depth` — and one presence object more
/// an `error.InvalidField` no decode could have returned. The bound is over
/// the document this function writes, which is the capability object itself;
/// [`encodeInitializeCapabilities`] charges one more level for the body
/// around it and so refuses a set one level shallower.
///
/// `error.BufferTooSmall` is then the caller's own shortage and has one
/// source: `writer` running out of room. On that path `writer` holds a prefix
/// of the object — up to a complete member, with no closing braces — so a
/// caller discards it and retries with a larger buffer rather than appending
/// to it.
///
/// `set` is only read: nothing is allocated, nothing is retained, and the
/// paths behind the entries have to outlive the call rather than the value.
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
    try validateCapabilitySet(version, side, set, capability_object_depth);
    try writeCapabilityObject(version, set, writer);
}

/// Write `set` as a capability object, with no leading or trailing bytes, for
/// a caller that has already run [`validateCapabilitySet`] for the document
/// it is writing into.
///
/// Both public entry points validate at their actual container depth before
/// calling this writer. The split avoids duplicate validation and prevents the
/// initializer from substituting the weaker standalone depth budget.
fn writeCapabilityObject(
    version: WireVersion,
    set: CapabilitySet,
    writer: *json.Writer,
) EncodeError!void {
    // The set is flat, so the nesting is rebuilt from the paths. The object
    // still open above an entry is its deepest ancestor, which is the last
    // one recorded before it, and `capabilityClosedLevels` is the one place
    // the test for that is asked: here to write the braces, and in
    // `validateCapabilityDepth` to count the depth the same set spends.
    //
    // Indexed by `depth`, which that preflight has already bounded by
    // `json.max_depth` minus the containers around the set, so `open` has a
    // slot for every depth this reaches and nothing here checks it a second
    // time.
    var open: [json.max_depth]usize = undefined;
    var depth: usize = 0;

    try writer.byte('{');
    for (set.entries, 0..) |entry, index| {
        const closed = capabilityClosedLevels(
            version,
            set.entries,
            open[0..depth],
            entry.path,
        );
        for (0..closed) |_| try writer.byte('}');
        depth -= closed;
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
        const key = if (depth == 0) capabilityRootKey(version, entry.path) else capabilityChildKey(
            version,
            set.entries[open[depth - 1]].path,
            entry.path,
        );
        try writer.string(key);
        try writer.byte(':');
        switch (entry.form) {
            // `validateCapabilitySet` has already refused the one value this arm
            // cannot spell — a `.boolean` member with no `value` is
            // `error.InvalidField`, and it is checked before the first byte is
            // written — so the unwrap below is that refusal standing next to
            // the use it protects rather than a second, quieter answer to the
            // same question. Writing `false` here instead would say a member
            // the library refuses to encode advertises "unsupported".
            // zwanzig-disable-next-line: optional-unwrap
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

/// Decode the capability member out of an `initialize` body at `version` for
/// `side`, into `out` and `paths`, using `scratch` for keys.
///
/// The member is optional in every version, so an initialize that advertises
/// nothing decodes to an absent set rather than an error: section 6.5 makes
/// omission mean unsupported, which is a set of no paths. `present` is how a
/// caller tells those two apart from an empty object, and it is the one field
/// [`encodeInitializeCapabilities`] writes differently for them.
///
/// Buffers are the caller's throughout and the result borrows them, exactly as
/// [`decodeCapabilityObject`] documents: every `Capability.path` is a region
/// of `paths`, and the value is valid until the caller writes that buffer or
/// releases it. `out` is written from the front and holds one slot per member
/// the object carries, claims from the back, so `out[0..entries.len]` is the
/// set and the remainder is the walk's own bookkeeping. The nested capability
/// object is borrowed from `raw` rather than copied, so it costs `scratch`
/// nothing and the keys read to find it are dead by the time the nested walk
/// runs — which is why one buffer serves both.
///
/// `error.BufferTooSmall` is the caller's own shortage and nothing else:
/// `out` too small for the members the object carries, `paths` too small for
/// the paths it records, or `scratch` too small for a key. Every other error is
/// a fact about the peer's document — `MalformedJson` for a second value behind
/// the body's closing brace, `Truncated`, `InvalidUtf8`, `MissingField`,
/// `InvalidField` for a member in a form its version does not declare,
/// `LimitExceeded` past `json.max_depth` — which this body is two levels deep
/// before the set begins, because the body is a container and the member is
/// read with `rawValue`, which spends a level opening the object it carries.
/// That is the same budget [`encodeInitializeCapabilities`] charges, so the
/// deepest body it writes is one with `json.max_depth - 2` presence objects
/// below the member, and a set one level deeper than
/// `encodeCapabilityObject` can write is refused here as `LimitExceeded` and
/// there as `error.InvalidField` — and `raw` is untouched on every one of
/// these errors, so the same buffers can be reused for the next document.
///
/// A `.protocol` side is `error.InvalidField`: neither schema gives a
/// capability object to a side-independent method, and the refusal is made
/// before a byte is read.
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

/// Write the capability member of an `initialize` request or response as the
/// whole `initialize` body, and nothing else.
///
/// What it writes is the body `decodeInitializeCapabilities` reads: an
/// object carrying `set` under the member name this version gives `side`, so a
/// body this writes decodes back to `set` with `present` as it was given. The
/// `present = false` case writes `{}`, which is a body with no member at all,
/// and that is the spelling the decoder reads back as absent. It is not the
/// inverse of a whole `initialize` body: that body also carries a protocol
/// version and an info object this module does not model, so a caller writing
/// one composes the two around this rather than calling it alone.
///
/// ## Errors, and what is left behind
///
/// `error.InvalidField` for a `.protocol` side, which neither version gives a
/// capability object to, and for any entry `validateCapabilitySet` refuses.
/// Both are decided before the first byte is written, so they leave `writer`
/// untouched and the caller may reuse the buffer.
///
/// Nesting is one of those refusals, and it is a different answer here than
/// [`encodeCapabilityObject`] gives for the same entries: this writes a whole
/// `initialize` body and the capability object is a member of it, so the
/// preflight runs at `initialize_body_depth` and a set carrying
/// `json.max_depth - 2` presence objects below the member is the deepest this
/// library can read back. One presence object more is `error.InvalidField`
/// with the buffer untouched — the level `decodeInitializeCapabilities` spends
/// on the body and the one it spends reading the member with `rawValue` are
/// both already spent, and a caller composing a larger `initialize` body has
/// to charge whatever it puts around this one.
///
/// `error.BufferTooSmall` is the one tag that can arrive after the brace and
/// the member name are already in the buffer, and it is the caller's own
/// shortage and nothing else: the nested capability object can be asked how
/// many bytes a set needs, but nothing asks it, so a short buffer is
/// discovered by running out of it. On that path `writer` holds a prefix
/// ending in `{"<member>":`, or in as much of the nested object as fitted. The
/// prefix is not a body, so a caller must discard it and retry with a larger
/// buffer rather than append to it.
///
/// Nothing allocates; `set` is only read, and its entries continue to borrow
/// whatever buffers they were decoded into.
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
    // Ahead of the member name rather than left to the nested write, so a set
    // `validateCapabilitySet` refuses leaves the buffer untouched rather than
    // holding `{"capabilities":`. That includes a set nested deeper than any
    // decode can produce, which is a fact about the set rather than a shortage
    // and is refused in the same place, before the member name, as a wrong
    // form. The depth it is asked with is `initialize_body_depth` and not
    // `capability_object_depth`, because this is a whole document with the
    // capability object as one of its members and `json.max_depth` is a budget
    // over the document: the same set that is the deepest thing
    // `encodeCapabilityObject` can write is one level too deep here, and only
    // here. The write below then writes the object without asking the same
    // questions twice, because the second run would be a second depth and so
    // a second answer.
    try validateCapabilitySet(version, side, set, initialize_body_depth);
    try writer.byte('{');
    try writer.string(member);
    try writer.byte(':');
    try writeCapabilityObject(version, set, writer);
    try writer.byte('}');
}

// --- 6.6 Permission options ----------------------------------------------------

/// The `kind` of a permission option, verbatim from the specification.
///
/// The four tags are the wire spellings, and `string` and `fromString` are
/// inverses over all four, so a value read off the wire and a value written
/// from a hand-built option agree on the bytes. What this enum is not is the
/// whole of what a `kind` can be at v2: an `anyOf` plus an `other` branch means
/// a fifth string is a value the schema defines, and
/// [`PermissionOptionKindValue`] is what a decoder returns so the two cannot
/// be confused. At v1 the four are all of them, and a fifth is
/// `error.UnknownTag`.
///
/// It carries no options, no state and no borrow, so a value is freely copied
/// and shared across threads, and there is nothing to release. `allow_always`
/// and `reject_always` say what the user chose for this prompt, not that the
/// library will remember it next time: no state is stored here, so a peer that
/// sent an `allow_always` has still to be asked again unless something above
/// this module remembers the choice.
pub const PermissionOptionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,

    /// The tag whose wire spelling is `text`, or `null` for any other string.
    ///
    /// The comparison is exact and case-sensitive against the four tag names,
    /// so `allow-once`, `allowOnce` and `ALLOW_ONCE` are all `null`. `null` is
    /// not a default kind and never resolves to one: what an unrecognised
    /// string means is the version's business, not this function's, so a caller
    /// that has a string in hand asks [`unknownTagPolicy`] next — that is
    /// exactly what `decodePermissionOptionKind` does. Nothing is retained;
    /// `text` is read and dropped.
    ///
    /// Total and allocation-free. The scan is unrolled at compile time over
    /// the four fields, so it costs at most four byte comparisons.
    pub fn fromString(text: []const u8) ?PermissionOptionKind {
        inline for (@typeInfo(PermissionOptionKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) {
                return @field(PermissionOptionKind, field.name);
            }
        }
        return null;
    }

    /// The wire spelling of this kind, which is also the tag name.
    ///
    /// The inverse of [`PermissionOptionKind.fromString`] over all four tags,
    /// so `PermissionOptionKind.fromString(k.string())` is `k` for every `k`.
    /// The result points at static storage inside this file and is never
    /// released, so a caller may hold it for as long as it likes and needs no
    /// copy to outlive anything.
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
///
/// The union is a tag and, on one arm, a borrow: no allocation, no owner and
/// nothing to release. A copy is a copy of the tag and the slice, so both
/// copies name the same borrowed bytes and neither may outlive them; sharing a
/// value across threads is fine as long as the buffer behind it is not written
/// while it is read. [`encodePermissionOutcome`] takes it by value, so it
/// never retains the borrow past the call.
pub const PermissionOutcome = union(enum) {
    /// The client cancelled. The v1 specification requires this response to
    /// every pending permission request when a `session/cancel` arrives.
    cancelled,
    /// The client chose the option named by `option_id`.
    ///
    /// Borrows the caller's `raw` or `scratch` buffer, whichever the decode put
    /// it in, and is invalidated when that buffer is overwritten or released.
    /// The id is whatever the peer spelled: nothing here checks it against the
    /// option list of the request it answers, because this function never sees
    /// that request. Matching it is the caller's obligation, and an id that is
    /// not on the list is consent to nothing —
    /// `acp_session.readOutcome` is where that check happens and where an
    /// unmatched id is reported rather than read as a grant.
    selected: []const u8,
};

/// Decode a `RequestPermissionOutcome` object out of `raw`, using `scratch`
/// for escaped strings.
///
/// The result borrows: `.{ .selected }`'s id points into `raw` when the string
/// carried no escape and into `scratch` when it did, so both buffers must stay
/// alive and unmodified for as long as the outcome is read. Nothing allocates
/// and there is nothing to release. A caller that needs the id past either
/// buffer has to copy it.
///
/// ## Failing closed
///
/// An `outcome` this library does not know is `error.UnknownTag`, and there is
/// no variant for it. That is the whole point: PROTOCOLS.md section 6.6
/// requires an agent receiving an unrecognised outcome to refuse to treat it
/// as approval, and the only safe surface for that is an error the caller has
/// to handle rather than a value it might match on. The same holds for the
/// contradictions: `error.MissingField` when the `outcome` member is absent or
/// when `selected` names no option, and `error.InvalidField` when `cancelled`
/// carries one. Every one of those is a refusal to interpret the message, not
/// a default and not a cancellation. The `cancelled` answer is reached only
/// from an explicit `"outcome":"cancelled"`, so no input reaches it by
/// omission.
///
/// ## A repeated member
///
/// A repeated member resolves first-wins, as in every other walk in this
/// library. This is the decoder behind the library's central safety rule, so
/// the case is the one `acp_session.readOutcome`'s own test names: a client
/// that answers `cancelled` and then appends the option it wanted would have
/// the grant read and the user shown the refusal. The repeat is stepped over
/// rather than read, so the first occurrence's text stays live.
///
/// `error.BufferTooSmall` is the caller's own buffer being too narrow for an
/// escaped string, and nothing is decoded on that path. Every other error is a
/// fact about the peer's document — `MalformedJson`, `Truncated`,
/// `InvalidUtf8`, `MissingField`, `InvalidField`, `UnknownTag` — and `raw` is
/// untouched either way, so a caller may fix the buffer and try again.
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
            if (branch != null) {
                try reader.skipValue(scratch);
                continue;
            }
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
            // First-wins here too, or an outcome could name an option other
            // than the one it was answered with.
            if (option_id != null) {
                try reader.skipValue(scratch);
            } else {
                option_id = try reader.string(scratch);
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    // An outcome is one JSON value, and this is the one decoder in this file
    // whose encoder can spell every value it returns. A tail behind the closing
    // brace would be bytes no encoder writes, so accepting it would mean a
    // document decoded successfully and then silently lost its tail on the way
    // back out: the truncated bytes still decode, so nothing downstream would
    // report it. `jsonrpc.decode` refuses the same document for the same
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
///
/// Every arm borrows. The two string arms point into the caller's `raw` or
/// `scratch`, and the `command` arm is a struct of borrows rather than owned
/// bytes, so nothing here allocates, nothing needs releasing, and copying the
/// value copies the handles rather than the text: both copies name the same
/// bytes and both die with them. What invalidates a subject is writing or
/// releasing the buffer behind any field, and reading it is safe from any
/// thread as long as no one writes that buffer meanwhile. A subject read from
/// a document is valid only as long as that document and its scratch buffer
/// are.
///
/// There is no variant for a subject the schema does not define: `.{ .other }`
/// is the schema's own catch-all, and it is a value the caller must decide
/// what to do with rather than one this module interpreted. What a *user* was
/// shown is not recorded here — no arm says whether the prompt was renderable —
/// which is why `acp_session` refuses the catch-all outright when it writes a
/// prompt rather than carrying it.
pub const PermissionSubject = union(enum) {
    /// Carries a required `toolCall`, as borrowed JSON text.
    ///
    /// The library does not model `ToolCallUpdate`, so the object is carried
    /// verbatim instead of being flattened into fields this module would then
    /// have to keep in step with the schema. The slice is exactly one JSON
    /// object value and nothing more: the decoder takes it with `rawValue`,
    /// which proves the value was complete, and the encoder refuses a lexeme
    /// that is not one object, so a member this library splices in cannot hide
    /// a second document. It is written out verbatim, whitespace and all.
    tool_call: []const u8,
    /// Carries a required `command` and a required **absolute** `cwd`.
    ///
    /// The struct is a value, so reading `.command.subject` copies four
    /// borrows; see the type for what that does and does not buy.
    command: CommandSubject,
    /// Any other `type` string. The other members of the object are the peer's
    /// and this module reads none of them, so a subject read from a document
    /// that had them re-encodes to `{"type":"…"}`. Carrying them would mean a
    /// lexeme on this arm, and `acp_session` and `testkit` construct and match
    /// on it; [`encodePermissionSubject`] records the loss and what closing it
    /// would take.
    other: []const u8,
};

/// The `command` arm of a v2 permission subject.
///
/// Every field is a borrow out of the caller's decode buffers, so the struct
/// owns nothing and a copy is a copy of the handles rather than of the text.
/// `command` and `cwd` are the two the schema requires; the two optionals are
/// the peer saying which tool call and which terminal this belongs to, and
/// there is no third state for them here — a member the peer spelled `null`
/// reads as `null` and re-encodes with the member absent, which
/// [`encodePermissionSubject`] records as a decoder-side loss.
pub const CommandSubject = struct {
    /// The command line, required. It is the text a user is approving, and
    /// this module does not parse or rewrite it: what the peer spelled is what
    /// the user was shown.
    command: []const u8,
    /// The working directory, required and **absolute**.
    ///
    /// A relative path is `error.InvalidField` on the way in and
    /// `error.InvalidField` on the way out, because the schema types this
    /// member as an `AbsolutePath` and because a relative path would resolve
    /// against whatever working directory the process running the command
    /// happens to have — so the user approving a command in one directory
    /// would approve it in another. [`isAbsolutePath`] is the test, and
    /// [`encodePermissionSubject`] is where a relative one is refused.
    cwd: []const u8,
    /// The tool call this command belongs to, when the agent named one. `null`
    /// when the agent named none, and also when it named one as `null`; the
    /// two are one state here, and the wire spelling of the second is not
    /// reproduced on the way back out.
    tool_call_id: ?[]const u8 = null,
    /// The terminal this command runs in, when the agent named one. `null`
    /// carries the same two meanings as `tool_call_id`.
    terminal_id: ?[]const u8 = null,
};

/// The v2 permission subject discriminator strings.
///
/// These are the two arms [`PermissionSubject`] models, by the exact spelling
/// a `type` member carries. A name-holder over static wire spellings: it owns
/// nothing, allocates nothing and is never released. A `type` outside this pair
/// is not an error — it is the schema's `other` branch, and
/// [`PermissionSubject.other`] is where it lands.
pub const permission_subject_type = struct {
    pub const tool_call = "tool_call";
    pub const command = "command";
};

/// Whether `path` is an absolute POSIX path, by its first byte.
///
/// The v2 `CommandPermissionSubject.cwd` is an `AbsolutePath`, so a relative
/// `cwd` is a value the schema does not permit. It matters beyond the schema:
/// a relative path would resolve against whatever working directory the
/// process that runs the command happens to have, so the user approving a
/// command in one directory would approve it in another.
///
/// This is the leading `/` and nothing more, so it is a shape test rather than
/// a validation of the path: a leading `/` followed by `..` is absolute by this
/// rule, a POSIX path with no leading slash is never absolute by it, and a
/// Windows or UNC spelling is not one this function recognises. The schema
/// types the member the same way this library checks it, so the two agree, and
/// a caller that needs a resolved path has to resolve it — nothing here touches
/// the file system.
///
/// Total, allocation-free, and an empty `path` is `false` rather than an error.
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

/// Decode a v2 `RequestPermissionSubject` object out of `raw`, using `scratch`
/// for escaped strings and for keys.
///
/// The result borrows. `.{ .tool_call }`'s lexeme and `.{ .other }`'s tag point
/// into `raw`; a `.{ .command }` field points into `raw` where its string
/// carried no escape and into `scratch` where it did. Both buffers must stay
/// alive and unmodified while the subject is read, and nothing is allocated or
/// released.
///
/// The `type` member is required and selects the arm. A missing or malformed
/// required member of a known arm is a decode error — `error.MissingField` for
/// an absent one, `error.InvalidField` for a `toolCall` that is not an object or
/// a `cwd` that is not absolute — while an unknown `type` is not an error,
/// because the v2 schema defines the catch-all that receives it. That is the
/// difference from [`decodePermissionOutcome`], whose union has no catch-all in
/// either version: here an unrecognised discriminator is a value to carry, and
/// there it is an error to surface.
///
/// A repeated member resolves first-wins, as in every other walk in this
/// library. `tool_call` and `command` are different requests to put in front of
/// a user, and `command` is a line a user approves, so a peer that names either
/// twice must not be able to choose which one the library shows. The repeat is
/// stepped over rather than read, so the first occurrence's text stays live in
/// the caller's scratch.
///
/// `error.BufferTooSmall` is the caller's own buffer being too narrow for a key
/// or an escaped string; nothing is decoded on that path. Every other error is
/// a fact about the peer's document, and `raw` is untouched either way.
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
    var saw_tool_call_id = false;
    var saw_terminal_id = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "type")) {
            if (tag != null) {
                try reader.skipValue(scratch);
            } else {
                tag = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "toolCall")) {
            if (tool_call != null) {
                try reader.skipValue(scratch);
            } else {
                tool_call = try reader.rawValue(scratch);
            }
        } else if (std.mem.eql(u8, key, "command")) {
            if (saw_command) {
                try reader.skipValue(scratch);
            } else {
                subject.command = try reader.string(scratch);
                saw_command = true;
            }
        } else if (std.mem.eql(u8, key, "cwd")) {
            if (saw_cwd) {
                try reader.skipValue(scratch);
            } else {
                subject.cwd = try reader.string(scratch);
                saw_cwd = true;
            }
        } else if (std.mem.eql(u8, key, "toolCallId")) {
            // The flag rather than the value, because a first `null` reads the
            // same as an absent member and would leave nothing to guard the
            // second one with.
            if (saw_tool_call_id) {
                try reader.skipValue(scratch);
            } else {
                subject.tool_call_id = try nullableString(&reader, scratch);
                saw_tool_call_id = true;
            }
        } else if (std.mem.eql(u8, key, "terminalId")) {
            if (saw_terminal_id) {
                try reader.skipValue(scratch);
            } else {
                subject.terminal_id = try nullableString(&reader, scratch);
                saw_terminal_id = true;
            }
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
/// `depth` charges enclosing objects: one for a standalone subject or v1
/// request, two for a subject nested in a v2 request.
fn isJsonObject(text: []const u8, depth: u32) bool {
    var reader = json.Reader.init(text);
    reader.depth = depth;
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
fn validatePermissionSubject(subject: PermissionSubject, depth: u32) EncodeError!void {
    switch (subject) {
        .tool_call => |call| {
            if (!isJsonObject(call, depth)) return error.InvalidField;
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

/// Write `subject` as a v2 `RequestPermissionSubject` object, with no
/// leading or trailing bytes.
///
/// Every value [`decodePermissionSubject`] can return is written, and the three
/// subjects that decoder refuses are refused here before the first byte
/// lands: a `tool_call` lexeme that is not exactly one JSON object, a
/// `command` whose `cwd` is not absolute, and an `other` tag naming a
/// modelled arm.
///
/// ## What the round trip does not carry
///
/// The guarantee is over the subject, not over the document it arrived in, and
/// there are two classes of input the pair reads differently. The catch-all arm
/// carries the `type` and nothing else, so a subject read from a document with
/// members of its own re-encodes to `{"type":"…"}`; and `nullableString` reads
/// an explicit `null` on `toolCallId` or `terminalId` as the absent case, so a
/// document that spelled one `null` re-encodes without the member. What is lost
/// is gone before any encoder sees the result, so refusing those values would
/// not help; both have to be carried by [`PermissionSubject`] and
/// [`CommandSubject`], which is a change to the shapes rather than to this
/// function. Carrying them means a lexeme on the `.other` arm and a third state
/// on the two optionals, and `src/acp_session.zig` and `src/testkit.zig` both
/// construct and match on the arms that would move.
///
/// Everything this writes is the same on both sides of that loss: the same
/// arm, the same members, the same order, and the same `type`, so the bytes
/// here decode back to the value that was written. They are not the source
/// bytes in general — whitespace is dropped, a string is re-escaped, and a
/// `toolCall` is the one member written verbatim — so only the canonical
/// spellings the tests pin reproduce their source exactly.
///
/// ## The caller's UTF-8
///
/// The `.other` tag and every `CommandSubject` field are written through
/// `json.Writer.string`, which requires valid UTF-8 and checks nothing in any
/// optimize mode. Strings from [`decodePermissionSubject`] are valid, because
/// `json.Reader.string` validated them; a `PermissionSubject` a caller built by
/// hand carries its own obligation, and an invalid one is written rather than
/// refused, leaving this library's own reader to reject the document with
/// `error.InvalidUtf8`. The absolute-path check on `cwd` is not a UTF-8 check
/// and does not become one. There is no assert on these paths, so nothing
/// catches it in Debug either.
///
/// `acp_session.writePermissionSubject` takes the opposite line again and
/// refuses the catch-all outright, because there the missing members would be a
/// request the agent never described.
///
/// ## Errors, and what is left behind
///
/// `error.InvalidField` for the three subjects above, and it is decided before
/// the first write, so it leaves `writer` untouched. `error.BufferTooSmall` is
/// the only tag that arrives mid-document: `writer` then holds a prefix of the
/// subject, which is not an object, so a caller discards it and retries with a
/// larger buffer. `subject` is only read here — nothing is allocated, nothing
/// is retained, and the borrows behind it have to outlive the call, not the
/// value.
///
/// The `tool_call` arm splices one complete JSON object verbatim. Its nesting
/// is checked at the field's actual write position. A malformed lexeme,
/// trailing value or excess nesting is `InvalidField` before writing.
pub fn encodePermissionSubject(
    subject: PermissionSubject,
    writer: *json.Writer,
) EncodeError!void {
    try validatePermissionSubject(subject, 1);
    try writePermissionSubject(subject, writer);
}

fn writePermissionSubject(subject: PermissionSubject, writer: *json.Writer) EncodeError!void {
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

/// Write `outcome` as a `RequestPermissionOutcome` object, with no leading or
/// trailing bytes.
///
/// This is the one decoder/encoder pair in this module that carries every
/// member its shape models: a value [`decodePermissionOutcome`] returned
/// re-encodes to the same object, so what survives the round trip is the whole
/// of what the shape holds. Members no schema models are still dropped, because
/// a member the decoder stepped over has no field to land in — which is what
/// makes `decodePermissionOutcome` refuse a tail behind the closing brace,
/// since a document this could not write back whole is not one it should have
/// accepted.
///
/// The bytes are not the source bytes in general: whitespace is dropped and
/// `optionId` is re-escaped, so `{"outcome": "selected","optionId":"A"}` comes
/// back as `{"outcome":"selected","optionId":"A"}`. Only the canonical
/// spellings the tests pin reproduce their source exactly, and a caller must
/// not compare bytes.
///
/// ## The caller's UTF-8
///
/// The `.selected` id is written through `json.Writer.string`, which requires
/// valid UTF-8 and checks nothing in any optimize mode. An id from
/// [`decodePermissionOutcome`] is valid, because `json.Reader.string` validated
/// it; one a caller built by hand is its own to validate, and an invalid one
/// is written rather than refused, leaving this library's own reader to reject
/// the document with `error.InvalidUtf8`. There is no assert on this path, so
/// nothing catches it in Debug either.
///
/// `outcome` is taken by value and only read: nothing is allocated, nothing is
/// retained, and a `.selected` id has to outlive the call rather than the
/// value.
///
/// There is no validation and so no `error.InvalidField` here — every value
/// this function can be handed is one the decoder can read back, including an
/// empty id, which is an option id and not a missing one.
/// `error.BufferTooSmall` is the only error, and it comes from `writer` after
/// the first bytes have landed: `writer` then holds a prefix of the object,
/// which is not an outcome, so a caller discards it and retries with a larger
/// buffer rather than appending to it.
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
///
/// It is a tag plus, on the `.other` arm, a borrow of the peer's own text. A
/// copy is a copy of that handle rather than of the string, nothing is
/// allocated or released, and the `.other` text stays valid exactly as long as
/// the decode buffer behind it.
pub const PermissionOptionKindValue = union(enum) {
    /// One of the four named kinds.
    known: PermissionOptionKind,
    /// A kind the library does not name, which only v2 can deliver. Borrows
    /// the caller's decode buffer and is written back out exactly as it
    /// arrived; there is no arm to give it a meaning, so a caller that has to
    /// decide whether the option grants asks [`PermissionOption.grants`],
    /// which answers `null` here rather than guessing either way.
    other: []const u8,
};

/// One `PermissionOption` of a request.
///
/// `required: ["optionId", "name", "kind"]` in both versions, and the v2
/// request adds no member to it. These three are what the user reads and what
/// an outcome names back, so the decoder keeps them apart instead of collapsing
/// the option into its kind.
///
/// Every field is a borrow. `option_id` and `name` point into the caller's
/// decode buffers, and `kind` may carry a borrow on its `.other` arm, so an
/// option read from a document dies with the buffers that document was decoded
/// into and a copy is a copy of the handles rather than of the text. An option
/// array this module did not decode is a caller's own storage and outlives
/// whatever the caller keeps it in.
pub const PermissionOption = struct {
    /// The id an outcome names back. What the peer spelled, neither
    /// normalised nor checked: it is compared against the ids of the options
    /// in the request it answers, and an id on no such list is a refusal
    /// rather than a grant.
    option_id: []const u8,
    /// The text the user is shown for this choice. This module does not render
    /// it and does not inspect it, so what the peer spelled is what a UI above
    /// this one displays.
    name: []const u8,
    /// What choosing this option means, as the version's schema defines it.
    kind: PermissionOptionKindValue,

    /// Whether choosing this option grants the action, or null when the kind is
    /// one this library does not name.
    ///
    /// Null rather than false, because v2's catch-all means a kind can arrive
    /// that the schema defines and this library does not, and answering "does
    /// not grant" for it would be the same guess as answering "grants". A
    /// caller that has to act on this cannot treat `null` as a refusal either:
    /// the only safe reading of an uninterpretable kind is that this module
    /// does not know, and `acp_session.readOutcome` reports it as
    /// `error.UnknownTag` rather than deciding. Total and allocation-free, and
    /// it reads nothing but the kind.
    pub fn grants(self: PermissionOption) ?bool {
        return switch (self.kind) {
            .known => |kind| kind.grants(),
            .other => null,
        };
    }
};

/// The v1 `session/request_permission` request.
///
/// Every member is a borrow: `session_id` and `tool_call` point into the
/// caller's decode buffers, and `options` borrows the array the caller passed to
/// [`decodePermissionRequest`]. Nothing is allocated and nothing needs
/// releasing; a copy is a copy of the handles.
pub const PermissionRequestV1 = struct {
    /// The session the request belongs to, named in the path of the call and
    /// repeated in the body. The two are not compared by this module.
    session_id: []const u8,
    /// The `ToolCallUpdate`, carried as borrowed JSON text. This module does
    /// not model a tool call, so flattening the object would create a second
    /// definition to keep in step with the schema. The slice is exactly one
    /// JSON object value: the decoder proves it with `rawValue` and a leading
    /// `{`, and the encoder refuses a lexeme that is not one object, so
    /// nothing spliced through this member can hide a second document.
    tool_call: []const u8,
    /// The offered choices. v1 puts no `minItems` on the array, so an empty one
    /// is well formed.
    ///
    /// Borrows `out_options[0..count]` from [`decodePermissionRequest`], so the
    /// array a caller supplied outlives the request and the entries inside it
    /// are valid only while that array is untouched. Options past the count
    /// are never written and never reachable through this slice.
    options: []const PermissionOption,
};

/// The v2 `session/request_permission` request.
///
/// Every member is a borrow, on the same terms as [`PermissionRequestV1`]:
/// nothing is allocated, nothing needs releasing, and the value is valid
/// exactly as long as the buffers it was decoded into.
pub const PermissionRequestV2 = struct {
    /// The session the request belongs to.
    session_id: []const u8,
    /// Required in v2: the prompt the user reads before choosing. v1 has no
    /// such member, and the tool call moves out of the request root and into
    /// the subject.
    title: []const u8,
    /// Free text below the title. `null` is the absent case: a peer that
    /// spelled the member `null` and a peer that omitted it are one state
    /// here, and the explicit spelling does not come back on the way out.
    description: ?[]const u8,
    /// Omitted and `null` both mean no structured subject, so the two agree,
    /// and the same loss applies: a `null` the peer spelled re-encodes with the
    /// member absent. See [`PermissionSubject`] for what a subject borrows.
    subject: ?PermissionSubject,
    /// The offered choices. v2 adds `"minItems": 1`, so an empty array is a
    /// request the user cannot answer: it is `error.InvalidField` on the way in
    /// and on the way out.
    ///
    /// Borrows `out_options[0..count]` from [`decodePermissionRequest`], on the
    /// same terms as [`PermissionRequestV1.options`].
    options: []const PermissionOption,
};

/// A permission request of one wire version.
///
/// The tag is the wire version rather than a library enum, because the two
/// requests share no required member: v1 requires `toolCall` and v2 requires
/// `title`. One struct carrying both would invite a reader to accept a request
/// the peer never sent. The tag also names the version the request was
/// decoded at, which is what lets [`encodePermissionRequest`] write it without
/// being told a second time.
///
/// Both arms are pure borrows, so the union owns nothing, a copy is a copy of
/// the handles rather than of the text, and nothing here needs releasing. The
/// value is valid exactly as long as the buffers [`decodePermissionRequest`]
/// decoded it into, and reading it from another thread is safe so long as no
/// one writes those buffers meanwhile.
pub const PermissionRequest = union(WireVersion) {
    stable: PermissionRequestV1,
    draft: PermissionRequestV2,
};

/// Decode the body of a `session/request_permission` for `version` out of
/// `raw`, into `out_options`, using `scratch` for keys and escaped strings.
///
/// Nothing allocates. The caller owns all three buffers and the result borrows
/// them, so the request is valid exactly as long as they are unchanged:
///
/// - `out_options` receives one [`PermissionOption`] per element of the
///   `options` array, and the result's `options` is `out_options[0..count]`
///   over it. Slots past the count are never written, so a caller that sizes
///   the array larger than the array on the wire keeps the remainder as it
///   was rather than reading a stale entry.
/// - `scratch` is the reader's escape buffer. A string carrying no escape is
///   borrowed from `raw` instead and costs `scratch` nothing, which is why the
///   result's slices may point into either buffer. The reader's high-water mark
///   never rewinds, so two strings read from one document never alias, and a
///   v2 `subject` is decoded into the unread tail so its fields cannot land on
///   top of the ids, title and description already handed out.
/// - `raw` is only read, and the lexemes a `toolCall` and a `subject` arrive
///   as are slices of it.
///
/// ## Errors, and what is left behind
///
/// `error.BufferTooSmall` in two cases, both the caller's own shortage and both
/// with the same rule: the options read so far stay in `out_options[0..count]`
/// and must be discarded, because the returned count never arrives and a
/// partially filled choice list is not a request. One is an `options` array
/// longer than the caller's array; the other is a key or an escaped string
/// wider than `scratch`. A request with more options than the caller reserved
/// is reported rather than truncated, because a truncated choice list would
/// hide the option the user wanted to pick.
///
/// Every other error is a fact about the peer's document, and `raw` and
/// `out_options` are as the caller supplied them beyond the entries already
/// written: `error.MissingField` for an absent `sessionId`, `options`, or a
/// member a required arm needs, `error.InvalidField` for a v2 empty choice
/// list, a `toolCall` that is not an object, a `cwd` that is not absolute or
/// the contradictory member set the subject check rejects, and the JSON-level
/// tags the reader raises. A member this module does not model is stepped over
/// rather than refused, which is what the version's open objects allow.
///
/// ## A repeated member
///
/// A repeated member resolves first-wins, as in every other walk in this
/// library. The tool call is what the agent shows the user and what
/// `encodePermissionRequest` writes back, and the option ids are what an
/// answer is matched against, so a peer that spells either twice must not be
/// able to choose which one the library acts on. The repeat is stepped over
/// rather than read, which also keeps a second `options` array from writing
/// over the entries the first one left in the caller's array, and from
/// replacing a count the first one set with one that satisfies `minItems`.
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
    // The flag rather than the value, because a first `null` reads the same as
    // an absent member and would leave nothing to guard the second one with.
    var saw_description = false;
    var tool_call: ?[]const u8 = null;
    var subject_text: ?[]const u8 = null;
    var option_count: usize = 0;
    var saw_options = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "sessionId")) {
            if (session_id != null) {
                try reader.skipValue(scratch);
            } else {
                session_id = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "title")) {
            if (title != null) {
                try reader.skipValue(scratch);
            } else {
                title = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "description")) {
            if (saw_description) {
                try reader.skipValue(scratch);
            } else {
                description = try nullableString(&reader, scratch);
                saw_description = true;
            }
        } else if (std.mem.eql(u8, key, "toolCall")) {
            // v1 only, and borrowed raw text, so it costs no scratch.
            if (tool_call != null) {
                try reader.skipValue(scratch);
            } else {
                tool_call = try reader.rawValue(scratch);
            }
        } else if (std.mem.eql(u8, key, "subject")) {
            if (subject_text != null) {
                try reader.skipValue(scratch);
            } else {
                subject_text = try reader.rawValue(scratch);
            }
        } else if (std.mem.eql(u8, key, "options")) {
            if (saw_options) {
                try reader.skipValue(scratch);
            } else {
                option_count = try decodePermissionOptions(
                    version,
                    &reader,
                    out_options,
                    scratch,
                );
                saw_options = true;
            }
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

/// Write `request` as the body of a `session/request_permission`, for the
/// version its own tag names and with no leading or trailing bytes.
///
/// Every value [`decodePermissionRequest`] can return is written, and every
/// value this refuses is one that decoder could not have returned: a v2
/// request with no option to choose from, a `toolCall` that is not one JSON
/// object, a subject the subject check refuses, and an option `kind` that the
/// version's schema does not define. The version is not a parameter because
/// the tag already is one, so a caller cannot write a v1 body under a v2 tag
/// or the other way round.
///
/// ## What the round trip does not carry
///
/// The guarantee is over the request, not over the document it arrived in, and
/// there are two classes of input the pair reads differently. An omitted member
/// and an explicit `null` are read as one, so a `description` or a `subject`
/// the peer spelled `null` re-encodes with the member absent; and the other
/// version's member is stepped over rather than read, so a v1 request carrying
/// `title`, `description` or `subject`, or a v2 one carrying `toolCall`,
/// re-encodes without it. What was lost is gone before any encoder sees the
/// result, so refusing either would not help; the first has to be carried by
/// [`PermissionRequestV2`], which would need a third state on two members, and
/// the second by both arms. `src/acp_session.zig` and `src/testkit.zig` build
/// and compare both, so that shape change is theirs to make with this one.
///
/// Everything this writes is the same on both sides of that loss: the same
/// tag, the same members, the same presence, and the same option list in the
/// same order, so the bytes here decode back to the value that was written.
///
/// They are not the source bytes in general, and the reasons are three
/// separate ones. Whitespace is dropped and a string is re-escaped, so
/// `{"sessionId": "s1", …}` comes back without the space. Member order inside
/// the request is this function's, not the peer's, so a document whose members
/// arrived in another order comes back in the order here — the same order the
/// decoder reads in either. And a `toolCall` is written verbatim, so it alone
/// keeps whatever whitespace its own object carried. Only the canonical
/// spellings the tests pin reproduce their source exactly, and a caller must
/// not compare bytes.
///
/// ## The caller's UTF-8
///
/// `sessionId`, `title`, `description`, an option's `optionId`, `name` and
/// `kind` text are written through `json.Writer.string`, which requires valid
/// UTF-8 and checks nothing in any optimize mode. Every one of them from
/// [`decodePermissionRequest`] is valid, because `json.Reader.string` validated
/// it; a `PermissionRequest` a caller built by hand carries its own
/// obligation, and an invalid one is written rather than refused, leaving this
/// library's own reader to reject the document with `error.InvalidUtf8`. There
/// is no assert on these paths, so nothing catches it in Debug either. The
/// `toolCall` and `subject` members are the exception: they are written
/// verbatim and what they must be is one complete JSON value, which the check
/// below establishes.
///
/// ## Errors, and what is left behind
///
/// The whole request is checked before the first byte is written. A refusal
/// halfway through would leave `{"sessionId":"s1","title":"t` in the caller's
/// buffer, which is neither a request nor nothing, so a caller that sized the
/// buffer for the refusal would have to discard what it holds rather than
/// read it. `error.InvalidField` for a request shape the decoder refuses and
/// `error.UnknownTag` for a v1 option `kind` outside the closed union both
/// therefore leave `writer` untouched and the buffer reusable.
///
/// `error.BufferTooSmall` is the one tag that arrives mid-document: `writer`
/// then holds a prefix of the request, which is not an object, so a caller
/// discards it and retries with a larger buffer rather than appending to it.
///
/// The request is only read here. Nothing is allocated, nothing is retained,
/// and the borrows behind its fields — the option array included — have to
/// outlive the call rather than the value.
///
/// The `toolCall` member is spliced in verbatim rather than re-encoded, so the
/// validity of the whole document rests on that lexeme being one complete JSON
/// object. That is the check above, and it is why a lexeme carrying a second
/// value behind it, or one the reader never finished, is refused rather than
/// written.
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
            if (!isJsonObject(value.tool_call, 1)) return error.InvalidField;
            for (value.options) |option| try validatePermissionOption(.stable, option);
        },
        .draft => |value| {
            // v2 names `minItems: 1`, so a request the user cannot answer is
            // not a request at all.
            if (options.len == 0) return error.InvalidField;
            if (value.subject) |subject| try validatePermissionSubject(subject, 2);
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
                try writePermissionSubject(subject, writer);
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
        // First-wins for each member, as in every other walk in this library.
        // The option id is what an answer is matched against and the kind is
        // what decides whether it grants, so a peer that spells either twice
        // must not be able to choose which one the caller acts on. The repeat
        // is stepped over rather than read, so the first occurrence's text
        // stays live in the caller's scratch.
        if (std.mem.eql(u8, key, "optionId")) {
            if (saw_id) {
                try reader.skipValue(scratch);
            } else {
                option.option_id = try reader.string(scratch);
                saw_id = true;
            }
        } else if (std.mem.eql(u8, key, "name")) {
            if (saw_name) {
                try reader.skipValue(scratch);
            } else {
                option.name = try reader.string(scratch);
                saw_name = true;
            }
        } else if (std.mem.eql(u8, key, "kind")) {
            if (saw_kind) {
                try reader.skipValue(scratch);
            } else {
                option.kind = try decodePermissionOptionKind(version, reader, scratch);
                saw_kind = true;
            }
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
/// form-only capability. The two tags are also the two halves of the gate on
/// `elicitation/create` — see [`isMethodSupported`], where either one enables
/// the method — so a caller cannot treat an unknown mode as form: there is no
/// third value, and `null` from `fromString` is the answer to give.
///
/// Carries no options and no borrow, so a value is freely copied, shared
/// across threads and stored anywhere; there is nothing to release. The tag
/// names are the wire spellings, so `string` and `fromString` are inverses over
/// both.
pub const ElicitationMode = enum {
    form,
    url,

    /// The mode whose wire spelling is `text`, or `null` for any other string.
    ///
    /// The comparison is exact and case-sensitive against
    /// [`elicitation_modes`], so `Form`, `FORM` and `form-url` are all `null`.
    /// `null` is not a default mode and never resolves to one: the table holds
    /// exactly the two the schema names, and a string outside it is a mode this
    /// library does not know — at v2 it lands in the schema's catch-all through
    /// [`classifyElicitationMode`], and that answer is the caller's to carry,
    /// not this function's to invent.
    ///
    /// Total and allocation-free, and nothing is retained: `text` is read
    /// against a comptime table of static strings and dropped.
    pub fn fromString(text: []const u8) ?ElicitationMode {
        for (elicitation_modes, 0..) |name, index| {
            if (std.mem.eql(u8, text, name)) return @enumFromInt(index);
        }
        return null;
    }

    /// The wire spelling of this mode, read out of [`elicitation_modes`].
    ///
    /// The inverse of [`ElicitationMode.fromString`] over both tags. The
    /// comptime check after this enum is what makes the indexing sound: it
    /// fails the build when the table and the enum name different modes, rather
    /// than letting `string` read past the end of the table or silently
    /// mis-spell a tag. The result points at static storage inside this file,
    /// so it is never released and outlives anything the caller holds.
    pub fn string(self: ElicitationMode) []const u8 {
        return elicitation_modes[@intFromEnum(self)];
    }
};

comptime {
    if (elicitation_modes.len != @typeInfo(ElicitationMode).@"enum".fields.len) {
        @compileError("elicitation_modes and ElicitationMode must name the same modes");
    }
}

/// The elicitation response actions, in the spelling the schema names them.
///
/// The three tags are the wire spellings, so `string` and `fromString` are
/// inverses over all of them. `decline` and `cancel` are different answers and
/// the wire keeps them apart: a decline is the user saying no to the question
/// that was asked, and a cancel is the user abandoning the elicitation. A
/// caller that collapses them changes what a session records about why a turn
/// ended, so this type does not offer a way to.
///
/// Carries no options and no borrow, so a value is freely copied, shared
/// across threads and stored anywhere; there is nothing to release.
///
/// There is no fourth arm, and that is deliberate. The specification requires
/// that an unrecognised action never be treated as acceptance — the same rule
/// PROTOCOLS.md section 6.6 states for a permission outcome — so `fromString`
/// answers `null` and a caller that has to act on it must report what it could
/// not read rather than substituting `.accept`.
pub const ElicitationAction = enum {
    accept,
    decline,
    cancel,

    /// The action whose wire spelling is `text`, or `null` for any other
    /// string.
    ///
    /// The comparison is exact and case-sensitive against the three tag names,
    /// so `Accept` and `ACCEPT` are `null` as well. `null` means "not one of
    /// the three", never "the nearest of the three": an action this library
    /// does not name is a value the schema may still define at v2, and reading
    /// it as `.accept` is the guess section 6.6 forbids. Nothing is retained;
    /// `text` is read and dropped.
    ///
    /// Total and allocation-free.
    pub fn fromString(text: []const u8) ?ElicitationAction {
        if (std.mem.eql(u8, text, "accept")) return .accept;
        if (std.mem.eql(u8, text, "decline")) return .decline;
        if (std.mem.eql(u8, text, "cancel")) return .cancel;
        return null;
    }

    /// The wire spelling of this action, which is also the tag name.
    ///
    /// The inverse of [`ElicitationAction.fromString`] over all three tags, so
    /// `ElicitationAction.fromString(a.string())` is `a` for every `a`. The
    /// result points at static storage inside this file and is never released,
    /// so a caller may hold it for as long as it likes and needs no copy to
    /// outlive anything.
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

/// Whether `version` admits a batch array on the wire.
///
/// v2 permits batch arrays and v1 does not. The one-entry minimum a v2 batch
/// carries is a fact about a batch decoder, and this module has none: it does
/// not decode a batch, does not count its entries and does not decide what an
/// empty array answers, so a constant here would bound nothing. The only batch
/// decision this module makes is the one below, and [`no_batch_methods`] is
/// advice to a caller rather than a rule anything here applies.
///
/// Total, allocation-free, and it says nothing beyond the version. A `true`
/// is the schema's permission to put several JSON-RPC values in one frame; what
/// may go in them is [`advisesAgainstBatching`] and the caller's own policy.
pub fn permitsBatch(version: WireVersion) bool {
    return version == .draft;
}

/// The methods the specification says should not go inside a batch array.
///
/// The list is the source's own, and it is a `SHOULD NOT`: clients and agents
/// are advised against batching these because each one changes session state
/// in a way whose result a later entry in the same array depends on. Nothing
/// here enforces it, and this library does not refuse a batch.
///
/// PROTOCOLS.md section 6.1 records only that v2 additionally permits batch
/// arrays; the method list comes from the deeper source the table at
/// `research/normative/acp-v1-v2.md` line 723 cites. That list names
/// `initialize`, `auth/login`, `session/new`, `session/resume` and
/// `session/prompt`. `authenticate` is here because it is the v1 spelling of
/// `auth/login` and this table is consulted without a version, so a caller
/// holding either name gets the same answer. Neither logout method is here:
/// the source names none, and adding one would be this library's judgment
/// rather than the specification's.
///
/// The entries are comptime static strings and the table owns nothing, so
/// nothing is released and a caller may hold a slice of it indefinitely.
pub const no_batch_methods = [_][]const u8{
    "initialize",
    "auth/login",
    "authenticate",
    "session/new",
    "session/resume",
    "session/prompt",
};

/// Whether the specification advises against putting `name` inside a batch
/// array. An advisory, not a gate.
///
/// The comparison is exact and case-sensitive against [`no_batch_methods`], so
/// a name the peer invented is `false` rather than an error, and a name this
/// library knows under a different spelling at the other version is `false`
/// too — which is why the table carries both spellings of the login method.
///
/// `true` means the source lists this method and nothing more: it is not a
/// refusal, and no decoder in this library acts on it. `false` does not mean
/// the method is safe to batch either — it means the specification is silent
/// about it, and a caller that wants a stricter rule than the source states
/// applies its own. Neither answer consults a [`WireVersion`], because the
/// table already spans both.
///
/// Total and allocation-free, over a comptime table of static strings, and
/// `name` is only read.
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

test "a frame split off the input borrows it and a partial arrival is not a refusal" {
    const input = "{\"a\":1}\n";
    const first = try nextFrame(input);
    // `bytes` and `rest` are two views of one buffer: `rest` starts one byte
    // past the delimiter that ended `bytes`, and neither is a copy.
    try testing.expectEqual(@intFromPtr(input.ptr), @intFromPtr(first.bytes.ptr));
    try testing.expectEqual(@intFromPtr(input.ptr) + first.bytes.len + 1, @intFromPtr(first.rest.ptr));
    try testing.expectEqual(@as(usize, input.len), first.bytes.len + first.rest.len + 1);

    // No delimiter at all is a partial arrival, not a malformed frame: the whole
    // input is the bytes, `rest` is empty and the flag says the frame is not
    // finished yet. Nothing was consumed and nothing was refused.
    const partial = try nextFrame("{\"a\":");
    try testing.expectEqualStrings("{\"a\":", partial.bytes);
    try testing.expectEqualStrings("", partial.rest);
    try testing.expect(partial.unterminated);

    // An empty input is the same case at zero bytes, and so is a blank line:
    // both are reported, neither is a refusal.
    const none = try nextFrame("");
    try testing.expectEqualStrings("", none.bytes);
    try testing.expect(none.unterminated);
    const blank = try nextFrame("\n");
    try testing.expectEqualStrings("", blank.bytes);
    try testing.expect(!blank.unterminated);
    try testing.expectEqualStrings("", blank.rest);
}

test "a carriage return is message text here and is passed through both ways" {
    // The split is on `'\n'` and on nothing else, so a peer sending CRLF keeps
    // its `'\r'` at the end of the frame. JSON calls that insignificant
    // whitespace, so the message still decodes — which is what makes leaving it
    // there safe and what `framing.Framer.next` differs on by stripping it.
    const from_peer = try nextFrame("{}\r\n");
    try testing.expectEqualStrings("{}\r", from_peer.bytes);
    try testing.expect(!from_peer.unterminated);

    var buffer: [16]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    // And writing it back appends only the delimiter this module names, with no
    // carriage return of its own: what a caller sends is the frame plus one
    // `'\n'`, and the `'\r'` the peer sent is the caller's byte to pass on.
    try writeFrame(from_peer.bytes, &writer);
    try testing.expectEqualStrings("{}\r\n", writer.written());
    const again = try nextFrame(writer.written());
    try testing.expectEqualStrings(from_peer.bytes, again.bytes);
}

test "a frame the writer could not fit leaves an incomplete frame, and a refusal leaves nothing" {
    var buffer: [64]u8 = undefined;

    // Both refusals are decided before the first write, so the writer is exactly
    // as the caller left it and the same buffer can be reused.
    var refuser = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, writeFrame("{\"a\":1}\n", &refuser));
    try testing.expectEqual(@as(usize, 0), refuser.written().len);
    try writeFrame("{}", &refuser);
    try testing.expectEqualStrings("{}\n", refuser.written());

    // `json.Writer.slice` is all-or-nothing, so a buffer too small for the
    // message receives none of it. What is left is not a frame, not a message,
    // and nothing a caller may send or parse.
    var small: [3]u8 = undefined;
    var short = json.Writer.init(&small);
    try testing.expectError(error.BufferTooSmall, writeFrame("{\"a\":1}", &short));
    try testing.expectEqual(@as(usize, 0), short.written().len);

    // Long enough for the message and not for its delimiter: the whole message
    // is there and the frame is still not complete, because the byte that did
    // not fit was the one that ends it.
    var no_delimiter: [7]u8 = undefined;
    var nearly = json.Writer.init(&no_delimiter);
    try testing.expectError(error.BufferTooSmall, writeFrame("{\"a\":1}", &nearly));
    try testing.expectEqualStrings("{\"a\":1}", nearly.written());
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

    // The accepted document carries nothing but the two members the shape
    // models, so the encoder writes it back whole; it cannot reach the tail, and
    // refusing that tail is what keeps a document this accepts from carrying
    // bytes no encoder will ever write.
    const source = "{\"outcome\":\"selected\",\"optionId\":\"opt-1\"}";
    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodePermissionOutcome(try decodePermissionOutcome(source, &scratch), &writer);
    try testing.expectEqualStrings(source, writer.written());
    try testing.expect(writer.written().len < tailed.len);
}

test "a repeated permission outcome member resolves first-wins" {
    var scratch: [128]u8 = undefined;
    // The threat the session layer's own test names: a client answers
    // `cancelled` and then appends the option it wanted. The grant read would
    // be the second one, and the user saw the first.
    const hostile = "{\"outcome\":\"cancelled\",\"outcome\":\"selected\"," ++
        "\"optionId\":\"allow-once\"}";
    try testing.expectError(error.InvalidField, decodePermissionOutcome(hostile, &scratch));

    // Read the other way round, the first branch is the one that stands and
    // the pair agrees on the document that carried the repeat.
    const branch = try decodePermissionOutcome(
        "{\"outcome\":\"selected\",\"outcome\":\"cancelled\",\"optionId\":\"opt-1\"}",
        &scratch,
    );
    try testing.expectEqualStrings("opt-1", branch.selected);
    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodePermissionOutcome(branch, &writer);
    try testing.expectEqualStrings(
        "{\"outcome\":\"selected\",\"optionId\":\"opt-1\"}",
        writer.written(),
    );

    // The option id resolves the same way, so an outcome cannot name an option
    // other than the one it was answered with.
    const chosen = try decodePermissionOutcome(
        "{\"outcome\":\"selected\",\"optionId\":\"opt-1\",\"optionId\":\"opt-2\"}",
        &scratch,
    );
    try testing.expectEqualStrings("opt-1", chosen.selected);
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

test "a repeated subject member resolves first-wins" {
    var scratch: [256]u8 = undefined;
    // `tool_call` and `command` are different requests to put in front of a
    // user, and a peer that names both must not be able to choose which one
    // the library shows. The arm is the one the first member named.
    const hostile = "{\"type\":\"tool_call\",\"type\":\"command\"," ++
        "\"command\":\"rm -rf /\",\"cwd\":\"/\"," ++
        "\"toolCall\":{\"kind\":\"read\"}}";
    const first = try decodePermissionSubject(hostile, &scratch);
    try testing.expect(first == .tool_call);
    try testing.expectEqualStrings("{\"kind\":\"read\"}", first.tool_call);

    // The first command line is the one the user reads, and a later one cannot
    // replace it. The repeat is stepped over rather than read, so the first
    // occurrence's text stays live in the scratch the caller owns.
    const command = "{\"type\":\"command\",\"command\":\"ls\",\"cwd\":\"/tmp\"," ++
        "\"command\":\"rm -rf /\",\"cwd\":\"/\"}";
    const shown = try decodePermissionSubject(command, &scratch);
    try testing.expectEqualStrings("ls", shown.command.command);
    try testing.expectEqualStrings("/tmp", shown.command.cwd);

    // An optional is resolved the same way, so a repeat cannot move the tool
    // call a command is attributed to.
    const ids = "{\"type\":\"command\",\"command\":\"ls\",\"cwd\":\"/tmp\"," ++
        "\"toolCallId\":\"first\",\"toolCallId\":\"second\"}";
    const named = try decodePermissionSubject(ids, &scratch);
    try testing.expectEqualStrings("first", named.command.tool_call_id.?);
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
        const mode = ElicitationMode.fromString(name) orelse return error.TestUnexpectedResult;
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

test "a repeated option member resolves first-wins" {
    var scratch: [256]u8 = undefined;
    var options: [1]PermissionOption = undefined;
    // The option id is what `acp_session.readOutcome` matches the grant
    // against, so a peer that names it twice must not be able to choose which
    // one the caller compares.
    const hostile = "{\"sessionId\":\"s\",\"toolCall\":{},\"options\":[" ++
        "{\"optionId\":\"a\",\"name\":\"No\",\"kind\":\"reject_once\"," ++
        "\"optionId\":\"allow-once\",\"name\":\"Yes\",\"kind\":\"allow_once\"}]}";
    const request = try decodePermissionRequest(.stable, hostile, &options, &scratch);
    const option = request.stable.options[0];
    try testing.expectEqualStrings("a", option.option_id);
    try testing.expectEqualStrings("No", option.name);
    try testing.expectEqual(PermissionOptionKind.reject_once, option.kind.known);
    try testing.expectEqual(@as(?bool, false), option.grants());

    // A repeated `kind` resolves the same way, so a grant cannot be moved from
    // a rejection to an approval behind the user's back.
    const moved = "{\"sessionId\":\"s\",\"toolCall\":{},\"options\":[" ++
        "{\"optionId\":\"a\",\"name\":\"No\",\"kind\":\"reject_once\"," ++
        "\"kind\":\"allow_once\"}]}";
    const again = try decodePermissionRequest(.stable, moved, &options, &scratch);
    try testing.expectEqual(@as(?bool, false), again.stable.options[0].grants());
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

test "a repeated permission request member resolves first-wins" {
    var scratch: [512]u8 = undefined;
    var options: [2]PermissionOption = undefined;
    // The tool call is what the agent shows the user and what
    // `encodePermissionRequest` writes back, so a second one must not be able
    // to replace the first.
    const hostile = "{\"sessionId\":\"s1\",\"title\":\"Read\"," ++
        "\"toolCall\":{\"kind\":\"read\"},\"options\":[" ++
        "{\"optionId\":\"a\",\"name\":\"Allow\",\"kind\":\"allow_once\"}]," ++
        "\"toolCall\":{\"kind\":\"execute\",\"command\":\"rm -rf /\"}}";
    const request = try decodePermissionRequest(.stable, hostile, &options, &scratch);
    try testing.expectEqualStrings("{\"kind\":\"read\"}", request.stable.tool_call);
    var buffer: [512]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encodePermissionRequest(request, &writer);
    try testing.expect(std.mem.startsWith(
        u8,
        writer.written(),
        "{\"sessionId\":\"s1\",\"toolCall\":{\"kind\":\"read\"}",
    ));

    // The second array is stepped over rather than read, so it cannot fill the
    // caller's array and it cannot replace a count the first one set with one
    // that satisfies `minItems`.
    const counted = "{\"sessionId\":\"s1\",\"title\":\"t\",\"options\":[]," ++
        "\"options\":[{\"optionId\":\"a\",\"name\":\"A\",\"kind\":\"allow_once\"}]}";
    try testing.expectError(
        error.InvalidField,
        decodePermissionRequest(.draft, counted, &options, &scratch),
    );
    var one: [1]PermissionOption = undefined;
    const roomy = "{\"sessionId\":\"s\",\"toolCall\":{},\"options\":[" ++
        "{\"optionId\":\"a\",\"name\":\"A\",\"kind\":\"allow_once\"}]," ++
        "\"options\":[{\"optionId\":\"b\",\"name\":\"B\",\"kind\":\"allow_once\"}," ++
        "{\"optionId\":\"c\",\"name\":\"C\",\"kind\":\"reject_once\"}]}";
    const kept = try decodePermissionRequest(.stable, roomy, &one, &scratch);
    try testing.expectEqual(@as(usize, 1), kept.stable.options.len);
    try testing.expectEqualStrings("a", kept.stable.options[0].option_id);

    // The session id resolves the same way, so the request the caller acts on
    // is the one the first member named.
    var named_options: [1]PermissionOption = undefined;
    const named = "{\"sessionId\":\"s1\",\"sessionId\":\"s2\",\"toolCall\":{}," ++
        "\"options\":[]}";
    const named_request = try decodePermissionRequest(
        .stable,
        named,
        &named_options,
        &scratch,
    );
    try testing.expectEqualStrings("s1", named_request.stable.session_id);
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

test "a repeated replayFrom type resolves first-wins" {
    var scratch: [64]u8 = undefined;
    // `start` and a vendor tag are different positions to resume at, so a peer
    // that sends both must not be able to choose which one the session takes.
    const start = try decodeReplayFrom("{\"type\":\"start\",\"type\":\"checkpoint\"}", &scratch);
    try testing.expect(start == .start);

    // The other way round the first tag is the catch-all, and the catch-all is
    // what stays carried.
    const other = try decodeReplayFrom("{\"type\":\"checkpoint\",\"type\":\"start\"}", &scratch);
    try testing.expect(other == .other);
    try testing.expectEqualStrings("checkpoint", other.other);
}

test "a repeated capability member resolves first-wins" {
    var scratch: [128]u8 = undefined;
    var paths: [64]u8 = undefined;
    var out: [4]Capability = undefined;
    // This walk took the last occurrence of every member it read, so a peer
    // that answered `false` and then `true` for `loadSession` had its refusal
    // overwritten by its own later claim. `isMethodSupported` is the question
    // `acp_session.checkCall` asks before it lets a call through, so the gate
    // opened on a member the peer had already answered. The first occurrence is
    // the answer every other walk in this library gives, and it is the one that
    // is read.
    const refused = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"loadSession\":false,\"loadSession\":true}",
        &out,
        &paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 1), refused.entries.len);
    try testing.expect(!refused.entries[0].advertised());
    var list: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), (try advertisedPaths(refused, &list)).len);
    // The gate, and the method that shares it: PROTOCOLS.md section 6.5 gates
    // `session/load` and `session/resume` on `loadSession` between them.
    try testing.expect(!isMethodSupported(try lookupMethod(.stable, "session/load"), list[0..0]));
    try testing.expect(!isMethodSupported(try lookupMethod(.stable, "session/resume"), list[0..0]));

    // The other order is the same document read the other way round, and it is
    // the one order that is support: the member is on the wire, and the value
    // the peer named first is the one it advertised with.
    var other_out: [4]Capability = undefined;
    var other_paths: [64]u8 = undefined;
    var other_scratch: [128]u8 = undefined;
    const offered = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"loadSession\":true,\"loadSession\":false}",
        &other_out,
        &other_paths,
        &other_scratch,
    );
    try testing.expectEqual(@as(usize, 1), offered.entries.len);
    var other_list: [4][]const u8 = undefined;
    const offered_paths = try advertisedPaths(offered, &other_list);
    try testing.expectEqual(@as(usize, 1), offered_paths.len);
    try testing.expect(isMethodSupported(try lookupMethod(.stable, "session/load"), offered_paths));

    // A repeat inside a nested object is the same rule one level down, on the
    // other side: `fs.readTextFile` is a v1 boolean that gates
    // `fs/read_text_file`, and the object around it advertises by being there,
    // so the only path left in the list is `fs`.
    var client_out: [4]Capability = undefined;
    var client_paths: [64]u8 = undefined;
    var client_scratch: [128]u8 = undefined;
    const client = try decodeCapabilityObject(
        .stable,
        .client,
        "{\"fs\":{\"readTextFile\":false,\"readTextFile\":true}}",
        &client_out,
        &client_paths,
        &client_scratch,
    );
    var client_list: [4][]const u8 = undefined;
    const client_paths_list = try advertisedPaths(client, &client_list);
    try testing.expectEqual(@as(usize, 1), client_paths_list.len);
    try testing.expectEqualStrings("fs", client_paths_list[0]);
    try testing.expect(!isMethodSupported(
        try lookupMethod(.stable, "fs/read_text_file"),
        client_paths_list,
    ));
    // The name is compared decoded, not by its spelling on the wire, so a peer
    // cannot write the same member two ways to slip a second occurrence past
    // the guard. `json.Reader.string` unescapes the key, and the entry's path
    // is the member's name whichever way it arrived.
    var spelled_out: [4]Capability = undefined;
    var spelled_paths: [64]u8 = undefined;
    var spelled_scratch: [128]u8 = undefined;
    const spelled = try decodeCapabilityObject(
        .stable,
        .client,
        "{\"\\u0074erminal\":true,\"terminal\":false}",
        &spelled_out,
        &spelled_paths,
        &spelled_scratch,
    );
    try testing.expectEqual(@as(usize, 1), spelled.entries.len);
    try testing.expectEqualStrings("terminal", spelled.entries[0].path);
    try testing.expect(spelled.entries[0].advertised());
}

test "a capability member that recorded nothing still claims its name" {
    var scratch: [128]u8 = undefined;
    var paths: [64]u8 = undefined;
    var out: [4]Capability = undefined;
    // The rule is about the name, and an explicit `null` is the member missing
    // and wearing a key. A walk that answered only from the members that
    // recorded reads the `true` behind it as the member's value, so a peer that
    // answered `null` and then `true` for `loadSession` opened a gate it had
    // already refused. The name is claimed, and the claim is the whole of what
    // the later occurrence is answered by.
    const nulled = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"loadSession\":null,\"loadSession\":true}",
        &out,
        &paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 0), nulled.entries.len);
    var list: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), (try advertisedPaths(nulled, &list)).len);
    try testing.expect(!isMethodSupported(try lookupMethod(.stable, "session/load"), list[0..0]));

    // A value neither schema declares is not a capability either, and it is
    // still the first occurrence of the name.
    var junk_out: [4]Capability = undefined;
    var junk_paths: [64]u8 = undefined;
    var junk_scratch: [128]u8 = undefined;
    const junked = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"loadSession\":7,\"loadSession\":true}",
        &junk_out,
        &junk_paths,
        &junk_scratch,
    );
    try testing.expectEqual(@as(usize, 0), junked.entries.len);

    // A claim costs a slot of `out` and no region of `paths`. The member above
    // that recorded nothing still costs the caller no region of that buffer
    // even where it is repeated, because a repeat that carries no form is spent
    // without a path to ask the table about.
    var no_paths: [0]u8 = undefined;
    var one_slot: [2]Capability = undefined;
    const spent = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"a\":null,\"a\":null}",
        &one_slot,
        &no_paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 0), spent.entries.len);

    // So `out` has to hold every member of the object, and a caller who sized
    // it for the entries alone is told so rather than silently handed a set the
    // walk could not finish resolving.
    var two_slots: [2]Capability = undefined;
    try testing.expectEqual(
        @as(usize, 0),
        (try decodeCapabilityObject(
            .stable,
            .agent,
            "{\"a\":null,\"b\":null}",
            &two_slots,
            &paths,
            &scratch,
        )).entries.len,
    );
    var no_room: [1]Capability = undefined;
    try testing.expectError(error.BufferTooSmall, decodeCapabilityObject(
        .stable,
        .agent,
        "{\"a\":null,\"b\":null}",
        &no_room,
        &paths,
        &scratch,
    ));
}

test "the same capability name at two levels is two members" {
    var scratch: [128]u8 = undefined;
    var paths: [64]u8 = undefined;
    var out: [8]Capability = undefined;
    // v1 has no closed capability set, so the names here are extension points,
    // which is the point: the walk has to tell a member of the top object from
    // a member of the object inside it even where the two are spelled alike.
    const nested = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"a\":{\"x\":null},\"x\":true}",
        &out,
        &paths,
        &scratch,
    );
    // `a.x` recorded nothing, so the claim it left behind says nothing about a
    // member of the top object named `x`, which is a different path. The claims
    // of an object that has closed are spent with it.
    try testing.expectEqual(@as(usize, 2), nested.entries.len);
    try testing.expectEqualStrings("a", nested.entries[0].path);
    try testing.expectEqualStrings("x", nested.entries[1].path);
    try testing.expect(findCapability(nested, "x").?.advertised());
    try testing.expect(findCapability(nested, "a.x") == null);

    // The other way round, with the member of the top object the one that
    // decided nothing this time.
    var other_out: [8]Capability = undefined;
    var other_paths: [64]u8 = undefined;
    var other_scratch: [128]u8 = undefined;
    const outer = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"a\":{\"x\":true},\"x\":null}",
        &other_out,
        &other_paths,
        &other_scratch,
    );
    try testing.expectEqual(@as(usize, 2), outer.entries.len);
    try testing.expect(findCapability(outer, "a.x").?.advertised());
    try testing.expect(findCapability(outer, "x") == null);

    // And a repeat inside one object is one member of that object, with the
    // first occurrence the answer.
    var inner_out: [8]Capability = undefined;
    var inner_paths: [64]u8 = undefined;
    var inner_scratch: [128]u8 = undefined;
    const inner = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"a\":{\"x\":true,\"x\":false}}",
        &inner_out,
        &inner_paths,
        &inner_scratch,
    );
    try testing.expectEqual(@as(usize, 2), inner.entries.len);
    try testing.expect(findCapability(inner, "a.x").?.advertised());

    // Two members can reach one path — a key spelled `a.x` at the top of the
    // object, and the `x` inside an `a` beside it — and the path is the
    // identity the rest of this module speaks, so the first one is kept and the
    // second is spent. Two entries with one path would also have re-encoded as
    // one object with the member spelled twice, which no walk here produces.
    var joined_out: [8]Capability = undefined;
    var joined_paths: [64]u8 = undefined;
    var joined_scratch: [128]u8 = undefined;
    const joined = try decodeCapabilityObject(
        .stable,
        .agent,
        "{\"a\":{\"x\":true},\"a.x\":false}",
        &joined_out,
        &joined_paths,
        &joined_scratch,
    );
    try testing.expectEqual(@as(usize, 2), joined.entries.len);
    try testing.expect(findCapability(joined, "a.x").?.advertised());
}

test "a repeated capability member is shape-checked wherever it appears" {
    var scratch: [128]u8 = undefined;
    var out: [4]Capability = undefined;
    // `terminal` is a boolean at v1, so a document that spells it twice has one
    // occurrence this schema does not define whichever position it is in. The
    // check runs on the repeat as well as on the first occurrence, for the
    // reason `bridge.decodeEnvelope` gives for `params`: the first occurrence is
    // the one that is carried, and a document whose second `terminal` is a
    // presence object is malformed whatever the first one said. A first-wins
    // walk that spent a repeat unchecked would answer
    // `{"terminal":true,"terminal":{}}` and refuse `{"terminal":{}}`, and those
    // are one member in one form.
    //
    // The buffer is sized for the single path the first occurrence borrowed,
    // and the repeat is still refused rather than reported short: the recorded
    // path is the one the check is asked of, so a repeat of a recorded member
    // costs the caller no region.
    var one_path: [8]u8 = undefined;
    try testing.expectError(error.InvalidField, decodeCapabilityObject(
        .stable,
        .client,
        "{\"terminal\":true,\"terminal\":{}}",
        &out,
        &one_path,
        &scratch,
    ));

    // The same document where the first occurrence recorded nothing, and so left
    // no path behind: the check is asked of one built for it, and the member
    // that recorded nothing still costs no region where the repeat carries no
    // form.
    var paths: [64]u8 = undefined;
    try testing.expectError(error.InvalidField, decodeCapabilityObject(
        .stable,
        .client,
        "{\"terminal\":null,\"terminal\":{}}",
        &out,
        &paths,
        &scratch,
    ));

    // v2 replaced every boolean with a presence object, so a boolean anywhere
    // in a v2 capability object is a shape the draft does not define — at the
    // second occurrence of a name as much as at the first.
    try testing.expectError(error.InvalidField, decodeCapabilityObject(
        .draft,
        .agent,
        "{\"session\":{\"delete\":{},\"delete\":true}}",
        &out,
        &paths,
        &scratch,
    ));

    // A name neither schema names has no declared form, so a repeat of one is
    // spent without a check: there is no table to ask, and an extension point
    // may take either form by the rule that keeps it legal in the first place.
    const extension = try decodeCapabilityObject(
        .stable,
        .client,
        "{\"vendor\":5,\"vendor\":{}}",
        &out,
        &paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 0), extension.entries.len);
}

test "the known-capability answer is read per side and per version" {
    // `encodeCapabilityObject` tells a caller that builds a set by hand to ask
    // this, so the answer has to be the one the walk derives on the way in and
    // the validator asks on the way out. A path this library names for one side
    // is not a capability of the other, and a v1 path is not a v2 one.
    try testing.expect(isKnownCapability(.stable, .agent, "loadSession"));
    try testing.expect(!isKnownCapability(.stable, .client, "loadSession"));
    try testing.expect(isKnownCapability(.stable, .client, "fs.readTextFile"));
    try testing.expect(!isKnownCapability(.stable, .agent, "fs.readTextFile"));
    try testing.expect(!isKnownCapability(.stable, .agent, "capabilities.session.delete"));
    try testing.expect(isKnownCapability(.draft, .agent, "capabilities.session.delete"));
    try testing.expect(!isKnownCapability(.draft, .client, "capabilities.session.delete"));
    // Neither schema gives a capability object to a side-independent method, so
    // the side that has none answers no at both versions rather than reaching
    // for a table.
    try testing.expect(!isKnownCapability(.stable, .protocol, "loadSession"));
    try testing.expect(!isKnownCapability(.draft, .protocol, "capabilities.session.delete"));
    // An extension point is a capability neither schema names, at either side.
    try testing.expect(!isKnownCapability(.stable, .agent, "vendor.custom"));
    try testing.expect(!isKnownCapability(.draft, .agent, "capabilities.vendor.custom"));
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

    const read = findCapability(set, "fs.readTextFile") orelse return error.TestUnexpectedResult;
    try testing.expect(read.known);
    try testing.expectEqual(CapabilityForm.boolean, read.form);
    try testing.expectEqual(@as(?bool, true), read.value);
    try testing.expect(read.advertised());

    const write = findCapability(set, "fs.writeTextFile") orelse return error.TestUnexpectedResult;
    try testing.expect(write.known);
    try testing.expectEqual(@as(?bool, false), write.value);
    // A `false` boolean is the v1 spelling of "unsupported": the member is on
    // the wire and it still advertises nothing.
    try testing.expect(!write.advertised());

    const mode = findCapability(set, "elicitation.form") orelse return error.TestUnexpectedResult;
    try testing.expect(mode.known);
    try testing.expectEqual(CapabilityForm.presence_object, mode.form);
    try testing.expectEqual(@as(?bool, null), mode.value);
    try testing.expect(mode.advertised());

    // An explicit `null` is the absent case, so it is not a member at all.
    try testing.expect(findCapability(set, "elicitation.url") == null);

    // v1 has no closed capability set, so an extension is carried with the
    // known flag off rather than refused.
    const vendor = findCapability(set, "vendor.custom") orelse return error.TestUnexpectedResult;
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

    const image = findCapability(set, "capabilities.session.prompt.image") orelse return error.TestUnexpectedResult;
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
    const http = findCapability(set, "mcpCapabilities.http") orelse return error.TestUnexpectedResult;
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
    // The discriminator is the only member this shape models and the document
    // carries no other, so the pair reproduces it exactly.
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

test "a v2 capability path with no capabilities root is refused, not mis-spelt" {
    var buffer: [256]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    // The walk writes the `capabilities` root into `paths` ahead of its first
    // member, so every path it records carries it, and the encoder writes the
    // contents of that member rather than the member itself. A hand-built path
    // without the root has no member name to write, so writing it would put
    // the dots inside one name instead.
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.draft, .agent, .{
        .entries = &.{
            .{ .path = "session.delete", .known = true, .form = .presence_object, .value = null },
        },
        .present = true,
    }, &writer));
    // Nothing reached the buffer, so a caller that sized it for the refusal is
    // not holding the prefix of a document.
    try testing.expectEqual(@as(usize, 0), writer.written().len);

    // The comparison is against `capabilities.` with the dot, so it is a whole
    // leading path component rather than a prefix match: a path that merely
    // starts with the letters is refused too, and so is a bare `capabilities`
    // and an empty one. The v2 walk would record each of them with the root
    // prepended, so none of them is a path it could have produced.
    for ([_][]const u8{
        "capabilitiesFoo.bar",
        "capabilitiesX",
        "capabilities",
        "",
    }) |not_a_root| {
        var collide = json.Writer.init(&buffer);
        try testing.expectError(error.InvalidField, encodeCapabilityObject(.draft, .agent, .{
            .entries = &.{
                .{ .path = not_a_root, .known = false, .form = .presence_object, .value = null },
            },
            .present = true,
        }, &collide));
        try testing.expectEqual(@as(usize, 0), collide.written().len);
    }

    // The document that path would have produced, and what a v2 walk reads back
    // out of it. The root is prepended on the way in, so the entry is a path
    // this library never recorded: the encoder accepted a value and the decoder
    // answered a different one, with no error on either side to report it.
    var scratch: [64]u8 = undefined;
    var paths: [64]u8 = undefined;
    var out: [4]Capability = undefined;
    const misread = try decodeCapabilityObject(
        .draft,
        .agent,
        "{\"session.delete\":{}}",
        &out,
        &paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 1), misread.entries.len);
    try testing.expectEqualStrings("capabilities.session.delete", misread.entries[0].path);
    try testing.expect(findCapability(misread, "session.delete") == null);

    // The same capability with the root the walk puts there is written, and what
    // it writes decodes back to the path it was given — the member name is the
    // root's tail, and the path is the whole of it.
    var rooted = json.Writer.init(&buffer);
    try encodeCapabilityObject(.draft, .agent, .{
        .entries = &.{
            .{ .path = "capabilities.session.delete", .known = true, .form = .presence_object, .value = null },
        },
        .present = true,
    }, &rooted);
    try testing.expectEqualStrings("{\"session.delete\":{}}", rooted.written());

    var again_paths: [64]u8 = undefined;
    var again_out: [4]Capability = undefined;
    const again = try decodeCapabilityObject(
        .draft,
        .agent,
        rooted.written(),
        &again_out,
        &again_paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 1), again.entries.len);
    try testing.expectEqualStrings("capabilities.session.delete", again.entries[0].path);
    try testing.expect(again.entries[0].known);

    // The same path on a client object is refused the same way, and so is the
    // initialize member that carries it — before the member name is written,
    // which is what keeps a refusal off the caller's buffer entirely.
    var client = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.draft, .client, .{
        .entries = &.{
            .{ .path = "elicitation.form", .known = false, .form = .presence_object, .value = null },
        },
        .present = true,
    }, &client));
    try testing.expectEqual(@as(usize, 0), client.written().len);

    var body = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encodeInitializeCapabilities(.draft, .agent, .{
        .entries = &.{
            .{ .path = "session.delete", .known = true, .form = .presence_object, .value = null },
        },
        .present = true,
    }, &body));
    try testing.expectEqual(@as(usize, 0), body.written().len);
}

test "a capability set is bounded by the deepest nesting a decode admits" {
    // `json.max_depth` is a budget over the whole document, and the capability
    // object is a container in it: `decodeCapabilityObject` opens the object
    // before it reads a member of it, so the members of the
    // `json.max_depth - 1`st object nested below it are the deepest a peer can
    // spell. One object more is what the encoder has to refuse, and refusing
    // it is a fact about the set rather than a shortage. The `initialize` body
    // is a container *around* that object, so the same budget answers a
    // different number there — one level shallower — and both numbers are one
    // contract rather than two.
    const deepest = json.max_depth - 1;
    const source = "{\"v\":" ** (deepest + 1) ++ "true" ++ "}" ** (deepest + 1);
    const too_deep_document = "{\"v\":" ** (deepest + 2) ++ "true" ++ "}" ** (deepest + 2);

    // A path at nesting level `k` is `2k + 1` bytes and every one owns its own
    // region of `paths`, so the sum over `deepest` objects and one boolean leaf
    // is `(deepest + 1) * (deepest + 1)`, and one object more needs a level
    // more again.
    // A short buffer here would answer `BufferTooSmall` and hide the bound
    // this is about, so both are sized from the paths themselves.
    var scratch: [16]u8 = undefined;
    var paths: [(deepest + 1) * (deepest + 1) + 8]u8 = undefined;
    var out: [72]Capability = undefined;
    var buffer: [512]u8 = undefined;
    const set = try decodeCapabilityObject(.stable, .client, source, &out, &paths, &scratch);
    try testing.expectEqual(@as(usize, deepest + 1), set.entries.len);
    try testing.expectEqual(CapabilityForm.presence_object, set.entries[deepest - 1].form);
    try testing.expectEqual(CapabilityForm.boolean, set.entries[deepest].form);

    // The deepest set this library reads is a set this library writes, and the
    // bytes it writes decode back to the same paths in the same forms.
    var writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .client, set, &writer);
    try testing.expectEqualStrings(source, writer.written());

    var again_paths: [(deepest + 1) * (deepest + 1) + 8]u8 = undefined;
    var again_out: [72]Capability = undefined;
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
        try testing.expectEqual(first.form, second.form);
        try testing.expectEqual(first.value, second.value);
    }

    // The same set and then a sibling at the root. The branch closes before
    // the sibling's member is written, so the two sit at their own depths
    // rather than summing, and the whole set is no deeper than the branch
    // alone: a bound that added the two up would refuse this, and a real
    // capability object carries many members rather than one chain.
    var with_sibling: [73]Capability = undefined;
    @memcpy(with_sibling[0..set.entries.len], set.entries);
    with_sibling[set.entries.len] = .{
        .path = "z",
        .known = false,
        .form = .boolean,
        .value = true,
    };
    var sibling_writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .client, .{
        .entries = with_sibling[0 .. set.entries.len + 1],
        .present = true,
    }, &sibling_writer);
    try testing.expectEqualStrings(
        source[0 .. source.len - 1] ++ ",\"z\":true}",
        sibling_writer.written(),
    );

    // One object more is not a set a decode can return, so it is built here
    // rather than decoded: the walk refuses the member inside it at walk depth
    // `json.max_depth + 1`, and the reader refuses to open the object at all.
    const too_deep_entries = comptime blk: {
        var built: [deepest + 2]Capability = undefined;
        // The same spelling the documents above are built from, one level per
        // step: `v`, `v.v`, `v.v.v`, and so on.
        var path: []const u8 = "v";
        for (0..deepest + 2) |level| {
            const leaf = level == deepest + 1;
            built[level] = .{
                .path = path,
                .known = false,
                .form = if (leaf) .boolean else .presence_object,
                .value = if (leaf) @as(?bool, true) else @as(?bool, null),
            };
            path = path ++ ".v";
        }
        break :blk built;
    };
    const too_deep: CapabilitySet = .{ .entries = &too_deep_entries, .present = true };

    var unreachable_paths: [(deepest + 2) * (deepest + 2) + 8]u8 = undefined;
    var unreachable_out: [80]Capability = undefined;
    try testing.expectError(
        error.LimitExceeded,
        decodeCapabilityObject(
            .stable,
            .client,
            too_deep_document,
            &unreachable_out,
            &unreachable_paths,
            &scratch,
        ),
    );

    // The refusal is about the set, so nothing reaches the buffer: not the
    // member name, not a brace, not one byte over what the caller had.
    var marked: [512]u8 = undefined;
    @memset(&marked, 0xa5);
    var refuser = json.Writer.init(&marked);
    try testing.expectError(
        error.InvalidField,
        encodeCapabilityObject(.stable, .client, too_deep, &refuser),
    );
    try testing.expectEqual(@as(usize, 0), refuser.written().len);
    for (marked) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);

    // The `initialize` member runs the preflight ahead of the member name as
    // well, at the depth of the body it is writing rather than the depth of
    // the object alone, so a set the body cannot hold is never left half
    // written in one either.
    var marked_body: [1024]u8 = undefined;
    @memset(&marked_body, 0xa5);
    var body_refuser = json.Writer.init(&marked_body);
    try testing.expectError(
        error.InvalidField,
        encodeInitializeCapabilities(.stable, .client, too_deep, &body_refuser),
    );
    try testing.expectEqual(@as(usize, 0), body_refuser.written().len);
    for (marked_body) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);

    // The same budget is a different number for that body, and it is the
    // number the wrapper has to answer with: the body spends a level on
    // `beginObject` and the member is read with `rawValue`, which spends
    // another on the object it carries, so the deepest body this library reads
    // carries `json.max_depth - 2` presence objects below the member rather
    // than the `json.max_depth - 1` above. That body decodes, re-encodes to
    // the same bytes, and decodes back to the same entries.
    const body_deepest = json.max_depth - 2;
    const body_object = "{\"v\":" ** (body_deepest + 1) ++ "true" ++ "}" ** (body_deepest + 1);
    const body_source = "{\"" ++ v2_renames.client_capabilities_v1 ++ "\":" ++ body_object ++ "}";

    // Sized the same way as the paths above, so a short buffer here would
    // answer `BufferTooSmall` and hide the bound this is about.
    var body_paths: [(body_deepest + 2) * (body_deepest + 2) + 8]u8 = undefined;
    var body_out: [72]Capability = undefined;
    const body_set = try decodeInitializeCapabilities(
        .stable,
        .client,
        body_source,
        &body_out,
        &body_paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, body_deepest + 1), body_set.entries.len);
    try testing.expectEqual(
        CapabilityForm.presence_object,
        body_set.entries[body_deepest - 1].form,
    );
    try testing.expectEqual(CapabilityForm.boolean, body_set.entries[body_deepest].form);

    var body_buffer: [512]u8 = undefined;
    var body_writer = json.Writer.init(&body_buffer);
    try encodeInitializeCapabilities(.stable, .client, body_set, &body_writer);
    try testing.expectEqualStrings(body_source, body_writer.written());

    var body_again_paths: [(body_deepest + 2) * (body_deepest + 2) + 8]u8 = undefined;
    var body_again_out: [72]Capability = undefined;
    const body_again = try decodeInitializeCapabilities(
        .stable,
        .client,
        body_writer.written(),
        &body_again_out,
        &body_again_paths,
        &scratch,
    );
    try testing.expectEqual(body_set.entries.len, body_again.entries.len);
    for (body_set.entries, body_again.entries) |first, second| {
        try testing.expectEqualStrings(first.path, second.path);
        try testing.expectEqual(first.form, second.form);
        try testing.expectEqual(first.value, second.value);
    }

    // `set` above is the deepest thing `encodeCapabilityObject` writes and is
    // one presence object too deep for the body, so the two writers disagree
    // about one set and nothing else. That is the whole point of charging the
    // body for itself: the same entries are legal at one depth and not at the
    // other, and the extra level belongs to the document the caller gets
    // rather than to the object inside it. Both refusals are about the set —
    // `error.InvalidField` on the way out, `error.LimitExceeded` on the way
    // in — and neither is a shortage, so the wrapper's arrives with the
    // buffer untouched: not the brace, not the member name, not one byte over
    // what the caller had.
    var one_deeper_paths: [(deepest + 2) * (deepest + 2) + 8]u8 = undefined;
    var one_deeper_out: [80]Capability = undefined;
    try testing.expectError(
        error.LimitExceeded,
        decodeInitializeCapabilities(
            .stable,
            .client,
            "{\"" ++ v2_renames.client_capabilities_v1 ++ "\":" ++ source ++ "}",
            &one_deeper_out,
            &one_deeper_paths,
            &scratch,
        ),
    );

    var one_deeper_marked: [1024]u8 = undefined;
    @memset(&one_deeper_marked, 0xa5);
    var one_deeper_refuser = json.Writer.init(&one_deeper_marked);
    try testing.expectError(
        error.InvalidField,
        encodeInitializeCapabilities(.stable, .client, set, &one_deeper_refuser),
    );
    try testing.expectEqual(@as(usize, 0), one_deeper_refuser.written().len);
    for (one_deeper_marked) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);

    // The same bound at v2, where every member name has the `capabilities`
    // root taken off it on the way out and put back on the way in, and with a
    // sibling at the root after the deepest branch. The branch closes before
    // the sibling's member is written, so the body is no deeper than the
    // branch alone: a bound that added the two up would refuse this, and the
    // root that comes off the names is a name rather than a level.
    const v2_branch = comptime blk: {
        var built: [body_deepest]Capability = undefined;
        // The same spelling the documents above are built from, one level per
        // step, behind the root this version writes as the member name.
        var path: []const u8 = v2_capabilities_root ++ "v";
        for (0..body_deepest) |level| {
            built[level] = .{
                .path = path,
                .known = false,
                .form = .presence_object,
                .value = null,
            };
            path = path ++ ".v";
        }
        break :blk built;
    };
    var v2_sibling: [body_deepest + 1]Capability = undefined;
    @memcpy(v2_sibling[0..body_deepest], &v2_branch);
    v2_sibling[body_deepest] = .{
        .path = v2_capabilities_root ++ "z",
        .known = false,
        .form = .presence_object,
        .value = null,
    };
    const v2_body = "{\"" ++ v2_renames.client_capabilities_v2 ++ "\":" ++
        "{" ++ "\"v\":{" ** body_deepest ++ "}" ** body_deepest ++ ",\"z\":{}}" ++ "}";

    var v2_buffer: [512]u8 = undefined;
    var v2_writer = json.Writer.init(&v2_buffer);
    try encodeInitializeCapabilities(.draft, .agent, .{
        .entries = &v2_sibling,
        .present = true,
    }, &v2_writer);
    try testing.expectEqualStrings(v2_body, v2_writer.written());

    // A path at level `k` here is `13 + 2k` bytes behind the root, so the
    // branch and the sibling together own `4601` of `paths`.
    var v2_paths: [4736]u8 = undefined;
    var v2_out: [72]Capability = undefined;
    const v2_read = try decodeInitializeCapabilities(
        .draft,
        .agent,
        v2_body,
        &v2_out,
        &v2_paths,
        &scratch,
    );
    try testing.expectEqual(@as(usize, body_deepest + 1), v2_read.entries.len);
    for (v2_sibling[0..v2_read.entries.len], v2_read.entries) |first, second| {
        try testing.expectEqualStrings(first.path, second.path);
        try testing.expectEqual(first.form, second.form);
    }

    // One object more under the same root, refused at the same bound, so the
    // level is counted on the levels rather than on the spelling of the paths.
    const v2_too_deep = comptime blk: {
        var built: [body_deepest + 1]Capability = undefined;
        var path: []const u8 = v2_capabilities_root ++ "v";
        for (0..body_deepest + 1) |level| {
            built[level] = .{
                .path = path,
                .known = false,
                .form = .presence_object,
                .value = null,
            };
            path = path ++ ".v";
        }
        break :blk built;
    };
    var v2_marked: [1024]u8 = undefined;
    @memset(&v2_marked, 0xa5);
    var v2_refuser = json.Writer.init(&v2_marked);
    try testing.expectError(error.InvalidField, encodeInitializeCapabilities(.draft, .agent, .{
        .entries = &v2_too_deep,
        .present = true,
    }, &v2_refuser));
    try testing.expectEqual(@as(usize, 0), v2_refuser.written().len);
    for (v2_marked) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
}

test "a capability the decoder let through is written for the side that let it" {
    var scratch: [256]u8 = undefined;
    var paths: [256]u8 = undefined;
    var out: [8]Capability = undefined;
    var buffer: [256]u8 = undefined;
    // `promptCapabilities.image` is an agent gate, so a *client* object that
    // carries it holds a path this library does not name for that side. v1 has
    // no closed capability set, so an unknown path is the extension point and
    // either form is legal. The validator has to ask the same per-side question
    // the walk asked on the way in, or it refuses a value the decoder returned
    // and `decode(encode(x)) == x` fails on the decoder's own output.
    const source = "{\"promptCapabilities\":{\"image\":{}}}";
    const set = try decodeCapabilityObject(.stable, .client, source, &out, &paths, &scratch);
    const entry = findCapability(set, "promptCapabilities.image") orelse return error.TestUnexpectedResult;
    try testing.expect(!entry.known);
    try testing.expectEqual(CapabilityForm.presence_object, entry.form);

    var writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .client, set, &writer);
    try testing.expectEqualStrings(source, writer.written());

    // The other spelling of the same drift: `session.close` is a presence
    // object on an agent object and no client capability at all, so a client
    // object may carry the boolean the walk read.
    // Its own array and paths, because `set` above borrows the ones the first
    // decode filled and a second walk into them would land on top of it.
    var other_out: [8]Capability = undefined;
    var other_paths: [128]u8 = undefined;
    const boolean_side = try decodeCapabilityObject(
        .stable,
        .client,
        "{\"session\":{\"close\":true}}",
        &other_out,
        &other_paths,
        &scratch,
    );
    var boolean_writer = json.Writer.init(&buffer);
    try encodeCapabilityObject(.stable, .client, boolean_side, &boolean_writer);
    try testing.expectEqualStrings(
        "{\"session\":{\"close\":true}}",
        boolean_writer.written(),
    );

    // The same set through the `initialize` member, which is the call
    // `acp_session` makes with a decoded set.
    var init_writer = json.Writer.init(&buffer);
    try encodeInitializeCapabilities(.stable, .client, set, &init_writer);
    try testing.expectEqualStrings(
        "{\"" ++ v2_renames.client_capabilities_v1 ++
            "\":{\"promptCapabilities\":{\"image\":{}}}}",
        init_writer.written(),
    );

    // The check is not gone, only asked per side: the same path on the agent
    // side is a boolean the schema types, and the presence object is refused.
    var refuser = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encodeCapabilityObject(.stable, .agent, .{
        .entries = &.{.{
            .path = "promptCapabilities.image",
            .known = true,
            .form = .presence_object,
            .value = null,
        }},
        .present = true,
    }, &refuser));
    try testing.expectEqual(@as(usize, 0), refuser.written().len);
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

test "permission tool calls spend subject and request containers" {
    const call = "{\"k\":" ++ "[" ** (json.max_depth - 2) ++ "0" ++ "]" ** (json.max_depth - 2) ++ "}";
    const too_deep = "{\"k\":" ++ "[" ** (json.max_depth - 1) ++ "0" ++ "]" ** (json.max_depth - 1) ++ "}";
    const nested_call = "{\"k\":" ++ "[" ** (json.max_depth - 3) ++ "0" ++ "]" ** (json.max_depth - 3) ++ "}";
    const options = [_]PermissionOption{.{
        .option_id = "a",
        .name = "Allow",
        .kind = .{ .known = .allow_once },
    }};
    var out: [1024]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var options_out: [1]PermissionOption = undefined;
    var writer = json.Writer.init(&out);
    try encodePermissionSubject(.{ .tool_call = call }, &writer);
    const subject = try decodePermissionSubject(writer.written(), &scratch);
    try testing.expectEqualStrings(call, subject.tool_call);
    @memset(&out, 0xa5);
    writer = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodePermissionSubject(.{ .tool_call = too_deep }, &writer));
    try testing.expectEqualSlices(u8, &([_]u8{0xa5} ** out.len), &out);

    writer = json.Writer.init(&out);
    try encodePermissionRequest(.{ .draft = .{
        .session_id = "s",
        .title = "Run",
        .description = null,
        .subject = .{ .tool_call = nested_call },
        .options = &options,
    } }, &writer);
    const request = try decodePermissionRequest(.draft, writer.written(), &options_out, &scratch);
    try testing.expectEqualStrings(nested_call, request.draft.subject.?.tool_call);
    @memset(&out, 0xa5);
    writer = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodePermissionRequest(.{ .draft = .{
        .session_id = "s",
        .title = "Run",
        .description = null,
        .subject = .{ .tool_call = call },
        .options = &options,
    } }, &writer));
    try testing.expectEqualSlices(u8, &([_]u8{0xa5} ** out.len), &out);
}
