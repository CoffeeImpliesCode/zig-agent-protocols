//! The Zig half of the Agent Client Protocol interoperability exchange.
//!
//! This is a participant, not a library module. `test/interop/acp_peer.py`
//! starts this executable as a child process with pipes on its standard
//! streams, and an independent upstream SDK serves the other end of them, so
//! the bytes this file puts on standard output are the real wire between two
//! implementations. Nothing here is imported by the library, and the library
//! keeps its zero-dependency guarantee because this process is a peer and not
//! a caller.
//!
//! ## What it does, in the order the specification requires
//!
//!   1. `initialize`, with `protocolVersion` at the stable wire version 1 and
//!      the capability object this client actually backs, then the handshake
//!      read by `acp_session.Client.initialize` — including the agent's own
//!      `agentCapabilities`, decoded by `acp.decodeCapabilityObject` and
//!      recorded as the paths every later gate is decided against.
//!   2. `session/new`, whose `sessionId` is read out of the answer.
//!   3. `session/prompt`, during which the agent calls back on this client.
//!
//! ## The callback, and why it is the interesting part
//!
//! The one thing this exchange cannot do without is the direction the protocol
//! runs the other way. While `session/prompt` is in flight the agent sends
//! `session/request_permission` — a request, so it wants an answer — and this
//! file answers it from a handler on the reader task, through
//! `acp_session.answerPermissionRequest`.
//!
//! The answer is `PermissionAnswer`'s refusal, `.cancelled`, and it is the only
//! answer this file can produce. `answerPermissionRequest` takes a
//! [`ReadableOutcome`](proto.acp_session.ReadableOutcome) rather than a
//! [`PermissionAnswer`](proto.acp_session.PermissionAnswer), so it has no way
//! to name an option id: its `.grants` arm is a refusal, emitted as the error
//! `conn.errorResponse` writes. An agent that reads such an answer back gets
//! `PermissionDecision.unreadable`, which PROTOCOLS.md 6.6 makes a refusal
//! rather than an approval. A participant that could have granted here would be
//! a different program, so this one cannot: the request is decoded, the
//! offered options and their kinds are read and reported, and every one of them
//! is refused.
//!
//! Two independent things then say the refusal reached the wire. The peer
//! parses this answer with the SDK's own `RequestPermissionResponse` model and
//! records the outcome it got, and the supervisor reads the answer out of the
//! captured bytes. Neither is this file's own opinion of what it wrote.
//!
//! ## Two answers this file reads for itself
//!
//! `session/new` and `session/prompt` are answered with `sessionId` and
//! `stopReason`, and the library models neither type, so [`readMember`] and
//! [`readStopReason`] are one borrowing `json.Reader` over the peer's own
//! bytes. They are deliberately not `NewSessionResponse` and not
//! `PromptResponse`: this run consumes one string out of each, and a member it
//! does not read is a member it does not claim to have decoded.
//!
//! `session/update` is the same case one level down. The agent's notification
//! carries a `ToolCall`-free `agent_message_chunk` whose text is the prompt
//! that went out, and [`readUpdate`] reads that text back out of the peer's
//! bytes with the same rule. Content in a notification is not evidence the
//! agent ran: the comparison is between the text that went out and the text
//! that came back, so a peer that answered with anything else fails.
//!
//! ## Why the handler does not read a field the client task writes
//!
//! The handler runs on the reader task and `initialize` runs on the client
//! task, and a wire version is one number both would want. So the handler does
//! not read one: it is built for the version this process asked for, which is
//! fixed before either task starts, and every fact it needs is its own.
//! What the agent actually answered is read by the client task, which checks
//! it and fails the run on a version this run did not ask for — so a run never
//! proceeds on a pin nobody agreed to.
//!
//! ## The wait on the client task has a bound
//!
//! Every failure here is recorded by a task and printed by the main task, and
//! the ways a run goes wrong leave a task parked in a call the peer will never
//! answer. The watcher records what its budget found *before* it wakes the main
//! task, because the main task's answer to a budget that ran out is to close
//! the connection, and a client task still parked in a call fails that call
//! with a transport fault the instant the connection closes. Recorded first, it
//! stands: `failLocked` keeps the first finding.
//!
//! ## Output
//!
//! Standard output is the wire and carries nothing else. The report goes to
//! standard error, and the machine-readable findings go to the file
//! `--report-file` names, which the supervisor reads. Every field in that
//! report is a value the peer sent and this client's decoder read.
//!
//! A run that passed is flushed once, at the end, and that flush is not best
//! effort: a summary that never reached the supervisor is a pass it cannot
//! show the evidence for, so a failure in it is this process's exit status.

const std = @import("std");
const proto = @import("zig-agent-protocols");

const acp = proto.acp;
const acp_session = proto.acp_session;
const conn = proto.conn;
const json = proto.json;
const jsonrpc = proto.jsonrpc;
const stdio = proto.stdio;

const Io = std.Io;
const testing = std.testing;

/// The wire version this run asks for unless the command line says otherwise.
///
/// Stable, and not a coin: PROTOCOLS.md 6.1 makes 1 the wire version and 2 a
/// draft, and the published SDK's v1 constant is 1. `--protocol-version 2` is
/// the only way to reach the draft and it is an explicit gate, because a
/// participant that silently asked for a version the peer had not agreed to
/// would be testing the peer's refusal rather than the protocol.
const default_requested_version: u16 = 1;

/// What this participant calls itself in the handshake. A fixed name and
/// version, so a capture taken from two runs is comparable to another and
/// carries nothing about the machine that produced it.
const client_name = "zig-agent-protocols-acp-interop";
const client_version = "0.0.0";

/// The workspace root `session/new` names, and one line because a newline
/// inside params is what NDJSON forbids and what the framing layer then
/// refuses.
///
/// Nothing touches it. The peer agent records it and answers; a workspace root
/// on the wire is a value the agent is told about, and fixing it is what lets
/// two captures be compared. It is absolute, which v2 requires and v1 names.
const session_cwd = "/zig-agent-protocols-acp-interop";

/// The text that goes out in `session/prompt` and has to come back in the
/// agent's `session/update`. One value on both sides of the exchange, so the
/// comparison is a comparison rather than two literals that happen to agree.
const prompt_text = "zig-agent-protocols";

/// The `clientInfo` object, built at comptime from the values above.
const client_info = std.fmt.comptimePrint(
    "{{\"name\":\"{s}\",\"version\":\"{s}\"}}",
    .{ client_name, client_version },
);

/// The `clientCapabilities` this client may honestly send.
///
/// Every member is `false` and nothing is present, which is not a stand-in for
/// a capability set: it is this participant's. It serves `session/update` and
/// `session/request_permission`, both ungated in the v1 registry, and it
/// serves no `fs/*`, no `terminal/*` and no `elicitation/*`, so
/// `acp.advertisedPaths` over this object returns nothing and every gated
/// client method is refused rather than answered on a capability this client
/// never claimed. A run that advertised one of them would be claiming a
/// method its handler does not have.
const client_capabilities_v1 =
    "{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false}," ++
    "\"terminal\":false,\"auth\":{\"terminal\":false}}";

