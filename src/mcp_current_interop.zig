//! The Zig half of the MCP 2026-07-28 interoperability exchange.
//!
//! This is a participant, not a library module. `test/interop/mcp_current_peer.py`
//! starts this executable as a child process with pipes on its standard streams
//! and a genuine `mcp` SDK server — the pinned 2.3.0 release — serves the other
//! end of them, so the bytes this file puts on standard output are the real
//! wire between two independent implementations. Nothing here is imported by
//! the library, and the library keeps its zero-dependency guarantee because this
//! process is a peer and not a caller.
//!
//! `src/mcp_interop.zig` is the same shape at the previous revision and neither
//! file is a compatibility shim for the other: PROTOCOLS.md section 4.8 has no
//! handshake at this revision at all, so the two exchanges share a supervisor
//! pattern and nothing else.
//!
//! ## What it does, in the order the specification requires
//!
//!   1. `server/discover`, which is the only mandatory server method at this
//!      revision. No `initialize` and no `notifications/initialized` are sent:
//!      both were removed, and [`removedNames`] is the list this client checks
//!      it refuses before any of them reaches the wire.
//!   2. `tools/list`, read with `mcp.decodeToolListResult`, which is the
//!      current decoder this revision's answer is shaped for: a `ListToolsResult`
//!      extends `CacheableResult`, so the answer carries `ttlMs` and
//!      `cacheScope` and the previous revision's decoder would refuse it.
//!   3. `tools/call` for a tool that answers, decoded with
//!      `mcp.decodeToolCallResult` and compared with the argument that went
//!      out, because a result with content in it is not evidence that the tool
//!      ran.
//!   4. `tools/call` for a tool that fails: a result with `isError`, which is
//!      not a peer error, and the difference is the point of the step.
//!   5. `tools/call` with params that omit the required `name`, so the peer
//!      answers with a JSON-RPC error and no result at all.
//!   6. `tools/call` for a tool that answers with an interim result: this
//!      client reads it with `mcp.decodeInputRequiredResult`, checks the
//!      method it asked for with `mcp.lookupInputRequest`, builds the retry
//!      from the server-assigned key and the opaque `requestState`, and sends
//!      it under a new id.
//!
//! Then it hangs up: the connection is closed and the process exits, so the
//! peer sees end of file and shuts down on its own. The supervisor checks that
//! it did.
//!
//! ## The envelope every request carries
//!
//! PROTOCOLS.md 4.8 makes the protocol version and the client capabilities
//! members of each request's `params._meta` at this revision, and the SDK's
//! own ladder refuses a request whose `_meta` lacks either
//! (`mcp.shared.inbound.classify_inbound_request`, rung one). `mcp_session.Client`
//! splices the capabilities in from its `capabilities` field; the version and
//! the client info are this participant's own `_meta`, which that same call
//! merges rather than writes beside. Two shapes, one object on the wire, and
//! neither side of it is a substitute codec: the merge is `mcp_session`'s and
//! the members are this participant's.
//!
//! ## What the retry carries, and why this file builds it
//!
//! `mcp_session.Client.respond` drives an interim result to completion, and it
//! takes the answer *before* the first leg goes out. A `requestState` is
//! minted by the server and opaque to the client, so the answer cannot be
//! written before the interim result has been read. This file therefore drives
//! the two legs itself, with the same public decoders `respond` uses:
//! `mcp.classifyResult` on each answer, `mcp.decodeInputRequiredResult` on the
//! interim one, and `mcp.decodeCacheLeg` on the params it composed — which is
//! what proves the retry is on the leg the no-cache rule names.
//!
//! [`buildRetryParams`] is the one encoder here, and it exists because 4.7 gives
//! the retry no typed builder. It writes with `json.Writer` rather than
//! splicing, because `requestState` is attacker-controlled: a state carrying a
//! quote, a backslash or a byte that is not UTF-8 would end the member early
//! or produce a literal this library's own reader refuses on the far side of
//! the wire, and the sending side would report it as written.
//!
//! ## Output
//!
//! Standard output is the wire and carries nothing else. The report goes to
//! standard error, and the machine-readable findings go to the file
//! `--report-file` names, which the supervisor reads. Every field in that
//! report is a value the peer sent and this client's decoder read, and the
//! supervisor checks each one against the bytes that crossed the pipes: a
//! report agreeing with a capture is evidence, and one that can be written
//! without looking at a wire is not.

const std = @import("std");
const proto = @import("zig-agent-proto");

const conn = proto.conn;
const json = proto.json;
const mcp = proto.mcp;
const mcp_session = proto.mcp_session;
const stdio = proto.stdio;

const Io = std.Io;
const testing = std.testing;

/// The revision this participant is pinned to.
///
/// `current` is `2026-07-28`. The gate in `mcp_session` reads the revision from
/// this one value, so the methods this file may send and the ones the peer may
/// answer are decided by the same pin the envelope declares.
const revision: mcp.Revision = .current;

/// The client capabilities object spliced into every request's `_meta`.
///
/// An empty object, and it is empty on purpose: the specification makes every
/// member optional and `{}` is a well-formed declaration of none. This client
/// answers an elicitation inside `inputResponses` rather than serving a
/// server-to-client request, so it claims nothing it does not do.
const client_capabilities = "{}";

/// The tool names. The peer serves exactly these, and a client that asked the
/// peer what it had rather than sending these would be testing the wrong thing:
/// the names are the interface, agreed by construction as any client's and a
/// server's are.
const tool_echo = "echo";
const tool_fail = "fail";
const tool_ask = "ask";

/// What this participant calls itself in the per-request envelope. A fixed
/// name and version, so a capture taken from two runs is comparable to another
/// and carries nothing about the machine that produced it.
const client_name = "zig-agent-proto-interop";
const client_version = "0.0.0";

/// The text the echo tool is called with, and the text its answer has to carry.
/// One value on both sides of the call, so the comparison the third step makes
/// is a comparison rather than two literals that happen to agree. The `ask`
/// tool is called with it too, so the fourth step's answer is checked the same
/// way against the same argument.
const echo_argument = "zig-agent-proto";

/// The answer this participant gives the elicitation the `ask` tool embeds.
///
/// `accept` with no `content`. The requested schema is the peer's to publish
/// and this client does not read it, so filling one in would be this run
/// inventing an answer to a question it never saw. Accepting with nothing
/// filled is the one answer that claims nothing.
const accept_answer = "{\"action\":\"accept\"}";

/// How long the whole exchange may take before this client stops waiting for
/// it and reports what it has.
///
/// Under the supervisor's own sixty-second deadline on purpose: a budget its
/// deadline reaches first is a budget whose diagnosis is never written, because
/// the process is killed before it can write one.
const exchange_budget_ms: i64 = 45_000;

/// The clock every bound in this file is measured on.
///
/// `awake` is monotonic and cannot be set, so a bound here is a promise about
/// elapsed time rather than about what a calendar says.
const clock: Io.Clock = .awake;

/// The `_meta` object every request carries, minus the capabilities member
/// `mcp_session.Client` splices in beside it.
///
/// Built at comptime from the names in `mcp` rather than written out, so the
/// reserved keys this file puts on the wire are the ones the library reserves
/// and a rename in `mcp.meta_key` moves this participant's envelope with it.
const envelope_meta = "\"_meta\":{\"" ++ mcp.meta_key.protocol_version ++
    "\":\"" ++ revision.string() ++ "\",\"" ++ mcp.meta_key.client_info ++
    "\":{\"name\":\"" ++ client_name ++ "\",\"version\":\"" ++ client_version ++ "\"}}";

/// The params of a request that has nothing else to say.
const discover_params: []const u8 = "{" ++ envelope_meta ++ "}";

/// The params of the two tool calls that pass an argument, with the envelope
/// beside the members the specification names.
///
/// One line each, because a newline inside params is what NDJSON forbids and
/// what the framing layer then refuses: these are the bytes the run depends on,
/// and a run that assembled them across lines would be one the peer cannot read.
const echo_params: []const u8 = "{\"name\":\"" ++ tool_echo ++
    "\",\"arguments\":{\"text\":\"" ++ echo_argument ++ "\"}," ++ envelope_meta ++ "}";
const ask_params: []const u8 = "{\"name\":\"" ++ tool_ask ++
    "\",\"arguments\":{\"text\":\"" ++ echo_argument ++ "\"}," ++ envelope_meta ++ "}";

/// The names this revision removed from the top level, which this client must
/// refuse rather than emulate.
///
/// Two sources and no third: `mcp.removed_methods` is the library's own table
/// of what `2026-07-28` took away, and the three `mcp.input_requests` are the
/// methods whose *top-level* use was removed — they survive inside
/// `InputRequiredResult.inputRequests`, which the fourth step reads, and as
/// requests at the previous revision. Both are checked with
/// `mcp_session.requestMethod` at this pin, and a name that resolved would fail
/// the run rather than reach the wire.
const removed_names = [_][]const u8{
    "initialize",
    "notifications/initialized",
    "ping",
    "logging/setLevel",
    "resources/subscribe",
    "resources/unsubscribe",
    "notifications/roots/list_changed",
    "notifications/elicitation/complete",
    "sampling/createMessage",
    "elicitation/create",
    "roots/list",
};

