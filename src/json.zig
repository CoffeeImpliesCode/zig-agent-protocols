//! Borrowing JSON reader and fixed-buffer writer.
//!
//! PROTOCOLS.md section 2 requires that no decode or encode path allocate, and
//! that the caller supply every buffer. That rules out `std.json.parseFromSlice`,
//! which builds a whole owned tree before the protocol decoder sees a byte. It
//! also rules out `std.json.Value`, whose `Array` and `ObjectMap` both own heap
//! memory.
//!
//! Nothing here calls `std.json`. The writer is `byte`, `slice` and `string`,
//! and a protocol encoder composes a message out of those, so no encode path
//! reaches a value tree either.
//!
//! So this module is a pull parser. The reader walks the caller's input and
//! hands back slices that borrow from it. A string containing no escape sequence
//! is returned as a sub-slice of the input and costs nothing; a string that does
//! contain one is unescaped into a fresh region of a caller-supplied scratch
//! buffer. Either way the caller decides the memory, and the returned slice
//! never outlives it.
//!
//! Scratch regions are handed out one after another and never reused, so two
//! strings decoded from one reader can both be held at once. That is not a
//! nicety: a decoded message keeps `method` and `params` side by side, and a
//! scheme that rewrote the first region while decoding the second would corrupt
//! a message that is otherwise perfectly well formed.
//!
//! Nesting is bounded. An adversarial peer can send `[[[[[...` forever, and a
//! recursive skip would turn that into a stack overflow, which is a crash and
//! not a decode error. `max_depth` turns it into `error.LimitExceeded`.
//!
//! The published surface is [`Reader`], [`Writer`], [`base64`],
//! [`memberText`] and [`max_depth`]; every other name here is implementation
//! behind those. Reading one member out of a document is
//!
//!     var reader = Reader.init(input);
//!     const text = reader.memberRaw("name", &scratch) catch unreachable;
//!
//! Every buffer is the caller's and nothing here owns anything, so there is no
//! teardown to call and no allocation to release.

const std = @import("std");
const root = @import("root.zig");
// The one decode and the one encode error set for the whole library, per
// PROTOCOLS.md section 2.1. A second set declared here would let a caller
// compare a failure against the wrong one and report a wire condition as a
// programming error.
const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

/// Maximum container nesting accepted while decoding.
///
/// The bound is a decoding budget, not a protocol constant: no legitimate
/// MCP, A2A or ACP message nests this deep, and the bound exists so that
/// hostile input is an error rather than a stack overflow.
pub const max_depth = 64;