/// The v2 capability object: `fs` and `terminal` do not exist there at all, so
/// the v1 text above would be a member v2 does not declare. An empty object is
/// the same claim the v1 one makes — nothing beyond the baseline — spelled the
/// way the v2 schema spells it.
const client_capabilities_v2 = "{}";

/// `session/new` at v1, where `mcpServers` is a required member with no
/// default, and at v2, where it is optional and the required list is `cwd`
/// alone. No MCP server is offered on either: this exchange is about ACP, and
/// a server this participant never starts would be a claim it cannot back.
const new_session_params_v1 =
    "{{\"cwd\":\"{s}\",\"mcpServers\":[]}}";
const new_session_params_v2 =
    "{{\"cwd\":\"{s}\"}}";

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

/// What the run received, in the order the supervisor checks it.
///
/// Every field is a value the peer sent and this client's own decoder read,
/// rather than a conclusion drawn here: the supervisor compares each one with
/// the bytes that crossed the pipes, so a report cannot agree with a capture
/// it never saw.
///
/// The fields are split by which task writes them. Everything the client task
/// writes is written once, before the exchange or by the client task itself.
/// Everything the handler writes is written under `mutex`, and the client task
/// reads it under the same lock, which is what orders the two.
const Report = struct {
    /// The lock `failLocked` and the handler take. Three tasks write here and
    /// "the first failure is the finding" is a read-then-write that three
    /// tasks would otherwise interleave.
    io: Io,
    mutex: Io.Mutex = .init,

    /// The version this run asked for, and the one the agent answered with.
    /// Both are wire numbers, because that is what the wire spells.
    requested_version: u16 = default_requested_version,
    negotiated_version: u16 = 0,

    /// Whether the agent advertised a non-empty `authMethods`. Read by
    /// `initialize` and reported rather than assumed, because it is the gate
    /// on two methods at v2.
    agent_auth_methods: bool = false,

    /// The capability paths the agent advertised, copied out of the region
    /// `acp.decodeCapabilityObject` builds them in and bounded on both counts.
    /// A peer that advertised more than this report holds is reported rather
    /// than quietly shortened: the supervisor compares this list with the wire
    /// and a difference fails the run.
    // SAFETY: keep copies one path into store and capabilities reads at most that many.
    capability_store: [16][64]u8 = undefined,
    capabilities: [16][]const u8 = .{ "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" },
    capability_count: usize = 0,

    /// The `sessionId` `session/new` answered with, copied out of the decode
    /// scratch: that scratch is used one decode at a time and the next decode
    /// would overwrite it, and a report read at the end of the run must still
    /// name the session the exchange was about.
    // SAFETY: keep copies the session id into it and session_id is set to that prefix.
    session_store: [128]u8 = undefined,
    session_id: []const u8 = "",

    /// Notifications for the issued session, and the first text update's
    /// variant and text. Both decoded values are compared with the capture.
    session_update_count: usize = 0,
    // SAFETY: keep copies the echoed text into it and echoed_text is set to that prefix.
    echo_store: [512]u8 = undefined,
    echoed_text: []const u8 = "",
    echoed_text_seen: bool = false,
    // SAFETY: keep fills this store before session_update_variant borrows it.
    update_variant_store: [64]u8 = undefined,
    session_update_variant: []const u8 = "",

    /// How many `session/request_permission` requests arrived, what they
    /// offered, and how many of the options they offered would have granted.
    ///
    /// The count of granting options is the point of the pair: an offer this
    /// client refused is not an offer with nothing in it, and a report that
    /// recorded only the refusal would be the same report whatever the agent
    /// asked for.
    permission_request_count: usize = 0,
    // SAFETY: keep copies one option id into it and permission_options reads at most that many.
    option_store: [8][64]u8 = undefined,
    permission_options: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },
    permission_option_count: usize = 0,
    permission_granting_option_count: usize = 0,

    /// The outcome this client answered with, as the library names it, and
    /// whether it granted. Empty means no permission request ever arrived,
    /// which is a different fact from a refusal and is checked as one.
    // SAFETY: keep copies the outcome name into it and permission_answer is set to that prefix.
    answer_store: [32]u8 = undefined,
    permission_answer: []const u8 = "",
    permission_grants: bool = false,
    /// The `stopReason` `session/prompt` answered with, copied out of the
    /// decode scratch on the same terms as the session id.
    // SAFETY: keep copies the stop reason into it and stop_reason is set to that prefix.
    stop_store: [32]u8 = undefined,
    stop_reason: []const u8 = "",

    /// The `messageId` v2's `session/prompt` answers with, copied out of the
    /// decode scratch on the same terms. Empty at v1, which has no such member,
    /// and a report that carried a v1 stop reason and a v2 message id in one
    /// field would be a report about a run that did not happen.
    // SAFETY: keep copies the message id into it and prompt_message_id is set to that prefix.
    message_store: [128]u8 = undefined,
    prompt_message_id: []const u8 = "",

    failure: []const u8 = "",
    ok: bool = false,
};

/// The most bytes one failure message holds.
///
/// `fail` copies into the buffer it is handed, and the handler's own buffer
/// and the main task's are both one of these, so `failure` is one of them and
/// nothing longer. It is named rather than written into the bound below as a
/// number, because a bound quoting a size the messages do not carry is a bound
/// about a report that does not exist.
const failure_capacity: usize = 512;

/// The most bytes the report's own storage holds as text.
///
/// Every value the agent sent is a slice into a fixed array declared beside it
/// — `keep` is the one place those slices are made — so `@sizeOf(Report)`
/// covers all of them along with the slice headers and the counters this
/// struct carries. Reading it rather than summing the arrays out by hand is
/// what makes a store added here widen the bound with it.
const report_text_capacity: usize = @sizeOf(Report) + failure_capacity;

/// The most bytes one decoded byte costs in the report.
///
/// `json.Writer.string` escapes what the JSON grammar forbids and passes
/// every other byte through, so the widest case is a control byte written as
/// `\u00XX`: six bytes for one. A session id, an echoed prompt, a capability
/// path or an option id carrying control bytes is a thing an agent can send,
/// and a bound sized for printable text is short by six times over.
const report_escape_width: usize = 6;

/// The bytes the report spends on what is not a decoded byte.
///
/// Every member name with its quotes and its colon, the brackets, the commas,
/// one decimal rendering per number, the booleans and the null: well under a
/// kilobyte for this schema at its widest. It is fixed because the schema is,
/// and 2048 is the next step above that kilobyte — slack this file does not
/// have to keep true by hand, in place of a bound that moves whenever a member
/// is added.
const report_syntax_capacity: usize = 2048;

