//! Codec benchmark: a fixed corpus, a fixed workload and a real measurement.
//!
//! What is measured is a transformation with an explicit input buffer and
//! explicit output buffers, which is the boundary the data-oriented measurement
//! protocol asks for. The transport is not measured here: `bench_runtime` owns
//! the socket, and a number that mixed the two would describe neither.
//!
//! ## The entry point
//!
//! `pub fn run(io: std.Io, out: *std.Io.Writer, iterations: u32, samples: u32)
//! !void`. The caller owns the `Io`, so the clock and the output sink belong to
//! whoever runs the benchmark rather than to this module. The parameters are
//! `iterations` in `1..1000000` and `samples` in `1..64`, and the product is
//! bounded too. A request outside any of those is refused before a single byte
//! is written: a caller that passed an unchecked argument must not be left
//! holding a report that ends in a newline and reads like a result. The product
//! bound is enforced here as well as in the driver because `run` is a public
//! entry point and not every caller is that driver.
//!
//! ## The unit of work
//!
//! `iterations` counts **passes over the accepted corpus**: one iteration
//! decodes and encodes each accepted row once, in corpus order. One
//! **operation** is one accepted document through that path, so a run performs
//! `accepted_rows * iterations * samples` of them, and a byte sum taken over
//! one pass is a per-pass figure until it is divided by the rows in that pass.
//! The report names both units on their own lines — `iterations_unit` and
//! `ops_unit` — so a rate printed beside them cannot be read against a
//! denominator that is not written down.
//!
//! Nothing is written until the whole run has finished. The report is composed
//! in a fixed buffer and handed over in one write, so a failure anywhere — a
//! wrong refusal, an unresolvable clock — leaves the caller's sink untouched
//! rather than half filled.
//!
//! ## The corpus
//!
//! Ten literal rows fixed at compile time and listed in [`corpus`]. There is no
//! generation step and no seed, so two runs measure the same bytes and the
//! report can name them.
//!
//! | Row                     | Protocol | Shape                | Outcome |
//! | ----------------------- | -------- | -------------------- | ------- |
//! | `json.small`            | json     | `Walk`               | accept  |
//! | `json.escape_heavy`     | json     | `Walk`               | accept  |
//! | `a2a.message`           | a2a      | `Message`            | accept  |
//! | `a2a.get_task`          | a2a      | `GetTaskRequest`     | accept  |
//! | `mcp.tools_list`        | mcp      | `ToolListResult`     | accept  |
//! | `a2a.missing_id`        | a2a      | `GetTaskRequest`     | reject `MissingField`   |
//! | `a2a.trailing_document` | a2a      | `GetTaskRequest`     | reject `MalformedJson`  |
//! | `a2a.short_scratch`     | a2a      | `GetTaskRequest`     | reject `BufferTooSmall` |
//! | `a2a.invalid_utf8`      | a2a      | `GetTaskRequest`     | reject `InvalidUtf8`    |
//! | `a2a.truncated`         | a2a      | `GetTaskRequest`     | reject `Truncated`      |
//!
//! The byte counts and the per-row scratch demands are not written here: the
//! report prints both, measured from the literals this file holds, and a table
//! copied above it would be a second copy to keep right.
//!
//! The rows are a workload matrix rather than a sample: each one exists to make
//! a different cost visible. Four of them carry escapes, and that is the reason
//! the corpus is not all plain text — a corpus with no escape in it would
//! measure a memcpy this library never has to do.
//!
//! The two `json` rows are not a shaped message, because this library has no
//! shaped JSON message: they measure `json.Reader` and `json.Writer` directly.
//! [`Walk`] reads every member of the object, decoding each string into
//! scratch, and writes the pairs it read back as an object. The escape-heavy row
//! is therefore the writer's escaping path measured against the reader's
//! unescaping of the same documents, which is the cost that row exists for.
//!
//! The five rejected rows are all `GetTaskRequest` documents, one per
//! `DecodeError` member this corpus can provoke, so the refusal paths are
//! accounted for rather than excluded from the report for being inconvenient.
//!
//! ## The measured input
//!
//! A measured decode reads a copy of the row, not the literal. The literals are
//! compile-time constants, so a decoder handed one is a decoder the optimizer
//! may satisfy from `.rodata`: the lengths it returns, and the bytes this module
//! folds in after it, are both readable without running a parser. [`run`] copies
//! each accepted row once into [`Storage.inputs`], before any window opens, and
//! every decode after that — the oracle, the warm-up and the timed loop alike —
//! reads the copy. The copy is compared byte for byte against the literal
//! outside the clock, so `corpus_bytes` and `corpus_sha256` name the bytes the
//! measurement decoded rather than bytes it merely agrees with.
//!
//! The barrier at the top of [`acceptRow`] is what keeps that copy
//! load-bearing. It reads [`Storage`] whole, so the input is a runtime buffer
//! the compiler must read and the decode cannot be hoisted out of the loop that
//! iterates it.
//!
//! ## Storage
//!
//! Nothing here allocates, so the memory cost is a fixed set of buffers sized at
//! compile time and reported apart from the corpus, because they are a property
//! of the harness and not of the workload. The report separates three regions
//! rather than summing them into one line called peak memory, because they are
//! not one thing and none of them is a peak:
//!
//!   - `codec_storage_bytes` is [`storageBytes`]: every array of [`Storage`],
//!     which is where a decode writes its output, an encode writes its bytes and
//!     the measured input lives.
//!   - `report_buffer_bytes` is [`report_capacity`]: the buffer the report is
//!     composed in before it is handed to the caller in one write.
//!   - `window_array_bytes` is the two [`window_slots`]-entry arrays of
//!     nanosecond counts — the windows a run takes, and the copy it sorts to
//!     find the median — so a run's statistics cost is visible next to the
//!     buffers the codec cost is measured in.
//!
//! `harness_fixed_bytes` is the sum of those three: the whole fixed footprint
//! of `run` apart from the corpus literals, which are read-only data and not
//! storage. It excludes the run's remaining locals — the three accumulators,
//! the hash state, the accepted-row table and the encoded-length table —
//! which are hundreds of bytes beside the three above.
//!
//! Two scratch numbers are reported and they answer different questions.
//! `scratch_required_bytes` is what `json.Reader.requiredScratchLen` demands of
//! the widest accepted row: the capacity the harness allocates.
//! `scratch_used_bytes` is what a decode actually reached, found by asking for
//! the smallest window that still decodes ([`measureHighWater`]). Needed is
//! not the same as touched — the count is an upper bound for any one decoder
//! because it cannot know which members that decoder models — and a run whose
//! storage depended on `iterations` or `samples` would have allocated per
//! iteration, which would invalidate every number beside it.
//!
//! ## The timed region
//!
//! One iteration decodes and encodes each of the accepted rows in corpus order,
//! into the fixed storage, and folds the decoded fields and the encoded bytes
//! into an accumulator ([`Sink`]). Two memory barriers bracket that work, and
//! both name the buffers rather than a slice of them: handed a slice,
//! `std.mem.doNotOptimizeAway` clobbers the two words of the slice header and
//! none of the bytes behind it. The first reads [`Storage`] whole, so the
//! decode reads the runtime copy above and cannot be hoisted or folded against
//! the corpus. The second does the same after the encode, so the bytes a decode
//! and an encode wrote are observed, and neither the encoder nor the
//! unescaping that fed it is a store nothing reads.
//!
//! The fold reads a bounded number of bytes per call rather than walking the
//! encoded document a second time: a byte-at-a-time traversal is harness
//! accounting, and in a timed region it would be accounting the report would
//! then bill to the codec. It is reported as `work_sum`.
//!
//! Neither the barriers nor the sum is a proof of what the machine did, and
//! the report does not claim one. A barrier says the work has an observable
//! effect here. It cannot show that the compiler did not inline a parser, hoist
//! a loop or choose a different instruction sequence. A sum says that a run
//! which skipped a contribution would differ from this one, so a run that did
//! less work than the corpus requires is not reported as the same result; a run
//! that reached the same result by a cheaper route reports the same sum. On its
//! own a sum is a fingerprint of the results, not a count of the work behind
//! them.
//!
//! That sum is the timed region's alone. The oracle and the warm-up fold into
//! their own accumulators and are reported as `oracle_work_sum` and
//! `warmup_work_sum`, for two reasons that are the same reason: a `work_sum`
//! an untimed region contributed to could be non-zero for a timed region that
//! did nothing, and printing each region is what keeps the warm-up loop — whose
//! result nothing else reads — from being deleted in an optimised build while
//! the report still claims it ran.
//!
//! Outside the timed region, and only outside it:
//!
//!   - the corpus literals are hashed and counted,
//!   - every accepted row is copied once into the fixed input storage and that
//!     copy is compared byte for byte with the literal it came from,
//!   - every rejected row is decoded and must produce the exact `DecodeError`
//!     this file names,
//!   - every accepted row is decoded from that copy, its fields compared against
//!     values written by hand, encoded, decoded again, and compared again,
//!   - the scratch high-water of each accepted row is measured, and
//!   - the warm-up iterations run, and are reported as `warmup_iterations`.
//!
//! The clock is `io`'s: `clock.now(io)` with `const clock: Io.Clock = .awake`,
//! the same clock `bench_runtime` reads, so the two halves of one `bench` run
//! are on one timescale. A window is `start.durationTo(end).nanoseconds`, taken
//! honestly. A window the clock could not resolve is
//! `error.ClockResolutionTooCoarse` rather than a fabricated `1`: a zero window
//! becomes a divide-by-zero downstream, and reporting one as `1ns` would turn
//! that into a plausible number instead of a failure.
//!
//! ## Statistics
//!
//! `samples` windows of `iterations` passes each. `total_ns` is the sum of the
//! windows and nothing else — no warm-up, no oracle, no measurement of the
//! measurement. The byte figures are three totals of one pass and the run that
//! contains them, and they are printed in that order so the chain is legible
//! without arithmetic the reader has to trust:
//!
//!   - `decode_bytes_per_pass` and `encode_bytes_per_pass` are the sums over
//!     the accepted rows of one pass. One pass decodes every accepted document
//!     and encodes what it decoded, so these are what one pass costs. The
//!     decode sum counts the bytes the timed decodes were handed, which are
//!     the copies above and not the literals.
//!   - `decode_bytes_per_op`, `encode_bytes_per_op` and `bytes_per_op` are
//!     those sums divided by `corpus_accepted`, because an operation is one
//!     accepted document and not one pass over five of them. They are printed
//!     as decimals rather than truncated, so a corpus whose pass does not
//!     divide evenly reports the average it has instead of a whole number that
//!     is smaller than it.
//!   - `bytes_processed` is the pass total times `iterations` times `samples`,
//!     which is `bytes_per_op * ops` — the same figure `ns_per_op` and
//!     `throughput_mib_s` divide. A rate is therefore read against the
//!     denominator printed next to it, and no number here is a count of work
//!     the run did not do.
//!
//! The raw windows are printed rather than kept: a caller that wants its own
//! percentile has the numbers, and nothing here allocates a vector
//! proportional to `samples`. The median is the middle window of the sorted
//! vector, so for an even sample count it is the upper of the two middles.
//!
//! ## Report
//!
//! One `key=value` per line. The workload block comes first and is a function
//! of the corpus alone; the measurement block follows and is the only part that
//! may differ between two runs of the same corpus. The units a number is in
//! are printed beside the number — `iterations_unit` says what one iteration
//! is and `ops_unit` says what one operation is — because a throughput figure
//! whose denominator is defined only in this file's comments is a figure
//! nobody can check against the report they are holding.
//!
//! These are scoped synthetic numbers for one build, one target and one
//! machine — a baseline for a later candidate measured the same way, not a
//! claim about the library on any other host, and no result from here is a
//! claim about MCP or A2A peer behaviour.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zig-agent-proto");

