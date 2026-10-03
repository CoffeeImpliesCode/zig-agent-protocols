//! Newline-delimited frame assembly for the stdio-shaped transports.
//!
//! ACP and MCP over stdio both frame with a raw newline: PROTOCOLS.md 6.2 says
//! a message "MUST NOT contain embedded newlines", and a JSON string carrying
//! one is escaped by the encoder, so the delimiter stays unambiguous. This
//! module turns a byte stream into frames and back, and it is the only place
//! that knows a frame ends.
//!
//! It is transport-agnostic on purpose. A Streamable HTTP body is framed the
//! same way, and a test feeds it from a slice rather than a socket, so the
//! framing has to stand on its own.
//!
//! ## No allocation, and a hard bound
//!
//! The buffer is the caller's, so a peer that never sends a newline cannot
//! make this module grow: the framer copies into a fixed region and refuses
//! rather than allocating. The bound is on the bytes a caller offers, not on a
//! frame, and [`Framer.push`] is all-or-nothing about them. A chunk that does
//! not fit the free region is refused whole, with `error.FrameTooLarge` and no
//! copy at all, so a peer that fills the buffer without a delimiter in it is
//! refused on every later push and holds no more than the caller sized. That
//! is the difference between a client that refuses one message and one that
//! runs out of memory on a hostile stream.
//!
//! All-or-nothing has a cost the caller has to plan for, because the refused
//! chunk carried bytes that would have fitted on their own. A 1 KiB buffer
//! refuses a push of 200 eight-byte frames offered together, and the 200
//! frames are lost with it. Take every frame with [`Framer.next`] before
//! offering more bytes and this does not arise, because the next `push`
//! reclaims the space behind the frames already taken. A caller reading from
//! a transport should bound its read with [`Framer.freeSpace`] and report
//! [`Framer.filled`] instead, as `conn.Conn.pump` does. Then a frame that
//! outgrows the buffer is a full buffer with no delimiter in it, and the
//! caller decides what that means for the connection.
//!
//! The error set is deliberately its own rather than `DecodeError`: a frame
//! that does not fit is a transport condition, not a wire-format one, and
//! folding it into `DecodeError` would let a caller mistake a transport fault
//! for a peer speaking a protocol this library does not implement.

const std = @import("std");

/// The byte a frame ends with. Raw `\n`, because that is what the
/// specifications name. `\r` is tolerated on input and never written, so a
/// peer that sends CRLF is read rather than rejected.
pub const delimiter: u8 = '\n';

/// Every failure framing itself can report.
///
/// One member, and [`Framer.push`] is the only operation that produces one.
/// Writing is not in this set: [`writeFrame`] reports
/// [`std.Io.Writer.Error`], and it answers `error.WriteFailed` for a message
/// that carries a delimiter of its own.
pub const Error = error{
    /// The bytes offered did not fit the caller's buffer.
    ///
    /// Nothing is copied, so the offending bytes are not in the buffer and
    /// their length cannot be read back from it. What arrived before the
    /// refusal is still there, and [`Framer.partial`] reports it.
    FrameTooLarge,
};

