//! The Zig half of the MCP 2025-11-25 interoperability exchange.
//!
//! This is a participant, not a library module. `test/interop/mcp_peer.py`
//! starts this executable as a child process with pipes on its standard
//! streams, and an independent upstream SDK serves the other end of them, so
//! the bytes this file puts on standard output are the real wire between two
//! implementations. Nothing here is imported by the library, and the library
//! keeps its zero-dependency guarantee because this process is a peer and not
//! a caller.
//!
//! What it does, in the order the specification requires:
//!
//!   1. `initialize`, pinned to `2025-11-25`, which is `mcp.Revision.previous`,
//!      and the revision in the answer read as the JSON string it is.
//!   2. `notifications/initialized`, before anything that depends on it.
//!   3. `tools/list`, and the three tool names the peer serves.
//!   4. `tools/call` for a tool that answers, decoded with `mcp`'s own decoder
//!      and compared with the argument that went out, because a result with
//!      content in it is not evidence that the tool ran.
//!   5. `tools/call` for a tool that fails: a result with `isError`, which is
//!      not a peer error, and the difference is the point of the step.
//!   6. `tools/call` with params that omit the required name, so the peer
//!      answers with a JSON-RPC error and no result at all.
//!   7. `tools/call` for a tool that takes long, cancelled while it is in
//!      flight by a second task, and the answer that comes back is read as the
//!      refusal it is.
//!
//! Then it hangs up: the connection is closed and the process exits, so the
//! peer sees end of file and shuts down on its own. The supervisor checks that
//! it did.
//!
//! ## Two answers this file reads for itself
//!
//! This run speaks the older revision, and two of its answers are shapes the
//! library's decoders do not read at that revision.
//!
//! `initialize`'s answer carries a `protocolVersion` string, and
//! `json.memberText` answers a request for that member with the member's raw
//! lexeme: `"2025-11-25"`, quotes and all. Compared with the text this client
//! is pinned to, that is a mismatch the wire does not carry, and the report
//! says the peer negotiated a revision with quotation marks in it. The first
//! run of this exchange failed exactly there, on a peer that had answered
//! correctly. So [`stringMember`] reads the member with `json.Reader.string`,
//! which decodes the value rather than cutting it out of the document, and
//! finishes the walk afterwards, so the member is read out of a whole document
//! rather than a prefix of one.
//!
//! `tools/list`'s answer is not read with `mcp.decodeToolListResult`, and the
//! reason is the shape rather than the convenience: at `2026-07-28` a
//! `ListToolsResult` extends `CacheableResult` and therefore requires the
//! `ttlMs` and `cacheScope` members, which a `2025-11-25` answer does not carry
//! and which this run will not invent to make the current decoder accept it.
//! What this run consumes out of that answer is the tool names, in wire order,
//! so [`toolNames`] reads them with one borrowing reader over the peer's own
//! bytes. It is deliberately neither a `Tool` nor a `ListToolsResult`: it
//! models the names this participant calls and nothing else, and a member it
//! does not read is a member it does not claim to have decoded.
//!
//! `tools/call` is read with `mcp.decodeToolCallResult` as it stands. A
//! `CallToolResult` extends `Result` at both revisions and carries no caching
//! members, so that one decoder reads both revisions' answers, and reusing it
//! is what makes the fourth and fifth steps checks of the library's decode
//! rather than of a second implementation written beside it.
//!
//! ## Why the cancellation needs a second task
//!
//! `conn.call` waits for the answer before it returns, so a cancellation
//! cannot be sent from the same task that is waiting for the slow call to come
//! back. A second task on the same group sends it. The order between the two
//! is not a sleep: the peer writes a file when its slow tool starts, and the
//! cancelling task waits for that file. A sleep would leave a window in which
//! the cancellation arrives before the request does, and the SDK drops a
//! cancellation for an id that is not in flight, which would make the run pass
//! or fail for a reason that has nothing to do with either side.
//!
//! ## Why the wait on the client task has a bound
//!
//! Every failure this file reports is recorded by a task and printed by the
//! main task, and the ways a run goes wrong leave a task parked in a call the
//! peer will never answer: a peer that accepts the handshake and then stops
//! talking, and a peer whose slow tool never starts, whose client task is
//! still inside that slow call long after the cancelling task has given up
//! and recorded why. Waiting on the client task without a bound means that
//! recorded diagnosis is never reached — the process sits until the
//! supervisor's own deadline kills it, and the one finding that explains the
//! stall is replaced by an opaque child that would not exit.
//!
//! The watcher records what its budget found *before* it wakes the main task,
//! and that order is the point. The main task's answer to a budget that ran out
//! is to close the connection, and a client task still parked in a call the peer
//! will never answer fails that call with a transport fault the instant the
//! connection closes. A diagnosis written after that close would be
//! `initialize: the call itself failed`, naming a transport this run broke
//! itself and hiding the deadline that caused it. Recorded first, it stands,
//! because `fail` keeps the first finding — so a step that named something
//! sooner, a peer that never started its slow tool, is still what the run says.
//!
//! So the main task waits on the same semaphore, posted by the client task
//! when the exchange is over and by a watcher when the budget runs out, and
//! either way it then closes the connection and cancels the group. That is what
//! ends the reader's blocked read and joins every task before the report is
//! read: a report read while a task is still writing it is a report of fields
//! mid-write. Which of the two ended the wait is settled by [`Ending`] under
//! its own lock, so a run that finished inside its budget is never reported as
//! one that outlasted it.
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
//!
//! A run that passed is flushed once, at the end, and that flush is not best
//! effort: a summary that never reached the supervisor is a pass it cannot
//! show the evidence for, so a failure in it is this process's exit status.

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
/// `previous` is `2025-11-25`. The gate in `mcp_session` reads the revision
/// from this one value, so the methods this file may send and the ones the
/// peer may answer are decided by the same pin the handshake negotiates.
const revision: mcp.Revision = .previous;

