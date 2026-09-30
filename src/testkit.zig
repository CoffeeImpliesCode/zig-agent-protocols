//! The property and differential harness for the JSON substrate.
//!
//! The library's own tests are hand written, which means they catch a
//! regression only when the author happened to write the same case twice.
//! Every byte on these wires is attacker-controlled and the parser underneath
//! has to survive all of them: no panic, no trap, no read out of bounds, and a
//! decode that always reports a `DecodeError` rather than a value nobody can
//! tell from a real one. This module generates those bytes from a fixed seed,
//! feeds them to every public decoder, and checks the properties that have to
//! hold for all of them.
//!
//! ## What it asserts, and why each one is not a tautology
//!
//! - **Round-trip stability.** Every decoder that has a matching encoder is
//!   encoded and decoded again, into a *second* scratch buffer, and the two
//!   decoded values are compared by content. Re-decoding into the buffer the
//!   first decode wrote into would compare memory the second decode has
//!   already overwritten, which is how this kind of test passes for the wrong
//!   reason.
//! - **`requiredScratchLen` is an upper bound, and an exact one.** The
//!   generated walk is handed a buffer of exactly the length that function
//!   reports, so a document that decodes must decode. A count that
//!   under-measured is a `BufferTooSmall` on input the caller sized correctly
//!   from the number the documentation gives, and a test measures the count
//!   from the other side as well: one byte short, the same document does not
//!   decode.
//! - **Borrowed values stay whole.** A `rawValue` is re-walked from a fresh
//!   reader, the reader's own scratch is checked for the distinct regions its
//!   bump offset promises, and capability paths are checked for the regions
//!   the capability walk promises. A region that were recycled would leave two
//!   entries pointing at the same bytes, and `isMethodSupported` would answer
//!   a question about whichever was written last.
//! - **A member name can be damaged.** A generator that only rewrites values
//!   hands the decoders the keys the seed documents spell and nothing else, so
//!   every rule about an unknown member, a missing member or a renamed one
//!   would be asserted over documents it cannot emit. The vocabulary therefore
//!   carries every member name a decoder this harness feeds branches on, and
//!   one shape renames a member of a real message outright: a renamed `id`
//!   turns a request into a notification, and a renamed `jsonrpc` is a
//!   refusal.
//! - **Differential agreement.** A generated corpus goes through both this
//!   reader and `std.json.Scanner`, and the two must agree on accept versus
//!   reject for the whole document and on the top-level classification. The
//!   corpus is the whole one, hostile bytes and mutated messages included,
//!   because a comparison run only on documents both parsers must accept never
//!   sees a disagreement. Every place they legitimately differ is listed by
//!   name in [`DivergenceCase`] with the reason, so a new disagreement fails
//!   the test rather than passing unnoticed. A generated document that
//!   disagrees is excused only by the one difference that table records, the
//!   leading zero [`hasLeadingZero`] names, and only in the direction the
//!   table gives it.
//!
//! ## Running it
//!
//! `zig build fuzz`, not `zig build test`. The seed and the iteration count
//! come from build options (`-Dfuzz-seed`, `-Dfuzz-iterations`) and are printed
//! on every run, so a failure is reproducible from the log alone. The step
//! inherits the standard optimize option and must not be run in ReleaseFast: a
//! bounds violation is a trap in Debug and ReleaseSafe and nothing at all in
//! ReleaseFast, and catching the former is the point.
//!
//! The reference parser and the scratch buffers here belong to the test, not to
//! the library. The library still allocates nothing.

const std = @import("std");
const proto = @import("zig-agent-proto");
const build_options = @import("build_options");

const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;
const acp = proto.acp;
const bridge = proto.bridge;

const DecodeError = proto.DecodeError;

/// The seed every run starts from unless `-Dfuzz-seed` overrides it.
///
/// Fixed on purpose: a harness that reports a failure without the input that
/// caused it is a harness nobody re-runs.
pub const default_seed: u64 = build_options.fuzz_seed;

/// Documents generated per run unless `-Dfuzz-iterations` overrides it.
pub const default_iterations: usize = build_options.fuzz_iterations;

const seed: u64 = default_seed;
const iterations: usize = default_iterations;

/// The largest document the harness builds.
///
/// Bounded so every buffer below is a stack array: the sum of every escaped
/// string in a document is at most the document's own length, so a scratch this
/// size always suffices, and a harness that grew its buffers with the seed
/// would be measuring an allocator rather than a parser.
const max_doc_len = 512;

/// The encode buffer, sized against the decode buffer.
///
/// An encoder re-emits a borrowed member as no more bytes than it read: an
/// escape is at least six characters and decodes to at most four bytes, and
/// every verbatim member is a substring of the input. The constant covers the
/// members `jsonrpc.encode` writes between them, so a `BufferTooSmall` here is
/// a harness bug rather than a tight buffer.
const encode_buf_len = 2 * max_doc_len + 256;

// --- Diagnostics ----------------------------------------------------------------

const escape_hex = "0123456789abcdef";

/// A printable rendering of a byte slice, so a failure names the bytes that
/// produced it instead of a truncated paragraph.
fn escaped(text: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    for (text) |byte| {
        switch (byte) {
            ' '...0x7e => {
                if (len == out.len) break;
                out[len] = byte;
                len += 1;
            },
            else => {
                if (len + 4 > out.len) break;
                out[len] = '\\';
                out[len + 1] = 'x';
                out[len + 2] = escape_hex[byte >> 4];
                out[len + 3] = escape_hex[byte & 0xf];
                len += 4;
            },
        }
    }
    if (len + 3 <= out.len) {
        out[len] = '.';
        out[len + 1] = '.';
        out[len + 2] = '.';
        return out[0 .. len + 3];
    }
    return out[0..len];
}

// --- Document construction ------------------------------------------------------

/// A byte buffer that saturates instead of overflowing.
const Doc = struct {
    bytes: [max_doc_len]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Doc) []const u8 {
        return self.bytes[0..self.len];
    }

    fn clear(self: *Doc) void {
        self.len = 0;
    }

    fn push(self: *Doc, text: []const u8) void {
        if (self.len + text.len > max_doc_len) return;
        // `memmove`, not `memcpy`: a mutation appends a run taken from this
        // same buffer, and the two regions overlap.
        @memmove(self.bytes[self.len..][0..text.len], text);
        self.len += text.len;
    }

    fn pushByte(self: *Doc, byte: u8) void {
        if (self.len == max_doc_len) return;
        self.bytes[self.len] = byte;
        self.len += 1;
    }
};

const whitespace = [_]u8{ ' ', '\t', '\n', '\r' };

/// String bodies a JSON grammar accepts, escape-free and with escapes.
///
/// `\u0000` is here deliberately: it is the one escape whose decoded byte is
/// itself a control character, so it exercises the writer's control-character
/// branch on a value that arrived through the reader's escape path.
const string_forms = [_][]const u8{
    "",
    "a",
    "Z",
    "0",
    " ",
    "/",
    ":",
    "{",
    "}",
    "[",
    "]",
    "\\\"",
    "\\\\",
    "\\/",
    "\\b\\f\\n\\r\\t",
    "\\u0000",
    "\\u0041",
    "\\u00e9",
    "\\u20ac",
    "\\ud83d\\ude00",
    "\u{00e9}",
    "\u{20ac}",
    "\u{1f600}",
    "key",
    "value",
};

/// The member names a decoder this harness feeds branches on.
///
/// Without these in the vocabulary a generated document spells no protocol
/// member at all, so the decoders only ever meet the keys the seed documents
/// happen to carry, unedited. Every rule that reads a member name — the
/// unknown-member skip, the required-member rules, the classification on `id`
/// and `method`, the `result`/`error` exclusion — would then be asserted over
/// documents the generator cannot emit.
///
/// Only keys a decoder really compares belong here. A capability path is not a
/// key: `acp.decodeCapabilityObject` turns whatever it reads into a path, so
/// `terminal` and `loadSession` are reached when a document nests them rather
/// than spelled on their own, and a dotted path fragment in a table of string
/// bodies is weight. `test "every member name is in a seed or listed as
/// grammar-only"` is what keeps this list, the seeds and
/// [`grammar_only_names`] in step.
const member_names = [_][]const u8{
    // `jsonrpc.decode` and the error object it carries.
    "jsonrpc",
    "id",
    "method",
    "params",
    "result",
    "error",
    "code",
    "message",
    "data",
    // `mcp.decodeResultType` and `mcp.decodeInputRequiredResult`.
    "resultType",
    "inputRequests",
    "requestState",
    // `acp.decodePermissionOutcome`.
    "outcome",
    "optionId",
    // `acp.decodePermissionRequest` and the option object inside it.
    "sessionId",
    "title",
    "description",
    "toolCall",
    "subject",
    "options",
    "name",
    "kind",
    // `acp.decodePermissionSubject`, which the draft arm of the permission
    // request reaches through its `subject` member.
    "type",
    "command",
    "cwd",
    "toolCallId",
    // The one member the capability walk treats differently: metadata on every
    // type, and never a capability path.
    "_meta",
    // `bridge.decodeEnvelope`.
    "serverId",
    "requestId",
};