/// Assembles frames from a byte stream into one caller-owned buffer.
///
/// The buffer is one linear run of three regions: complete frames waiting to
/// be taken, one partial frame being assembled, and free space. Sliding the
/// held bytes down to the front reclaims the space behind them, so a long
/// stream does not walk the buffer forward until it is exhausted.
pub const Framer = struct {
    buffer: []u8,
    /// Start of the region not yet handed to the caller.
    start: usize = 0,
    /// End of the bytes received but not yet consumed.
    end: usize = 0,

    /// Bind the caller's buffer to an empty framer.
    ///
    /// The buffer is the framer's whole storage and nothing is allocated, so
    /// it has to outlive the framer. Both cursors start at zero, so a fresh
    /// framer is not [`Framer.pending`] and has no frame to take.
    pub fn init(buffer: []u8) Framer {
        return .{ .buffer = buffer };
    }

    /// Add received bytes to the partial frame.
    ///
    /// All-or-nothing: on `error.FrameTooLarge` nothing is appended, so the
    /// caller can drain and report without having half a frame in the buffer.
    /// The offered chunk is the unit, so the complete frames it carried are
    /// discarded with it. Taking frames with [`Framer.next`] between pushes
    /// keeps the free region open and avoids the refusal.
    pub fn push(self: *Framer, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        self.compact();
        const free = self.buffer.len - self.end;
        if (bytes.len > free) return error.FrameTooLarge;
        @memcpy(self.buffer[self.end..][0..bytes.len], bytes);
        self.end += bytes.len;
    }

    /// The next complete frame, without the delimiter, or null when the bytes
    /// received do not contain one yet.
    ///
    /// An empty line yields an empty frame rather than null. The JSON layer
    /// refuses it, which is a better error than a connection that silently
    /// swallows a stray newline and waits forever for a message.
    pub fn next(self: *Framer) ?[]const u8 {
        const region = self.buffer[self.start..self.end];
        const at = std.mem.indexOfScalar(u8, region, delimiter) orelse return null;
        var frame = region[0..at];
        // Tolerate CRLF from a peer that sends it. The `\r` is not part of the
        // message and would otherwise make an otherwise valid frame fail to
        // decode.
        if (frame.len != 0 and frame[frame.len - 1] == '\r') frame = frame[0 .. frame.len - 1];
        self.start += at + 1;
        return frame;
    }

    /// Whether any received byte is still held, whether or not it completes
    /// a frame. A framer with a complete frame the caller has not taken is
    /// still pending, so a caller cannot use this to ask whether a frame is
    /// ready.
    pub fn pending(self: *const Framer) bool {
        return self.start != self.end;
    }

    /// The bytes received and not yet taken, complete frames included.
    ///
    /// This is the size report available after `error.FrameTooLarge`: what
    /// arrived before the refused push is still here, and the bytes of the
    /// refused push are nowhere.
    pub fn partial(self: *const Framer) []const u8 {
        return self.buffer[self.start..self.end];
    }

    /// Slide the unconsumed bytes to the front so a full buffer can be reused
    /// instead of being reported as full while holding only one byte.
    pub fn slide(self: *Framer) void {
        self.compact();
    }

    /// The free region a caller may read into directly.
    ///
    /// Reading straight into the framer avoids a copy per frame, which is the
    /// whole cost of a byte stream on the hot path. The next `push` or `slide`
    /// overwrites the region, and [`Framer.filled`] consumes its front, so the
    /// caller must record what it read before touching the framer again.
    /// `next` leaves the region alone: it only advances the start of what has
    /// already been received.
    pub fn freeSpace(self: *Framer) []u8 {
        return self.buffer[self.end..];
    }

    /// Record `count` bytes read into the region from [`Framer.freeSpace`].
    pub fn filled(self: *Framer, count: usize) void {
        std.debug.assert(count <= self.buffer.len - self.end);
        self.end += count;
    }

    /// Drop everything received so far.
    ///
    /// The caller uses this after a fatal framing error so one hostile frame
    /// does not poison every frame after it.
    pub fn reset(self: *Framer) void {
        self.start = 0;
        self.end = 0;
    }

    /// [`Framer.slide`] under its internal name, because [`Framer.push`] needs
    /// the same move before it can measure the free region and has no slide
    /// step in its own contract.
    fn compact(self: *Framer) void {
        if (self.start == 0) return;
        const held = self.end - self.start;
        if (held != 0) @memmove(self.buffer[0..held], self.buffer[self.start..self.end]);
        self.start = 0;
        self.end = held;
    }
};

/// Write one frame and its delimiter.
///
/// Refuses a message containing a raw newline. The caller has already broken
/// the framing by the time those bytes reach the wire, and writing them would
/// split one message into two that the peer then fails to decode.
pub fn writeFrame(bytes: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.mem.indexOfScalar(u8, bytes, delimiter) != null) return error.WriteFailed;
    try writer.writeAll(bytes);
    try writer.writeByte(delimiter);
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test "one frame per newline, and several frames in one push" {
    var buffer: [256]u8 = undefined;
    var framer = Framer.init(&buffer);

    try framer.push("{\"a\":1}\n{\"b\":2}\n");
    // Two complete frames are held and neither has been taken, so this is
    // pending. A framer that reported false until a frame was complete would
    // report false here. A caller polling it would then read both frames
    // twice.
    try testing.expect(framer.pending());
    try testing.expectEqualStrings("{\"a\":1}", framer.next().?);
    try testing.expect(framer.pending());
    try testing.expectEqualStrings("{\"b\":2}", framer.next().?);
    try testing.expectEqual(@as(?[]const u8, null), framer.next());
    try testing.expect(!framer.pending());
}

test "a frame split across pushes is reassembled" {
    var buffer: [256]u8 = undefined;
    var framer = Framer.init(&buffer);

    // A socket read boundary lands wherever it lands, so a frame routinely
    // arrives in pieces. Returning null early here would be the bug this
    // guards against.
    try framer.push("{\"json");
    try testing.expectEqual(@as(?[]const u8, null), framer.next());
    try testing.expect(framer.pending());
    try framer.push("rpc\":\"2.0\"}");
    try testing.expectEqual(@as(?[]const u8, null), framer.next());
    try framer.push("\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", framer.next().?);
}

test "CRLF is tolerated on input" {
    var buffer: [64]u8 = undefined;
    var framer = Framer.init(&buffer);
    try framer.push("{}\r\n");
    // The `\r` is transport noise, not message content, so keeping it would
    // make an otherwise valid frame fail to decode.
    try testing.expectEqualStrings("{}", framer.next().?);
}

test "an empty line is an empty frame, not silence" {
    var buffer: [64]u8 = undefined;
    var framer = Framer.init(&buffer);
    try framer.push("\n");
    // Returning null here would leave a connection waiting forever for a
    // message that already arrived and was malformed.
    try testing.expectEqualStrings("", framer.next().?);
}