/// The tool names. The peer serves exactly these, and a client that asked the
/// peer what it had rather than sending these would be testing the wrong thing:
/// the names are the interface, agreed by construction as any client's and a
/// server's are.
const tool_echo = "echo";
const tool_fail = "fail";
const tool_slow = "slow";

/// What this participant calls itself in the handshake. A fixed name and
/// version, so a capture taken from two runs is comparable to another and
/// carries nothing about the machine that produced it.
const client_name = "zig-agent-proto-interop";
const client_version = "0.0.0";

/// The text the echo tool is called with, and the text its answer has to carry.
/// One value on both sides of the call, so the comparison the fourth step
/// makes is a comparison rather than two literals that happen to agree.
const echo_argument = "zig-agent-proto";

/// How long the slow tool is asked to take. Long enough that the cancellation
/// has to go out while it runs, and short enough that a peer which ignored it
/// would still be inside the supervisor's deadline rather than parking the
/// run until the deadline kills both children.
const slow_seconds: u32 = 30;

/// The params that go on the wire, built at comptime from the values above.
///
/// One line each, because a newline inside params is what NDJSON forbids and
/// what the framing layer then refuses: these are the bytes the run depends on,
/// and a run that assembled them across lines would be one the peer cannot read.
/// Each names its tool from the same constant the tool list is checked against,
/// so a name cannot drift between the call and the check.
const initialize_params = std.fmt.comptimePrint(
    "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}}," ++
        "\"clientInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}}}}",
    .{ revision.string(), client_name, client_version },
);
const echo_params = std.fmt.comptimePrint(
    "{{\"name\":\"{s}\",\"arguments\":{{\"text\":\"{s}\"}}}}",
    .{ tool_echo, echo_argument },
);
const slow_params = std.fmt.comptimePrint(
    "{{\"name\":\"{s}\",\"arguments\":{{\"seconds\":{d}}}}}",
    .{ tool_slow, slow_seconds },
);

/// How long the cancelling task waits for the peer to say its slow tool has
/// started. A bound rather than a wait: a peer that never starts the tool is a
/// failure to report, not a task to park on for ever.
const default_cancel_timeout_ms: i64 = 15_000;

/// How long the whole exchange may take before this client stops waiting for
/// it and reports what it has.
///
/// Under the supervisor's own sixty-second deadline on purpose: a budget its
/// deadline reaches first is a budget whose diagnosis is never written, because
/// the process is killed before it can write one. Above the slow tool's thirty
/// seconds, so that a peer which ignored the cancellation and ran its tool to
/// completion is still answered inside the budget rather than cut off half way,
/// which would report a deadline for what is really a peer that does not
/// cancel.
const exchange_budget_ms: i64 = 45_000;

/// The clock every bound in this file is measured on.
///
/// `awake` is monotonic and cannot be set, so a bound here is a promise about
/// elapsed time rather than about what a calendar says: a step of the system
/// clock cannot make a wait shorter than the budget it was given, and the two
/// tasks that wait — the budget watcher and the cancelling one — are on one
/// timescale, so the order of the events they report is the order they
/// happened in.
const clock: Io.Clock = .awake;

/// What the run received, in the order the supervisor checks it.
///
/// Every field is a value the peer sent and this client's own decoder read,
/// rather than a conclusion drawn here: the supervisor compares each one with
/// the bytes that crossed the pipes, so a report cannot agree with a capture
/// it never saw.
const Report = struct {
    /// The lock `fail` takes. The client task, the cancelling task and the
    /// budget watcher all write here, and "the first failure is the finding" is
    /// a read-then-write that three tasks would otherwise interleave.
    io: Io,
    mutex: Io.Mutex = .init,

    revision: []const u8 = revision.string(),
    /// Owned by this struct rather than borrowed from the decode scratch: the
    /// scratch is used one decode at a time and every later decode would
    /// overwrite it, and a report read at the end of the run must still say
    /// what the handshake answered.
    // SAFETY: keep copies the negotiated text into it and protocol_version is set to that prefix.
    version_text: [32]u8 = undefined,
    protocol_version: []const u8 = "",

    /// The names `tools/list` answered with, copied out of the decode scratch
    /// and bounded on both counts. A peer that offered more than this report
    /// can hold is reported rather than quietly shortened: the supervisor
    /// compares this list with the wire and a difference fails the run.
    // SAFETY: keep fills one entry per name offered, and namedTools reads at most that many.
    tool_name_store: [8][32]u8 = undefined,
    tools: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },
    tool_count: usize = 0,

    /// The text the echo tool came back with. What went out in the call's own
    /// params is what this is compared against, rather than a flag saying the
    /// result carried content: content is not evidence that the tool ran.
    // SAFETY: keep copies the echoed text into it and echo_text is set to that prefix.
    echo_store: [128]u8 = undefined,
    echo_text: []const u8 = "",

    fail_is_error: bool = false,
    /// The codes the peer sent beside its two error objects. Optional because
    /// an error answer carrying no code is a shape this run refuses rather
    /// than one it reports as a zero.
    peer_error_code: ?i32 = null,
    cancelled_error_code: ?i32 = null,
    failure: []const u8 = "",
    ok: bool = false,
};

