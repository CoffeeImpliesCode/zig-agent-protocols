//! The stdio transport: a connection over this process's own standard streams.
//!
//! ACP names stdio as its only normative transport and PROTOCOLS.md 6.2 makes
//! it normative there: UTF-8, newline-delimited, no embedded newlines, and the
//! agent must not write non-ACP bytes to stdout. MCP over stdio uses the same
//! framing, so both get this one adapter rather than two.
//!
//! This is deliberately a thin adapter. The framing is [`framing`], the
//! JSON-RPC is [`conn`], and everything above them is protocol-specific; what
//! is left for a transport to do is open two streams and hand them over. The
//! one rule it does enforce is the stdout rule, because a stray `print` in an
//! agent corrupts the protocol stream and the failure looks like a parse error
//! three layers away.
//!
//! ## Buffering
//!
//! Both directions get caller-owned buffers. The read buffer bounds how much
//! may arrive per syscall, and the frame buffer is what bounds a message; a
//! peer that sends a message larger than the frame buffer is refused rather
//! than buffered without limit.

const std = @import("std");
const conn = @import("conn.zig");

pub const Io = std.Io;

/// Standard input and output wired for a protocol connection.
pub const Stdio = struct {
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,

    /// Open the process's own streams. Neither is closed by this type: they
    /// belong to the process, not to a connection, and closing stdout would
    /// take the exit status reporting with it.
    pub fn init(io: Io, read_buffer: []u8, write_buffer: []u8) Stdio {
        return .{
            .reader = std.Io.File.stdin().reader(io, read_buffer),
            .writer = std.Io.File.stdout().writer(io, write_buffer),
        };
    }

    /// Build a connection over these streams.
    pub fn connection(self: *Stdio, config: conn.Conn.Config) conn.Conn {
        return conn.Conn.init(
            self.reader.io,
            &self.reader.interface,
            &self.writer.interface,
            config,
        );
    }

    /// Flush anything buffered. A caller must do this before exiting or the
    /// last frame is lost, which reads to the peer as a truncated message.
    pub fn flush(self: *Stdio) !void {
        try self.writer.flush();
    }
};

/// The buffers a stdio connection needs, sized by the caller.
///
/// Grouped in one struct because a caller that has to supply six buffers to
/// set up a connection will get at least one of them wrong, and the pairing
/// that matters is the frame buffer against the largest message the peer may
/// send.
pub const Buffers = struct {
    /// Read buffer. Bounds one read from the stream.
    read: [4096]u8 = undefined,
    /// Write buffer. Should exceed the largest outbound frame.
    write: [4096]u8 = undefined,
    /// Frame buffer. Bounds one inbound message.
    frame: [65536]u8 = undefined,
    /// Slots for calls that may be outstanding at once.
    pending: [16]conn.Slot = undefined,
    decode_scratch: [4096]u8 = undefined,
    handler_scratch: [4096]u8 = undefined,
    /// Per-call buffers for the encode and the response.
    out: [8192]u8 = undefined,
    result: [8192]u8 = undefined,
    params: [8192]u8 = undefined,

    pub fn config(self: *Buffers) conn.Conn.Config {
        return .{
            .frame_buffer = &self.frame,
            .pending = &self.pending,
            .decode_scratch = &self.decode_scratch,
            .handler_scratch = &self.handler_scratch,
        };
    }
};

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test "the buffer group produces a config the connection accepts" {
    var buffers: Buffers = .{};
    const config = buffers.config();
    // Every slice the connection is given has to be non-empty: a zero-length
    // pending table would make every call report `TooManyPending`, and a
    // zero-length frame buffer would refuse the first message.
    try testing.expect(config.frame_buffer.len != 0);
    try testing.expect(config.pending.len != 0);
    try testing.expect(config.decode_scratch.len != 0);
    try testing.expect(config.handler_scratch.len != 0);
}

test "the read buffer is smaller than the frame buffer, as framing requires" {
    // The frame buffer is what bounds a message. If the read buffer were the
    // larger of the two, a caller would reasonably conclude the buffer is big
    // enough when the frame buffer is the one that has to be.
    const buffers: Buffers = .{};
    try testing.expect(buffers.read.len < buffers.frame.len);
}