const json = proto.json;
const a2a = proto.a2a;
const mcp = proto.mcp;

const Self = @This();
const testing = std.testing;

/// Corpus passes one window may ask for.
pub const max_iterations: u32 = 1_000_000;

/// Windows one run may ask for.
pub const max_samples: u32 = 64;

/// Windows the fixed sample array holds.
const window_slots: usize = 64;

/// Timed passes the whole measured run may ask for.
///
/// The same bound the driver applies, enforced again here because
/// `iterations * samples` is the one product a caller can get wrong without
/// noticing from either number on its own. The product counts passes over the
/// corpus and the windows those passes were timed in, not operations: one pass
/// touches every accepted row once, so a run at this bound performs
/// `max_measured_ops * corpus_accepted` document operations.
pub const max_measured_ops: u64 = 1_000_000;

/// Corpus passes run and thrown away before the first window opens.
pub const warmup_iterations: u32 = 16;

/// The clock every timestamp here comes from.
///
/// `awake` is `CLOCK_MONOTONIC` on Linux, so consecutive reads never go
/// backwards and every subtraction below is a duration and not an accident.
pub const clock: std.Io.Clock = .awake;

/// The refusals this module itself produces.
///
/// A codec error inside the oracle or the timed loop keeps its own identity and
/// is not funnelled through one of these, because which `DecodeError` a corpus
/// row provoked is part of what the report says about the corpus.
pub const Error = error{
    /// `iterations` is zero or above [`max_iterations`].
    BadIterations,
    /// `samples` is zero or above [`max_samples`].
    BadSamples,
    /// `iterations * samples` is above [`max_measured_ops`].
    WorkTooLarge,
    /// A timed window came back zero-length, so the clock cannot resolve this
    /// workload. The run's repair is more iterations, not a smaller number.
    ClockResolutionTooCoarse,
    /// A decoded field was not the value this file writes beside the row, or
    /// the run's copy of a row is not that row's bytes.
    FieldMismatch,
    /// A rejected row decoded, or was refused with another error than the one
    /// its corpus row names.
    RejectionMismatch,
};

/// Which decoder a row is measured through.
///
/// The protocol name the report prints comes from here rather than from a
/// second column, because two columns describing one row is one column too
/// many.
const Kind = enum {
    /// The `json` reader and writer, over an object of members.
    json_walk,
    /// `a2a.Message`.
    a2a_message,
    /// `a2a.GetTaskRequest`.
    a2a_request,
    /// `mcp.ToolListResult`.
    mcp_tool_list,
    /// A row the corpus expects to be refused. Every such row is a
    /// `GetTaskRequest` document.
    refusal,

    fn protocol(self: Kind) []const u8 {
        return switch (self) {
            .json_walk => "json",
            .a2a_message, .a2a_request, .refusal => "a2a",
            .mcp_tool_list => "mcp",
        };
    }
};