/// What the run received, in the order the supervisor checks it.
///
/// Peer-derived fields are decoded facts that the supervisor compares with
/// captured bytes. Revision and refused-method fields name this client's pin
/// and local gates; failure and ok describe local execution.
const Report = struct {
    /// The lock `fail` takes. The client task and the budget watcher both write
    /// here, and "the first failure is the finding" is a read-then-write that
    /// two tasks would otherwise interleave.
    io: Io,
    mutex: Io.Mutex = .init,

    revision: []const u8 = revision.string(),

    /// The versions `server/discover` answered with, copied out of the decode
    /// scratch and bounded on both counts. A peer that offered more than this
    /// report can hold is reported rather than quietly shortened: the
    /// supervisor compares this list with the wire and a difference fails the
    /// run.
    // SAFETY: keep copies one entry per version offered, and discover_versions reads at most that many.
    version_store: [8][32]u8 = undefined,
    discover_versions: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },
    discover_version_count: usize = 0,
    discover_ttl_ms: u64 = 0,
    discover_cache_scope: mcp.CacheScope = .private,
    /// Whether the advertised capabilities carried a `tools` member, read out
    /// of the lexeme `decodeDiscoverResult` carries rather than out of a typed
    /// shape this library does not model.
    discover_has_tools: bool = false,
    // SAFETY: keep copies the instructions into it and discover_instructions is set to that prefix.
    instructions_store: [256]u8 = undefined,
    discover_instructions: []const u8 = "",

    /// The tool names `tools/list` answered with, copied out of the decode
    /// scratch and bounded on both counts.
    // SAFETY: keep copies one entry per name offered, and tools reads at most that many.
    tool_name_store: [8][32]u8 = undefined,
    tools: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },
    tool_count: usize = 0,
    tool_list_ttl_ms: u64 = 0,
    tool_list_cache_scope: mcp.CacheScope = .private,

    /// The text the echo tool came back with. What went out in the call's own
    /// params is what this is compared against, rather than a flag saying the
    /// result carried content: content is not evidence that the tool ran.
    // SAFETY: keep copies the echoed text into it and echo_text is set to that prefix.
    echo_store: [128]u8 = undefined,
    echo_text: []const u8 = "",

    fail_is_error: bool = false,
    /// The code the peer sent beside its error object. Optional because an
    /// error answer carrying no code is a shape this run refuses rather than
    /// one it reports as a zero.
    peer_error_code: ?i32 = null,

    /// The interim result's own members, as this client read them. The
    /// `resultType` gets a store of its own: it is the wire value, so the
    /// supervisor compares it with the capture, and sharing a store with the
    /// discover instructions would leave one of them reporting the other's text.
    // SAFETY: keep copies the resultType into it and mrtr_result_type is set to that prefix.
    result_type_store: [32]u8 = undefined,
    mrtr_result_type: []const u8 = "",
    // SAFETY: keep copies the server-assigned key into it and mrtr_key is set to that prefix.
    key_store: [64]u8 = undefined,
    mrtr_key: []const u8 = "",
    // SAFETY: keep copies the method into it and mrtr_method is set to that prefix.
    method_store: [48]u8 = undefined,
    mrtr_method: []const u8 = "",
    /// The length of the opaque `requestState` and its first four characters,
    /// rather than the state itself: it is server-minted and attacker-influenced,
    /// and a report is not the place to carry a token around. The supervisor
    /// compares the length and the prefix against the wire, and checks the retry
    /// carried the whole thing byte for byte against the peer it came from.
    mrtr_state_len: usize = 0,
    // SAFETY: keep copies the prefix into it and mrtr_state_prefix is set to that prefix.
    state_prefix_store: [8]u8 = undefined,
    mrtr_state_prefix: []const u8 = "",
    /// What `mcp.decodeCacheLeg` said about the params the retry went out with.
    mrtr_retry_leg: mcp.CacheLeg = .original,
    /// The text the tool answered with after the retry, checked against the
    /// argument that went out on the first leg.
    // SAFETY: keep copies the resumed text into it and mrtr_echo_text is set to that prefix.
    resumed_store: [128]u8 = undefined,
    mrtr_echo_text: []const u8 = "",

    /// How many names this client refused before the wire, and the list it
    /// refused. The count is the claim and the names are what it was made from.
    refused_count: usize = 0,
    // SAFETY: keep copies each refused name into it and refused reads at most that many.
    refused_store: [removed_names.len][48]u8 = undefined,
    refused: [removed_names.len][]const u8 = .{
        "", "", "", "", "", "", "", "", "", "", "",
    },

    failure: []const u8 = "",
    ok: bool = false,
};

/// The most bytes one failure message holds.
///
/// `fail` copies into the buffer it is handed and both callers hand it one of
/// these, so `failure` is one of them and nothing longer. It is named because
/// the report's bound below has to include it: a bound quoting a number the
/// messages do not carry is a bound about a report that does not exist.
const failure_capacity: usize = 512;

/// The most bytes the report's own storage holds as text.
///
/// Every peer string in [`Report`] is a slice into a fixed array declared
/// beside it — `keep` is the one place those slices are made — so
/// `@sizeOf(Report)` covers all of them along with the slice headers, the
/// counters and the lock this struct carries. Reading it rather than summing
/// the arrays out by hand is what makes a store added here widen the bound
/// with it.
const report_text_capacity: usize = @sizeOf(Report) + failure_capacity;

/// The most bytes one decoded byte costs in the report.
///
/// `json.Writer.string` escapes what the JSON grammar forbids and passes
/// every other byte through, so the widest case is a control byte written as
/// `\u00XX`: six bytes for one. A peer answering with instructions, a request
/// state or a tool name carrying control bytes fills every store in this
/// report with them, and a bound sized for printable text is short by six
/// times over.
const report_escape_width: usize = 6;

/// The bytes the report spends on what is not a decoded byte.
///
/// Every member name with its quotes and its colon, the schema literal, the
/// brackets, the commas, one decimal rendering per number and one tag name
/// per enum: well under a kilobyte for this schema at its widest. It is a
/// fixed number rather than a derived one because the schema is fixed, and
/// 2048 is the next step above that kilobyte — slack this file does not have
/// to keep true by hand, in place of a bound that moves every time a member is
/// added.
const report_syntax_capacity: usize = 2048;

/// The buffer the report is composed in, before the one write that hands it to
/// the file.
///
/// Six bytes for every byte the report's own storage holds, plus the syntax
/// around them: the whole report at the worst escaping a peer can produce,
/// with nothing allocated to get there and nothing grown when it does not fit.
const report_capacity: usize = report_escape_width * report_text_capacity + report_syntax_capacity;

/// Which of the two ended the exchange: the client task finished it, or the
/// budget ran out first.
///
/// One lock for the decision, because the two are one decision taken from two
/// sides and only one of them may stand. The client task marks itself finished
/// as it returns, on every path including a failed check, and the watcher asks
/// before it records anything; whichever of the two takes the lock first
/// reached the end of the exchange first in real time, so a run that finished
/// inside its budget never reports that it did not, and a run that outlasted it
/// reports that rather than the transport fault the main task's own close
/// produces on the way out.
const Ending = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    finished: bool = false,

    fn finish(self: *Ending) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.finished = true;
    }

    /// Whether the client task had not finished when this was asked.
    fn outstanding(self: *Ending) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.finished;
    }
};

/// What this participant takes on the command line.
///
/// The supervisor passes `--report-file` and may pass `--budget-ms`; a run
/// without either still works and simply has less to hand back. `--budget-ms`
/// is a bound on this client's own wait, and the supervisor's `--deadline` is
/// the bound on the whole run: the first is under the second on purpose, so a
/// budget that runs out is a finding this client writes down rather than a
/// process the supervisor kills before it can.
const Options = struct {
    report_file: ?[]const u8 = null,
    budget_ms: i64 = exchange_budget_ms,
};

/// The smallest budget a run may be given, in milliseconds.
///
/// A second is refused rather than clamped below it, because a budget that
/// short is a typo and a clamped one runs the exchange to a stop and then
/// reports a timeout that says nothing about the peer.
const budget_min_ms: i64 = 1_000;

/// The largest budget a run may be given: the supervisor's own default
/// deadline, so a budget above it could never be recorded as a finding before
/// the process is killed.
const budget_max_ms: i64 = 60_000;

/// The most words this participant reads after its own name.
///
/// Eight is two flags and their two values with room beside them; the bound is
/// here so a line longer than any of them is a refusal rather than a
/// truncation, and so [`readWords`] has storage whose size is this file's own
/// decision rather than a default.
const max_words: usize = 8;

/// What a command line can be wrong in.
///
/// Kept apart from every protocol fault this file reports: none of these is
/// anything the peer said, and all of them are decided before a peer exists.
const CliError = error{
    /// A word beginning with `-` that is not one of this file's flags.
    UnknownFlag,
    /// A flag given twice. The last one winning is not a reading of the line
    /// anybody wrote.
    DuplicateFlag,
    /// A flag with nothing after it, or with another flag where its value
    /// belongs.
    MissingValue,
    /// A word that is not a flag at all.
    UnexpectedArgument,
    /// More words than [`max_words`].
    TooManyWords,
    /// A `--budget-ms` that is not a run of decimal digits.
    NotANumber,
    /// A `--budget-ms` no `i64` holds.
    BudgetOverflow,
    /// A `--budget-ms` outside `budget_min_ms..budget_max_ms`.
    BudgetOutOfRange,
};

