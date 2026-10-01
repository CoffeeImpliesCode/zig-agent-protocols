//! The benchmark driver's command line, and the tests that pin it.
//!
//! `src/bench_codec.zig` measures the codec against a fixed corpus and
//! `src/bench_runtime.zig` measures a `Conn` round trip and an HTTP first event
//! between real peers over real sockets. This file is the one executable that
//! runs either of them, so this is where a run is sized — and a run is bounded
//! work that burns real CPU and opens real sockets, which makes a mistyped
//! count the kind of fault that costs an hour before anyone notices it. The
//! rules the tests below pin are:
//!
//!   - `--mode codec|runtime|all` says what runs, `--iterations N` and
//!     `--samples N` say how much, and no other word is accepted.
//!   - `iterations` is `1..1000000` and `samples` is `1..64`. Each is a run of
//!     decimal digits and nothing else, so a sign, a `0x` prefix, a separator,
//!     an empty word and a trailing letter are one fault between them, while a
//!     count too large for a `u32` is a second: that one is an overflow, not a
//!     range complaint, and saying so keeps the reader from looking for a
//!     bound that was never the problem.
//!   - `iterations * samples` — the timed work a run asks for — is checked
//!     against a budget that follows the mode: `1000000` for the codec and
//!     `10000` for anything that runs `bench_runtime`. The product counts timed
//!     passes times windows, and a pass means what the module measures it to
//!     mean: for the codec, one pass over the fixed corpus, so every accepted
//!     document is decoded and encoded once per iteration; for the runtime,
//!     one round trip per peer, each of which opens a socket and exchanges
//!     frames over it. `all` carries the runtime budget because `all` runs the
//!     runtime workload.
//!   - A flag that is unknown, repeated, missing its value or followed by
//!     another flag, a word that is not a flag at all, a word that is not a
//!     count, a count no `u32` holds, a count outside its range and a run over
//!     its budget are each refused by name, and every one of those refusals
//!     happens before a benchmark starts rather than partway through one.
//!   - `--help` asks for the usage instead of for a run, and it does not
//!     swallow a typo, an unknown flag or a count outside its range beside it.
//!     It does not carry the budget either: a request for usage runs nothing,
//!     and a limit on work has nothing to say about a line that does none.
//!
//! The faults are values, not prose: [`CliError`] gives each one a member, and
//! the tests pin those members, so the message a reader sees can be reworded
//! without a test moving and a fault cannot be reported under the wrong name.
//!
//! Nothing here allocates. The command line is copied into a fixed array of
//! words, the parse borrows those words, and the report goes to one buffered
//! `std.Io.Writer` held open for the whole run, so a redirected standard
//! output captures a whole report rather than a half-flushed one.
//!
//! The flush that puts the last of that report on standard output is the last
//! thing the program does, and it is one this program checks: a failure in it
//! is the exit status the run gets, because a report that reached no reader is
//! not a report, and a run that exits zero over one says the opposite.
//!
//! The two benchmark modules are named imports, the same way this executable
//! reaches the library and the way the shared test harness is reached: one
//! module instance each, shared with the test binary that covers that module,
//! so the driver cannot compile a second copy of a benchmark the build has
//! already built.

const std = @import("std");

const bench_codec = @import("bench_codec");
const bench_runtime = @import("bench_runtime");

const Self = @This();
const testing = std.testing;

/// What a run measures.
pub const Mode = enum {
    /// The codec against a fixed corpus of literals: buffers, no sockets.
    codec,
    /// A `Conn` round trip and an HTTP first event between real peers over
    /// real sockets.
    runtime,
    /// Both, the codec first.
    all,
};

/// A sized run: what to measure, and how much of it.
pub const Config = struct {
    mode: Mode,
    iterations: u32,
    samples: u32,
};

/// What a command line asks for.
pub const Parsed = union(enum) {
    /// The usage was asked for. No benchmark runs and nothing is sized.
    help,
    /// A run that is complete, in range and inside its budget. A `run` here
    /// has already been checked, so a caller that has one can measure without
    /// checking anything again.
    run: Config,
};