/// One corpus row.
const Row = struct {
    /// The name the report prints. Unique across the corpus.
    name: []const u8,
    /// Which decoder the row is measured through.
    kind: Kind,
    /// The literal document. Fixed at compile time; nothing generates it.
    bytes: []const u8,
    /// Whether the corpus expects this row to decode.
    accept: bool,
    /// `none` for an accepted row, otherwise the exact `DecodeError` member
    /// the row must be refused with.
    expected_error: []const u8,
    /// A deliberate window narrower than the row needs, for the row whose point
    /// is that `BufferTooSmall` is a refusal and not a truncated string. Null
    /// means the row is decoded with the harness's own scratch.
    scratch_override: ?usize = null,
};

/// The workload.
///
/// The accepted rows cover three protocol families, a small working set and an
/// escape-heavy one, and one document per family that exercises the shapes a
/// real peer sends rather than the shape a unit test picks.
const corpus = [_]Row{
    .{
        .name = "json.small",
        .kind = .json_walk,
        // No escape anywhere, so the string path borrows the input and the
        // scratch is untouched. This is the small row: fixed cost only.
        .bytes = "{\"type\":\"object\",\"title\":\"WeatherQuery\",\"required\":[\"city\",\"zip\"]}",
        .accept = true,
        .expected_error = "none",
    },
    .{
        .name = "json.escape_heavy",
        .kind = .json_walk,
        // The adversarial row. Every escape form the reader defines appears
        // here: the five shorthands, a quote, a backslash, a solidus, a control
        // character that only a `\u` escape can spell, a non-ASCII scalar, and
        // a surrogate pair. An empty string sits beside them so the zero-length
        // case is measured next to the worst one.
        .bytes = "{\"note\":\"line1\\nline2\\ttab \\\"quoted\\\" back\\\\slash \\u0001bell caf\\u00e9\"," ++
            "\"emoji\":\"\\ud83d\\ude80 rocket\",\"slash\":\"a\\/b\",\"empty\":\"\",\"plain\":\"no escapes\"}",
        .accept = true,
        .expected_error = "none",
    },
    .{
        .name = "a2a.message",
        .kind = .a2a_message,
        // The typical A2A row. All eight `Message` members are present, and
        // `parts` carries one member of each `PartContent` arm: text with
        // escapes, five raw bytes as canonical base64, and a `data` lexeme
        // that must survive the round trip as the exact bytes it arrived as.
        .bytes = "{\"messageId\":\"msg-1\",\"contextId\":\"ctx-1\",\"taskId\":\"task-1\"," ++
            "\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"line1\\nline2 \\\"quoted\\\" back\\\\slash\"}," ++
            "{\"raw\":\"AAECAwQ=\"},{\"data\":{\"k\":[1,2,3]}}]," ++
            "\"metadata\":{\"m\":1},\"extensions\":[\"https://a.example.com/x\"," ++
            "\"https://b.example.com/y\"],\"referenceTaskIds\":[\"task-0\"]}",
        .accept = true,
        .expected_error = "none",
    },
    .{
        .name = "a2a.get_task",
        .kind = .a2a_request,
        // Every member of the smallest A2A request, so the presence rules for
        // an optional tenant and an optional page-bound integer are measured
        // rather than assumed.
        .bytes = "{\"tenant\":\"acme\",\"id\":\"task-1\",\"historyLength\":10}",
        .accept = true,
        .expected_error = "none",
    },
    .{
        .name = "mcp.tools_list",
        .kind = .mcp_tool_list,
        // The typical MCP row: a `ListToolsResult` with the caching members
        // that are required, a cursor, two tools, a `_meta`, and a member no
        // shape names, which arrives in the verbatim store rather than being
        // dropped. The description carries a quote and a newline.
        .bytes = "{\"resultType\":\"complete\",\"ttlMs\":60000,\"cacheScope\":\"public\"," ++
            "\"nextCursor\":\"c2\",\"tools\":[{\"name\":\"echo\"," ++
            "\"inputSchema\":{\"type\":\"object\"}," ++
            "\"description\":\"says it \\\"back\\\"\\n\"}," ++
            "{\"name\":\"rev\",\"inputSchema\":{\"type\":\"object\"," ++
            "\"properties\":{\"text\":{\"type\":\"string\"}}}}]," ++
            "\"_meta\":{\"a\":1},\"note\":\"hi\"}",
        .accept = true,
        .expected_error = "none",
    },
    .{
        .name = "a2a.missing_id",
        .kind = .refusal,
        // `id` is REQUIRED and `tenant` is not, so this is the refusal that
        // cannot be mistaken for an absent optional.
        .bytes = "{\"tenant\":\"acme\"}",
        .accept = false,
        .expected_error = "MissingField",
    },
    .{
        .name = "a2a.trailing_document",
        .kind = .refusal,
        // A valid body with a second document behind it. Accepting this and
        // re-encoding the first half is the whole defect, so it is a row.
        .bytes = "{\"id\":\"task-1\"} tail",
        .accept = false,
        .expected_error = "MalformedJson",
    },
    .{
        .name = "a2a.short_scratch",
        .kind = .refusal,
        // Decoded through a one-byte window on purpose. The five bytes the
        // escaped tenant needs are this row's declared scratch, and the run
        // must see `BufferTooSmall` rather than a truncated string.
        .bytes = "{\"tenant\":\"caf\\u00e9\",\"id\":\"task-1\"}",
        .accept = false,
        .expected_error = "BufferTooSmall",
        .scratch_override = 1,
    },
    .{
        .name = "a2a.invalid_utf8",
        .kind = .refusal,
        // A stray continuation byte inside a JSON string. The grammar allows
        // the byte, so this is `InvalidUtf8` and not a syntax error, and a
        // decoder that reported it as malformed would be reporting an encoding
        // fault against a well-formed byte.
        .bytes = "{\"tenant\":\"caf\xff\",\"id\":\"task-1\"}",
        .accept = false,
        .expected_error = "InvalidUtf8",
    },
    .{
        .name = "a2a.truncated",
        .kind = .refusal,
        // The document stops inside a string value. This is the refusal that
        // must not be `MalformedJson`: the prefix so far was well formed.
        .bytes = "{\"tenant\":\"acme\",\"id\":\"tas",
        .accept = false,
        .expected_error = "Truncated",
    },
};

/// The accepted rows, in corpus order. One iteration touches each of them.
const accepted_rows = blk: {
    var count: usize = 0;
    for (corpus) |row| {
        if (row.accept) count += 1;
    }
    break :blk count;
};

/// Bytes the widest accepted row's copy takes.
///
/// A measured decode reads a copy of its row rather than the literal, and every
/// copy is as wide as the widest accepted row so one fixed array of them holds
/// the whole measured input. Sized from the corpus at compile time, like every
/// other capacity here, and for the same reason: a buffer that grew at run time
/// would have to be allocated per iteration.
const input_capacity = blk: {
    var widest: usize = 0;
    for (corpus) |row| {
        if (row.accept) widest = @max(widest, row.bytes.len);
    }
    // A corpus with no accepted row would make this zero, and a zero-length
    // array is not a useful declaration of nothing.
    break :blk if (widest == 0) 1 else widest;
};

/// One accepted row, paired with the runtime bytes a measured decode reads.
///
/// `slot` is this run's own copy of the row and `len` is how many bytes of that
/// copy the document occupies, so the timed loop, the byte totals and the
/// report all name one buffer rather than the literal beside it.
const Accepted = struct {
    row: *const Row,
    slot: *const [input_capacity]u8,
    len: usize,
};

/// The capacity the harness allocates: the widest accepted row's demand.
const scratch_capacity = blk: {
    // `requiredScratchLen` is a whole-document walk, so the ten literals are
    // more branches than the default comptime budget allows.
    @setEvalBranchQuota(100_000);
    var widest: usize = 0;
    for (corpus) |row| {
        if (row.accept) widest = @max(widest, json.Reader.requiredScratchLen(row.bytes));
    }
    // Zero would be a legal size for a corpus with no escapes at all, and a
    // zero-length array is not a useful declaration of that.
    break :blk if (widest == 0) 1 else widest;
};