/// The usage, printed beside every refused line.
const usage =
    \\usage: mcp-current-interop [--report-file PATH] [--budget-ms N]
    \\
    \\  --report-file PATH    where the machine-readable report goes. The
    \\                         supervisor reads it; a run without one reports on
    \\                         standard error only and still exits with the same
    \\                         status.
    \\  --budget-ms N         how long this client waits for the exchange before
    \\                         it stops and reports what it has, {d}..{d}. Under
    \\                         the supervisor's own deadline on purpose, so an
    \\                         exhausted budget is a finding this process writes
    \\                         down rather than a process killed before it can
    \\                         write one. Defaults to {d}.
    \\
    \\A flag given twice, a flag with no value after it, an unknown flag, a word
    \\that is not a flag, and a budget outside its range are each refused on
    \\standard error beside this usage, with exit status 2.
    \\
    \\A passing run writes one JSON report to its report file and a summary to
    \\standard error. A failed check is a non-zero exit, the same report, and a
    \\"failure" member that says which check. Standard output is the wire and
    \\carries nothing else.
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The line is read and parsed before anything else happens, and a refusal
    // leaves through `exit(2)` with the usage beside the reason. Nothing is
    // written to standard output before the line has been read, so a refused
    // line leaves the usage and nothing else — never a partial frame on a
    // stream that is the wire.
    var words: [max_words][]const u8 = undefined;
    const line = readWords(init, &words) catch |fault| try refuse(io, fault);
    const options = parseArgs(line) catch |fault| try refuse(io, fault);
    var report_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &report_buffer);
    const err = &stderr.interface;

    // The report is a string, so it needs storage that outlives every task
    // below, and so does the message a failed check leaves behind. Both are
    // fixed buffers, because the failure path allocates nothing either.
    var message: [failure_capacity]u8 = undefined;
    var report: Report = .{ .io = io };

    var transport = try stdio.Stdio.init(io, &buffers.read, &buffers.write);
    var connection = try transport.connection(buffers.config());

    var group: Io.Group = .init;
    defer group.cancel(io);
    defer connection.close();
    var done: Io.Semaphore = .{};
    var ending: Ending = .{ .io = io };

    // Spawned on the group the main task joins, and joined with `cancel` rather
    // than `await`: the reader's whole life is a blocking read on a pipe the
    // peer only closes when this process exits, so awaiting it would wait for
    // an event this process is what causes. `close` is the decision and
    // cancelling the group is how the task is told to stop, in that order.
    try group.concurrent(io, readLoop, .{&connection});
    try group.concurrent(
        io,
        clientTask,
        .{ io, &connection, &ending, &done, &report, &message },
    );

    // The bound on the wait below, armed before the main task starts waiting
    // and cancelled with everything else once it stops.
    try group.concurrent(
        io,
        budgetTask,
        .{ io, options.budget_ms, &ending, &report, &message, &done },
    );

    // The client task posts this when the exchange is over, and the budget
    // watcher posts it when the exchange has outlasted any run of this exchange
    // should. Waiting here rather than awaiting the group is what keeps the
    // reader's blocked read from being the thing the main task waits on:
    // closing the connection and cancelling the group below is what ends that
    // read, and cancelling the group joins every task.
    //
    // What the wait ended *on* is not decided after that close. The watcher has
    // already recorded what its budget found, and the tasks the close ends are
    // answering a transport fault this run caused, so a finding made after it
    // would name the mechanism rather than the cause.
    done.waitUncancelable(io);

    connection.close();
    group.cancel(io);

    // Every frame is flushed as it is written, so there is nothing pending
    // here; a flush that fails anyway is a cause the run reports rather than
    // drops, because the peer reads a lost last frame as a truncated message.
    transport.flush() catch |flush_err| {
        var detail: [256]u8 = undefined;
        fail(&report, &message, cause("the last flush before hanging up failed", &detail, flush_err));
    };

    // Every task is joined above, so nothing is still writing the report and
    // what follows reads a finished run. `fail` keeps the first failure, so a
    // step that named what it found sooner — a peer that refused the
    // handshake-free discover, a call the peer answered with an error — is
    // still what this run reports, and the budget is the finding only for a run
    // in which nothing got far enough to name one.
    //
    // Read under the lock the tasks wrote their findings with. Nothing can take
    // it now that the group is joined; taking it anyway keeps this read and
    // those writes under one rule rather than two.
    report.mutex.lockUncancelable(io);
    report.ok = report.failure.len == 0;
    report.mutex.unlock(io);
    try writeReport(io, &options, &report);
    try printSummary(err, &report);
    try stderr.flush();
    if (!report.ok) std.process.exit(1);
}

/// The reader task: this connection's whole job until it is told to stop.
fn readLoop(connection: *conn.Conn) void {
    connection.pump();
}

/// The task that bounds the main task's wait on the exchange.
///
/// It waits the budget out and then records that the budget is what this run
/// has found, before it wakes the main task. Recording first is the whole of
/// the order here: the main task answers a budget that ran out by closing the
/// connection, and a client task still parked in a call the peer will never
/// answer fails that call with a transport fault the instant the connection
/// closes.
///
/// The group's cancelation interrupts the wait, so a run that finished never
/// waits the budget out.
fn budgetTask(
    io: Io,
    budget_ms: i64,
    ending: *Ending,
    report: *Report,
    message: *[failure_capacity]u8,
    done: *Io.Semaphore,
) void {
    // A deadline on the monotonic clock rather than one sleep, so the budget
    // ends when it says it does whether or not a sleep is woken when it was
    // asked to be, and a wall-clock step cannot decide it either way.
    const deadline = Io.Clock.Timestamp.fromNow(io, .{
        .clock = clock,
        .raw = Io.Duration.fromMilliseconds(budget_ms),
    });
    while (true) {
        const remaining = deadline.durationFromNow(io);
        if (remaining.raw.nanoseconds <= 0) break;
        // The only failure a wait here can carry is this group's cancelation,
        // and by the time it arrives the exchange is over or has already been
        // given up on: there is nothing left to say, and the main task is not
        // waiting on this task anyway.
        remaining.sleep(io) catch return;
    }
    // A run whose exchange ended before the budget is not one that outlasted
    // it, whatever order the two reached this point in: the client task says so
    // under the lock, and the lock is what says which of them came first.
    if (!ending.outstanding()) return;
    var detail: [256]u8 = undefined;
    const text: []const u8 = std.fmt.bufPrint(&detail, "the exchange did not finish inside its {d}ms budget", .{
        budget_ms,
    }) catch "the exchange did not finish inside its budget";
    fail(report, message, text);
    done.post(io);
}