/// Every way a command line can be refused, one member per fault.
///
/// The members are separate rather than a single `InvalidArgument` because the
/// faults are separate: a reader who typed `--iterations 5000000` and a reader
/// who typed `--iterations abc` have to be told different things, and a driver
/// that collapsed both into one message taught neither of them anything.
pub const CliError = error{
    /// A word that is not a flag this driver knows, including a joined
    /// spelling such as `--iterations=5` and a name spelled differently such as
    /// `--Iterations`. Neither is silently dropped and neither is guessed at.
    UnknownFlag,
    /// A flag this driver knows, given twice. The last one does not win: a
    /// line that repeats a flag was assembled by something that did not read
    /// what it wrote, and picking one of the two would hide that.
    DuplicateFlag,
    /// A flag that takes a value, with nothing after it or with another flag
    /// after it. A flag is not a value.
    MissingValue,
    /// A word that is not a flag at all. This driver takes no positional
    /// argument, so there is nothing a bare word could have meant.
    UnexpectedArgument,
    /// A `--mode` value that is not one of the three spellings. The mode is
    /// spelled in lower case and exactly.
    InvalidMode,
    /// A count that is not a run of decimal digits: empty, signed, in another
    /// base, separated, or with anything trailing it.
    NotANumber,
    /// A count of decimal digits that no `u32` holds. Distinct from
    /// `IterationsOutOfRange` because no bound is what was crossed.
    CountOverflow,
    /// `iterations` outside `1..1000000`.
    IterationsOutOfRange,
    /// `samples` outside `1..64`.
    SamplesOutOfRange,
    /// `iterations * samples` over the budget the mode carries.
    WorkBudgetExceeded,
};

/// The most timed passes a codec run may be asked for.
///
/// The product is passes and windows, not documents: one codec pass decodes
/// and encodes every accepted row of that module's fixed corpus, so a run at
/// this bound performs several million document operations. A million passes
/// is still bounded work in buffers the process already holds, with no I/O in
/// it at all — which is why this bound is two orders of magnitude from
/// [`work_runtime_max`] rather than beside it.
pub const work_codec_max: u64 = 1_000_000;

/// The most timed operations a `runtime` or an `all` run may be asked for.
///
/// Every runtime operation costs a socket, a round trip and the peer's answer,
/// which is two orders of magnitude from the buffer slice the codec budget is
/// sized for. This is a bound, not a preference: a run of the size the codec
/// budget allows would keep a machine busy for an hour, and an hour is long
/// enough that a mistake is not noticed until it is over.
pub const work_runtime_max: u64 = 10_000;

/// The largest `--iterations` a run may ask for.
const iterations_max: u32 = 1_000_000;

/// The largest `--samples` a run may ask for.
const samples_max: u32 = 64;

/// The counts a line that names no counts asks for.
const default_iterations: u32 = 100;
const default_samples: u32 = 5;

/// The mode a line that names no mode asks for: both workloads, sized small
/// enough for a bare invocation to stay inside the runtime budget.
const default_mode: Mode = .all;

/// The most words a command line may hold after the program name.
///
/// A complete line is five words. An array this size keeps the copy bounded
/// and makes a longer line a refusal instead of a truncation, because a
/// truncated line would parse as a shorter line and run something the reader
/// did not ask for.
const max_words = 64;