/// Member names the grammar generator spells but no seed document carries.
///
/// `renameMember` moves a name a seed already contains, so a name here widens
/// what a mutation can produce as a key and nothing more.
///
/// `_meta` is a deliberate gap: a capability object carrying it is a shape this
/// library does not otherwise produce, nothing in `src/` emits one, and a seed
/// invented only so the name could be renamed is a document no peer of this
/// protocol sends. `terminalId` is an ordinary one: no seed spells it, so there
/// is nothing for a mutation to move, and the subject it belongs to is a
/// decoder branch nothing else in the corpus reaches.
const grammar_only_names = [_][]const u8{
    "_meta",
    "terminalId",
};

/// Every string body the generator can write, key or value alike.
///
/// `writeObject` draws a member name from here too, so a key is not a special
/// case: the same table feeds both halves of a document.
const string_vocabulary = string_forms ++ member_names;

/// Number lexemes the generator writes.
///
/// The last two are past what an `f64` or an `i64` can hold, and a lexeme is
/// exactly what the reader returns, so both must survive as text.
///
/// `01` is the one form RFC 8259 forbids, and it is here because it is the only
/// shape on which the two parsers are recorded to differ: `Reader.number`
/// counts the digits and accepts it, `std.json.Scanner` refuses it, and the
/// differential run has to produce that disagreement to meet it at all. A
/// recorded divergence the generator cannot emit is a record nothing checks.
const number_forms = [_][]const u8{
    "0",
    "-0",
    "01",
    "1",
    "-1",
    "12",
    "0.5",
    "-0.5",
    "1.0",
    "1e3",
    "1E+3",
    "1e-3",
    "9007199254740993",
    "12345678901234567890",
};

/// Bytes a JSON grammar never produces, so a random draw lands on a near miss
/// far more often than on noise.
const hostile_alphabet = [_]u8{
    '{',  '}',  '[',  ']',  ':',  ',',  '"',  '\\', '/',  ' ',
    '\t', '\n', '\r', 't',  'r',  'u',  'e',  'f',  'a',  'l',
    's',  'n',  '0',  '1',  '9',  '-',  '+',  '.',  'e',  'E',
    'x',  'y',  'z',  0x00, 0x1f, 0x7f, 0x80, 0xc3, 0xa9, 0xff,
};

/// Documents a mutation starts from. Each is a well-formed message of the kind
/// the protocols actually carry, so a mutation is a change to a real document
/// rather than a change to noise.
///
/// The last two carry members no other seed spells, and they are here for the
/// decoder arms nothing else reaches: an MRTR interim result is the only
/// document `mcp.decodeInputRequiredResult` accepts, and a permission request
/// with a `toolCall` is the only document the stable arm of
/// `acp.decodePermissionRequest` accepts. Both are real messages at the pinned
/// revisions, so a mutation of either is a change to a real document.
const seed_documents = [_][]const u8{
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\"}}",
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"," ++
        "\"params\":{\"progress\":0.5}}",
    "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":" ++
        "{\"resultType\":\"complete\",\"content\":[]}}",
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"bad\"}}",
    "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"tools/call\"," ++
        "\"params\":{\"n\":1}}",
    "{\"result\":\"x\",\"error\":{\"code\":-1,\"message\":\"m\",\"data\":[1,2]}}",
    "{\"outcome\":\"selected\",\"optionId\":\"opt-1\"}",
    "{\"sessionId\":\"s\",\"title\":\"t\",\"options\":" ++
        "[{\"optionId\":\"o\",\"name\":\"n\",\"kind\":\"allow_once\"}]}",
    "{\"a\":[1,2,{\"b\":[true,false,null]}],\"c\":\"\\u00e9\\ud83d\\ude00\"}",
    "{\"resultType\":\"input_required\",\"inputRequests\":" ++
        "{\"r1\":{\"method\":\"tools/call\"}},\"requestState\":\"st-1\"}",
    "{\"sessionId\":\"s2\",\"title\":\"t\",\"description\":\"d\"," ++
        "\"toolCall\":{\"toolCallId\":\"tc\"}," ++
        "\"subject\":{\"type\":\"command\",\"command\":\"ls\",\"cwd\":\"/tmp\"}," ++
        "\"options\":[{\"optionId\":\"o\",\"name\":\"n\"," ++
        "\"kind\":\"allow_once\"}]}",
};

fn hostileByte(rng: std.Random) u8 {
    return hostile_alphabet[rng.intRangeLessThan(u8, 0, hostile_alphabet.len)];
}

fn writeSpace(rng: std.Random, doc: *Doc) void {
    if (rng.intRangeLessThan(u8, 0, 8) == 0) return;
    doc.pushByte(whitespace[rng.intRangeLessThan(u8, 0, whitespace.len)]);
}

fn writeString(rng: std.Random, doc: *Doc) void {
    doc.pushByte('"');
    const count = rng.intRangeLessThan(u8, 0, 4);
    for (0..count) |_| {
        doc.push(string_vocabulary[rng.intRangeLessThan(usize, 0, string_vocabulary.len)]);
    }
    doc.pushByte('"');
}

fn writeNumber(rng: std.Random, doc: *Doc) void {
    doc.push(number_forms[rng.intRangeLessThan(u8, 0, number_forms.len)]);
}

fn writeValue(rng: std.Random, doc: *Doc, depth: u32) void {
    if (depth >= 5 or rng.intRangeLessThan(u8, 0, 100) < 40) {
        switch (rng.intRangeLessThan(u8, 0, 6)) {
            0 => writeString(rng, doc),
            1 => writeNumber(rng, doc),
            2 => doc.push("true"),
            3 => doc.push("false"),
            4 => doc.push("null"),
            else => doc.push("\"\""),
        }
        return;
    }
    if (rng.boolean()) {
        writeObject(rng, doc, depth);
    } else {
        writeArray(rng, doc, depth);
    }
}

fn writeObject(rng: std.Random, doc: *Doc, depth: u32) void {
    doc.pushByte('{');
    const count = rng.intRangeLessThan(u8, 0, 5);
    for (0..count) |index| {
        if (index != 0) {
            writeSpace(rng, doc);
            doc.pushByte(',');
        }
        writeSpace(rng, doc);
        writeString(rng, doc);
        writeSpace(rng, doc);
        doc.pushByte(':');
        writeSpace(rng, doc);
        writeValue(rng, doc, depth + 1);
    }
    writeSpace(rng, doc);
    doc.pushByte('}');
}

fn writeArray(rng: std.Random, doc: *Doc, depth: u32) void {
    doc.pushByte('[');
    const count = rng.intRangeLessThan(u8, 0, 5);
    for (0..count) |index| {
        if (index != 0) {
            writeSpace(rng, doc);
            doc.pushByte(',');
        }
        writeSpace(rng, doc);
        writeValue(rng, doc, depth + 1);
    }
    writeSpace(rng, doc);
    doc.pushByte(']');
}

/// A document built from the grammar, so the borrow reader accepts all of it.
///
/// One form is the exception and it is deliberate: `number_forms` carries a
/// leading zero, which RFC 8259 forbids and `std.json.Scanner` refuses, so a
/// document that draws it is the one shape on which the two parsers differ.
fn writeValid(rng: std.Random, doc: *Doc) void {
    writeValue(rng, doc, 0);
}

/// Bytes a JSON grammar never produces, and mostly near misses.
fn writeHostile(rng: std.Random, doc: *Doc) void {
    const count = rng.intRangeLessThan(usize, 0, 96);
    for (0..count) |_| doc.pushByte(hostileByte(rng));
}

/// A slice of a real document with a handful of edits applied.
fn writeMutated(rng: std.Random, doc: *Doc) void {
    const source = seed_documents[rng.intRangeLessThan(usize, 0, seed_documents.len)];
    const start = rng.intRangeLessThan(usize, 0, source.len);
    doc.push(source[start .. start + rng.intRangeLessThan(usize, 0, source.len - start)]);

    const edits = rng.intRangeLessThan(usize, 0, 6);
    for (0..edits) |_| {
        if (doc.len == 0) break;
        const at = rng.intRangeLessThan(usize, 0, doc.len);
        switch (rng.intRangeLessThan(u8, 0, 4)) {
            0 => doc.bytes[at] = hostileByte(rng),
            1 => {
                // Both sides are the same explicit run. Slicing the source to
                // the end of the fixed array instead would make it longer than
                // the destination and trip `copyForwards`' length check.
                const run = doc.len - at - 1;
                std.mem.copyForwards(
                    u8,
                    doc.bytes[at..][0..run],
                    doc.bytes[at + 1 ..][0..run],
                );
                doc.len -= 1;
            },
            2 => doc.pushByte(hostileByte(rng)),
            else => {
                // `at` is drawn from the whole document, so the tail from it
                // can be empty; only a non-empty run can be duplicated.
                const tail = doc.len - at;
                if (tail == 0) {
                    doc.pushByte(hostileByte(rng));
                    continue;
                }
                const run = doc.bytes[at..][0..rng.intRangeLessThan(usize, 1, tail + 1)];
                doc.push(run);
            },
        }
    }
}

