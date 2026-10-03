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
//!
//! Every region is vetted where the caller passes it: a region with no room is
//! refused by [`Stdio.init`] or by [`conn.Conn.init`] rather than at the first
//! message, so a wiring mistake is never reported as a dead transport. Two
//! regions that share a byte are refused on the same terms, and no call is
//! handed all six of them, so the pairs that span [`Stdio.init`] and
//! [`conn.Conn.init`] are refused by [`Stdio.connection`], which is the one
//! call that sees both halves.

const std = @import("std");
const conn = @import("conn.zig");

/// The `std.Io` namespace, under the name this file's signatures use.
///
/// It is the same namespace and not a wrapper, so the `Io` a [`Stdio`] is
/// built over and the readers and writers a caller hands it are the standard
/// ones.
pub const Io = std.Io;

/// Standard input and output wired for a protocol connection.
///
/// ## Lifetime
///
/// A connection borrows this struct's reader and writer by pointer. Keep it
/// alive at a stable address until that connection's tasks finish; do not move
/// or copy it after `connection`. Its caller buffers and borrowed `Io` backend
/// must outlive it. No allocator or file ownership is transferred: standard
/// streams belong to the process and this type has no `deinit`.
///
/// One pump reads and Conn serializes writes. Do not concurrently flush or use
/// the raw interfaces outside Conn. Shut down or cancel blocked work and join
/// the caller-owned group before releasing any of these objects.
///
/// ```zig
/// // Wrong. The temporary dies at the end of the statement, and the
/// // connection reads a freed struct on its first frame.
/// var c = try Stdio.init(io, &r, &w).connection(config);
///
/// // Right. The streams live in a local that outlives the connection.
/// var stdio = try Stdio.init(io, &r, &w);
/// var c = try stdio.connection(config);
/// ```
pub const Stdio = struct {
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,

    /// Open the process's own streams. Neither is closed by this type: they
    /// belong to the process rather than to a connection.
    ///
    /// Falls with `error.UnusableBuffer` for a `read_buffer` or a
    /// `write_buffer` with no room, and with `error.OverlappingBuffers` for the
    /// two of them sharing a byte, and with nothing else. Both are checked
    /// before anything is built, so a refused call leaves no half-wired reader
    /// behind. `error.UnusableBuffer` is the error `conn.Conn.init` raises for
    /// a configuration region and the one name it raises it under, so the rule
    /// stays one rule over all six regions a connection is handed. It lands
    /// here rather than at [`Stdio.connection`] because this is the call that
    /// names the array: one call later a region with no room is one nobody can
    /// see, and a write buffer with no room comes back as `error.Transport`
    /// from the first frame, a dead socket for a wiring mistake the caller can
    /// still make. The overlap lands here on the same reasoning, and it is the
    /// one pair of the fifteen among a stdio connection's six regions that
    /// this call is the earliest to see; [`Stdio.connection`] says which call
    /// refuses the other fourteen.
    ///
    /// Returns streaming file adapters that retain both buffers and `io`.
    /// Neither buffer is initialized or written here; no stream I/O blocks.
    /// Sizes are caller policy. The backend must support streaming standard
    /// files; the type does not construct or certify a concrete executor.
    pub fn init(io: Io, read_buffer: []u8, write_buffer: []u8) conn.Error!Stdio {
        // One test per argument, in the order they are passed, rather than one
        // over both that cannot say which of them was short.
        if (read_buffer.len == 0) return error.UnusableBuffer;
        if (write_buffer.len == 0) return error.UnusableBuffer;
        // The one pair of the fifteen this call can see, because these two are
        // the only regions it is handed and it is the earliest call handed
        // both. A reader filling into the writer's storage writes bytes an
        // answer being composed there has not written yet, and nothing on the
        // wire reports it.
        if (conn.overlaps(read_buffer, write_buffer)) return error.OverlappingBuffers;
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
    ///
    /// Falls with `error.UnusableBuffer` for a configured region sized with no
    /// room and `error.OverlappingBuffers` for two regions that share a byte,
    /// and refuses both before it builds anything: a refused call leaves the
    /// caller's pending table exactly as it was handed over. Every fault is the
    /// caller's to fix by resizing or separating its buffers, and none of them
    /// is visible once a peer is on the wire, which is why they arrive here
    /// rather than at the first message.
    ///
    /// A stdio connection is handed six regions and there are fifteen pairs
    /// among them. No one call is handed all six, so the pairs are refused by
    /// the three calls that see them:
    ///
    /// - The six among the four configured regions are `conn.Conn.init`'s own:
    ///   the frame buffer against each handler region, and the pending table
    ///   against all three.
    /// - The one among the transport's own two regions is [`Stdio.init`]'s,
    ///   which is handed both of them and neither of the other four.
    /// - The eight that span the two calls are refused here, because this is
    ///   the only call handed a transport region and a configured region
    ///   together: `Stdio.init` never learns what the frame buffer is, and
    ///   `conn.Conn.init` never learns what the read and write buffers are. Left
    ///   unchecked they are silent rather than fatal: the reader's `fill`
    ///   writes into the framer's own storage, and an answer composed into the
    ///   write buffer lands inside a frame that has not been taken yet.
    ///
    /// The two compared here are the regions the reader and the writer hold
    /// now. After [`Stdio.init`] those are the caller's own arrays; a caller
    /// that replaced `reader` or `writer` after that has moved them, and what
    /// this checks is whatever the replacement was handed.
    ///
    /// Retains pointers into `self`; fix its address before this call. Success
    /// clears Config's pending slots, not transport buffers, and starts no task.
    /// Keep both transport regions and Config storage until all Conn work ends.
    pub fn connection(self: *Stdio, config: conn.Conn.Config) conn.Error!conn.Conn {
        // The eight pairs that neither [`Stdio.init`] nor the call below is
        // handed, compared before anything is built. The pending table as its
        // whole slice of bytes, because `conn.Conn.init` compares it the same
        // way and a table that overlaps anything is a race on bytes rather
        // than a wrong answer.
        const table = std.mem.sliceAsBytes(config.pending);
        for ([_][]const u8{
            self.reader.interface.buffer,
            self.writer.interface.buffer,
        }) |transport| {
            if (conn.overlaps(transport, config.frame_buffer)) return error.OverlappingBuffers;
            if (conn.overlaps(transport, table)) return error.OverlappingBuffers;
            if (conn.overlaps(transport, config.decode_scratch)) return error.OverlappingBuffers;
            if (conn.overlaps(transport, config.answer)) return error.OverlappingBuffers;
        }
        return conn.Conn.init(
            self.reader.io,
            &self.reader.interface,
            &self.writer.interface,
            config,
        );
    }

    /// Flush buffered standard output. Blocks on the borrowed file backend.
    ///
    /// Success drains this writer; cancellation returns `Canceled` and other
    /// file failures return its write errors. A prefix may already be written
    /// on failure. Do not race Conn writes or another flush. Conn itself flushes
    /// each frame; this is for direct buffered writes made outside live Conn use.
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
/// [`Buffers.config`] hands the connection the four it owns, and
/// [`Stdio.connection`] compares those four against `read` and `write`, so one
/// array handed to two of these fields is refused there rather than corrupting
/// the first frame that overlaps it. `read` and `write` are the pair
/// [`Stdio.init`] takes, and `out`, `result` and `params` are the per-call
/// buffers of [`conn.Conn.call`] and [`conn.Conn.notify`].
///
/// These capacities are a convenience policy, not wire limits or negotiated
/// defaults. Declare the struct at its final address before handing out slices.
/// Do not copy or move it while Stdio, Conn or a response borrows any field.
/// Undefined byte arrays become readable only in the extents a writer fills;
/// `Conn.init` initializes the pending table. Per-call arrays serve one issuer
/// at a time; concurrent calls need additional independent storage.
pub const Buffers = struct {
    /// Read buffer. Bounds one read from the stream.
    // SAFETY: `Stdio.init` refuses an empty one; the file reader reads back only bytes it filled.
    read: [4096]u8 = undefined,
    /// Write buffer. Should exceed the largest outbound frame.
    // SAFETY: `Stdio.init` refuses an empty one; the file writer writes only the bytes it holds.
    write: [4096]u8 = undefined,
    /// Frame buffer. Bounds one inbound message.
    // SAFETY: the framer fills it from the transport and yields only frames it has read whole.
    frame: [65536]u8 = undefined,
    /// Slots for calls that may be outstanding at once.
    // SAFETY: `Conn.init` clears every slot to `.{}` before the table is ever read.
    pending: [16]conn.Slot = undefined,
    /// The region an inbound frame is decoded into, and the region a handler
    /// is handed to decode one into. See [`conn.Conn.decode_scratch`].
    // SAFETY: a decode writes it before its result is read, and `Conn.init` refuses it empty.
    decode_scratch: [4096]u8 = undefined,
    /// The region a handler composes an answer into. It shares no byte with
    /// `decode_scratch`, because a handler that decoded into the region it
    /// writes its answer into has the writer's first bytes land on the value
    /// it is about to read; `conn.Conn.init` refuses a pair that overlaps.
    // SAFETY: the handler writes the envelope it returns into it; `Conn.init` refuses it empty.
    answer: [4096]u8 = undefined,
    /// Per-call buffers for the encode and the response.
    // SAFETY: the encoder fills it and only the slice it returns from it is read back.
    out: [8192]u8 = undefined,
    // SAFETY: `Conn.open` reads the answer in and reads it back as `[0..slot.len]`.
    result: [8192]u8 = undefined,
    // SAFETY: caller-written JSON spliced into the frame; only its encoded length is read.
    params: [8192]u8 = undefined,

    /// The four Config regions borrowed from this struct, with no mutation.
    ///
    /// Slices retain these field addresses. Keep this struct alive and unmoved
    /// until the connection's tasks finish; no storage or cleanup is transferred.
    pub fn config(self: *Buffers) conn.Conn.Config {
        return .{
            .frame_buffer = &self.frame,
            .pending = &self.pending,
            .decode_scratch = &self.decode_scratch,
            .answer = &self.answer,
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
    // SAFETY: `handle` copies into it and sets `len` in the same step, and reads `[0..len]`.
    frame: [256]u8 = undefined,
    len: usize = 0,

    /// Both regions are discarded, and the reason is the shape of a handler
    /// that decodes nothing: it has no borrowed value to keep alive and no
    /// envelope to compose, so it needs neither. A handler that does decode
    /// writes only into the first.
    fn handle(ctx: ?*anyopaque, frame: []const u8, _: []u8, _: []u8) conn.Error!?[]const u8 {
        // `conn.Handler.call` is a frozen signature whose context is
        // `?*anyopaque` and whose error set is `conn.Error`, so a handler
        // cannot report "there was no context" here without borrowing a fault
        // this transport does not have. Every registration of this function is
        // a `setHandler` in this file's own tests, and each hands it the
        // agent's address, so the absent case is unreachable.
        // zwanzig-disable-next-line: optional-unwrap
        const self: *EchoAgent = @ptrCast(@alignCast(ctx.?));
        const n = @min(frame.len, self.frame.len);
        @memcpy(self.frame[0..n], frame[0..n]);
        self.len = n;
        return "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"sessionId\":\"s-1\"}}";
    }
};

test "flush delivers buffered protocol bytes to a file" {
    var buffers: Buffers = .{};

    var stdio = try Stdio.init(testing.io, &buffers.read, &buffers.write);

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

test "a read buffer with no room is refused at the call that passed it" {
    var buffers: Buffers = .{};

    // The write region beside it is the full array, so this passes only when
    // the refusal is specific to the region that had no room. An `init` that
    // failed on either argument, or on every call, would fail this test for
    // the wrong reason, and one that refused nothing hands back a transport
    // where the error is.
    try testing.expectError(error.UnusableBuffer, Stdio.init(testing.io, &.{}, &buffers.write));
}

test "a write buffer with no room is refused at the call that passed it" {
    var buffers: Buffers = .{};

    // The mirror of the region above, and the one the fault was reported
    // against: this pair built a transport whose first frame failed inside
    // `Io.File.Writer`, which `Conn.writeFrame` maps to `error.Transport`, so
    // the caller was told the socket was dead for a buffer it had not been
    // told to check.
    try testing.expectError(error.UnusableBuffer, Stdio.init(testing.io, &buffers.read, &.{}));
}

test "a read buffer and a write buffer that share a byte are refused" {
    // One array carved two ways. Neither test above can catch this: each of
    // them passes one empty region and one full array, so an `init` that
    // compared nothing would pass both, and one that compared everything would
    // refuse nothing here. `Stdio.init` is the only call handed both regions,
    // so this pair is refused here or nowhere — `conn.Conn.init` is handed
    // neither, and `Stdio.connection` would have to look at what the reader
    // and the writer hold rather than at what the caller passed.
    //
    // The two halves are not the same array here on purpose: a reader filling
    // into the writer's storage writes bytes an answer being composed there has
    // not written yet, and nothing on the wire reports it.
    var shared: [8192]u8 = undefined;
    try testing.expectError(
        error.OverlappingBuffers,
        Stdio.init(testing.io, shared[0..4096], shared[0..4096]),
    );
}

test "the transport's two regions are checked against the connection's four" {
    // The eight pairs neither of the other two calls is handed: `Stdio.init`
    // sees the two transport regions and `conn.Conn.init` the four configured
    // ones, so a pair spanning the two is in neither. `Stdio.connection` is
    // handed both halves, and it is where this is refused.
    //
    // One array carved three ways. The frame buffer takes the head, which is
    // where the read buffer is, and the answer region takes the tail, which is
    // where the write buffer is: the two pairs a real caller hits, one per
    // direction. Both are silent rather than fatal without the refusal — the
    // reader's `fill` writes into the framer's own storage, and an answer
    // composed into the write buffer lands inside a frame that has not been
    // taken yet, so the peer reads one good frame and then a mangled one.
    // Aligned as a slot table as well as as bytes, because the third case
    // below reads the head of it as one.
    var shared: [65536 + 8192]u8 align(@alignOf(conn.Slot)) = undefined;
    var buffers: Buffers = .{};
    var slots: [4]conn.Slot = undefined;
    var stdio = try Stdio.init(testing.io, shared[0..4096], shared[65536..]);

    // The frame buffer against the read buffer.
    try testing.expectError(error.OverlappingBuffers, stdio.connection(.{
        .frame_buffer = shared[0..65536],
        .pending = &slots,
        .decode_scratch = &buffers.decode_scratch,
        .answer = &buffers.answer,
    }));
    // The answer region against the write buffer, with the frame buffer moved
    // clear so this fails on its own pair and not on the one above.
    try testing.expectError(error.OverlappingBuffers, stdio.connection(.{
        .frame_buffer = &buffers.frame,
        .pending = &slots,
        .decode_scratch = &buffers.decode_scratch,
        .answer = shared[65536..],
    }));
    // And the pending table against the read buffer, which is a race on bytes
    // rather than a wrong answer and is refused for the same reason. The
    // alignment cast is over the array's own declared alignment, so it costs
    // nothing to read.
    const table_in_read: []conn.Slot = @ptrCast(@alignCast(
        shared[0..@sizeOf(conn.Slot)],
    ));
    try testing.expectError(error.OverlappingBuffers, stdio.connection(.{
        .frame_buffer = &buffers.frame,
        .pending = table_in_read,
        .decode_scratch = &buffers.decode_scratch,
        .answer = &buffers.answer,
    }));

    // The same six regions, carved so that nothing shares a byte, build: the
    // refusal is about the pair and not about this transport. `Buffers` is what
    // a caller is meant to hand over, and it is disjoint by construction, so
    // this is the arrangement the check has to leave alone.
    _ = try stdio.connection(.{
        .frame_buffer = shared[4096..65536],
        .pending = &slots,
        .decode_scratch = &buffers.decode_scratch,
        .answer = &buffers.answer,
    });
}

test "a request off the transport is answered on the transport" {
    var buffers: Buffers = .{};
    var stdio = try Stdio.init(testing.io, &buffers.read, &buffers.write);

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
    var connection = try stdio.connection(buffers.config());
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