/// Bytes one encoded body may take.
const out_capacity = 4096;

/// Bytes `Part.raw` re-encoding may take. The widest row in the corpus carries
/// five raw bytes, so this is slack rather than a bound anybody measured.
const base64_capacity = 512;

/// `ContentArena` capacity for the parts `a2a.message` spells, plus slack.
const parts_capacity = 8;

/// `ContentArena` capacity for artifacts no row spells, kept small because a
/// number nobody needs is memory nobody should pay for.
const artifacts_capacity = 2;

/// `ContentArena` capacity for messages a task-shaped document would hold.
const messages_capacity = 8;

/// `ContentArena` capacity for every repeated string in the corpus: the two
/// extension URIs, the reference task id and the slack beside them.
const strings_capacity = 16;

/// `ContentArena` capacity for decoded `Part.raw` bytes.
const arena_bytes_capacity = 512;

/// `mcp.Tool` capacity for `mcp.tools_list` and its slack.
const tools_capacity = 8;

/// `mcp.VerbatimMember` capacity for the members no shape names: the tool
/// description and the result's own `note`.
const verbatim_capacity = 32;

/// The report this module writes, at its longest.
///
/// Sixty-four windows and ten rows is the most this can produce; the buffer is
/// sized from that rather than grown, because a benchmark that allocates for
/// its own output has already started measuring something else.
const report_capacity = 16 * 1024;

/// The fixed storage one run reads and writes.
///
/// Every array is sized above and none of them grows with `iterations` or
/// `samples`, which is what makes a per-iteration allocation impossible rather
/// than merely absent.
const Storage = struct {
    /// One copy of each accepted row, in corpus order, and the only input a
    /// measured decode reads. Filled once, before the first window opens; the
    /// literals stay where they are, in read-only data.
    inputs: [accepted_rows][input_capacity]u8,
    scratch: [scratch_capacity]u8,
    out: [out_capacity]u8,
    /// The second encode of the untimed round trip. It is separate from `out`
    /// so the oracle can decode the document `out` holds while writing the
    /// re-encoding of it.
    roundtrip: [out_capacity]u8,
    base64: [base64_capacity]u8,
    arena_parts: [parts_capacity]a2a.Part,
    arena_artifacts: [artifacts_capacity]a2a.Artifact,
    arena_messages: [messages_capacity]a2a.Message,
    arena_strings: [strings_capacity][]const u8,
    arena_bytes: [arena_bytes_capacity]u8,
    tools: [tools_capacity]mcp.Tool,
    verbatim: [verbatim_capacity]mcp.VerbatimMember,

    fn arena(self: *Storage) a2a.ContentArena {
        return a2a.ContentArena.init(
            &self.arena_parts,
            &self.arena_artifacts,
            &self.arena_messages,
            &self.arena_strings,
            &self.arena_bytes,
        );
    }
};

/// The byte total of the arrays above: what a measured decode reads and writes,
/// and what an encode writes into.
///
/// Taken with `@sizeOf` rather than written out, because a hand-copied layout
/// table is a number that rots. The sum is over the arrays and not over
/// `@sizeOf(Storage)`, so the padding between them is not charged to a caller
/// as though it were usable. The report prints it as `codec_storage_bytes`,
/// which is the name that says what it includes: [`Storage`] and nothing else.
fn storageBytes() usize {
    return @sizeOf([accepted_rows][input_capacity]u8) +
        @sizeOf([scratch_capacity]u8) +
        @sizeOf([out_capacity]u8) +
        @sizeOf([out_capacity]u8) +
        @sizeOf([base64_capacity]u8) +
        @sizeOf([parts_capacity]a2a.Part) +
        @sizeOf([artifacts_capacity]a2a.Artifact) +
        @sizeOf([messages_capacity]a2a.Message) +
        @sizeOf([strings_capacity][]const u8) +
        @sizeOf([arena_bytes_capacity]u8) +
        @sizeOf([tools_capacity]mcp.Tool) +
        @sizeOf([verbatim_capacity]mcp.VerbatimMember);
}

/// The byte total of the sample arrays: the windows a run took and the copy it
/// sorted to find the median.
///
/// Reported apart from [`storageBytes`] because statistics are not codec
/// storage, and a reader comparing two harnesses would otherwise be comparing
/// a buffer against a counter.
fn windowBytes() usize {
    return 2 * @sizeOf([window_slots]u64);
}

/// Every fixed buffer `run` holds: the codec storage, the report buffer and the
/// sample arrays.
///
/// This is a footprint and not a peak: nothing here is allocated, freed or
/// grown, so the bytes are the same for a run of one pass and a run of a
/// million. It excludes the corpus literals, which are read-only data, and the
/// run's other locals, which are hundreds of bytes beside these three.
fn harnessBytes() usize {
    return storageBytes() + report_capacity + windowBytes();
}

/// What a run folds its results into, one accumulator per region.
///
/// A fold reads the bytes a decode produced and an encode wrote, which is what
/// stops the optimizer deleting work whose result nothing else looks at, and
/// what makes a run that did less work than it claims visible rather than
/// merely faster. What it does *not* do is walk them: the fold reads at most
/// [`sampled_bytes`] bytes per call whatever the slice is, because a
/// byte-at-a-time pass over the encoded document charged `ns_per_op` for a
/// second traversal of data the codec had just written, and at one dependent
/// add per byte that accounting was a measurable part of what the report
/// called codec work.
///
/// The bytes are read from the slice rather than summarised from its length,
/// so the decoded fields and the encoded document are consumed where they
/// are, and the sampled bytes are spread across each slice so a decode cannot
/// satisfy them from one corner of its output.
///
/// The three accumulators are kept apart — see [`run`] — so `work_sum` is the
/// timed work and nothing else.
const Sink = struct {
    /// Bytes one fold reads at most, whatever the slice length.
    const sampled_bytes = 8;

    sum: u64 = 0,

    /// Mix one slice in: its length, and at most [`sampled_bytes`] of its bytes.
    ///
    /// The stride rounds up, so the reads land at even spacing across the slice
    /// and the loop takes at most `sampled_bytes` steps whatever the length. A
    /// stride that rounded down would read a slice shorter than twice the
    /// sample count whole — fifteen reads for a fifteen-byte slice against a
    /// bound of eight — and the count of reads would be a property of the
    /// document rather than of this fold.
    fn fold(self: *Sink, bytes: []const u8) void {
        self.mix(bytes.len);
        if (bytes.len == 0) return;
        const stride = (bytes.len - 1) / sampled_bytes + 1;
        var at: usize = 0;
        while (at < bytes.len) : (at += stride) {
            self.sum +%= bytes[at];
        }
    }

    fn mix(self: *Sink, value: u64) void {
        self.sum = self.sum *% 0x9e37_79b9_7f4a_7c15 +% value;
    }
};