/// Replace the first occurrence of `from` in `source` with `to`, appending the
/// result to `doc`.
///
/// Returns false when the name is not there, when the two names are the same
/// and so nothing would move, or when the result would not fit `doc`. A rename
/// that changed nothing is not a mutation, and a truncated one is a different
/// document. The tail is rebuilt rather than patched in place: `to` is a
/// different width, so everything after the match moves.
fn renameMember(source: []const u8, from: []const u8, to: []const u8, doc: *Doc) bool {
    if (std.mem.eql(u8, from, to)) return false;
    const at = std.mem.indexOf(u8, source, from) orelse return false;
    if (source.len - from.len + to.len > max_doc_len) return false;
    doc.push(source[0..at]);
    doc.push(to);
    doc.push(source[at + from.len ..]);
    return true;
}

/// Whether any seed document spells `name`.
///
/// This is the question `renameMember` asks when it draws a name, so the two
/// answers agree by construction: the first occurrence it would rewrite is the
/// first one this finds. The needle is `"name"`, so a member that is only a
/// prefix of a longer one does not count as spelled.
fn spelledByASeed(comptime name: []const u8) bool {
    for (seed_documents) |document| {
        if (std.mem.indexOf(u8, document, "\"" ++ name ++ "\"") != null) return true;
    }
    return false;
}