/// A cursor over a caller-owned JSON document.
///
/// `input` is borrowed for the whole life of the reader. Every slice handed
/// back by `string` either points into `input` or into the caller's scratch
/// buffer, so the caller chooses the memory and nothing outlives it.
///
/// ## The scratch contract
///
/// `string(scratch)` decodes a JSON escape into the *unread tail* of `scratch`
/// and advances a high-water mark past it, so two strings decoded from one
/// reader never alias and a decoded struct can hold both for as long as the
/// buffer is alive. A string with no escape borrows `input` and consumes no
/// scratch at all, so a caller that expects only plain text may pass a
/// zero-length buffer. What the buffer must cover is the *sum* of every
/// escaped string in the document, not the largest one: regions are never
/// recycled, because recycling is the aliasing this design exists to prevent.
///
/// `requiredScratchLen` measures that sum from the document before the
/// decode, so a caller sizes its buffer from the bytes it was handed
/// instead of guessing at a constant that has to cover the worst case.
///
/// `skipValue` and `rawValue` need no scratch and take none, so stepping over
/// a member the decoder does not model can never consume the region a modelled
/// member is about to be given.
///
/// [`Reader.nextKeyRaw`] is the third step that needs none: a member name a
/// caller only compares against a spelling it already holds is handed back as
/// the peer's own bytes, validated and undecoded, so a document full of escaped
/// names in members nobody models costs no buffer at all.
///
/// `input` and the scratch buffer must not overlap. The escaped path copies
/// out of `input` into `scratch` as it goes, so two buffers sharing bytes have
/// the copy overwrite the bytes it has yet to read. Nothing checks this in any
/// optimize mode — it is a precondition on the caller — and a caller handing
/// one buffer to both roles has to size it as the union of both.
pub const Reader = struct {
    /// The document. It has to stay alive and unmodified for the life of the
    /// reader, and it must not overlap the scratch buffer handed to `string`.
    input: []const u8,
    /// The cursor. Writable, because the reader it composes with is the
    /// caller's: a body decoded from a nested value is a second `Reader` over
    /// that text rather than a rewind of this one.
    pos: usize = 0,
    /// Containers currently open, bounded by [`max_depth`]. Writable for the
    /// same reason `pos` is, so a caller can charge a spliced body for the
    /// containers the frame around it already holds: a body that lands inside
    /// one frame object starts at one.
    depth: u32 = 0,
    /// High-water mark of the scratch buffer: the first byte not yet handed to
    /// a decoded string.
    ///
    /// Writable for the same reason `depth` is. A caller that hands one
    /// scratch buffer to a second `Reader` over a spliced body copies the
    /// outer reader's mark into this one, so the body decodes above the
    /// regions the frame already handed out instead of over them. The buffer
    /// behind the mark must then be the same one for the life of both readers:
    /// this is an index into that buffer, not a byte count.
    bump: usize = 0,

    /// Whether the container open at each depth has yielded a member or an
    /// element yet. Indexed by `depth`, which `enterContainer` bounds by
    /// `max_depth`, so the array is never indexed out of range.
    has_member: [max_depth + 1]bool = @splat(false),

    /// A reader positioned at the first byte of `input`.
    ///
    /// `input` is borrowed, not copied, and has to stay alive and unmodified
    /// for as long as this reader is used. A fresh reader is at depth zero
    /// with no container open, so `beginObject` or `beginArray` may be called
    /// on it directly. Reading costs no scratch until a string carrying an
    /// escape is reached.
    pub fn init(input: []const u8) Reader {
        return .{ .input = input };
    }

    /// The scratch a decode of `input` can consume, in bytes.
    ///
    /// Only a string that carries an escape reaches the buffer, so the sum
    /// is over the *decoded* width of every escaped string in the document
    /// and not over its source width: `"\n"` costs one byte, `"\ud83d\ude00"`
    /// costs four. A string with no escape borrows `input` and costs nothing.
    ///
    /// The count is an upper bound for any one decoder, because this scan
    /// cannot know which members that decoder models: a value it skips
    /// unescapes nothing and is counted anyway. Over-counting costs a few
    /// bytes of buffer. Under-counting would cost a `BufferTooSmall` on a
    /// document the caller sized from this number, so the count is exact
    /// for every document that decodes: each escape adds the width
    /// `stringEscaped` writes for it, and an escape this scan cannot read is
    /// one that stops the decode before it needs the space.
    ///
    ///     const text = ...;
    ///     var scratch: [Reader.requiredScratchLen(text)]u8 = undefined;
    ///
    /// One pass over the document and no allocation, so measuring is not
    /// cheaper than guessing but is correct where a guess is not. The value
    /// is comptime-known whenever the document is, which is what lets it size
    /// a stack array in the position the reader is created in.
    pub fn requiredScratchLen(input: []const u8) usize {
        var total: usize = 0;
        var pos: usize = 0;
        while (pos < input.len) {
            if (input[pos] != '"') {
                pos += 1;
                continue;
            }
            const body_start = pos + 1;
            pos = body_start;
            while (pos < input.len) : (pos += 1) {
                const byte = input[pos];
                // A backslash covers the byte after it, so an escaped quote
                // closes nothing.
                if (byte == '\\') {
                    pos += 1;
                    continue;
                }
                if (byte == '"') break;
            }
            // An unterminated string is a decode error, so nothing past it
            // is ever read and nothing past it has to be counted.
            if (pos >= input.len) return total;
            if (escapedLen(input[body_start..pos])) |width| total += width;
            pos += 1;
        }
        return total;
    }

    /// The scratch a string body decodes to, or null when it needs none.
    ///
    /// Every escape read here is one `stringEscaped` also reads, and every
    /// width added is the width that one writes. A body with no backslash
    /// comes back from `string` as a slice of the input, so it is null
    /// rather than zero: the caller then adds nothing at all.
    fn escapedLen(body: []const u8) ?usize {
        var total: usize = 0;
        var pos: usize = 0;
        var escaped = false;
        count: while (pos < body.len) {
            if (body[pos] != '\\') {
                total += 1;
                pos += 1;
                continue;
            }
            escaped = true;
            pos += 1;
            // A backslash with nothing after it is a truncated document, and
            // the count ends where the decode ends.
            if (pos >= body.len) break :count;
            const escape = body[pos];
            pos += 1;
            switch (escape) {
                // Each of these one characters stands for one output byte.
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => total += 1,
                'u' => {
                    const width = unicodeLen(body, &pos) orelse break :count;
                    total += width;
                },
                // Not an escape JSON defines, so `stringEscaped` refuses
                // here and the rest of the body is never written.
                else => break :count,
            }
        }
        return if (escaped) total else null;
    }

    /// The width a `\u` escape decodes to, advancing `pos` past what it read.
    ///
    /// A surrogate pair is one code point in four bytes spread over two
    /// escapes, which is the join `unicodeEscape` performs and this must
    /// count the same way. Null ends the count at an escape that is not one:
    /// truncated hex, or a pairing the decoder refuses.
    fn unicodeLen(body: []const u8, pos: *usize) ?usize {
        if (pos.* + 4 > body.len) return null;
        const unit = std.fmt.parseInt(u32, body[pos.*..][0..4], 16) catch return null;
        pos.* += 4;
        if (unit < 0xd800 or unit > 0xdfff) {
            var encoded: [4]u8 = undefined;
            const width = std.unicode.utf8Encode(@intCast(unit), &encoded) catch return null;
            return width;
        }
        // A surrogate is half a pair, not a character. A trailing one with no
        // high half ahead of it is the same fault the decoder calls
        // `InvalidUtf8`, so the count stops rather than guessing.
        if (unit > 0xdbff) return null;
        if (pos.* + 6 > body.len) return null;
        if (body[pos.*] != '\\' or body[pos.* + 1] != 'u') return null;
        pos.* += 2;
        if (pos.* + 4 > body.len) return null;
        const low = std.fmt.parseInt(u32, body[pos.*..][0..4], 16) catch return null;
        if (low < 0xdc00 or low > 0xdfff) return null;
        pos.* += 4;
        return 4;
    }

    /// The next byte without consuming it, or null at end of input.
    pub fn peek(self: *const Reader) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    /// A byte that is not JSON whitespace terminates the document.
    fn fail(self: *const Reader) DecodeError {
        _ = self;
        return error.MalformedJson;
    }

    /// Advance `pos` over the four bytes JSON calls whitespace, and stop at the
    /// first byte that is not one of them.
    ///
    /// It moves the cursor rather than only reading it, so a caller that needs
    /// the position it had asks `peek` before calling this. Nothing else is
    /// touched, no scratch is spent, and it cannot fail. Every value-taking
    /// method here calls it first, so a caller never has to.
    pub fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    /// Consume one structural byte, or fail.
    pub fn expect(self: *Reader, literal: u8) DecodeError!void {
        self.skipWhitespace();
        const byte = self.peek() orelse return error.Truncated;
        if (byte != literal) return self.fail();
        self.pos += 1;
    }

    /// True when nothing but whitespace is left in the document.
    ///
    /// It is not a pure query: it leaves `pos` at the end of the input, which
    /// is where a document this reader has finished reading ends. A caller
    /// that asks and then reads another value is reading past the end, and
    /// `Truncated` is what it gets.
    pub fn atEnd(self: *Reader) bool {
        self.skipWhitespace();
        return self.pos >= self.input.len;
    }

    /// Descend one container, or report `LimitExceeded`.
    ///
    /// The bound is checked before the increment, so `depth` never exceeds
    /// `max_depth` on any path. A caller that reads the error as "stop
    /// descending" and carries on indexes `has_member[depth]`, and an
    /// increment first would leave that one past the end of the array.
    ///
    /// Paired with [`Reader.leaveContainer`], which is where the level is
    /// given back. The two are the caller's bracket discipline: nothing here
    /// checks that they are balanced, so a decoder that descends twice and
    /// rises once leaves the reader one level deeper than the document, and
    /// every container it opens after that spends a level it does not have.
    pub fn enterContainer(self: *Reader) DecodeError!void {
        if (self.depth >= max_depth) return error.LimitExceeded;
        self.depth += 1;
    }

    /// Give back one level of [`Reader.enterContainer`].
    ///
    /// The level is only given back above zero, so a caller whose rise and fall
    /// do not balance cannot drive `depth` under and have every later
    /// container refused. The closing byte itself was consumed by the `next`
    /// method that reported the end of the container; nothing here looks for
    /// it, and calling this does not read the document.
    pub fn leaveContainer(self: *Reader) void {
        if (self.depth > 0) self.depth -= 1;
    }

    /// Read a JSON string.
    ///
    /// With no escape sequence the result borrows `input` directly and costs
    /// no scratch. With one, the decoded bytes go to the unread tail of
    /// `scratch`, the reader's high-water mark moves past them, and the result
    /// borrows that. See the scratch contract on `Reader`: two strings read
    /// from one reader therefore never alias.
    ///
    /// The result is validated as UTF-8. A protocol that promises text must
    /// not re-emit a stray continuation byte as if it were a character, so
    /// invalid UTF-8 is `error.InvalidUtf8` rather than a value that looks
    /// decoded but is not.
    pub fn string(self: *Reader, scratch: []u8) DecodeError![]const u8 {
        self.skipWhitespace();
        const byte = self.peek() orelse return error.Truncated;
        if (byte != '"') return self.fail();
        self.pos += 1;

        const start = self.pos;
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                '"' => {
                    const raw = self.input[start..self.pos];
                    self.pos += 1;
                    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
                    return raw;
                },
                '\\' => return self.stringEscaped(start, scratch),
                // A raw control character is not in the JSON grammar, so this
                // is a syntax error. It is not an encoding fault: the peer
                // wrote a byte the grammar forbids, and a reader that called it
                // `InvalidUtf8` would report an encoding problem for a
                // perfectly well formed byte.
                0x00...0x1f => return error.MalformedJson,
                else => {},
            }
        }
        return error.Truncated;
    }

    /// The slow path for `string`, entered on the first backslash.
    ///
    /// The bytes before the escape are already known to be literal, so the copy
    /// starts with the pre-escape run and continues across the escape. The
    /// output lands past the high-water mark, never over a string that was
    /// already handed to the caller.
    fn stringEscaped(self: *Reader, start: usize, scratch: []u8) DecodeError![]const u8 {
        if (self.bump > scratch.len) return error.BufferTooSmall;
        const out_buffer = scratch[self.bump..];
        var out: usize = 0;

        const prefix = self.input[start..self.pos];
        try pushRun(out_buffer, &out, prefix);
        // The cursor still points at the backslash, so the loop below sees it
        // and consumes the escape character itself. Advancing here would start
        // the loop on the escape character and copy it through literally.

        // The cursor is advanced explicitly rather than in the loop condition:
        // an escape consumes two bytes, so a trailing increment would skip the
        // character after it.
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            self.pos += 1;
            switch (byte) {
                '"' => return self.takeString(out_buffer, out),
                '\\' => {
                    if (self.pos >= self.input.len) return error.Truncated;
                    const escaped = self.input[self.pos];
                    self.pos += 1; // Consume the escape character itself.
                    switch (escaped) {
                        '"', '\\', '/' => try pushByte(out_buffer, &out, escaped),
                        'b' => try pushByte(out_buffer, &out, 0x08),
                        'f' => try pushByte(out_buffer, &out, 0x0c),
                        'n' => try pushByte(out_buffer, &out, '\n'),
                        'r' => try pushByte(out_buffer, &out, '\r'),
                        't' => try pushByte(out_buffer, &out, '\t'),
                        'u' => {
                            // The cursor now sits past the `u`, which is what
                            // `unicodeEscape` documents that it expects.
                            const unit = try self.unicodeEscape();
                            var encoded: [4]u8 = undefined;
                            const width = std.unicode.utf8Encode(unit, &encoded) catch {
                                return error.InvalidUtf8;
                            };
                            try pushRun(out_buffer, &out, encoded[0..width]);
                        },
                        // An escape letter outside the eight JSON defines is
                        // not in the grammar, so this is a syntax error.
                        else => return self.fail(),
                    }
                },
                0x00...0x1f => return error.MalformedJson,
                else => try pushByte(out_buffer, &out, byte),
            }
        }
        return error.Truncated;
    }

    /// Hand the decoded string to the caller and close out its region.
    ///
    /// The high-water mark moves only here, on success, so a string that fails
    /// to decode leaves the region it was being written into available to the
    /// next one. The validation covers the literal runs copied out of the
    /// input as well as the escapes: an escape always produces well-formed
    /// UTF-8, so anything invalid in the result came from the input.
    fn takeString(self: *Reader, out_buffer: []u8, out: usize) DecodeError![]const u8 {
        const decoded = out_buffer[0..out];
        if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidUtf8;
        self.bump += out;
        return decoded;
    }

    /// Append one decoded byte to the scratch output.
    fn pushByte(out_buffer: []u8, out: *usize, char: u8) DecodeError!void {
        if (out.* + 1 > out_buffer.len) return error.BufferTooSmall;
        out_buffer[out.*] = char;
        out.* += 1;
    }

    /// Append a run of already-decoded bytes to the scratch output.
    fn pushRun(out_buffer: []u8, out: *usize, run: []const u8) DecodeError!void {
        if (out.* + run.len > out_buffer.len) return error.BufferTooSmall;
        @memcpy(out_buffer[out.*..][0..run.len], run);
        out.* += run.len;
    }

    /// Read the four hex digits of a `\u` escape, already past the `u`.
    ///
    /// A surrogate pair is joined into one code point. An unpaired surrogate is
    /// rejected as `InvalidUtf8`: a surrogate is not a Unicode scalar value, so
    /// the escape names a character that has no UTF-8 form at all, and
    /// emitting the replacement character would silently corrupt an identifier.
    fn unicodeEscape(self: *Reader) DecodeError!u21 {
        const high = try self.hex4();
        if (high < 0xd800 or high > 0xdfff) return @intCast(high);

        if (high > 0xdbff) return error.InvalidUtf8; // Lone trailing surrogate.
        // Check the two bytes in the order they are needed, so a high surrogate
        // followed by an ordinary character reports the malformed pairing
        // rather than a truncation that did not happen.
        if (self.pos >= self.input.len) return error.Truncated;
        if (self.input[self.pos] != '\\') return error.InvalidUtf8;
        if (self.pos + 1 >= self.input.len) return error.Truncated;
        if (self.input[self.pos + 1] != 'u') return error.InvalidUtf8;
        self.pos += 2;
        const low = try self.hex4();
        if (low < 0xdc00 or low > 0xdfff) return error.InvalidUtf8;

        const combined: u21 = (@as(u21, high - 0xd800) << 10) | @as(u21, low - 0xdc00);
        return combined + 0x10000;
    }

    fn hex4(self: *Reader) DecodeError!u16 {
        var value: u16 = 0;
        for (0..4) |_| {
            if (self.pos >= self.input.len) return error.Truncated;
            const digit = switch (self.input[self.pos]) {
                '0'...'9' => self.input[self.pos] - '0',
                'a'...'f' => self.input[self.pos] - 'a' + 10,
                'A'...'F' => self.input[self.pos] - 'A' + 10,
                else => return self.fail(),
            };
            value = value * 16 + digit;
            self.pos += 1;
        }
        return value;
    }

    /// Read the raw lexeme of a JSON number, borrowing from the input.
    ///
    /// Callers convert with the width they need. Returning the lexeme rather
    /// than an `f64` keeps an `i64` JSON-RPC id exact: `f64` has 53 bits of
    /// mantissa and would round an id above 2^53.
    pub fn number(self: *Reader) DecodeError![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        if (self.pos < self.input.len and self.input[self.pos] == '-') self.pos += 1;

        var digits: usize = 0;
        while (self.pos < self.input.len and isDigit(self.input[self.pos])) : (self.pos += 1) {
            digits += 1;
        }
        if (digits == 0) return self.fail();

        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            var fraction: usize = 0;
            while (self.pos < self.input.len and isDigit(self.input[self.pos])) : (self.pos += 1) {
                fraction += 1;
            }
            if (fraction == 0) return self.fail();
        }

        if (self.pos < self.input.len) switch (self.input[self.pos]) {
            'e', 'E' => {
                self.pos += 1;
                // An exponent carries its own sign, so `1e-3` and `1e+3` are
                // both numbers. Only a sign and no digit after it is a fault.
                if (self.pos < self.input.len) switch (self.input[self.pos]) {
                    '+', '-' => self.pos += 1,
                    else => {},
                };
                var exponent: usize = 0;
                while (self.pos < self.input.len and isDigit(self.input[self.pos])) : (self.pos += 1) {
                    exponent += 1;
                }
                if (exponent == 0) return self.fail();
            },
            else => {},
        };
        return self.input[start..self.pos];
    }

    /// Read `true` or `false`.
    ///
    /// The cursor advances over the exact literal and over nothing else, so a
    /// truncated `true` is `error.MalformedJson` rather than a false read. No
    /// scratch is spent: the result is a tag and there is no slice to hand
    /// back.
    pub fn boolean(self: *Reader) DecodeError!bool {
        self.skipWhitespace();
        if (self.consumeLiteral("true")) return true;
        if (self.consumeLiteral("false")) return false;
        return self.fail();
    }

    /// Read the literal `null` and return nothing.
    ///
    /// A member carrying this is present, and an absent member is a different
    /// fact, so a caller that has to tell the two asks for this rather than
    /// treating a leading `n` as nothing there. The cursor advances over the
    /// exact four bytes, and no scratch is spent.
    pub fn nullLiteral(self: *Reader) DecodeError!void {
        self.skipWhitespace();
        if (!self.consumeLiteral("null")) return self.fail();
    }

    fn consumeLiteral(self: *Reader, literal: []const u8) bool {
        if (self.pos + literal.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos..][0..literal.len], literal)) return false;
        self.pos += literal.len;
        return true;
    }

    /// Step over a string without decoding it.
    ///
    /// Skipped content must not reach the caller's scratch buffer. A decoder
    /// that walks over a member it does not model would otherwise consume the
    /// region a modelled member is about to be given, and would hand back a
    /// slice a later string could overwrite. So this scans the string's
    /// extent instead of unescaping it: a backslash covers the byte after it,
    /// and a `u` covers the four hex digits, which is all the cursor needs to
    /// know to find the closing quote.
    ///
    /// The escapes are still checked. A bad escape is a syntax error wherever
    /// it appears, and a reader that only complained about the strings it
    /// modelled would let a peer smuggle malformed JSON past a decoder simply
    /// by putting it somewhere unmodelled.
    fn skipString(self: *Reader) DecodeError!void {
        self.skipWhitespace();
        if (self.peek() != @as(?u8, '"')) return self.fail();
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                '"' => {
                    const raw = self.input[start..self.pos];
                    self.pos += 1;
                    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
                    return;
                },
                '\\' => try self.skipEscape(),
                0x00...0x1f => return error.MalformedJson,
                else => self.pos += 1,
            }
        }
        return error.Truncated;
    }

    /// Step over one escape, the cursor sitting on the backslash.
    fn skipEscape(self: *Reader) DecodeError!void {
        self.pos += 1; // The backslash itself.
        const escaped = self.peek() orelse return error.Truncated;
        self.pos += 1;
        switch (escaped) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
            // Reading the escape as a code point rather than as four hex digits
            // is what makes a surrogate pair cost one step here.
            'u' => _ = try self.unicodeEscape(),
            else => return self.fail(),
        }
    }

    /// Consume a value of any type and discard it.
    ///
    /// Used to step over the members of an object a decoder does not model. The
    /// alternative, buffering the subtree, is exactly the allocation the encoding
    /// contract forbids.
    ///
    /// `scratch` is taken so that a caller can hand the same buffer to every
    /// read without deciding which ones need it, and is never written: a
    /// skipped value produces no slice, so it must not take a region a value
    /// the caller does model still needs.
    pub fn skipValue(self: *Reader, scratch: []u8) DecodeError!void {
        self.skipWhitespace();
        const byte = self.peek() orelse return error.Truncated;
        switch (byte) {
            '"' => try self.skipString(),
            '{' => {
                try self.enterContainer();
                defer self.leaveContainer();
                self.pos += 1;
                // Whitespace is legal between the brace and the first member,
                // so `{"a":{ }}` is a well formed object with an empty one
                // inside it. Testing for the brace without skipping first
                // would call that malformed.
                self.skipWhitespace();
                if (self.peek() == '}') {
                    self.pos += 1;
                    return;
                }
                while (true) {
                    // The key comes first, so a leading comma has nothing in
                    // front of it to separate and is rejected here.
                    try self.skipString();
                    try self.expect(':');
                    // `skipValue` recurses here, and the bound is
                    // `enterContainer`: both container arms call it before they
                    // descend, and it refuses a container past `max_depth`
                    // with `error.LimitExceeded` before the depth is spent,
                    // so this call cannot outrun the stack. AGENTS.md records
                    // the recursion finding as advisory for exactly this
                    // reason, and a test covers the bound.
                    // gate-reviewed-zbc-next-line: recursive-parse-fn-without-stack-check
                    try self.skipValue(scratch);
                    self.skipWhitespace();
                    const next = self.peek() orelse return error.Truncated;
                    if (next == '}') {
                        self.pos += 1;
                        return;
                    }
                    if (next != ',') return self.fail();
                    self.pos += 1;
                }
            },
            '[' => {
                try self.enterContainer();
                defer self.leaveContainer();
                self.pos += 1;
                self.skipWhitespace();
                if (self.peek() == ']') {
                    self.pos += 1;
                    return;
                }
                while (true) {
                    try self.skipValue(scratch);
                    self.skipWhitespace();
                    const next = self.peek() orelse return error.Truncated;
                    if (next == ']') {
                        self.pos += 1;
                        return;
                    }
                    if (next != ',') return self.fail();
                    self.pos += 1;
                }
            },
            't', 'f' => _ = try self.boolean(),
            'n' => try self.nullLiteral(),
            '-', '0'...'9' => _ = try self.number(),
            else => return self.fail(),
        }
    }

    /// Begin an object and report whether it was empty.
    ///
    /// An empty object is reported `true` with both braces already consumed and
    /// the container level given back, so there is no key left to read and
    /// `nextKey` is not called on it. Anything else is reported `false` with
    /// the cursor on its first key, and the caller reads members with
    /// [`Reader.nextKey`] until that returns null, which is the call that
    /// consumes the closing brace and gives the level back.
    pub fn beginObject(self: *Reader) DecodeError!bool {
        try self.expect('{');
        try self.enterContainer();
        // This container has yielded no member yet, so its first key may not be
        // preceded by a comma. The flag is per depth, because a nested object
        // must not inherit the state of the one enclosing it.
        self.has_member[self.depth] = false;
        self.skipWhitespace();
        if (self.peek() == '}') {
            self.pos += 1;
            self.leaveContainer();
            return true;
        }
        return false;
    }

    /// Read the next member key of an object opened by `beginObject`, or null
    /// at its closing brace.
    ///
    /// Null consumes the `}` and gives the container level back, so the call
    /// that returns null is the one that ends the object; nothing is left for
    /// the caller to consume. A separating comma is consumed here too, so a
    /// caller that ignores a key it does not model simply calls `skipValue`
    /// and loops.
    ///
    /// The key is unescaped before it is returned, so a name carrying an
    /// escape spends scratch and a zero-length buffer is `error.BufferTooSmall`
    /// on it. A plain key borrows `input` and costs nothing.
    pub fn nextKey(self: *Reader, scratch: []u8) DecodeError!?[]const u8 {
        if (!try self.openKey()) return null;
        const key = try self.string(scratch);
        try self.expect(':');
        self.has_member[self.depth] = true;
        return key;
    }

    /// The next member key of an object opened by `beginObject` as the bytes it
    /// arrived as, or null at the closing brace.
    ///
    /// This is [`Reader.nextKey`] with the key left as the peer's spelling
    /// rather than decoded into a scratch buffer: quotes and escapes included,
    /// borrowed from `input` and costing no scratch however long the name is.
    /// Everything else is the same walk — the closing brace and the container
    /// level, the separating comma, the colon, and the per-container
    /// first-member flag — so the two cannot disagree about where one member
    /// ends and the next begins.
    ///
    /// A caller that compares a name against a fixed spelling it already holds
    /// is the case this is for. Decoding a name it does not model spends a
    /// region of the caller's buffer on a value nothing keeps, and refusing one
    /// for want of scratch would fail a document this library reads perfectly
    /// well. `{"jsonrpc":"2.0","id":1,"\u0069d":1}` carries an `id` this
    /// reports as bytes, and a decoder that wanted the name would compare it
    /// itself.
    ///
    /// The name is still validated in full: a bad escape, a control character,
    /// a truncated lexeme, an unpaired surrogate and a byte sequence that is
    /// not UTF-8 are the faults [`Reader.string`] reports for the same string,
    /// and are reported here as the same faults. The only thing this does not
    /// do is hand back a name the caller can compare without decoding it, and
    /// `error.BufferTooSmall` is therefore not among its errors.
    pub fn nextKeyRaw(self: *Reader) DecodeError!?[]const u8 {
        if (!try self.openKey()) return null;
        const start = self.pos;
        try self.skipString();
        const key = self.input[start..self.pos];
        try self.expect(':');
        self.has_member[self.depth] = true;
        return key;
    }

    /// Everything a member key needs before the name itself: report the closing
    /// brace and give the container level back, or consume the separator that
    /// has to be there and report that a member follows.
    ///
    /// Both key walks open with this, which is what keeps their agreement about
    /// commas, the brace and the level a property of the code rather than of
    /// two copies of it.
    fn openKey(self: *Reader) DecodeError!bool {
        self.skipWhitespace();
        const byte = self.peek() orelse return error.Truncated;
        if (byte == '}') {
            self.pos += 1;
            self.leaveContainer();
            return false;
        }
        try self.takeSeparator(byte);
        return true;
    }

    /// Consume the comma that separates two members or elements.
    ///
    /// A comma has to have one on each side of it, so the first member of a
    /// container must not be preceded by one and every later member must be.
    /// A reader that consumed a comma wherever it found one would accept
    /// `{,"a":1}` and silently decode it as `{"a":1}`, which is a wire format
    /// the peer never sent and a framing bug worth refusing rather than
    /// smoothing over.
    fn takeSeparator(self: *Reader, byte: u8) DecodeError!void {
        if (self.has_member[self.depth]) {
            if (byte != ',') return self.fail();
            self.pos += 1;
            self.skipWhitespace();
        } else if (byte == ',') return self.fail();
    }

    /// Begin an array and report whether it was empty.
    ///
    /// The return is the same fact `beginObject` reports and not a count: `[]`
    /// is reported `true` with the bracket consumed and the level given back,
    /// so the caller reads no element at all. Anything else is reported `false`
    /// with the cursor on its first element, and the caller calls
    /// [`Reader.nextArrayElement`] before each element and until it returns
    /// false, which is the call that consumes the `]` and gives the level
    /// back. There is no separate end step: this and the object path end the
    /// same way.
    pub fn beginArray(self: *Reader) DecodeError!bool {
        try self.expect('[');
        try self.enterContainer();
        self.has_member[self.depth] = false;
        self.skipWhitespace();
        if (self.peek() == ']') {
            self.pos += 1;
            self.leaveContainer();
            return true;
        }
        return false;
    }

    /// Whether another element follows, or false at the closing bracket.
    ///
    /// False consumes the `]` and gives the container level back, so it is the
    /// call that ends the array and no element is read after it. True leaves
    /// the cursor on the element itself, and consumes the separating comma,
    /// so an element needs no separator handling of its own.
    pub fn nextArrayElement(self: *Reader) DecodeError!bool {
        self.skipWhitespace();
        const byte = self.peek() orelse return error.Truncated;
        if (byte == ']') {
            self.pos += 1;
            self.leaveContainer();
            return false;
        }
        try self.takeSeparator(byte);
        self.has_member[self.depth] = true;
        return true;
    }

    /// Consume a value and return its raw JSON text, borrowed from the input.
    ///
    /// Used for members this library carries opaquely, such as a JSON-RPC
    /// `result` or an error `data`, so their exact structure survives a round
    /// trip without the library having to model it.
    ///
    /// The result is a slice of the input, so it costs no scratch however
    /// deeply the value nests or however many escapes it holds. `scratch` is
    /// threaded through to `skipValue`, which also takes none.
    pub fn rawValue(self: *Reader, scratch: []u8) DecodeError![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        try self.skipValue(scratch);
        return self.input[start..self.pos];
    }

    /// The raw JSON text of the member `name` in the object at the cursor,
    /// with the faults attached.
    ///
    /// This is the walk [`memberText`] performs, in the form a caller that
    /// has to tell the faults apart can use: the same members, the same
    /// first-wins rule, the same stopping point, and the `DecodeError` a
    /// signature with no error set cannot carry.
    ///
    /// ## What comes back
    ///
    /// Null when the object carries no member of that name at this level, and
    /// the member's own bytes when it does. A string keeps its quotes and its
    /// escapes, a nested object or array comes back whole, and a literal
    /// `null` comes back as those four bytes rather than as an absent member:
    /// a peer that wrote `"capabilities": null` and a peer that wrote no
    /// `capabilities` are two facts. The slice borrows `self.input`, so the
    /// answer copies nothing and costs no memory the caller did not hand
    /// over already.
    ///
    /// ## Which errors are the caller's
    ///
    /// `error.BufferTooSmall` is the caller's own shortage and nothing else. A
    /// key carrying an escape is unescaped before its name can be compared
    /// with `name`, so a buffer too narrow for one is reported as what it is.
    /// Reported as an absent member instead, the same bytes would tell a
    /// caller the peer wrote nothing where it wrote something, which is the
    /// one answer a caller may not invent. Every other error is a fact about
    /// the peer's document: `MalformedJson`, `Truncated`, `InvalidUtf8`, and
    /// `LimitExceeded`, because the object opened here spends one level of
    /// `max_depth` and a value nested to the bound in a document this reads is
    /// a value this refuses.
    ///
    /// ## The scratch
    ///
    /// A value never reaches `scratch`: `rawValue` and `skipValue` read an
    /// extent and write none, so a document whose keys are all plain costs a
    /// zero-length buffer however many escapes its values hold. What an
    /// escaped key does take is taken from this reader and moves its
    /// high-water mark like any other decoded string, so a caller that reads
    /// further into this document counts those bytes too. Size the buffer
    /// from [`requiredScratchLen`].
    ///
    /// ## Repeated names
    ///
    /// RFC 8259 section 4 says the names within an object *should* be unique,
    /// so a repeat is a document the grammar permits and this still has to
    /// answer for it. The first occurrence wins, for the reason
    /// [`memberText`] gives: a later member must not be able to make a
    /// comparison that has already failed pass. The walk returns at that
    /// first match, so a repeat is never read — an escaped repeat costs the
    /// caller nothing, and a fault behind the matched member is a fault this
    /// never reaches.
    ///
    /// ## The reader afterwards
    ///
    /// The walk consumes this reader. On a match it stands just past the
    /// member and inside the object it opened, so the remaining members are
    /// still readable with [`nextKey`] on this same reader. On an error the
    /// cursor is wherever the walk stopped and nothing about it means
    /// anything, so a caller that wants another answer starts a new
    /// [`Reader`] over the input rather than rewinding this one.
    pub fn memberRaw(self: *Reader, name: []const u8, scratch: []u8) DecodeError!?[]const u8 {
        // An empty object reports true because it consumed its own closing
        // brace, so no key is left to read and no key can match.
        if (try self.beginObject()) return null;
        while (try self.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, name)) {
                const lexeme = try self.rawValue(scratch);
                return lexeme;
            }
            try self.skipValue(scratch);
        }
        return null;
    }

    fn isDigit(byte: u8) bool {
        return byte >= '0' and byte <= '9';
    }
};