/// The client task: the whole exchange, in the order the specification requires.
fn clientTask(
    io: Io,
    connection: *conn.Conn,
    ending: *Ending,
    done: *Io.Semaphore,
    report: *Report,
    message: *[failure_capacity]u8,
) void {
    defer {
        // Marked before the post, and on every path out including a failed
        // check: the main task waits on this post, so a task that returned
        // without it would hang the run, and the watcher asks under the lock
        // whether the exchange ended, so a post the watcher has not seen yet
        // would have it report a budget that this run did not outlast.
        ending.finish();
        done.post(io);
    }
    // Where a cause is formatted, in a buffer of its own: a failure is named
    // by the step that ran and the error it failed with, and the finding it
    // lands in is filled a step at a time.
    var detail: [256]u8 = undefined;

    // One session, one pin. At this revision the capabilities ride in `_meta`
    // on every request, which is what `Client.request` itself does once
    // `capabilities` is set; the version and the client info are in the params
    // this file composes and that call merges them beside.
    var session = mcp_session.Client.init(connection, revision);
    session.capabilities = client_capabilities;

    // 0. The names this revision removed, refused before the wire rather than
    //    emulated by a call the peer may or may not still accept. A name that
    //    resolved would mean the pin and the gate disagree, which is a broken
    //    run rather than a slow peer.
    for (removed_names, 0..) |name, index| {
        if (mcp_session.requestMethod(revision, name)) |_| {
            fail(report, message, "a method this revision removed still resolves as a request");
            return;
        } else |err| switch (err) {
            error.MethodNotInRevision => {},
            // A name refused for its arity is refused for the wrong reason:
            // this list is about what the revision removed, and a notification
            // or a server-to-client name reaching it means the two tables
            // disagree about what exists.
            error.NotARequest => {
                fail(report, message, "a removed name was refused as a notification rather than as removed");
                return;
            },
        }
        if (!mcp.isRemovedMethod(revision, name)) {
            fail(report, message, "a name this client refuses as removed is not in the library's table");
            return;
        }
        report.refused[index] = keep(&report.refused_store[index], name);
    }
    report.refused_count = removed_names.len;

    // 1. server/discover, the only mandatory method at this revision, and the
    //    first request on the wire: the SDK's era routing decides from the first
    //    request's envelope, so a client that opened with a handshake-era frame
    //    would be answering a different protocol for the rest of the run.
    const discover = session.request(
        "server/discover",
        discover_params,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "server/discover: the call itself failed", &detail, err);
        return;
    };
    if (discover.failed()) {
        fail(report, message, "server/discover: the peer refused the request");
        return;
    }
    // The answer is checked against the method table before it is decoded: a
    // peer that left out a caching member would be refused by `decodeDiscoverResult`
    // as a missing field, and this check says which member it was.
    const discover_info = mcp_session.requestMethod(revision, "server/discover") catch |err| {
        record(report, message, "server/discover: the method table refused the name", &detail, err);
        return;
    };
    mcp.checkResult(discover_info, discover.body, &client_scratch) catch |err| {
        record(report, message, "server/discover: the result does not satisfy the revision", &detail, err);
        return;
    };
    const discovery = mcp.decodeDiscoverResult(
        discover.body,
        &version_scratch,
        &verbatim,
        &client_scratch,
    ) catch |err| {
        record(report, message, "server/discover: the result did not decode", &detail, err);
        return;
    };
    // The pin is this client's, and the pin is what the envelope declared, so a
    // peer answering a version this client did not ask for is refused here.
    // Nothing is negotiated at this revision, which is the whole difference
    // from the previous-revision exchange: the answer is a claim to check, not
    // a choice to make.
    if (!offered(discovery.supported_versions, revision.string())) {
        fail(report, message, "server/discover: the peer does not offer the revision this client is pinned to");
        return;
    }
    if (discovery.supported_versions.len > report.discover_versions.len) {
        fail(report, message, "server/discover: the peer offered more versions than this report holds");
        return;
    }
    report.discover_version_count = discovery.supported_versions.len;
    for (discovery.supported_versions, 0..) |version, index| {
        report.discover_versions[index] = keep(&report.version_store[index], version);
    }
    report.discover_ttl_ms = discovery.cacheable.ttl_ms;
    report.discover_cache_scope = discovery.cacheable.cache_scope;
    report.discover_has_tools =
        json.memberText(discovery.capabilities, "tools", &client_scratch) != null;
    report.discover_instructions = keep(&report.instructions_store, discovery.instructions orelse "");
    if (!report.discover_has_tools) {
        fail(report, message, "server/discover: the peer advertised no tools capability");
        return;
    }

    // 2. tools/list, read with this revision's decoder: a ListToolsResult
    //    extends CacheableResult, so the answer carries ttlMs and cacheScope and
    //    the previous revision's decoder would refuse it for a missing member.
    const listed = session.request(
        "tools/list",
        discover_params,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "tools/list: the call itself failed", &detail, err);
        return;
    };
    if (listed.failed()) {
        fail(report, message, "tools/list: the peer refused the request");
        return;
    }
    const list_info = mcp_session.requestMethod(revision, "tools/list") catch |err| {
        record(report, message, "tools/list: the method table refused the name", &detail, err);
        return;
    };
    mcp.checkResult(list_info, listed.body, &client_scratch) catch |err| {
        record(report, message, "tools/list: the result does not satisfy the revision", &detail, err);
        return;
    };
    const catalogue = mcp.decodeToolListResult(
        listed.body,
        &tool_scratch,
        &verbatim,
        &client_scratch,
    ) catch |err| {
        record(report, message, "tools/list: the result did not decode", &detail, err);
        return;
    };
    if (catalogue.tools.len > report.tools.len) {
        fail(report, message, "tools/list: the peer offered more tools than this report holds");
        return;
    }
    report.tool_count = catalogue.tools.len;
    for (catalogue.tools, 0..) |tool, index| {
        report.tools[index] = keep(&report.tool_name_store[index], tool.name);
    }
    report.tool_list_ttl_ms = catalogue.cacheable.ttl_ms;
    report.tool_list_cache_scope = catalogue.cacheable.cache_scope;
    if (!offerNames(catalogue.tools, tool_echo) or !offerNames(catalogue.tools, tool_fail) or
        !offerNames(catalogue.tools, tool_ask))
    {
        fail(report, message, "tools/list: the peer did not offer the three tools this client calls");
        return;
    }

    // 3. A tool that answers. The text that came back is compared with the text
    //    that went out, because a result carrying content is not evidence that
    //    the tool ran: any result with a block in it would pass that.
    const echoed = session.request(
        "tools/call",
        echo_params,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "tools/call echo: the call itself failed", &detail, err);
        return;
    };
    if (echoed.failed()) {
        fail(report, message, "tools/call echo: the peer answered with an error");
        return;
    }
    const echo_result = mcp.decodeToolCallResult(
        echoed.body,
        &content,
        &verbatim,
        &client_scratch,
    ) catch |err| {
        record(report, message, "tools/call echo: the result did not decode", &detail, err);
        return;
    };
    if (echo_result.is_error == true) {
        fail(report, message, "tools/call echo: a call the peer accepted came back with isError");
        return;
    }
    const echoed_text = firstText(echo_result.content) orelse {
        fail(report, message, "tools/call echo: the result carried no text block");
        return;
    };
    report.echo_text = keep(&report.echo_store, echoed_text);
    if (!std.mem.eql(u8, echoed_text, echo_argument)) {
        fail(report, message, "tools/call echo: the peer answered with text this client did not send");
        return;
    }

    // 4. A tool that fails. The failure is inside the result, so this call
    //    succeeded as a call: reading the answer as an error would be the
    //    mistake this step exists to rule out.
    const failed_call = session.request(
        "tools/call",
        "{\"name\":\"" ++ tool_fail ++ "\"," ++ envelope_meta ++ "}",
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "tools/call fail: the call itself failed", &detail, err);
        return;
    };
    if (failed_call.failed()) {
        fail(report, message, "tools/call fail: a failing tool was answered as a peer error");
        return;
    }
    const fail_result = mcp.decodeToolCallResult(
        failed_call.body,
        &content,
        &verbatim,
        &client_scratch,
    ) catch |err| {
        record(report, message, "tools/call fail: the result did not decode", &detail, err);
        return;
    };
    report.fail_is_error = fail_result.is_error == true;
    if (!report.fail_is_error) {
        fail(report, message, "tools/call fail: a failing tool did not answer with isError");
        return;
    }

    // 5. A call the peer must refuse: the params carry no name, and the name is
    //    the required member the specification names. The peer answers with a
    //    JSON-RPC error, and this client reads it as an error beside the body
    //    rather than as a result.
    const refused = session.request(
        "tools/call",
        discover_params,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "tools/call with no name: the call itself failed", &detail, err);
        return;
    };
    if (!refused.failed()) {
        fail(report, message, "tools/call with no name: the peer answered with a result");
        return;
    }
    // An error answer carries no result member, so there is nothing to decode:
    // the body is the error object and the code beside it is what says so. An
    // error with no code is reported as what it is rather than as a zero,
    // which is a code the peer could have meant.
    report.peer_error_code = refused.error_code orelse {
        fail(report, message, "tools/call with no name: the peer's error carried no code");
        return;
    };

    // 6. The multi-round-trip exchange. The first leg is a call like any
    //    other, so `tools/call` is gated for it exactly as the steps above were.
    const first = session.request(
        "tools/call",
        ask_params,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "tools/call ask: the first call itself failed", &detail, err);
        return;
    };
    if (first.failed()) {
        fail(report, message, "tools/call ask: the peer answered the first leg with an error");
        return;
    }
    // Classified before it is decoded as anything: an interim result is not the
    // final answer, and handing one back as one is the mistake this step exists
    // to rule out.
    const kind = mcp.classifyResult(first.body, &client_scratch) catch |err| {
        record(report, message, "tools/call ask: the first answer is not a result", &detail, err);
        return;
    };
    if (kind.known() == null) {
        fail(report, message, "tools/call ask: the peer sent a resultType this client does not define");
        return;
    }
    if (kind.isComplete()) {
        fail(report, message, "tools/call ask: the first leg completed rather than asking for input");
        return;
    }
    if (!mcp.permitsMrtr("tools/call")) {
        fail(report, message, "tools/call ask: the method table does not permit an interim result here");
        return;
    }
    report.mrtr_result_type = keep(&report.result_type_store, kind.value orelse "");
    const interim = mcp.decodeInputRequiredResult(
        first.body,
        &verbatim,
        &client_scratch,
    ) catch |err| {
        record(report, message, "tools/call ask: the interim result did not decode", &detail, err);
        return;
    };
    // The map the peer keyed its questions by, read with this file's own view:
    // the library carries `inputRequests` as a lexeme and offers
    // `lookupInputRequest` for a name a consumer reads out of it, and this run
    // needs exactly one key and one method to answer with.
    //
    // Its own scratch, not the decoders': `interim.request_state` is read as a
    // JSON string and borrows `client_scratch` whenever the peer wrote an
    // escape, so a walk sharing that region could overwrite the state between
    // decoding it and building the retry with it.
    //
    // The map is borrowed from the answer in `buffers.result`, which is read
    // before the retry below writes to that same buffer.
    const requests = interim.input_requests orelse {
        fail(report, message, "tools/call ask: the interim result carried no inputRequests");
        return;
    };
    const question = firstInputRequest(requests, &input_scratch) catch |err| {
        record(report, message, "tools/call ask: the inputRequests map did not decode", &detail, err);
        return;
    };
    // The method inside the map is one of the three the specification names, and
    // `lookupInputRequest` is the entry point that decides it: a map is any
    // JSON value to the decoder, so the name inside it is checked here or not at
    // all.
    _ = mcp.lookupInputRequest(question.method) catch |err| {
        record(report, message, "tools/call ask: the peer asked with a method outside the InputRequest union", &detail, err);
        return;
    };
    report.mrtr_key = keep(&report.key_store, question.key);
    report.mrtr_method = keep(&report.method_store, question.method);
    // The state is needed to build the retry and is not kept: it is opaque,
    // server-minted and attacker-influenced, so the report carries its length
    // and its first four characters and the retry carries the whole of it.
    const state = interim.request_state orelse {
        fail(report, message, "tools/call ask: the interim result carried no requestState");
        return;
    };
    report.mrtr_state_len = state.len;
    report.mrtr_state_prefix = keep(&report.state_prefix_store, state[0..@min(state.len, 4)]);

    // The retry, composed here rather than by `respond` because the state was
    // minted by the answer this step read. It goes out under a new id, which
    // `conn.call` guarantees and the supervisor checks.
    const retry = buildRetryParams(
        &retry_params,
        tool_ask,
        echo_argument,
        question.key,
        accept_answer,
        state,
    ) catch |err| {
        record(report, message, "tools/call ask: the retry params did not compose", &detail, err);
        return;
    };
    // The no-cache rule reads "requests carrying inputResponses or
    // requestState", and `decodeCacheLeg` is what says which leg a document is
    // on. A retry this file built reading as the original leg would mean the
    // members it wrote are not the ones the rule names.
    report.mrtr_retry_leg = mcp.decodeCacheLeg(retry, &client_scratch) catch |err| {
        record(report, message, "tools/call ask: the retry params did not decode", &detail, err);
        return;
    };
    if (report.mrtr_retry_leg != .mrtr_retry) {
        fail(report, message, "tools/call ask: the retry does not carry what makes it a retry");
        return;
    }
    const second = session.request(
        "tools/call",
        retry,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "tools/call ask: the retry itself failed", &detail, err);
        return;
    };
    if (second.failed()) {
        fail(report, message, "tools/call ask: the peer refused the retry with an error");
        return;
    }
    const retried = mcp.classifyResult(second.body, &client_scratch) catch |err| {
        record(report, message, "tools/call ask: the retry answer is not a result", &detail, err);
        return;
    };
    if (!retried.isComplete()) {
        fail(report, message, "tools/call ask: the retry was answered with another interim result");
        return;
    }
    const resumed = mcp.decodeToolCallResult(
        second.body,
        &content,
        &verbatim,
        &client_scratch,
    ) catch |err| {
        record(report, message, "tools/call ask: the retry answer did not decode", &detail, err);
        return;
    };
    if (resumed.is_error == true) {
        fail(report, message, "tools/call ask: a call the peer accepted came back with isError");
        return;
    }
    const resumed_text = firstText(resumed.content) orelse {
        fail(report, message, "tools/call ask: the retry answer carried no text block");
        return;
    };
    report.mrtr_echo_text = keep(&report.resumed_store, resumed_text);
    if (!std.mem.eql(u8, resumed_text, echo_argument)) {
        fail(report, message, "tools/call ask: the peer answered with text this client did not send");
        return;
    }
}