/// The most bytes a failure message holds.
///
/// `fail` copies into the buffer it is handed and every caller hands it one of
/// these, so `failure` is one of them and nothing longer. It is named because
/// the report's bound below has to include it: `failure` is a slice into a
/// buffer declared in `main` rather than a store inside [`Report`], and a
/// bound reading `@sizeOf(Report)` alone would be a bound about a report this
/// run does not write.
const failure_capacity: usize = 512;

/// The most bytes the report's own storage holds as text.
///
/// Every peer string in [`Report`] is a slice into a fixed array declared
/// beside it — `keep` is the one place those slices are made — so
/// `@sizeOf(Report)` covers all of them along with the slice headers, the
/// counters and the lock this struct carries. Reading it rather than summing
/// the arrays out by hand is what makes a store added here widen the bound
/// with it. `revision` is the one member no store covers: it is this run's
/// pin, spelled by the constant at the top of this file rather than copied
/// out of anything, so it adds its own length here instead of being counted
/// as the sixteen bytes of a slice header.
const report_text_capacity: usize = @sizeOf(Report) + failure_capacity + revision.string().len;

/// The most bytes one decoded byte costs in the report.
///
/// `json.Writer.string` escapes what the JSON grammar forbids and passes
/// every other byte through, so the widest case is a control byte written as
/// `\u00XX`: six bytes for one. A peer answering with control bytes in its
/// tool names, its negotiated revision or the text it echoed fills every store
/// in this report with them, and a bound sized for printable text is short by
/// six times over.
const report_escape_width: usize = 6;

/// The bytes the report spends on what is not a decoded byte.
///
/// Every member name with its quotes and its colon, the brackets, the commas
/// and one decimal rendering per number: well under a kilobyte for this schema
/// at its widest. It is a fixed number rather than a derived one because the
/// schema is fixed, and 2048 is the next step above that kilobyte — slack this
/// file does not have to keep true by hand, in place of a bound that moves
/// every time a member is added.
const report_syntax_capacity: usize = 2048;

/// The buffer the report is composed in, before the one write that hands it to
/// the file.
///
/// Six bytes for every byte the report's own storage holds, plus the syntax
/// around them: the whole report at the worst escaping a peer can produce,
/// with nothing allocated to get there and nothing grown when it does not fit.
const report_capacity: usize = report_escape_width * report_text_capacity + report_syntax_capacity;

/// What the two tasks share: the id of the in-flight call the cancelling task
/// has to name, and nothing else.
const Shared = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    slow_id: i64 = 0,
    published: bool = false,

    fn publish(self: *Shared, id: i64) void {
        self.mutex.lockUncancelable(self.io);
        self.slow_id = id;
        self.published = true;
        self.mutex.unlock(self.io);
    }

    fn take(self: *Shared) struct { id: i64, published: bool } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .id = self.slow_id, .published = self.published };
    }
};

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

/// Options, read from the command line. The supervisor passes both paths; a
/// run without `--report-file` still works and simply has nothing to hand back.
const Options = struct {
    slow_entered_file: ?[]const u8 = null,
    report_file: ?[]const u8 = null,
    cancel_timeout_ms: i64 = default_cancel_timeout_ms,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const options = parseArgs(init);

    var report_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &report_buffer);
    const err = &stderr.interface;

    // Preserve partial diagnostics if printSummary or writeReport fails.
    // Set the guard before the final flush so its failure cannot trigger a retry.
    var final_flush_attempted = false;
    errdefer {
        if (!final_flush_attempted) {
            // gate-reviewed-zlint-next-statement: suppressed-errors
            // ziglint-ignore: Z026
            // zwanzig-disable-next-line: empty-catch-engine
            stderr.flush() catch {};
        }
    }

    // The report is a string, so it needs storage that outlives every task
    // below, and so does the message a failed check leaves behind. Both are
    // fixed buffers, because the failure path allocates nothing either.
    var message: [failure_capacity]u8 = undefined;
    var detail: [256]u8 = undefined;
    var report: Report = .{ .io = io };

    var transport = try stdio.Stdio.init(io, &buffers.read, &buffers.write);
    var connection = try transport.connection(buffers.config());

    var group: Io.Group = .init;
    defer group.cancel(io);
    defer connection.close();
    var done: Io.Semaphore = .{};
    var shared: Shared = .{ .io = io };
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
        .{ io, &connection, &shared, &ending, &done, &report, &message },
    );
    if (options.slow_entered_file != null) {
        try group.concurrent(io, cancelTask, .{ io, &connection, &shared, &options, &report, &message });
    }

    // The bound on the wait below, armed before the main task starts waiting
    // and cancelled with everything else once it stops.
    try group.concurrent(io, budgetTask, .{ io, &ending, &report, &message, &done });

    // The client task posts this when the exchange is over, and the budget
    // watcher posts it when the exchange has outlasted any run of this exchange
    // should. Waiting here rather than awaiting the group is what keeps the
    // reader's blocked read from being the thing the main task waits on:
    // closing the connection and cancelling the group below is what ends that
    // read, and cancelling the group joins every task.

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
        fail(&report, &message, cause("the last flush before hanging up failed", &detail, flush_err));
    };

    // Every task is joined above, so nothing is still writing the report and
    // what follows reads a finished run. `fail` keeps the first failure, so a
    // step that named what it found sooner — a peer that never started its slow
    // tool, a call the peer refused — is still what this run reports, and the
    // budget is the finding only for a run in which nothing got far enough to
    // name one.

    // Read under the lock the tasks wrote their findings with. Nothing can take
    // it now that the group is joined; taking it anyway keeps this read and
    // those writes under one rule rather than two.
    report.mutex.lockUncancelable(io);
    report.ok = report.failure.len == 0;
    report.mutex.unlock(io);
    try writeReport(io, &options, &report);
    printSummary(err, &report);
    if (!report.ok) {
        // A non-zero exit is what the supervisor reads first, and the summary
        // is flushed before the process goes, so nothing is lost with it.

        // This flush is the last thing between the summary and the exit, so a
        // failure in it has nowhere left to go. The only line below it is
        // `exit(1)`, whose code cannot carry a second answer, and writing the
        // failure to the same `err` would be the same discard it is. The run
        // is already reported by the exit code and by the summary itself, and
        // this is the best-effort cleanup on the way out that this is for.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        err.flush() catch {};
        std.process.exit(1);
    }

    // Reached only by a run that passed: the arm above left through
    // `exit(1)`. This is the one flush that is not best effort, and the flag
    // above is already set so the defer does not push the same summary a
    // second time on the way out — not even after a failure in this line,
    // because a second attempt at a flush that just failed is a second chance
    // to hide the fault rather than to report it.
    final_flush_attempted = true;
    try stderr.flush();
}