/// A JSON writer over a caller-owned buffer.
///
/// Every write either fits or reports `error.BufferTooSmall`, so a caller can
/// size a buffer, retry on failure and grow it without the writer having
/// allocated anything.
///
/// What a failure preserves is the logical length: `written()` reports the
/// same prefix, byte for byte, after a failed write as before it. Bytes past
/// that prefix may have been overwritten on the way, so the guarantee a caller
/// holds is about the message it has written and not about memory it never
/// wrote into.
///
/// Sources passed to `slice` and `string` must not overlap `buffer`. This
/// caller precondition is unchecked in every optimize mode; failure is not
/// reported as an encoding error.
///
/// Every method returns the one `EncodeError` from `root.zig`, not a set of
/// this module's own, so a caller can catch a failure from any protocol
/// encoder in the same place.
pub const Writer = struct {
    /// The caller's buffer, borrowed for the whole life of the writer. It has
    /// to stay alive and unmodified for as long as it is read through `written`.
    buffer: []u8,
    /// How many bytes of `buffer` are written. Writable, because a protocol
    /// encoder records a mark before it writes and rewinds to it when a write
    /// fails part way: `jsonrpc.encode` and `bridge.encodeEnvelope` both do,
    /// and neither can do it through a method.
    len: usize = 0,

    /// A writer over `buffer` with nothing written yet.
    ///
    /// `buffer` is the writer's whole storage: it is borrowed, not copied, and
    /// has to stay alive for as long as the writer is used. `len` starts at
    /// zero, so `written()` is empty and the caller reads its bytes back out of
    /// `buffer` rather than out of the writer.
    pub fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    /// The bytes written so far, as a prefix of `buffer`.
    ///
    /// It borrows `buffer`, so the next write invalidates it. After a failed
    /// write it is the same prefix as before the call, which is what makes a
    /// size, retry and grow loop correct; the bytes behind it are not promised
    /// to be the ones they were.
    pub fn written(self: *const Writer) []const u8 {
        return self.buffer[0..self.len];
    }

    // `len` never passes `buffer.len`, because every write bounds itself
    // first, so this subtraction cannot underflow.
    fn remaining(self: *const Writer) usize {
        return self.buffer.len - self.len;
    }

    /// Append one byte as it stands, or `error.BufferTooSmall` having written
    /// none.
    ///
    /// Nothing here is checked against the JSON grammar. This is the raw
    /// primitive a protocol encoder composes a message out of, and a byte that
    /// is not legal where it lands is the caller's framing decision, not
    /// something this can refuse without modelling every document a caller may
    /// be writing.
    pub fn byte(self: *Writer, char: u8) EncodeError!void {
        if (self.len >= self.buffer.len) return error.BufferTooSmall;
        self.buffer[self.len] = char;
        self.len += 1;
    }

    /// Append `bytes` as they stand, or `error.BufferTooSmall` having written
    /// none.
    ///
    /// The bound is settled before the first byte is copied, so a refusal
    /// leaves the prefix already written exactly as it was. As with
    /// [`Writer.byte`] nothing here is JSON, and that is what lets a member
    /// this library does not model reach the wire with its own spelling
    /// intact rather than rebuilt from a shape that could not hold it.
    /// `bytes` must not overlap `buffer`; this is unchecked in every optimize
    /// mode.
    pub fn slice(self: *Writer, bytes: []const u8) EncodeError!void {
        if (self.remaining() < bytes.len) return error.BufferTooSmall;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Write a JSON string literal, quotes included, with the escapes JSON
    /// requires and none it does not.
    ///
    /// The write is all-or-nothing in the sense that matters to a retry: on
    /// `error.BufferTooSmall` the length is back where it was, so the caller can
    /// grow the buffer and call again without rewinding. The bytes past that
    /// length are not restored, and a caller that kept its own copy of them has to
    /// have written it before the call.
    /// `text` must be valid UTF-8, and that is the caller's obligation rather than
    /// a check here. Every byte the grammar forbids is escaped and every other
    /// byte passes through, so a `text` carrying a stray byte produces a literal
    /// this module's own [`Reader.string`] then refuses with `error.InvalidUtf8`
    /// on the far side of the wire. Nothing enforces the precondition in any
    /// optimize mode: PROTOCOLS.md section 2 makes a value that could not have
    /// been decoded a programming error, and every string arriving here from a
    /// decode is already validated as UTF-8.
    /// `text` must also be disjoint from `buffer`, unchecked in every mode.
    pub fn string(self: *Writer, text: []const u8) EncodeError!void {
        const mark = self.len;
        self.writeString(text) catch |err| {
            self.len = mark;
            return err;
        };
    }

    fn writeString(self: *Writer, text: []const u8) EncodeError!void {
        try self.byte('"');
        for (text) |char| {
            switch (char) {
                '"' => try self.slice("\\\""),
                '\\' => try self.slice("\\\\"),
                0x08 => try self.slice("\\b"),
                0x0c => try self.slice("\\f"),
                '\n' => try self.slice("\\n"),
                '\r' => try self.slice("\\r"),
                '\t' => try self.slice("\\t"),
                // The five escaped shorthands above are the only members of
                // this set left, so the range is spelled around them rather
                // than overlapping. Every other byte, including multi-byte
                // UTF-8, passes through unchanged.
                0x00...0x07, 0x0b, 0x0e...0x1f => {
                    var digits: [6]u8 = undefined;
                    const escaped = std.fmt.bufPrint(&digits, "\\u{x:0>4}", .{char}) catch {
                        return error.BufferTooSmall;
                    };
                    try self.slice(escaped);
                },
                else => try self.byte(char),
            }
        }
        try self.byte('"');
    }
};

/// The raw JSON text of the top-level member `name` in the object `raw`.
///
/// This is public because the layers above this one need the same walk, and
/// none of them should keep a copy of it. A private copy of this walk is a
/// second parser to keep correct, and one already existed in the ACP session
/// layer. It is for any decoder that wants one member of a body it does not
/// model, such as the `agentCapabilities` off an initialize reply.
///
/// ## What comes back
///
/// Null when the object carries no member of that name, and the member's own
/// bytes when it does. A string keeps its quotes and its escapes, and a nested
/// object or array comes back whole. The result borrows `raw`, so reading a
/// member copies nothing and costs no memory the caller has not already
/// handed over.
///
/// A member whose value is the literal `null` comes back as those four bytes
/// rather than as a null pointer. A peer that sent `"capabilities": null` and
/// a peer that sent no `capabilities` are two facts, and a caller that reads
/// one as the other reports a refusal as an omission.
///
/// A document this reader cannot parse also comes back null, because the
/// signature carries no error set. A malformed body, a truncated one, a
/// string that is not UTF-8, an escaped key the caller sized the scratch too
/// narrowly for, and a nesting past the depth bound all arrive as the same
/// answer, and a caller that has to tell them apart cannot use that one.
/// [`Reader.memberRaw`] is where the walk below lives and reports each of
/// them, so that is what such a caller calls. This is a reader of it over one
/// input, not a second copy of it.
///
/// Only the outer object counts. A member of that name inside a nested object
/// or array is not a top-level member, and reporting one would hand a caller a
/// field the peer never wrote at this level.
///
/// ## The scratch
///
/// `nextKey` is the only step that uses `scratch`, because a key carrying an
/// escape has to be unescaped before the name can be compared. A value never
/// reaches the buffer, so plain keys and any number of escaped values decode
/// with a zero-length `scratch`. Size it from `Reader.requiredScratchLen`; a
/// key the buffer cannot hold makes this return null, as a malformed document
/// does.
///
/// ## Repeated names
///
/// RFC 8259 section 4 says the names within an object *should* be unique, so a
/// repeat is a document the grammar permits. PROTOCOLS.md does not forbid one,
/// the two conventions in the wild disagree, and a decoder still has to pick
/// one. The first occurrence wins.
///
/// The first is what a reader expects when a member appears twice, and it is
/// the answer this function can give for the price of the walk. It returns at
/// the match, which is what lets it hand back a borrowed slice without reading
/// the rest of the object. Last-wins has to walk to the end to know it holds
/// the last one.
///
/// `http.zig` refuses a repeated derived header with `error.DuplicateHeader`,
/// and the two rules differ on purpose. There, two values for a header that is
/// compared against the body leave the check ambiguous, because a gateway and
/// a library can read different ones. Here the caller compares this result
/// against a value it already holds, and the first is enough to make that
/// comparison fail closed: a later member cannot make a failed comparison
/// pass.
///
/// The walk stops at the match, so a fault after that member is not read and
/// `{"a":1,"b":}` still yields `1`. That is the intended behaviour. A caller
/// that has to know the whole document parses runs one of the library's
/// decoders, and a caller that wants one member has its answer either way.
///
/// The object opened here spends one level of `max_depth`, so a value nested
/// to the bound in a document this reads is a value this refuses.
pub fn memberText(raw: []const u8, name: []const u8, scratch: []u8) ?[]const u8 {
    // One walk, in [`Reader.memberRaw`], and every fault that walk reports is
    // a fault this signature has no way to spell.
    var reader = Reader.init(raw);
    return reader.memberRaw(name, scratch) catch null;
}

/// Base64 with `=` padding: the text every protocol in this library uses when
/// it carries bytes as characters.
///
/// RFC 4648 section 4 and section 5 differ in two characters and nowhere
/// else, so [`Alphabet`] is a parameter of one codec rather than the reason
/// for two. A second copy of this walk is a second thing to keep correct, and
/// one lived inside the MCP module until the codec moved here; A2A needs it
/// for `Part.raw`, and neither module should own a codec both sit on.
///
/// Nothing allocates. [`encode`] writes into a buffer the caller sizes from
/// [`encodedLen`], [`decode`] writes into a buffer the caller sizes from
/// [`decodedLen`], and both hand back a slice of that buffer, so nothing
/// outlives the call. Neither takes a `Reader` or a `Writer`: this is not
/// JSON and does not go through a JSON string.
///
/// Decoding is total. Every byte of an encoded value is peer input, so a
/// character outside the alphabet, a quad opening with `=`, a group that is
/// not four characters and a pad in the wrong place are all
/// `error.InvalidField`, never a trap. `error.BufferTooSmall` is the caller's
/// own sizing mistake and is kept apart from it, because the two have
/// different repairs.
///
/// Only the canonical spelling of a value decodes. RFC 4648 section 3.5
/// requires the bits a pad covers to be zero, and enforcing that is what
/// keeps `encode(decode(b)) == b`: an encoding of a value this emits has one
/// spelling, so an accepted encoding is one that can be written back, and two
/// spellings of the same bytes cannot both be accepted and then be told
/// apart on the way out.
///
/// Encoding refuses before it writes. The bound is settled once from
/// [`encodedLen`] rather than per quad, so `error.BufferTooSmall` leaves the
/// caller's buffer as it was handed over and a caller may size, retry and
/// grow without this having allocated anything.
pub const base64 = struct {
    /// The RFC 4648 alphabet a value is written in.
    ///
    /// `=` is the pad in both of them. RFC 4648 section 5 defines the
    /// URL-safe alphabet as carrying the same pad characters, so padding is a
    /// property of this codec rather than of the alphabet: it emits pads and
    /// requires them. The one specification that omits them is JWS, whose
    /// segments are carried here as borrowed text rather than decoded.
    pub const Alphabet = enum {
        /// RFC 4648 section 4. The MCP `=?base64?` sentinel and a ProtoJSON
        /// `bytes` field.
        standard,
        /// RFC 4648 section 5.
        url,
    };

    fn symbols(alphabet: Alphabet) []const u8 {
        return switch (alphabet) {
            .standard => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
            .url => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
        };
    }

    fn digitOf(byte: u8, alphabet: Alphabet) ?u8 {
        return switch (byte) {
            'A'...'Z' => byte - 'A',
            'a'...'z' => byte - 'a' + 26,
            '0'...'9' => byte - '0' + 52,
            // The alphabets differ here and only here: digits 62 and 63 are
            // the same two numbers in both, and only the characters carrying
            // them are not. Taking the alphabet as a parameter is what keeps
            // this one walk rather than two that have to agree.
            '+' => if (alphabet == .standard) 62 else null,
            '/' => if (alphabet == .standard) 63 else null,
            '-' => if (alphabet == .url) 62 else null,
            '_' => if (alphabet == .url) 63 else null,
            else => null,
        };
    }

    /// The buffer [`encode`] writes `input_len` bytes into.
    ///
    /// A partial final group is padded out to four characters, so the bound is
    /// a multiple of four and an input of every length has one.
    pub fn encodedLen(input_len: usize) usize {
        return (input_len + 2) / 3 * 4;
    }

    /// The most bytes `encoded_len` characters decode to, or null when
    /// `encoded_len` is not a whole number of groups.
    ///
    /// The bound ignores padding and so overstates the result, which is the
    /// direction that matters: a buffer sized from it is never short, whereas
    /// one sized from the padded length would report the peer's bytes as the
    /// caller's mistake.
    pub fn decodedLen(encoded_len: usize) ?usize {
        if (encoded_len % 4 != 0) return null;
        return (encoded_len / 4) * 3;
    }

    /// Encode `input` into `output` in `alphabet`, padded to a group boundary.
    ///
    /// The result is a prefix of `output`, and it is as long as
    /// [`encodedLen`] for an `input` of that length. A buffer shorter than that
    /// is `error.BufferTooSmall` with nothing written, so a caller may size,
    /// retry and grow without this having allocated anything.
    /// Input and output regions must be disjoint, unchecked in every optimize
    /// mode. The returned bytes borrow `output` until its next write.
    pub fn encode(input: []const u8, output: []u8, alphabet: Alphabet) EncodeError![]const u8 {
        // The whole result is sized before the first byte is written, so a
        // refusal leaves the caller's buffer exactly as it was handed over
        // and a caller may size, retry and grow without this having
        // allocated anything. A check per quad cannot promise that: it has
        // already written every earlier quad by the time it runs out.
        if (output.len < encodedLen(input.len)) return error.BufferTooSmall;
        // Resolved once, so the alphabet costs a switch outside the loop rather
        // than a branch per character.
        const table = symbols(alphabet);
        var out: usize = 0;
        var index: usize = 0;
        while (index + 3 <= input.len) : (index += 3) {
            const chunk = std.mem.readInt(u24, input[index..][0..3], .big);
            output[out] = table[(chunk >> 18) & 0x3f];
            output[out + 1] = table[(chunk >> 12) & 0x3f];
            output[out + 2] = table[(chunk >> 6) & 0x3f];
            output[out + 3] = table[chunk & 0x3f];
            out += 4;
        }
        // The final partial group is padded, because a decoder groups four
        // characters at a time and an unpadded tail is a length error.
        const rest = input.len - index;
        if (rest == 1) {
            const chunk: u32 = @as(u32, input[index]) << 16;
            output[out] = table[(chunk >> 18) & 0x3f];
            output[out + 1] = table[(chunk >> 12) & 0x3f];
            output[out + 2] = '=';
            output[out + 3] = '=';
            out += 4;
        } else if (rest == 2) {
            const chunk: u32 = @as(u32, input[index]) << 16 |
                @as(u32, input[index + 1]) << 8;
            output[out] = table[(chunk >> 18) & 0x3f];
            output[out + 1] = table[(chunk >> 12) & 0x3f];
            output[out + 2] = table[(chunk >> 6) & 0x3f];
            output[out + 3] = '=';
            out += 4;
        }
        return output[0..out];
    }

    /// Decode `input` into `output` in `alphabet`, returning a prefix of it.
    ///
    /// `decodedLen(input.len)` is an upper bound; padding can make the actual
    /// result smaller. Capacity is checked per group. An output too short for
    /// the actual decoded bytes is `error.BufferTooSmall`.
    /// A character outside the alphabet, a group whose length is not four, a
    /// group carrying fewer than two digits, misplaced padding and nonzero
    /// discarded bits are `error.InvalidField`.
    ///
    /// Either error can leave previously decoded groups in `output`; discard
    /// those bytes because no result length is returned. The current group is
    /// checked before its bytes are written. Input and output must be disjoint,
    /// unchecked in every optimize mode. A successful result borrows `output`
    /// until its next write.
    pub fn decode(input: []const u8, output: []u8, alphabet: Alphabet) DecodeError![]const u8 {
        if (input.len % 4 != 0) return error.InvalidField;
        var out: usize = 0;
        var index: usize = 0;
        while (index < input.len) : (index += 4) {
            const quad = input[index..][0..4];
            const final_group = index + 4 == input.len;
            var bits: u32 = 0;
            var count: usize = 0;
            var last: u8 = 0;
            var padded = false;
            for (quad, 0..) |byte, position| {
                // RFC 4648 sections 3.3 and 3.5: a pad appears only in the
                // final group and only as a run to its end. A pad in an
                // earlier group is a length the encoder never emits, and a
                // character behind one is a digit this would have to drop.
                if (byte == '=') {
                    if (!final_group) return error.InvalidField;
                    padded = true;
                    continue;
                }
                if (padded) return error.InvalidField;
                const digit = digitOf(byte, alphabet) orelse return error.InvalidField;
                bits |= @as(u32, digit) << @intCast(18 - 6 * position);
                last = digit;
                count += 1;
            }
            // A group carries at least two digits. One digit is not a whole
            // byte, and a group that opens with `=` carries none at all, so
            // `count - 1` below would underflow a `usize`.
            if (count < 2) return error.InvalidField;
            const produced: usize = if (count == 4) 3 else count - 1;
            // The digits that reach no byte must be zero. RFC 4648 section
            // 3.5 requires it, and a group that sets them is a second
            // spelling of bytes already decoded: two encodings reading back
            // as one value, so a round trip can neither reproduce what the
            // peer sent nor say which of the two it sent.
            const discarded: u3 = @intCast(6 * count - 8 * produced);
            if ((last & ((@as(u8, 1) << discarded) - 1)) != 0) return error.InvalidField;
            if (out + produced > output.len) return error.BufferTooSmall;
            for (0..produced) |offset| {
                output[out + offset] = @truncate(bits >> @intCast(16 - 8 * offset));
            }
            out += produced;
        }
        return output[0..out];
    }
};

// The reader's string scratch buffer and the writer's encoding share no state,
// so a single test buffer is enough to exercise both.
const testing = std.testing;

test "reader returns a plain string as a slice of the input" {
    var reader = Reader.init("\"hello\"");
    const scratch: [0]u8 = .{};
    try testing.expectEqualStrings("hello", try reader.string(&scratch));
    try testing.expect(reader.atEnd());
}

test "reader unescapes into the caller's scratch buffer" {
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("\"a\\nb\\u00e9\\ud83d\\ude00\"");
    try testing.expectEqualStrings("a\nbé😀", try reader.string(&scratch));
}

test "reader reports BufferTooSmall rather than truncating an escape" {
    var scratch: [3]u8 = undefined;
    var reader = Reader.init("\"a\\nb\\nc\"");
    try testing.expectError(error.BufferTooSmall, reader.string(&scratch));
}

test "reader rejects an unpaired surrogate instead of substituting" {
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("\"\\ud83d\"");
    try testing.expectError(error.InvalidUtf8, reader.string(&scratch));
    reader = Reader.init("\"\\udc00x\"");
    try testing.expectError(error.InvalidUtf8, reader.string(&scratch));
}

test "a raw control character is a syntax error, not an encoding fault" {
    // PROTOCOLS.md 2.1 calls `InvalidUtf8` a byte sequence that is not valid
    // UTF-8. A control character is valid UTF-8 and simply not in the grammar,
    // so reporting it as an encoding fault would send a caller looking for a
    // transcoding bug that does not exist.
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("\"a\nb\"");
    try testing.expectError(error.MalformedJson, reader.string(&scratch));
    reader = Reader.init("\"a\\nb\rc\"");
    try testing.expectError(error.MalformedJson, reader.string(&scratch));
}

test "an unknown escape letter is a syntax error" {
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("\"a\\qb\"");
    try testing.expectError(error.MalformedJson, reader.string(&scratch));
}

test "invalid UTF-8 in a string is InvalidUtf8" {
    var scratch: [16]u8 = undefined;
    // 0xff can never appear in UTF-8, and a lone continuation byte cannot
    // start a character. Neither is a grammar error, and both must be refused
    // rather than decoded and re-emitted.
    var reader = Reader.init("\"a\xff\"");
    try testing.expectError(error.InvalidUtf8, reader.string(&scratch));
    reader = Reader.init("\"\x80\"");
    try testing.expectError(error.InvalidUtf8, reader.string(&scratch));
    // The escaped path copies literal bytes through, so it needs the check
    // too. The newline here is an escape, not a raw control character, which
    // is what puts this on the slow path.
    reader = Reader.init("\"a\\nb\xff\"");
    try testing.expectError(error.InvalidUtf8, reader.string(&scratch));
}

test "two escaped strings from one reader do not alias" {
    // A decoded struct holds both at once. A scheme that rewrote the first
    // region while decoding the second would corrupt the first.
    var scratch: [32]u8 = undefined;
    var reader = Reader.init("\"a\\nb\" \"c\\nd\"");
    const first = try reader.string(&scratch);
    const second = try reader.string(&scratch);
    try testing.expectEqualStrings("a\nb", first);
    try testing.expectEqualStrings("c\nd", second);
    // Two distinct regions, not one buffer read twice.
    try testing.expect(first.ptr != second.ptr);
}

test "skipping a value takes no scratch and cannot clobber" {
    // The skipped member is walked in full, escapes and all, without being
    // unescaped anywhere. The high-water mark proves the first of the two
    // decoded strings is still the only region handed out, so the string the
    // caller is holding cannot have been rewritten underneath it.
    var scratch: [8]u8 = undefined;
    var reader = Reader.init("\"a\\nb\" {\"skip\":\"x\\ny\\u0041z\"}");
    const kept = try reader.string(&scratch);
    const claimed = reader.bump;
    try reader.skipValue(&scratch);
    try testing.expectEqualStrings("a\nb", kept);
    try testing.expectEqual(claimed, reader.bump);
    try testing.expect(reader.atEnd());
}

test "a raw value borrows the input, escapes and all" {
    // Nothing is unescaped, so a zero-length scratch decodes a result holding
    // as many escapes as the peer likes.
    var reader = Reader.init("{\"a\":\"x\\ny\\u0041\"}");
    _ = try reader.beginObject();
    const key = try reader.nextKey("");
    try testing.expectEqualStrings("a", key.?);
    // The reader sits at the string value after `nextKey`, so the raw text is
    // that value with its escapes still spelled out, borrowed from the input.
    try testing.expectEqualStrings("\"x\\ny\\u0041\"", try reader.rawValue(""));
}

test "number lexeme keeps an i64 id exact beyond f64 precision" {
    // 2^53 + 1 is 9007199254740993. An f64 cannot hold it.
    const lexeme = "9007199254740993";
    var reader = Reader.init(lexeme);
    const raw = try reader.number();
    try testing.expectEqual(@as(i64, 9007199254740993), try std.fmt.parseInt(i64, raw, 10));
}

test "number rejects a truncated lexeme" {
    var reader = Reader.init("-");
    try testing.expectError(error.MalformedJson, reader.number());
    reader = Reader.init("1.");
    try testing.expectError(error.MalformedJson, reader.number());
    reader = Reader.init("1e");
    try testing.expectError(error.MalformedJson, reader.number());
}

test "a number keeps the whole lexeme, fraction and exponent included" {
    // The lexeme is what a caller converts, so a truncated lexeme silently
    // changes the value it converts. The reader has to run past the mantissa.
    const lexemes = [_][]const u8{ "1.5e-3", "1e3", "1E+3", "-0.5", "0.5", "0" };
    for (lexemes) |lexeme| {
        var reader = Reader.init(lexeme);
        try testing.expectEqualStrings(lexeme, try reader.number());
        try testing.expect(reader.atEnd());
    }
}

test "deep nesting is LimitExceeded, not a stack overflow" {
    // More opens than `max_depth`, which is the case that would otherwise
    // recurse until the stack ran out.
    var text: [max_depth + 8]u8 = undefined;
    @memset(text[0 .. max_depth + 4], '[');
    var reader = Reader.init(text[0 .. max_depth + 4]);
    try testing.expectError(error.LimitExceeded, reader.skipValue(""));
}

test "the depth bound holds on the failure path too" {
    // A caller that reads `LimitExceeded` as "stop descending" and carries on
    // indexes `has_member[depth]`, which sits one past the end of the array
    // when the increment came first. The bound is what turns hostile input
    // into an error, so it must not leave behind a reader that traps on the
    // very document it refused.
    var reader = Reader.init("");
    for (0..max_depth) |_| try reader.enterContainer();
    try testing.expectEqual(@as(u32, max_depth), reader.depth);
    try testing.expectError(error.LimitExceeded, reader.enterContainer());
    try testing.expectEqual(@as(u32, max_depth), reader.depth);
    // Still indexable, which is the whole point of bounding the depth.
    reader.has_member[reader.depth] = false;

    // The same through the helper a decoder actually calls.
    reader = Reader.init(&@as([max_depth + 1]u8, @splat('{')));
    for (0..max_depth) |_| try testing.expect(!try reader.beginObject());
    try testing.expectError(error.LimitExceeded, reader.beginObject());
    try testing.expectEqual(@as(u32, max_depth), reader.depth);
}

test "a reader adopted over a spliced body is charged for the containers it lands inside" {
    // `depth` and `bump` are writable, and a caller decoding a body out of a
    // frame it is already holding does exactly this: one reader over the
    // frame and a second over the body, sharing one scratch buffer. Neither
    // effect below is visible from the shape of the two fields.

    // The bound is charged from the depth the caller set, because the body
    // lands inside containers the frame already holds. A body nesting
    // `max_depth` deep is exactly what a reader at depth zero accepts, and it
    // is refused here — which is the same verdict a decoder reaches a level
    // earlier when it meets the body inside the frame, so the two sides agree
    // on what this library carries.
    var text: [max_depth * 2 + 1]u8 = undefined;
    @memset(text[0..max_depth], '[');
    text[max_depth] = '0';
    @memset(text[max_depth + 1 ..], ']');

    var at_zero = Reader.init(&text);
    try at_zero.skipValue("");

    var adopted = Reader.init(&text);
    adopted.depth = 1;
    try testing.expectError(error.LimitExceeded, adopted.skipValue(""));
    // `skipValue` unwinds its container count on refusal. Its cursor still
    // advanced, so the failed value needs a new reader before retrying.
    try testing.expectEqual(@as(u32, 1), adopted.depth);

    // One scratch buffer for both readers, so the body's escapes land above
    // the region the frame already handed out. Both decoded strings are alive
    // at once and neither overwrote the other: a second reader starting its
    // own mark at zero would have rewritten the first, and no assertion would
    // have said so.
    var scratch: [16]u8 = undefined;
    var frame = Reader.init("{\"a\":\"x\\ny\"}");
    try testing.expect(!try frame.beginObject());
    try testing.expectEqualStrings("a", (try frame.nextKey(&scratch)).?);
    const outer = try frame.string(&scratch);
    const mark = frame.bump;
    try testing.expect(mark != 0);

    var body = Reader.init("\"b\\tc\"");
    body.bump = mark;
    const inner = try body.string(&scratch);
    try testing.expectEqualStrings("b\tc", inner);
    try testing.expectEqualStrings("x\ny", outer);
    try testing.expectEqual(mark + inner.len, body.bump);
}

test "skipValue steps over a whole mixed document" {
    const text =
        \\{"a":[1,2,{"b":null}],"c":"d","e":true,"f":{"g":[]},"h":-1.5e3}
    ;
    var scratch: [64]u8 = undefined;
    var reader = Reader.init(text);
    try reader.skipValue(&scratch);
    try testing.expect(reader.atEnd());
}

test "whitespace inside a container is legal" {
    // An empty container holding only whitespace is still empty, and the
    // reader must say so after skipping that whitespace rather than call the
    // document malformed.
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("{\"a\":{ },\"b\":[ ]}");
    _ = try reader.beginObject();
    const first = try reader.nextKey(&scratch);
    try testing.expectEqualStrings("a", first.?);
    try reader.skipValue(&scratch);
    const second = try reader.nextKey(&scratch);
    try testing.expectEqualStrings("b", second.?);
    try reader.skipValue(&scratch);
    try testing.expect((try reader.nextKey(&scratch)) == null);
    try testing.expect(reader.atEnd());

    reader = Reader.init("{ }");
    try testing.expect(try reader.beginObject());
    reader = Reader.init("[ ]");
    try testing.expect(try reader.beginArray());
    reader = Reader.init("{ \t\r\n }");
    try testing.expect(try reader.beginObject());
}

test "a leading comma is a syntax error" {
    // JSON has no leading or trailing comma, and a reader that consumed a
    // comma wherever it found one would decode `{,"a":1}` as `{"a":1}`: a
    // document the peer never sent, accepted as if it had.
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("{,\"a\":1}");
    _ = try reader.beginObject();
    try testing.expectError(error.MalformedJson, reader.nextKey(&scratch));

    reader = Reader.init("[ ,1]");
    _ = try reader.beginArray();
    try testing.expectError(error.MalformedJson, reader.nextArrayElement());

    // The same rule inside a skipped value.
    reader = Reader.init("{,\"a\":1}");
    try testing.expectError(error.MalformedJson, reader.skipValue(&scratch));
}

test "a missing comma between members is a syntax error" {
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("{\"a\":1 \"b\":2}");
    _ = try reader.beginObject();
    _ = try reader.nextKey(&scratch);
    _ = try reader.number();
    try testing.expectError(error.MalformedJson, reader.nextKey(&scratch));
}

test "a trailing comma is a syntax error" {
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("{\"a\":1,}");
    _ = try reader.beginObject();
    _ = try reader.nextKey(&scratch);
    _ = try reader.number();
    try testing.expectError(error.MalformedJson, reader.nextKey(&scratch));
}

test "a nested container starts its own member count" {
    // The flag that rejects a leading comma is per container, so the inner
    // object must not inherit the outer one having already yielded a member.
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("{\"a\":{\"b\":1},\"c\":2}");
    _ = try reader.beginObject();
    _ = try reader.nextKey(&scratch);
    _ = try reader.beginObject();
    const inner = try reader.nextKey(&scratch);
    try testing.expectEqualStrings("b", inner.?);
    _ = try reader.number();
    try testing.expect((try reader.nextKey(&scratch)) == null);
    const outer = try reader.nextKey(&scratch);
    try testing.expectEqualStrings("c", outer.?);
    _ = try reader.number();
    try testing.expect((try reader.nextKey(&scratch)) == null);
    try testing.expect(reader.atEnd());
}

test "object iteration separates handled from unhandled members" {
    const text =
        \\{"resultType":"complete","ttlMs":5000,"extra":{"deep":[1,2]}}
    ;
    var scratch: [32]u8 = undefined;
    var reader = Reader.init(text);
    var seen_ttl: ?i64 = null;
    var seen_result_type: []const u8 = "";

    try testing.expect(!try reader.beginObject());
    while (try reader.nextKey(&scratch)) |key| {
        if (std.mem.eql(u8, key, "resultType")) {
            seen_result_type = try reader.string(&scratch);
        } else if (std.mem.eql(u8, key, "ttlMs")) {
            seen_ttl = try std.fmt.parseInt(i64, try reader.number(), 10);
        } else {
            try reader.skipValue(&scratch);
        }
    }
    try testing.expectEqualStrings("complete", seen_result_type);
    try testing.expectEqual(@as(?i64, 5000), seen_ttl);
}

test "an empty object yields no keys, an empty array yields no elements" {
    // `beginObject` reporting true means it consumed the closing brace, so the
    // object is over and there is no key left to read.
    var reader = Reader.init("{}");
    try testing.expect(try reader.beginObject());
    try testing.expect(reader.atEnd());

    // Likewise for an empty array: `beginArray` reporting true means it
    // consumed the closing bracket, so there is no element to step to.
    reader = Reader.init("[]");
    try testing.expect(try reader.beginArray());
    try testing.expect(reader.atEnd());
}

test "array iteration visits every element" {
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("[\"a\",\"b\",\"c\"]");
    var count: usize = 0;
    try testing.expect(!try reader.beginArray());
    while (try reader.nextArrayElement()) {
        _ = try reader.string(&scratch);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "truncated input is Truncated, not a panic" {
    var scratch: [16]u8 = undefined;
    var reader = Reader.init("\"abc");
    try testing.expectError(error.Truncated, reader.string(&scratch));

    reader = Reader.init("{\"a\":");
    try testing.expect(try reader.beginObject() == false);
    _ = try reader.nextKey(&scratch);
    try testing.expectError(error.Truncated, reader.skipValue(&scratch));
}

test "writer round-trips a string through the reader" {
    // The escaped form is longer than the input: 38 bytes for a 33-byte string.
    var buffer: [64]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.string("quote\" backslash\\ newline\n tab\t");
    try testing.expectEqualStrings(
        "\"quote\\\" backslash\\\\ newline\\n tab\\t\"",
        writer.written(),
    );

    var scratch: [64]u8 = undefined;
    var reader = Reader.init(writer.written());
    try testing.expectEqualStrings(
        "quote\" backslash\\ newline\n tab\t",
        try reader.string(&scratch),
    );
}

test "writer reports BufferTooSmall and leaves the buffer usable" {
    var buffer: [4]u8 = undefined;
    var writer = Writer.init(&buffer);
    try testing.expectError(error.BufferTooSmall, writer.string("far too long"));
    try testing.expectEqual(@as(usize, 0), writer.len);

    try writer.string("ok");
    try testing.expectEqualStrings("\"ok\"", writer.written());
}

test "writer escapes a control character as \\u00XX" {
    var buffer: [16]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.string("\x01");
    try testing.expectEqualStrings("\"\\u0001\"", writer.written());
}

test "writer passes multi-byte UTF-8 through unescaped" {
    var buffer: [16]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.string("é😀");
    try testing.expectEqualStrings("\"é😀\"", writer.written());
}

test "writer passes a byte its own reader refuses straight through" {
    // The writer escapes what the JSON grammar forbids and leaves every other
    // byte alone, so a value that is not valid UTF-8 comes out as a literal
    // this module's reader then rejects. That is the precondition `string`
    // documents, and the writer checks nothing: PROTOCOLS.md section 2.1 makes
    // a value that could not have been decoded a programming error, and every
    // string that arrives from a decode is already validated.
    var buffer: [8]u8 = undefined;
    var writer = Writer.init(&buffer);
    try writer.string("a\xff");
    try testing.expectEqualStrings("\"a\xff\"", writer.written());

    var scratch: [8]u8 = undefined;
    var reader = Reader.init(writer.written());
    try testing.expectError(error.InvalidUtf8, reader.string(&scratch));
}

test "requiredScratchLen measures the buffer a decode fills" {
    const text =
        \\{"a":"x\ny","b":"\u00e9","c":"\ud83d\ude00","d":"plain","e":"\t"}
    ;
    var scratch: [Reader.requiredScratchLen(text)]u8 = undefined;
    // Three bytes for `x\ny`, two for the two-byte `é`, four for the
    // surrogate pair and one for the `\t`. `d` is plain, so it borrows the
    // input and is not counted at all.
    try testing.expectEqual(@as(usize, 10), scratch.len);

    const expected = [_][2][]const u8{
        .{ "a", "x\ny" },
        .{ "b", "é" },
        .{ "c", "😀" },
        .{ "d", "plain" },
        .{ "e", "\t" },
    };

    var reader = Reader.init(text);
    try testing.expect(!try reader.beginObject());
    var index: usize = 0;
    while (try reader.nextKey(&scratch)) |key| {
        try testing.expect(index < expected.len);
        try testing.expectEqualStrings(expected[index][0], key);
        // Read rather than skipped: a skipped value takes no scratch, so
        // stepping over it would not exercise the sizing at all.
        try testing.expectEqualStrings(expected[index][1], try reader.string(&scratch));
        index += 1;
    }
    try testing.expectEqual(expected.len, index);
    // The high-water mark ends on the last byte, so the measurement is exact
    // and not merely safe: a buffer this size cannot be one byte too large.
    try testing.expectEqual(scratch.len, reader.bump);
}

test "a buffer one byte below the measurement is BufferTooSmall" {
    // `x`, the newline and `y` are three decoded bytes, so a two-byte buffer
    // is short. Sizing from `requiredScratchLen` therefore cannot overflow
    // by a margin nobody would notice.
    const text = "{\"a\":\"x\\ny\"}";
    try testing.expectEqual(@as(usize, 3), Reader.requiredScratchLen(text));

    var reader = Reader.init(text);
    try testing.expect(!try reader.beginObject());
    _ = try reader.nextKey("");
    var short: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, reader.string(&short));
}

test "a document of plain strings needs no scratch at all" {
    // The reader contract promises that plain text decodes with a zero-length
    // buffer. Measuring it is what turns that promise into something a caller
    // can rely on without sizing for the worst case by hand.
    const text = "{\"a\":\"x\",\"b\":\"y\"}";
    var scratch: [Reader.requiredScratchLen(text)]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), scratch.len);

    var reader = Reader.init(text);
    try testing.expect(!try reader.beginObject());
    while (try reader.nextKey(&scratch)) |_| {
        try testing.expect((try reader.string(&scratch)).len != 0);
    }
    try testing.expectEqual(@as(usize, 0), reader.bump);
}