/// The `json` rows: an object's member pairs, read and written back.
///
/// The keys and values are borrowed from the document or from scratch, so the
/// struct holds slices and never copies. Eight members is the corpus's widest
/// row with room to spare; a document with more is `error.BufferTooSmall` rather
/// than a walk that quietly drops the tail.
const Walk = struct {
    // SAFETY: `decode` zeroes `count` first and writes `keys[at]` before `count` grows past it.
    keys: [8][]const u8 = undefined,
    // SAFETY: `decode` assigns `values[at]` in the same step as `keys[at]`, and `encode` reads `at < count`.
    values: [8][]const u8 = undefined,
    count: usize = 0,

    fn decode(raw: []const u8, scratch: []u8, out: *Walk) !void {
        var reader = json.Reader.init(raw);
        out.* = .{};
        if (try reader.beginObject()) return error.MissingField;
        while (try reader.nextKey(scratch)) |key| {
            if (out.count == out.keys.len) return error.BufferTooSmall;
            const at = out.count;
            out.keys[at] = key;
            reader.skipWhitespace();
            if (reader.peek() == @as(?u8, '"')) {
                out.values[at] = try reader.string(scratch);
            } else {
                // A member this walk does not model is consumed and recorded
                // as empty, so the encode below is the inverse of the decode
                // rather than a document that silently lost a member.
                try reader.skipValue(scratch);
                out.values[at] = "";
            }
            out.count += 1;
        }
        if (!reader.atEnd()) return error.MalformedJson;
    }

    fn encode(self: Walk, writer: *json.Writer) !void {
        try writer.byte('{');
        for (self.keys[0..self.count], 0..) |key, at| {
            if (at != 0) try writer.byte(',');
            try writer.string(key);
            try writer.byte(':');
            try writer.string(self.values[at]);
        }
        try writer.byte('}');
    }
};

// --- The oracle -----------------------------------------------------------------

fn expect(condition: bool) Error!void {
    if (!condition) return error.FieldMismatch;
}

fn expectCount(got: usize, want: usize) Error!void {
    try expect(got == want);
}

fn expectText(got: []const u8, want: []const u8) Error!void {
    try expect(std.mem.eql(u8, got, want));
}

fn expectMember(got: ?[]const u8, want: []const u8) Error!void {
    try expectText(got orelse return error.FieldMismatch, want);
}

fn expectAbsent(got: ?[]const u8) Error!void {
    try expect(got == null);
}

fn expectBytes(got: []const u8, want: []const u8) Error!void {
    try expectCount(got.len, want.len);
    for (got, want) |left, right| try expect(left == right);
}

/// What `members` carried under `key`, or null when it carried nothing.
fn verbatimText(members: []const mcp.VerbatimMember, key: []const u8) ?[]const u8 {
    for (members) |member| {
        if (std.mem.eql(u8, member.key, key)) return member.value;
    }
    return null;
}

/// Decode one accepted row and hold it to the values this file writes beside it.
///
/// This runs outside every timed window. A codec that drifted, a field that
/// arrived empty and an escape that decoded wrongly are all reported here as a
/// failure rather than as a number.
fn checkAccepted(row: Row, raw: []const u8, scratch: []u8, st: *Storage) !void {
    switch (row.kind) {
        .json_walk => {
            var walk: Walk = .{};
            try Walk.decode(raw, scratch, &walk);
            if (std.mem.eql(u8, row.name, "json.small")) {
                try expectCount(walk.count, 3);
                try expectText(walk.keys[0], "type");
                try expectText(walk.values[0], "object");
                try expectText(walk.keys[1], "title");
                try expectText(walk.values[1], "WeatherQuery");
                try expectText(walk.keys[2], "required");
                // The array member is stepped over rather than modelled, so it
                // comes back as the empty string the decode recorded. A codec
                // that grew an arm for it would fail here, which is the point:
                // this row measures the reader, not a schema.
                try expectText(walk.values[2], "");
            } else {
                try expectCount(walk.count, 5);
                try expectText(walk.keys[0], "note");
                try expectText(walk.values[0], "line1\nline2\ttab \"quoted\" back\\slash \x01bell caf\xc3\xa9");
                try expectText(walk.keys[1], "emoji");
                try expectText(walk.values[1], "\xf0\x9f\x9a\x80 rocket");
                try expectText(walk.keys[2], "slash");
                try expectText(walk.values[2], "a/b");
                try expectText(walk.keys[3], "empty");
                try expectText(walk.values[3], "");
                try expectText(walk.keys[4], "plain");
                try expectText(walk.values[4], "no escapes");
            }
        },
        .a2a_message => {
            var arena = st.arena();
            const message = try a2a.decodeMessage(raw, &arena, scratch);
            try expectText(message.message_id, "msg-1");
            try expectMember(message.context_id, "ctx-1");
            try expectMember(message.task_id, "task-1");
            try expect(message.role == .user);
            try expectCount(message.parts.len, 3);
            try expectText(message.parts[0].content.text, "line1\nline2 \"quoted\" back\\slash");
            try expectBytes(message.parts[1].content.raw, "\x00\x01\x02\x03\x04");
            try expectBytes(message.parts[2].content.data, "{\"k\":[1,2,3]}");
            try expectMember(message.metadata, "{\"m\":1}");
            const extensions = message.extensions orelse return error.FieldMismatch;
            try expectCount(extensions.len, 2);
            try expectText(extensions[0], "https://a.example.com/x");
            try expectText(extensions[1], "https://b.example.com/y");
            const references = message.reference_task_ids orelse return error.FieldMismatch;
            try expectCount(references.len, 1);
            try expectText(references[0], "task-0");
        },
        .a2a_request => {
            const request = try a2a.decodeGetTaskRequest(raw, scratch);
            try expectMember(request.tenant, "acme");
            try expectText(request.id, "task-1");
            const history_length = request.history_length orelse return error.FieldMismatch;
            try expect(history_length == 10);
        },
        .mcp_tool_list => {
            const list = try mcp.decodeToolListResult(raw, &st.tools, &st.verbatim, scratch);
            try expectMember(list.result_type.value, "complete");
            try expect(list.cacheable.ttl_ms == 60000);
            try expect(list.cacheable.cache_scope == .public);
            try expectMember(list.page.next_cursor, "c2");
            try expectMember(list.meta, "{\"a\":1}");
            try expectCount(list.tools.len, 2);
            try expectText(list.tools[0].name, "echo");
            try expectBytes(list.tools[0].input_schema, "{\"type\":\"object\"}");
            // A verbatim member is the raw lexeme, so a string keeps its quotes
            // and its escapes: the value here is what the wire wrote, not a
            // decoded sentence.
            try expectText(verbatimText(list.tools[0].verbatim, "description") orelse
                return error.FieldMismatch, "\"says it \\\"back\\\"\\n\"");
            try expectText(list.tools[1].name, "rev");
            // The second tool declares no member this shape does not model, so
            // it carries nothing in the verbatim region rather than a
            // placeholder for a member the document never had.
            try expectAbsent(verbatimText(list.tools[1].verbatim, "description"));
            try expectText(verbatimText(list.verbatim, "note") orelse
                return error.FieldMismatch, "\"hi\"");
        },
        .refusal => unreachable, // `checkAccepted` is never called for one.
    }
}

/// Decode one rejected row and hold it to the exact refusal its row names.
fn checkRefusal(row: Row, st: *Storage) Error!void {
    const window = row.scratch_override orelse scratch_capacity;
    const outcome = a2a.decodeGetTaskRequest(row.bytes, st.scratch[0..window]);
    const name = if (outcome) |_| "accepted" else |err| @errorName(err);
    if (!std.mem.eql(u8, name, row.expected_error)) return error.RejectionMismatch;
}

// --- The timed region ------------------------------------------------------------

