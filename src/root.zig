//! zig-agent-proto — the root module.
//!
//! PROTOCOLS.md is the authority for every type name, tag value and byte layout
//! in this library. Where the source and that document disagree, the source is
//! wrong.
//!
//! The library models three wire protocols and the one defined composition
//! between them:
//!
//!   - [`mcp`]      — Model Context Protocol, revisions `2026-07-28` and
//!                    `2025-11-25`, decoded separately.
//!   - [`a2a`]      — Agent2Agent `1.0.0`.
//!   - [`acp`]      — Agent Client Protocol, wire version `1` with `2` gated.
//!   - [`bridge`]   — the `mcp-over-acp` binding.
//!   - [`jsonrpc`]  — the JSON-RPC 2.0 base that MCP and ACP both sit on.
//!
//! Encoding contract, from PROTOCOLS.md section 2:
//!
//!   - Decoding is total. It returns a `DecodeError` and never `unreachable`,
//!     because every byte on these wires is attacker-controlled input.
//!   - Encoding is the exact inverse: `decode(encode(x)) == x` and
//!     `encode(decode(b)) == b` for every accepted input.
//!   - Nothing allocates. The caller supplies every buffer; slices borrow from
//!     the caller's memory and nothing is retained past the call.
//!   - Unknown enum tags and unknown method names are errors, never a silent
//!     fallback, so a peer speaking a newer revision cannot crash an older one.

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
pub const framing = @import("framing.zig");
pub const stdio = @import("stdio.zig");

/// The single decode error set for the whole library.
///
/// It is the union of the per-protocol failure modes because a caller that
/// decodes bytes does not know in advance which protocol produced them.
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

/// The encode error set.
///
/// Smaller than `DecodeError` on purpose: encoding a value that could not have
/// been decoded is a programming error, not a wire condition.
pub const EncodeError = error{
    BufferTooSmall,
    InvalidField,
    UnknownTag,
};

test {
    // Zig only runs tests in files a reference reaches, so name the modules here
    // rather than trusting the build to discover them.
    std.testing.refAllDecls(@This());
}