/// Whether the peer's answer offered the tool this run calls.
///
/// Over the names rather than over decoded tools, because names are all this
/// run reads out of the answer: it calls the three tools by name and never
/// looks at a schema, so a list it can compare is the list it asked for.
fn offerNames(offered_tools: []const mcp.Tool, name: []const u8) bool {
    for (offered_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

/// Whether the peer's answer offered a revision by name.
fn offered(offered_versions: []const []const u8, name: []const u8) bool {
    for (offered_versions) |version| {
        if (std.mem.eql(u8, version, name)) return true;
    }
    return false;
}

/// Copy a decoded string out of the decode scratch into storage that outlives
/// it.
///
/// The scratch is reused by the next decode, so a report field that borrowed
/// from it would say whatever the last decode left behind. Truncating rather
/// than refusing keeps a long peer string from turning a check into a
/// failure: every check below compares the whole decoded text, and only the
/// report is bounded.
///
/// The cut is on a code point. `text` came out of a decoder, so it is valid
/// UTF-8, and the only thing uncertain about a prefix of it is where a code
/// point ends: a cut at the storage's capacity can land between a lead byte and
/// its continuations, and the report then holds bytes the JSON grammar has no
/// spelling for. So the code point the cut landed in is the one dropped, and
/// what is kept is the longest prefix that is whole code points.
fn keep(storage: []u8, text: []const u8) []const u8 {
    var room = @min(text.len, storage.len);
    if (room < text.len) {
        // `text[room]` is the first byte that did not fit. A continuation byte
        // there is the tail of a code point that starts inside the prefix, so
        // the cut moves back to that code point's lead byte — the walk stops
        // on the lead byte rather than going past it, because the byte before
        // it may be the tail of one of its own.
        while (room > 0 and (text[room] & 0xc0) == 0x80) : (room -= 1) {}
    }
    @memcpy(storage[0..room], text[0..room]);
    return storage[0..room];
}

/// The text of the first text block, or null when a result carried none.
fn firstText(blocks: []const mcp.ContentBlock) ?[]const u8 {
    for (blocks) |block| switch (block) {
        .text => |value| return value.text,
        else => {},
    };
    return null;
}

// --- the two answers this file reads for itself ---------------------------------
//
// Both are one borrowing `json.Reader` over the peer's own bytes: a key and a
// method name are slices of the document or of the caller's scratch, never a
// copy of it, and neither reader needs a sub-reader of its own — the members
// are read where the walk stands, so there is no lexeme to hand to a second
// cursor and no scratch to hand it from.

/// One question out of an `inputRequests` map.
const InputQuestion = struct {
    /// The server-assigned key the answer has to be filed under.
    key: []const u8,
    /// The method inside that key's object.
    method: []const u8,
};

/// Read the first question out of an `InputRequiredResult.inputRequests` map.
///
/// This run answers exactly one question and the peer mints exactly one, so the
/// first entry is the one that gets answered; the count is not read because a
/// peer that asked more would be answered for the first and the rest would go
/// unanswered, which the supervisor's check on the wire would catch. `out` is
/// the caller's array and `scratch` is the caller's escape scratch; nothing here
/// allocates and nothing is copied out of the document.
///
/// `mcp.decodeInputRequiredResult` carries `inputRequests` as a borrowed
/// lexeme and checks only that it is one JSON value, so the map is walked here.
/// A value that is not an object, an entry that is not an object, an entry with
/// no `method` and a `method` that is not a string are each refused, and so is
/// a document with a tail. The walk is finished rather than stopped at the
/// match: a repeated key is consumed and not read again, because the first
/// occurrence wins and a later one must not be able to make a comparison that
/// has already failed pass.
fn firstInputRequest(raw: []const u8, scratch: []u8) proto.DecodeError!InputQuestion {
    var reader = json.Reader.init(raw);
    var key: ?[]const u8 = null;
    var method: ?[]const u8 = null;
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |name| {
            if (key == null) {
                key = name;
                method = try inputRequestMethod(&reader, scratch);
                continue;
            }
            try reader.skipValue(scratch);
        }
    }
    if (!reader.atEnd()) return error.MalformedJson;
    const found_key = key orelse return error.MissingField;
    return .{ .key = found_key, .method = method orelse return error.MissingField };
}

/// The `method` of one question, read where the entry stands.
fn inputRequestMethod(reader: *json.Reader, scratch: []u8) proto.DecodeError![]const u8 {
    var method: ?[]const u8 = null;
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |name| {
            if (method == null and std.mem.eql(u8, name, "method")) {
                method = try reader.string(scratch);
                continue;
            }
            try reader.skipValue(scratch);
        }
    }
    return method orelse error.MissingField;
}

/// The params of the retry leg of a multi-round-trip exchange.
///
/// PROTOCOLS.md 4.7 gives the retry no typed builder — `mcp.inputRequired`
/// writes the *interim result* the server sends, not the request the client
/// answers it with — so this composes the members 4.7 names: the original
/// method's own members, the `inputResponses` map keyed as the interim result
/// keyed its questions, and the opaque `requestState` echoed byte for byte.
///
/// Every text goes through `json.Writer.string` rather than a splice, because two
/// of them are not this file's own: the server chose the key and the state. The
/// writer escapes the quotes and backslashes in them, which is what keeps a state
/// carrying JSON syntax from ending the member early.
///
/// `json.Writer.string` states its UTF-8 precondition as the caller's and does
/// not check it. Both of those values arrive from this library's own decoders —
/// the key from the `inputRequests` walk below, the state from
/// `mcp.decodeInputRequiredResult` — and `json.Reader.string` validates what it
/// decodes, so the precondition already holds on the path this file takes. The
/// check that follows is what makes it a precondition of *this* function rather
/// than of whoever called it: a caller that handed in bytes from anywhere else
/// would get `error.InvalidField` before the first byte rather than a literal
/// this library's own reader refuses on the far side of the wire.
///
/// `out` receives the params and the result borrows it. `error.BufferTooSmall`
/// is a short `out`: the writer escapes rather than truncates, so there is no
/// partial member to mistake for a params document and the caller grows the
/// buffer and calls again.
fn buildRetryParams(
    out: []u8,
    tool: []const u8,
    argument: []const u8,
    key: []const u8,
    answer: []const u8,
    state: []const u8,
) proto.EncodeError![]const u8 {
    if (!std.unicode.utf8ValidateSlice(state)) return error.InvalidField;
    var writer = json.Writer.init(out);
    writer.slice("{\"name\":") catch return error.BufferTooSmall;
    writer.string(tool) catch return error.BufferTooSmall;
    writer.slice(",\"arguments\":{\"text\":") catch return error.BufferTooSmall;
    writer.string(argument) catch return error.BufferTooSmall;
    writer.slice("},\"inputResponses\":{") catch return error.BufferTooSmall;
    writer.string(key) catch return error.BufferTooSmall;
    writer.byte(':') catch return error.BufferTooSmall;
    writer.slice(answer) catch return error.BufferTooSmall;
    writer.slice("},\"requestState\":") catch return error.BufferTooSmall;
    writer.string(state) catch return error.BufferTooSmall;
    writer.byte(',') catch return error.BufferTooSmall;
    writer.slice(envelope_meta) catch return error.BufferTooSmall;
    writer.byte('}') catch return error.BufferTooSmall;
    return writer.written();
}

/// A failed step and the error it failed with, in the message the supervisor
/// reads. A fixed string would name the step and hide the cause, which is the
/// one thing a run like this exists to report.
fn cause(step: []const u8, detail: []u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(detail, "{s}: {s}", .{ step, @errorName(err) }) catch step;
}

/// Record what a step failed with, unless the run was abandoned rather than a
/// step failing.
///
/// `Io.Group.cancel` is the only thing in this process that cancels a task, and
/// the main task does it exactly once: after it has decided that the exchange
/// is over or that its budget has run out. So `error.Canceled` names neither the
/// peer nor a step. Recording it would replace the reason the run ended with the
/// mechanism that ended it, and a peer that stopped talking half way through a
/// call would be reported as a call that failed with `Canceled` — the one thing
/// that error never means on this wire.
fn record(report: *Report, message: *[failure_capacity]u8, step: []const u8, detail: []u8, err: anyerror) void {
    if (err == error.Canceled) return;
    fail(report, message, cause(step, detail, err));
}

fn fail(report: *Report, message: *[failure_capacity]u8, text: []const u8) void {
    report.mutex.lockUncancelable(report.io);
    defer report.mutex.unlock(report.io);
    // The first failure is the finding; a later one is a consequence of it.
    if (report.failure.len != 0) return;
    const copied = @min(text.len, message.len - 1);
    @memcpy(message[0..copied], text[0..copied]);
    message[copied] = 0;
    report.failure = message[0..copied];
}