/// Whether `grammar_only_names` lists `name`.
fn isGrammarOnly(comptime name: []const u8) bool {
    for (grammar_only_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// A real message with one of its members renamed to another member name.
///
/// `writeMutated` damages bytes, so the key it leaves behind is a key the seed
/// never spelled and the decoder cannot name. This shape moves a member the
/// protocol decoder branches on onto a name it does not know, which is the
/// only mutation that makes the key rules observable: the same document with
/// `id` renamed is a notification rather than a request, and with `jsonrpc`
/// renamed it is a refusal.
fn writeMemberRenamed(rng: std.Random, doc: *Doc) void {
    const source = seed_documents[rng.intRangeLessThan(usize, 0, seed_documents.len)];
    const from = member_names[rng.intRangeLessThan(usize, 0, member_names.len)];
    const to = member_names[rng.intRangeLessThan(usize, 0, member_names.len)];
    if (renameMember(source, from, to, doc)) return;
    // A seed that spells neither name, or a rename that would overflow the
    // document, is not a rename. The seed itself still reaches every decoder,
    // so this branch costs no coverage.
    doc.push(source);
}

/// The document shapes the corpus is built from.
///
/// Each one reaches every decoder, so the choice is about which property it
/// exercises and not about which decoder sees it.
const Shape = enum {
    /// Assembled from the grammar, so the borrow reader accepts it. A leading
    /// zero is the one exception, and it is the divergence the corpus exists
    /// to produce.
    composed,
    /// Bytes no grammar produces.
    hostile,
    /// A real document with bytes damaged.
    mutated,
    /// A real document with a member renamed.
    renamed,
    /// Two damaged documents joined, which is wrong at exactly one seam.
    spliced,
};

/// The order the shapes are drawn in. Both harnesses walk this list, so the
/// property run and the differential run see the same documents.
const shapes = [_]Shape{
    .composed,
    .hostile,
    .mutated,
    .renamed,
    .spliced,
};

/// Build the `index`-th document of a run into `doc`.
///
/// `spare` is the join buffer for the spliced shape alone; every other shape
/// ignores it.
fn writeShape(rng: std.Random, doc: *Doc, spare: *Doc, index: usize) void {
    doc.clear();
    switch (shapes[index % shapes.len]) {
        .composed => writeValid(rng, doc),
        .hostile => writeHostile(rng, doc),
        .mutated => writeMutated(rng, doc),
        .renamed => writeMemberRenamed(rng, doc),
        .spliced => {
            spare.clear();
            writeMutated(rng, spare);
            writeMutated(rng, doc);
            doc.push(spare.slice());
        },
    }
}

// --- The generated walk over the reader surface --------------------------------

/// Consume one value, decoding every string and reading every scalar.
///
/// The container bound is the reader's own: `enterContainer` refuses past
/// `json.max_depth`, so the recursion cannot outrun it, and a second guard here
/// would only be a second place for the bound to be wrong.
fn walkValue(reader: *json.Reader, scratch: []u8) DecodeError!void {
    reader.skipWhitespace();
    const byte = reader.peek() orelse return error.Truncated;
    switch (byte) {
        '"' => _ = try reader.string(scratch),
        '{' => {
            if (try reader.beginObject()) return;
            while (try reader.nextKey(scratch)) |_| {
                try walkValue(reader, scratch);
            }
        },
        '[' => {
            if (try reader.beginArray()) return;
            while (try reader.nextArrayElement()) {
                try walkValue(reader, scratch);
            }
        },
        't', 'f' => _ = try reader.boolean(),
        'n' => try reader.nullLiteral(),
        '-', '0'...'9' => _ = try reader.number(),
        else => try reader.skipValue(scratch),
    }
}

/// The top-level JSON classification, as both parsers report it.
const Kind = enum { object, array, string, number, boolean, null_value };

/// Whether the borrow reader accepts `input` as one complete JSON value.
fn borrowAccepts(input: []const u8, scratch: []u8) bool {
    var reader = json.Reader.init(input);
    reader.skipValue(scratch) catch return false;
    return reader.atEnd();
}

/// The classification the borrow reader implies, from its first structural
/// byte. Reading it from the reader rather than from a hand-rolled peek is what
/// keeps the two answers comparable.
fn borrowKind(input: []const u8) ?Kind {
    var reader = json.Reader.init(input);
    reader.skipWhitespace();
    const byte = reader.peek() orelse return null;
    return switch (byte) {
        '{' => .object,
        '[' => .array,
        '"' => .string,
        '-', '0'...'9' => .number,
        't', 'f' => .boolean,
        'n' => .null_value,
        else => null,
    };
}

// --- Comparisons across two decodes --------------------------------------------

/// Compare two borrowed strings by content.
///
/// The two decodes read from different buffers, so a slice comparison would be a
/// pointer comparison and would fail on every successful round trip.
fn expectSameString(first: ?[]const u8, second: ?[]const u8) !void {
    const testing = std.testing;
    if (first) |text| {
        try testing.expectEqualStrings(text, second orelse return error.TestUnexpectedResult);
    } else {
        try testing.expect(second == null);
    }
}

fn expectSameId(first: ?jsonrpc.Id, second: ?jsonrpc.Id) !void {
    const testing = std.testing;
    const id = first orelse {
        try testing.expect(second == null);
        return;
    };
    switch (id) {
        .integer => |number| {
            const other = switch (second orelse return error.TestUnexpectedResult) {
                .integer => |value| value,
                .string => return error.TestUnexpectedResult,
            };
            try testing.expectEqual(number, other);
        },
        .string => |text| {
            const other = switch (second orelse return error.TestUnexpectedResult) {
                .string => |value| value,
                .integer => return error.TestUnexpectedResult,
            };
            try testing.expectEqualStrings(text, other);
        },
    }
}

fn expectSameMessage(first: jsonrpc.Message, second: jsonrpc.Message) !void {
    const testing = std.testing;
    try testing.expectEqual(first.kind, second.kind);
    try expectSameId(first.id, second.id);

    // A method is split once on `/`, so the re-decode has to reproduce the
    // category and the action as well as the whole name.
    if (first.method) |method| {
        const other = second.method orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(method.text, other.text);
        try testing.expectEqualStrings(method.category, other.category);
        try testing.expectEqualStrings(method.action, other.action);
    } else {
        try testing.expect(second.method == null);
    }

    try expectSameString(first.result, second.result);

    if (first.rpc_error) |object| {
        const other = second.rpc_error orelse return error.TestUnexpectedResult;
        try testing.expectEqual(object.code, other.code);
        try testing.expectEqualStrings(object.message, other.message);
        try expectSameString(object.data, other.data);
    } else {
        try testing.expect(second.rpc_error == null);
    }

    switch (first.params) {
        .absent => try testing.expect(second.params == .absent),
        .null_value => try testing.expect(second.params == .null_value),
        .value => |text| {
            const other = switch (second.params) {
                .value => |value| value,
                else => return error.TestUnexpectedResult,
            };
            try testing.expectEqualStrings(text, other);
        },
    }
}

// --- Round trips ---------------------------------------------------------------

const Stats = struct {
    documents: usize = 0,
    accepted: usize = 0,
    refused: usize = 0,
    round_trips: usize = 0,
};

fn roundTripJsonRpc(
    message: jsonrpc.Message,
    scratch: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    // `decode` produces only shapes `validate` accepts, so any refusal here is
    // a harness buffer that is too small, and returning it fails the test
    // rather than quietly skipping the round trip.
    try jsonrpc.encode(message, &writer);
    try expectSameMessage(message, try jsonrpc.decode(writer.written(), scratch));
    stats.round_trips += 1;
}

fn roundTripEnvelope(
    envelope: bridge.Envelope,
    scratch: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    if (bridge.encodeEnvelope(envelope, &writer)) |_| {
        // The outer id is not a member of the params object, so the re-decode
        // cannot be told the direction and reports the notification.
        const again = try bridge.decodeEnvelope(writer.written(), scratch, null);
        try testing.expectEqualStrings(envelope.server_id, again.server_id);
        try testing.expectEqualStrings(envelope.request_id, again.request_id);
        try testing.expectEqualStrings(envelope.inner_method, again.inner_method);
        try expectSameString(envelope.inner_params, again.inner_params);
        stats.round_trips += 1;
    } else |err| {
        // A decoded envelope carries three non-empty members, which is what
        // `encodeEnvelope` validates, so the only error left here is a harness
        // buffer that is too small.
        return err;
    }
}

fn roundTripOutcome(outcome: bridge.Outcome, scratch: []u8, stats: *Stats) !void {
    // No encoder exists for the carrier, so the property is the one the
    // borrowed text has to satisfy: a fresh reader must still see a complete
    // value at exactly the bytes the decoder handed back.
    const text = switch (outcome) {
        .result => |value| value,
        .@"error" => |value| value,
    };
    if (!borrowAccepts(text, scratch)) return error.BorrowedValueTruncated;
    stats.round_trips += 1;
}

fn roundTripPermissionOutcome(
    outcome: acp.PermissionOutcome,
    scratch: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try acp.encodePermissionOutcome(outcome, &writer);
    const again = try acp.decodePermissionOutcome(writer.written(), scratch);
    switch (outcome) {
        .cancelled => try testing.expect(again == .cancelled),
        .selected => |id| try testing.expectEqualStrings(id, again.selected),
    }
    stats.round_trips += 1;
}

fn roundTripResultType(
    result: mcp.ResultType,
    scratch: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try writer.byte('{');
    if (result.value) |value| {
        try writer.slice("\"resultType\":");
        try writer.string(value);
    }
    try writer.byte('}');
    try expectSameString(
        result.value,
        (try mcp.decodeResultType(writer.written(), scratch)).value,
    );
    stats.round_trips += 1;
}

fn roundTripInputRequiredResult(
    result: mcp.InputRequiredResult,
    scratch: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try writer.byte('{');
    // The separator is written in front of every member after the first rather
    // than baked into each one, because `resultType` is optional: a result the
    // peer left out decodes with a null value, and a comma where that member
    // stood is a document `takeSeparator` is right to refuse. The harness was
    // building the malformed document, not the decoder.
    var separator: []const u8 = "";
    if (result.result_type.value) |value| {
        try writer.slice(separator);
        try writer.slice("\"resultType\":");
        try writer.string(value);
        separator = ",";
    }
    if (result.input_requests) |requests| {
        try writer.slice(separator);
        try writer.slice("\"inputRequests\":");
        try writer.slice(requests);
        separator = ",";
    }
    if (result.request_state) |state| {
        try writer.slice(separator);
        try writer.slice("\"requestState\":");
        try writer.string(state);
    }
    try writer.byte('}');
    const again = try mcp.decodeInputRequiredResult(writer.written(), scratch);
    try expectSameString(result.result_type.value, again.result_type.value);
    try expectSameString(result.input_requests, again.input_requests);
    try expectSameString(result.request_state, again.request_state);
    stats.round_trips += 1;
}

/// Every recorded path must own a region no later path overwrote.
///
/// What this proves is narrow and worth naming: every entry points into the
/// caller's `paths` buffer, and consecutive entries do not overlap, so the
/// capability walk hands out its regions once each. It says nothing about
/// `json.Reader`'s own scratch, which is a different allocator with a
/// different high-water mark; `expectDisjointRegions` is the assertion for
/// that one. A recycled region would leave two entries pointing at the same
/// bytes, and `isMethodSupported` would answer a question about whichever was
/// written last.
fn expectDisjointPaths(entries: []const acp.Capability, paths: []const u8) !void {
    const testing = std.testing;
    const base = @intFromPtr(paths.ptr);
    for (entries, 0..) |entry, index| {
        const start = @intFromPtr(entry.path.ptr);
        // The path is a slice of the caller's buffer, not of a dead frame. A
        // member name that is the empty string yields an empty path, so the
        // length itself is not asserted; the bounds below are the invariant.
        try testing.expect(start >= base);
        try testing.expect(start + entry.path.len <= base + paths.len);
        if (index == 0) continue;
        const previous = entries[index - 1].path;
        try testing.expect(start >= @intFromPtr(previous.ptr) + previous.len);
    }
}

/// Every borrowed region must come from `scratch` and no two may overlap.
///
/// This is the property `json.Reader` documents for its bump offset, and it is
/// the one `expectDisjointPaths` cannot see. A region that is outside
/// `scratch` was borrowed from the input instead, which is a different promise
/// from the one asserted here, so it is a failure rather than an exemption.
fn expectDisjointRegions(scratch: []const u8, regions: []const []const u8) !void {
    const testing = std.testing;
    const base = @intFromPtr(scratch.ptr);
    for (regions) |region| {
        const start = @intFromPtr(region.ptr);
        try testing.expect(start >= base);
        try testing.expect(start + region.len <= base + scratch.len);
    }
    for (regions, 0..) |region, index| {
        if (index == 0) continue;
        for (regions[index + 1 ..]) |later| {
            const here = @intFromPtr(region.ptr);
            const there = @intFromPtr(later.ptr);
            try testing.expect(here + region.len <= there or there + later.len <= here);
        }
    }
}

test "one reader hands out disjoint scratch regions" {
    const testing = std.testing;
    // The property AGENTS.md pins for the substrate: two escaped strings read
    // from one reader take separate regions of the caller's scratch, so the
    // first is still intact when the second is read. A bump offset that
    // recycled a region would pass every single-string test there is.
    const input = "\"a\\nb\" \"c\\nd\" \"plain\"";
    var scratch: [16]u8 = undefined;
    var reader = json.Reader.init(input);
    const first = try reader.string(&scratch);
    const second = try reader.string(&scratch);
    // The third string carries no escape, so it borrows the input and costs no
    // scratch. It is not one of the regions: the assertion is about the two
    // that took a region, and including this one would compare a borrowed
    // slice against the buffer it did not come from.
    const plain = try reader.string(&scratch);
    try testing.expectEqualStrings("plain", plain);
    // It points into the input rather than the scratch, which is the promise
    // the escaped path does not make: a string with no escape borrows the
    // document and costs nothing.
    const input_base = @intFromPtr(input.ptr);
    try testing.expect(@intFromPtr(plain.ptr) >= input_base);
    try testing.expect(@intFromPtr(plain.ptr) + plain.len <= input_base + input.len);

    try expectDisjointRegions(&scratch, &.{ first, second });
    // Disjoint is not enough: a reader that handed out two regions in the wrong
    // order would still be disjoint, and the contents would be swapped.
    try testing.expectEqualStrings("a\nb", first);
    try testing.expectEqualStrings("c\nd", second);
    try testing.expectEqual(@as(usize, 6), reader.bump);
}

test "requiredScratchLen is exact for a message holding two escaped strings" {
    const testing = std.testing;
    // The same quota as the corpus guard, for the same kind of reason: the
    // measurement below runs at comptime and walks the document twice. One
    // short document fits inside the default thousand, so this is headroom
    // rather than a fix, and it is here so that lengthening the document does
    // not turn a property test into a compile error.
    @setEvalBranchQuota(20_000);

    // An id and an error message, both escaped, both alive in the returned
    // message at once. This is the case the scratch contract is written for,
    // and the count has to cover both: it is a sum, not a maximum.
    const text = "{\"jsonrpc\":\"2.0\",\"id\":\"a\\nb\"," ++
        "\"error\":{\"code\":-1,\"message\":\"c\\nd\"}}";
    // `comptime` and not a plain `const`: the document is a literal, so the
    // count is computable at compile time, but a `const` bound to a call is a
    // runtime value to the compiler and the array below would have no type.
    const measured = comptime json.Reader.requiredScratchLen(text);
    try testing.expectEqual(@as(usize, 6), measured);

    var scratch: [measured]u8 = undefined;
    const message = try jsonrpc.decode(text, &scratch);
    const id = message.id.?.string;
    const reported = message.rpc_error.?.message;
    try expectDisjointRegions(&scratch, &.{ id, reported });
    try testing.expectEqualStrings("a\nb", id);
    try testing.expectEqualStrings("c\nd", reported);

    // A bound that over-counted would satisfy the decode above and this would
    // pass with a byte to spare, so the count is measured from the other side
    // as well: one byte short and the same document does not decode.
    var tight: [measured - 1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, jsonrpc.decode(text, &tight));
}

// --- The decoder battery --------------------------------------------------------

/// Feed one document to every public decoder and check the properties.
///
/// `scratch` and `replay` are two buffers of the same size on purpose: the
/// round trips decode into `replay`, so the first decode's borrowed values are
/// still intact when the two are compared.
fn exerciseEveryDecoder(
    input: []const u8,
    scratch: []u8,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    stats.documents += 1;

    // The reader surface on its own, with a buffer sized by the function the
    // documentation tells a caller to size it from. Every string in the
    // document is decoded, so a count that under-measured shows up here as a
    // `BufferTooSmall` on input the caller sized correctly.
    var walk_scratch: [max_doc_len]u8 = undefined;
    const measured = json.Reader.requiredScratchLen(input);
    try testing.expect(measured <= walk_scratch.len);
    if (borrowAccepts(input, &walk_scratch)) {
        var walk_reader = json.Reader.init(input);
        try walkValue(&walk_reader, walk_scratch[0..measured]);
    }

    if (jsonrpc.decode(input, scratch)) |message| {
        stats.accepted += 1;
        try roundTripJsonRpc(message, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (mcp.decodeResultType(input, scratch)) |result| {
        stats.accepted += 1;
        try roundTripResultType(result, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (mcp.decodeInputRequiredResult(input, scratch)) |result| {
        stats.accepted += 1;
        try roundTripInputRequiredResult(result, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (acp.nextFrame(input)) |frame| {
        stats.accepted += 1;
        var writer = json.Writer.init(out);
        try acp.writeFrame(frame.bytes, &writer);
        const again = try acp.nextFrame(writer.written());
        try testing.expectEqualStrings(frame.bytes, again.bytes);
        try testing.expect(!again.unterminated);
        try testing.expectEqualStrings("", again.rest);
        stats.round_trips += 1;
    } else |_| {
        stats.refused += 1;
    }

    if (acp.decodePermissionOutcome(input, scratch)) |outcome| {
        stats.accepted += 1;
        try roundTripPermissionOutcome(outcome, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    // The option array every permission-request decode writes into. A document
    // with more options than this is a `BufferTooSmall`, which a caller sees as
    // a decode error rather than a truncated list of choices.
    var permission_options: [16]acp.PermissionOption = undefined;
    if (acp.decodePermissionRequest(.stable, input, &permission_options, scratch)) |request| {
        stats.accepted += 1;
        const v1 = switch (request) {
            .stable => |value| value,
            .draft => return error.TestUnexpectedResult,
        };
        try testing.expect(borrowAccepts(v1.tool_call, replay));
        stats.round_trips += 1;
    } else |_| {
        stats.refused += 1;
    }

    if (acp.decodePermissionRequest(.draft, input, &permission_options, scratch)) |request| {
        stats.accepted += 1;
        const v2 = switch (request) {
            .draft => |value| value,
            .stable => return error.TestUnexpectedResult,
        };
        // The v2 subject is carried verbatim on the `tool_call` arm, so it must
        // still be a complete value to a fresh reader.
        if (v2.subject) |subject| {
            switch (subject) {
                .tool_call => |call| try testing.expect(borrowAccepts(call, replay)),
                .command, .other => {},
            }
        }
        stats.round_trips += 1;
    } else |_| {
        stats.refused += 1;
    }

    if (bridge.decodeEnvelope(input, scratch, .{ .integer = 1 })) |envelope| {
        stats.accepted += 1;
        try roundTripEnvelope(envelope, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (bridge.decodeEnvelope(input, scratch, null)) |envelope| {
        stats.accepted += 1;
        // Without an outer id the same params bytes are a notification, so the
        // direction is the one member the params object cannot carry.
        try testing.expect(envelope.direction == .provider_to_agent);
    } else |_| {
        stats.refused += 1;
    }

    if (bridge.decodeOutcome(input, scratch)) |outcome| {
        stats.accepted += 1;
        try roundTripOutcome(outcome, replay, stats);
    } else |_| {
        stats.refused += 1;
    }

    var capabilities: [32]acp.Capability = undefined;
    var paths: [512]u8 = undefined;
    for ([_]acp.WireVersion{ .stable, .draft }) |version| {
        for ([_]acp.Side{ .client, .agent }) |side| {
            if (acp.decodeCapabilityObject(
                version,
                side,
                input,
                &capabilities,
                &paths,
                scratch,
            )) |set| {
                stats.accepted += 1;
                // An empty object is a peer that advertises nothing, which is a
                // fact rather than an error, so every success is present.
                try testing.expect(set.present);
                try expectDisjointPaths(set.entries, paths[0..]);
            } else |_| {
                // Arbitrary input is usually not a capability object. Any
                // DecodeError is a valid refusal; only a trap violates totality.
                stats.refused += 1;
            }
        }
    }

    // The registries take a name rather than a document, so they are fed a
    // name taken from the document: something a peer could plausibly have sent.
    if (input.len != 0) {
        const name = input[0..@min(input.len, 24)];
        if (mcp.lookupMethod(.current, name)) |_| {} else |err| switch (err) {
            error.UnknownMethod => {},
            else => return err,
        }
        if (mcp.lookupMethod(.previous, name)) |_| {} else |err| switch (err) {
            error.UnknownMethod => {},
            else => return err,
        }
        if (acp.lookupMethod(.stable, name)) |_| {} else |err| switch (err) {
            error.UnknownMethod => {},
            else => return err,
        }
        if (acp.lookupMethod(.draft, name)) |_| {} else |err| switch (err) {
            error.UnknownMethod => {},
            else => return err,
        }
    }
}

/// Generate `count` documents and run every one through every decoder.
fn runPropertyHarness(run_seed: u64, count: usize) !Stats {
    const testing = std.testing;
    std.debug.print(
        "\nproperty harness: seed=0x{X} iterations={d}\n",
        .{ run_seed, count },
    );

    var prng = std.Random.DefaultPrng.init(run_seed);
    const rng = prng.random();

    var stats: Stats = .{};
    var doc: Doc = .{};
    var splice: Doc = .{};
    var scratch: [max_doc_len]u8 = undefined;
    var replay: [max_doc_len]u8 = undefined;
    var out: [encode_buf_len]u8 = undefined;

    for (0..count) |index| {
        writeShape(rng, &doc, &splice, index);
        try exerciseEveryDecoder(doc.slice(), &scratch, &replay, &out, &stats);
    }

    // A run that generated nothing useful would pass by decoding nothing.
    // These are the only guarantees a seed-independent count can make.
    try testing.expect(stats.documents == count);
    try testing.expect(stats.accepted != 0);
    try testing.expect(stats.refused != 0);
    try testing.expect(stats.round_trips != 0);
    std.debug.print(
        "  documents={d} accepted={d} refused={d} round-trips={d}\n",
        .{ stats.documents, stats.accepted, stats.refused, stats.round_trips },
    );
    return stats;
}

test "every public decoder is total over generated input" {
    _ = try runPropertyHarness(seed, iterations);
}

test "the generator can spell every member jsonrpc.decode branches on" {
    // Transcribed from the branches of `jsonrpc.decode` and `decodeError`. The
    // point is the comparison and not the transcription: a generator whose
    // vocabulary lacks one of these hands the decoder the keys the seed
    // documents spell and nothing else, and the unknown-member, missing-member
    // and classification rules are then asserted over a corpus that cannot
    // reach them. The wider table is checked against the corpus rather than
    // against a decoder, because a decoder's key set cannot be read as data
    // from here; `test "every member name is in a seed or listed as
    // grammar-only"` is what keeps that table from growing into weight.
    const decoded_names = [_][]const u8{
        "jsonrpc",
        "id",
        "method",
        "params",
        "result",
        "error",
        "code",
        "message",
        "data",
    };
    for (decoded_names) |name| {
        var reachable = false;
        for (string_vocabulary) |form| {
            if (std.mem.eql(u8, form, name)) reachable = true;
        }
        if (!reachable) {
            std.debug.print("\ngenerator: no document can carry the member '{s}'\n", .{name});
            return error.MemberNameUnreachable;
        }
    }
}

test "every member name is in a seed or listed as grammar-only" {
    // The quota is the price of the check below, not slack. The loop unrolls,
    // every comparison runs at comptime, and each name is searched through
    // every seed, so the work is names times seeds times a substring search
    // that preprocesses its own skip table. That is more backwards branches
    // than the default thousand allows by a wide margin, and 20 000 was not
    // enough either: the compiler reported the same overflow at that figure,
    // so the number is two orders above the limit rather than one. Deleting
    // the keyword does not make the check cheaper, it makes the test fail to
    // compile, so raise the number rather than drop a name.
    @setEvalBranchQuota(200_000);

    // The table of member names and the two ways the corpus can use one have to
    // cover each other exactly. A name a seed spells is one a mutation can move;
    // a name no seed spells is one the grammar generator can emit as a key and
    // nothing more, and it has to be listed as such or it is corpus weight. A
    // name in neither place widens every mutation in the corpus and reaches no
    // rule, so this fails rather than growing.
    //
    // `inline for` and not `for`, and the body carries no `continue`, no
    // `break` and no `return`. The loop unrolls, so a `continue` inside it is
    // comptime control flow in a runtime block, which Zig refuses. Take the
    // `inline` away and each name becomes a runtime value, `spelledByASeed`
    // loses the comptime parameter it is written around, and the table is free
    // to grow into weight again. So the body records which name failed and the
    // verdict is reached after the loop, where a `return` is ordinary control
    // flow. Do not put the `inline` back for speed: there is nothing to speed
    // up, and the property is what the loop is for.
    var stale: ?[]const u8 = null;
    var unexplained: ?[]const u8 = null;
    inline for (member_names) |name| {
        // `comptime` for the same reason as the count in the scratch test: a
        // `const` bound to a call is a runtime value, and these two answers are
        // the whole assertion.
        const spelled = comptime spelledByASeed(name);
        const listed = comptime isGrammarOnly(name);
        if (stale == null and spelled and listed) stale = name;
        if (unexplained == null and !spelled and !listed) unexplained = name;
    }
    // A listing that names something a seed now spells is stale the other way,
    // and one loop catches both faults: a name that is both spelled and listed
    // is the stale case, and a name that is neither is the unexplained one.
    if (stale) |name| {
        std.debug.print("\ncorpus: '{s}' is in a seed and listed grammar-only\n", .{name});
        return error.StaleGrammarOnlyName;
    }
    if (unexplained) |name| {
        std.debug.print("\ncorpus: '{s}' is in no seed and not listed\n", .{name});
        return error.UnreachableMemberName;
    }
}

test "a renamed member reaches the acp and bridge decoders too" {
    const testing = std.testing;
    // The rename is not a JSON-RPC trick. These take keys that came from a seed
    // rather than from the grammar generator, so a decoder outside the base
    // layer is shown to read a member name a mutation changed.
    var doc: Doc = .{};
    var options: [4]acp.PermissionOption = undefined;
    var scratch: [max_doc_len]u8 = undefined;

    // `outcome` is the discriminator the ACP outcome decoder branches on and
    // `optionId` is what makes a selected outcome usable, so the untouched
    // document is a selected outcome carrying an id and either member renamed
    // leaves the decoder with nothing to answer.
    switch (try acp.decodePermissionOutcome(seed_documents[6], &scratch)) {
        .selected => |id| try testing.expectEqualStrings("opt-1", id),
        .cancelled => return error.TestUnexpectedResult,
    }
    doc.clear();
    try testing.expect(renameMember(seed_documents[6], "outcome", "outcomes", &doc));
    const no_branch = doc.slice();
    const refused_outcome = acp.decodePermissionOutcome(no_branch, &scratch);
    try testing.expectError(error.MissingField, refused_outcome);
    doc.clear();
    try testing.expect(renameMember(seed_documents[6], "optionId", "outcomeId", &doc));
    const no_option = doc.slice();
    const refused_id = acp.decodePermissionOutcome(no_option, &scratch);
    try testing.expectError(error.MissingField, refused_id);

    // The draft permission request is the ACP rule with the most member names
    // behind it: a session, an option list and a title. Renaming the list is a
    // missing required member, not an extension point.
    const request = try acp.decodePermissionRequest(.draft, seed_documents[7], &options, &scratch);
    switch (request) {
        .draft => |value| {
            try testing.expectEqualStrings("s", value.session_id);
            try testing.expectEqual(@as(usize, 1), value.options.len);
        },
        .stable => return error.TestUnexpectedResult,
    }
    doc.clear();
    try testing.expect(renameMember(seed_documents[7], "options", "optionz", &doc));
    const no_options = doc.slice();
    const refused_request = acp.decodePermissionRequest(.draft, no_options, &options, &scratch);
    try testing.expectError(error.MissingField, refused_request);

    // The envelope carries the three members both directions validate, so a
    // renamed one is the missing-field rule one layer down.
    const envelope = try bridge.decodeEnvelope(seed_documents[4], &scratch, null);
    try testing.expectEqualStrings("s", envelope.server_id);
    doc.clear();
    try testing.expect(renameMember(seed_documents[4], "serverId", "serverID", &doc));
    const no_server = doc.slice();
    const refused_envelope = bridge.decodeEnvelope(no_server, &scratch, null);
    try testing.expectError(error.MissingField, refused_envelope);
}

test "a renamed member changes what jsonrpc.decode returns" {
    const testing = std.testing;
    // `id` is what classifies a request against a notification, so renaming it
    // is the sharpest mutation the corpus can make: the document differs from
    // a valid request by one character, and a decoder that read the member
    // reports a different shape than one that did not. The document is the
    // corpus's own request, so the test and the generator agree on what a well
    // formed one is.
    const request = seed_documents[0];
    var doc: Doc = .{};
    try testing.expect(renameMember(request, "id", "ids", &doc));
    const renamed = doc.slice();
    // The rename is a rename and not a corruption: the old key is gone and the
    // new one is where it stood.
    try testing.expect(std.mem.indexOf(u8, renamed, "\"ids\":") != null);
    try testing.expect(std.mem.indexOf(u8, renamed, "\"id\":") == null);

    var scratch: [max_doc_len]u8 = undefined;
    const before = try jsonrpc.decode(request, &scratch);
    try testing.expect(before.kind == .request);
    const after = try jsonrpc.decode(renamed, &scratch);
    try testing.expect(after.kind == .notification);
    try testing.expect(after.id == null);
    try testing.expect(after.method != null);

    // The version member is a requirement rather than a classification, so a
    // renamed one is a refusal. A decoder that read no member name at all would
    // report a missing field for the wrong reason, which is why the error is
    // named here rather than counted.
    doc.clear();
    try testing.expect(renameMember(request, "jsonrpc", "jsonrp", &doc));
    try testing.expectError(error.MissingField, jsonrpc.decode(doc.slice(), &scratch));

    // A name the seed does not spell is not a rename, and the harness says so
    // rather than pretending it made one.
    doc.clear();
    try testing.expect(!renameMember(request, "outcome", "result", &doc));
    try testing.expectEqual(@as(usize, 0), doc.len);

    // A rename onto the name it already has moves nothing, so the harness
    // refuses it rather than counting an unedited seed as a mutation.
    try testing.expect(!renameMember(request, "id", "id", &doc));
}

test "a renamed document is measured before it is decoded" {
    const testing = std.testing;
    // The renamed shape is new, so the scratch bound has to hold for it as it
    // does for every other document: the walk is handed the count
    // `requiredScratchLen` reports and nothing more.
    const escaped_key = "m\\u00e9thod";
    var doc: Doc = .{};
    try testing.expect(renameMember(seed_documents[1], "method", escaped_key, &doc));
    const bytes = doc.slice();
    const measured = json.Reader.requiredScratchLen(bytes);
    try testing.expect(measured <= max_doc_len);

    var scratch: [max_doc_len]u8 = undefined;
    try testing.expect(borrowAccepts(bytes, scratch[0..measured]));
    var reader = json.Reader.init(bytes);
    try walkValue(&reader, scratch[0..measured]);

    // An escaped member is still a legal JSON name, so the reference parser
    // takes the document and the two spellings differ only where it matters:
    // the decoder no longer finds the member it classifies on.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try referenceAccepts(arena.allocator(), bytes));
    try testing.expectError(error.MissingField, jsonrpc.decode(bytes, &scratch));
}

// --- Differential testing against std.json --------------------------------------

fn referenceAccepts(allocator: std.mem.Allocator, input: []const u8) !bool {
    return std.json.Scanner.validate(allocator, input);
}

fn referenceKind(allocator: std.mem.Allocator, input: []const u8) !?Kind {
    var scanner = std.json.Scanner.initCompleteInput(allocator, input);
    defer scanner.deinit();
    const token = try scanner.nextAlloc(allocator, .alloc_if_needed);
    return switch (token) {
        .object_begin => .object,
        .array_begin => .array,
        .string, .partial_string, .allocated_string => .string,
        .number, .partial_number, .allocated_number => .number,
        .true, .false => .boolean,
        .null => .null_value,
        else => null,
    };
}

/// Whether the two parsers agree on a document, in the direction recorded.
const Verdict = enum { both_accept, both_reject, borrow_only, reference_only };

/// A hand-written document and the answer both parsers must give for it.
///
/// Every case the two legitimately disagree on is here with its reason, and
/// the test asserts the recorded answer rather than skipping the document. A
/// case that starts agreeing is a fix to the library and a line to delete; a
/// case that starts disagreeing the other way is a regression the test must not
/// absorb silently.
const DivergenceCase = struct {
    name: []const u8,
    text: []const u8,
    verdict: Verdict,
    why: []const u8,
};

const divergence_cases = [_]DivergenceCase{
    .{
        .name = "leading zero",
        .text = "01",
        .verdict = .borrow_only,
        .why = "RFC 8259 forbids a leading zero; Reader.number counts digits " ++
            "and does not refuse one",
    },
    .{
        .name = "leading zero in a member",
        .text = "{\"a\":01}",
        .verdict = .borrow_only,
        .why = "the same rule, reached through skipValue",
    },
    .{
        .name = "leading zero in an id",
        .text = "{\"jsonrpc\":\"2.0\",\"id\":01,\"method\":\"x\"}",
        .verdict = .borrow_only,
        .why = "parseInt accepts 01 as 1",
    },
    .{
        .name = "empty object",
        .text = "{ }",
        .verdict = .both_accept,
        .why = "whitespace is legal between the brace and the first member",
    },
    .{
        .name = "empty array",
        .text = "[ ]",
        .verdict = .both_accept,
        .why = "and between the bracket and the first element",
    },
    .{
        .name = "whitespace everywhere",
        .text = "{ \"a\" : [ 1 , 2 ] }",
        .verdict = .both_accept,
        .why = "insignificant whitespace",
    },
    .{
        .name = "bmp escape and surrogate pair",
        .text = "\"\\u00e9\\ud83d\\ude00\"",
        .verdict = .both_accept,
        .why = "a pair is one code point",
    },
    .{
        .name = "nul escape",
        .text = "\"\\u0000\"",
        .verdict = .both_accept,
        .why = "an escape may name a control character",
    },
    .{
        .name = "fraction and negative exponent",
        .text = "1.5e-3",
        .verdict = .both_accept,
        .why = "an ordinary number",
    },
    .{
        .name = "empty input",
        .text = "",
        .verdict = .both_reject,
        .why = "there is no value",
    },
    .{
        .name = "whitespace only",
        .text = "  ",
        .verdict = .both_reject,
        .why = "and no value after it",
    },
    .{
        .name = "truncated object",
        .text = "{",
        .verdict = .both_reject,
        .why = "the closing brace is missing",
    },
    .{
        .name = "truncated member",
        .text = "{\"a\":1",
        .verdict = .both_reject,
        .why = "the value is complete but the object is not",
    },
    .{
        .name = "leading comma in an object",
        .text = "{,\"a\":1}",
        .verdict = .both_reject,
        .why = "a comma needs a member on each side",
    },
    .{
        .name = "leading comma in an array",
        .text = "[,1]",
        .verdict = .both_reject,
        .why = "and an element on each side",
    },
    .{
        .name = "trailing comma",
        .text = "{\"a\":1,}",
        .verdict = .both_reject,
        .why = "there is no second member",
    },
    .{
        .name = "doubled comma",
        .text = "{\"a\":1,,\"b\":2}",
        .verdict = .both_reject,
        .why = "one separator is not two",
    },
    .{
        .name = "missing colon",
        .text = "{\"a\" 1}",
        .verdict = .both_reject,
        .why = "a member is a key, a colon and a value",
    },
    .{
        .name = "missing value",
        .text = "{\"a\":}",
        .verdict = .both_reject,
        .why = "the value is not optional",
    },
    .{
        .name = "two documents",
        .text = "{\"a\":1}{\"b\":2}",
        .verdict = .both_reject,
        .why = "a frame carries one document",
    },
    .{
        .name = "trailing value",
        .text = "1 2",
        .verdict = .both_reject,
        .why = "and there is no separator between two values",
    },
    .{
        .name = "raw control character",
        .text = "\"a\x01b\"",
        .verdict = .both_reject,
        .why = "0x00 to 0x1f are not in the string grammar",
    },
    .{
        .name = "unpaired high surrogate",
        .text = "\"\\ud83d\"",
        .verdict = .both_reject,
        .why = "a surrogate is half a pair",
    },
    .{
        .name = "unpaired low surrogate",
        .text = "\"\\udc00\"",
        .verdict = .both_reject,
        .why = "and a low half cannot start one",
    },
    .{
        .name = "undefined escape",
        .text = "\"\\x\"",
        .verdict = .both_reject,
        .why = "JSON defines eight escapes and a \\u",
    },
    .{
        .name = "truncated literal",
        .text = "tru",
        .verdict = .both_reject,
        .why = "there is no true",
    },
    .{
        .name = "leading plus",
        .text = "+1",
        .verdict = .both_reject,
        .why = "a number has no sign character here",
    },
    .{
        .name = "no integer part",
        .text = ".5",
        .verdict = .both_reject,
        .why = "a fraction needs a digit before the point",
    },
    .{
        .name = "no fraction digits",
        .text = "1.",
        .verdict = .both_reject,
        .why = "and a digit after it",
    },
    .{
        .name = "no exponent digits",
        .text = "1e",
        .verdict = .both_reject,
        .why = "an exponent marker needs a digit",
    },
    .{
        .name = "no digits",
        .text = "-",
        .verdict = .both_reject,
        .why = "a minus sign is not a number",
    },
    .{
        .name = "invalid utf-8",
        .text = "\"\xff\"",
        .verdict = .both_reject,
        .why = "0xff cannot appear in UTF-8",
    },
};

/// Bytes that can never continue one value into another.
///
/// `}` and `]` are excluded deliberately: a streaming scanner reads a stray one
/// as a container close, so the two parsers would differ on whether the
/// container it closes is well formed, which is a different question from the
/// one this family asks.
const suffix_bytes = [_]u8{ '{', '[', ':', '"' };

fn isDigitByte(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

/// Bytes that can stand immediately before the integer part of a number.
///
/// A number starts the document or follows one of these, so a `0` behind one
/// of them and in front of a digit is the only `0` that begins a number. `-` is
/// here because a sign opens the number rather than the integer part, so `-01`
/// is the same fault one byte in. `.`, `e` and `E` are deliberately absent: they
/// continue a number already under way, which is why `1.02` and `1e0` are
/// numbers and not leading zeros.
const number_start_bytes = " \t\n\r:,[-";

/// True when some number in the document carries a leading zero.
///
/// RFC 8259 forbids the second digit, and `Reader.number` counts digits without
/// refusing one, so this is the one document shape on which the two parsers may
/// legitimately differ, and always in the same direction: the borrow reader
/// accepts and `std.json` refuses. `divergence_cases` records it three times
/// over, as a value, as a member and as an id; this is the rule that lets a
/// generated document carry the same disagreement instead of failing on it. Any
/// other disagreement is a finding, and the loop that calls this reports it.
fn hasLeadingZero(input: []const u8) bool {
    var pos: usize = 0;
    while (pos < input.len) {
        const byte = input[pos];
        if (byte == '"') {
            // Step over the body rather than the delimiter, because a `\` covers
            // the byte after it and an escaped quote closes nothing.
            pos += 1;
            while (pos < input.len) : (pos += 1) {
                if (input[pos] == '\\') {
                    pos += 1;
                } else if (input[pos] == '"') {
                    break;
                }
            }
            pos += 1;
            continue;
        }
        if (byte == '0' and pos + 1 < input.len and isDigitByte(input[pos + 1])) {
            const opens = pos == 0 or
                std.mem.indexOfScalar(u8, number_start_bytes, input[pos - 1]) != null;
            if (opens) return true;
        }
        pos += 1;
    }
    return false;
}

test "the disagreement rule names the recorded leading zero and nothing else" {
    const testing = std.testing;
    // The rule decides whether a generated disagreement is the recorded one or
    // a finding, so it has to be blind to a zero that is not leading and awake
    // to one that is. Each recorded `borrow_only` case names a document this
    // rule must accept, which is what ties it to the table rather than to a
    // reading of the grammar.
    for (divergence_cases) |case| {
        if (case.verdict == .borrow_only) {
            try testing.expect(hasLeadingZero(case.text));
        }
    }

    try testing.expect(hasLeadingZero("01"));
    try testing.expect(hasLeadingZero("-01"));
    try testing.expect(hasLeadingZero("{\"id\":-01}"));
    try testing.expect(hasLeadingZero("00.5"));
    try testing.expect(hasLeadingZero("{\"a\":[01]}"));
    // A zero that is not leading is not this fault. `102` is a number and
    // `1.02` is a number, and both parsers take them.
    try testing.expect(!hasLeadingZero("0"));
    try testing.expect(!hasLeadingZero("10"));
    try testing.expect(!hasLeadingZero("102"));
    try testing.expect(!hasLeadingZero("1.02"));
    try testing.expect(!hasLeadingZero("0.5"));
    // A zero in the fraction or the exponent continues a number under way, so
    // it is the second digit of that number and not the first of another.
    try testing.expect(!hasLeadingZero("1e0"));
    try testing.expect(!hasLeadingZero("1E+0"));
    try testing.expect(!hasLeadingZero("{\"a\":1.02}"));
    try testing.expect(!hasLeadingZero("-"));
    // Text is not a number, so a zero inside a string is a character.
    try testing.expect(!hasLeadingZero("\"01\""));
    // An escaped quote does not close the string it is in.
    try testing.expect(!hasLeadingZero("\"a\\\"01\" 12"));
}

test "the borrow reader and std.json agree on the hand-written corpus" {
    const testing = std.testing;
    var scratch: [max_doc_len]u8 = undefined;
    var text: [1024]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scoped = arena.allocator();

    for (divergence_cases) |case| {
        const mine = borrowAccepts(case.text, &scratch);
        const theirs = try referenceAccepts(scoped, case.text);
        const want_mine = case.verdict == .both_accept or case.verdict == .borrow_only;
        const want_theirs = case.verdict == .both_accept or case.verdict == .reference_only;
        if (mine != want_mine or theirs != want_theirs) {
            std.debug.print(
                "\ndifferential: '{s}' no longer matches its recorded verdict\n" ++
                    "  document:     {s}\n  borrow reader: {s}\n  std.json:      {s}\n" ++
                    "  recorded:     {s}\n  why:          {s}\n",
                .{
                    case.name,
                    escaped(case.text, &text),
                    if (mine) "accept" else "reject",
                    if (theirs) "accept" else "reject",
                    @tagName(case.verdict),
                    case.why,
                },
            );
            return error.DifferentialVerdictChanged;
        }
        // Where both accept they must also agree on what kind of value it is,
        // or one of them is reading a different document.
        if (mine) {
            try testing.expectEqual(
                borrowKind(case.text),
                try referenceKind(scoped, case.text),
            );
        }
    }
}

test "the borrow reader refuses nesting past its own bound" {
    // The one divergence that is a policy rather than a grammar difference:
    // `json.max_depth` exists so that a peer sending `[[[[...` forever gets
    // `error.LimitExceeded` rather than a stack overflow, and `std.json` grows
    // its own stack instead. A document inside the bound must still be
    // accepted, or the bound has quietly moved.
    const testing = std.testing;
    const inside = json.max_depth;
    const outside = json.max_depth + 32;
    var scratch: [2 * outside + 8]u8 = undefined;

    var shallow: [2 * inside]u8 = undefined;
    for (0..inside) |index| shallow[index] = '[';
    for (0..inside) |index| shallow[inside + index] = ']';
    try testing.expect(borrowAccepts(shallow[0..], scratch[0..]));

    var deep: [2 * outside]u8 = undefined;
    for (0..outside) |index| deep[index] = '[';
    for (0..outside) |index| deep[outside + index] = ']';
    try testing.expect(!borrowAccepts(deep[0..], scratch[0..]));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The reference parser has no such bound, which is the whole reason this
    // library has one.
    try testing.expect(try referenceAccepts(arena.allocator(), deep[0..]));
    try testing.expect(try referenceAccepts(arena.allocator(), shallow[0..]));
}

test "the borrow reader and std.json agree on generated documents" {
    const testing = std.testing;
    std.debug.print(
        "\ndifferential: seed=0x{X} iterations={d}\n",
        .{ seed, iterations },
    );

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var doc: Doc = .{};
    var splice: Doc = .{};
    var tail: Doc = .{};
    var scratch: [max_doc_len]u8 = undefined;
    var text: [2 * max_doc_len + 8]u8 = undefined;
    var per_shape = [_]usize{0} ** shapes.len;
    var accepted: usize = 0;
    var leading_zero: usize = 0;
    var prefixes: usize = 0;
    var suffixes: usize = 0;

    // One arena for the whole run, reset after each document. The reference
    // parser allocates a nesting stack per call, and going through the testing
    // allocator that many times would measure the allocator rather than the two
    // parsers; the arena keeps the leak check on the one block that outlives
    // the loop.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scoped = arena.allocator();

    // The whole corpus, not only the documents both parsers must accept. These
    // are the shapes the property harness walks over the same seed, so the run
    // that checks totality and the run that compares parsers see one document
    // stream between them.
    for (0..iterations) |index| {
        writeShape(rng, &doc, &splice, index);
        const bytes = doc.slice();
        if (bytes.len == 0) continue;
        per_shape[@as(usize, @intFromEnum(shapes[index % shapes.len]))] += 1;

        const mine = borrowAccepts(bytes, &scratch);
        const theirs = try referenceAccepts(scoped, bytes);
        if (mine != theirs) {
            // The one disagreement the corpus records, in the direction
            // `divergence_cases` gives it: the borrow reader counts the digits
            // of a leading zero and `std.json` refuses the number. Every other
            // disagreement is a finding, so it is reported rather than
            // absorbed, and the direction has to be the recorded one.
            if (mine and !theirs and hasLeadingZero(bytes)) {
                leading_zero += 1;
            } else {
                std.debug.print(
                    "\ndifferential: a generated document disagrees\n" ++
                        "  document:     {s}\n  borrow reader: {s}\n" ++
                        "  std.json:      {s}\n  leading zero: {}\n",
                    .{
                        escaped(bytes, &text),
                        if (mine) "accept" else "reject",
                        if (theirs) "accept" else "reject",
                        hasLeadingZero(bytes),
                    },
                );
                return error.DifferentialDisagreement;
            }
        }

        // The reference parser is only asked what it is when it read the whole
        // document. A document it refuses has no classification to give.
        if (mine and theirs) {
            accepted += 1;
            try testing.expectEqual(borrowKind(bytes), try referenceKind(scoped, bytes));

            // A proper prefix of a value that has a mandatory terminator byte is
            // not a document. A reader that stopped at the first closing brace
            // would accept one, and a transport built on it would read a frame
            // that was never sent. A number is the exception: it has no
            // terminator, so `1.5` is a number in its own right and also a
            // prefix of `1.5e-3`.
            //
            // The prefix is cut from the significant bytes. Trailing whitespace
            // is not part of the value, so `{"a":1} ` has a proper prefix that
            // is the whole document, and a mutation that appends a space would
            // report the harness's own padding instead of a reader fault.
            const significant = std.mem.trimEnd(u8, bytes, whitespace[0..]);
            if (borrowKind(significant) != .number) {
                for (0..3) |_| {
                    if (significant.len < 2) break;
                    const prefix_len = rng.intRangeLessThan(usize, 1, significant.len);
                    const prefix = significant[0..prefix_len];
                    const mine_prefix = borrowAccepts(prefix, &scratch);
                    const theirs_prefix = try referenceAccepts(scoped, prefix);
                    if (mine_prefix or theirs_prefix) {
                        std.debug.print(
                            "\ndifferential: a proper prefix was accepted\n" ++
                                "  prefix:       {s}\n  borrow reader: {s}\n" ++
                                "  std.json:      {s}\n",
                            .{
                                escaped(prefix, &text),
                                if (mine_prefix) "accept" else "reject",
                                if (theirs_prefix) "accept" else "reject",
                            },
                        );
                        return error.DifferentialPrefixAccepted;
                    }
                    prefixes += 1;
                }
            }
        }

        // A value cannot be followed by a value, so a document followed by a
        // structural byte is two documents rather than one.
        //
        // The base has to be a document both readers read, because a hostile
        // or mutated one can stop part way through a value and a byte appended
        // to that completes it rather than contradicting it: `"tt9` plus a
        // quote is the document `"tt9"`, which both readers accept, and the
        // check would be reporting a document that was never malformed. Once
        // the base is a complete value, every byte in `suffix_bytes` is
        // illegal after it, so the document is provably two. The base also
        // has to leave room for the byte, or the append is a no-op and the
        // check would be testing the document against itself.
        if (mine and theirs and bytes.len < max_doc_len) {
            const suffix = suffix_bytes[rng.intRangeLessThan(u8, 0, suffix_bytes.len)];
            tail.clear();
            tail.push(bytes);
            tail.pushByte(suffix);
            const two = tail.slice();
            const mine_two = borrowAccepts(two, &scratch);
            const theirs_two = try referenceAccepts(scoped, two);
            if (mine_two or theirs_two) {
                std.debug.print(
                    "\ndifferential: a trailing structural byte was accepted\n" ++
                        "  document:     {s}\n  appended:     0x{X}\n" ++
                        "  borrow reader: {s}\n  std.json:      {s}\n",
                    .{
                        escaped(bytes, &text),
                        suffix,
                        if (mine_two) "accept" else "reject",
                        if (theirs_two) "accept" else "reject",
                    },
                );
                return error.DifferentialSuffixAccepted;
            }
            suffixes += 1;
        }

        _ = arena.reset(.retain_capacity);
    }

    std.debug.print(
        "  accepted={d} leading-zero divergences={d} proper prefixes rejected={d}" ++
            " trailing bytes rejected={d}\n",
        .{ accepted, leading_zero, prefixes, suffixes },
    );
    for (shapes, per_shape) |shape, count| {
        std.debug.print("  {s}: {d} documents\n", .{ @tagName(shape), count });
    }
    try testing.expect(accepted != 0);
    try testing.expect(prefixes != 0);
    try testing.expect(suffixes != 0);
    // A run long enough to have drawn a leading zero must have seen one: a
    // fifth of the corpus is hostile bytes, a third of that alphabet is digits,
    // and a leading zero is the only disagreement the recorded cases name. A
    // short run says nothing either way, so it asserts nothing.
    if (iterations >= 1000) try testing.expect(leading_zero != 0);
}