/// The buffer the report is composed in, before the one write that hands it to
/// the file.
///
/// Six bytes for every byte the report's own storage holds, plus the syntax
/// around them: the whole report at the worst escaping an agent can produce,
/// with nothing allocated to get there and nothing grown when it does not fit.
const report_capacity: usize = report_escape_width * report_text_capacity + report_syntax_capacity;

/// The reader task's side of the exchange.
///
/// Version and advertised capabilities are fixed before either task starts.
/// The client publishes the issued session id under the report mutex; this
/// handler compares notifications with it under the same mutex.
const Handler = struct {
    version: acp.WireVersion,
    /// What this client advertised in its own `initialize`. Empty is the
    /// answer `client_capabilities_v1` decodes to, so every gated client
    /// method is refused rather than answered on a capability this client
    /// never claimed.
    advertised: []const []const u8 = &.{},
    report: *Report,
    /// This handler's own message buffer. Three tasks write `report.failure`
    /// and one buffer for all of them is a race on the finding itself.
    // SAFETY: failLocked fills this buffer before report.failure borrows it.
    message: [failure_capacity]u8 = undefined,
    // SAFETY: keep copies the message into it and report.failure is set to that prefix.
    detail: [256]u8 = undefined,

    /// Whether this client serves a client method the agent called, asked on
    /// the same gate `acp_session.Client.accepts` applies, over the same
    /// advertised list and the same `Shape` the frame's arity implies.
    fn accepts(self: *const Handler, method: []const u8, shape: acp_session.Shape) bool {
        _ = acp_session.checkCall(self.version, method, shape, .client, self.advertised, true) catch
            return false;
        return true;
    }

    fn record(self: *Handler, step: []const u8, err: anyerror) void {
        if (err == error.Canceled) return;
        fail(self.report, &self.message, cause(step, &self.detail, err));
    }
};

/// Options, read from the command line. The supervisor passes both; a run
/// without `--report-file` still works and simply has nothing to hand back.
const Options = struct {
    protocol_version: u16 = default_requested_version,
    report_file: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const options = parseArgs(init) catch |fault| try refuse(io, switch (fault) {
        error.UnknownFlag => "a flag this participant does not take",
        error.MissingValue => "a flag was given without the value it needs",
        error.NotANumber => "--protocol-version takes a decimal number",
    });

    // The wire version is resolved before either task starts, so the reader
    // task's gate and the client session's pin are the same number decided in
    // one place rather than a field two tasks read and one writes.
    var phrase: [128]u8 = undefined;
    const version = acp.WireVersion.fromNumber(options.protocol_version) orelse
        try refuse(io, std.fmt.bufPrint(&phrase, "{d} is not an ACP wire version this client implements", .{
            options.protocol_version,
        }) catch "an ACP wire version this client does not implement");

    var report_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &report_buffer);
    const err = &stderr.interface;

    // The report is a value, so it needs storage that outlives every task
    // below, and so does the message a failed check leaves behind. Both are
    // fixed buffers, because the failure path allocates nothing either.
    var message: [failure_capacity]u8 = undefined;
    var detail: [256]u8 = undefined;
    var report: Report = .{ .io = io, .requested_version = options.protocol_version };

    var handler: Handler = .{ .version = version, .report = &report };

    var transport = try stdio.Stdio.init(io, &buffers.read, &buffers.write);
    var connection = try transport.connection(buffers.config());
    connection.setHandler(.{
        .ctx = @ptrCast(&handler),
        .call = handlerCall,
    });

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
        .{ io, version, &connection, &ending, &done, &report, &message, &detail },
    );
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
    // step that named what it found sooner is still what this run reports, and
    // the budget is the finding only for a run in which nothing got far enough
    // to name one.

    // Read under the lock the tasks wrote their findings with. Nothing can take
    // it now that the group is joined; taking it anyway keeps this read and
    // those writes under one rule rather than two.
    report.mutex.lockUncancelable(io);
    report.ok = report.failure.len == 0;
    report.mutex.unlock(io);
    try writeReport(io, &options, &report);
    try printSummary(err, version, &report);
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
/// answer fails that call with a transport fault the moment the connection
/// closes.
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

/// Which of the two ended the exchange: the client task finished it, or the
/// budget ran out first.
///
/// One lock for the decision, because the two are one decision taken from two
/// sides and only one of them may stand. The client task marks itself finished
/// as it returns, on every path including a failed check, and the watcher asks
/// before it records anything; whichever of the two takes the lock first
/// reached the end of the exchange first in real time.
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