test "an escaped string inside a skipped value is still counted" {
    // The scan cannot know which members a decoder models, so it counts every
    // escaped string in the document. That is the safe direction to be wrong
    // in: a few bytes of buffer too many, rather than a BufferTooSmall on a
    // message the caller sized from this number.
    const text =
        \\{"a":1,"b":"\n"}
    ;
    var scratch: [Reader.requiredScratchLen(text)]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), scratch.len);

    var reader = Reader.init(text);
    try testing.expect(!try reader.beginObject());
    _ = try reader.nextKey(&scratch);
    _ = try reader.number();
    _ = try reader.nextKey(&scratch);
    try reader.skipValue(&scratch);
    // Skipped, so the buffer went untouched: the count was a bound, not a
    // prediction of what this decoder would have used.
    try testing.expectEqual(@as(usize, 0), reader.bump);
}

test "memberText returns a member's exact bytes" {
    const text =
        \\{"jsonrpc":"2.0","id":7,"params":{"a":[1,{"b":null}],"c":"x\ny"},"note":"plain"}
    ;
    // No key here carries an escape, and no value ever reaches the buffer, so
    // a zero-length scratch decodes the whole object.
    const scratch: [0]u8 = .{};
    // A nested value comes back whole, with the peer's own spelling of every
    // escape intact, because the walk reads the extent and copies nothing.
    try testing.expectEqualStrings(
        "{\"a\":[1,{\"b\":null}],\"c\":\"x\\ny\"}",
        memberText(text, "params", &scratch).?,
    );
    // A bare string keeps its quotes. The raw text is the JSON, not the decoded
    // value, so a caller that wants the value decodes it.
    try testing.expectEqualStrings("\"plain\"", memberText(text, "note", &scratch).?);
    // A number is a member the same way, and comes back as its lexeme.
    try testing.expectEqualStrings("7", memberText(text, "id", &scratch).?);
}