fn printSummary(err: *Io.Writer, report: *const Report) Io.Writer.Error!void {
    try err.print("zig-agent-proto mcp interop client, current revision ({s})\n", .{
        report.revision,
    });
    try err.print("  refused before the wire: {d} methods this revision removed\n", .{
        report.refused_count,
    });
    if (report.failure.len != 0) {
        try err.print("  FAILED: {s}\n", .{report.failure});
        return;
    }
    // Past this point every step that fills a field checked it first, so the
    // values below are known to be there rather than assumed to be.
    try err.print("  server/discover: {d} versions, the pin {s} among them; capabilities carried tools\n", .{
        report.discover_version_count, report.revision,
    });
    try err.print("  server/discover: ttlMs={d} cacheScope={s}\n", .{
        report.discover_ttl_ms, @tagName(report.discover_cache_scope),
    });
    try err.print("  tools/list: {d} tools: ", .{report.tool_count});
    for (namedTools(report), 0..) |name, index| {
        if (index != 0) try err.print(", ", .{});
        try err.print("{s}", .{name});
    }
    try err.print("\n", .{});
    try err.print("  tools/list: ttlMs={d} cacheScope={s}, both required at this revision\n", .{
        report.tool_list_ttl_ms, @tagName(report.tool_list_cache_scope),
    });
    try err.print("  tools/call {s}: a result carrying back the text that went out\n", .{tool_echo});
    try err.print("  tools/call {s}: a result with isError, which is not a peer error\n", .{
        tool_fail,
    });
    // A missing one is printed as the missing thing it is rather than as a
    // zero, which is a code the peer could have meant.
    const peer_code = report.peer_error_code orelse {
        try err.print("  tools/call with no name: the peer's error carried no code\n", .{});
        return;
    };
    try err.print("  tools/call with no name: a peer error, code {d}\n", .{peer_code});
    try err.print("  tools/call {s}: an interim result {s} asking {s} under {s}\n", .{
        tool_ask, report.mrtr_result_type, report.mrtr_method, report.mrtr_key,
    });
    try err.print("  tools/call {s}: requestState {d} bytes from {s}, retried on the {s} leg\n", .{
        tool_ask, report.mrtr_state_len, report.mrtr_state_prefix, @tagName(report.mrtr_retry_leg),
    });
    try err.print("  tools/call {s}: the retry answered with the text that went out\n", .{
        tool_ask,
    });
    try err.print("  hung up: the connection is closed and the peer will see end of file\n", .{});
}

/// The tool names this run received, which is as many as the peer offered up to
/// what the report holds.
fn namedTools(report: *const Report) []const []const u8 {
    return report.tools[0..@min(report.tool_count, report.tools.len)];
}

/// The revision names this run refused, which is every name it checked.
fn refusedNames(report: *const Report) []const []const u8 {
    return report.refused[0..@min(report.refused_count, report.refused.len)];
}

/// The report, in the machine-readable shape `test/interop/mcp_current_peer.py`
/// reads at the end of a run.
///
/// Every value here was decoded off the peer's own bytes by the library's
/// decoders before it was written, and the supervisor compares each one with
/// the capture rather than taking this object as evidence for anything.
fn writeReport(io: Io, options: *const Options, report: *const Report) !void {
    const path = options.report_file orelse return;
    var buffer: [report_capacity]u8 = undefined;
    const document = try encodeReport(&buffer, report);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = document,
    });
}

/// The report as one JSON object, in the caller's buffer.
///
/// Every value the peer sent went through `json.Writer.string`, so a text
/// carrying a quote, a backslash or a control byte leaves here as a string
/// literal rather than as a member that ends early or bytes a reader on the
/// far side refuses. The buffer is sized from [`report_capacity`], which is the
/// whole report at the worst escaping a peer can produce; a buffer with no
/// room is `error.BufferTooSmall` with the prefix already written left as it
/// was, never a document cut short.
fn encodeReport(buffer: []u8, report: *const Report) proto.EncodeError![]const u8 {
    var text = json.Writer.init(buffer);
    try text.slice("{\"schema\":\"zig-agent-proto/mcp-current-interop-report/2\"");
    try text.slice(",\"revision\":");
    try text.string(report.revision);
    try text.slice(",\"refused_methods_count\":");
    try number(&text, report.refused_count);
    try text.slice(",\"refused_methods\":[");
    for (refusedNames(report), 0..) |name, index| {
        if (index != 0) try text.byte(',');
        try text.string(name);
    }
    try text.slice("],\"discover_supported_versions\":[");
    for (report.discover_versions[0..report.discover_version_count], 0..) |version, index| {
        if (index != 0) try text.byte(',');
        try text.string(version);
    }
    try text.slice("],\"discover_ttl_ms\":");
    try number(&text, report.discover_ttl_ms);
    try text.slice(",\"discover_cache_scope\":");
    try text.string(@tagName(report.discover_cache_scope));
    try text.slice(",\"discover_has_tools_capability\":");
    try boolean(&text, report.discover_has_tools);
    try text.slice(",\"discover_instructions\":");
    try text.string(report.discover_instructions);
    try text.slice(",\"tools\":[");
    for (namedTools(report), 0..) |name, index| {
        if (index != 0) try text.byte(',');
        try text.string(name);
    }
    try text.slice("],\"tool_count\":");
    try number(&text, report.tool_count);
    try text.slice(",\"tool_list_ttl_ms\":");
    try number(&text, report.tool_list_ttl_ms);
    try text.slice(",\"tool_list_cache_scope\":");
    try text.string(@tagName(report.tool_list_cache_scope));
    try text.slice(",\"echo_text\":");
    try text.string(report.echo_text);
    try text.slice(",\"fail_is_error\":");
    try boolean(&text, report.fail_is_error);
    try text.slice(",\"peer_error_code\":");
    try optionalNumber(&text, report.peer_error_code);
    try text.slice(",\"mrtr_result_type\":");
    try text.string(report.mrtr_result_type);
    try text.slice(",\"mrtr_input_request_key\":");
    try text.string(report.mrtr_key);
    try text.slice(",\"mrtr_input_request_method\":");
    try text.string(report.mrtr_method);
    try text.slice(",\"mrtr_state_len\":");
    try number(&text, report.mrtr_state_len);
    try text.slice(",\"mrtr_state_prefix\":");
    try text.string(report.mrtr_state_prefix);
    try text.slice(",\"mrtr_retry_leg\":");
    try text.string(@tagName(report.mrtr_retry_leg));
    try text.slice(",\"mrtr_echo_text\":");
    try text.string(report.mrtr_echo_text);
    try text.slice(",\"failure\":");
    try text.string(report.failure);
    try text.slice(",\"ok\":");
    try boolean(&text, report.ok);
    try text.byte('}');

    return text.written();
}

fn number(text: *json.Writer, value: anytype) !void {
    var buffer: [24]u8 = undefined;
    const written = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.BufferTooSmall;
    try text.slice(written);
}

/// A code the peer sent beside an error, or null for a run that never got one.
fn optionalNumber(text: *json.Writer, value: ?i32) !void {
    if (value) |code| return number(text, @as(i64, code));
    try text.slice("null");
}

fn boolean(text: *json.Writer, value: bool) !void {
    try text.slice(if (value) "true" else "false");
}

/// Read the words after the program name into `storage`.
///
/// The program name is dropped: it is the shell's word, not the participant's,
/// and nothing below reads it. A line with more words than `storage` holds is a
/// refusal rather than a truncation, because a word this file never saw is a
/// flag it cannot have refused.
fn readWords(init: std.process.Init, storage: *[max_words][]const u8) CliError![]const []const u8 {
    var it = std.process.Args.iterate(init.minimal.args);
    _ = it.skip();
    var count: usize = 0;
    while (it.next()) |argument| {
        if (count == storage.len) return error.TooManyWords;
        // The iterator hands back a sentinel-terminated slice, and the words
        // this file compares are the bytes before the sentinel.
        storage[count] = argument[0..argument.len :0];
        count += 1;
    }
    return storage[0..count];
}

/// The two flags this participant takes.
const Flag = enum { report_file, budget_ms };

/// Read a command line into a run request or the fault that refuses it.
///
/// The parse is a pure function of the words, which is what lets the tests
/// below pin every refusal without starting a process. The order of the checks
/// is the order the failures bind: a word that is not a flag, then a flag
/// nobody knows, then a flag given twice, then each value the line carries.
///
/// An unknown flag is refused rather than skipped. The alternative reads as
/// harmless here — the only flags that matter are the ones the supervisor
/// writes — and it is not: a misspelled `--report-file` would otherwise leave a
/// run with no report, and the supervisor would report "the Zig client wrote no
/// report" instead of the typo that caused it.
pub fn parseArgs(args: []const []const u8) CliError!Options {
    var options: Options = .{};
    var seen = std.EnumArray(Flag, bool).initFill(false);
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (!isFlag(argument)) return error.UnexpectedArgument;
        const flag = flagOf(argument) orelse return error.UnknownFlag;
        if (seen.get(flag)) return error.DuplicateFlag;
        seen.set(flag, true);
        switch (flag) {
            .report_file => options.report_file = try takeValue(args, &index),
            .budget_ms => options.budget_ms = try takeBudget(args, &index),
        }
    }
    return options;
}

/// Whether a word is this participant's to read as a flag.
///
/// One dash is not a flag, and a joined spelling is not one either:
/// `--budget-ms=5000` is a spelling nobody here wrote, and reading it as the
/// flag it starts with would silently drop the value.
fn isFlag(word: []const u8) bool {
    return std.mem.startsWith(u8, word, "--") and word.len > 2;
}

fn flagOf(word: []const u8) ?Flag {
    if (std.mem.eql(u8, word, "--report-file")) return .report_file;
    if (std.mem.eql(u8, word, "--budget-ms")) return .budget_ms;
    return null;
}

