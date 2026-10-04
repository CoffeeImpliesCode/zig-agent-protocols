//! zig-agent-protocols — the root module.
//!
//! PROTOCOLS.md is the authority for every type name, tag value and byte layout
//! in this library. Where the source and that document disagree, the source is
//! wrong.
//!
//! The library models three wire protocols, the one defined composition
//! between them, and a runtime layer above the codec:
//!
//!   - [`mcp`]      — Model Context Protocol, revisions `2026-07-28` and
//!                    `2025-11-25`, decoded separately.
//!   - [`a2a`]      — Agent2Agent `1.0.0`.
//!   - [`acp`]      — Agent Client Protocol, wire version `1` with `2` gated.
//!   - [`bridge`]   — the `mcp-over-acp` binding.
//!   - [`jsonrpc`]  — the JSON-RPC 2.0 base that MCP and ACP both sit on.
//!   - [`json`]     — the borrowing reader and fixed-buffer writer under them.
//!
//! Above the codec sit [`framing`], [`conn`] and [`stdio`] for a byte
//! transport, [`http`] for the MCP Streamable HTTP one and [`a2a_http`] for
//! the A2A `1.0` unary JSON-RPC binding over `std.http`, and a session layer
//! per MCP and ACP protocol: [`mcp_session`], [`acp_session`] and
//! [`bridge_session`].
//!
//! Four modules under `src/` are deliberately not re-exported here.
//! `testkit.zig` is the property and differential harness, which the `fuzz`
//! step compiles as its own root so its generated documents never reach a
//! consumer's build. `testio.zig` is the shared test executor, which the build
//! adds to this module as the named import `testio`, and `bench_codec.zig` and
//! `bench_runtime.zig` are the two benchmark modules, which the `run-bench`
//! driver reaches as named imports of its own. The ten other roots under
//! `src/` are programs rather than library surface: five demonstrations, four
//! interoperability participants and the benchmark driver.
//!
//! Encoding contract, from PROTOCOLS.md section 2:
//!
//!   - Decoding is total. It returns a `DecodeError` and never `unreachable`,
//!     because every byte on these wires is attacker-controlled input.
//!   - Modeled wire values and represented presence round-trip; encoded JSON
//!     is stable after its first normalization. Source whitespace, modeled
//!     member order and string escapes are not lexical provenance. Opaque raw
//!     JSON carried by a model keeps its bytes; unmodeled members may be skipped.
//!   - Codec, framing, connection and session code allocates no wire storage.
//!     Returned values borrow caller input, scratch, arenas or output until
//!     reuse. Runtime objects retain caller buffers and backend capabilities:
//!     their owning type documents the required keepalive and cleanup.
//!     Borrowed `std.http.Client` and `Io` implementations may allocate for
//!     transport pools or execution; that is not a no-heap backend guarantee.
//!   - Closed enum decoders and revision method lookups reject unknown values
//!     rather than selecting a silent fallback. The generic JSON-RPC codec
//!     carries method text; protocol registries decide which names are supported.
//!
//! Supported consumer entry: the native Zig module `zig-agent-protocols`, using
//! stable Zig 0.16.0. The installed static archive is not a C ABI and does not
//! force analysis of every lazy declaration. Public type and method doc comments
//! define caller preconditions and error residue. Assertions diagnose caller
//! misuse in Debug and ReleaseSafe; ReleaseFast and ReleaseSmall do not turn
//! unchecked alias or lifetime misuse into a recoverable wire error.

const std = @import("std");

pub const a2a = @import("a2a.zig");
pub const acp = @import("acp.zig");
pub const bridge = @import("bridge.zig");
pub const json = @import("json.zig");
pub const jsonrpc = @import("jsonrpc.zig");
pub const mcp = @import("mcp.zig");
pub const conn = @import("conn.zig");
pub const mcp_session = @import("mcp_session.zig");
pub const acp_session = @import("acp_session.zig");
pub const bridge_session = @import("bridge_session.zig");
pub const http = @import("http.zig");
pub const a2a_http = @import("a2a_http.zig");
pub const framing = @import("framing.zig");
pub const stdio = @import("stdio.zig");

/// The single decode error set for the whole library.
///
/// It is the union of the per-protocol failure modes because a caller that
/// decodes bytes does not know in advance which protocol produced them.
///
/// This is a shared upper bound, not a claim that each decoder can return every
/// member. A failed decode returns no value; scratch and arenas may be dirty or
/// partly consumed as documented on the owning boundary. No error frees caller
/// storage. Inputs and writable decode regions must be separate.
pub const DecodeError = error{
    /// Input ended before the value was complete.
    Truncated,
    /// A byte sequence was not valid UTF-8 where the protocol requires text.
    InvalidUtf8,
    /// A JSON syntax error, or a value of the wrong JSON type.
    MalformedJson,
    /// A required field was absent.
    MissingField,
    /// A field was present with a value the protocol does not permit.
    InvalidField,
    /// An enum tag this library does not know.
    UnknownTag,
    /// A method name this library does not know for the negotiated revision.
    UnknownMethod,
    /// The peer's protocol version is not one this library implements.
    UnsupportedVersion,
    /// The caller-supplied output buffer was too small.
    BufferTooSmall,
    /// A limit the protocol states as a numeric bound was exceeded.
    LimitExceeded,
};

/// Shared upper bound for encoding failures; individual encoders use a subset.
///
/// Encoders reject the modeled conditions named in their contracts. Unchecked
/// text primitives require valid UTF-8 caller text; decoded strings satisfy it.
/// Writer-taking encoders document logical rollback or partial-prefix residue.
/// Backing bytes may be dirty on failure. Caller-owned source values must not
/// alias bytes the writer will overwrite.
pub const EncodeError = error{
    /// The caller's writable output cannot hold the complete encoding.
    BufferTooSmall,
    /// A value or raw JSON member is not valid for this wire shape.
    InvalidField,
    /// An enum/discriminator has no supported wire spelling.
    UnknownTag,
};

test {
    // Zig only runs tests in files a reference reaches, so name the modules here
    // rather than trusting the build to discover them.
    std.testing.refAllDecls(@This());
}