/// Decode and encode one accepted row, folding both sides into `sink`.
///
/// Nothing here generates input, hashes, allocates or checks. The input is the
/// run's own copy of the row ([`Storage.inputs`]), so there is nothing to
/// generate and nothing the compiler can satisfy from a literal, and the sink
/// is the only reader of the result.
///
/// The two barriers are the instrumentation, and they name [`Storage`] rather
/// than a slice of it: `std.mem.doNotOptimizeAway` handed a slice would clobber
/// the two words of the slice header and none of the bytes behind them. Each is
/// an empty assembly statement that reads the whole storage object and clobbers
/// memory, so it costs no instructions and it tells the compiler that the
/// buffers are read. Before the work it is also what stops the decode from
/// being hoisted out of the loop that iterates it.
fn acceptRow(
    kind: Kind,
    raw: []const u8,
    scratch: []u8,
    st: *Storage,
    writer: *json.Writer,
    sink: *Sink,
) !void {
    // Read the storage before the work: the input bytes are runtime values, not
    // the literal this row was copied from, and the decode cannot be lifted out
    // of the loop that iterates it.
    std.mem.doNotOptimizeAway(st);

    switch (kind) {
        .json_walk => {
            var walk: Walk = .{};
            try Walk.decode(raw, scratch, &walk);
            for (walk.keys[0..walk.count], walk.values[0..walk.count]) |key, value| {
                sink.fold(key);
                sink.fold(value);
            }
            try walk.encode(writer);
        },
        .a2a_message => {
            var arena = st.arena();
            const message = try a2a.decodeMessage(raw, &arena, scratch);
            sink.fold(message.message_id);
            sink.mix(@intCast(message.parts.len));
            for (message.parts) |part| switch (part.content) {
                .text => |text| sink.fold(text),
                .raw => |decoded| sink.fold(decoded),
                .url => |url| sink.fold(url),
                .data => |data| sink.fold(data),
            };
            sink.mix(@intFromEnum(message.role));
            try a2a.encodeMessage(message, writer, &st.base64);
        },
        .a2a_request => {
            const request = try a2a.decodeGetTaskRequest(raw, scratch);
            // The fields themselves rather than their lengths: a length is a
            // number a reader could return without looking at the bytes, and
            // the optional tenant is the member this shape may go without.
            sink.fold(request.tenant orelse "");
            sink.fold(request.id);
            sink.mix(@intCast((request.history_length orelse 0) + 1));
            try a2a.encodeGetTaskRequest(request, writer);
        },
        .mcp_tool_list => {
            const list = try mcp.decodeToolListResult(raw, &st.tools, &st.verbatim, scratch);
            sink.mix(@intCast(list.tools.len));
            sink.mix(list.cacheable.ttl_ms);
            for (list.tools) |tool| {
                sink.fold(tool.name);
                sink.fold(tool.input_schema);
            }
            try mcp.encodeToolListResult(list, writer);
        },
        .refusal => unreachable, // A refusal is never in the timed region.
    }
    sink.fold(writer.written());
    // Read the storage again: every byte a decode wrote and every byte an
    // encode wrote lives in it, so this is what keeps those stores observable
    // and stops the encoder, and the unescaping that fed it, from being deleted
    // as writes nothing reads.
    std.mem.doNotOptimizeAway(st);
}

/// The smallest `scratch` window `row` still decodes through.
///
/// Bisected rather than read out of the reader, because the reader that performs
/// the decode is the one the protocol codecs own and this module has no handle
/// on its high-water mark. Success needs `len >= bump` at every step and the
/// bump only grows, so the smallest window that decodes is the high-water mark
/// itself. Runs outside every timed window: it is a measurement, not work.
fn measureHighWater(row: Row, raw: []const u8, st: *Storage) !usize {
    // The accumulator is discarded here and deliberately: what this bisection
    // observes is whether each narrower window decoded, and that branch is
    // what keeps the decode alive. A fold would only be a second consumer of
    // untimed work.
    var discarded: Sink = .{};
    var writer = json.Writer.init(&st.out);
    var high = json.Reader.requiredScratchLen(raw);
    var low: usize = 0;
    while (low < high) {
        const middle = low + (high - low) / 2;
        writer.len = 0;
        const decoded = acceptRow(row.kind, raw, st.scratch[0..middle], st, &writer, &discarded);
        if (decoded) |_| {
            high = middle;
        } else |_| {
            low = middle + 1;
        }
    }
    return low;
}

// --- The entry point -------------------------------------------------------------

/// Refuse a workload the fixed arrays and the run budget cannot hold.
fn checkArgs(iterations: u32, samples: u32) Error!void {
    if (iterations == 0 or iterations > max_iterations) return error.BadIterations;
    if (samples == 0 or samples > max_samples) return error.BadSamples;
    if (@as(u64, iterations) * samples > max_measured_ops) return error.WorkTooLarge;
}

/// Sort the raw windows in place, so the median is the middle of a real vector
/// rather than a running guess.
fn sortWindows(windows: []u64) void {
    for (1..windows.len) |at| {
        const value = windows[at];
        var hole = at;
        while (hole > 0 and windows[hole - 1] > value) : (hole -= 1) {
            windows[hole] = windows[hole - 1];
        }
        windows[hole] = value;
    }
}

const hex_alphabet = "0123456789abcdef";

/// The lowercase hex of `bytes`.
///
/// `std.fmt.fmtSliceHexLower` is gone in 0.16.0, and the digest has to be
/// rendered the same way here and in the report.
fn hexLower(bytes: []const u8, out: []u8) []const u8 {
    var used: usize = 0;
    for (bytes) |byte| {
        out[used] = hex_alphabet[byte >> 4];
        out[used + 1] = hex_alphabet[byte & 0x0f];
        used += 2;
    }
    return out[0..used];
}