/// The reader task: this connection's whole job until it is told to stop.
fn readLoop(connection: *conn.Conn) void {
    connection.pump();
}

/// The task that bounds the main task's wait on the exchange.
///
/// It waits the budget out and then records that the budget is what this run
/// has found, before it wakes the main task. Recording first is the whole of
/// the order here, and the module's own section on the bound says why: the main
/// task answers a budget that ran out by closing the connection, and a client
/// task still parked in a call the peer will never answer fails that call with a
/// transport fault the moment the connection closes.
///
/// The group's cancelation interrupts the wait, so a run that finished never
/// waits the budget out.
fn budgetTask(
    io: Io,
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
        .raw = Io.Duration.fromMilliseconds(exchange_budget_ms),
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
        exchange_budget_ms,
    }) catch "the exchange did not finish inside its budget";
    fail(report, message, text);
    done.post(io);
}

/// The client task: the whole exchange, in the order the specification requires.
fn clientTask(
    io: Io,
    connection: *conn.Conn,
    shared: *Shared,
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

    // One session, one pin. The capabilities ride in `initialize` at this
    // revision, which is what `Client.request` itself will not do: it adds
    // them to `_meta` only at the current revision, where the handshake does
    // not carry them.
    var session = mcp_session.Client.init(connection, revision);

    // 1. initialize.
    const handshake = session.request(
        "initialize",
        initialize_params,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "initialize: the call itself failed", &detail, err);
        return;
    };
    if (handshake.failed()) {
        fail(report, message, "initialize: the peer refused the handshake");
        return;
    }
    // Read as the JSON string it is, not as the lexeme it arrived in. The two
    // are the same bytes and not the same text, and the comparison below is
    // against a bare version, so a member read as its lexeme reports a peer
    // that negotiated a revision with quotation marks in it.
    const negotiated = stringMember(handshake.body, "protocolVersion", &client_scratch) catch |err| {
        record(report, message, "initialize: the answer did not decode", &detail, err);
        return;
    } orelse {
        fail(report, message, "initialize: the answer carried no protocolVersion");
        return;
    };
    report.protocol_version = keep(&report.version_text, negotiated);
    if (!std.mem.eql(u8, negotiated, revision.string())) {
        fail(report, message, "initialize: the peer negotiated a revision this client is not pinned to");
        return;
    }

    // 2. notifications/initialized, before the first request that needs it.
    session.notify("notifications/initialized", null, &buffers.out) catch |err| {
        record(report, message, "notifications/initialized: the notification failed", &detail, err);
        return;
    };

    // 3. tools/list, with the names read out of the peer's own bytes by this
    //    file's view of this revision's answer rather than by the current
    //    revision's decoder. What the run consumes is the names; what the
    //    current decoder insists on is a result this revision does not send.
    const list = session.request(
        "tools/list",
        null,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        record(report, message, "tools/list: the call itself failed", &detail, err);
        return;
    };
    if (list.failed()) {
        fail(report, message, "tools/list: the peer refused the request");
        return;
    }
    const offered = toolNames(list.body, &tool_names, &client_scratch) catch |err| {
        record(report, message, "tools/list: the result did not decode", &detail, err);
        return;
    };
    // A peer that offered more tools than the report holds is named, not
    // shortened: the supervisor compares this list with the wire, and a list
    // that stops where the report's storage does would look like a peer that
    // offered fewer tools than it did.
    if (offered.names.len > report.tools.len) {
        fail(report, message, "tools/list: the peer offered more tools than this report holds");
        return;
    }
    report.tool_count = offered.names.len;
    for (offered.names, 0..) |name, index| {
        report.tools[index] = keep(&report.tool_name_store[index], name);
    }
    if (!offerNames(offered.names, tool_echo) or !offerNames(offered.names, tool_fail) or
        !offerNames(offered.names, tool_slow))
    {
        fail(report, message, "tools/list: the peer did not offer the three tools this client calls");
        return;
    }

    // 4. A tool that answers. The text that came back is compared with the text
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
    const echo_result = mcp.decodeToolCallResult(echoed.body, &content, &verbatim, &client_scratch) catch |err| {
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

    // 5. A tool that fails. The failure is inside the result, so this call
    //    succeeded as a call: reading the answer as an error would be the
    //    mistake this step exists to rule out.
    const failed_call = session.request(
        "tools/call",
        "{\"name\":\"" ++ tool_fail ++ "\"}",
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
    const fail_result = mcp.decodeToolCallResult(failed_call.body, &content, &verbatim, &client_scratch) catch |err| {
        record(report, message, "tools/call fail: the result did not decode", &detail, err);
        return;
    };
    report.fail_is_error = fail_result.is_error == true;
    if (!report.fail_is_error) {
        fail(report, message, "tools/call fail: a failing tool did not answer with isError");
        return;
    }

    // 6. A call the peer must refuse: the params carry no name, and the name is
    //    the required member the specification names. The peer answers with a
    //    JSON-RPC error, and this client reads it as an error beside the body
    //    rather than as a result.
    const refused = session.request(
        "tools/call",
        "{}",
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

    // 7. The cancellable call. The id is published before the request goes out,
    //    so the cancelling task cannot name an id this task has not used yet.
    shared.publish(connection.nextId());
    const slow = session.request(
        "tools/call",
        slow_params,
        &buffers.result,
        &buffers.out,
        &buffers.params,
    ) catch |err| {
        // The call did not come back with an answer at all, which is not a
        // cancellation the peer acknowledged: a cancelled request is answered
        // with an error, and a connection that died under the call is the
        // peer's exit rather than its refusal. Either way the run stops here
        // rather than reporting something the wire does not carry.
        record(report, message, "tools/call slow: the call did not come back with an answer", &detail, err);
        return;
    };
    if (!slow.failed()) {
        fail(report, message, "tools/call slow: the call was answered with a result rather than refused");
        return;
    }
    report.cancelled_error_code = slow.error_code orelse {
        fail(report, message, "tools/call slow: the peer's cancellation carried no code");
        return;
    };
}

/// The cancelling task.
///
/// It waits for the peer to write the file that says its slow tool has started,
/// then sends `notifications/cancelled` for the id the client published. The
/// wait is a poll against a file with a bound on it, because there is no
/// notification to wait on and a sleep is a race with a moving target.
fn cancelTask(
    io: Io,
    connection: *conn.Conn,
    shared: *Shared,
    options: *const Options,
    report: *Report,
    message: *[failure_capacity]u8,
) void {
    const marker = options.slow_entered_file orelse return;
    var detail: [256]u8 = undefined;

    const tick = @min(options.cancel_timeout_ms, 50);
    var waited_ms: i64 = 0;
    while (waited_ms < options.cancel_timeout_ms) {
        std.Io.Dir.cwd().access(io, marker, .{}) catch {
            // The only failure a sleep here can carry is this group's
            // cancellation, and by the time it arrives the exchange is over
            // and the report has been written: there is nothing left to say.
            Io.sleep(io, Io.Duration.fromMilliseconds(tick), clock) catch return;
            waited_ms += tick;
            continue;
        };
        break;
    } else {
        fail(report, message, "cancellation: the peer never started its slow tool");
        return;
    }

    const taken = shared.take();
    if (!taken.published) {
        // The slow call cannot have reached the peer without the id going out
        // with it, so this is a broken run rather than a quiet cancellation.
        fail(report, message, "cancellation: the client task never published the id of the in-flight call");
        return;
    }

    // Its own frame buffer: two tasks writing one `out` array would interleave
    // two frames, and the connection takes the write mutex around writing a
    // frame but not around composing one. The params are composed rather than
    // spliced from a literal because the id is a number this run chose.
    var out: [512]u8 = undefined;
    var params: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&params, "{{\"requestId\":{d}}}", .{taken.id}) catch |err| {
        record(report, message, "cancellation: the params did not fit their own buffer", &detail, err);
        return;
    };

    var session = mcp_session.Client.init(connection, revision);
    session.notify("notifications/cancelled", text, &out) catch |err| {
        record(report, message, "cancellation: the notification was refused or the write failed", &detail, err);
    };
}

/// Whether the peer's answer offered the tool this run calls.
///
/// Over the names rather than over decoded tools, because names are all this
/// run reads out of the answer: it calls the three tools by name and never
/// looks at a schema, so a list it can compare is the list it asked for.
fn offerNames(available: []const []const u8, name: []const u8) bool {
    for (available) |offered| {
        if (std.mem.eql(u8, offered, name)) return true;
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
/// spelling for — `json.Writer.string` passes every byte it does not forbid
/// straight through, so those bytes would leave the file as a document the
/// reader on the far side refuses with `InvalidUtf8`. So the code point the cut
/// landed in is the one dropped, and what is kept is the longest prefix that is
/// whole code points.
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

// --- the two answers this file reads for itself --------------------------------
//
// Both are one borrowing `json.Reader` over the peer's own bytes: a name and a
// version are slices of the document or of the caller's scratch, never a copy
// of it, and neither reader needs a sub-reader of its own — the members are
// read where the walk stands, so there is no lexeme to hand to a second cursor
// and no scratch to hand it from.

/// One member of a result object, read as the JSON string it has to be.
///
/// `json.memberText` answers with the member's raw lexeme, so a string member
/// arrives with its quotes still on it: `"2025-11-25"` is not the text
/// `2025-11-25`, and a comparison against the text this client is pinned to
/// then fails on a peer that answered correctly. Trimming the quotes here
/// would be the same mistake with a special case on top, so the member is
/// decoded instead — `json.Reader.string` consumes the whole value and resolves
/// its escapes, so what comes back is what the peer sent.
///
/// Null is a document that carried no such member. The walk does not stop at
/// the match: a repeated member is consumed and not read again, because the
/// first occurrence wins and a later one must not be able to make a comparison
/// that has already failed pass, and a document with anything after its
/// closing brace is refused, because those bytes are a second document the
/// transport did not split.
fn stringMember(
    raw: []const u8,
    name: []const u8,
    scratch: []u8,
) proto.DecodeError!?[]const u8 {
    var reader = json.Reader.init(raw);
    var member: ?[]const u8 = null;
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |key| {
            if (member == null and std.mem.eql(u8, key, name)) {
                member = try reader.string(scratch);
                continue;
            }
            try reader.skipValue(scratch);
        }
    }
    if (!reader.atEnd()) return error.MalformedJson;
    return member;
}

/// The tool names in a `2025-11-25` `tools/list` answer, in wire order.
///
/// Not a `Tool` and not a `ListToolsResult`, on purpose. This run calls three
/// tools by name and reads nothing else out of the answer, so what it models is
/// the names — and `mcp.Tool` is the `2026-07-28` tool, whose decoder would be
/// this file claiming to have decoded a shape the answer does not carry.
const ToolNames = struct {
    names: []const []const u8,
};

/// Read the names out of a `2025-11-25` `tools/list` result.
///
/// `out` is the caller's array and `scratch` is the caller's escape scratch;
/// nothing here allocates and nothing is copied out of the document. More tools
/// than `out` holds is `error.BufferTooSmall` rather than a list that stops
/// where the array does, because the supervisor compares this list with the
/// wire and a short one looks like a peer that offered fewer tools.
///
/// `nextCursor` and `_meta` are stepped over rather than read. This run asks
/// for one page of three tools and consumes nothing else out of the answer, and
/// a member this does not read is a member it has no business claiming to have
/// decoded. An absent `tools`, a tool entry that is not an object and a tool
/// with no `name` are each refused, and so is a document with a tail.
fn toolNames(
    raw: []const u8,
    out: [][]const u8,
    scratch: []u8,
) proto.DecodeError!ToolNames {
    var reader = json.Reader.init(raw);
    var names: ?[]const []const u8 = null;
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |key| {
            if (names == null and std.mem.eql(u8, key, "tools")) {
                var count: usize = 0;
                if (!try reader.beginArray()) {
                    while (try reader.nextArrayElement()) {
                        if (count == out.len) return error.BufferTooSmall;
                        out[count] = try toolName(&reader, scratch);
                        count += 1;
                    }
                }
                names = out[0..count];
                continue;
            }
            try reader.skipValue(scratch);
        }
    }
    if (!reader.atEnd()) return error.MalformedJson;
    const found = names orelse return error.MissingField;
    return .{ .names = found };
}

/// The one thing this run reads out of one tool object.
///
/// Its own object walk on the reader it is handed, for the same reason the
/// result object has one: a tool is read where the array stands rather than
/// copied out to be read again. The check for a tail belongs to the document
/// and is made once, by the reader that opened it.
fn toolName(reader: *json.Reader, scratch: []u8) proto.DecodeError![]const u8 {
    var name: ?[]const u8 = null;
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |key| {
            if (name == null and std.mem.eql(u8, key, "name")) {
                name = try reader.string(scratch);
                continue;
            }
            try reader.skipValue(scratch);
        }
    }
    const found = name orelse return error.MissingField;
    return found;
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
/// peer nor a step. Recording it would replace the reason the run ended with
/// the mechanism that ended it, and a peer that stopped talking half way
/// through a call would be reported as a call that failed with `Canceled` — the
/// one thing that error never means on this wire.
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

fn printSummary(err: *Io.Writer, report: *const Report) void {
    err.print("zig-agent-proto mcp interop client ({s})\n", .{report.revision}) catch return;
    if (report.failure.len != 0) {
        err.print("  FAILED: {s}\n", .{report.failure}) catch return;
        return;
    }
    // Past this point every step that fills a field checked it first, so the
    // two codes are known to be there rather than assumed to be.
    err.print("  initialize: protocolVersion={s}\n", .{report.protocol_version}) catch return;
    err.print("  tools/list: {d} tools: ", .{report.tool_count}) catch return;
    for (namedTools(report), 0..) |name, index| {
        if (index != 0) err.print(", ", .{}) catch return;
        err.print("{s}", .{name}) catch return;
    }
    err.print("\n", .{}) catch return;
    err.print("  tools/call {s}: a result carrying back the text that went out\n", .{tool_echo}) catch return;
    err.print("  tools/call {s}: a result with isError, which is not a peer error\n", .{
        tool_fail,
    }) catch return;
    // A missing one is printed as the missing thing it is rather than as a
    // zero, which is a code the peer could have meant.
    const peer_code = report.peer_error_code orelse {
        err.print("  tools/call with no name: the peer's error carried no code\n", .{}) catch return;
        return;
    };
    err.print("  tools/call with no name: a peer error, code {d}\n", .{peer_code}) catch return;
    const cancel_code = report.cancelled_error_code orelse {
        err.print("  tools/call {s}: the peer's cancellation carried no code\n", .{
            tool_slow,
        }) catch return;
        return;
    };
    err.print("  tools/call {s}: cancelled in flight, answered with a peer error, code {d}\n", .{
        tool_slow, cancel_code,
    }) catch return;
    err.print("  hung up: the connection is closed and the peer will see end of file\n", .{}) catch return;
}

/// The tool names this run received, which is as many as the peer offered up
/// to what the report holds.
fn namedTools(report: *const Report) []const []const u8 {
    return report.tools[0..@min(report.tool_count, report.tools.len)];
}

/// Write the report to the path this run was given, or to nothing at all when
/// it named none.
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
/// literal rather than as a member that ends early or bytes a reader on the far
/// side refuses. The buffer is sized from [`report_capacity`], which is the
/// whole report at the worst escaping a peer can produce; a buffer with no room
/// is `error.BufferTooSmall` with the prefix already written left as it was,
/// never a document cut short.
fn encodeReport(buffer: []u8, report: *const Report) proto.EncodeError![]const u8 {
    var text = json.Writer.init(buffer);
    try text.slice("{\"revision\":");
    try text.string(report.revision);
    try text.slice(",\"protocol_version\":");
    try text.string(report.protocol_version);
    try text.slice(",\"tools\":[");
    for (namedTools(report), 0..) |name, index| {
        if (index != 0) try text.byte(',');
        try text.string(name);
    }
    try text.slice("],\"tool_count\":");
    try number(&text, report.tool_count);
    try text.slice(",\"echo_text\":");
    try text.string(report.echo_text);
    try text.slice(",\"fail_is_error\":");
    try boolean(&text, report.fail_is_error);
    try text.slice(",\"peer_error_code\":");
    try optionalNumber(&text, report.peer_error_code);
    try text.slice(",\"cancelled_error_code\":");
    try optionalNumber(&text, report.cancelled_error_code);
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

fn parseArgs(init: std.process.Init) Options {
    var options: Options = .{};
    var it = std.process.Args.iterate(init.minimal.args);
    _ = it.skip();
    while (it.next()) |argument| {
        const flag: []const u8 = argument;
        if (std.mem.eql(u8, flag, "--slow-entered-file")) {
            options.slow_entered_file = it.next() orelse break;
        } else if (std.mem.eql(u8, flag, "--report-file")) {
            options.report_file = it.next() orelse break;
        } else if (std.mem.eql(u8, flag, "--cancel-timeout-ms")) {
            const value = it.next() orelse break;
            options.cancel_timeout_ms = std.fmt.parseInt(i64, value, 10) catch options.cancel_timeout_ms;
        } else {
            continue;
        }
    }
    return options;
}

// --- storage --------------------------------------------------------------------
//
// Every buffer this file needs is at file scope, because the tasks borrow
// pointers to it and those pointers have to outlive the group. The decoders'
// scratch is one region used one at a time: a decoded result is read before the
// next one is decoded, so no two borrows out of it are live at once.

var buffers: stdio.Buffers = .{};

/// Scratch for the two readers below and for the `tools/call` decoder.
var client_scratch: [8192]u8 = undefined;

/// Where the names in a `tools/list` answer are read, and the content blocks
/// and verbatim store the `tools/call` decoder fills.
///
/// Sixteen names against eight report slots, on purpose. A peer offering more
/// tools than the report holds is a finding this run names, where one array
/// sized to the report would make the same peer a decode failure instead — and
/// a capacity failure is the caller's own sizing mistake, which is not what a
/// peer that serves more tools than expected is.
var tool_names: [16][]const u8 = undefined;
var verbatim: [32]mcp.VerbatimMember = undefined;
var content: [16]mcp.ContentBlock = undefined;

// --- the reads the first run of this exchange got wrong ------------------------

test "initialize: the revision is read as the string it is, not as its lexeme" {
    // The answer the SDK sent, byte for byte. `json.memberText` reports the
    // member it finds here as `"2025-11-25"` with its quotes, and comparing
    // that with the revision this client is pinned to is the mismatch the first
    // run of this exchange failed on, with a peer that had answered correctly.
    const answer =
        "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{\"listChanged\":false}}," ++
        "\"serverInfo\":{\"name\":\"peer\",\"version\":\"1.29.0\"}}";
    var scratch: [256]u8 = undefined;
    const negotiated = (try stringMember(answer, "protocolVersion", &scratch)) orelse
        return error.NoProtocolVersion;
    try testing.expectEqualStrings(mcp.previous_protocol_version, negotiated);
    try testing.expectEqualStrings("2025-11-25", negotiated);
    // Decoded rather than cut: a member whose bytes spell the revision with
    // escapes is the same revision, and only a decode says so.
    const escaped = try stringMember(
        "{\"capabilities\":{},\"protocolVersion\":\"2025\\u002d11\\u002d25\"}",
        "protocolVersion",
        &scratch,
    );
    try testing.expectEqualStrings("2025-11-25", escaped.?);
}

test "initialize: a member that is absent, repeated, or not a string" {
    var scratch: [256]u8 = undefined;
    // Absent is absent. A document without the member is a handshake this run
    // cannot check, which is a finding rather than a null to compare.
    try testing.expect((try stringMember("{}", "protocolVersion", &scratch)) == null);
    try testing.expect((try stringMember("{\"capabilities\":{}}", "protocolVersion", &scratch)) == null);
    // The first occurrence wins, and a repeat is consumed rather than read, so
    // a later member cannot make a comparison that has already failed pass.
    try testing.expectEqualStrings("2025-11-25", (try stringMember(
        "{\"protocolVersion\":\"2025-11-25\",\"protocolVersion\":\"2026-07-28\"}",
        "protocolVersion",
        &scratch,
    )).?);
    // Including when the first one is empty: a revision is never empty, and a
    // member that is is still the member that is there.
    try testing.expectEqualStrings("", (try stringMember(
        "{\"protocolVersion\":\"\",\"protocolVersion\":\"2026-07-28\"}",
        "protocolVersion",
        &scratch,
    )).?);
    // A value that is not a string is refused, not trimmed into one.
    try testing.expectError(
        error.MalformedJson,
        stringMember("{\"protocolVersion\":2025}", "protocolVersion", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        stringMember("{\"protocolVersion\":null}", "protocolVersion", &scratch),
    );
    // The walk is finished rather than stopped at the match: a fault after the
    // member is a fault in the document, and bytes after the closing brace are
    // a second document the transport did not split.
    try testing.expectError(
        error.MalformedJson,
        stringMember("{\"protocolVersion\":\"2025-11-25\",\"x\":}", "protocolVersion", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        stringMember("{\"protocolVersion\":\"2025-11-25\"} {\"a\":1}", "protocolVersion", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        stringMember("[]", "protocolVersion", &scratch),
    );
}

test "tools/list: the names are read out of the answer this revision sends" {
    // The answer the SDK sent for this revision: no `ttlMs`, no `cacheScope`,
    // and tools carrying a name, a description and a schema. Only the names are
    // read, and `nextCursor` is stepped over rather than mistaken for a tool.
    const answer =
        "{\"tools\":[" ++
        "{\"name\":\"echo\",\"description\":\"Return the text it was given.\"," ++
        "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}}," ++
        "{\"name\":\"fail\",\"description\":\"Fail on purpose.\",\"inputSchema\":{\"type\":\"object\"}}," ++
        "{\"name\":\"slow\",\"inputSchema\":{\"type\":\"object\"}}" ++
        "],\"nextCursor\":\"page-2\"}";
    var scratch: [512]u8 = undefined;
    var out: [8][]const u8 = undefined;
    const listed = try toolNames(answer, &out, &scratch);
    try testing.expectEqual(@as(usize, 3), listed.names.len);
    try testing.expectEqualStrings("echo", listed.names[0]);
    try testing.expectEqualStrings("fail", listed.names[1]);
    try testing.expectEqualStrings("slow", listed.names[2]);
    // In the order the peer sent them, which is the order the supervisor
    // compares the report with the wire in.
    try testing.expect(offerNames(listed.names, tool_echo));
    try testing.expect(offerNames(listed.names, tool_fail));
    try testing.expect(offerNames(listed.names, tool_slow));
    try testing.expect(!offerNames(listed.names, "absent"));
}

test "tools/list: what the answer has to carry, and what it must not" {
    var scratch: [512]u8 = undefined;
    var out: [8][]const u8 = undefined;
    // An empty page is a page: nothing is wrong with a peer that offers none,
    // and the run's own check for the three tools is what says otherwise.
    try testing.expectEqual(@as(usize, 0), (try toolNames("{\"tools\":[]}", &out, &scratch)).names.len);
    // An answer with no `tools` member is refused rather than read as no tools.
    try testing.expectError(error.MissingField, toolNames("{}", &out, &scratch));
    // More tools than the caller's array holds is a capacity failure, not a list
    // that stops where the array does.
    var two: [2][]const u8 = undefined;
    try testing.expectError(error.BufferTooSmall, toolNames(
        "{\"tools\":[{\"name\":\"a\"},{\"name\":\"b\"},{\"name\":\"c\"}]}",
        &two,
        &scratch,
    ));
    // A tool entry that is not an object, and a name that is not a string.
    try testing.expectError(error.MalformedJson, toolNames("{\"tools\":[\"echo\"]}", &out, &scratch));
    try testing.expectError(
        error.MalformedJson,
        toolNames("{\"tools\":[{\"name\":7}]}", &out, &scratch),
    );
    // A tool with no name is a tool this run cannot call, and the report has no
    // way to say one of the three names was offered by it.
    try testing.expectError(
        error.MissingField,
        toolNames("{\"tools\":[{\"description\":\"no name at all\"}]}", &out, &scratch),
    );
    // A fault after the names is a fault in the answer, because the walk is
    // finished rather than stopped at the first one: the second entry here is
    // not a tool object, and a reader that had already taken the first name
    // would call this answer a one-tool page.
    try testing.expectError(
        error.MalformedJson,
        toolNames("{\"tools\":[{\"name\":\"echo\"},\"slow\"]}", &out, &scratch),
    );
    try testing.expectError(error.MalformedJson, toolNames("{\"tools\":[]} {}", &out, &scratch));
    // The first occurrence of a repeated member wins, at both levels, and a
    // repeat is consumed rather than read.
    const outer = try toolNames(
        "{\"tools\":[{\"name\":\"echo\"}],\"tools\":[{\"name\":\"slow\"}]}",
        &out,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 1), outer.names.len);
    try testing.expectEqualStrings("echo", outer.names[0]);
    const inner = try toolNames("{\"tools\":[{\"name\":\"echo\",\"name\":\"slow\"}]}", &out, &scratch);
    try testing.expectEqualStrings("echo", inner.names[0]);
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
    // answering with control bytes in its tool names, its negotiated revision
    // or the text it echoed is an ordinary thing for it to do, and the report
    // is the only account of what it said: a run that was complete and could
    // not say so failed for having been complete.

    // A control byte takes six JSON bytes.
    const fillWorst = struct {
        fn fill(storage: []u8) []const u8 {
            @memset(storage, 0x01);
            return storage;
        }
    }.fill;

    var report: Report = .{ .io = testing.io };
    report.protocol_version = fillWorst(&report.version_text);
    for (report.tools, 0..) |_, index| {
        report.tools[index] = fillWorst(&report.tool_name_store[index]);
    }
    report.tool_count = report.tools.len;
    report.echo_text = fillWorst(&report.echo_store);
    report.fail_is_error = true;
    report.peer_error_code = std.math.minInt(i32);
    report.cancelled_error_code = std.math.minInt(i32);
    var message: [failure_capacity]u8 = undefined;
    report.failure = fillWorst(message[0 .. failure_capacity - 1]);
    report.ok = false;

    var buffer: [report_capacity]u8 = undefined;
    const document = try encodeReport(&buffer, &report);

    // One complete JSON value: every member walked, and nothing after it.
    var reader = json.Reader.init(document);
    var scratch: [64]u8 = undefined;
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
    var decoded: [report.echo_store.len]u8 = undefined;
    var expected: [report.echo_store.len]u8 = undefined;
    try testing.expectEqualStrings(fillWorst(&expected), try echo_reader.string(&decoded));

    // A buffer that cannot hold the whole report is refused rather than cut
    // short: half a document is one no reader can parse, and the supervisor
    // would read it as a report about a run that never happened.
    var narrow: [64]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, encodeReport(&narrow, &report));
}