/// The usage, in one string so `--help` and a refusal cannot drift apart.
///
/// The bounds are printed from the names above rather than written here as
/// digits, so a bound that changes changes this text with it.
const usage =
    \\usage: bench [--mode codec|runtime|all] [--iterations N] [--samples N]
    \\       bench --help
    \\
    \\Sizes a zig-agent-proto benchmark run and then runs it. Every argument is
    \\a flag this driver knows, and every other word is a refusal.
    \\
    \\  --mode MODE     what runs. codec measures the codec against a fixed
    \\                  corpus of literals; runtime measures a Conn round trip
    \\                  and an HTTP first event between real peers over real
    \\                  sockets; all runs both, the codec first. Default: all.
    \\  --iterations N  timed passes per window, 1..{d}. Default: {d}. A
    \\                  codec pass decodes and encodes every accepted corpus
    \\                  row once; a runtime pass is one round trip per peer.
    \\  --samples N     timed windows the statistics span, 1..{d}. Default: {d}.
    \\  --help, -h      print this and run nothing.
    \\
    \\iterations * samples counts timed passes times windows, and it is capped at
    \\{d} for --mode codec and at {d} for --mode runtime and --mode all. Reports
    \\go to standard output, one per workload, key=value per line.
    \\
    \\A flag given twice, a flag with no value or with another flag after it, an
    \\unknown flag, a word that is not a flag, a count that is not decimal
    \\digits, a count no u32 holds, a count outside its range and a run over the
    \\budget are each refused on standard error beside this usage, with exit
    \\status 2. --help does not hide any of them when it stands on the same line.
    \\
;

/// The program's whole path: read the words, then either print the usage or size
/// and run one benchmark.
///
/// Nothing is written to standard output before the line has been read, so a
/// refused line leaves the usage and nothing else — never a partial report
/// that reads like a result.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;

    // Preserve buffered diagnostics if measurement fails before the final flush.
    // Set the guard before that flush so its failure cannot trigger a retry.
    var final_flush_attempted = false;
    errdefer {
        if (!final_flush_attempted) {
            // gate-reviewed-zlint-next-statement: suppressed-errors
            // ziglint-ignore: Z026
            // zwanzig-disable-next-line: empty-catch-engine
            stdout.flush() catch {};
        }
    }

    var words: [max_words][]const u8 = undefined;
    const line = readWords(init, &words) catch |fault| refuse(io, fault);

    const parsed = parseArgs(line) catch |fault| refuse(io, fault);

    switch (parsed) {
        .help => try writeUsage(out),
        .run => |config| try measure(io, out, config),
    }

    final_flush_attempted = true;
    try stdout.flush();
}

/// Read the words after the program name into `storage`.
///
/// The program name is dropped: it is the shell's word, not the driver's, and
/// nothing below reads it. A line with more words than `storage` holds is a
/// refusal rather than a truncation.
fn readWords(init: std.process.Init, storage: *[max_words][]const u8) CliError![]const []const u8 {
    var it = std.process.Args.iterate(init.minimal.args);
    _ = it.skip();

    var count: usize = 0;
    while (it.next()) |word| {
        if (count == storage.len) return error.UnexpectedArgument;
        storage[count] = word;
        count += 1;
    }
    return storage[0..count];
}

/// Read a command line into a run request, the usage, or the name of the fault
/// that refuses it.
///
/// The parse is a pure function of the words: no `Io`, no allocator, no clock
/// and no global state, which is what lets the tests below pin every refusal
/// without starting a process.
pub fn parseArgs(args: []const []const u8) CliError!Parsed {
    var mode: Mode = default_mode;
    var iterations: u32 = default_iterations;
    var samples: u32 = default_samples;
    var seen = std.EnumArray(Flag, bool).initFill(false);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (!isFlag(argument)) return error.UnexpectedArgument;

        const flag = flagOf(argument) orelse return error.UnknownFlag;
        if (seen.get(flag)) return error.DuplicateFlag;
        seen.set(flag, true);

        switch (flag) {
            .help => {},
            .mode, .iterations, .samples => switch (flag) {
                .mode => mode = std.meta.stringToEnum(Mode, try takeValue(args, &index)) orelse
                    return error.InvalidMode,
                .iterations => iterations = try parseCount(try takeValue(args, &index)),
                .samples => samples = try parseCount(try takeValue(args, &index)),
                // `help` is the one flag that takes no value, and this switch is
                // only reached for the three that do.
                .help => unreachable,
            },
        }
    }

    // The ranges are checked on the effective counts rather than as each word
    // is read, so a run the driver filled in is held to the same bound as one
    // the reader typed. Both are checked before `help` below for the same
    // reason a refusal is checked there: a count outside its range is a bad
    // argument whatever else the line says.
    if (iterations == 0 or iterations > iterations_max) return error.IterationsOutOfRange;
    if (samples == 0 or samples > samples_max) return error.SamplesOutOfRange;

    // Asked for only once every word has been read and every other fault
    // checked, because the usage is not a licence to wave a typo through. It is
    // answered before the budget, because a line that runs nothing has asked
    // for no work to bound.
    if (seen.get(.help)) return .help;

    const work = @as(u64, iterations) * @as(u64, samples);
    if (work > workBudget(mode)) return error.WorkBudgetExceeded;

    return .{ .run = .{ .mode = mode, .iterations = iterations, .samples = samples } };
}