/// Run the benchmark and write one report.
pub fn run(io: std.Io, out: *std.Io.Writer, iterations: u32, samples: u32) !void {
    try checkArgs(iterations, samples);

    // SAFETY: every array is written before it is read; the arenas and store start at zero.
    var st: Storage = undefined;
    // Three accumulators, one per region, because a mixed one would report a
    // `work_sum` that a timed loop doing nothing at all could still satisfy
    // from untimed folds. `sink` is the timed region alone; the oracle's and
    // the warm-up's are printed under their own names.
    var sink: Sink = .{};
    var oracle: Sink = .{};

    // The untimed pass. Nothing below is measured, and everything it proves is
    // needed before a number may be printed.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var corpus_bytes: u64 = 0;
    var decode_bytes: u64 = 0;
    var encoded_lengths: [accepted_rows]u64 = undefined;
    var accepted: [accepted_rows]Accepted = undefined;
    var scratch_required: usize = 0;
    var scratch_used: usize = 0;

    var accepted_len: usize = 0;
    for (corpus, 0..) |row, at| {
        hasher.update(row.bytes);
        corpus_bytes += @intCast(row.bytes.len);
        if (!row.accept) {
            try checkRefusal(row, &st);
            continue;
        }
        try expect(std.mem.eql(u8, row.expected_error, "none"));

        // Copy the row once, into storage this run owns, and hold the copy to
        // the literal byte for byte. Every decode below reads that copy — the
        // oracle, the warm-up and the timed loop alike — so a copy that was
        // short, stale or overwritten fails the run here rather than measuring
        // a corpus the report does not name.
        const slot = &st.inputs[accepted_len];
        const input = slot[0..row.bytes.len];
        @memcpy(input, row.bytes);
        try expectBytes(input, row.bytes);

        // Decode the copy, check it, encode it, decode the encoding, and check
        // that too. The second encode goes to a separate buffer so the document
        // being decoded is not overwritten under the reader.
        try checkAccepted(row, input, &st.scratch, &st);
        var first = json.Writer.init(&st.out);
        try acceptRow(row.kind, input, &st.scratch, &st, &first, &oracle);
        const encoded = st.out[0..first.len];
        var second = json.Writer.init(&st.roundtrip);
        try acceptRow(row.kind, encoded, &st.scratch, &st, &second, &oracle);
        try checkAccepted(row, encoded, &st.scratch, &st);

        accepted[accepted_len] = .{ .row = &corpus[at], .slot = slot, .len = input.len };
        encoded_lengths[accepted_len] = first.len;
        accepted_len += 1;
        // The byte totals count what the timed decodes were handed, so a figure
        // here cannot describe a corpus other than the measured one.
        decode_bytes += @intCast(input.len);
        scratch_required = @max(scratch_required, json.Reader.requiredScratchLen(input));
        scratch_used = @max(scratch_used, try measureHighWater(row, input, &st));
    }
    try expect(scratch_used <= scratch_required);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var digest_hex: [64]u8 = undefined;
    const corpus_sha256 = hexLower(&digest, &digest_hex);

    // The warm-up pays the first page faults and the frequency ramp, and no
    // window contains it. Its own accumulator is reported as
    // `warmup_work_sum`, which is also what keeps it from being optimized away:
    // a sum nothing reads would let the whole loop be deleted while the report
    // still claimed the warm-up ran.
    var warm: Sink = .{};
    for (0..warmup_iterations) |_| {
        for (accepted[0..accepted_len]) |entry| {
            var writer = json.Writer.init(&st.out);
            try acceptRow(entry.row.kind, entry.slot[0..entry.len], &st.scratch, &st, &writer, &warm);
        }
    }

    var windows: [window_slots]u64 = undefined;
    for (0..samples) |at| {
        const start = clock.now(io);
        for (0..iterations) |_| {
            for (accepted[0..accepted_len]) |entry| {
                var writer = json.Writer.init(&st.out);
                try acceptRow(entry.row.kind, entry.slot[0..entry.len], &st.scratch, &st, &writer, &sink);
            }
        }
        const end = clock.now(io);
        const elapsed = start.durationTo(end).nanoseconds;
        // A window the clock could not resolve is reported as the failure it
        // is. Rounding it up to `1` would turn a divide-by-zero into a
        // plausible number.
        if (elapsed <= 0) return error.ClockResolutionTooCoarse;
        windows[at] = @intCast(elapsed);
    }

    const count: usize = samples;
    var encode_bytes: u64 = 0;
    for (encoded_lengths) |length| encode_bytes += length;

    // `decode_bytes` and `encode_bytes` are each a sum over one pass over the
    // accepted rows, and an operation is one accepted document rather than one
    // pass over all of them. So a per-operation byte figure divides the pass
    // sum by the rows that pass covered, and the run's byte total is the pass
    // sum scaled by the passes and windows that ran it — which is exactly
    // `bytes_per_op * ops`, because `ops` counts those same documents.
    const pass_bytes = decode_bytes + encode_bytes;
    const rows: f64 = @floatFromInt(accepted_rows);
    const ops = @as(u64, accepted_rows) * iterations * samples;
    const decode_bytes_per_op = @as(f64, @floatFromInt(decode_bytes)) / rows;
    const encode_bytes_per_op = @as(f64, @floatFromInt(encode_bytes)) / rows;
    const bytes_per_op = decode_bytes_per_op + encode_bytes_per_op;
    const bytes_processed = pass_bytes * @as(u64, iterations) * samples;

    var total_ns: u64 = 0;
    var smallest: u64 = std.math.maxInt(u64);
    var largest: u64 = 0;
    for (windows[0..count]) |window| {
        total_ns += window;
        smallest = @min(smallest, window);
        largest = @max(largest, window);
    }
    var sorted: [window_slots]u64 = undefined;
    @memcpy(sorted[0..count], windows[0..count]);
    sortWindows(sorted[0..count]);
    const median = sorted[count / 2];

    var report_buffer: [report_capacity]u8 = undefined;
    var report = std.Io.Writer.fixed(&report_buffer);

    try report.print("bench=codec\n", .{});
    try report.print("target={s}\ntarget_os={s}\noptimize={s}\n", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.mode),
    });
    try report.print("corpus_rows={d}\ncorpus_accepted={d}\ncorpus_rejected={d}\ncorpus_bytes={d}\n", .{
        corpus.len,
        accepted_rows,
        corpus.len - accepted_rows,
        corpus_bytes,
    });
    try report.print("corpus_sha256={s}\n", .{corpus_sha256});
    for (corpus) |row| {
        try report.print(
            "row={s} protocol={s} bytes={d} scratch={d} outcome={s} error={s}\n",
            .{
                row.name,
                row.kind.protocol(),
                row.bytes.len,
                json.Reader.requiredScratchLen(row.bytes),
                if (row.accept) "accept" else "reject",
                row.expected_error,
            },
        );
    }
    // One line per distinct refusal class, so a class two rows provoke is
    // reported as a count of two and not as two lines that disagree.
    for (corpus, 0..) |row, at| {
        if (row.accept) continue;
        var earlier: usize = 0;
        while (earlier < at) : (earlier += 1) {
            const other = corpus[earlier];
            if (!other.accept and std.mem.eql(u8, other.expected_error, row.expected_error)) break;
        }
        if (earlier != at) continue;
        var rejected: u64 = 0;
        for (corpus) |other| {
            if (!other.accept and std.mem.eql(u8, other.expected_error, row.expected_error)) {
                rejected += 1;
            }
        }
        try report.print("reject_{s}={d}\n", .{ row.expected_error, rejected });
    }
    try report.print(
        "scratch_required_bytes={d}\nscratch_used_bytes={d}\n",
        .{ scratch_required, scratch_used },
    );
    // Three regions, named for what each includes: the codec's own buffers,
    // the report this run composes, and the sample arrays the statistics come
    // from. The total is a footprint — nothing here grows with the request —
    // and it is not a peak, because nothing is allocated to have one.
    try report.print(
        "codec_storage_bytes={d}\nreport_buffer_bytes={d}\nwindow_slots={d}\n" ++
            "window_array_bytes={d}\nharness_fixed_bytes={d}\n",
        .{ storageBytes(), report_capacity, window_slots, windowBytes(), harnessBytes() },
    );
    // The two unit lines sit beside the counts they define, so `ops` and the
    // per-operation figures can be read from the report alone.
    try report.print(
        "iterations={d}\niterations_unit=corpus_pass\nsamples={d}\n" ++
            "warmup_iterations={d}\nops={d}\nops_unit=accepted_row_decode_and_encode\n",
        .{ iterations, samples, warmup_iterations, ops },
    );
    // Pass sums first, then the averages an operation divides them into, then
    // the run total the two rates use. Decimals, because an average of bytes is
    // not necessarily a whole number and a truncated one would under-report
    // the bytes the run actually moved.
    try report.print(
        "decode_bytes_per_pass={d}\nencode_bytes_per_pass={d}\nbytes_per_pass={d}\n",
        .{ decode_bytes, encode_bytes, pass_bytes },
    );
    try report.print(
        "decode_bytes_per_op={d:.3}\nencode_bytes_per_op={d:.3}\nbytes_per_op={d:.3}\n" ++
            "bytes_processed={d}\n",
        .{ decode_bytes_per_op, encode_bytes_per_op, bytes_per_op, bytes_processed },
    );
    try report.print("total_ns={d}\n", .{total_ns});
    const total_seconds = @as(f64, @floatFromInt(total_ns)) / @as(f64, std.time.ns_per_s);
    try report.print("ns_per_op={d:.3}\n", .{
        @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(ops)),
    });
    try report.print("throughput_mib_s={d:.3}\n", .{
        if (total_seconds > 0)
            @as(f64, @floatFromInt(bytes_processed)) / total_seconds / (1024 * 1024)
        else
            @as(f64, 0),
    });
    // Three checksums, one per region, so `work_sum` beside `ops` describes
    // the timed work and the two untimed regions are visible rather than
    // folded into it.
    try report.print(
        "work_sum={x}\noracle_work_sum={x}\nwarmup_work_sum={x}\n",
        .{ sink.sum, oracle.sum, warm.sum },
    );
    try report.print("sample_ns_min={d}\nsample_ns_median={d}\nsample_ns_max={d}\n", .{
        smallest,
        median,
        largest,
    });
    for (windows[0..count]) |window| {
        try report.print("sample_ns={d}\n", .{window});
    }

    try out.writeAll(report.buffered());
}