test "an absent member is null" {
    const scratch: [0]u8 = .{};
    // No member of that name.
    try testing.expect(memberText("{\"a\":1}", "b", &scratch) == null);
    // An empty object has no members, and its closing brace is already behind
    // the cursor.
    try testing.expect(memberText("{}", "a", &scratch) == null);
    // Only the outer object counts. A member of that name one level down is
    // not a top-level member, and reporting it would hand the caller a field
    // the peer never wrote here.
    try testing.expect(memberText("{\"outer\":{\"a\":1}}", "a", &scratch) == null);
    try testing.expect(memberText("{\"outer\":[{\"a\":1}]}", "a", &scratch) == null);
    // The top-level member of that name wins over the nested one beside it.
    try testing.expectEqualStrings(
        "1",
        memberText("{\"a\":1,\"outer\":{\"a\":2}}", "a", &scratch).?,
    );
    // A document that is not an object carries no top-level member.
    try testing.expect(memberText("[{\"a\":1}]", "a", &scratch) == null);
    try testing.expect(memberText("\"a\"", "a", &scratch) == null);
    // A body the reader cannot parse is null as well, because the signature
    // carries no error set. A caller that must tell the two apart walks a
    // `Reader` of its own and gets the `DecodeError`.
    try testing.expect(memberText("{\"a\":", "a", &scratch) == null);
    try testing.expect(memberText("{\"a\" 1}", "a", &scratch) == null);
}