/// The flags this driver knows, named by the exact word that names each one.
const Flag = enum { mode, iterations, samples, help };

/// The flag a word names, or null for a word that names none.
///
/// The match is on the whole word, so a joined spelling and a name spelled
/// differently are both unknown flags: guessing at either would run something
/// the reader did not ask for.
fn flagOf(argument: []const u8) ?Flag {
    const table = .{
        .{ "--mode", Flag.mode },
        .{ "--iterations", Flag.iterations },
        .{ "--samples", Flag.samples },
        .{ "--help", Flag.help },
        .{ "-h", Flag.help },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, argument, entry[0])) return entry[1];
    }
    return null;
}

/// Whether a word names a flag rather than supplying a value.
///
/// A `-` followed by a digit is a signed number and not a flag. `-1` is a
/// mistake a reader makes often enough to deserve the `NotANumber` the count
/// parser gives it rather than the `MissingValue` a flag would produce, and
/// `std.fmt.parseInt` alone would not give it that: it reads the sign, negates
/// and returns an overflow.
fn isFlag(argument: []const u8) bool {
    if (argument.len < 2 or argument[0] != '-') return false;
    return !std.ascii.isDigit(argument[1]);
}

/// The word after a flag that takes one, advancing past it.
///
/// A flag is not a value, so a flag at the end of the line and a flag followed
/// by another flag are one fault: the value is missing, not wrong.
fn takeValue(args: []const []const u8, index: *usize) CliError![]const u8 {
    if (index.* + 1 >= args.len or isFlag(args[index.* + 1])) return error.MissingValue;
    index.* += 1;
    return args[index.*];
}

/// A count as a `u32`.
///
/// The digits are checked here rather than left to `parseInt`, because the two
/// faults a bad count can be are different faults: a word that is not a number
/// is `NotANumber`, and a number no `u32` holds is `CountOverflow`.
fn parseCount(text: []const u8) CliError!u32 {
    if (text.len == 0) return error.NotANumber;
    for (text) |digit| {
        if (!std.ascii.isDigit(digit)) return error.NotANumber;
    }
    return std.fmt.parseInt(u32, text, 10) catch error.CountOverflow;
}

/// The most timed operations a mode may be asked for.
fn workBudget(mode: Mode) u64 {
    return switch (mode) {
        .codec => work_codec_max,
        .runtime, .all => work_runtime_max,
    };
}

/// Run what the mode names, in the order the mode names it, and write one
/// report per workload to the caller's buffered writer.
///
/// The header comes first so a captured report says which run produced it,
/// rather than leaving that to the reader's memory of the command line.
fn measure(io: std.Io, out: *std.Io.Writer, config: Config) !void {
    try out.print("mode={s} iterations={d} samples={d} work={d}\n", .{
        @tagName(config.mode),
        config.iterations,
        config.samples,
        @as(u64, config.iterations) * @as(u64, config.samples),
    });

    switch (config.mode) {
        .codec => try bench_codec.run(io, out, config.iterations, config.samples),
        .runtime => try bench_runtime.run(io, out, config.iterations, config.samples),
        .all => {
            try bench_codec.run(io, out, config.iterations, config.samples);
            try bench_runtime.run(io, out, config.iterations, config.samples);
        },
    }
}