// --- Tests -----------------------------------------------------------------------

/// The value of the single line whose key is exactly `key`.
///
/// A test reads the report a run produced, so the lookup is by exact key rather
/// than by prefix: `sample_ns_min` shares a prefix with `sample_ns`.
fn reportValue(text: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.findScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..at], key)) return line[at + 1 ..];
    }
    return "";
}

/// The value each line whose key is exactly `key` carries, in report order,
/// into caller storage.
///
/// The value and not the whole line, because a caller that wants the key back
/// has already named it here to find the line.
fn reportValues(text: []const u8, key: []const u8, into: [][]const u8) []const []const u8 {
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.findScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, line[0..at], key)) continue;
        if (used == into.len) break;
        into[used] = line[at + 1 ..];
        used += 1;
    }
    return into[0..used];
}

/// The number the single line whose key is exactly `key` carries.
fn reportNumber(text: []const u8, key: []const u8) !u64 {
    const value = reportValue(text, key);
    if (value.len == 0) return error.MissingKey;
    return std.fmt.parseInt(u64, value, 10);
}

test "a request outside the bounds is refused and writes nothing" {
    // Both parameters and their product. The product is the case a caller cannot
    // check by looking at either number alone: 20000 and 51 are each inside
    // their own range and together are a million and twenty thousand timed
    // passes over the corpus, which is a run long enough to be a mistake and
    // short enough to be a typo rather than a request.
    const refused = [_]struct { iterations: u32, samples: u32, want: Error }{
        .{ .iterations = 0, .samples = 1, .want = Error.BadIterations },
        .{ .iterations = max_iterations + 1, .samples = 1, .want = Error.BadIterations },
        .{ .iterations = 1, .samples = 0, .want = Error.BadSamples },
        .{ .iterations = 1, .samples = max_samples + 1, .want = Error.BadSamples },
        .{ .iterations = max_iterations, .samples = 2, .want = Error.WorkTooLarge },
        .{ .iterations = 20_000, .samples = 51, .want = Error.WorkTooLarge },
    };
    for (refused) |request| {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try testing.expectError(
            request.want,
            Self.run(testing.io, &writer, request.iterations, request.samples),
        );
        try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

test "decoded byte throughput counts each accepted input once per corpus pass" {
    var buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const iterations: u32 = 32;
    const samples: u32 = 2;
    try run(testing.io, &writer, iterations, samples);
    const text = writer.buffered();

    // The run copies each accepted row into its own storage and holds that copy
    // to the literal byte for byte before the first window opens, so the
    // literal lengths below are the lengths the timed decodes were handed.
    var decoded_bytes_per_pass: u64 = 0;
    for (corpus) |row| {
        if (row.accept) decoded_bytes_per_pass += row.bytes.len;
    }
    const operations = try reportNumber(text, "ops");
    const decoded_bytes_per_op = try std.fmt.parseFloat(f64, reportValue(text, "decode_bytes_per_op"));
    try testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(decoded_bytes_per_pass)) * iterations * samples,
        decoded_bytes_per_op * @as(f64, @floatFromInt(operations)),
        0.01,
    );
}

test "byte totals are one pass scaled by the passes that ran it" {
    // The same arithmetic as the decoded figure above, on the encoded side and
    // on the run total the two rates use: a pass sums the accepted rows, a run
    // scales that by the passes and windows it ran, and a per-operation figure
    // divides the pass sum by the accepted rows in it.
    const iterations: u32 = 8;
    const samples: u32 = 2;
    var buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try Self.run(testing.io, &writer, iterations, samples);
    const text = writer.buffered();

    const decoded = try reportNumber(text, "decode_bytes_per_pass");
    const encoded = try reportNumber(text, "encode_bytes_per_pass");
    const pass = try reportNumber(text, "bytes_per_pass");
    try testing.expectEqual(decoded + encoded, pass);
    try testing.expectEqual(
        pass * iterations * samples,
        try reportNumber(text, "bytes_processed"),
    );

    const rows: f64 = @floatFromInt(accepted_rows);
    try testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(decoded)),
        try std.fmt.parseFloat(f64, reportValue(text, "decode_bytes_per_op")) * rows,
        0.001,
    );
    try testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(encoded)),
        try std.fmt.parseFloat(f64, reportValue(text, "encode_bytes_per_op")) * rows,
        0.001,
    );

    // Throughput is the byte total over the time the windows spent, so the
    // MiB/s beside `ns_per_op` describes the bytes the run really moved rather
    // than the bytes of a single pass counted once per document.
    const seconds = @as(f64, @floatFromInt(try reportNumber(text, "total_ns"))) /
        @as(f64, std.time.ns_per_s);
    try testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(pass * iterations * samples)) / seconds / (1024 * 1024),
        try std.fmt.parseFloat(f64, reportValue(text, "throughput_mib_s")),
        0.001,
    );
}

test "the reported windows are the ones that were run" {
    // The summary lines are checked against the raw vector rather than against
    // each other: a median or a total taken from a different vector is a
    // summary of a measurement nobody made.
    const samples: u32 = 5;
    const iterations: u32 = 256;
    var buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try Self.run(testing.io, &writer, iterations, samples);
    const text = writer.buffered();

    var window_storage: [window_slots][]const u8 = undefined;
    const values = reportValues(text, "sample_ns", &window_storage);
    try testing.expectEqual(@as(usize, samples), values.len);

    var smallest: u64 = std.math.maxInt(u64);
    var largest: u64 = 0;
    var sum: u64 = 0;
    for (values) |value| {
        const window = try std.fmt.parseInt(u64, value, 10);
        // A zero-length window is a clock that could not resolve this workload,
        // which the run refuses rather than reports as a nanosecond.
        try testing.expect(window > 0);
        smallest = @min(smallest, window);
        largest = @max(largest, window);
        sum += window;
    }
    try testing.expectEqual(smallest, try reportNumber(text, "sample_ns_min"));
    try testing.expectEqual(largest, try reportNumber(text, "sample_ns_max"));
    const median = try reportNumber(text, "sample_ns_median");
    try testing.expect(median >= smallest and median <= largest);
    try testing.expectEqual(sum, try reportNumber(text, "total_ns"));
}

test "the corpus is refused and accepted exactly as it is written" {
    // Every row's own outcome, checked through the same functions the run uses
    // and against the same expectations, so a row that stopped being refused —
    // or stopped decoding — is a failing test rather than a corpus that quietly
    // measured the wrong thing.
    var st: Storage = undefined;
    for (corpus) |row| {
        if (row.accept) {
            try checkAccepted(row, row.bytes, &st.scratch, &st);
            continue;
        }
        try checkRefusal(row, &st);
    }
}
