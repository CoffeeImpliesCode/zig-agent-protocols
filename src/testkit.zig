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
//! - **Round-trip stability, in bytes.** The two `bridge` encoders are the
//!   ones whose output this harness compares byte for byte against a
//!   prediction rather than member by member: the bytes the *input* says each
//!   of them owes are predicted from that input, and the prediction is
//!   compared against what the encoder wrote. One more comparison sits in the
//!   same family and is the exception rather than the rule:
//!   [`roundTripA2aEmpty`] compares `a2a.encodeEmpty` against `{}`, which is
//!   the canonical form of every document `a2a.decodeEmpty` accepts, so the
//!   twenty `a2a` codecs are one byte comparison and nineteen member
//!   comparisons. A comparison of decoded members is blind to a member the
//!   encoder dropped: a decoder that accepted an ACP carrier `_meta` beside a
//!   result, and an encoder that wrote no `_meta` back, left a value whose
//!   members still compared equal, so `encode(decode(b)) != b` went unnoticed
//!   for the life of the repository. The expected bytes are never read back
//!   off a decoder, since a check whose two sides come from one walk is the
//!   same check with more steps. The comparison is against the canonical form
//!   and not against `b` itself: member order and insignificant whitespace are
//!   two ways a document can differ without losing anything, and a harness
//!   that failed on legal input would be a harness people turn off. A member
//!   the schema does not define is dropped by the encoder on purpose, so it is
//!   outside the prediction too, and the check covers exactly the members the
//!   protocol defines. A member the input spells twice is written once, from
//!   the first occurrence, because that is the one every decoder in this
//!   library keeps; the prediction applies the same rule for the same reason,
//!   and `test "the prediction and the decoder resolve a repeated member the
//!   same way"` fails in either direction the two ever part company.
//!   Re-decoding into the buffer the first decode wrote into would compare
//!   memory the second decode has already overwritten, which is how this kind
//!   of test passes for the wrong reason.
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
//!   carries every member name a decoder this harness feeds branches on, and a
//!   name no seed spells is accounted for by name in
//!   [`grammar_only_names`]: the grammar shape can write it as a key, but only
//!   the renamed shape can *move* one, so a name in the vocabulary and in no
//!   seed is reached by chance and a rule about it is asserted over a handful
//!   of documents in the whole run. One shape renames a member of a real
//!   message outright: a renamed `id` turns a request into a notification, and
//!   a renamed `jsonrpc` is a refusal.
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
//!   table gives it — and only when taking that difference *out* of the
//!   document leaves the two parsers agreeing, so a second and independent
//!   divergence behind the same leading zero is reported rather than
//!   absorbed. A whole document carrying a leading zero is not a whole
//!   document excused.
//! - **The A2A vocabulary comes from the A2A tables.** The twenty `a2a`
//!   codecs are table driven: every message carries a `fields` table of
//!   `{number, json, zig_name}` that `a2a.assertFieldTable` checks against the
//!   struct at comptime, and those tables are where the member names those
//!   decoders compare are written down. [`a2a_member_names`] reads them out of
//!   the tables instead of listing them again here, because a transcribed
//!   second copy is a second thing to keep correct and the codec is what the
//!   generator has to reach. A new A2A member is then a row in its own table
//!   and one seed document, and a renamed one changes neither file.
//! - **Base64 is a codec, and it is total too.** `json.base64` is not a JSON
//!   decoder, so no document reaches it and it cannot have a trailing-byte
//!   case. What it can take is bytes, and the corpus's own bytes are the most
//!   hostile input this harness owns: invalid UTF-8, a NUL and a `0xff` reach
//!   it on every run, at every length from zero to the document bound, in both
//!   RFC 4648 alphabets rather than only the standard one.
//! - **A decoder nobody reached is a decoder nobody checked.** Being in the
//!   battery is not coverage: a decoder that accepts nothing has a
//!   trailing-byte assertion that never fires and a round trip that never
//!   runs, and both are green. [`battery_codec_names`] lists every codec the
//!   battery hands something to, not only the ones this wave added, and
//!   [`expectEveryBatteryCodecReached`] fails a run that fed one of them
//!   nothing it takes, so "the corpus reaches it" is something the harness
//!   proves rather than something this file claims. A decoder that cannot be
//!   reached that way is named in [`tail_rule.unasserted`] with the reason it
//!   is there instead of being left out quietly, and that list is the complete
//!   one: a field naming two of twenty-nine was worse than no field at all.
//! - **A name the current revision removed still resolves at the previous
//!   one.** `mcp.lookupMethod` takes the revision, and the three `2026-07-28`
//!   removed were ordinary client-to-server requests at `2025-11-25`. The
//!   corpus feeds the registry a name cut out of the document, which reaches
//!   `.previous` and never reaches those three, so the rule carries a test of
//!   its own rather than resting on the registry feed.
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
const a2a = proto.a2a;
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
/// bodies is weight.
///
/// This is the hand-written half and it is not where a decoder's own table
/// goes. The twenty `a2a` codecs publish the members they compare as a `fields`
/// table beside every message, and [`a2a_member_names`] derives the rest of the
/// vocabulary from those rather than copying them here, where a rename would
/// have to be made twice and one of the two copies would be the one nobody
/// reads. The two halves meet in [`vocabulary_member_names`], and `test "every
/// member name is in a seed or listed as grammar-only"` walks that rather than
/// this table alone.
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

/// The messages whose members the twenty A2A codecs compare.
///
/// One entry per message that has both a decoder and an encoder, and the list
/// is what makes the derivation below a statement about the codecs rather than
/// about every message `a2a.zig` declares: a message with no codec compares no
/// member, so its table would widen the vocabulary with names no rule reads.
/// Every `json` name in each of these twenty tables is compared by the decoder
/// for that message, which is why the derivation can be the whole of it.
const a2a_codec_messages = [_]type{
    a2a.Empty,
    a2a.GetTaskRequest,
    a2a.CancelTaskRequest,
    a2a.SubscribeToTaskRequest,
    a2a.GetTaskPushNotificationConfigRequest,
    a2a.DeleteTaskPushNotificationConfigRequest,
    a2a.ListTaskPushNotificationConfigsRequest,
    a2a.GetExtendedAgentCardRequest,
    a2a.ListTasksRequest,
    a2a.AuthenticationInfo,
    a2a.TaskPushNotificationConfig,
    a2a.SendMessageConfiguration,
    a2a.AgentInterface,
    a2a.AgentProvider,
    a2a.AgentCardSignature,
    a2a.AgentExtension,
    a2a.ApiKeySecurityScheme,
    a2a.HttpAuthSecurityScheme,
    a2a.OpenIdConnectSecurityScheme,
    a2a.MutualTlsSecurityScheme,
};

/// How many ProtoJSON rows those twenty tables hold before a repeat is dropped.
///
/// `tenant` is a member of nine of them and `id` of six, so this counts rows
/// rather than names. It sizes the one scratch array [`collectA2aMemberNames`]
/// needs to remember what it has already emitted.
const a2a_field_row_count = blk: {
    var rows: usize = 0;
    for (a2a_codec_messages) |T| {
        for (T.fields) |entry| {
            if (entry.json != null) rows += 1;
        }
    }
    break :blk rows;
};

/// Write the ProtoJSON names the twenty A2A codecs compare into `out` and
/// return how many there are.
///
/// The names come from the `fields` tables `a2a.zig` derives every Zig field
/// name from, so they cannot drift: a renamed member is a new row in that
/// table and nothing to change here. A name two tables carry contributes it
/// once, and a name [`member_names`] already carries is not repeated, so the
/// vocabulary stays a set rather than a tally of how many decoders branch on
/// each name.
fn collectA2aMemberNames(out: [][]const u8) usize {
    // The quota, for the same reason the reachability test below has one: this
    // runs at comptime because the two tables above are built from it, and it
    // compares every row of twenty tables against the whole hand-written table
    // and against everything it has already emitted.
    @setEvalBranchQuota(100_000);
    var seen: [member_names.len + a2a_field_row_count][]const u8 = undefined;
    var count: usize = 0;
    for (a2a_codec_messages) |T| {
        for (T.fields) |entry| {
            const name = entry.json orelse continue;
            var known = false;
            for (member_names) |existing| {
                if (std.mem.eql(u8, existing, name)) known = true;
            }
            for (seen[0..count]) |existing| {
                if (std.mem.eql(u8, existing, name)) known = true;
            }
            if (known) continue;
            seen[count] = name;
            out[count] = name;
            count += 1;
        }
    }
    return count;
}

/// How many names [`a2a_member_names`] holds, counted before it is built.
const a2a_member_name_count = blk: {
    var scratch: [member_names.len + a2a_field_row_count][]const u8 = undefined;
    break :blk collectA2aMemberNames(scratch[0..]);
};

/// The member names the twenty A2A codecs branch on, read out of their tables.
///
/// Derived rather than transcribed, for the reason in the module comment: the
/// table a decoder branches on and the table it is written from are then one
/// thing. Every name here is spelled by a seed in [`seed_documents`], which is
/// what lets a mutation move an A2A member as readily as it moves `id`; a name
/// only the grammar generator could produce would be reached by chance and a
/// rule about it would be asserted over a handful of documents in the whole
/// run. `test "every member name is in a seed or listed as grammar-only"` is
/// what keeps that promise honest, and it walks the derived table too.
const a2a_member_names: [a2a_member_name_count][]const u8 = blk: {
    var list: [a2a_member_name_count][]const u8 = undefined;
    const written = collectA2aMemberNames(list[0..]);
    if (written != a2a_member_name_count) @compileError("the two A2A name counts disagree");
    break :blk list;
};

/// Every member name the corpus can write as a key.
///
/// [`member_names`] is the hand-written half and [`a2a_member_names`] the
/// derived one, and the generator draws from both. A rename is only a rename if
/// its name is in here, so a decoder that branches on a member the rename shape
/// can never move is one whose key rules the corpus cannot reach.
const vocabulary_member_names = member_names ++ a2a_member_names;

/// Member names the grammar generator spells but no seed document carries.
///
/// `renameMember` moves a name a seed already contains, so a name here widens
/// what a mutation can produce as a key and nothing more.
///
/// `terminalId` is the ordinary case: no seed spells it, so there is nothing
/// for a mutation to move, and the subject it belongs to is a decoder branch
/// nothing else in the corpus reaches.
///
/// `_meta` was listed here too, on the grounds that a seed invented only so
/// the name could be renamed is a document no peer sends. Measured over the
/// default 20 000 documents, that left the carrier `_meta` of the two
/// `bridge` objects carried by 1 accepted envelope and 2 accepted outcomes.
/// One document in ten thousand is not coverage: a decoder may drop the
/// member on every run and the property harness never sees it. A seed spells
/// it now, and a listing that names something a seed spells is the stale
/// case `test "every member name is in a seed or listed as grammar-only"`
/// names.
const grammar_only_names = [_][]const u8{
    "terminalId",
};

/// Every string body the generator can write, key or value alike.
///
/// `writeObject` draws a member name from here too, so a key is not a special
/// case: the same table feeds both halves of a document.
const string_vocabulary = string_forms ++ vocabulary_member_names;

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
/// Three of them carry members no other seed spells, and they are here for the
/// decoder arms nothing else reaches: an MRTR interim result is the only
/// document `mcp.decodeInputRequiredResult` accepts, and a permission request
/// with a `toolCall` is the only document the stable arm of
/// `acp.decodePermissionRequest` accepts. Both are real messages at the pinned
/// revisions, so a mutation of either is a change to a real document. The
/// three after them carry a carrier `_meta`, and the comment among the seeds
/// says why that needed one.
///
/// The last fourteen are the A2A half, and they are the reason the twenty
/// `a2a` codecs are in the battery at all. A decoder the corpus only ever sees
/// through random keys is a decoder whose required-member rules are asserted
/// over a handful of documents in the whole run, and whose arms nothing else
/// reaches: `id` and `location` together are one draw in ten thousand, so
/// `decodeAgentProvider` and `decodeApiKeySecurityScheme` were never going to
/// accept anything at all. One real request per codec is both the coverage and
/// the reason every ProtoJSON name the twenty `fields` tables carry is spelled
/// here, which is what lets `a2a_member_names` be derived rather than listed as
/// grammar-only. Member sets come from `research/normative/a2a-1.0.0.md`; the
/// values are the ones a tenant-prefixed deployment sends.
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
    // The last three carry a carrier `_meta`, the one member of the two
    // `bridge` objects the encoders write back. They are appended rather than
    // inserted because the hand-written tests name seeds by index, and they
    // are real messages at the pinned revisions rather than documents invented
    // to reach a branch: `research/normative/acp-v1-v2.md` table 10b puts the
    // envelope `_meta` after `params` and table 10c puts the carrier `_meta`
    // after the outcome member, which is the order these three spell.
    "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\"},\"_meta\":{\"trace\":\"t\"}}",
    "{\"result\":{\"resultType\":\"complete\",\"content\":[]}," ++
        "\"_meta\":{\"trace\":\"t\"}}",
    "{\"error\":{\"code\":-32602,\"message\":\"bad\"}," ++
        "\"_meta\":{\"trace\":\"t\"}}",
    // A2A. `GetTaskRequest`, `SubscribeToTaskRequest` and
    // `GetExtendedAgentCardRequest` all accept the first of these, and the
    // push-notification configuration is the only seed carrying both `taskId`
    // and `id`, so the get and delete config requests accept it too.
    "{\"tenant\":\"acme\",\"id\":\"task-1\",\"historyLength\":10}",
    "{\"tenant\":\"acme\",\"id\":\"task-1\",\"metadata\":{\"reason\":\"user\"}}",
    "{\"taskId\":\"task-1\",\"pageSize\":50,\"pageToken\":\"tok\"," ++
        "\"tenant\":\"acme\"}",
    "{\"tenant\":\"acme\",\"contextId\":\"ctx-1\"," ++
        "\"status\":\"TASK_STATE_WORKING\",\"pageSize\":10," ++
        "\"pageToken\":\"tok\",\"historyLength\":5," ++
        "\"statusTimestampAfter\":\"2026-01-01T00:00:00Z\"," ++
        "\"includeArtifacts\":true}",
    "{\"scheme\":\"Bearer\",\"credentials\":\"secret\"}",
    "{\"tenant\":\"acme\",\"id\":\"cfg-1\",\"taskId\":\"task-1\"," ++
        "\"url\":\"https://example.com/hook\",\"token\":\"tok\"," ++
        "\"authentication\":{\"scheme\":\"Bearer\"," ++
        "\"credentials\":\"secret\"}}",
    "{\"acceptedOutputModes\":[\"text/plain\",\"application/json\"]," ++
        "\"taskPushNotificationConfig\":" ++
        "{\"url\":\"https://example.com/hook\"}," ++
        "\"historyLength\":3,\"returnImmediately\":false}",
    "{\"url\":\"https://example.com/agent\",\"protocolBinding\":\"JSONRPC\"," ++
        "\"tenant\":\"acme\",\"protocolVersion\":\"1.0\"}",
    "{\"url\":\"https://example.com\",\"organization\":\"Example Inc\"}",
    "{\"protected\":\"eyJhbGciOiJFUzI1NiJ9\"," ++
        "\"signature\":\"QFdk-_8\",\"header\":{\"kid\":\"key-1\"}}",
    "{\"uri\":\"https://example.com/ext\",\"description\":\"ext\"," ++
        "\"required\":true,\"params\":{\"k\":1}}",
    "{\"description\":\"d\",\"location\":\"header\",\"name\":\"X-Api-Key\"}",
    "{\"description\":\"d\",\"scheme\":\"bearer\",\"bearerFormat\":\"JWT\"}",
    "{\"description\":\"d\",\"openIdConnectUrl\":" ++
        "\"https://example.com/.well-known/openid-configuration\"}",
    "{\"description\":\"d\"}",
    // The two ACP objects the trailing-byte work could name but not reach. Both
    // select their shape from a top-level `type` member, and no seed above
    // carries one, so `acp.decodeReplayFrom` and `acp.decodePermissionSubject`
    // saw a document they accept only when the grammar generator happened to
    // draw that key. These are the objects themselves: the `replayFrom` member
    // of a v2 `session/new` request, and the two `subject` arms the v2
    // permission request carries beside its options.
    "{\"type\":\"start\"}",
    "{\"type\":\"command\",\"command\":\"ls\",\"cwd\":\"/tmp\"}",
    "{\"type\":\"tool_call\",\"toolCall\":{\"toolCallId\":\"tc\"}}",
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