/// Write the usage, with every bound spelled as the numbers it is.
fn writeUsage(out: *std.Io.Writer) !void {
    try out.print(usage, .{
        iterations_max, default_iterations,
        samples_max,    default_samples,
        work_codec_max, work_runtime_max,
    });
}

/// The fault as a phrase, for the line that precedes the usage.
///
/// The phrase names the fault rather than the offending word, because
/// [`CliError`] is where the fault is kept and a word the reader already
/// typed does not need repeating; the usage that follows names every word this
/// driver takes. The numbers are in that usage too, so a bound is written down
/// once.
fn reason(fault: CliError) []const u8 {
    return switch (fault) {
        error.UnknownFlag => "an unknown flag",
        error.DuplicateFlag => "a flag given twice",
        error.MissingValue => "a flag with no value after it",
        error.UnexpectedArgument => "an argument that is not a flag",
        error.InvalidMode => "a mode that is not codec, runtime or all",
        error.NotANumber => "a count that is not a run of decimal digits",
        error.CountOverflow => "a count no u32 holds",
        error.IterationsOutOfRange => "iterations outside its range",
        error.SamplesOutOfRange => "samples outside its range",
        error.WorkBudgetExceeded => "iterations * samples over the budget for that mode",
    };
}

/// Say what was wrong with the line, print the usage beside it, and leave with
/// the status a refused line gets.
///
/// `noreturn`, because there is nothing to measure and nothing to report: the
/// only honest answer to a line this driver refuses is to stop. The buffer
/// holds a whole refusal, because a message that arrives in two writes is a
/// message another line can land in the middle of.
fn refuse(io: std.Io, fault: CliError) noreturn {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    const err = &stderr.interface;
    // Standard error may already be closed; there is no alternate reporting
    // channel, and refusing the command must still exit with status 2.
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    err.print("bench: {s}\n", .{reason(fault)}) catch {};
    // Keep attempting the usage even if writing the reason failed.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    writeUsage(err) catch {};
    // `exit` runs no defer. Flush even after a failed write so buffered
    // refusal bytes are not lost merely because the later usage failed.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    stderr.flush() catch {};
    std.process.exit(2);
}

/// A configuration that names a run rather than a request for the usage.
fn expectRun(parsed: Self.Parsed) !Self.Config {
    return switch (parsed) {
        .help => error.ExpectedARun,
        .run => |config| config,
    };
}

/// A configuration that asks for the usage rather than naming a run.
fn expectHelp(parsed: Self.Parsed) !void {
    switch (parsed) {
        .help => {},
        .run => return error.ExpectedHelp,
    }
}

test "budget: a codec run of exactly the budget is allowed and one iteration more is not" {
    const at_budget = try expectRun(try Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "200000",
        "--samples",    "5",
    }));
    try testing.expectEqual(@as(u32, 200000), at_budget.iterations);
    try testing.expectEqual(@as(u32, 5), at_budget.samples);

    try testing.expectError(Self.CliError.WorkBudgetExceeded, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "200001",
        "--samples",    "5",
    }));
}

test "budget: a runtime run of exactly ten thousand works is allowed and one more is not" {
    const at_budget = try expectRun(try Self.parseArgs(&.{
        "--mode",       "runtime",
        "--iterations", "10000",
        "--samples",    "1",
    }));
    try testing.expectEqual(Self.Mode.runtime, at_budget.mode);
    try testing.expectEqual(@as(u32, 10000), at_budget.iterations);

    try testing.expectError(Self.CliError.WorkBudgetExceeded, Self.parseArgs(&.{
        "--mode",       "runtime",
        "--iterations", "10001",
        "--samples",    "1",
    }));
}

test "budget: all carries the runtime budget because all runs the runtime work" {
    const at_budget = try expectRun(try Self.parseArgs(&.{
        "--mode",       "all",
        "--iterations", "10000",
        "--samples",    "1",
    }));
    try testing.expectEqual(Self.Mode.all, at_budget.mode);

    // The count the codec budget allows, refused here: the budget follows
    // the mode rather than being one number the largest mode has to fit
    // inside.
    try testing.expectError(Self.CliError.WorkBudgetExceeded, Self.parseArgs(&.{
        "--mode",       "all",
        "--iterations", "200000",
        "--samples",    "5",
    }));
}