/// The client task: the whole exchange, in the order the specification requires.
fn clientTask(
    io: Io,
    version: acp.WireVersion,
    connection: *conn.Conn,
    ending: *Ending,
    done: *Io.Semaphore,
    report: *Report,
    message: *[failure_capacity]u8,
    detail: *[256]u8,
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

    var client = acp_session.Client.init(connection, version);

    // 1. initialize. The handshake is the library's own: it composes the params
    //    under the member names the version spells, reads the answer's version
    //    under the same names, and repins the session to what the agent chose.
    const handshake = client.initialize(
        version.number(),
        client_info,
        clientCapabilities(version),
        &buffers.result,
        &buffers.out,
        &handshake_params,
        &handshake_scratch,
    ) catch |err| {
        record(report, message, "initialize: the call itself failed", detail, err);
        return;
    };
    if (handshake.error_code) |code| {
        var refusal: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&refusal, "initialize: the peer refused the handshake with code {d}", .{
            code,
        }) catch "initialize: the peer refused the handshake";
        fail(report, message, text);
        return;
    }
    // A null version with a null error code is PROTOCOLS.md 6.1 rule 3: an
    // agent answered with a version this library does not implement. It is
    // reported rather than treated as the version that was asked for.
    const negotiated = handshake.version orelse {
        fail(report, message, "initialize: the peer answered with a wire version this client does not speak");
        return;
    };
    report.negotiated_version = negotiated.number();
    if (negotiated != version) {
        fail(report, message, "initialize: the peer negotiated a version this run did not ask for");
        return;
    }
    report.agent_auth_methods = handshake.auth_methods;

    // The capability object the agent answered with, read by the library's own
    // v1 (or v2) capability decoder and turned into the paths every later gate
    // is decided against. A peer that advertised nothing leaves the list empty,
    // which refuses every gated agent method rather than sending one to be
    // rediscovered.
    var advertised: []const []const u8 = &.{};
    if (handshake.capabilities) |raw| {
        const set = acp.decodeCapabilityObject(
            negotiated,
            .agent,
            raw,
            &capabilities,
            &capability_paths,
            &capability_scratch,
        ) catch |err| {
            record(report, message, "initialize: the agent capabilities did not decode", detail, err);
            return;
        };
        advertised = acp.advertisedPaths(set, &advertised_capabilities) catch |err| {
            record(report, message, "initialize: the agent capabilities did not decode", detail, err);
            return;
        };
    }
    client.setAgentCapabilities(advertised);
    if (advertised.len > report.capabilities.len) {
        fail(report, message, "initialize: the peer advertised more capabilities than this report holds");
        return;
    }
    report.capability_count = advertised.len;
    for (advertised, 0..) |path, index| {
        report.capabilities[index] = keep(&report.capability_store[index], path);
    }

    // 2. session/new. The `mcpServers` member is required at v1 and optional at
    //    v2, so the params are spelled for the version rather than trimmed
    //    after the fact.
    const created = client.request(
        "session/new",
        newSessionParams(version),
        &buffers.result,
        &buffers.out,
    ) catch |err| {
        record(report, message, "session/new: the call itself failed", detail, err);
        return;
    };
    if (created.failed()) {
        fail(report, message, "session/new: the peer refused the request");
        return;
    }
    // The id is the peer's text and is spliced into the next request's params,
    // so it is copied into the report before anything reuses the region it was
    // read out of, and it is composed below with the JSON writer rather than
    // pasted: an id carrying a quote or a newline must not be able to build a
    // frame the transport then refuses.
    const session_id = readMember(created.body, "sessionId", &client_scratch) catch |err| {
        record(report, message, "session/new: the answer did not decode", detail, err);
        return;
    } orelse {
        fail(report, message, "session/new: the answer carried no sessionId");
        return;
    };
    // Refused rather than shortened, unlike the fields below: this one is load
    // bearing. The next request's params are composed from the copy, so a
    // truncated id would be a session the agent never issued, and the failure
    // would surface as a prompt it refused rather than as the peer that chose
    // an id this report cannot hold.
    if (session_id.len > report.session_store.len) {
        fail(report, message, "session/new: the peer's sessionId is longer than this report holds");
        return;
    }
    report.mutex.lockUncancelable(io);
    report.session_id = keep(&report.session_store, session_id);
    report.mutex.unlock(io);

    // 3. session/prompt. The agent answers this request only after it has had
    //    its `session/request_permission` answered, so the fields the handler
    //    wrote are all present by the time the call below returns; the lock
    //    below is what makes that ordering a fact about memory as well as
    //    about the wire.
    const prompt_body = composePrompt(&prompt_params, report.session_id) catch |err| {
        record(report, message, "session/prompt: the params did not fit their own buffer", detail, err);
        return;
    };
    const prompted = client.request(
        "session/prompt",
        prompt_body,
        &buffers.result,
        &buffers.out,
    ) catch |err| {
        record(report, message, "session/prompt: the call itself failed", detail, err);
        return;
    };
    if (prompted.failed()) {
        fail(report, message, "session/prompt: the peer refused the prompt");
        return;
    }
    // The prompt result is not the same member at the two versions, and the
    // difference is structural rather than additive: v2 answers as soon as it
    // has inserted the user message, so it returns the id of what it inserted
    // instead of a reason for stopping. One reader over the member this version
    // names, rather than a check for one member and a hope about the other.
    const prompt_member = if (version == .stable) "stopReason" else "messageId";
    const prompt_value = readMember(prompted.body, prompt_member, &client_scratch) catch |err| {
        record(report, message, "session/prompt: the answer did not decode", detail, err);
        return;
    } orelse {
        var missing: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&missing, "session/prompt: the answer carried no {s}", .{
            prompt_member,
        }) catch "session/prompt: the answer carried no prompt result member";
        fail(report, message, text);
        return;
    };
    if (version == .stable) {
        report.stop_reason = keep(&report.stop_store, prompt_value);
    } else {
        report.prompt_message_id = keep(&report.message_store, prompt_value);
    }

    // Everything the handler recorded, read under the lock it wrote with.
    report.mutex.lockUncancelable(io);
    if (report.failure.len != 0) {
        // A handler finding is a finding: the peer asked for something this
        // client will not answer, and that happened while the prompt was in
        // flight rather than after it.
        report.mutex.unlock(io);
        return;
    }
    if (report.session_update_count == 0) {
        failLocked(report, message, "session/prompt: the agent sent no session/update while it answered");
        report.mutex.unlock(io);
        return;
    }
    if (!std.mem.eql(u8, report.echoed_text, prompt_text)) {
        failLocked(report, message, "session/update: the agent answered with text this client did not send");
        report.mutex.unlock(io);
        return;
    }
    if (report.permission_request_count == 0) {
        failLocked(report, message, "session/prompt: the agent never asked this client for permission");
        report.mutex.unlock(io);
        return;
    }
    if (report.permission_answer.len == 0) {
        failLocked(report, message, "session/request_permission: the request arrived and was never answered");
        report.mutex.unlock(io);
        return;
    }
    if (report.permission_grants) {
        // Unreachable through the handler, which has no arm that produces it.
        // It is checked because a check that cannot fail is not a check: if a
        // later change gave this participant a way to answer with an option id,
        // this is the line that says the run is no longer the program that was
        // reviewed.
        failLocked(report, message, "session/request_permission: this client answered with a grant");
        report.mutex.unlock(io);
        return;
    }
    report.mutex.unlock(io);
}