test "a literal null member is not an absent member" {
    const scratch: [0]u8 = .{};
    const text = "{\"capabilities\":null,\"note\":1}";
    // The four bytes, not a null pointer. A peer that sent a null capability
    // and a peer that mentioned none are two facts, and a caller that reads
    // one as the other reports a refusal as an omission.
    try testing.expectEqualStrings("null", memberText(text, "capabilities", &scratch).?);
    // The member beside it is absent, and says so.
    try testing.expect(memberText(text, "agentCapabilities", &scratch) == null);
    // A null nested inside a value is the same four bytes, and the walk does
    // not read it as the end of the object.
    try testing.expectEqualStrings(
        "{\"x\":null}",
        memberText("{\"o\":{\"x\":null},\"y\":2}", "o", &scratch).?,
    );
    // A null does not end the walk either, so the member after it is found.
    try testing.expectEqualStrings("1", memberText(text, "note", &scratch).?);
}

test "the first of two members with the same name wins, and the second is still readable" {
    // RFC 8259 section 4 says the names within an object should be unique, so
    // this document is grammar the library permits. A decoder still has to
    // answer for it, and this one answers with the first.
    const text = "{\"a\":1,\"a\":2}";
    try testing.expectEqualStrings("1", memberText(text, "a", "").?);

    // The later value is not lost. A caller that wants it walks the object
    // with a `Reader` and counts past the member this function returned.
    var reader = Reader.init(text);
    try testing.expect(!try reader.beginObject());
    var seen: usize = 0;
    var second: []const u8 = "";
    while (try reader.nextKey("")) |key| {
        try testing.expect(std.mem.eql(u8, key, "a"));
        const value = try reader.rawValue("");
        seen += 1;
        if (seen == 2) second = value;
    }
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqualStrings("2", second);
}