test "budget: the largest in-range pair is still refused where the budget is smaller" {
    try testing.expectError(Self.CliError.WorkBudgetExceeded, Self.parseArgs(&.{
        "--mode",       "runtime",
        "--iterations", "1000000",
        "--samples",    "1",
    }));
}

test "budget: the effective counts are checked, not only the ones on the line" {
    // 200000 is inside the iteration range on its own; only the sample
    // count the driver filled in carries this over the runtime budget, so a
    // caller that checked the flags it typed would let this through.
    try testing.expectError(Self.CliError.WorkBudgetExceeded, Self.parseArgs(&.{
        "--mode",       "runtime",
        "--iterations", "200000",
    }));
}

test "range: zero and a million-plus iterations are refused, one and a million are not" {
    try testing.expectError(Self.CliError.IterationsOutOfRange, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "0",
        "--samples",    "1",
    }));
    try testing.expectError(Self.CliError.IterationsOutOfRange, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1000001",
        "--samples",    "1",
    }));

    const lowest = try expectRun(try Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1",
        "--samples",    "1",
    }));
    try testing.expectEqual(@as(u32, 1), lowest.iterations);

    const highest = try expectRun(try Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1000000",
        "--samples",    "1",
    }));
    try testing.expectEqual(@as(u32, 1000000), highest.iterations);
}

test "range: zero and sixty-five samples are refused, one and sixty-four are not" {
    try testing.expectError(Self.CliError.SamplesOutOfRange, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1",
        "--samples",    "0",
    }));
    try testing.expectError(Self.CliError.SamplesOutOfRange, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1",
        "--samples",    "65",
    }));

    const lowest = try expectRun(try Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1",
        "--samples",    "1",
    }));
    try testing.expectEqual(@as(u32, 1), lowest.samples);

    const highest = try expectRun(try Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1",
        "--samples",    "64",
    }));
    try testing.expectEqual(@as(u32, 64), highest.samples);
}

test "count: a count no u32 holds is an overflow rather than a range complaint" {
    try testing.expectError(Self.CliError.CountOverflow, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "4294967296",
        "--samples",    "1",
    }));
    try testing.expectError(Self.CliError.CountOverflow, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "1",
        "--samples",    "99999999999999999999",
    }));
}

test "count: a word that is not a decimal count is refused" {
    try testing.expectError(Self.CliError.NotANumber, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "abc",
        "--samples",    "1",
    }));
    try testing.expectError(Self.CliError.NotANumber, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "12x",
        "--samples",    "1",
    }));
    try testing.expectError(Self.CliError.NotANumber, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "",
        "--samples",    "1",
    }));
    // A signed count is not a count. `parseInt` reads the sign and negates,
    // so `-1` would otherwise arrive as an overflow and send the reader
    // looking for a digit that is too long.
    try testing.expectError(Self.CliError.NotANumber, Self.parseArgs(&.{
        "--mode",       "codec",
        "--iterations", "-1",
        "--samples",    "1",
    }));
}

test "flag: an unknown flag is refused rather than ignored" {
    try testing.expectError(Self.CliError.UnknownFlag, Self.parseArgs(&.{"--nope"}));
    try testing.expectError(Self.CliError.UnknownFlag, Self.parseArgs(&.{"-x"}));
    // The joined spelling is not the one this driver accepts, and saying so
    // beats reading `--iterations=5` as a flag nobody knows and dropping it.
    try testing.expectError(
        Self.CliError.UnknownFlag,
        Self.parseArgs(&.{"--iterations=5"}),
    );
    try testing.expectError(
        Self.CliError.UnknownFlag,
        Self.parseArgs(&.{ "--Iterations", "5" }),
    );
}