/// The reader task's handler: the direction the agent runs.
///
/// Runs inline on the pump task, which is why it answers rather than calls: the
/// reader that would deliver an answer to an outbound call is the very task now
/// waiting for one.
fn handlerCall(
    ctx: ?*anyopaque,
    frame: []const u8,
    decode_scratch: []u8,
    answer: []u8,
) conn.Error!?[]const u8 {
    const self: *Handler = @ptrCast(@alignCast(ctx orelse return error.InvalidMessage));

    // A frame this library cannot read is recorded rather than raised: an error
    // returned here is answered with an internal error, and answering a
    // notification nobody asked an answer to is a frame this run invented.
    const message = jsonrpc.decode(frame, decode_scratch) catch |err| {
        self.record("an inbound frame", err);
        return null;
    };
    switch (message.kind) {
        .notification => {
            const method = message.method orelse {
                self.record("an inbound notification carrying no method", error.MalformedJson);
                return null;
            };
            if (!self.accepts(method.text, .notification)) {
                self.record("a client notification this client does not serve", error.UnknownMethod);
                return null;
            }
            if (!std.mem.eql(u8, method.text, "session/update")) {
                // The only ungated client notifications are `session/update`
                // and `elicitation/complete`, and this client implements one of
                // them. A peer that sent the other asked for a handler that does
                // not exist, which is a finding rather than a frame to drop.
                self.record("a client notification this client does not implement", error.UnknownMethod);
                return null;
            }
            const params = paramsOf(message.params) orelse {
                self.record("session/update", error.MissingField);
                return null;
            };
            const update = readUpdate(params, &update_scratch) catch |err| {
                self.record("session/update", err);
                return null;
            };
            self.report.mutex.lockUncancelable(self.report.io);
            defer self.report.mutex.unlock(self.report.io);
            if (!std.mem.eql(u8, update.session_id, self.report.session_id)) {
                failLocked(self.report, &self.message, "session/update: the notification names another session");
                return null;
            }
            self.report.session_update_count += 1;
            // A text update is captured once, including an empty first text.
            if (!self.report.echoed_text_seen) {
                if (update.text) |text| {
                    if (update.variant.len > self.report.update_variant_store.len) {
                        failLocked(self.report, &self.message, "session/update: the variant exceeds report storage");
                        return null;
                    }
                    self.report.echoed_text_seen = true;
                    self.report.echoed_text = keep(&self.report.echo_store, text);
                    self.report.session_update_variant = keep(&self.report.update_variant_store, update.variant);
                }
            }
            return null;
        },
        .request => {
            const request = requestOf(message) orelse {
                self.record("an inbound request this library could not read", error.MalformedJson);
                return null;
            };
            // Two refusals, one answer: the gate is what this client advertised
            // and the name is what it implements, and a peer that asked for
            // either the wrong method or a method on a capability it never
            // claimed is owed the same `-32601` the connection writes.
            if (!self.accepts(request.method.text, .request) or
                !std.mem.eql(u8, request.method.text, "session/request_permission"))
            {
                return try conn.methodNotFound(request, answer);
            }
            const params = paramsOf(request.params) orelse {
                self.record("session/request_permission", error.MissingField);
                return null;
            };
            // The request itself, decoded by the library's own permission
            // decoder: the options, their ids and their kinds are what a user
            // would have been choosing between, and a report that named the
            // refusal without naming them would be true of every agent.
            const permission = acp.decodePermissionRequest(
                self.version,
                params,
                &permission_options,
                &permission_scratch,
            ) catch |err| {
                self.record("session/request_permission", err);
                return null;
            };
            self.report.mutex.lockUncancelable(self.report.io);
            self.report.permission_request_count += 1;
            const offered: []const acp.PermissionOption = switch (permission) {
                .stable => |value| value.options,
                .draft => |value| value.options,
            };
            if (offered.len > self.report.permission_options.len) {
                // Reported rather than shortened: a truncated choice list would
                // hide the option the peer wanted this client to name, and a
                // capacity failure reported as a decode fault would name the
                // wrong one of the two.
                self.report.mutex.unlock(self.report.io);
                fail(
                    self.report,
                    &self.message,
                    "session/request_permission: the peer offered more options than this report holds",
                );
                return null;
            }
            self.report.permission_option_count = offered.len;
            for (offered, 0..) |option, index| {
                self.report.permission_options[index] = keep(
                    &self.report.option_store[index],
                    option.option_id,
                );
                if (option.grants() orelse false) {
                    self.report.permission_granting_option_count += 1;
                }
            }
            self.report.mutex.unlock(self.report.io);

            // The answer. `answerPermissionRequest` takes a decision rather
            // than a choice, so `.cancelled` is the one outcome it can write
            // here and its `.grants` arm is the error the connection writes for
            // an answer that would need an option id. The name and the boolean
            // are recorded after the frame is composed, so a report that names
            // an answer is a report about bytes that were written.
            const written = try acp_session.answerPermissionRequest(request, .cancelled, answer);
            self.report.mutex.lockUncancelable(self.report.io);
            self.report.permission_answer = keep(&self.report.answer_store, "cancelled");
            self.report.permission_grants = false;
            self.report.mutex.unlock(self.report.io);
            return written;
        },
        .response => {
            // A response with no outstanding call. The connection routes those
            // to its orphan hook and this participant installs none, so the one
            // that reaches here is recorded rather than dropped: a peer that
            // answers a call this client never made is a fact about the run.
            self.record("a response naming no outstanding call", error.MalformedJson);
            return null;
        },
    }
}

/// The client capability object this client may honestly send, per version.
fn clientCapabilities(version: acp.WireVersion) []const u8 {
    return switch (version) {
        .stable => client_capabilities_v1,
        .draft => client_capabilities_v2,
    };
}

/// The `session/new` params, per version.
///
/// Composed at comptime from `session_cwd`, so neither text carries a newline:
/// those are the bytes the run depends on, and a run that assembled them across
/// lines would be one the peer cannot read. `session_cwd` is a fixed literal,
/// which is why it is safe to splice rather than encode here.
fn newSessionParams(version: acp.WireVersion) []const u8 {
    return switch (version) {
        .stable => std.fmt.comptimePrint(new_session_params_v1, .{session_cwd}),
        .draft => std.fmt.comptimePrint(new_session_params_v2, .{session_cwd}),
    };
}

/// The `session/prompt` params, composed from the session id the peer chose.
///
/// Through the JSON writer rather than a format string, because the session id
/// is peer-controlled: pasted into a format string, an id carrying a quote
/// would build a frame that is not the frame this client meant, and an id
/// carrying a newline would be refused by the framing layer at the worst
/// possible moment. `json.Writer.string` escapes both.
fn composePrompt(out: []u8, session_id: []const u8) proto.EncodeError![]const u8 {
    var text = json.Writer.init(out);
    try text.slice("{\"sessionId\":");
    try text.string(session_id);
    try text.slice(",\"prompt\":[{\"type\":\"text\",\"text\":");
    try text.string(prompt_text);
    try text.slice("}]}");
    return text.written();
}

/// The JSON-RPC request this frame carried, or null when it carried none.
///
/// Built from the decoded message rather than decoded a second time: the
/// decoder has already read the id, the method and the params, and a second
/// walk over the same frame would be a second answer to a question that was
/// already answered.
fn requestOf(message: jsonrpc.Message) ?jsonrpc.Request {
    const id = message.id orelse return null;
    const method = message.method orelse return null;
    return .{ .id = id, .method = method, .params = message.params };
}

/// The `params` member's bytes, or null for the two states that carry none.
///
/// An absent `params` and a `null` one are different facts and both arrive
/// here as null: a request whose body this client cannot see is a request it
/// will not answer from a guess.
fn paramsOf(params: jsonrpc.Params) ?[]const u8 {
    return switch (params) {
        .value => |value| value,
        .absent, .null_value => null,
    };
}

// --- the answers this file reads for itself ------------------------------------
//
// One borrowing `json.Reader` over the peer's own bytes: a name, a version and
// a string of text are slices of the document or of the caller's scratch, never
// a copy of it. `session/new`, `session/prompt` and `session/update` are not
// decoded by a library type on purpose — the library models no
// `NewSessionResponse`, no `PromptResponse` and no session notification, and a
// reader for one that did would be a second definition to keep in step with the
// schema rather than a check of this one.

