//! The stdio transport: a connection over this process's own standard streams.
//!
//! ACP names stdio as its only normative transport and PROTOCOLS.md 6.2 makes
//! it normative there: UTF-8, newline-delimited, no embedded newlines, and the
//! agent must not write non-ACP bytes to stdout. MCP over stdio uses the same
//! framing, so both get this one adapter rather than two.
//!
//! This is deliberately a thin adapter. The framing is [`framing`], the
//! JSON-RPC is [`conn`], and everything above them is protocol-specific; what
//! is left for a transport to do is open two streams and hand them over.
//! Keeping non-protocol bytes off standard output is the caller's rule, and
//! nothing in this type enforces it.
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
///
/// ## Lifetime
///
/// A connection borrows this struct's reader and writer by pointer, so this
/// struct has to outlive the connection built from it. `AGENTS.md` records
/// the same rule for `conn.Conn`.
///
/// ```zig
/// // Wrong. The temporary dies at the end of the statement, and the
/// // connection reads a freed struct on its first frame.
/// var c = Stdio.init(io, &r, &w).connection(config);
///
/// // Right. The streams live in a local that outlives the connection.
/// var stdio = Stdio.init(io, &r, &w);
/// var c = stdio.connection(config);
/// ```
pub const Stdio = struct {
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,

    /// Open the process's own streams. Neither is closed by this type: they
    /// belong to the process rather than to a connection.
    pub fn init(io: Io, read_buffer: []u8, write_buffer: []u8) Stdio {
        // Streaming, not the positional default. A pipe is unseekable, so the
        // positional default finds that out by failing a syscall and then
        // falling back, and the streaming constructors skip the failed call
        // entirely. The fallback is survivable, but it is a wasted syscall
        // before the first byte of a connection moves.
        return .{
            .reader = std.Io.File.stdin().readerStreaming(io, read_buffer),
            .writer = std.Io.File.stdout().writerStreaming(io, write_buffer),
        };
    }

    /// Build a connection over these streams. The result borrows `self`, so
    /// `self` must outlive it; see the lifetime rule on [`Stdio`].
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
/// Grouped in one struct because a caller that has to supply nine buffers to
/// set up a connection will get at least one of them wrong, and the pairing
/// that matters is the frame buffer against the largest message the peer may
/// send.
///
/// [`Buffers.config`] hands the connection the four it owns. `read` and
/// `write` are the pair [`Stdio.init`] takes, and `out`, `result` and `params`
/// are the per-call buffers of [`conn.Conn.call`] and [`conn.Conn.notify`].
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

test {
    // Zig analyses only what a test reaches. The root module reaches this
    // file, not the bodies in it, so a declaration nothing names has never
    // been type-checked. Every test below drives what it names.
    testing.refAllDecls(@This());
}

/// Records the frame the transport delivered, and answers it.
///
/// The answer is a literal, so it outlives the handler. Its id is the
/// request's, because a response is matched by id and by nothing else.
const EchoAgent = struct {
    frame: [256]u8 = undefined,
    len: usize = 0,

    fn handle(ctx: ?*anyopaque, frame: []const u8, _: []u8) conn.Error!?[]const u8 {
        const self: *EchoAgent = @ptrCast(@alignCast(ctx.?));
        const n = @min(frame.len, self.frame.len);
        @memcpy(self.frame[0..n], frame[0..n]);
        self.len = n;
        return "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"sessionId\":\"s-1\"}}";
    }
};

test "the transport is the process's own streams, and flush pushes them out" {
    var buffers: Buffers = .{};

    // A consumer starts here, so what `init` builds is asserted rather than
    // assumed. The wrong descriptor, the positional default on an unseekable
    // pipe, or a buffer the caller did not supply each fail this test.
    var stdio = Stdio.init(testing.io, &buffers.read, &buffers.write);
    try testing.expect(std.Io.File.stdin().handle == stdio.reader.file.handle);
    try testing.expect(std.Io.File.stdout().handle == stdio.writer.file.handle);
    try testing.expect(std.meta.eql(testing.io, stdio.reader.io));
    try testing.expect(std.meta.eql(testing.io, stdio.writer.io));
    try testing.expectEqual(std.Io.File.Reader.Mode.streaming, stdio.reader.mode);
    try testing.expectEqual(std.Io.File.Writer.Mode.streaming, stdio.writer.mode);
    // Compared as slices, not as pointers: what the assertion is about is
    // that the reader and the writer were handed the caller's buffers, and a
    // slice says so without caring how the buffer is stored.
    try testing.expectEqualSlices(
        u8,
        &buffers.read,
        stdio.reader.interface.buffer[0..buffers.read.len],
    );
    try testing.expectEqualSlices(
        u8,
        &buffers.write,
        stdio.writer.interface.buffer[0..buffers.write.len],
    );

    // The writer `init` built is the process's standard output. A byte
    // written there corrupts the message stream the test runner speaks over
    // that descriptor. So the write half is pointed at a file in a temporary
    // directory. The buffering is real, the flush is real, and the bytes are
    // on the descriptor. Nothing is left on the process's own output.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sink = try tmp.dir.createFile(testing.io, "out", .{});
    defer sink.close(testing.io);
    stdio.writer = sink.writerStreaming(testing.io, &buffers.write);

    const frame = "{\"jsonrpc\":\"2.0\"}\n";
    try stdio.writer.interface.writeAll(frame);
    // Buffered, not sent. A transport that lost the last frame on exit passes
    // a test that only inspects the encode buffer.
    try testing.expect(stdio.writer.interface.buffered().len != 0);
    try stdio.flush();
    try testing.expectEqual(@as(usize, 0), stdio.writer.interface.buffered().len);

    // The frame is on the descriptor, not merely accounted for. The count
    // comes from the literal rather than a hand tally, because the payload is
    // seventeen bytes and the delimiter makes eighteen, and reading seventeen
    // back reports a frame that starts one byte late.
    const read_back = try tmp.dir.openFile(testing.io, "out", .{});
    defer read_back.close(testing.io);
    // Two arrays, not one. The reader's own buffer must not alias the
    // destination: the read lands in the reader's buffer and is copied out
    // from there, so an aliased destination loses its leading byte.
    var read_buffer: [64]u8 = undefined;
    var back: [64]u8 = undefined;
    var read_handle = read_back.readerStreaming(testing.io, &read_buffer);
    try read_handle.interface.readSliceAll(back[0..frame.len]);
    try testing.expectEqualStrings(frame, back[0..frame.len]);
}

test "a request off the transport is answered on the transport" {
    var buffers: Buffers = .{};
    var stdio = Stdio.init(testing.io, &buffers.read, &buffers.write);

    // The two interfaces are replaced with in-memory ones. A `Stdio` bound to
    // the process's own streams cannot be driven by a test. Reading standard
    // input blocks until a peer speaks, and a byte written to standard output
    // corrupts the message stream the test runner speaks over that
    // descriptor. Everything above the two interfaces is the real thing, and
    // that is exactly what `connection` hands to `Conn`.
    stdio.reader.interface = Io.Reader.fixed(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\"}}\n",
    );
    var sent: [512]u8 = undefined;
    stdio.writer.interface = Io.Writer.fixed(&sent);

    // `stdio` is a local that outlives `connection`, not a temporary on the
    // right of a dot. The connection keeps raw pointers to both interfaces,
    // and a temporary would leave it reading freed memory on its first frame.
    var agent: EchoAgent = .{};
    var connection = stdio.connection(buffers.config());
    connection.setHandler(.{ .ctx = &agent, .call = EchoAgent.handle });

    const progress = "{\"progress\":1}";
    @memcpy(buffers.params[0..progress.len], progress);
    try connection.notify("notifications/progress", buffers.params[0..progress.len], &buffers.out);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}",
        buffers.out[0..connection.lastEncodedLen()],
    );

    // The pump reads one message and then end of stream, so it returns on its
    // own rather than parking on a stream nobody writes to.
    connection.pump();

    // The request arrived whole, which it cannot do unless the framer framed
    // the bytes the reader delivered.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\"}}",
        agent.frame[0..agent.len],
    );
    // And the answer went back out over the same streams, after the
    // notification, as two well-formed frames in one buffer.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"sessionId\":\"s-1\"}}\n",
        stdio.writer.interface.buffered(),
    );
}