test "flag: a flag given twice is refused rather than letting the last one win" {
    try testing.expectError(
        Self.CliError.DuplicateFlag,
        Self.parseArgs(&.{ "--mode", "codec", "--mode", "runtime" }),
    );
    try testing.expectError(
        Self.CliError.DuplicateFlag,
        Self.parseArgs(&.{
            "--mode",       "codec",
            "--iterations", "5",
            "--iterations", "6",
            "--samples",    "1",
        }),
    );
    // Twice with the same value is still twice: a line that repeats a flag
    // has been assembled by something the reader did not write.
    try testing.expectError(
        Self.CliError.DuplicateFlag,
        Self.parseArgs(&.{
            "--mode",       "codec",
            "--iterations", "5",
            "--samples",    "1",
            "--samples",    "1",
        }),
    );
}

test "flag: a flag with nothing after it has no value" {
    try testing.expectError(Self.CliError.MissingValue, Self.parseArgs(&.{"--mode"}));
    try testing.expectError(Self.CliError.MissingValue, Self.parseArgs(&.{"--iterations"}));
    try testing.expectError(Self.CliError.MissingValue, Self.parseArgs(&.{"--samples"}));
}

test "flag: another flag is not a value" {
    try testing.expectError(
        Self.CliError.MissingValue,
        Self.parseArgs(&.{ "--mode", "--iterations", "5" }),
    );
    try testing.expectError(
        Self.CliError.MissingValue,
        Self.parseArgs(&.{ "--iterations", "--samples", "5" }),
    );
}

test "flag: a word that is not a flag at all is refused" {
    try testing.expectError(
        Self.CliError.UnexpectedArgument,
        Self.parseArgs(&.{"codec"}),
    );
    try testing.expectError(
        Self.CliError.UnexpectedArgument,
        Self.parseArgs(&.{ "--mode", "codec", "extra" }),
    );
}

test "mode: a spelling that is not one of the three is refused" {
    try testing.expectError(
        Self.CliError.InvalidMode,
        Self.parseArgs(&.{ "--mode", "fast" }),
    );
    try testing.expectError(
        Self.CliError.InvalidMode,
        Self.parseArgs(&.{ "--mode", "Codec" }),
    );
    try testing.expectError(
        Self.CliError.InvalidMode,
        Self.parseArgs(&.{ "--mode", "" }),
    );
}

test "help: --help and -h ask for the usage rather than for a run" {
    try expectHelp(try Self.parseArgs(&.{"--help"}));
    try expectHelp(try Self.parseArgs(&.{"-h"}));
}

test "help: --help does not run benchmarks beside a valid configuration" {
    try expectHelp(try Self.parseArgs(&.{
        "--mode",       "runtime",
        "--iterations", "10",
        "--samples",    "1",
        "--help",
    }));
}

test "help: --help does not hide a typo on the same line" {
    try testing.expectError(
        Self.CliError.UnknownFlag,
        Self.parseArgs(&.{ "--help", "--nope" }),
    );
    try testing.expectError(
        Self.CliError.UnknownFlag,
        Self.parseArgs(&.{ "--nope", "--help" }),
    );
}

test "help: --help does not hide a count outside its range" {
    try testing.expectError(
        Self.CliError.IterationsOutOfRange,
        Self.parseArgs(&.{ "--help", "--iterations", "0" }),
    );
    try testing.expectError(
        Self.CliError.SamplesOutOfRange,
        Self.parseArgs(&.{ "--samples", "65", "--help" }),
    );
}

test "help: asked for twice, it is still a flag given twice" {
    try testing.expectError(
        Self.CliError.DuplicateFlag,
        Self.parseArgs(&.{ "--help", "-h" }),
    );
    try testing.expectError(
        Self.CliError.DuplicateFlag,
        Self.parseArgs(&.{ "--help", "--help" }),
    );
}

test "default: a bare line is admissible under the tighter of the two budgets" {
    // The default counts are not pinned here; what has to hold is that a
    // line with no flags at all cannot ask for more work than the runtime
    // budget allows, whichever mode it goes on to name.
    const config = try expectRun(try Self.parseArgs(&.{}));
    const work = @as(u64, config.iterations) * @as(u64, config.samples);
    try testing.expect(work <= Self.work_runtime_max);
}