/// One member of a result object, read as the JSON string it has to be.
///
/// `json.memberText` answers with the member's raw lexeme, so a string member
/// arrives with its quotes still on it. Trimming them here would be the same
/// mistake with a special case on top, so the member is decoded instead and
/// what comes back is what the peer sent.
///
/// Null is a document that carried no such member. The walk does not stop at
/// the match: a repeated member is consumed and not read again, because the
/// first occurrence wins and a later one must not be able to make a comparison
/// that has already failed pass, and a document with anything after its closing
/// brace is refused, because those bytes are a second document the transport
/// did not split.
fn readMember(
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

/// The three members this run reads out of a `session/update` notification.
///
/// The variant, so a peer that sent a different kind of update is named rather
/// than read as one carrying text, and the session it belongs to, so a peer's
/// notification for another session is visible in the capture and not folded
/// into this one's count. The text is optional because an update the library
/// does not model has none, and a run that insists on text for every variant
/// would be refusing a shape the protocol permits.
const Update = struct {
    session_id: []const u8,
    variant: []const u8,
    text: ?[]const u8,
};

/// Read one `session/update` notification's members out of the peer's bytes.
///
/// One reader for the whole walk, nested containers included, so the escape
/// offset is never rewound: two strings read out of one document cannot alias
/// each other in `scratch`, which is the hazard `acp_session.readOutcome`
/// refuses two shared scratch regions over.
fn readUpdate(raw: []const u8, scratch: []u8) proto.DecodeError!Update {
    var reader = json.Reader.init(raw);
    var session_id: ?[]const u8 = null;
    // The flag rather than `text.* != null`: a `content` the agent sent with
    // no text in it is still the `content` that was sent, and letting a second
    // one in would let a peer choose which of its own members this run reads.
    var saw_update = false;
    var variant: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    if (!try reader.beginObject()) {
        while (try reader.nextKey(scratch)) |key| {
            if (session_id == null and std.mem.eql(u8, key, "sessionId")) {
                session_id = try reader.string(scratch);
                continue;
            }
            if (!saw_update and std.mem.eql(u8, key, "update")) {
                saw_update = true;
                try readUpdateBody(&reader, scratch, &variant, &text);
                continue;
            }
            try reader.skipValue(scratch);
        }
    }
    if (!reader.atEnd()) return error.MalformedJson;
    const found = session_id orelse return error.MissingField;
    return .{ .session_id = found, .variant = variant orelse "", .text = text };
}

/// The `update` object, read on the reader the notification is being read with.
///
/// Its own object walk rather than a second `json.Reader` over a lexeme cut out
/// of the first: a fresh reader starts its escape offset at zero again, and a
/// notification whose text carried an escape would then write it over the
/// session id the same buffer already handed out.
fn readUpdateBody(
    reader: *json.Reader,
    scratch: []u8,
    variant: *?[]const u8,
    text: *?[]const u8,
) proto.DecodeError!void {
    if (try reader.beginObject()) return error.MalformedJson;
    var saw_content = false;
    while (try reader.nextKey(scratch)) |key| {
        if (variant.* == null and std.mem.eql(u8, key, "sessionUpdate")) {
            variant.* = try reader.string(scratch);
            continue;
        }
        if (!saw_content and std.mem.eql(u8, key, "content")) {
            saw_content = true;
            try readContentBody(reader, scratch, text);
            continue;
        }
        try reader.skipValue(scratch);
    }
}

/// The `content` object, which is where a message chunk keeps its text.
fn readContentBody(
    reader: *json.Reader,
    scratch: []u8,
    text: *?[]const u8,
) proto.DecodeError!void {
    if (try reader.beginObject()) return;
    var saw_text = false;
    while (try reader.nextKey(scratch)) |key| {
        if (!saw_text and std.mem.eql(u8, key, "text")) {
            saw_text = true;
            text.* = try reader.string(scratch);
            continue;
        }
        try reader.skipValue(scratch);
    }
}

/// Copy a decoded string out of a decode region into storage that outlives it.
///
/// The region is reused by the next decode, so a report field that borrowed
/// from it would say whatever the last decode left behind. Truncating rather
/// than refusing keeps a long peer string from turning a check into a failure:
/// every check below compares the whole decoded text, and only the report is
/// bounded.
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
    failLocked(report, message, text);
}

/// [`fail`] with the lock already held, for a caller that is inside a read it
/// cannot leave to take it.
fn failLocked(report: *Report, message: *[failure_capacity]u8, text: []const u8) void {
    // The first failure is the finding; a later one is a consequence of it.
    if (report.failure.len != 0) return;
    const copied = @min(text.len, message.len - 1);
    @memcpy(message[0..copied], text[0..copied]);
    message[copied] = 0;
    report.failure = message[0..copied];
}

fn printSummary(err: *Io.Writer, version: acp.WireVersion, report: *const Report) Io.Writer.Error!void {
    try err.print("zig-agent-protocols acp interop client (wire {d})\n", .{version.number()});
    if (report.failure.len != 0) {
        try err.print("  FAILED: {s}\n", .{report.failure});
        return;
    }
    // Past this point every step that fills a field checked it first, so the
    // values are known to be there rather than assumed to be.
    try err.print("  initialize: protocolVersion={d}, {d} advertised capabilities\n", .{
        report.negotiated_version,
        report.capability_count,
    });
    try err.print("  session/new: sessionId={s}\n", .{report.session_id});
    try err.print("  session/update: {d} notification(s) carrying back the text that went out\n", .{
        report.session_update_count,
    });
    try err.print("  session/request_permission: {d} request(s), {d} option(s), {d} of them granting\n", .{
        report.permission_request_count,
        report.permission_option_count,
        report.permission_granting_option_count,
    });
    for (namedOptions(report), 0..) |option, index| {
        if (index != 0) try err.print(", ", .{});
        try err.print("{s}", .{option});
    }
    try err.print("\n", .{});
    // The one thing this run exists to show: the outcome is a refusal, and it
    // is the refusal this client is able to produce rather than a choice it
    // declined to make.
    try err.print("  session/request_permission: answered with outcome {s}, grants={}\n", .{
        report.permission_answer,
        report.permission_grants,
    });
    // The member is named because the two versions do not have the same one,
    // and a summary that said `stopReason` over an empty field would be a
    // summary about a run that never happened.
    if (version == .stable) {
        try err.print("  session/prompt: stopReason={s}\n", .{report.stop_reason});
    } else {
        try err.print("  session/prompt: messageId={s}\n", .{report.prompt_message_id});
    }
    try err.print("  hung up: the connection is closed and the peer will see end of file\n", .{});
}