test "two members read out of one object with one scratch do not overlap" {
    // A session reads one body twice, once per member, with one buffer. The
    // second read must not disturb the first, and both of these values carry
    // an escape.
    const text =
        \\{"a":"x\ny","b":"p\tq"}
    ;
    var scratch: [16]u8 = undefined;
    const first = memberText(text, "a", &scratch) orelse return error.TestUnexpectedResult;
    // Overwriting the whole buffer is what a copy into it would not survive.
    // Neither value was ever copied there, so both still hold the input's own
    // bytes with their escapes spelled out.
    @memset(scratch[0..], 0xff);
    const second = memberText(text, "b", &scratch) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("\"x\\ny\"", first);
    try testing.expectEqualStrings("\"p\\tq\"", second);
    // Two runs of one input, at different offsets, so they cannot overlap each
    // other either.
    try testing.expect(first.ptr != second.ptr);
}

test "a key that carries an escape needs the caller's scratch" {
    // The key is unescaped so the name can be compared, and a zero-length
    // buffer cannot hold it, so the walk reports nothing.
    const text = "{\"\\u0063aps\":1}";
    try testing.expect(memberText(text, "caps", "") == null);
    // Four bytes is the decoded width of the key `caps`.
    var four: [4]u8 = undefined;
    try testing.expectEqualStrings("1", memberText(text, "caps", &four).?);

    // Plain keys and escaped values need no buffer at all, because a value
    // never reaches it.
    const plain = "{\"caps\":{\"a\":\"x\\ny\"},\"d\":[1,2]}";
    try testing.expectEqualStrings("{\"a\":\"x\\ny\"}", memberText(plain, "caps", "").?);
    try testing.expectEqualStrings("[1,2]", memberText(plain, "d", "").?);
}

test "a fault after the matched member is not read" {
    // The walk returns at the match, so the garbage behind it goes unread and
    // the member is still the answer. This is the intended behaviour, not a
    // caveat: a caller that has to know the whole document parses runs one of
    // the library's decoders, and a caller that wants one member has its
    // answer either way.
    try testing.expectEqualStrings("1", memberText("{\"a\":1,\"b\":}", "a", "").?);
    // The same fault before the member is caught, because the walk has to
    // step over it on the way there.
    try testing.expect(memberText("{\"b\":,\"a\":1}", "a", "") == null);
}

// The two tests below are the fallible walk's contract, and they are the only
// place in this file that asks for a member with the error set attached. The
// distinction they draw is the one `memberText` cannot draw: a key that carries
// an escape has to be unescaped before the name can be compared, and a buffer
// that cannot hold it is the caller's shortage rather than a fact about the
// peer's document. Reported as an absent member, the same bytes would tell a
// caller the peer wrote nothing where it wrote something, which is the one
// answer a caller may not invent.
test "an escaped key the scratch cannot hold is the caller's shortage, not an absent member" {
    // A reader of its own for every call, because a walk that fails part
    // way leaves it wherever it stopped and nothing here is about what a
    // reader does after a fault.
    const escaped = "{\"\\u0063aps\":1}";
    // Four bytes is the decoded width of the key `caps`, and the member is
    // there. Every width below it is the caller's own shortage, reported
    // as such rather than as a member the peer did not write.
    var no_room = Reader.init(escaped);
    try testing.expectError(error.BufferTooSmall, no_room.memberRaw("caps", ""));
    var three = Reader.init(escaped);
    var narrow: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, three.memberRaw("caps", &narrow));
    var four = Reader.init(escaped);
    var room: [4]u8 = undefined;
    try testing.expectEqualStrings("1", (try four.memberRaw("caps", &room)).?);

    // A key that is not the one asked for is read the same way: the name
    // has to be unescaped before it can be compared with the one being
    // looked for, so an unreadable key anywhere on the way to the match is
    // the same shortage. Three bytes decode the key `a\nb`, and the member
    // behind it is then found.
    const beside =
        \\{"a\nb":1,"caps":2}
    ;
    var beside_no_room = Reader.init(beside);
    try testing.expectError(error.BufferTooSmall, beside_no_room.memberRaw("caps", ""));
    var beside_room = Reader.init(beside);
    var three_wide: [3]u8 = undefined;
    try testing.expectEqualStrings("2", (try beside_room.memberRaw("caps", &three_wide)).?);

    // An escaped VALUE is not a key, so it never reaches the buffer and the
    // member that carries one is found with no buffer at all. A walk that
    // spent scratch on values would report a shortage over a document whose
    // keys are all plain.
    var value_reader = Reader.init("{\"caps\":\"x\\ny\"}");
    try testing.expectEqualStrings("\"x\\ny\"", (try value_reader.memberRaw("caps", "")).?);

    // The same document through `memberText`, whose signature carries no
    // error set: an unreadable key is null there, and the two answers are
    // what tell a caller which one it asked for.
    try testing.expect(memberText(escaped, "caps", "") == null);
}