test "a frame larger than the buffer is refused, and none of it is kept" {
    var buffer: [16]u8 = undefined;
    var framer = Framer.init(&buffer);

    try testing.expectError(error.FrameTooLarge, framer.push("{\"text\":\"far too long for this\"}"));
    // The push is all-or-nothing, so not one of the offending bytes is in the
    // buffer. A push that copied first and failed afterwards would leave the
    // framer holding the start of a frame it can never complete. This
    // assertion is what catches that.
    try testing.expectEqualStrings("", framer.partial());
    framer.reset();
    try testing.expect(!framer.pending());

    // The refusal leaves the framer usable, which is what lets a caller
    // resynchronise after one hostile frame instead of tearing the
    // connection down.
    try framer.push("{\"a\":1}\n");
    try testing.expectEqualStrings("{\"a\":1}", framer.next().?);
}

test "an oversized read discards the frames it carried, and draining between reads keeps them" {
    // The bound is on the bytes offered, not on a frame, and the refusal is
    // all-or-nothing. Offering 200 small frames in one push and expecting
    // every one of them to survive would pin the opposite rule, the one the
    // code does not implement.
    const frame = "{\"a\":1}\n";
    var chunk: [200 * frame.len]u8 = undefined;
    for (0..200) |i| @memcpy(chunk[i * frame.len ..][0..frame.len], frame[0..]);

    var buffer: [1024]u8 = undefined;
    var framer = Framer.init(&buffer);

    try testing.expectError(error.FrameTooLarge, framer.push(&chunk));
    // The chunk did not fit, so not one of its bytes is in the buffer and the
    // 200 complete frames it carried are gone. This is the consequence the
    // module doc names, and the part a caller has to be able to reason about.
    try testing.expectEqualStrings("", framer.partial());
    try testing.expectEqual(@as(?[]const u8, null), framer.next());

    // Offered one at a time, the same 200 frames all survive, because the
    // next push reclaims the space behind a frame already taken. Draining
    // between pushes is what keeps a reader off the refusal.
    for (0..200) |_| {
        try framer.push(frame);
        try testing.expectEqualStrings("{\"a\":1}", framer.next().?);
    }
    try testing.expect(!framer.pending());
}

test "a peer that sends no delimiter fills the buffer, and every later push is refused" {
    // The bound the module doc claims. The framer cannot know that the bytes
    // it holds are one frame until a delimiter arrives, so a full buffer is
    // what ends the stream: a peer that never sends a newline gets a refusal
    // instead of memory the caller never sized.
    const unterminated = "{\"jsonrpc\":1}";
    var buffer: [unterminated.len]u8 = undefined;
    var framer = Framer.init(&buffer);

    try framer.push(unterminated);
    try testing.expectEqual(@as(?[]const u8, null), framer.next());
    // The buffer is full, so the delimiter that would end this frame has
    // nowhere to go, and the push carrying it is refused like any other.
    try testing.expectError(error.FrameTooLarge, framer.push("\n"));
    // What arrived before the refusal is still here, so a caller can report
    // it and resynchronise rather than guess.
    try testing.expectEqualStrings(unterminated, framer.partial());

    framer.reset();
    try framer.push("{}\n");
    try testing.expectEqualStrings("{}", framer.next().?);
}

test "the buffer is reused across many frames without running out" {
    // This is the case a naive start/end pair fails: every frame is taken, but
    // the write cursor only moves forward, so the buffer looks full after a
    // few hundred bytes no matter how small each frame is.
    var buffer: [64]u8 = undefined;
    var framer = Framer.init(&buffer);
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try framer.push("{\"n\":1}\n");
        try testing.expectEqualStrings("{\"n\":1}", framer.next().?);
    }
}

test "writeFrame refuses an embedded newline" {
    var out: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.WriteFailed, writeFrame("{\"a\":\n1}", &writer));

    writer = std.Io.Writer.fixed(&out);
    try writeFrame("{\"a\":1}", &writer);
    try testing.expectEqualStrings("{\"a\":1}\n", writer.buffered());
}

test "freeSpace and filled let a caller read straight into the framer" {
    // Reading into the framer instead of a scratch buffer and copying is the
    // difference between one copy per frame and none.
    var buffer: [64]u8 = undefined;
    var framer = Framer.init(&buffer);
    framer.slide();

    const space = framer.freeSpace();
    try testing.expectEqual(@as(usize, 64), space.len);
    @memcpy(space[0..3], "abc");
    // Three bytes went in, so three are recorded. Recording a fourth would
    // put one byte of uninitialised memory into the region the framer reads
    // and frames, which is the one thing `filled` exists to prevent.
    framer.filled(3);
    // `filled` consumed the front of the region it was given, so the slice
    // the caller still holds is no longer the free space.
    try testing.expectEqual(@as(usize, 61), framer.freeSpace().len);

    // A push lands in the same region, so a caller still holding the slice
    // would read its own earlier bytes back as frame data.
    try framer.push("d");
    try testing.expectEqual(@as(usize, 60), framer.freeSpace().len);

    @memcpy(framer.freeSpace()[0..2], "e\n");
    framer.filled(2);
    try testing.expectEqualStrings("abcde", framer.next().?);
}