/// The option ids this run was offered, which is as many as the peer offered up
/// to what the report holds.
fn namedOptions(report: *const Report) []const []const u8 {
    return report.permission_options[0..@min(report.permission_option_count, report.permission_options.len)];
}

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
/// Every value the agent sent went through `json.Writer.string`, so a text
/// carrying a quote, a backslash or a control byte leaves here as a string
/// literal rather than as a member that ends early or bytes a reader on the
/// far side refuses. The buffer is sized from [`report_capacity`], which is the
/// whole report at the worst escaping an agent can produce; a buffer with no
/// room is `error.BufferTooSmall` with the prefix already written left as it
/// was, never a document cut short.
fn encodeReport(buffer: []u8, report: *const Report) proto.EncodeError![]const u8 {
    var text = json.Writer.init(buffer);
    try text.slice("{\"requested_version\":");
    try number(&text, report.requested_version);
    try text.slice(",\"negotiated_version\":");
    try number(&text, report.negotiated_version);
    try text.slice(",\"agent_auth_methods\":");
    try boolean(&text, report.agent_auth_methods);
    try text.slice(",\"agent_capability_count\":");
    try number(&text, report.capability_count);
    try text.slice(",\"agent_capabilities\":[");
    for (namedCapabilities(report), 0..) |capability_path, index| {
        if (index != 0) try text.byte(',');
        try text.string(capability_path);
    }
    try text.slice("],\"session_id\":");
    try text.string(report.session_id);
    try text.slice(",\"session_update_count\":");
    try number(&text, report.session_update_count);
    try text.slice(",\"session_update_variant\":");
    try text.string(report.session_update_variant);
    try text.slice(",\"echoed_text\":");
    try text.string(report.echoed_text);
    try text.slice(",\"permission_request_count\":");
    try number(&text, report.permission_request_count);
    try text.slice(",\"permission_option_count\":");
    try number(&text, report.permission_option_count);
    try text.slice(",\"permission_granting_option_count\":");
    try number(&text, report.permission_granting_option_count);
    try text.slice(",\"permission_options\":[");
    for (namedOptions(report), 0..) |option, index| {
        if (index != 0) try text.byte(',');
        try text.string(option);
    }
    try text.slice("],\"permission_answer\":");
    try text.string(report.permission_answer);
    try text.slice(",\"permission_grants\":");
    try boolean(&text, report.permission_grants);
    try text.slice(",\"stop_reason\":");
    try text.string(report.stop_reason);
    try text.slice(",\"prompt_message_id\":");
    try text.string(report.prompt_message_id);
    try text.slice(",\"failure\":");
    try text.string(report.failure);
    try text.slice(",\"ok\":");
    try boolean(&text, report.ok);
    try text.byte('}');

    return text.written();
}

/// The capability paths this run was advertised, as many as the agent offered
/// up to what the report holds.
fn namedCapabilities(report: *const Report) []const []const u8 {
    return report.capabilities[0..@min(report.capability_count, report.capabilities.len)];
}

fn number(text: *json.Writer, value: anytype) !void {
    var buffer: [24]u8 = undefined;
    const written = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.BufferTooSmall;
    try text.slice(written);
}

fn boolean(text: *json.Writer, value: bool) !void {
    try text.slice(if (value) "true" else "false");
}

const usage =
    "usage: zig-agent-protocols-acp-interop [--protocol-version <1|2>] [--report-file <path>]\n" ++
    "\n" ++
    "  --protocol-version <n>  the ACP wire version to ask for in initialize.\n" ++
    "                          1 is the stable version and the default; 2 is the\n" ++
    "                          draft, asked for only when it is named here.\n" ++
    "  --report-file <path>    where the machine-readable findings are written.\n";

/// Read the words, or the fault that refuses them.
///
/// The faults it reports are its own error set rather than strings, so the
/// caller reads them by name and the phrase a reader sees is decided in one
/// place. Nothing here reaches the connection and nothing is written to
/// standard output, so a line this refuses leaves nothing behind but the
/// refusal itself.
fn parseArgs(init: std.process.Init) !Options {
    var options: Options = .{};
    var it = std.process.Args.iterate(init.minimal.args);
    _ = it.skip();
    while (it.next()) |argument| {
        const flag: []const u8 = argument;
        if (std.mem.eql(u8, flag, "--protocol-version")) {
            const value = it.next() orelse return error.MissingValue;
            options.protocol_version = std.fmt.parseInt(u16, value, 10) catch
                return error.NotANumber;
        } else if (std.mem.eql(u8, flag, "--report-file")) {
            options.report_file = it.next() orelse return error.MissingValue;
        } else {
            // A flag this program does not take is refused rather than ignored:
            // a supervisor that misspelled one would otherwise watch a run
            // prove something other than what it asked for.
            return error.UnknownFlag;
        }
    }
    return options;
}

/// Print a CLI refusal and exit 2; propagate a failed diagnostic write.
fn refuse(io: Io, phrase: []const u8) !noreturn {
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.print("zig-agent-protocols-acp-interop: {s}\n", .{phrase});
    try stderr.interface.print("{s}", .{usage});
    try stderr.flush();
    std.process.exit(2);
}

// --- storage --------------------------------------------------------------------
//
// Every buffer this file needs is at file scope, because the tasks borrow
// pointers to it and those pointers have to outlive the group, and because the
// regions handed to one call must share no byte with the regions handed to
// another. The decoders' scratch is one region used one at a time: a decoded
// result is read before the next one is decoded, so no two borrows out of it
// are live at once.

var buffers: stdio.Buffers = .{};

/// Scratch for the `session/new` and `session/prompt` readers below.
var client_scratch: [4096]u8 = undefined;

/// Scratch for the reader task's `session/update` walk. Its own region and not
/// `client_scratch` or the connection's decode scratch: three readers run in
/// this process over three different documents, and one region shared between
/// two of them is the escape-offset aliasing the library refuses in two places.
var update_scratch: [4096]u8 = undefined;

/// Scratch for `acp.decodePermissionRequest`. Separate from the connection's
/// decode scratch for the same reason `acp_session.readOutcome` insists on two
/// of its own: the option ids an answer is checked against are borrowed from
/// here, and an id written over itself is a grant nobody made.
var permission_scratch: [4096]u8 = undefined;

/// The two regions `Client.initialize` needs beyond the caller's four: the
/// params it composes and the scratch it unescapes the answer's keys into.
/// Neither is borrowed from `buffers`, because `initialize` refuses a region
/// shared with one of the four.
var handshake_params: [4096]u8 = undefined;
var handshake_scratch: [4096]u8 = undefined;

/// The `session/prompt` params, composed from the peer's own session id.
var prompt_params: [4096]u8 = undefined;

/// Where the agent's advertised capability paths are built and recorded. The
/// paths borrow `capability_paths`, so the session's gate keeps working after
/// the result region the answer arrived in is reused by the next call.
var capabilities: [32]acp.Capability = undefined;
var capability_paths: [1024]u8 = undefined;
var capability_scratch: [1024]u8 = undefined;