/// Where `name` sits in a table of names, or null when it is not in it.
///
/// `inline for` because the caller is a test body that walks comptime tables
/// with `inline for`, so the answer has to be available at comptime. A plain
/// loop would be a runtime function called from a comptime block, which the
/// compiler refuses. The optional is carried out of the loop rather than
/// returned from inside it for the same reason the other two comptime helpers
/// here are written the way they are.
fn nameIndex(comptime names: []const []const u8, name: []const u8) ?usize {
    @setEvalBranchQuota(100_000);
    var found: ?usize = null;
    inline for (names, 0..) |candidate, index| {
        if (found == null and std.mem.eql(u8, candidate, name)) found = index;
    }
    return found;
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
    // The whole vocabulary and not [`member_names`] alone: a rename of an A2A
    // member is the only mutation that turns a required member of one of the
    // twenty into a missing-field refusal, and drawing from the hand-written
    // half alone would never produce one.
    const from = vocabulary_member_names[rng.intRangeLessThan(usize, 0, vocabulary_member_names.len)];
    const to = vocabulary_member_names[rng.intRangeLessThan(usize, 0, vocabulary_member_names.len)];
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
    /// Two documents joined, which is wrong at exactly one seam.
    ///
    /// The head is a whole, undamated seed half the time and a mutated
    /// fragment the other half. Do not "simplify" this back to two damaged
    /// halves: two mutated halves almost never leave the first one decodable,
    /// so before the draw existed this shape produced no trailing-byte
    /// document any decoder would accept, and every decoder in
    /// [`tail_rule`] swallowed the tail on every run without the harness
    /// noticing. The draw is the only source of those documents, and the
    /// damage both halves used to take is still here.
    ///
    /// Measured on the default seed over 20 000 documents, with the decoders
    /// in [`tail_rule`] left lenient so the count is of what they would have
    /// accepted: 3388 documents were one value and then more, 279 of those
    /// were accepted by `bridge.decodeOutcome` on its `result` arm and 250 on
    /// its `error` arm. The two arms are both reached, which is what makes an
    /// `atEnd` check misplaced inside the `error` arm's lexeme capture a
    /// failure rather than a pass.
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
            if (rng.boolean()) {
                doc.push(seed_documents[rng.intRangeLessThan(usize, 0, seed_documents.len)]);
            } else {
                writeMutated(rng, doc);
            }
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

/// Whether `input` holds one complete value and then bytes that are not part
/// of it.
///
/// The other question from [`borrowAccepts`], and a decoder given this input
/// has to refuse it: the value is a document, the rest is not inside it, and
/// there is nowhere in an object to put those bytes, so no encoder could ever
/// write them back. A decoder that accepts the document anyway drops them, and
/// nothing downstream reports the loss, because the members it does keep are
/// all correct.
fn hasTail(input: []const u8, scratch: []u8) bool {
    var reader = json.Reader.init(input);
    reader.skipValue(scratch) catch return false;
    return !reader.atEnd();
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

// --- The bytes an encoder owes -------------------------------------------------

/// Write one member of a canonical object, separator included.
///
/// A member the decoder decoded and the encoder re-escaped comes back through
/// `string`, and one the encoder splices comes back as it stood. The two are
/// different rules and are named separately rather than behind a flag,
/// because a prediction that re-escaped a spliced value would disagree with
/// the encoder over a document both handled correctly.
fn writeCanonicalTextMember(
    name: []const u8,
    text: []const u8,
    separator: []const u8,
    writer: *json.Writer,
) !void {
    try writer.slice(separator);
    try writer.slice("\"");
    try writer.slice(name);
    try writer.slice("\":");
    try writer.string(text);
}

/// The same member, spliced.
fn writeCanonicalRawMember(
    name: []const u8,
    text: []const u8,
    separator: []const u8,
    writer: *json.Writer,
) !void {
    try writer.slice(separator);
    try writer.slice("\"");
    try writer.slice(name);
    try writer.slice("\":");
    try writer.slice(text);
}

/// Write the exact bytes `bridge.encodeEnvelope` owes for the document `raw`.
///
/// The prediction is built from the input alone, and that is the whole reason
/// the round trip compares bytes. A comparison of the members a decoder
/// returned cannot see a member the encoder dropped, which is how a carrier
/// `_meta` was accepted and then lost without the harness noticing; a
/// prediction read back off the decoder's own output would be that same
/// comparison with more steps. Here the only thing either side is allowed to
/// know is `raw`.
///
/// The prediction differs from the input in exactly the two ways a JSON
/// document may without losing anything: insignificant whitespace goes, and
/// the members come out in the order table 10b lists them. Every member that
/// table defines is written whenever the input carried one, and a member the
/// input spelled more than once is written once, from the *first* occurrence,
/// because that is the one `bridge.decodeEnvelope` keeps. A member the table
/// does not define is written by neither side.
///
/// First-wins is not a choice this walk makes. It is the rule `bridge`, and
/// every other member walk in this library, applies, so a prediction that
/// resolved a repeat the other way would disagree with the encoder over a
/// document both handle correctly — and a prediction pinned to the wrong rule
/// makes the byte comparison evidence for that rule rather than against it.
fn writeCanonicalEnvelope(
    raw: []const u8,
    scratch: []u8,
    writer: *json.Writer,
) !void {
    var reader = json.Reader.init(raw);
    var server: ?[]const u8 = null;
    var request: ?[]const u8 = null;
    var method: ?[]const u8 = null;
    var params: ?[]const u8 = null;
    var meta: ?[]const u8 = null;
    // The five guards below are the decoder's own five, in the same order and
    // for the same reason, so a repeated member is spent here exactly as it is
    // spent in `decodeEnvelope`.
    var saw_server = false;
    var saw_request = false;
    var saw_method = false;
    var saw_params = false;
    var saw_meta = false;

    // An object with no member is not an envelope, so a caller that decoded
    // one never reaches this branch. Refusing rather than defaulting keeps a
    // future caller from predicting `{}` for a document nothing accepts.
    if (try reader.beginObject()) return error.MissingMember;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "serverId")) {
            if (saw_server) {
                try reader.skipValue(scratch);
            } else {
                server = try reader.string(scratch);
                saw_server = true;
            }
        } else if (std.mem.eql(u8, key, "requestId")) {
            if (saw_request) {
                try reader.skipValue(scratch);
            } else {
                request = try reader.string(scratch);
                saw_request = true;
            }
        } else if (std.mem.eql(u8, key, "method")) {
            if (saw_method) {
                try reader.skipValue(scratch);
            } else {
                method = try reader.string(scratch);
                saw_method = true;
            }
        } else if (std.mem.eql(u8, key, "params")) {
            const value = try reader.rawValue(scratch);
            if (!saw_params) {
                params = value;
                saw_params = true;
            }
        } else if (std.mem.eql(u8, key, "_meta")) {
            const value = try reader.rawValue(scratch);
            if (!saw_meta) {
                meta = value;
                saw_meta = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    var separator: []const u8 = "";
    try writer.byte('{');
    try writeCanonicalTextMember(
        "serverId",
        server orelse return error.MissingMember,
        separator,
        writer,
    );
    separator = ",";
    try writeCanonicalTextMember(
        "requestId",
        request orelse return error.MissingMember,
        separator,
        writer,
    );
    try writeCanonicalTextMember(
        "method",
        method orelse return error.MissingMember,
        separator,
        writer,
    );
    separator = ",";
    if (params) |value| try writeCanonicalRawMember("params", value, separator, writer);
    separator = ",";
    if (meta) |value| try writeCanonicalRawMember("_meta", value, separator, writer);
    try writer.byte('}');
}

/// Write the exact bytes `bridge.encodeOutcome` owes for the document `raw`.
///
/// The same two rules as the envelope, and neither arm is decoded and rebuilt:
/// a result carries whatever the MCP operation returned and an error object
/// arrives with its bytes already checked, so `encodeOutcome` splices both and
/// so does this. A document carrying both members is not an outcome and never
/// reaches the branch below, so which name is written is decided by the only
/// one the input had. A member the input spelled twice is read from the first
/// occurrence, because that is the one `bridge.decodeOutcome` keeps.
fn writeCanonicalOutcome(
    raw: []const u8,
    scratch: []u8,
    writer: *json.Writer,
) !void {
    var reader = json.Reader.init(raw);
    var is_error = false;
    var text: ?[]const u8 = null;
    var meta: ?[]const u8 = null;
    var saw_result = false;
    var saw_error = false;
    var saw_meta = false;

    if (try reader.beginObject()) return error.MissingMember;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "result")) {
            if (saw_result) {
                try reader.skipValue(scratch);
            } else {
                saw_result = true;
                text = try reader.rawValue(scratch);
            }
        } else if (std.mem.eql(u8, key, "error")) {
            if (saw_error) {
                try reader.skipValue(scratch);
            } else {
                saw_error = true;
                text = try reader.rawValue(scratch);
                is_error = true;
            }
        } else if (std.mem.eql(u8, key, "_meta")) {
            const value = try reader.rawValue(scratch);
            if (!saw_meta) {
                meta = value;
                saw_meta = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    try writer.byte('{');
    try writer.slice(if (is_error) "\"error\":" else "\"result\":");
    try writer.slice(text orelse return error.MissingMember);
    if (meta) |value| try writeCanonicalRawMember("_meta", value, ",", writer);
    try writer.byte('}');
}

/// Fail unless the encoder wrote the bytes the input says it owed.
///
/// The three renderings are separate buffers rather than one, because a
/// truncated diagnostic that names only the input is a failure nobody can
/// reproduce from a CI log, and reproducing it is the one job this message
/// has.
fn expectSameDocumentBytes(
    comptime what: []const u8,
    input: []const u8,
    expected: []const u8,
    encoded: []const u8,
) !void {
    if (std.mem.eql(u8, expected, encoded)) return;
    var was: [2 * max_doc_len + 8]u8 = undefined;
    var want: [2 * max_doc_len + 8]u8 = undefined;
    var got: [2 * max_doc_len + 8]u8 = undefined;
    std.debug.print(
        "\nround trip: the {s} encoder did not reproduce the document\n" ++
            "  input:    {s}\n  expected: {s}\n  encoded:  {s}\n",
        .{
            what,
            escaped(input, &was),
            escaped(expected, &want),
            escaped(encoded, &got),
        },
    );
    return error.RoundTripBytesDiffer;
}

/// The two ways a decoder can be named here, and why the split moved.
///
/// Ten decoders in the tree accepted a byte sequence that is one JSON value
/// and then more, and dropped the tail without saying so. Measured by running
/// each on a valid document and on that document plus `" trailing"`:
///
///   acp.zig:725   decodeReplayFrom
///   acp.zig:1042  decodeCapabilityObject
///   acp.zig:1098  decodeInitializeCapabilities
///   acp.zig:1179  decodePermissionOutcome
///   acp.zig:1284  decodePermissionSubject
///   acp.zig:1429  decodePermissionRequest
///   mcp.zig:1209  decodeResultType
///   mcp.zig:1259  decodeCacheable
///   mcp.zig:1336  decodeInputRequiredResult
///   mcp.zig:1388  decodeCacheLeg
///
/// `jsonrpc.decode` (jsonrpc.zig:274), its error object (jsonrpc.zig:552) and
/// the two session readers (acp_session.zig:235, mcp_session.zig:637) refuse
/// one, and `bridge` now does too (bridge.zig:184, bridge.zig:303). The twenty
/// `a2a` codecs never accepted one: each closes with a `reader.atEnd()` check
/// after its member loop, and the property run is what says so rather than the
/// reading.
///
/// This table used to have three halves' worth of meaning and now has two. The
/// five `acp` decoders that were fed nothing have been fed: `encodeReplayFrom`,
/// `encodeCapabilityObject`, `encodeInitializeCapabilities`,
/// `encodePermissionSubject` and `encodePermissionRequest` all landed, so
/// every one of the ten is in [`tail_rule.round_trip`] beside the two
/// `bridge` decoders, and the set of decoders this harness re-encodes no
/// longer has a member outside it. What is left is named in
/// [`tail_rule.unasserted`], and that list is the whole of what is left: every
/// row carries the reason it is there, and a decoder in neither half fails
/// the build rather than going unmentioned.
///
/// "Fed" is the operative word and it is not a claim about the code. A decoder
/// in the battery that accepts nothing has a trailing-byte assertion that never
/// fires and a round trip that never runs, and both are green, so
/// [`battery_codec_names`] is the list of every codec the battery hands
/// something to and [`expectEveryBatteryCodecReached`] fails the run if the
/// corpus never fed one of them a document it takes. A decoder that cannot be
/// reached that way belongs in [`tail_rule.unasserted`] and not in the battery,
/// which is what that field is for.
///
/// A decoder named in [`tail_rule.unasserted`] is named with a reason because
/// the reason is the only part a reader cannot work out. This list used to hold
/// two of the twenty-nine decoders the battery does not feed, which is worse
/// than holding none: a reader who trusted it would conclude that two lack
/// coverage, and the other twenty-seven would be missing from the statement
/// with nothing saying so. The field is the one place a coverage gap is
/// allowed to be recorded, so it records all of them.
const TailRule = struct {
    /// Decoders this harness re-encodes, so a tail they accept is a lost
    /// `encode(decode(b))`: `mcp.decodeResultType` and
    /// `mcp.decodeInputRequiredResult` through `mcp.encodeResultType` and
    /// `mcp.encodeInputRequiredResult`, the six `acp` ones and the two
    /// `bridge` ones through their own encoders, and the twenty `a2a` ones
    /// through the twenty `roundTripA2a*` writers.
    ///
    /// The byte comparison cannot see the loss for the ones without one, and
    /// that is worth being blunt about rather than dressing up: an encoder
    /// has nowhere inside an object to put the tail, so the prediction and
    /// the encoder agree on a document neither can reproduce. The decoder is
    /// the thing that is wrong, and the assertion is a refusal because a
    /// round trip cannot express what was thrown away. The two `bridge`
    /// decoders are the exception: for those the prediction is a document
    /// both sides can produce, so the tail is visible as a byte difference
    /// before it ever reaches the refusal.
    ///
    /// The twenty A2A names are the same twenty as
    /// [`a2a_codec_messages`] paired with their `decode` function, which is
    /// why none of them is in the round-trip half for a different reason than
    /// the rest: each has an encoder, and each encoder is called.
    round_trip: []const []const u8 = &.{
        "mcp.decodeResultType",
        "mcp.decodeInputRequiredResult",
        "acp.decodeReplayFrom",
        "acp.decodePermissionOutcome",
        "acp.decodePermissionSubject",
        "acp.decodePermissionRequest",
        "acp.decodeCapabilityObject",
        "acp.decodeInitializeCapabilities",
        "bridge.decodeEnvelope",
        "bridge.decodeOutcome",
        "a2a.decodeEmpty",
        "a2a.decodeGetTaskRequest",
        "a2a.decodeCancelTaskRequest",
        "a2a.decodeSubscribeToTaskRequest",
        "a2a.decodeGetTaskPushNotificationConfigRequest",
        "a2a.decodeDeleteTaskPushNotificationConfigRequest",
        "a2a.decodeListTaskPushNotificationConfigsRequest",
        "a2a.decodeGetExtendedAgentCardRequest",
        "a2a.decodeListTasksRequest",
        "a2a.decodeAuthenticationInfo",
        "a2a.decodeTaskPushNotificationConfig",
        "a2a.decodeSendMessageConfiguration",
        "a2a.decodeAgentInterface",
        "a2a.decodeAgentProvider",
        "a2a.decodeAgentCardSignature",
        "a2a.decodeAgentExtension",
        "a2a.decodeApiKeySecurityScheme",
        "a2a.decodeHttpAuthSecurityScheme",
        "a2a.decodeOpenIdConnectSecurityScheme",
        "a2a.decodeMutualTlsSecurityScheme",
    },

    /// Decoders this harness does not feed at all, so no assertion above would
    /// ever fire for them. Every one has a matching public encoder: what each
    /// is missing is a call site in [`exerciseEveryDecoder`] and the caller
    /// storage that call site needs, and both are spelled out per row.
    unasserted: []const UnfedDecoder = &.{
        .{ .name = "mcp.decodeCacheable", .why = "the cache members are on the input side of a retry, and no seed " ++
            "spells a result carrying them; `encodeCacheable` exists, so " ++
            "this is a missing corpus and nothing else" },
        .{ .name = "mcp.decodeCacheLeg", .why = "no encoder by design: a leg is derived from a caller's own " ++
            "`params` and there is nothing to write back, which " ++
            "mcp.zig:1705 states. What it still needs is a call in " ++
            "`exerciseEveryDecoder`" },
        .{ .name = "mcp.decodeHeaderValue", .why = "takes one header value rather than a document, so the call " ++
            "site would have to extract a member first. Every decoder " ++
            "in the battery is handed the document whole" },
        .{ .name = "mcp.decodePaginatedResult", .why = "needs a caller-sized `VerbatimStore` this harness sets up for " ++
            "no other decoder, and no seed spells a result carrying " ++
            "`nextCursor` beside a payload" },
        .{ .name = "mcp.decodeToolCallResult", .why = "the `tools/call` payload, and the one result type every seed " ++
            "names. It needs a caller-sized `ContentBlock` array and a " ++
            "`VerbatimStore` before it can be called at all" },
        .{ .name = "mcp.decodeToolListResult", .why = "needs a caller-sized `Tool` array and a `VerbatimStore`, and no " ++
            "seed spells a `tools` array inside a result" },
        .{ .name = "mcp.decodeResourceReadResult", .why = "needs a caller-sized `ResourceContents` array and a " ++
            "`VerbatimStore`, and no seed spells a `resources/read` " ++
            "payload" },
        .{ .name = "mcp.decodePromptsGetResult", .why = "needs a caller-sized `PromptMessage` array and a " ++
            "`VerbatimStore`, and no seed spells a `prompts/get` " ++
            "payload" },
        .{ .name = "mcp.decodeDiscoverResult", .why = "needs a caller-sized `[]const []const u8` and a " ++
            "`VerbatimStore`, and no seed spells a discover payload" },
        .{ .name = "jsonrpc.decodeRequest", .why = "the `Request` projection of the walk the battery already feeds " ++
            "through `jsonrpc.decode`, and nothing seeds a document it " ++
            "alone takes" },
        .{ .name = "a2a.decodePartContent", .why = "takes a caller-owned `ContentArena`, and sizing one is a " ++
            "decision rather than a line: five arrays the harness would " ++
            "have to bound against the document it is looking at" },
        .{ .name = "a2a.decodePart", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeMessage", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeArtifact", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeTaskStatus", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeTask", .why = "a caller-owned `ContentArena`, and the one walk it exists for: " ++
            "a task holds a status that may hold a message, and artifacts " ++
            "and history besides, so the arena bounds are the assertion" },
        .{ .name = "a2a.decodeTaskStatusUpdateEvent", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeTaskArtifactUpdateEvent", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeSendMessageRequest", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeSendMessageResponse", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeStreamResponse", .why = "a caller-owned `ContentArena`, as above" },
        .{ .name = "a2a.decodeAgentCard", .why = "a caller-owned `CardArena`, which is eight arrays rather than " ++
            "five, and the one card fixture the battery does have " ++
            "(`a2a_agent_card_signature.json`) names no required member" },
        .{ .name = "a2a.decodeAgentSkill", .why = "a caller-owned `CardArena`, as above" },
        .{ .name = "a2a.decodeAgentCapabilities", .why = "a caller-owned `CardArena`, as above" },
        .{ .name = "a2a.decodeSecurityRequirement", .why = "a caller-owned `CardArena`, as above" },
        .{ .name = "a2a.decodeSecurityScheme", .why = "a caller-owned `CardArena`, as above" },
        .{ .name = "a2a.decodeOAuthFlows", .why = "a caller-owned `CardArena`, as above" },
        .{ .name = "a2a.decodeOAuth2SecurityScheme", .why = "a caller-owned `CardArena`, as above" },
        .{ .name = "a2a.decodeStringList", .why = "a caller-owned `CardArena`, as above" },
    },
};

/// The two ways a decoder can be named here, as a value and not only as a
/// namespace.
///
/// A file-scope `const` bound to an anonymous struct is a *namespace* in
/// Zig: the name resolves to the type in an expression, so the two tables this
/// harness keeps in step could be written down and never read. Naming the
/// type and giving the value a name of its own is what lets the coverage test
/// compare them.
const tail_rule: TailRule = .{};

/// A decoder the harness does not feed, and why.
///
/// The reason is the point: a name without one is a gap a reader has to guess
/// at, and a gap that cannot be guessed at is the only kind worth recording.
const UnfedDecoder = struct {
    /// The public decoder, named exactly as its module spells it.
    name: []const u8,
    /// Why the battery does not feed it.
    why: []const u8,
};

/// Fail unless a decoder whose value is re-encoded refused a tailed input.
///
/// See [`tail_rule.round_trip`] for the set and for why a refusal is the only
/// shape this can take.
fn expectRoundTripHasNoTail(
    comptime what: []const u8,
    input: []const u8,
    tail: bool,
) !void {
    if (!tail) return;
    var text: [2 * max_doc_len + 8]u8 = undefined;
    std.debug.print(
        "\nround trip: {s} accepted a document with a tail\n  document: {s}\n",
        .{ what, escaped(input, &text) },
    );
    return error.DocumentHasTail;
}

/// Every codec the battery hands something to, in the order
/// [`Stats.reached_battery_codecs`] indexes them.
///
/// The first twenty-three are the ones this wave added: three `acp` decoders
/// the trailing-byte work named rather than asserted because they had no
/// encoder, then the twenty `a2a` codecs. The nine after them are the battery
/// decoders that predate the wave, and they are here for the same reason the
/// twenty-three are: a reachability guard that covers only the new ones leaves
/// the old ones undetectable, and a decoder that accepts nothing has a
/// trailing-byte assertion that never fires and a round trip that never runs.
/// Both are green, so both need something to say so.
///
/// `acp.decodePermissionRequest` appears once and is set from either version's
/// call site: the two arms are one decoder read at two revisions, and a corpus
/// that reached only the draft arm has still reached it. `acp.nextFrame` takes
/// bytes rather than a document, which is why it has a round trip and no
/// trailing-byte case, and `jsonrpc.decode` is here for the same reason the
/// rest is: it accepts something on almost every document, so a bit that
/// silently never turns on is the failure this table exists to prevent.
///
/// `test "the coverage tables agree on what the battery feeds"` is what keeps
/// this list, [`tail_rule.round_trip`] and [`tail_rule.unasserted`] from
/// disagreeing about it, which is the drift two of those tables recorded.
const battery_codec_names = [_][]const u8{
    "acp.decodeReplayFrom",
    "acp.decodePermissionSubject",
    "acp.decodeInitializeCapabilities",
    "a2a.decodeEmpty",
    "a2a.decodeGetTaskRequest",
    "a2a.decodeCancelTaskRequest",
    "a2a.decodeSubscribeToTaskRequest",
    "a2a.decodeGetTaskPushNotificationConfigRequest",
    "a2a.decodeDeleteTaskPushNotificationConfigRequest",
    "a2a.decodeListTaskPushNotificationConfigsRequest",
    "a2a.decodeGetExtendedAgentCardRequest",
    "a2a.decodeListTasksRequest",
    "a2a.decodeAuthenticationInfo",
    "a2a.decodeTaskPushNotificationConfig",
    "a2a.decodeSendMessageConfiguration",
    "a2a.decodeAgentInterface",
    "a2a.decodeAgentProvider",
    "a2a.decodeAgentCardSignature",
    "a2a.decodeAgentExtension",
    "a2a.decodeApiKeySecurityScheme",
    "a2a.decodeHttpAuthSecurityScheme",
    "a2a.decodeOpenIdConnectSecurityScheme",
    "a2a.decodeMutualTlsSecurityScheme",
    "jsonrpc.decode",
    "mcp.decodeResultType",
    "mcp.decodeInputRequiredResult",
    "acp.nextFrame",
    "acp.decodePermissionOutcome",
    "acp.decodeCapabilityObject",
    "acp.decodePermissionRequest",
    "bridge.decodeEnvelope",
    "bridge.decodeOutcome",
};

/// How many of [`battery_codec_names`] this wave added, which is where the
/// tail of the table above begins.
///
/// The split is here rather than written into the names because the test that
/// keeps the tables in step needs the two halves to differ: every name this
/// wave added is in [`tail_rule.round_trip`], and the nine after them are
/// named for the reachability guard rather than for the wave.
const wave_codec_count: usize = 23;

/// Record that one of the codecs in [`battery_codec_names`] accepted something.
///
/// The index is a comptime constant rather than a lookup by name, because a
/// lookup is a second place for the two lists to disagree and this table
/// exists to say a codec was reached rather than to say a call happened.
fn reachedBatteryCodec(stats: *Stats, comptime index: usize) void {
    stats.reached_battery_codecs[index] = true;
}

/// Fail unless the corpus reached every codec [`battery_codec_names`] names.
///
/// A short run says nothing either way, so it asserts nothing, for the same
/// reason the trailing-byte guard above is behind a length check.
fn expectEveryBatteryCodecReached(stats: *const Stats) !void {
    var unreached: ?[]const u8 = null;
    for (battery_codec_names, stats.reached_battery_codecs) |name, reached| {
        if (!reached and unreached == null) unreached = name;
    }
    if (unreached) |name| {
        std.debug.print(
            "\ncoverage: the corpus fed '{s}' nothing it accepts\n",
            .{name},
        );
        return error.CodecNeverReached;
    }
}

// --- Round trips ---------------------------------------------------------------

const Stats = struct {
    documents: usize = 0,
    accepted: usize = 0,
    refused: usize = 0,
    round_trips: usize = 0,
    /// Documents that were one value and then more. Not a printed line,
    /// because CI and the gate parse this block and this number is a
    /// liveness check for the assertion above rather than a result.
    tails: usize = 0,
    /// Which of [`battery_codec_names`] the corpus fed a document it accepts.
    ///
    /// A boolean and not a count, because the failure this exists to catch is
    /// a decoder that accepted nothing at all: its trailing-byte assertion and
    /// its round trip would both be green on every run without ever having
    /// run. One bit per decoder rather than one count for all of them, because
    /// a single total cannot say which one went missing.
    reached_battery_codecs: [battery_codec_names.len]bool =
        .{false} ** battery_codec_names.len,
    /// How many byte comparisons carried a carrier `_meta` through, per object.
    ///
    /// The carrier is the one member of the two `bridge` objects the encoders
    /// write back, and the loss it was carried to prevent was invisible for the
    /// life of the repository because the member-level comparison could not see
    /// it. The byte comparison can, but only over a document that carries one:
    /// three seeds spell a `_meta` so that the comparison runs on some, and a
    /// counter is what stops their removal from narrowing the run to documents
    /// with no carrier at all. One counter per object, because the envelope and
    /// the outcome are two decoders and either one could go quiet alone.
    envelope_meta_round_trips: usize = 0,
    outcome_meta_round_trips: usize = 0,
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

/// Encode the envelope, compare the bytes, then compare the members.
///
/// The two are separate properties and the first is the one that matters. The
/// byte comparison is what PROTOCOLS.md section 2 states, and it is the only
/// one that can see a member the encoder dropped, because a decoder that
/// never returned it cannot fail a comparison of its own output against
/// itself. The member comparison is narrower and is kept because it names the
/// member that went wrong instead of printing two escaped documents.
fn roundTripEnvelope(
    input: []const u8,
    envelope: bridge.Envelope,
    scratch: []u8,
    out: []u8,
    owed: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    // A decoded envelope carries three non-empty members, which is what
    // `encodeEnvelope` validates, so the only error left here is a harness
    // buffer that is too small, and returning it fails the test rather than
    // quietly skipping the round trip.
    try bridge.encodeEnvelope(envelope, &writer);

    // The prediction borrows `scratch` and is spent before the re-decode takes
    // the buffer, so one buffer serves both and the first decode's values are
    // still intact when the members are compared.
    var predicted = json.Writer.init(owed);
    try writeCanonicalEnvelope(input, scratch, &predicted);
    try expectSameDocumentBytes("envelope", input, predicted.written(), writer.written());
    // The count the `_meta` guard below reads. It is the comparison over a
    // document that carries a carrier, not the number of comparisons, because
    // a byte comparison over a document with no carrier says nothing about the
    // member the carrier exists to keep.
    if (envelope.meta != null) stats.envelope_meta_round_trips += 1;

    // The outer id is not a member of the params object, so the re-decode
    // cannot be told the direction and reports the notification.
    const again = try bridge.decodeEnvelope(writer.written(), scratch, null);
    try testing.expectEqualStrings(envelope.server_id, again.server_id);
    try testing.expectEqualStrings(envelope.request_id, again.request_id);
    try testing.expectEqualStrings(envelope.inner_method, again.inner_method);
    try expectSameString(envelope.inner_params, again.inner_params);
    try expectSameString(envelope.meta, again.meta);
    stats.round_trips += 1;
}

/// Encode the outcome, compare the bytes, then compare the members.
///
/// The byte comparison is the whole reason this is worth doing. The check
/// this replaces read the borrowed payload back through a fresh reader and
/// stopped there, and a decoder that dropped the carrier `_meta` satisfied it
/// as completely as one that kept it: the payload was intact either way, so
/// the loss the carrier field was added to prevent was invisible on every run.
fn roundTripOutcome(
    input: []const u8,
    outcome: bridge.Outcome,
    scratch: []u8,
    out: []u8,
    owed: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    const payload = switch (outcome) {
        .result => |arm| arm,
        .@"error" => |arm| arm,
    };
    // Both halves are borrowed lexemes, so both must still be complete values
    // to a reader that has not seen this one.
    if (!borrowAccepts(payload.text, scratch)) return error.BorrowedValueTruncated;
    if (payload.meta) |meta| {
        if (!borrowAccepts(meta, scratch)) return error.BorrowedValueTruncated;
    }

    var writer = json.Writer.init(out);
    // The payload came from `decodeOutcome`, which has already checked it
    // against the shape its arm requires, and both it and the carrier are
    // spliced rather than rebuilt, so the only failure left is a harness
    // buffer that is too small.
    try bridge.encodeOutcome(outcome, &writer);

    var predicted = json.Writer.init(owed);
    try writeCanonicalOutcome(input, scratch, &predicted);
    try expectSameDocumentBytes("outcome", input, predicted.written(), writer.written());
    // The same count for the other object. The carrier `_meta` is the member
    // this whole check was rebuilt for, and a run that compared bytes over
    // documents with no carrier would be green whatever the encoder did with
    // one.
    if (payload.meta != null) stats.outcome_meta_round_trips += 1;

    const again = try bridge.decodeOutcome(writer.written(), scratch);
    // The arm is the byte comparison's business as well, since the prediction
    // writes the name the input carried, and one line here is what names it.
    try testing.expect(std.meta.activeTag(again) == std.meta.activeTag(outcome));
    const other = switch (again) {
        .result => |arm| arm,
        .@"error" => |arm| arm,
    };
    try testing.expectEqualStrings(payload.text, other.text);
    try expectSameString(payload.meta, other.meta);
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

/// Re-encode a `ResultType` with the library's own encoder.
///
/// The encoder is the point. A hand-rolled writer beside `decodeResultType` is
/// a second implementation of a document the library already knows how to
/// write, and a round trip through it can only ever prove
/// `decode(encode_harness(x)) == x`: a renamed member, a lost comma or a
/// dropped validation inside `mcp.encodeResultType` would leave every run
/// green. The two writers this file used to carry are gone, and the assertion
/// that replaced them is that the shipped encoder is the one being exercised.
fn roundTripResultType(
    result: mcp.ResultType,
    scratch: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    // `encodeResultType` writes no member a decoder could not have returned,
    // so the only refusal left is a harness buffer that is too small, and
    // returning it fails the run rather than quietly skipping the round trip.
    try mcp.encodeResultType(result, &writer);
    try expectSameString(
        result.value,
        (try mcp.decodeResultType(writer.written(), scratch)).value,
    );
    stats.round_trips += 1;
}

/// Re-encode an `InputRequiredResult` with the library's own encoder.
///
/// The same reason as [`roundTripResultType`], and one more: the hand-rolled
/// writer spliced `inputRequests` with no check, so the harness was building
/// documents `mcp.encodeInputRequiredResult` refuses outright. A round trip
/// that manufactures its own input is not evidence about the shipped pair.
fn roundTripInputRequiredResult(
    result: mcp.InputRequiredResult,
    scratch: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    // The separator belongs in front of every member after the first rather
    // than baked into each one, because `resultType` is optional, and that is
    // now the encoder's problem rather than the harness's.
    try mcp.encodeInputRequiredResult(result, &writer);
    const again = try mcp.decodeInputRequiredResult(writer.written(), scratch);
    try expectSameString(result.result_type.value, again.result_type.value);
    try expectSameString(result.input_requests, again.input_requests);
    try expectSameString(result.request_state, again.request_state);
    stats.round_trips += 1;
}

// --- The ACP encoders that arrived after the battery -----------------------------
//
// Five `acp` decoders had no encoder when the trailing-byte work named them, so
// they were named rather than asserted. Each has one now, and each is
// re-encoded below. The pair that takes `(version, side)` ahead of the value
// takes them here too: the version is what picks the member name and the
// boolean-versus-presence-object split, so it is an input to the encoding and
// not a detail of it.

/// Compare a decoded capability set with the one its encoder was given.
///
/// The entries are compared one at a time and not as a slice: `Capability` has
/// a slice in it, so no single equality would say what this says, and a
/// whole-set comparison would pass on two sets differing in one path.
fn expectCapabilityEntries(
    first: []const acp.Capability,
    second: []const acp.Capability,
) !void {
    const testing = std.testing;
    try testing.expectEqual(first.len, second.len);
    for (first, second) |one, other| {
        try expectSameString(one.path, other.path);
        try testing.expectEqual(one.form, other.form);
        // `known` is derived from the path and the version rather than carried
        // on the wire, and `encodeCapabilityObject` reads it back off the path
        // rather than writing it, so a decoder that derived it differently from
        // the encoder shows here and nowhere else.
        try testing.expectEqual(one.known, other.known);
        // `value` is read through `advertised` rather than compared directly,
        // because the two forms carry it differently: a presence object has
        // none and a boolean has one, and the pair is only comparable once
        // each has been reduced to what it advertises.
        try testing.expectEqual(one.advertised(), other.advertised());
    }
}

fn roundTripCapabilityObject(
    version: acp.WireVersion,
    side: acp.Side,
    set: acp.CapabilitySet,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try acp.encodeCapabilityObject(version, side, set, &writer);

    // The paths are built in the caller's buffer and the encoder only reads
    // them, so the re-decode takes a second pair: sharing one would overwrite
    // the entries being compared and make the comparison a copy of itself.
    var entries: [32]acp.Capability = undefined;
    var paths: [512]u8 = undefined;
    const again = try acp.decodeCapabilityObject(
        version,
        side,
        writer.written(),
        &entries,
        &paths,
        replay,
    );
    // An empty object is a peer that advertised nothing, which is a fact and
    // not an error, so the encoder has to have kept the member present rather
    // than dropped it for `{}`.
    try testing.expect(again.present);
    try expectCapabilityEntries(set.entries, again.entries);
    stats.round_trips += 1;
}

fn roundTripInitializeCapabilities(
    version: acp.WireVersion,
    side: acp.Side,
    set: acp.CapabilitySet,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try acp.encodeInitializeCapabilities(version, side, set, &writer);

    var entries: [32]acp.Capability = undefined;
    var paths: [512]u8 = undefined;
    const again = try acp.decodeInitializeCapabilities(
        version,
        side,
        writer.written(),
        &entries,
        &paths,
        replay,
    );
    // Presence is the half of the value this has to pin. Omission and an empty
    // member are different documents, and the decoder reads them back as
    // `present = false` and `present = true` respectively, so an encoder that
    // swapped them would pass a comparison of the entries alone.
    try testing.expectEqual(set.present, again.present);
    try expectCapabilityEntries(set.entries, again.entries);
    stats.round_trips += 1;
}

fn roundTripReplayFrom(
    value: acp.ReplayFrom,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try acp.encodeReplayFrom(value, &writer);
    const again = try acp.decodeReplayFrom(writer.written(), replay);
    switch (value) {
        // The one named tag is the `.start` arm, and the catch-all refuses to
        // spell it, so a `.start` can only come back as a `.start`.
        .start => try testing.expect(again == .start),
        .other => |tag| switch (again) {
            .other => |other| try testing.expectEqualStrings(tag, other),
            .start => return error.TestUnexpectedResult,
        },
    }
    stats.round_trips += 1;
}

/// Compare two decoded permission subjects, arm by arm.
fn expectPermissionSubject(
    first: acp.PermissionSubject,
    second: acp.PermissionSubject,
) !void {
    switch (first) {
        .tool_call => |call| switch (second) {
            .tool_call => |other| try expectSameString(call, other),
            .command, .other => return error.TestUnexpectedResult,
        },
        .command => |command| {
            const other = switch (second) {
                .command => |arm| arm,
                .tool_call, .other => return error.TestUnexpectedResult,
            };
            try expectSameString(command.command, other.command);
            try expectSameString(command.cwd, other.cwd);
            // Both are nullable and each is written only when the peer sent it,
            // so the absent cases have to agree rather than one standing in for
            // the other.
            try expectSameString(command.tool_call_id, other.tool_call_id);
            try expectSameString(command.terminal_id, other.terminal_id);
        },
        .other => |tag| switch (second) {
            .other => |other| try expectSameString(tag, other),
            .tool_call, .command => return error.TestUnexpectedResult,
        },
    }
}

fn roundTripPermissionSubject(
    value: acp.PermissionSubject,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try acp.encodePermissionSubject(value, &writer);
    const again = try acp.decodePermissionSubject(writer.written(), replay);
    try expectPermissionSubject(value, again);
    // The `toolCall` member is spliced rather than rebuilt, so it has to be a
    // complete value to a reader that has not seen the document it was cut out
    // of. This comes last because it borrows `replay`, which is where the
    // comparison above keeps its own escaped strings.
    switch (again) {
        .tool_call => |call| try testing.expect(borrowAccepts(call, replay)),
        .command, .other => {},
    }
    stats.round_trips += 1;
}

/// Compare two decoded option lists.
///
/// No version parameter, because every member of an option is written whatever
/// the version is: the two versions differ in whether an unknown kind is a
/// value at all, and that difference is settled before a decoder could have
/// returned one.
fn expectPermissionOptions(
    first: []const acp.PermissionOption,
    second: []const acp.PermissionOption,
) !void {
    const testing = std.testing;
    try testing.expectEqual(first.len, second.len);
    for (first, second) |one, other| {
        try expectSameString(one.option_id, other.option_id);
        try expectSameString(one.name, other.name);
        // A switch and not an `==`, for the reason the capability entries are
        // compared member by member: a tagged union with a payload in it has no
        // equality that would say which arm the two disagree on, and naming
        // the arm is what a failure report needs.
        switch (one.kind) {
            .known => |kind| switch (other.kind) {
                .known => |other_kind| try testing.expectEqual(kind, other_kind),
                .other => return error.TestUnexpectedResult,
            },
            .other => |text| switch (other.kind) {
                .other => |other_text| try testing.expectEqualStrings(text, other_text),
                .known => return error.TestUnexpectedResult,
            },
        }
    }
}

fn roundTripPermissionRequest(
    value: acp.PermissionRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    // The version is not an argument here because it is not an argument to the
    // encoder either: `PermissionRequest` is a `union(WireVersion)`, so the
    // value carries the revision it was decoded at and passing it separately
    // would give the two a way to disagree.
    const version: acp.WireVersion = switch (value) {
        .stable => .stable,
        .draft => .draft,
    };
    var writer = json.Writer.init(out);
    try acp.encodePermissionRequest(value, &writer);

    // The options live in a caller's array and the decoder fills that array
    // rather than borrowing the document, so the re-decode takes a second one:
    // sharing it would overwrite the entries being compared.
    var options: [16]acp.PermissionOption = undefined;
    const again = try acp.decodePermissionRequest(version, writer.written(), &options, replay);
    try testing.expect(std.meta.activeTag(again) == std.meta.activeTag(value));
    switch (value) {
        .stable => |first| {
            const other = switch (again) {
                .stable => |arm| arm,
                .draft => return error.TestUnexpectedResult,
            };
            try expectSameString(first.session_id, other.session_id);
            // Spliced verbatim, because a `ToolCallUpdate` is not modelled here
            // and this is the one member an agent cannot afford to have
            // re-shaped.
            try expectSameString(first.tool_call, other.tool_call);
            try expectPermissionOptions(first.options, other.options);
        },
        .draft => |first| {
            const other = switch (again) {
                .draft => |arm| arm,
                .stable => return error.TestUnexpectedResult,
            };
            try expectSameString(first.session_id, other.session_id);
            try expectSameString(first.title, other.title);
            // Omitted and `null` mean the same in both schemas, so the encoder
            // writes the member only when the peer sent it and the absent
            // cases have to agree.
            try expectSameString(first.description, other.description);
            try expectPermissionOptions(first.options, other.options);
            if (first.subject == null or other.subject == null) {
                try testing.expect((first.subject == null) == (other.subject == null));
            } else {
                try expectPermissionSubject(first.subject.?, other.subject.?);
            }
        },
    }
    stats.round_trips += 1;
}

// --- The twenty A2A codecs ------------------------------------------------------
//
// One writer per pair, and one of the twenty compares bytes rather than
// members: [`roundTripA2aEmpty`], because the canonical form of every document
// `a2a.decodeEmpty` accepts is `{}` whatever the input spelled, and that is the
// one case where the two sides can be told apart without a model of the
// members. The other nineteen compare members, and the reason is the same one
// the `bridge` comparison exists for: a member a peer sent
// and the shape does not model is dropped by the encoder on purpose, which is
// the stated consequence every decoder in this library records, so a byte
// comparison there would be asserting a document the protocol does not define.
// What is asserted instead is the property that does hold: every member the
// codec models comes back, an optional member comes back as the same optional
// rather than as a default, and a member carried as a borrowed lexeme is still
// a complete value once it has been written out.

fn expectAuthenticationInfo(
    first: ?a2a.AuthenticationInfo,
    second: ?a2a.AuthenticationInfo,
) !void {
    const value = first orelse {
        // The encoder omits an absent member rather than writing `null`, so the
        // re-decode has to agree there was nothing to read.
        try std.testing.expect(second == null);
        return;
    };
    const again = second orelse return error.TestUnexpectedResult;
    try expectSameString(value.scheme, again.scheme);
    try expectSameString(value.credentials, again.credentials);
}

fn roundTripA2aEmpty(
    input: []const u8,
    value: a2a.Empty,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    // The message declares no field, so a member comparison would be a
    // tautology and the bytes are the whole of the value. `{}` is the canonical
    // form of every document the decoder accepts, decoration and all, which is
    // the consequence a decoder that steps over unknown members documents.
    var writer = json.Writer.init(out);
    try a2a.encodeEmpty(value, &writer);
    try expectSameDocumentBytes("a2a.encodeEmpty", input, "{}", writer.written());
    _ = try a2a.decodeEmpty(writer.written(), replay);
    stats.round_trips += 1;
}

fn roundTripA2aGetTaskRequest(
    value: a2a.GetTaskRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeGetTaskRequest(value, &writer);
    const again = try a2a.decodeGetTaskRequest(writer.written(), replay);
    try expectSameString(value.tenant, again.tenant);
    try expectSameString(value.id, again.id);
    // `historyLength` is an `optional int32`, so `"historyLength":0` and no
    // member are two requests and the encoder has to tell them apart.
    try std.testing.expectEqual(value.history_length, again.history_length);
    stats.round_trips += 1;
}

fn roundTripA2aCancelTaskRequest(
    value: a2a.CancelTaskRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try a2a.encodeCancelTaskRequest(value, &writer);
    const again = try a2a.decodeCancelTaskRequest(writer.written(), replay);
    try expectSameString(value.tenant, again.tenant);
    try expectSameString(value.id, again.id);
    try expectSameString(value.metadata, again.metadata);
    // `metadata` is a `Struct` borrowed as the lexeme it arrived as, so it has
    // to be a complete value to a reader that has not seen the document it was
    // cut out of.
    if (again.metadata) |text| try testing.expect(borrowAccepts(text, replay));
    stats.round_trips += 1;
}

fn roundTripA2aSubscribeToTaskRequest(
    value: a2a.SubscribeToTaskRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeSubscribeToTaskRequest(value, &writer);
    const again = try a2a.decodeSubscribeToTaskRequest(writer.written(), replay);
    try expectSameString(value.tenant, again.tenant);
    try expectSameString(value.id, again.id);
    stats.round_trips += 1;
}

fn roundTripA2aGetTaskPushNotificationConfigRequest(
    value: a2a.GetTaskPushNotificationConfigRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeGetTaskPushNotificationConfigRequest(value, &writer);
    const again = try a2a.decodeGetTaskPushNotificationConfigRequest(
        writer.written(),
        replay,
    );
    try expectSameString(value.tenant, again.tenant);
    try expectSameString(value.task_id, again.task_id);
    try expectSameString(value.id, again.id);
    stats.round_trips += 1;
}

fn roundTripA2aDeleteTaskPushNotificationConfigRequest(
    value: a2a.DeleteTaskPushNotificationConfigRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeDeleteTaskPushNotificationConfigRequest(value, &writer);
    const again = try a2a.decodeDeleteTaskPushNotificationConfigRequest(
        writer.written(),
        replay,
    );
    try expectSameString(value.tenant, again.tenant);
    try expectSameString(value.task_id, again.task_id);
    try expectSameString(value.id, again.id);
    stats.round_trips += 1;
}

fn roundTripA2aListTaskPushNotificationConfigsRequest(
    value: a2a.ListTaskPushNotificationConfigsRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try a2a.encodeListTaskPushNotificationConfigsRequest(value, &writer);
    const again = try a2a.decodeListTaskPushNotificationConfigsRequest(
        writer.written(),
        replay,
    );
    try expectSameString(value.task_id, again.task_id);
    // A plain `int32` is still carried as presence here, for the reason
    // `historyLength` is: `"pageSize":0` and no member are the same page and
    // two different documents.
    try testing.expectEqual(value.page_size, again.page_size);
    try expectSameString(value.page_token, again.page_token);
    // `tenant` is field 4 in the proto although the source lists it first, so
    // it is written last and has to come back as itself rather than as the
    // token that precedes it on the wire.
    try expectSameString(value.tenant, again.tenant);
    stats.round_trips += 1;
}

fn roundTripA2aGetExtendedAgentCardRequest(
    value: a2a.GetExtendedAgentCardRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeGetExtendedAgentCardRequest(value, &writer);
    const again = try a2a.decodeGetExtendedAgentCardRequest(writer.written(), replay);
    try expectSameString(value.tenant, again.tenant);
    stats.round_trips += 1;
}

fn roundTripA2aListTasksRequest(
    value: a2a.ListTasksRequest,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try a2a.encodeListTasksRequest(value, &writer);
    const again = try a2a.decodeListTasksRequest(writer.written(), replay);
    try expectSameString(value.tenant, again.tenant);
    try expectSameString(value.context_id, again.context_id);
    // `status` is presence even though the proto declares it singular, and it
    // goes out under the full proto name, so an encoder that wrote the Zig tag
    // would fail to decode at all and one that dropped an unspecified filter
    // would pass an equality on the value alone.
    try testing.expectEqual(value.status, again.status);
    try testing.expectEqual(value.page_size, again.page_size);
    try expectSameString(value.page_token, again.page_token);
    try testing.expectEqual(value.history_length, again.history_length);
    try expectSameString(value.status_timestamp_after, again.status_timestamp_after);
    try testing.expectEqual(value.include_artifacts, again.include_artifacts);
    stats.round_trips += 1;
}

fn roundTripA2aAuthenticationInfo(
    value: a2a.AuthenticationInfo,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeAuthenticationInfo(value, &writer);
    const again = try a2a.decodeAuthenticationInfo(writer.written(), replay);
    try expectSameString(value.scheme, again.scheme);
    try expectSameString(value.credentials, again.credentials);
    stats.round_trips += 1;
}

fn roundTripA2aTaskPushNotificationConfig(
    value: a2a.TaskPushNotificationConfig,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeTaskPushNotificationConfig(value, &writer);
    const again = try a2a.decodeTaskPushNotificationConfig(writer.written(), replay);
    try expectAuthenticationInfo(value.authentication, again.authentication);
    try expectSameString(value.tenant, again.tenant);
    try expectSameString(value.id, again.id);
    try expectSameString(value.task_id, again.task_id);
    try expectSameString(value.url, again.url);
    try expectSameString(value.token, again.token);
    stats.round_trips += 1;
}

fn roundTripA2aSendMessageConfiguration(
    value: a2a.SendMessageConfiguration,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try a2a.encodeSendMessageConfiguration(value, &writer);

    // The accepted modes are filled into a caller's array rather than borrowed
    // from the document, so the re-decode takes a second array: sharing one
    // would overwrite the elements being compared and make the comparison a
    // copy of itself.
    var modes: [16][]const u8 = undefined;
    const again = try a2a.decodeSendMessageConfiguration(writer.written(), &modes, replay);
    try testing.expectEqual(value.history_length, again.history_length);
    try testing.expectEqual(value.return_immediately, again.return_immediately);

    const first = value.accepted_output_modes;
    const second = again.accepted_output_modes;
    if (first == null or second == null) {
        // An absent list and an empty one are different documents, so exactly
        // one of the two being absent is already a disagreement.
        try testing.expect((first == null) == (second == null));
    } else {
        try testing.expectEqual(first.?.len, second.?.len);
        for (first.?, second.?) |one, other| {
            try testing.expectEqualStrings(one, other);
        }
    }

    // The nested configuration is an ordinary optional struct rather than the
    // `AuthenticationInfo` above, so it gets its own comparison rather than
    // sharing one with it.
    const pushed = value.task_push_notification_config;
    const pushed_again = again.task_push_notification_config;
    if (pushed == null or pushed_again == null) {
        try testing.expect((pushed == null) == (pushed_again == null));
    } else {
        try expectSameString(pushed.?.tenant, pushed_again.?.tenant);
        try expectSameString(pushed.?.id, pushed_again.?.id);
        try expectSameString(pushed.?.task_id, pushed_again.?.task_id);
        try expectSameString(pushed.?.url, pushed_again.?.url);
        try expectSameString(pushed.?.token, pushed_again.?.token);
        try expectAuthenticationInfo(
            pushed.?.authentication,
            pushed_again.?.authentication,
        );
    }
    stats.round_trips += 1;
}

fn roundTripA2aAgentInterface(
    value: a2a.AgentInterface,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeAgentInterface(value, &writer);
    const again = try a2a.decodeAgentInterface(writer.written(), replay);
    try expectSameString(value.url, again.url);
    try expectSameString(value.protocol_binding, again.protocol_binding);
    try expectSameString(value.tenant, again.tenant);
    // Kept as the declared text rather than a parsed `Major.Minor`, because a
    // normalised spelling of the same version is not the bytes the agent
    // published.
    try expectSameString(value.protocol_version, again.protocol_version);
    stats.round_trips += 1;
}

fn roundTripA2aAgentProvider(
    value: a2a.AgentProvider,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeAgentProvider(value, &writer);
    const again = try a2a.decodeAgentProvider(writer.written(), replay);
    try expectSameString(value.url, again.url);
    try expectSameString(value.organization, again.organization);
    stats.round_trips += 1;
}

fn roundTripA2aAgentCardSignature(
    value: a2a.AgentCardSignature,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try a2a.encodeAgentCardSignature(value, &writer);
    const again = try a2a.decodeAgentCardSignature(writer.written(), replay);
    // Both are base64url text and neither is a `bytes` field, so there is
    // nothing to convert and the bytes the agent published are the bytes that
    // have to come back.
    try expectSameString(value.protected, again.protected);
    try expectSameString(value.signature, again.signature);
    // `header` is a JSON object rather than base64url and it is carried as the
    // borrowed lexeme, so it is spliced and has to survive whole.
    try expectSameString(value.header, again.header);
    if (again.header) |text| try testing.expect(borrowAccepts(text, replay));
    stats.round_trips += 1;
}

fn roundTripA2aAgentExtension(
    value: a2a.AgentExtension,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    const testing = std.testing;
    var writer = json.Writer.init(out);
    try a2a.encodeAgentExtension(value, &writer);
    const again = try a2a.decodeAgentExtension(writer.written(), replay);
    try expectSameString(value.uri, again.uri);
    try expectSameString(value.description, again.description);
    // `"required":false` and no `required` are two documents, so the boolean
    // has to come back as present-or-absent rather than as a plain false.
    try testing.expectEqual(value.required, again.required);
    try expectSameString(value.params, again.params);
    if (again.params) |text| try testing.expect(borrowAccepts(text, replay));
    stats.round_trips += 1;
}

fn roundTripA2aApiKeySecurityScheme(
    value: a2a.ApiKeySecurityScheme,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeApiKeySecurityScheme(value, &writer);
    const again = try a2a.decodeApiKeySecurityScheme(writer.written(), replay);
    try expectSameString(value.description, again.description);
    // The location is an enum and goes out under the spelling the parser takes,
    // so a value that came back as a different tag would be a peer told to
    // read a credential from somewhere it was never written.
    try std.testing.expectEqual(value.location, again.location);
    try expectSameString(value.name, again.name);
    stats.round_trips += 1;
}

fn roundTripA2aHttpAuthSecurityScheme(
    value: a2a.HttpAuthSecurityScheme,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeHttpAuthSecurityScheme(value, &writer);
    const again = try a2a.decodeHttpAuthSecurityScheme(writer.written(), replay);
    try expectSameString(value.description, again.description);
    try expectSameString(value.scheme, again.scheme);
    try expectSameString(value.bearer_format, again.bearer_format);
    stats.round_trips += 1;
}

fn roundTripA2aOpenIdConnectSecurityScheme(
    value: a2a.OpenIdConnectSecurityScheme,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeOpenIdConnectSecurityScheme(value, &writer);
    const again = try a2a.decodeOpenIdConnectSecurityScheme(writer.written(), replay);
    try expectSameString(value.description, again.description);
    try expectSameString(value.open_id_connect_url, again.open_id_connect_url);
    stats.round_trips += 1;
}

fn roundTripA2aMutualTlsSecurityScheme(
    value: a2a.MutualTlsSecurityScheme,
    replay: []u8,
    out: []u8,
    stats: *Stats,
) !void {
    var writer = json.Writer.init(out);
    try a2a.encodeMutualTlsSecurityScheme(value, &writer);
    const again = try a2a.decodeMutualTlsSecurityScheme(writer.written(), replay);
    try expectSameString(value.description, again.description);
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

test "the round-trip prediction is the encoder's byte order" {
    const testing = std.testing;
    // The prediction is a second walk of the same object, so the one way it
    // could be worthless is by being wrong in exactly the way the encoder is
    // wrong, and the two would then agree on a document neither reproduces.
    // The expected bytes below are written out by hand, so a prediction that
    // lost the carrier `_meta`, moved it, or re-escaped the spliced `params`
    // disagrees with a literal rather than with another piece of the harness.
    //
    // Every document here is deliberately not in the order the encoder writes
    // and carries whitespace beside every member. A prediction compared
    // against the input rather than against the canonical form would fail on
    // all of them, which is why the comparison is against the canonical form.
    var scratch: [max_doc_len]u8 = undefined;
    var out: [encode_buf_len]u8 = undefined;
    var owed: [encode_buf_len]u8 = undefined;

    // `method` arrives escaped and comes back as the character the escape
    // names, because the decoder decodes it and the encoder re-escapes it.
    // `params` arrives with whitespace inside it and keeps it, because neither
    // end of that member ever looks at its structure.
    const envelope_input =
        "{ \"_meta\" : {\"trace\":\"t\"} , \"method\" : \"tools/\\u0063all\" ," ++
        " \"serverId\" : \"s\" , \"requestId\" : \"r\" , " ++
        "\"params\" : { \"n\" : 1 } }";
    const envelope_bytes =
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"tools/call\"," ++
        "\"params\":{ \"n\" : 1 },\"_meta\":{\"trace\":\"t\"}}";
    var envelope_predicted = json.Writer.init(&owed);
    try writeCanonicalEnvelope(envelope_input, &scratch, &envelope_predicted);
    try testing.expectEqualStrings(envelope_bytes, envelope_predicted.written());
    var envelope_writer = json.Writer.init(&out);
    try bridge.encodeEnvelope(
        try bridge.decodeEnvelope(envelope_input, &scratch, null),
        &envelope_writer,
    );
    try testing.expectEqualStrings(envelope_bytes, envelope_writer.written());

    // The result arm, where the payload is spliced, so the whitespace inside
    // it survives the round trip exactly as it arrived.
    const result_input =
        "{ \"_meta\" : {\"trace\":\"t\"} , \"result\" : { \"a\" : [1, 2] } }";
    const result_bytes =
        "{\"result\":{ \"a\" : [1, 2] },\"_meta\":{\"trace\":\"t\"}}";
    var result_predicted = json.Writer.init(&owed);
    try writeCanonicalOutcome(result_input, &scratch, &result_predicted);
    try testing.expectEqualStrings(result_bytes, result_predicted.written());
    var result_writer = json.Writer.init(&out);
    try bridge.encodeOutcome(try bridge.decodeOutcome(result_input, &scratch), &result_writer);
    try testing.expectEqualStrings(result_bytes, result_writer.written());

    // The error arm, and a carrier that is the literal `null` rather than an
    // object: it is a lexeme like any other and the encoder splices it.
    const error_input = "{ \"error\" : {\"code\":-1,\"message\":\"m\"} , \"_meta\" : null }";
    const error_bytes = "{\"error\":{\"code\":-1,\"message\":\"m\"},\"_meta\":null}";
    var error_predicted = json.Writer.init(&owed);
    try writeCanonicalOutcome(error_input, &scratch, &error_predicted);
    try testing.expectEqualStrings(error_bytes, error_predicted.written());

    // A member spelled twice is the *first* one the decoder keeps, so the
    // prediction has to be built from the same occurrence or the two disagree
    // over a document both handle correctly. The bytes below are written out
    // by hand rather than read off either side, which is the only way this
    // case can say which occurrence is the right one.
    const duplicate_input =
        "{\"serverId\":\"first\",\"serverId\":\"s\"," ++
        "\"requestId\":\"r\",\"method\":\"m\"}";
    const duplicate_bytes = "{\"serverId\":\"first\",\"requestId\":\"r\",\"method\":\"m\"}";
    var duplicate_predicted = json.Writer.init(&owed);
    try writeCanonicalEnvelope(duplicate_input, &scratch, &duplicate_predicted);
    try testing.expectEqualStrings(duplicate_bytes, duplicate_predicted.written());
}

test "the prediction and the decoder resolve a repeated member the same way" {
    const testing = std.testing;
    // The byte comparison is built on a prediction that is a second walk of the
    // same object, so the two can be wrong together and still agree. They were
    // wrong together: both walks resolved a repeated member last-wins, so the
    // comparison could not see a peer appending a second `serverId` and being
    // forwarded somewhere the first reader would not have sent it, and the
    // meta-test pinned last-wins as the expected answer.
    //
    // Each case below carries the bytes written out by hand, and both sides
    // are compared against them. So this fails in either direction: a decoder
    // that goes back to last-wins fails on the encoder comparison, and a
    // prediction that goes back to last-wins fails on the prediction one. There
    // is no third way for the two to disagree without one of the two lines
    // noticing, which is what makes the pair evidence rather than a tautology.
    var scratch: [max_doc_len]u8 = undefined;
    var out: [encode_buf_len]u8 = undefined;
    var owed: [encode_buf_len]u8 = undefined;

    // The envelope, one case per member the walk compares. The documents are
    // named constants rather than literals inside the table so that both sides
    // of every comparison read as one string, and so that a case which has to
    // be edited is edited in one place.
    const env_server =
        "{\"serverId\":\"first\",\"serverId\":\"s\"," ++
        "\"requestId\":\"r\",\"method\":\"m\"}";
    const env_request =
        "{\"serverId\":\"s\",\"requestId\":\"first\"," ++
        "\"requestId\":\"second\",\"method\":\"m\"}";
    const env_method =
        "{\"serverId\":\"s\",\"requestId\":\"r\"," ++
        "\"method\":\"first\",\"method\":\"second\"}";
    const env_params =
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"m\"," ++
        "\"params\":{\"a\":1},\"params\":{\"b\":2}}";
    const env_meta =
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"m\"," ++
        "\"_meta\":{\"a\":1},\"_meta\":{\"b\":2}}";
    const env_params_first =
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"m\"," ++
        "\"params\":{\"a\":1}}";
    const env_meta_first =
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"m\"," ++
        "\"_meta\":{\"a\":1}}";
    const env_server_first =
        "{\"serverId\":\"first\",\"requestId\":\"r\",\"method\":\"m\"}";
    const env_request_first =
        "{\"serverId\":\"s\",\"requestId\":\"first\",\"method\":\"m\"}";
    const env_method_first =
        "{\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"first\"}";

    const envelope_cases = [_]struct { input: []const u8, owed: []const u8 }{
        .{ .input = env_server, .owed = env_server_first },
        .{ .input = env_request, .owed = env_request_first },
        .{ .input = env_method, .owed = env_method_first },
        .{ .input = env_params, .owed = env_params_first },
        .{ .input = env_meta, .owed = env_meta_first },
    };
    for (envelope_cases) |case| {
        var predicted = json.Writer.init(&owed);
        try writeCanonicalEnvelope(case.input, &scratch, &predicted);
        try testing.expectEqualStrings(case.owed, predicted.written());
        const decoded = try bridge.decodeEnvelope(case.input, &scratch, null);
        var encoded = json.Writer.init(&out);
        try bridge.encodeEnvelope(decoded, &encoded);
        try testing.expectEqualStrings(case.owed, encoded.written());
    }

    // The outcome, on both arms and on the carrier. The inner error object
    // carries a repeated `code` of its own, so the pair is checked through two
    // walks rather than one — and the payload is spliced rather than rebuilt,
    // so the repeat is still in the bytes the encoder writes.
    const out_result = "{\"result\":{\"a\":1},\"result\":{\"b\":2}}";
    const out_error =
        "{\"error\":{\"code\":-1,\"code\":-32022,\"message\":\"m\"}}";
    const out_meta = "{\"result\":1,\"_meta\":{\"a\":1},\"_meta\":{\"b\":2}}";
    const outcome_cases = [_]struct { input: []const u8, owed: []const u8 }{
        .{ .input = out_result, .owed = "{\"result\":{\"a\":1}}" },
        .{ .input = out_error, .owed = out_error },
        .{ .input = out_meta, .owed = "{\"result\":1,\"_meta\":{\"a\":1}}" },
    };
    for (outcome_cases) |case| {
        var predicted = json.Writer.init(&owed);
        try writeCanonicalOutcome(case.input, &scratch, &predicted);
        try testing.expectEqualStrings(case.owed, predicted.written());
        const decoded = try bridge.decodeOutcome(case.input, &scratch);
        var encoded = json.Writer.init(&out);
        try bridge.encodeOutcome(decoded, &encoded);
        try testing.expectEqualStrings(case.owed, encoded.written());
    }

    // The rule the two walks share, stated as an assertion rather than as a
    // comment: a later member cannot repair an empty one. Under last-wins this
    // document decoded, and the byte comparison had nothing to say about it,
    // because both sides agreed on the wrong answer.
    try testing.expectError(error.InvalidField, bridge.decodeEnvelope(
        "{\"serverId\":\"\",\"serverId\":\"s\",\"requestId\":\"r\",\"method\":\"m\"}",
        &scratch,
        null,
    ));
    // And the repeats the two walks skip are not the mutual exclusion of the
    // outcome members, which is still a refusal: a pair is two outcomes
    // whichever order they arrived in.
    try testing.expectError(error.InvalidField, bridge.decodeOutcome(
        "{\"result\":1,\"error\":{\"code\":-1,\"message\":\"m\"}}",
        &scratch,
    ));
    try testing.expectError(error.InvalidField, bridge.decodeOutcome(
        "{\"error\":{\"code\":-1,\"message\":\"m\"},\"result\":1}",
        &scratch,
    ));
}

test "an encoder that drops the carrier _meta does not reproduce the document" {
    const testing = std.testing;
    // What the check is for, named as a test. The carrier `_meta` was accepted
    // by the decoder, held nowhere the encoder could reach, and dropped on the
    // way out; the members that survived still compared equal, so the
    // member-level check this harness used to make passed on every run. Here
    // the two byte sequences differ by exactly that member, and the check has
    // to say so rather than shrug.
    var scratch: [max_doc_len]u8 = undefined;
    var out: [encode_buf_len]u8 = undefined;
    var owed: [encode_buf_len]u8 = undefined;

    const input = "{\"result\":{\"a\":1},\"_meta\":{\"trace\":\"t\"}}";
    const decoded = try bridge.decodeOutcome(input, &scratch);
    const payload = switch (decoded) {
        .result => |arm| arm,
        .@"error" => return error.TestUnexpectedResult,
    };
    // The decoder really did keep it, so the loss below is the encoder's and
    // not a document that never carried one.
    try expectSameString("{\"trace\":\"t\"}", payload.meta);

    var predicted = json.Writer.init(&owed);
    try writeCanonicalOutcome(input, &scratch, &predicted);
    try testing.expectEqualStrings(input, predicted.written());

    // `meta = null` is what the outcome looked like while the member was being
    // skipped, and the encoder writes exactly the document without it.
    var dropped = json.Writer.init(&out);
    try bridge.encodeOutcome(.{ .result = .{ .text = payload.text } }, &dropped);
    try testing.expectEqualStrings("{\"result\":{\"a\":1}}", dropped.written());
    try testing.expectError(
        error.RoundTripBytesDiffer,
        expectSameDocumentBytes("outcome", input, predicted.written(), dropped.written()),
    );
}

// --- Base64, which takes bytes rather than a document ---------------------------

/// The buffer one base64 encoding of a whole document needs.
///
/// `encodedLen` is the documented bound and the codec writes exactly it, so a
/// buffer sized from the number and handed to the function is the tight one:
/// one byte shorter is `BufferTooSmall`, which is what
/// `test "base64 refuses the alphabet it was not given and every buffer it was
/// told about"` asserts from the other side.
const base64_encoded_len = json.base64.encodedLen(max_doc_len);

/// The buffer the documented decode bound needs, which is one byte more than
/// the document at the lengths this harness builds: three input bytes make four
/// characters, and four characters decode to at most three, so the bound
/// overstates by the whole of the final partial group.
const base64_decoded_len = json.base64.decodedLen(base64_encoded_len).?;

/// Encode the corpus's own bytes in both alphabets and read them back.
///
/// `json.base64` is the one public codec in the tree that takes no document, so
/// it cannot have a trailing-byte case and it is not in [`tail_rule`]. What it
/// can take is bytes, and this harness owns twenty thousand documents' worth of
/// the most hostile bytes there are: invalid UTF-8, a NUL and a `0xff` reach
/// it on every run, at every length from zero to the document bound, which
/// exercises the one-byte, two-byte and three-byte final groups the padding
/// rules turn on. Both alphabets, because a codec that took the alphabet as
/// decoration would agree with itself on every one of them.
fn exerciseBase64(input: []const u8, stats: *Stats) !void {
    const testing = std.testing;
    var encoded: [base64_encoded_len]u8 = undefined;
    var decoded: [base64_decoded_len]u8 = undefined;

    for ([_]json.base64.Alphabet{ .standard, .url }) |alphabet| {
        const text = try json.base64.encode(input, encoded[0..], alphabet);
        try testing.expectEqual(json.base64.encodedLen(input.len), text.len);
        // The bound the documentation tells a caller to size from, measured
        // from this run's own text rather than from the input: a decode that
        // needed more would be a caller's `BufferTooSmall` on a buffer sized
        // correctly from the number the documentation gives.
        const bound = json.base64.decodedLen(text.len) orelse
            return error.Base64BoundMissing;
        try testing.expect(decoded.len >= bound);
        try testing.expectEqualSlices(u8, input, try json.base64.decode(text, decoded[0..], alphabet));
        stats.round_trips += 1;
    }
}

// --- The decoder battery --------------------------------------------------------

/// Feed one document to every public decoder and check the properties.
///
/// `scratch` and `replay` are two buffers of the same size on purpose: the
/// round trips decode into `replay`, so the first decode's borrowed values are
/// still intact when the two are compared. `owed` is a third, for the bytes
/// each `bridge` encoder was supposed to write, and it is never a decode
/// target: the prediction is spent before the re-decode takes `replay`.
fn exerciseEveryDecoder(
    input: []const u8,
    scratch: []u8,
    replay: []u8,
    out: []u8,
    owed: []u8,
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
    // Whether the input is one complete value, and whether it is one value and
    // then more. The second is the question a whole-document decoder has to
    // refuse, and both walks are cheap: the document is bounded by
    // `max_doc_len` and this harness already walks it several times.
    const tail = hasTail(input, &walk_scratch);
    if (tail) stats.tails += 1;
    if (!tail and borrowAccepts(input, &walk_scratch)) {
        var walk_reader = json.Reader.init(input);
        try walkValue(&walk_reader, walk_scratch[0..measured]);
    }

    if (jsonrpc.decode(input, scratch)) |message| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 23);
        try roundTripJsonRpc(message, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (mcp.decodeResultType(input, scratch)) |result| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 24);
        try expectRoundTripHasNoTail("mcp.decodeResultType", input, tail);
        try roundTripResultType(result, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (mcp.decodeInputRequiredResult(input, scratch)) |result| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 25);
        try expectRoundTripHasNoTail("mcp.decodeInputRequiredResult", input, tail);
        try roundTripInputRequiredResult(result, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (acp.nextFrame(input)) |frame| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 26);
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
        reachedBatteryCodec(stats, 27);
        try expectRoundTripHasNoTail("acp.decodePermissionOutcome", input, tail);
        try roundTripPermissionOutcome(outcome, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (acp.decodeReplayFrom(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 0);
        try expectRoundTripHasNoTail("acp.decodeReplayFrom", input, tail);
        try roundTripReplayFrom(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (acp.decodePermissionSubject(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 1);
        try expectRoundTripHasNoTail("acp.decodePermissionSubject", input, tail);
        try roundTripPermissionSubject(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    // The option array every permission-request decode writes into. A document
    // with more options than this is a `BufferTooSmall`, which a caller sees as
    // a decode error rather than a truncated list of choices.
    var permission_options: [16]acp.PermissionOption = undefined;
    if (acp.decodePermissionRequest(.stable, input, &permission_options, scratch)) |request| {
        stats.accepted += 1;
        // The stable arm records the reach for the decoder, because the draft
        // arm two blocks down is the same function read at another revision
        // and a corpus that reached only one of them has still reached it.
        reachedBatteryCodec(stats, 29);
        try expectRoundTripHasNoTail("acp.decodePermissionRequest stable", input, tail);
        const v1 = switch (request) {
            .stable => |value| value,
            .draft => return error.TestUnexpectedResult,
        };
        try testing.expect(borrowAccepts(v1.tool_call, replay));
        // The round trip takes `replay` back, so it runs after the borrow check
        // above rather than before it: the two would otherwise be reading one
        // buffer at the same time.
        try roundTripPermissionRequest(request, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (acp.decodePermissionRequest(.draft, input, &permission_options, scratch)) |request| {
        stats.accepted += 1;
        try expectRoundTripHasNoTail("acp.decodePermissionRequest draft", input, tail);
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
        try roundTripPermissionRequest(request, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (bridge.decodeEnvelope(input, scratch, .{ .integer = 1 })) |envelope| {
        stats.accepted += 1;
        // The round-trip block rather than the direction-only one below: they
        // are the same decoder, and the bit is about the decoder being fed.
        reachedBatteryCodec(stats, 30);
        try expectRoundTripHasNoTail("bridge.decodeEnvelope", input, tail);
        try roundTripEnvelope(input, envelope, replay, out, owed, stats);
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
        reachedBatteryCodec(stats, 31);
        try expectRoundTripHasNoTail("bridge.decodeOutcome", input, tail);
        try roundTripOutcome(input, outcome, replay, out, owed, stats);
    } else |_| {
        stats.refused += 1;
    }

    // --- The twenty A2A codecs ------------------------------------------------
    //
    // One block per pair, and the shape is the one every other decoder here
    // has: accept or refuse, count it, refuse a tailed document if it accepted,
    // and put the value back through its own encoder. Fourteen seeds in
    // [`seed_documents`] exist so these twenty are reached by a real document
    // rather than by a lucky draw; every block below runs on the whole corpus.

    if (a2a.decodeEmpty(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 3);
        try expectRoundTripHasNoTail("a2a.decodeEmpty", input, tail);
        try roundTripA2aEmpty(input, value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeGetTaskRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 4);
        try expectRoundTripHasNoTail("a2a.decodeGetTaskRequest", input, tail);
        try roundTripA2aGetTaskRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeCancelTaskRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 5);
        try expectRoundTripHasNoTail("a2a.decodeCancelTaskRequest", input, tail);
        try roundTripA2aCancelTaskRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeSubscribeToTaskRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 6);
        try expectRoundTripHasNoTail("a2a.decodeSubscribeToTaskRequest", input, tail);
        try roundTripA2aSubscribeToTaskRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeGetTaskPushNotificationConfigRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 7);
        try expectRoundTripHasNoTail(
            "a2a.decodeGetTaskPushNotificationConfigRequest",
            input,
            tail,
        );
        try roundTripA2aGetTaskPushNotificationConfigRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeDeleteTaskPushNotificationConfigRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 8);
        try expectRoundTripHasNoTail(
            "a2a.decodeDeleteTaskPushNotificationConfigRequest",
            input,
            tail,
        );
        try roundTripA2aDeleteTaskPushNotificationConfigRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeListTaskPushNotificationConfigsRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 9);
        try expectRoundTripHasNoTail(
            "a2a.decodeListTaskPushNotificationConfigsRequest",
            input,
            tail,
        );
        try roundTripA2aListTaskPushNotificationConfigsRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeGetExtendedAgentCardRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 10);
        try expectRoundTripHasNoTail("a2a.decodeGetExtendedAgentCardRequest", input, tail);
        try roundTripA2aGetExtendedAgentCardRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeListTasksRequest(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 11);
        try expectRoundTripHasNoTail("a2a.decodeListTasksRequest", input, tail);
        try roundTripA2aListTasksRequest(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeAuthenticationInfo(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 12);
        try expectRoundTripHasNoTail("a2a.decodeAuthenticationInfo", input, tail);
        try roundTripA2aAuthenticationInfo(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeTaskPushNotificationConfig(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 13);
        try expectRoundTripHasNoTail("a2a.decodeTaskPushNotificationConfig", input, tail);
        try roundTripA2aTaskPushNotificationConfig(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    // The accepted-mode array the configuration decoder fills. A document with
    // more modes than this is a `BufferTooSmall`, which a caller reads as a
    // decode error rather than as a truncated list of what it will accept.
    var output_modes: [16][]const u8 = undefined;
    if (a2a.decodeSendMessageConfiguration(input, &output_modes, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 14);
        try expectRoundTripHasNoTail("a2a.decodeSendMessageConfiguration", input, tail);
        try roundTripA2aSendMessageConfiguration(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeAgentInterface(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 15);
        try expectRoundTripHasNoTail("a2a.decodeAgentInterface", input, tail);
        try roundTripA2aAgentInterface(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeAgentProvider(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 16);
        try expectRoundTripHasNoTail("a2a.decodeAgentProvider", input, tail);
        try roundTripA2aAgentProvider(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeAgentCardSignature(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 17);
        try expectRoundTripHasNoTail("a2a.decodeAgentCardSignature", input, tail);
        try roundTripA2aAgentCardSignature(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeAgentExtension(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 18);
        try expectRoundTripHasNoTail("a2a.decodeAgentExtension", input, tail);
        try roundTripA2aAgentExtension(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeApiKeySecurityScheme(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 19);
        try expectRoundTripHasNoTail("a2a.decodeApiKeySecurityScheme", input, tail);
        try roundTripA2aApiKeySecurityScheme(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeHttpAuthSecurityScheme(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 20);
        try expectRoundTripHasNoTail("a2a.decodeHttpAuthSecurityScheme", input, tail);
        try roundTripA2aHttpAuthSecurityScheme(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeOpenIdConnectSecurityScheme(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 21);
        try expectRoundTripHasNoTail("a2a.decodeOpenIdConnectSecurityScheme", input, tail);
        try roundTripA2aOpenIdConnectSecurityScheme(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    if (a2a.decodeMutualTlsSecurityScheme(input, scratch)) |value| {
        stats.accepted += 1;
        reachedBatteryCodec(stats, 22);
        try expectRoundTripHasNoTail("a2a.decodeMutualTlsSecurityScheme", input, tail);
        try roundTripA2aMutualTlsSecurityScheme(value, replay, out, stats);
    } else |_| {
        stats.refused += 1;
    }

    // The one public codec that takes no document. It has no trailing-byte case
    // for that reason and is not in [`tail_rule`]; what it does have is the
    // whole corpus of hostile bytes, in both alphabets.
    try exerciseBase64(input, stats);

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
                reachedBatteryCodec(stats, 28);
                try expectRoundTripHasNoTail("acp.decodeCapabilityObject", input, tail);
                // No assertion on `set.present` here, and the absence is the
                // point: `decodeCapabilityObject` has one success path and it
                // returns `present = true`, so `expect(set.present)` could not
                // fail and was a green carrying no information inside the
                // battery whose thesis is that green must mean something. The
                // assertion that can fail is in
                // [`roundTripCapabilityObject`], where the re-decode's
                // `present` is compared against what the encoder was handed
                // and the encoder refuses `!present` outright — so a swap
                // between an absent member and an empty one lands there. That
                // is the same rule, on the only side of the pair where it is
                // a question.
                try expectDisjointPaths(set.entries, paths[0..]);
                try roundTripCapabilityObject(version, side, set, replay, out, stats);
            } else |_| {
                // Arbitrary input is usually not a capability object. Any
                // DecodeError is a valid refusal; only a trap violates totality.
                stats.refused += 1;
            }
        }
    }

    // The capability member of an `initialize` body, which is the same walk
    // behind a member name the version and the side choose. It was named rather
    // than asserted while it had no encoder, so it gets its own loop here
    // rather than being folded into the one above: the two agree on what a set
    // contains and differ on what an absent member means, and the encoder is
    // what tells them apart.
    for ([_]acp.WireVersion{ .stable, .draft }) |version| {
        for ([_]acp.Side{ .client, .agent }) |side| {
            if (acp.decodeInitializeCapabilities(
                version,
                side,
                input,
                &capabilities,
                &paths,
                scratch,
            )) |set| {
                stats.accepted += 1;
                reachedBatteryCodec(stats, 2);
                try expectRoundTripHasNoTail("acp.decodeInitializeCapabilities", input, tail);
                try expectDisjointPaths(set.entries, paths[0..]);
                try roundTripInitializeCapabilities(version, side, set, replay, out, stats);
            } else |_| {
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
    // The bytes each `bridge` encoder owes. Sized like `out` for the reason
    // `out` is: a prediction never re-escapes a byte into more bytes than it
    // read, and it drops the whitespace the input spent, so a
    // `BufferTooSmall` here is a harness bug rather than a tight buffer.
    var owed: [encode_buf_len]u8 = undefined;

    for (0..count) |index| {
        writeShape(rng, &doc, &splice, index);
        try exerciseEveryDecoder(doc.slice(), &scratch, &replay, &out, &owed, &stats);
    }

    // A run that generated nothing useful would pass by decoding nothing.
    // These are the only guarantees a seed-independent count can make.
    try testing.expect(stats.documents == count);
    try testing.expect(stats.accepted != 0);
    try testing.expect(stats.refused != 0);
    try testing.expect(stats.round_trips != 0);
    // A harness whose trailing-byte assertion never fires is a harness that
    // has stopped checking anything, so the corpus has to keep producing the
    // case. The same guard the differential run uses: a short run says
    // nothing either way, so it asserts nothing.
    if (count >= 1000) try testing.expect(stats.tails != 0);
    // Every codec the battery hands something to has to have accepted
    // something, or its trailing-byte assertion and its round trip are both
    // green on a run that never called it. This is the same guard as the line
    // above and for the same reason: a short run says nothing either way, so
    // it asserts nothing.
    if (count >= 1000) try expectEveryBatteryCodecReached(&stats);
    // The byte comparison this harness exists for has to have run over a
    // document carrying a carrier `_meta`, on both objects, or the run says
    // nothing about the member the carrier was added to keep. Three seeds
    // spell one; a counter is what makes their removal a failure rather than a
    // quiet narrowing, and one counter per object is what stops the envelope
    // going quiet while the outcome stays loud.
    if (count >= 1000) {
        try testing.expect(stats.envelope_meta_round_trips != 0);
        try testing.expect(stats.outcome_meta_round_trips != 0);
    }
    std.debug.print(
        "  documents={d} accepted={d} refused={d} round-trips={d}\n",
        .{ stats.documents, stats.accepted, stats.refused, stats.round_trips },
    );
    return stats;
}

test "every decoder the battery feeds is total over generated input" {
    // The completeness of that set is `test "the coverage tables agree on what
    // the battery feeds"`: this test is about totality over the corpus, and
    // naming it after every public decoder claimed a coverage the run cannot
    // see. What the two together say is what the harness means — every public
    // decoder is either fed here or named in [`tail_rule.unasserted`] with the
    // reason it is not.
    _ = try runPropertyHarness(seed, iterations);
}

test "the generator can spell every member jsonrpc.decode branches on" {
    // Transcribed from the branches of `jsonrpc.decode` and `decodeError`.
    //
    // The check is `spelledByASeed` and not "is the name in the vocabulary",
    // because membership in the vocabulary holds by construction: the nine
    // names below are the first nine rows of `member_names`, and
    // `string_vocabulary` is that table plus the derived one, so the old form
    // of this test could not have failed whatever a decoder did. What the
    // check below can fail on is the corpus: a name in the vocabulary that no
    // seed spells is a name only the grammar generator can emit as a key, and
    // the rules that depend on *moving* it — the unknown-member skip, the
    // missing-member rules, the classification on `id` and `method`, the
    // `result`/`error` exclusion — are then asserted over the handful of
    // documents in the whole run that happen to draw it. Each name here is one
    // `renameMember` can move, which is what "the generator can spell it" has
    // to mean to be worth asserting.
    //
    // The wider table is checked in both directions by `test "every member
    // name is in a seed or listed as grammar-only"` and `test "the derived A2A
    // vocabulary is the tables the codecs are written from"`, because a
    // decoder's key set cannot be read as data from here.
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
    // `inline for` because `spelledByASeed` takes its needle as a comptime
    // parameter, and a runtime name cannot satisfy one.
    inline for (decoded_names) |name| {
        if (!spelledByASeed(name)) {
            std.debug.print("\ngenerator: no seed spells the member '{s}'\n", .{name});
            return error.MemberNameUnreachable;
        }
    }
}

test "the coverage tables agree on what the battery feeds" {
    const testing = std.testing;
    // Three tables say what this harness does, and while they agreed there was
    // no way to tell whether any of them was right. The checks below are what
    // makes disagreement a failure rather than a paragraph nobody reads.
    //
    // `inline for` and a body without `continue`, `break` or `return`, for the
    // reason `test "every member name is in a seed or listed as grammar-only"`
    // gives: the loop unrolls, so a `continue` in it is comptime control flow
    // in a runtime block. The body records which name failed and the verdicts
    // are reached after the loop.
    @setEvalBranchQuota(200_000);
    var repeated: ?[]const u8 = null;
    var unlisted_round_trip: ?[]const u8 = null;
    var unlisted_wave_codec: ?[]const u8 = null;
    var fed: ?[]const u8 = null;
    var reasonless: ?[]const u8 = null;
    var misfiled: ?[]const u8 = null;

    // The prose around these tables quotes their sizes — "twenty-nine", "the
    // first twenty-three", "the nine after them" — and a count that has
    // drifted from the number the comment states is the same fault in a new
    // place: a reader who believes "twenty-nine decoders lack coverage" is
    // told something false, which is what this test exists to stop.
    try testing.expectEqual(@as(usize, 29), tail_rule.unasserted.len);
    try testing.expectEqual(@as(usize, 30), tail_rule.round_trip.len);
    try testing.expectEqual(wave_codec_count + 9, battery_codec_names.len);

    // And the split the table's doc describes, by name shape rather than by
    // arithmetic: the wave's half is three `acp` rows and then twenty `a2a`
    // ones, and a row filed on the wrong side of that is a table and a
    // paragraph disagreeing all over again.
    inline for (battery_codec_names[0..wave_codec_count], 0..) |name, index| {
        const acp_row = std.mem.startsWith(u8, name, "acp.");
        const a2a_row = std.mem.startsWith(u8, name, "a2a.");
        if (acp_row == a2a_row) misfiled = name;
        if (a2a_row != (index >= 3)) misfiled = name;
    }
    if (misfiled) |name| {
        std.debug.print("\ncoverage: '{s}' is filed on the wrong side of the wave\n", .{name});
        return error.CodecTableShapeChanged;
    }

    // A name in [`battery_codec_names`] twice is one bit short of the two, and
    // the one that is short is whichever sort order put last. That is exactly
    // the fault the two tables recorded: a decoder in the battery with a
    // trailing-byte assertion, a round trip, and no bit to say so.
    inline for (battery_codec_names, 0..) |name, index| {
        inline for (battery_codec_names[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, name) and repeated == null) repeated = name;
        }
    }

    // Every decoder the harness re-encodes is one it feeds, or the tail rule
    // is asserting about a decoder nothing in the battery calls.
    //
    // The two tables are held in locals so the membership helper below is
    // handed slices rather than arrays: a comptime array does not coerce to a
    // comptime slice on its own, and the helper is written for the slice both
    // tables really are.
    const round_trip_names: []const []const u8 = tail_rule.round_trip;
    const battery_names: []const []const u8 = &battery_codec_names;
    inline for (round_trip_names) |name| {
        if (nameIndex(battery_names, name) == null) unlisted_round_trip = name;
    }

    // And every codec this wave added is in the round-trip half, which is the
    // sentence the two tables used to disagree about: one said three `acp`
    // decoders landed, the other said five.
    inline for (battery_codec_names[0..wave_codec_count]) |name| {
        if (nameIndex(round_trip_names, name) == null) unlisted_wave_codec = name;
    }

    // A decoder named as unfed that the battery feeds is the same fault in the
    // other direction, and the more dangerous one: it tells a reader the
    // coverage is absent when the run is exercising it. `inline for` here for
    // the same reason as the two loops above — the membership answer has to be
    // a comptime one — and so an empty `why` is checked the same way: a row
    // with no reason is the gap this field exists to close, left open.
    inline for (tail_rule.unasserted) |row| {
        if (row.why.len == 0) reasonless = row.name;
        if (nameIndex(battery_names, row.name) != null) fed = row.name;
        if (nameIndex(round_trip_names, row.name) != null) fed = row.name;
    }

    if (repeated) |name| {
        std.debug.print("\ncoverage: '{s}' is in the battery table twice\n", .{name});
        return error.DuplicateBatteryCodec;
    }
    if (unlisted_round_trip) |name| {
        std.debug.print("\ncoverage: '{s}' is re-encoded and not in the battery\n", .{name});
        return error.RoundTripCodecNotInBattery;
    }
    if (unlisted_wave_codec) |name| {
        std.debug.print("\ncoverage: '{s}' is in the battery and not re-encoded\n", .{name});
        return error.BatteryCodecNotRoundTripped;
    }
    if (fed) |name| {
        std.debug.print("\ncoverage: '{s}' is fed and named as unfed\n", .{name});
        return error.FeedCodecAlsoNamedUnfed;
    }
    if (reasonless) |name| {
        std.debug.print("\ncoverage: '{s}' is named as unfed with no reason\n", .{name});
        return error.UnfedCodecWithoutReason;
    }
}

test "every member name is in a seed or listed as grammar-only" {
    // The quota is the price of the check below, not slack. The loop unrolls,
    // every comparison runs at comptime, and each name is searched through
    // every seed, so the work is names times seeds times a substring search
    // that preprocesses its own skip table. That is more backwards branches
    // than the default thousand allows by a wide margin, and 20 000 was not
    // enough either: the compiler reported the same overflow at that figure.
    // The A2A half made it worse in both factors at once — twenty-nine more
    // names and nineteen more seeds — so the number is three orders above the
    // limit rather than one. Deleting the keyword does not make the check
    // cheaper, it makes the test fail to compile, so raise the number rather
    // than drop a name.
    @setEvalBranchQuota(2_000_000);

    // The whole vocabulary and the two ways the corpus can use one have to
    // cover each other exactly. A name a seed spells is one a mutation can move;
    // a name no seed spells is one the grammar generator can emit as a key and
    // nothing more, and it has to be listed as such or it is corpus weight. A
    // name in neither place widens every mutation in the corpus and reaches no
    // rule, so this fails rather than growing. This is what holds the derived
    // half to the same promise as the hand-written one: a member an A2A
    // message's table carries has to be spelled by a seed, and the fourteen at
    // the end of [`seed_documents`] are what make that true.
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
    inline for (vocabulary_member_names) |name| {
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

test "the previous revision resolves the three names the current one refuses" {
    const testing = std.testing;
    // `lookupMethod` takes the revision, and what `2026-07-28` removed from the
    // top level is a request `2025-11-25` still defines. The corpus feeds the
    // registry a name cut out of a document, so it reaches `.previous` and
    // reaches it with names no table below matches; nothing else in this file
    // would notice a registry that answered the current revision's table for
    // both and refused three requests an older peer is entitled to send.
    //
    // Three and not four, because the count is itself part of the claim: a
    // fourth name added to the table would be a fourth thing to check.
    try testing.expectEqual(@as(usize, 3), mcp.previous_top_level_requests.len);
    for (mcp.previous_top_level_requests) |info| {
        const there = try mcp.lookupMethod(.previous, info.name);
        try testing.expectEqualStrings(info.name, there.name);
        // The top-level direction rather than the one `input_requests` carries:
        // a row that reused the carried direction would resolve the name here
        // and then be refused as `NotARequest` by the session gate, so a
        // previous-revision server would refuse to answer it as well.
        try testing.expect(there.direction == .client_to_server);
        try testing.expect(!there.present_at_current);

        try testing.expectError(
            error.UnknownMethod,
            mcp.lookupMethod(.current, info.name),
        );

        // The same three survive as values inside an MRTR answer at every
        // revision the library decodes, so the second table has to resolve them
        // too and in the other direction.
        const carried = try mcp.lookupInputRequest(info.name);
        try testing.expectEqualStrings(info.name, carried.name);
        try testing.expect(carried.direction == .server_to_client_mrtr_only);
        try testing.expect(carried.present_at_current);
    }
}

test "base64 refuses the alphabet it was not given and every buffer it was told about" {
    const testing = std.testing;
    var encoded: [16]u8 = undefined;
    var decoded: [16]u8 = undefined;

    // The two alphabets differ in exactly two characters, so a codec that took
    // the alphabet as decoration would accept what the other spelling refuses
    // and produce the same bytes from both. This input reaches all four of the
    // differing positions: 0xfb 0xff 0xbf is 62 63 62 63 in six-bit groups,
    // which is `+/+/` in one spelling and `-_-_` in the other and nothing
    // else, so a decoder reading the wrong alphabet has no character to fall
    // back on.
    const digits = [_]u8{ 0xfb, 0xff, 0xbf };
    try testing.expectEqualStrings(
        "+/+/",
        try json.base64.encode(&digits, encoded[0..], .standard),
    );
    try testing.expectEqualStrings(
        "-_-_",
        try json.base64.encode(&digits, encoded[0..], .url),
    );
    try testing.expectError(
        error.InvalidField,
        json.base64.decode("+/+/", decoded[0..], .url),
    );
    try testing.expectError(
        error.InvalidField,
        json.base64.decode("-_-_", decoded[0..], .standard),
    );
    // Each spelling reads its own back to the bytes it came from.
    try testing.expectEqualSlices(
        u8,
        &digits,
        try json.base64.decode("+/+/", decoded[0..], .standard),
    );
    try testing.expectEqualSlices(
        u8,
        &digits,
        try json.base64.decode("-_-_", decoded[0..], .url),
    );

    // Padding is a property of the codec rather than of the alphabet: RFC 4648
    // section 5 defines the URL-safe alphabet with the same pad characters, so
    // both spellings emit pads and both require them.
    try testing.expectEqualStrings("QQ==", try json.base64.encode("A", encoded[0..], .standard));
    try testing.expectEqualStrings("QQ==", try json.base64.encode("A", encoded[0..], .url));
    try testing.expectEqualStrings("QUI=", try json.base64.encode("AB", encoded[0..], .standard));
    try testing.expectEqualStrings("QUJD", try json.base64.encode("ABC", encoded[0..], .url));
    try testing.expectEqualStrings("", try json.base64.encode("", encoded[0..], .url));

    // Totality. Every byte of an encoded value is peer input, so a group that
    // is not four characters, a group opening with a pad, a group carrying one
    // digit and a character outside the alphabet are all `error.InvalidField`
    // and never a trap.
    try testing.expectError(error.InvalidField, json.base64.decode("QQ=", decoded[0..], .standard));
    try testing.expectError(error.InvalidField, json.base64.decode("====", decoded[0..], .standard));
    try testing.expectError(error.InvalidField, json.base64.decode("=QQQ", decoded[0..], .standard));
    try testing.expectError(error.InvalidField, json.base64.decode("Q=QQ", decoded[0..], .standard));
    try testing.expectError(error.InvalidField, json.base64.decode("QQ!Q", decoded[0..], .standard));
    try testing.expectError(error.InvalidField, json.base64.decode("+/+/", decoded[0..], .url));

    // The two bounds, from both sides. `decodedLen` is null for a length that
    // is not a whole number of groups, so a caller that checks it cannot go on
    // to divide a partial group, and `encodedLen` is the buffer an input of
    // every length from zero to three needs.
    try testing.expect(json.base64.decodedLen(0) != null);
    try testing.expect(json.base64.decodedLen(3) == null);
    try testing.expectEqual(@as(usize, 0), json.base64.encodedLen(0));
    try testing.expectEqual(@as(usize, 4), json.base64.encodedLen(1));
    try testing.expectEqual(@as(usize, 4), json.base64.encodedLen(2));
    try testing.expectEqual(@as(usize, 4), json.base64.encodedLen(3));
    try testing.expectEqual(@as(usize, 8), json.base64.encodedLen(4));
    // The documented decode bound overstates rather than understates, so a
    // buffer sized from it is never short. That is the direction that matters:
    // one sized from the padded length would report the peer's bytes as the
    // caller's own mistake.
    try testing.expectEqual(@as(usize, 3), json.base64.decodedLen(4).?);
    try testing.expectEqual(@as(usize, 6), json.base64.decodedLen(8).?);

    // A buffer one byte short is `BufferTooSmall` rather than a truncated
    // value. That is the caller's own sizing mistake and it is kept apart from
    // `InvalidField` because the two have different repairs.
    var short_out: [3]u8 = undefined;
    var short_in: [2]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        json.base64.encode("ABC", short_out[0..], .standard),
    );
    try testing.expectError(
        error.BufferTooSmall,
        json.base64.decode("QUJD", short_in[0..], .standard),
    );
}

test "the derived A2A vocabulary is the tables the codecs are written from" {
    const testing = std.testing;
    // The point of deriving [`a2a_member_names`] rather than transcribing it is
    // that there is nothing left to keep in step. This is what says so from the
    // other side: every name the harness can write as an A2A key is one a
    // decoder in [`a2a_codec_messages`] really compares, and `findField` finds
    // it on that message and on no other of the twenty.
    //
    // "On no other" is the half that matters. A name several of the twenty
    // carry is fine — `tenant` is nine — and the assertion below is that the
    // set the generator uses and the set the tables carry are the same set,
    // checked from the tables rather than from a list.
    var missing_from_a_table: ?[]const u8 = null;
    for (a2a_member_names) |name| {
        var found = false;
        inline for (a2a_codec_messages) |T| {
            if (a2a.findField(T, name) != null) found = true;
        }
        if (!found) missing_from_a_table = name;
    }
    if (missing_from_a_table) |name| {
        std.debug.print("\ncorpus: '{s}' is in no A2A field table\n", .{name});
        return error.A2aMemberNameNotInATable;
    }

    // And the other direction: a table row that the vocabulary dropped is a
    // member the corpus cannot spell, which is the drift the derivation was
    // supposed to remove rather than introduce.
    var dropped: ?[]const u8 = null;
    inline for (a2a_codec_messages) |T| {
        for (T.fields) |entry| {
            const name = entry.json orelse continue;
            var known = false;
            for (vocabulary_member_names) |existing| {
                if (std.mem.eql(u8, existing, name)) known = true;
            }
            if (!known and dropped == null) dropped = name;
        }
    }
    if (dropped) |name| {
        std.debug.print("\ncorpus: the A2A table carries '{s}' and the vocabulary does not\n", .{name});
        return error.A2aMemberNameMissing;
    }
    try testing.expect(a2a_member_names.len != 0);
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

/// Write `input` into `out` with every leading zero replaced by a `1`.
///
/// One byte in, one byte out, so the copy is the same length as the input and
/// the only thing that changed is the fault. `01` becomes `11`, `-01` becomes
/// `-11` and `00.5` becomes `10.5`; each is a number both parsers take, so a
/// document whose *only* disagreement was the leading zero turns into one they
/// agree on and a document with a second and independent fault does not. The
/// scan is [`hasLeadingZero`]'s, byte for byte, so the rewrite and the
/// predicate it feeds cannot disagree about which zeros are leading.
///
/// False when the buffer cannot hold the copy or when there was nothing to
/// change, and a false answer is what makes the exemption unavailable rather
/// than what makes it automatic.
fn rewriteLeadingZeros(input: []const u8, out: []u8) bool {
    if (out.len < input.len) return false;
    @memcpy(out[0..input.len], input);
    var changed = false;
    var pos: usize = 0;
    while (pos < input.len) {
        const byte = out[pos];
        if (byte == '"') {
            pos += 1;
            while (pos < input.len) : (pos += 1) {
                if (out[pos] == '\\') {
                    pos += 1;
                } else if (out[pos] == '"') {
                    break;
                }
            }
            pos += 1;
            continue;
        }
        if (byte == '0' and pos + 1 < input.len and isDigitByte(out[pos + 1])) {
            const opens = pos == 0 or
                std.mem.indexOfScalar(u8, number_start_bytes, out[pos - 1]) != null;
            if (opens) {
                out[pos] = '1';
                changed = true;
            }
        }
        pos += 1;
    }
    return changed;
}

/// Whether a disagreement is the one [`DivergenceCase`] records.
///
/// Scoped to the difference the table names rather than to a document that
/// happens to carry it. [`hasLeadingZero`] answers "is the fault in here"; this
/// answers "is the fault the whole of the disagreement", and it answers it by
/// taking the fault out and asking the two parsers again. A second and
/// independent divergence behind the same leading zero therefore leaves them
/// disagreeing and is reported, where a predicate that only looked for a zero
/// would have absorbed it.
///
/// The direction is the recorded one and nothing else: the borrow reader takes
/// a leading zero and `std.json` refuses it, so a disagreement the other way
/// round is a finding whatever the document carries.
fn isRecordedLeadingZeroDisagreement(
    allocator: std.mem.Allocator,
    mine: bool,
    theirs: bool,
    input: []const u8,
    scratch: []u8,
    fixed: []u8,
) !bool {
    if (!mine or theirs) return false;
    if (!hasLeadingZero(input)) return false;
    if (!rewriteLeadingZeros(input, fixed)) return false;
    const mine_fixed = borrowAccepts(fixed, scratch);
    if (mine_fixed != try referenceAccepts(allocator, fixed)) return false;
    // Where both now take the document they must also read it as the same kind
    // of value, so the rewrite removed the fault rather than moving it.
    if (mine_fixed) return borrowKind(fixed) == try referenceKind(allocator, fixed);
    return true;
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

    // The exemption is scoped to the difference rather than to a document
    // carrying one, and the two halves of that are checked from both sides
    // below. The recorded case is excused, and the rewrite that decides it
    // leaves a document both parsers take.
    var scratch: [max_doc_len]u8 = undefined;
    var fixed: [max_doc_len]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scoped = arena.allocator();

    try testing.expect(try isRecordedLeadingZeroDisagreement(
        scoped,
        true,
        false,
        "01",
        &scratch,
        &fixed,
    ));
    try testing.expectEqualStrings("11", fixed[0..2]);
    try testing.expect(borrowAccepts(fixed[0..2], &scratch));
    try testing.expect(try referenceAccepts(scoped, fixed[0..2]));

    // With nowhere to take the difference out, the same document is a finding
    // rather than an exemption. A rule that only asked whether the document
    // carried a leading zero would answer true here, and this is the line
    // between the two claims.
    var no_room: [0]u8 = undefined;
    try testing.expect(!try isRecordedLeadingZeroDisagreement(
        scoped,
        true,
        false,
        "01",
        &scratch,
        &no_room,
    ));

    // The other direction is a finding whatever the document carries: the
    // borrow reader is the one that takes a leading zero, never the reference.
    try testing.expect(!try isRecordedLeadingZeroDisagreement(
        scoped,
        false,
        true,
        "01",
        &scratch,
        &fixed,
    ));
    // A document with no leading zero in it, and one with a zero that is text,
    // are both findings however the parsers answered them.
    try testing.expect(!try isRecordedLeadingZeroDisagreement(
        scoped,
        true,
        false,
        "102",
        &scratch,
        &fixed,
    ));
    try testing.expect(!try isRecordedLeadingZeroDisagreement(
        scoped,
        true,
        false,
        "\"01\"",
        &scratch,
        &fixed,
    ));
    // And a document the two parsers agree on is not a disagreement at all,
    // whatever the arguments say: the rule cannot excuse a document that was
    // never in dispute.
    try testing.expect(!try isRecordedLeadingZeroDisagreement(
        scoped,
        true,
        true,
        "01",
        &scratch,
        &fixed,
    ));
    try testing.expect(!try isRecordedLeadingZeroDisagreement(
        scoped,
        false,
        false,
        "01",
        &scratch,
        &fixed,
    ));

    // The rewrite is the mechanism the rule rests on, so it is checked on its
    // own: the length is preserved, the strings are untouched, and a `0` that
    // continues a number under way is not a leading one.
    const rewrite = "{\"a\":[01,-01,00.5]}";
    try testing.expect(rewriteLeadingZeros(rewrite, &fixed));
    try testing.expectEqualStrings("{\"a\":[11,-11,10.5]}", fixed[0..rewrite.len]);
    try testing.expect(!rewriteLeadingZeros("{\"a\":1.02}", &fixed));
    try testing.expect(!rewriteLeadingZeros("\"01\"", &fixed));
    try testing.expect(!rewriteLeadingZeros("01", &no_room));
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
    // The document with its leading zeros taken out, which is what the recorded
    // disagreement has to be the whole of, and the buffer the failure message
    // renders it through.
    var fixed: [max_doc_len]u8 = undefined;
    var without: [2 * max_doc_len + 8]u8 = undefined;
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
            // absorbed. The exemption is the *difference* and not the document:
            // a leading zero has to be the whole of the disagreement, which is
            // what the rule checks by taking it out and asking both parsers
            // again. `fixed` is the rewrite, and its bytes are named in the
            // failure so a reader can see what the difference was.
            if (try isRecordedLeadingZeroDisagreement(
                scoped,
                mine,
                theirs,
                bytes,
                &scratch,
                &fixed,
            )) {
                leading_zero += 1;
            } else {
                std.debug.print(
                    "\ndifferential: a generated document disagrees\n" ++
                        "  document:     {s}\n  borrow reader: {s}\n" ++
                        "  std.json:      {s}\n  leading zero: {}\n" ++
                        "  without it:    {s}\n",
                    .{
                        escaped(bytes, &text),
                        if (mine) "accept" else "reject",
                        if (theirs) "accept" else "reject",
                        hasLeadingZero(bytes),
                        if (rewriteLeadingZeros(bytes, &fixed))
                            escaped(fixed[0..bytes.len], &without)
                        else
                            "(no leading zero)",
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