test "the first member of a name is the answer, and the walk never reads past it" {
    // RFC 8259 section 4 says the names within an object should be unique,
    // so this document is grammar the library permits and a decoder still
    // has to answer for it. Both walks answer with the first, for the
    // reason `memberText` states: a later member cannot make a comparison
    // that has already failed pass.
    var reader = Reader.init("{\"a\":1,\"a\":2}");
    try testing.expectEqualStrings("1", (try reader.memberRaw("a", "")).?);
    try testing.expectEqualStrings("1", memberText("{\"a\":1,\"a\":2}", "a", "").?);

    // The walk returns at the match, so a fault after that member is not
    // read and the member is still the answer. `{"a":1,"b":}` is not JSON,
    // and the member asked for is in it.
    var tail = Reader.init("{\"a\":1,\"b\":}");
    try testing.expectEqualStrings("1", (try tail.memberRaw("a", "")).?);
    // The fault before the member is still a fault, because the walk has to
    // step over it to reach the member.
    var lead = Reader.init("{\"b\":,\"a\":1}");
    try testing.expectError(error.MalformedJson, lead.memberRaw("a", ""));

    // First-wins holds against a duplicate that is itself escaped, and it
    // costs nothing to hold: the walk returns at the first match, so the
    // escaped key behind it is never read and needs no scratch. A walk that
    // compared every key before answering would spend the buffer here and
    // report the caller's sizing over a document that asked nothing of it.
    var escaped_duplicate = Reader.init("{\"a\":1,\"\\u0061\":2}");
    try testing.expectEqualStrings("1", (try escaped_duplicate.memberRaw("a", "")).?);

    // Only the outer object is walked, on the same terms as `memberText`: a
    // member of that name one level down is not a top-level member.
    var nested = Reader.init("{\"outer\":{\"a\":2}}");
    try testing.expect(try nested.memberRaw("a", "") == null);
    // An absent member is null and not an error, which is what tells a
    // caller that the walk finished rather than ran out of anything.
    var absent = Reader.init("{\"b\":1}");
    try testing.expect(try absent.memberRaw("a", "") == null);
}

test "base64 round-trips every length mod 3 in both alphabets" {
    // Bytes chosen so that most groups carry digits 62 and 63, which is where
    // the two alphabets part company. A corpus of ASCII would exercise
    // neither, and a corpus that only ever pads would exercise one length mod
    // 3 out of three.
    const corpus = [_][]const u8{
        "\xfb\xff\xbe",
        "\xfb\xff\xbf",
        "\xff\xff\xff\xff\xff",
        "\x00\x10\x83",
        "f",
        "fo",
        "foo",
        "foobar",
        "",
    };
    var encoded: [64]u8 = undefined;
    var decoded: [64]u8 = undefined;
    for ([_]base64.Alphabet{ .standard, .url }) |alphabet| {
        for (corpus) |bytes| {
            const digits = try base64.encode(bytes, &encoded, alphabet);
            // Exactly what `encodedLen` promised, so a caller that sized the
            // buffer from the helper neither overflows nor over-allocates.
            try testing.expectEqual(base64.encodedLen(bytes.len), digits.len);
            try testing.expectEqualStrings(bytes, try base64.decode(digits, &decoded, alphabet));
        }
    }
}

test "the two alphabets differ only in the characters carrying digits 62 and 63" {
    // Each vector is one whose standard spelling contains `+` or `/`, because
    // those are the only characters the tables disagree about. A test built
    // from vectors that touch neither would pass against two identical
    // tables.
    const vectors = [_]struct { bytes: []const u8, standard: []const u8, url: []const u8 }{
        .{ .bytes = "\xfb\xff\xbe", .standard = "+/++", .url = "-_--" },
        .{ .bytes = "\xfb\xff\xbf", .standard = "+/+/", .url = "-_-_" },
        .{ .bytes = "\xfb\xff\x00", .standard = "+/8A", .url = "-_8A" },
        .{ .bytes = "\xff\xff\xff", .standard = "////", .url = "____" },
        // One that reaches neither, so the two tables are not a swap of the
        // whole alphabet.
        .{ .bytes = "foobar", .standard = "Zm9vYmFy", .url = "Zm9vYmFy" },
    };
    var out: [16]u8 = undefined;
    for (vectors) |vector| {
        try testing.expectEqualStrings(
            vector.standard,
            try base64.encode(vector.bytes, &out, .standard),
        );
        try testing.expectEqualStrings(
            vector.url,
            try base64.encode(vector.bytes, &out, .url),
        );
    }
}

test "each base64 alphabet refuses the two characters that belong to the other" {
    // `-_` and `+/` are not interchangeable. A decoder that read either in
    // place of the other would report the peer's bytes as something this
    // library happens to spell differently, which is a fault with no repair.
    var out: [8]u8 = undefined;
    try testing.expectError(error.InvalidField, base64.decode("-_8A", &out, .standard));
    try testing.expectError(error.InvalidField, base64.decode("+/8A", &out, .url));
    // The other sixty-two characters are shared, so each alphabet reads the
    // other's spelling of a value that reaches neither pair.
    try testing.expectEqualStrings("foobar", try base64.decode("Zm9vYmFy", &out, .standard));
    try testing.expectEqualStrings("foobar", try base64.decode("Zm9vYmFy", &out, .url));
}

test "a malformed base64 group is InvalidField, never a trap" {
    var out: [8]u8 = undefined;
    // A group that is not four characters. The encoder always pads the final
    // group, so an unpadded tail is not something this guesses at.
    try testing.expectError(error.InvalidField, base64.decode("aGk", &out, .standard));
    // A character outside the alphabet, which is entirely the peer's to send.
    try testing.expectError(error.InvalidField, base64.decode("aGk?", &out, .standard));
    try testing.expectError(error.InvalidField, base64.decode("a k=", &out, .standard));
    // A group opening with `=` carries no digit at all, and one carrying a
    // single digit is not a whole byte. Both are the cases `count - 1` would
    // underflow on.
    try testing.expectError(error.InvalidField, base64.decode("=AAA", &out, .standard));
    try testing.expectError(error.InvalidField, base64.decode("A===", &out, .standard));
    try testing.expectError(error.InvalidField, base64.decode("====", &out, .standard));
    // The legal forms beside them still decode, so the refusals above are not
    // a decoder that refuses everything.
    try testing.expectEqualStrings("hi", try base64.decode("aGk=", &out, .standard));
    try testing.expectEqualStrings("", try base64.decode("", &out, .standard));
}

test "a base64 pad is legal only in the final group, and only as a run" {
    var out: [8]u8 = undefined;
    // A pad in a group that is not the last one. `aGk=aGk=` read as `hihi`
    // before, and those four bytes encode as `aGloaQ==`, so the eight
    // characters that arrived could not be reproduced: the value was accepted
    // and then lost on the way back out.
    try testing.expectError(error.InvalidField, base64.decode("aGk=aGk=", &out, .standard));
    try testing.expectError(error.InvalidField, base64.decode("QQ==QQ==", &out, .standard));
    // A digit behind a pad is the same fault inside one group: `aG=x`
    // produced `h` and dropped the `x` without saying so.
    try testing.expectError(error.InvalidField, base64.decode("aG=x", &out, .standard));
    try testing.expectError(error.InvalidField, base64.decode("aA=a", &out, .standard));
    // The legal forms beside them still decode, so the refusals above are not
    // a decoder that refuses every pad.
    try testing.expectEqualStrings("hi", try base64.decode("aGk=", &out, .standard));
    try testing.expectEqualStrings("A", try base64.decode("QQ==", &out, .standard));
    // A whole group carries every digit it reads, so there is nothing over
    // the byte and the rule below has nothing to say about it.
    try testing.expectEqualStrings("hia", try base64.decode("aGlh", &out, .standard));
}

test "a base64 group whose digits reach no byte must have them zero" {
    var out: [8]u8 = undefined;
    // RFC 4648 section 3.5. `aGl=` and `aGk=` are the same two bytes and only
    // the second is a spelling this encoder emits, so a decoder reading both
    // could not say which one the peer sent when asked to send it back.
    try testing.expectError(error.InvalidField, base64.decode("aGl=", &out, .standard));
    try testing.expectError(error.InvalidField, base64.decode("aGm=", &out, .standard));
    try testing.expectEqualStrings("hi", try base64.decode("aGk=", &out, .standard));
    // One byte over two digits leaves four digits over the byte rather than
    // two, so the reach is longer here and `aB==` is the spelling refused.
    try testing.expectError(error.InvalidField, base64.decode("aB==", &out, .standard));
    try testing.expectEqualStrings("h", try base64.decode("aA==", &out, .standard));
}

test "a base64 buffer one byte short is the caller's error, not the peer's" {
    // `aGk=` decodes to two bytes, so a one-byte buffer is a caller-side
    // sizing mistake. Reporting it as InvalidField would tell the caller the
    // peer sent something malformed, which is a different fault with a
    // different repair.
    var tiny: [1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, base64.decode("aGk=", &tiny, .standard));

    // The encode side bounds itself before it writes, so a short buffer is
    // refused with the output untouched rather than half written.
    var short: [3]u8 = undefined;
    @memset(&short, 0xff);
    try testing.expectError(error.BufferTooSmall, base64.encode("foobar", &short, .standard));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff }, &short);
}

test "a base64 encode refuses a short buffer without writing a byte" {
    // Room for one whole group and not for the rest. The encode side used to
    // bound itself per group, so it wrote `Zm9v` and only then reported the
    // shortfall: a caller that sized, retried and grew would find the head
    // of the failed attempt already in the buffer it passed again.
    var one_group: [6]u8 = undefined;
    @memset(&one_group, 0xff);
    try testing.expectError(error.BufferTooSmall, base64.encode("foobar", &one_group, .standard));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, &one_group);

    // The padded tail is written after every whole group, so both of these
    // reached their refusal with a buffer already holding the groups in
    // front of the pad.
    var one_tail: [5]u8 = undefined;
    @memset(&one_tail, 0xff);
    try testing.expectError(error.BufferTooSmall, base64.encode("foob", &one_tail, .standard));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff }, &one_tail);

    var two_tail: [6]u8 = undefined;
    @memset(&two_tail, 0xff);
    try testing.expectError(error.BufferTooSmall, base64.encode("fooba", &two_tail, .standard));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, &two_tail);

    // The bound the documentation tells a caller to size from is accepted, so
    // the refusals above are not an encoder that refuses every length.
    var exact: [8]u8 = undefined;
    try testing.expectEqualStrings("Zm9vYmFy", try base64.encode("foobar", &exact, .standard));
    try testing.expectEqualStrings("Zm9vYg==", try base64.encode("foob", &exact, .standard));
    try testing.expectEqualStrings("Zm9vYmE=", try base64.encode("fooba", &exact, .standard));
}

test "the base64 length helpers state the bounds both directions need" {
    // Four characters for every three bytes, rounded up, so that a final
    // partial group is covered by a buffer sized from the helper.
    try testing.expectEqual(@as(usize, 0), base64.encodedLen(0));
    try testing.expectEqual(@as(usize, 4), base64.encodedLen(1));
    try testing.expectEqual(@as(usize, 4), base64.encodedLen(2));
    try testing.expectEqual(@as(usize, 4), base64.encodedLen(3));
    try testing.expectEqual(@as(usize, 8), base64.encodedLen(4));

    // The decode bound ignores padding, so it overstates rather than
    // understates, and a length that is not a whole number of groups has no
    // bound at all.
    try testing.expectEqual(@as(?usize, 0), base64.decodedLen(0));
    try testing.expectEqual(@as(?usize, 6), base64.decodedLen(8));
    try testing.expectEqual(@as(?usize, null), base64.decodedLen(3));

    // A buffer sized from the bound holds what the decoder writes.
    var out: [8]u8 = undefined;
    const digits = try base64.encode("foob", &out, .standard);
    const room = base64.decodedLen(digits.len) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("foob", try base64.decode(digits, out[0..room], .standard));
}