/// The path list handed to `acp.advertisedPaths`, sized larger than the
/// report's sixteen slots on purpose: a peer advertising more than the report
/// holds is then named by the run, where one array sized to the report would
/// make the same peer a capacity failure instead — and a capacity failure is
/// the caller's own sizing mistake, which is not what a peer that advertises
/// more than expected is. Only a peer above twenty-four is a decode failure,
/// and that one is real.
var advertised_capabilities: [24][]const u8 = undefined;

/// Where `acp.decodePermissionRequest` fills one entry per option the peer
/// offered. Ten against the report's eight, for the same reason: an offer of
/// nine is a finding the run names, and only an offer above ten is a decode
/// fault.
var permission_options: [10]acp.PermissionOption = undefined;

// --- the reads this participant has to answer for itself -----------------------
//
// Two, and both for the same reason: each consumes a member out of a document
// the library models no type for, so each is this file's own view of it rather
// than a check of a second decoder. Everything else the exchange touches goes
// through `acp` or `acp_session` and is proved by the real capture instead — a
// test calling those helpers directly would be a copy of the library's own
// tests and would say nothing about this program.

test "the prompt params escape a session id the peer chose" {
    var out: [256]u8 = undefined;
    var scratch: [64]u8 = undefined;
    // Peer-controlled quotes, frame delimiters and other control bytes must
    // survive the params as one JSON string, not become a key or a new frame.
    const session_id = "a\"b\nc\x01d\\e";
    const params = try composePrompt(&out, session_id);
    const raw_id = json.memberText(params, "sessionId", &scratch) orelse
        return error.TestUnexpectedResult;
    var reader = json.Reader.init(raw_id);
    try testing.expectEqualStrings(session_id, try reader.string(&scratch));
}

test "session/update: the text is read out of the agent's own bytes" {
    // The notification the SDK's `AgentSideConnection.session_update` writes
    // for an `AgentMessageChunk` carrying one text block.
    const raw =
        "{\"sessionId\":\"s-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\"," ++
        "\"content\":{\"type\":\"text\",\"text\":\"zig-agent-protocols\"}}}";
    var scratch: [512]u8 = undefined;
    const update = try readUpdate(raw, &scratch);
    try testing.expectEqualStrings("s-1", update.session_id);
    try testing.expectEqualStrings("agent_message_chunk", update.variant);
    try testing.expectEqualStrings(prompt_text, update.text.?);

    // An escaped text member is decoded, so a peer that spells the text with
    // escapes is still read as the text it sent.
    const escaped = try readUpdate(
        "{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\"," ++
            "\"content\":{\"type\":\"text\",\"text\":\"a\\u0062c\"}}}",
        &scratch,
    );
    try testing.expectEqualStrings("abc", escaped.text.?);

    // A variant this run does not compare is named rather than refused, and it
    // carries no text, so the comparison the run makes is skipped for it rather
    // than failed on it.
    const other = try readUpdate(
        "{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"tool_call\"," ++
            "\"toolCallId\":\"t-1\"}}",
        &scratch,
    );
    try testing.expectEqualStrings("tool_call", other.variant);
    try testing.expect(other.text == null);

    // A repeated member resolves first-wins at every level, and a repeat is
    // consumed rather than read: the same rule the library's own decoders
    // apply, because a peer that spells a member twice must not choose which
    // occurrence this run acts on.
    const repeated_update = try readUpdate(
        "{\"sessionId\":\"first\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\"," ++
            "\"content\":{\"text\":\"one\"}}," ++
            "\"update\":{\"sessionUpdate\":\"tool_call\",\"content\":{\"text\":\"two\"}}}",
        &scratch,
    );
    try testing.expectEqualStrings("first", repeated_update.session_id);
    try testing.expectEqualStrings("agent_message_chunk", repeated_update.variant);
    try testing.expectEqualStrings("one", repeated_update.text.?);
    const repeated_content = try readUpdate(
        "{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\"," ++
            "\"content\":{},\"content\":{\"text\":\"second\"}}}",
        &scratch,
    );
    try testing.expect(repeated_content.text == null);

    // A missing session, a notification that is not an object, an update that is
    // not an object and bytes after the closing brace are each refused.
    try testing.expectError(
        error.MissingField,
        readUpdate("{\"update\":{\"sessionUpdate\":\"agent_message_chunk\"}}", &scratch),
    );
    try testing.expectError(error.MalformedJson, readUpdate("[]", &scratch));
    try testing.expectError(error.MalformedJson, readUpdate("{\"sessionId\":\"s\",\"update\":7}", &scratch));
    try testing.expectError(
        error.MalformedJson,
        readUpdate("{\"sessionId\":\"s\",\"update\":{\"sessionUpdate\":\"x\"}} {}", &scratch),
    );
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
    // the wire, and every count at the most a peer can be credited with. A
    // session id, an echoed prompt, a capability path or an option id carrying
    // control bytes is a thing an agent can send, and the report is the only
    // account of what it said: a run that was complete and could not say so
    // failed for having been complete.

    const fillWorst = struct {
        fn fill(storage: []u8) []const u8 {
            @memset(storage, 0x01);
            return storage;
        }
    }.fill;

    var report: Report = .{ .io = testing.io };
    for (report.capabilities, 0..) |_, index| {
        report.capabilities[index] = fillWorst(&report.capability_store[index]);
    }
    report.capability_count = report.capabilities.len;
    report.session_id = fillWorst(&report.session_store);
    report.session_update_count = std.math.maxInt(usize);
    report.echoed_text = fillWorst(&report.echo_store);
    report.session_update_variant = fillWorst(&report.update_variant_store);
    report.permission_request_count = std.math.maxInt(usize);
    for (report.permission_options, 0..) |_, index| {
        report.permission_options[index] = fillWorst(&report.option_store[index]);
    }
    report.permission_option_count = report.permission_options.len;
    report.permission_granting_option_count = report.permission_options.len;
    report.permission_answer = fillWorst(&report.answer_store);
    report.stop_reason = fillWorst(&report.stop_store);
    report.prompt_message_id = fillWorst(&report.message_store);
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

    // Six bytes on the wire for every byte the agent sent, and one string back
    // to the reader: the escaping is what makes the wide report the same
    // account of the run as a narrow one.
    const session = json.memberText(document, "session_id", &scratch) orelse
        return error.TestUnexpectedResult;
    var session_reader = json.Reader.init(session);
    var decoded: [256]u8 = undefined;
    var expected: [128]u8 = undefined;
    try testing.expectEqualStrings(fillWorst(&expected), try session_reader.string(&decoded));

    // A buffer that cannot hold the whole report is refused rather than cut
    // short: half a document is one no reader can parse, and the supervisor
    // would read it as a report about a run that never happened.
    var narrow: [64]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, encodeReport(&narrow, &report));
}
