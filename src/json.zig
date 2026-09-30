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
pub const Reader = struct {
    input: []const u8,
    pos: usize = 0,
    depth: u32 = 0,
    /// High-water mark of the scratch buffer: the first byte not yet handed to
    /// a decoded string.
    bump: usize = 0,
    /// Whether the container open at each depth has yielded a member or an
    /// element yet. Indexed by `depth`, which `enterContainer` bounds by
    /// `max_depth`, so the array is never indexed out of range.
    has_member: [max_depth + 1]bool = [_]bool{false} ** (max_depth + 1),

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

    /// True when the reader has consumed everything but trailing whitespace.
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
    pub fn enterContainer(self: *Reader) DecodeError!void {
        if (self.depth >= max_depth) return error.LimitExceeded;
        self.depth += 1;
    }

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

    pub fn boolean(self: *Reader) DecodeError!bool {
        self.skipWhitespace();
        if (self.consumeLiteral("true")) return true;
        if (self.consumeLiteral("false")) return false;
        return self.fail();
    }

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

    /// Begin an object and report whether it is empty.
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

    /// Read the next member key of an object opened by `beginObject`.
    ///
    /// Returns null at the closing brace, which the caller consumes. A comma is
    /// consumed here, so a caller that ignores an unknown key simply calls
    /// `skipValue` and loops.
    pub fn nextKey(self: *Reader, scratch: []u8) DecodeError!?[]const u8 {
        self.skipWhitespace();
        const byte = self.peek() orelse return error.Truncated;
        if (byte == '}') {
            self.pos += 1;
            self.leaveContainer();
            return null;
        }
        try self.takeSeparator(byte);
        const key = try self.string(scratch);
        try self.expect(':');
        self.has_member[self.depth] = true;
        return key;
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

    /// Step over the elements of an array opened here.
    ///
    /// Returns an empty slice for `[]`, otherwise the element count. The caller
    /// then reads elements with `nextArrayElement` and finishes with
    /// `endArray`.
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

    /// Returns true when another element follows, false at `]`.
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

    fn isDigit(byte: u8) bool {
        return byte >= '0' and byte <= '9';
    }
};

/// A JSON writer over a caller-owned buffer.
///
/// Every write either fits or reports `error.BufferTooSmall` with the buffer
/// untouched, so a caller can size a buffer, retry on failure, and grow it
/// without the writer having allocated anything.
///
/// Every method returns the one `EncodeError` from `root.zig`, not a set of
/// this module's own, so a caller can catch a failure from any protocol
/// encoder in the same place.
pub const Writer = struct {
    buffer: []u8,
    len: usize = 0,

    pub fn init(buffer: []u8) Writer {
        return .{ .buffer = buffer };
    }

    /// The bytes written so far.
    pub fn written(self: *const Writer) []const u8 {
        return self.buffer[0..self.len];
    }

    // `len` never passes `buffer.len`, because every write bounds itself
    // first, so this subtraction cannot underflow.
    fn remaining(self: *const Writer) usize {
        return self.buffer.len - self.len;
    }

    pub fn byte(self: *Writer, char: u8) EncodeError!void {
        if (self.len >= self.buffer.len) return error.BufferTooSmall;
        self.buffer[self.len] = char;
        self.len += 1;
    }

    pub fn slice(self: *Writer, bytes: []const u8) EncodeError!void {
        if (self.remaining() < bytes.len) return error.BufferTooSmall;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Write a JSON string literal, quotes included, with the escapes JSON
    /// requires and none it does not.
    ///
    /// The write is all-or-nothing. A caller that gets `error.BufferTooSmall`
    /// can grow the buffer and call again without first rewinding, which is the
    /// only way a retry loop around this is worth writing.
    ///
    /// `text` must be valid UTF-8. Every byte the grammar forbids is escaped
    /// and every other byte passes through, so a value carrying a stray byte
    /// produces a literal this module's own reader refuses. Nothing here
    /// checks: PROTOCOLS.md section 2.1 makes a value that could not have been
    /// decoded a programming error, and every string that arrives here from a
    /// decode is already validated.
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
/// signature carries no error set. A caller that must tell a malformed body
/// from an absent member walks a `Reader` of its own and gets the
/// `DecodeError`.
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
    var reader = Reader.init(raw);
    // An empty object reports true because it consumed its own closing brace,
    // so no key is left to read and no key can match.
    if (reader.beginObject() catch return null) return null;
    while (reader.nextKey(scratch) catch return null) |key| {
        if (std.mem.eql(u8, key, name)) return reader.rawValue(scratch) catch null;
        reader.skipValue(scratch) catch return null;
    }
    return null;
}

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
    reader = Reader.init("{" ** (max_depth + 1));
    for (0..max_depth) |_| try testing.expect(!try reader.beginObject());
    try testing.expectError(error.LimitExceeded, reader.beginObject());
    try testing.expectEqual(@as(u32, max_depth), reader.depth);
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
    const first = memberText(text, "a", &scratch).?;
    // Overwriting the whole buffer is what a copy into it would not survive.
    // Neither value was ever copied there, so both still hold the input's own
    // bytes with their escapes spelled out.
    @memset(scratch[0..], 0xff);
    const second = memberText(text, "b", &scratch).?;
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