/// The value after a flag, refusing a line where the next word is another flag.
///
/// Reading another flag as this one's value is the mistake this exists to stop:
/// `--report-file --budget-ms 5000` would otherwise name a report file called
/// `--budget-ms` and leave `5000` as a word that is not a flag.
fn takeValue(args: []const []const u8, index: *usize) CliError![]const u8 {
    if (index.* + 1 >= args.len or isFlag(args[index.* + 1])) return error.MissingValue;
    index.* += 1;
    return args[index.*];
}

/// The budget after `--budget-ms`, as a count of milliseconds inside the range
/// this participant accepts.
///
/// Three faults, three names: a value that is not decimal digits, one no `i64`
/// holds, and one outside the range. They are apart because the caller's repair
/// differs — a typo is fixed by typing, an overflow by a shorter number, and a
/// number outside the range by a different one — and a single name would send
/// the reader looking in the wrong place.
fn takeBudget(args: []const []const u8, index: *usize) CliError!i64 {
    const text = try takeValue(args, index);
    if (text.len == 0) return error.NotANumber;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.NotANumber;
    }
    const value = std.fmt.parseInt(i64, text, 10) catch return error.BudgetOverflow;
    if (value < budget_min_ms or value > budget_max_ms) return error.BudgetOutOfRange;
    return value;
}

/// The fault as a phrase, for the line that precedes the usage.
///
/// The phrase names the fault rather than the offending word, because
/// [`CliError`] is where the fault is kept and a word the reader already typed
/// does not need repeating; the usage that follows names every word this
/// participant takes.
fn reason(fault: CliError) []const u8 {
    return switch (fault) {
        error.UnknownFlag => "an unknown flag",
        error.DuplicateFlag => "a flag given twice",
        error.MissingValue => "a flag with no value after it",
        error.UnexpectedArgument => "an argument that is not a flag",
        error.TooManyWords => "more words on the command line than this participant reads",
        error.NotANumber => "a budget that is not a run of decimal digits",
        error.BudgetOverflow => "a budget no 64-bit signed integer holds",
        error.BudgetOutOfRange => "a budget outside its range",
    };
}

/// Print a CLI refusal and exit 2; propagate a failed diagnostic write.
fn refuse(io: Io, fault: CliError) !noreturn {
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.print("mcp-current-interop: {s}\n", .{reason(fault)});
    try stderr.interface.print(usage, .{ budget_min_ms, budget_max_ms, exchange_budget_ms });
    try stderr.flush();
    std.process.exit(2);
}

// --- storage --------------------------------------------------------------------
//
// Every buffer this file needs is at file scope, because the tasks borrow
// pointers to it and those pointers have to outlive the group. The decoders'
// scratch is one region used one at a time: a decoded result is read before the
// next one is decoded, so no two borrows out of it are live at once.

var buffers: stdio.Buffers = .{};

/// Scratch for the decoders below and for the walks this file does itself.
var client_scratch: [8192]u8 = undefined;

/// The escape scratch for the `inputRequests` walk, of its own for the reason
/// the sixth step states: `interim.request_state` borrows `client_scratch`
/// whenever the peer wrote an escape, so a walk sharing that region could
/// overwrite the state between decoding it and building the retry with it.
var input_scratch: [2048]u8 = undefined;

/// The versions `server/discover` answered with, and the content blocks and
/// verbatim store the `tools/call` decoder fills.
///
/// Eight tools against eight report slots, on purpose. A peer offering more
/// tools than the report holds is a finding this run names, where one array
/// sized to the report would make the same peer a decode failure instead — and
/// a capacity failure is the caller's own sizing mistake, which is not what a
/// peer that serves more tools than expected is.
var version_scratch: [8][]const u8 = undefined;
var tool_scratch: [8]mcp.Tool = undefined;
var content: [16]mcp.ContentBlock = undefined;
var verbatim: [64]mcp.VerbatimMember = undefined;

/// The retry params, composed from the interim result's own members.
///
/// A region of its own because it is `params` on the second `tools/call` and
/// the rule `mcp_session.Client.request` states is that no two of the five it is
/// handed may share a byte. `result` holds the interim answer the state is
/// copied out of, so the two cannot be the same array.
var retry_params: [4096]u8 = undefined;

// --- the reads the first run of this exchange would otherwise get wrong ---------

// The two facts a unit test cannot earn here are left to the exchange and are
// stated where they are made: that every request carries the envelope this
// revision requires is a claim about the wire, and the supervisor's
// `require_envelope` reads it off the capture for every request this file sent;
// that the names in `removed_names` are refused before the wire is a claim about
// this file's control flow, and the supervisor's `check_no_handshake` reads the
// absence of the handshake off the same capture. Both are checked where they can
// fail for a reason that has nothing to do with the library, which is what a real
// capture gives and a static fixture does not.

test "inputRequests: the key and the method are read out of the peer's own bytes" {
    // The answer the SDK sent for round one, byte for byte: the map is keyed by
    // the server, the value carries the method, and `params` rides beside them.
    const raw =
        "{\"colour\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"which colour?\"," ++
        "\"mode\":\"form\",\"requestedSchema\":{\"properties\":{\"confirm\":{\"type\":\"boolean\"}}," ++
        "\"required\":[\"confirm\"],\"type\":\"object\"}}}}";
    var scratch: [1024]u8 = undefined;
    const question = try firstInputRequest(raw, &scratch);
    try testing.expectEqualStrings("colour", question.key);
    try testing.expectEqualStrings("elicitation/create", question.method);
    // The name is one of the three the specification allows inside the map, and
    // `lookupInputRequest` is what decides it rather than this file.
    _ = try mcp.lookupInputRequest(question.method);
}

test "inputRequests: what the map has to carry, and what it must not" {
    var scratch: [1024]u8 = undefined;
    // A map that is not an object is refused rather than read as no questions,
    // because an answer with no key to file it under is one this run cannot send.
    try testing.expectError(
        error.MalformedJson,
        firstInputRequest("[]", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        firstInputRequest("\"colour\"", &scratch),
    );
    // An empty map carries no question.
    try testing.expectError(error.MissingField, firstInputRequest("{}", &scratch));
    // An entry that is not an object, and an entry with no `method`.
    try testing.expectError(
        error.MalformedJson,
        firstInputRequest("{\"colour\":\"elicitation/create\"}", &scratch),
    );
    try testing.expectError(
        error.MissingField,
        firstInputRequest("{\"colour\":{\"params\":{}}}", &scratch),
    );
    // A `method` that is not a string is refused, not trimmed into one.
    try testing.expectError(
        error.MalformedJson,
        firstInputRequest("{\"colour\":{\"method\":7}}", &scratch),
    );
    // A fault after the first entry is a fault in the map, because the walk is
    // finished rather than stopped at the first one.
    try testing.expectError(
        error.MalformedJson,
        firstInputRequest("{\"colour\":{\"method\":\"elicitation/create\"},\"x\":}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        firstInputRequest("{\"colour\":{\"method\":\"elicitation/create\"}} {}", &scratch),
    );
    // The first occurrence of a repeated key wins and the repeat is consumed
    // rather than read, so a later entry cannot become the one answered.
    const repeated = try firstInputRequest(
        "{\"colour\":{\"method\":\"elicitation/create\"},\"colour\":{\"method\":\"roots/list\"}}",
        &scratch,
    );
    try testing.expectEqualStrings("elicitation/create", repeated.method);
    // Including when the first entry has no method at all: the member that is
    // there is the member the answer is keyed under, and a repeat must not
    // supply the method it lacks.
    try testing.expectError(
        error.MissingField,
        firstInputRequest("{\"colour\":{\"params\":{}},\"colour\":{\"method\":\"roots/list\"}}", &scratch),
    );
    // An escaped key decodes rather than arriving with its quotes: the key is
    // what the answer is filed under, so the escape has to be resolved.
    const escaped = try firstInputRequest(
        "{\"col\\u006fur\":{\"method\":\"elicitation/create\"}}",
        &scratch,
    );
    try testing.expectEqualStrings("colour", escaped.key);
}

test "the retry carries what makes it a retry, and escapes what the server chose" {
    // The state and the key are both the server's, and both are opaque: a state
    // carrying JSON syntax must come out as a string literal and not as a member
    // that ends early. `mcp.decodeCacheLeg` reads which leg the result is on.
    var out: [1024]u8 = undefined;
    const state = "v1.aA\"b\\\\c";
    const params = try buildRetryParams(
        &out,
        tool_ask,
        echo_argument,
        "co\"lour",
        accept_answer,
        state,
    );
    // The state round-trips: read back out of the document as the JSON string
    // it is, it is the bytes the peer minted.
    var scratch: [1024]u8 = undefined;
    const state_lexeme = json.memberText(params, "requestState", &scratch).?;
    var state_reader = json.Reader.init(state_lexeme);
    try testing.expectEqualStrings(state, try state_reader.string(&scratch));
    const responses = json.memberText(params, "inputResponses", &scratch).?;
    var response_reader = json.Reader.init(responses);
    _ = try response_reader.beginObject();
    try testing.expectEqualStrings("co\"lour", (try response_reader.nextKey(&scratch)).?);
    try testing.expectEqual(mcp.CacheLeg.mrtr_retry, try mcp.decodeCacheLeg(params, &scratch));
    // A first leg carries neither member, so the same reader calls it the
    // original leg. This is the check that a retry this file composed reads as
    // a retry rather than as a second first attempt.
    try testing.expectEqual(
        mcp.CacheLeg.original,
        try mcp.decodeCacheLeg(ask_params, &scratch),
    );
    try testing.expectEqual(
        mcp.CacheLeg.original,
        try mcp.decodeCacheLeg(discover_params, &scratch),
    );
}

test "the retry refuses a state it could not quote, and reports a short buffer as one" {
    var out: [1024]u8 = undefined;
    // `json.Writer.string` does not check UTF-8 and escapes only the bytes JSON
    // names, so a stray byte would become a literal this library's own reader
    // refuses on the far side of the wire. `InvalidField` and not
    // `BufferTooSmall`, because the fault is a value and not a buffer.
    try testing.expectError(error.InvalidField, buildRetryParams(
        &out,
        tool_ask,
        echo_argument,
        "colour",
        accept_answer,
        "v1.\xff",
    ));
    // A short buffer is a short buffer: the writer escapes rather than
    // truncates, so a caller that grows `out` gets the whole document.
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, buildRetryParams(
        &tiny,
        tool_ask,
        echo_argument,
        "colour",
        accept_answer,
        "v1.state",
    ));
    var enough: [512]u8 = undefined;
    const params = try buildRetryParams(
        &enough,
        tool_ask,
        echo_argument,
        "colour",
        accept_answer,
        "v1.state",
    );
    try testing.expect(std.mem.indexOf(u8, params, "\"name\":\"" ++ tool_ask ++ "\"") != null);
}

test "the command line the supervisor writes is read, and one it does not write is refused" {
    // The parse is a pure function of the words, so every refusal below is pinned
    // without starting a process. What is pinned is the behaviour a caller can
    // change: which flags exist, which lines are refused and why, and what a value
    // becomes. The path strings are fixtures — nothing here reads or writes them —
    // and they are named under this project's own scratch rather than a system
    // temporary directory, so a reader copying one out of this test does not copy a
    // path the interop peers refuse by name.
    const scratch_path = "/home/tmp2/zdap/interop/zig-report.json";

    // Both flags, in either order: the order they appear on the line decides
    // nothing, because neither value is the other's.
    const both = try parseArgs(&.{ "--budget-ms", "5000", "--report-file", scratch_path });
    try testing.expectEqual(@as(i64, 5000), both.budget_ms);
    try testing.expectEqualStrings(scratch_path, both.report_file.?);
    const reversed = try parseArgs(&.{ "--report-file", scratch_path, "--budget-ms", "5000" });
    try testing.expectEqual(@as(i64, 5000), reversed.budget_ms);
    try testing.expectEqualStrings(scratch_path, reversed.report_file.?);

    // A flag nobody knows is refused rather than skipped, because a misspelled
    // `--report-file` would otherwise leave a run with no report and the
    // supervisor would report the symptom instead of the typo.
    try testing.expectError(
        error.UnknownFlag,
        parseArgs(&.{ "--slow-entered-file", "/home/tmp2/zdap/interop/marker" }),
    );
    try testing.expectError(error.UnknownFlag, parseArgs(&.{"--nope"}));
    // A joined spelling is a word nobody here wrote. Reading it as the flag it
    // starts with would silently drop the value beside the `=`.
    try testing.expectError(
        error.UnknownFlag,
        parseArgs(&.{"--report-file=/home/tmp2/zdap/interop/zig-report.json"}),
    );
    try testing.expectError(error.UnknownFlag, parseArgs(&.{"--budget-ms=5000"}));
    // And a flag given twice is not a reading of the line anybody wrote.
    try testing.expectError(
        error.DuplicateFlag,
        parseArgs(&.{ "--report-file", "a", "--report-file", "b" }),
    );
    try testing.expectError(
        error.DuplicateFlag,
        parseArgs(&.{ "--budget-ms", "5000", "--budget-ms", "6000" }),
    );

    // A word that is not a flag at all, and a flag whose value is missing or
    // is another flag.
    try testing.expectError(error.UnexpectedArgument, parseArgs(&.{"report.json"}));
    try testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "--report-file", "r.json", "extra" }),
    );
    for ([_][]const u8{ "--report-file", "--budget-ms" }) |flag| {
        try testing.expectError(error.MissingValue, parseArgs(&.{flag}));
        try testing.expectError(
            error.MissingValue,
            parseArgs(&.{ flag, "--report-file", "r.json" }),
        );
    }

    // A budget that is not a run of digits, one no `i64` holds, and one outside
    // the range: three faults and three names, because the caller's repair
    // differs and a single name would send the reader looking in the wrong
    // place. A signed value is refused rather than read as a positive one, and
    // a value with a sign in it is not a run of digits.
    for ([_][]const u8{ "soon", "5000ms", "", "1e3", "0x10", "1_000", "+5000", " 5000" }) |bad| {
        try testing.expectError(
            error.NotANumber,
            parseArgs(&.{ "--budget-ms", bad }),
        );
    }
    try testing.expectError(
        error.BudgetOverflow,
        parseArgs(&.{ "--budget-ms", "99999999999999999999999" }),
    );
    // The bounds are inclusive at both ends, so the two edges parse and the
    // values beside them are the refusals. A budget outside the range is
    // refused rather than clamped: a clamped one runs the exchange to a stop and
    // then reports a timeout that says nothing about the peer.
    try testing.expectEqual(
        budget_min_ms,
        (try parseArgs(&.{ "--budget-ms", "1000" })).budget_ms,
    );
    try testing.expectEqual(
        budget_max_ms,
        (try parseArgs(&.{ "--budget-ms", "60000" })).budget_ms,
    );
    for ([_][]const u8{ "0", "1", "999", "60001" }) |bad| {
        try testing.expectError(error.BudgetOutOfRange, parseArgs(&.{ "--budget-ms", bad }));
    }
}

test "report: a peer string too long for its store is cut on a code point" {
    // A store that cannot hold what a peer sent truncates rather than refuses,
    // so where the cut lands decides whether the report is readable at all.
    // Every capacity from none to the whole string is checked, because a cut
    // inside a code point is invisible at the capacities either side of it and
    // is the only case that matters.
    const text = "aé€😀z";
    for (0..text.len + 1) |capacity| {
        var storage: [text.len]u8 = undefined;
        const kept = keep(storage[0..capacity], text);
        try testing.expect(std.unicode.utf8ValidateSlice(kept));
        try testing.expect(std.mem.startsWith(u8, text, kept));
        if (kept.len == text.len) {
            // Nothing was dropped, which is the whole string and nothing else.
            try testing.expectEqual(text.len, capacity);
            continue;
        }
        // What is left out is exactly the one code point that did not fit, so
        // what is kept is the longest prefix a store of this size could hold.
        const dropped = std.unicode.utf8ByteSequenceLength(text[kept.len]) catch
            return error.TestUnexpectedResult;
        try testing.expect(kept.len + dropped > capacity);
    }

    // The case that reads as the rule: a four-byte code point that would have
    // fit by two of its bytes is dropped whole, because a prefix ending inside
    // one is not a string at all.
    var storage: [7]u8 = undefined;
    try testing.expectEqualStrings("aé€", keep(&storage, text));
}

test "report: a complete report of control bytes fits the buffer the run gives it" {
    // Every store in the report filled to its capacity with the worst byte on
    // the wire, and every count at the most a peer can be credited with. A peer
    // answering with control bytes in its instructions, its tool names or its
    // request state is an ordinary thing for it to do, and the report is the
    // only account of what it said: a run that was complete and could not say
    // so failed for having been complete.

    const fillWorst = struct {
        fn fill(storage: []u8) []const u8 {
            @memset(storage, 0x01);
            return storage;
        }
    }.fill;

    var report: Report = .{ .io = testing.io };
    for (report.discover_versions, 0..) |_, index| {
        report.discover_versions[index] = fillWorst(&report.version_store[index]);
    }
    report.discover_version_count = report.discover_versions.len;
    report.discover_ttl_ms = std.math.maxInt(u64);
    report.discover_instructions = fillWorst(&report.instructions_store);
    for (report.tools, 0..) |_, index| {
        report.tools[index] = fillWorst(&report.tool_name_store[index]);
    }
    report.tool_count = report.tools.len;
    report.echo_text = fillWorst(&report.echo_store);
    report.mrtr_result_type = fillWorst(&report.result_type_store);
    report.mrtr_key = fillWorst(&report.key_store);
    report.mrtr_method = fillWorst(&report.method_store);
    report.mrtr_state_prefix = fillWorst(&report.state_prefix_store);
    report.mrtr_state_len = std.math.maxInt(usize);
    report.mrtr_echo_text = fillWorst(&report.resumed_store);
    for (report.refused, 0..) |_, index| {
        report.refused[index] = fillWorst(&report.refused_store[index]);
    }
    report.refused_count = report.refused.len;
    var message: [failure_capacity]u8 = undefined;
    report.failure = fillWorst(message[0 .. failure_capacity - 1]);

    var buffer: [report_capacity]u8 = undefined;
    const document = try encodeReport(&buffer, &report);

    // One complete JSON value: every member walked, and nothing after it.
    var reader = json.Reader.init(document);
    var scratch: [8]u8 = undefined;
    if (!try reader.beginObject()) {
        while (try reader.nextKey(&scratch)) |_| try reader.skipValue(&scratch);
    }
    try testing.expect(reader.atEnd());

    // Six bytes on the wire for every byte the peer sent, and one string back
    // to the reader: the escaping is what makes the wide report the same
    // account of the run as a narrow one.
    const echo = json.memberText(document, "echo_text", &scratch) orelse
        return error.TestUnexpectedResult;
    var echo_reader = json.Reader.init(echo);
    var decoded: [256]u8 = undefined;
    var expected: [128]u8 = undefined;
    try testing.expectEqualStrings(fillWorst(&expected), try echo_reader.string(&decoded));

    // A buffer that cannot hold the whole report is refused rather than cut
    // short: half a document is one no reader can parse, and the supervisor
    // would read it as a report about a run that never happened.
    var narrow: [64]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, encodeReport(&narrow, &report));
}
