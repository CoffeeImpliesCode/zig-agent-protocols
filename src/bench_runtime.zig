//! Runtime benchmark — a `conn.Conn` round trip and an HTTP first valid event.
//!
//! Two measured workloads, one module, and one frozen entry point:
//! `pub fn run(io, out, iterations, samples) !void`. The caller owns the `Io`
//! and the writer, so the executor, the clock and the sink all belong to
//! whoever runs the benchmark rather than to this module; nothing here builds a
//! `std.Io.Threaded` of its own.
//!
//! ## What is timed, to the nanosecond
//!
//! - **Round trip.** `t0` is read on the task that is about to call, directly
//!   before `conn.Conn.call`; `t1` is read directly after it returns. The
//!   encoded request and the decoded answer are the caller's own buffers, so
//!   nothing between the two reads is setup: the interval is one request
//!   written and one answer matched by id, over a real TCP loopback socket
//!   with a real peer task reading it. The verification of the answer happens
//!   after `t1`, because a benchmark that timed its own correctness check
//!   would report the check.
//! - **First event.** `t0` is read before `http.Client.post` writes the POST
//!   and `t1` after the first event whose bytes decode as a JSON-RPC message
//!   has been read off the socket. The TCP connect is measured separately and
//!   reported separately, so it is outside this boundary; the id and result
//!   comparison happen after `t1`. The boundary is therefore time to first
//!   *valid* event and never the end of the reply, which for
//!   `subscriptions/listen` does not come: the peer sends the answer, keeps
//!   the body open, and only ends it once this client says it has the event.
//!   That is the flush proof — a peer that buffered the event would leave the
//!   reader waiting, and the reader waits only under the wall budget below.
//!
//! `Timestamp.durationTo` reads `from.durationTo(to) == to - from`, so every
//! interval below is `start.durationTo(end)` and never the other way round.
//!
//! ## The requests are real MCP requests
//!
//! Both workloads drive methods this revision defines, with the params and the
//! result the specification fixes for them. Nothing is bypassed: the HTTP
//! reply arrives through `http.checkPost`, which refuses a request whose
//! `Mcp-Method` disagrees with the body, whose `MCP-Protocol-Version` header
//! disagrees with `params._meta`, or whose body carries no revision claim at
//! all. The parameters below satisfy every one of those rules, so a run that
//! reached the oracle went through the same checks a real endpoint applies.
//!
//! | Workload | Method | `params` | Result |
//! |---|---|---|---|
//! | round trip | `tools/call` | `_meta` revision, `name`, `arguments` | `CallToolResult` |
//! | first event | `subscriptions/listen` | `_meta` revision | `SubscriptionsListenResult` |
//!
//! The `subscriptions/listen` result is the interesting one: PROTOCOLS.md 4.10.3
//! makes its `_meta` the one place a result's `_meta` is required, and
//! `io.modelcontextprotocol/subscriptionId` must equal this response's own
//! `id`. The oracle compares that byte for byte, so a result carrying another
//! call's id is a different result even though it is the same shape.
//!
//! ## Warm-up, windows and the closed loop
//!
//! `warmup_ops` operations run first and are discarded: they pay the first
//! page faults, the first frame-buffer fills and the frequency ramp, and no
//! window contains them. `samples` timed windows then run, `iterations`
//! operations each, and the statistics are computed across the windows. The
//! first window is reported on its own beside the median, so drift between a
//! cold-ish window and the rest is visible instead of averaged away.
//!
//! One operation is in flight at a time: the caller waits for each answer
//! before sending the next request. The distribution recorded is therefore
//! *service* completion latency under a closed loop, and a stall of the caller
//! would not be seen as a longer sample. No coordinated-omission correction is
//! applied, because there is no open-loop arrival process to correct against,
//! and the caveat is printed in the report rather than buried here.
//!
//! ## The correctness oracle
//!
//! The correctness oracle runs before any number is reported, and a run whose
//! oracle failed reports the failure instead of the number:
//!
//! - A JSON-RPC refusal is not a result. `Response.failed()` and
//!   `Message.rpc_error` are read before the body, so a peer error is a
//!   failure here and never a fast sample.
//! - The answer's bytes are compared against the exact result member the peer
//!   owes, and the first SSE message's id against the id this client sent. A
//!   wrong result, a wrong id and a stale event are three distinct failures.
//! - An operation that raced the teardown is reported (`PeerEnded`,
//!   `StreamEndedBeforeEvent`), not counted: it is never added to a window.
//! - A response that named no outstanding call is a peer answering an id
//!   nobody asked for, and it is detected on the connection's own orphan hook
//!   rather than by waiting for a timeout.
//! - Every peer is used through the teardown discipline `runtime_demo.zig`
//!   uses: `shutdown` before `close`, and the side's *owner* releases the
//!   descriptor, once every task that can touch it has been joined. Never the
//!   reader: a connection is read by the pump and written by whichever
//!   caller is inside `Conn.call`, and those are different tasks, so a
//!   reader that closed it on its way out took it away from a write that was
//!   still pending. `ConnSide.releases` counts the releases and the tests
//!   assert it is exactly one per side, on the success path and on every
//!   failure path, which is the no-use-after-close check.
//!
//! ## Bounds
//!
//! Every array here is fixed: `max_samples` windows, `max_skippable_events`
//! skipped events before the client gives up, `max_measured_ops` for the whole
//! run. Nothing grows with what the caller asks for. The HTTP client takes
//! `std.http`'s own allocator, and it is a fixed buffer reset at the top of
//! every operation, so the one allocator in this module cannot grow either;
//! the codec path takes none. `wall_budget_ns` bounds the whole measured
//! workload: a peer that never flushes and a peer that never answers are one
//! failure, `WallBudgetExceeded`, and the tasks are cancelled rather than
//! waited on. Cancellation reaches everything the workload owns — its `Io.Group`
//! holds both peers and both pumps, and the group's await waits for every task
//! in it — so a cancelled run leaves no task and no descriptor behind.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zig-agent-proto");

const Io = std.Io;
/// The standard library's HTTP client sits under this library's transport, so
/// both names are in scope: `http` is MCP and `wire` is `std.http`.
const wire = std.http;

const conn = proto.conn;
const http = proto.http;
const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;

/// The clock every timestamp here comes from.
///
/// `awake` is `CLOCK_MONOTONIC` on Linux: consecutive reads never go backwards,
/// so every subtraction below is a duration and not an accident.
pub const clock: Io.Clock = .awake;

const ns_per_s: i96 = 1_000_000_000;

/// Windows one run may ask for, and the fixed array that holds them.
pub const max_samples = 64;

/// Operations one window may ask for.
pub const max_iterations = 1_000_000;

/// Operations the whole measured run may ask for.
///
/// The same bound the driver applies, enforced again here because
/// `iterations * samples` is the one product a caller can get wrong without
/// noticing: it is walked one operation at a time on a socket.
pub const max_measured_ops = 10_000;

/// Operations run and thrown away before the first window opens.
///
/// The peer cannot tell a warm-up operation from a timed one, so the counters
/// it keeps cover both; the counters the client keeps cover the timed windows
/// only, and the report says which is which.
pub const warmup_ops: u32 = 16;

/// Wall time the whole measured workload may take.
///
/// A bound rather than a target: the run is cancelled at this deadline and
/// reports `WallBudgetExceeded`, so a peer that never flushes an event cannot
/// leave this module reading a socket that will never speak.
pub const wall_budget_ns: i96 = 120 * ns_per_s;

/// Events the client steps over before it gives up on finding the answer.
pub const max_skippable_events = 8;

/// The revision every request here declares, in both places the specification
/// requires: the `MCP-Protocol-Version` header and `params._meta`.
///
/// A literal rather than a call to `Revision.string`, so the request bodies are
/// compile-time constants and no input is generated inside a timed region.
pub const protocol_version = "2026-07-28";

comptime {
    if (!std.mem.eql(u8, protocol_version, mcp.latest_protocol_version)) {
        @compileError(
            "the benchmark declares a protocol revision this library does not implement",
        );
    }
}

/// The method the round-trip workload calls.
///
/// `tools/call` names one entity, so on the HTTP transport it would owe an
/// `Mcp-Name` header; the connection transport has no headers at all and the
/// name travels in `params.name`, which is where PROTOCOLS.md 4.2 puts it.
pub const conn_method = "tools/call";

/// The `params` the round-trip workload sends.
///
/// `_meta` first because PROTOCOLS.md 4.3 puts the revision claim on every
/// request, then the tool name and its arguments.
pub const conn_params =
    "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"" ++
    protocol_version ++
    "\"},\"name\":\"bench_echo\",\"arguments\":{\"text\":\"bench\"}}";

/// The method the first-event workload calls.
///
/// PROTOCOLS.md 4.4 makes it the one long-lived response stream, which is why
/// its reply is the one this benchmark leaves open: a body that ended by
/// itself would be a reply no client could still be reading events from.
pub const http_method = "subscriptions/listen";

/// The `params` the first-event workload sends. Section 4.2 requires no
/// `Mcp-Name` for this method, and 4.3 requires the revision claim.
pub const http_params =
    "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"" ++
    protocol_version ++
    "\"}}";

/// The `CallToolResult` a `tools/call` peer owes, byte for byte.
///
/// The oracle compares against these bytes and not against a decoded shape:
/// a result that decodes to the right fields but arrived different is a
/// different result, and a comparison is what says so. `resultType` plus one
/// text content block and no `isError`, because a tool failure belongs in the
/// result and not in a JSON-RPC error.
const tool_call_result =
    "{\"resultType\":\"complete\"," ++
    "\"content\":[{\"type\":\"text\",\"text\":\"bench-runtime\"}]}";

/// The head of the `SubscriptionsListenResult`; the subscription id and two
/// closers follow it.
///
/// Assembled from pieces rather than from one format string so that no brace in
/// the JSON needs escaping, and the exact bytes are pinned by a test.
const listen_result_head =
    "{\"resultType\":\"complete\"," ++
    "\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":";

/// The result a peer with the `wrong_result` defect answers a `tools/call`
/// with instead: a well-formed `CallToolResult` carrying other text.
const wrong_tool_result =
    "{\"resultType\":\"complete\"," ++
    "\"content\":[{\"type\":\"text\",\"text\":\"bench-wrong\"}]}";

/// How far from the real id a defective envelope id or subscription id sits.
const wrong_id_offset: i64 = 1000;

/// The event a peer with the `peer_request` defect sends before its answer: a
/// request of its own, which PROTOCOLS.md 4.4 forbids a server from sending on
/// the client's reply stream. The id is far outside anything a run mints, so a
/// client that matched by prefix rather than by value would not find it.
const peer_request_event =
    "{\"jsonrpc\":\"2.0\",\"id\":999999," ++
    "\"method\":\"notifications/tools/list_changed\",\"params\":{}}";

/// The events a peer with the `preamble` defect sends before its answer.
///
/// The first is not a JSON-RPC message at all, so the client has to step over
/// it; the second is a real MCP notification, which is legal on this stream
/// and is still not the answer.
const preamble_padding = "not-json";
const preamble_notification =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}";

/// What this module reports.
///
/// One member per way an operation can fail to be a measurement. They are
/// separate because a caller reading only a number cannot tell a slow peer
/// from a broken one, and each of these is a different repair.
pub const Error = error{
    /// `iterations` is zero or above `max_iterations`.
    BadIterations,
    /// `samples` is zero or above `max_samples`.
    BadSamples,
    /// `iterations * samples` is above `max_measured_ops`.
    WorkTooLarge,
    /// The chosen executor could not assign a blocking task concurrency.
    ConcurrencyUnavailable,
    /// A socket would not listen, connect or accept.
    SocketFailed,
    /// The transport ended where an answer belonged.
    PeerEnded,
    /// The peer refused the call instead of answering it. A peer error is not
    /// a result, so this is never a sample.
    Refused,
    /// The result member is not the one the peer owes.
    WrongResult,
    /// A response named an id nobody asked for.
    WrongResponseId,
    /// A message that is not a response arrived where the answer belongs.
    NotAResponse,
    /// The peer sent a request of its own on the client's reply stream, which
    /// this revision forbids the server from doing.
    PeerRequest,
    /// The reply body ended before a valid event arrived.
    StreamEndedBeforeEvent,
    /// More messages than `max_skippable_events` arrived before a valid one.
    NoValidEvent,
    /// The wall budget expired; the run was cancelled and nothing it had
    /// measured is reported as a result.
    WallBudgetExceeded,
    /// A frame arrived that cannot be an answer at all.
    UnexpectedAnswer,
    /// This module's own buffers or wiring refused the work.
    HarnessFault,
};

/// Refuse a workload the fixed arrays cannot hold.
///
/// Called by [`run`] before it writes one byte, and by the harness itself
/// rather than only by the driver, because a test or a future caller reaches
/// the harness directly and the bound is a property of the storage here, not
/// of a command line.
pub fn checkArgs(iterations: u32, samples: u32) Error!void {
    if (iterations == 0 or iterations > max_iterations) return error.BadIterations;
    if (samples == 0 or samples > max_samples) return error.BadSamples;
    if (@as(u64, iterations) * samples > max_measured_ops) return error.WorkTooLarge;
}

// --- What the peer answers with ------------------------------------------------

/// The `CallToolResult` owed, assembled into `out`.
///
/// One function is both the oracle's expectation and the peer's answer: the
/// peer writes what it owes with it and the client compares what it received
/// against what it would write itself, so the two cannot drift and a
/// hand-copied expectation cannot sit in two places.
fn owedCallResult(out: []u8) Error![]const u8 {
    if (tool_call_result.len > out.len) return error.HarnessFault;
    @memcpy(out[0..tool_call_result.len], tool_call_result);
    return out[0..tool_call_result.len];
}

/// The `CallToolResult` a peer with the `wrong_result` defect owes instead.
///
/// A well-formed document of the same type and not a malformed one: a peer that
/// sent garbage would be caught as garbage, and the oracle would never be shown
/// a well-formed answer that is the wrong one.
fn defectiveCallResult(out: []u8) Error![]const u8 {
    if (wrong_tool_result.len > out.len) return error.HarnessFault;
    @memcpy(out[0..wrong_tool_result.len], wrong_tool_result);
    return out[0..wrong_tool_result.len];
}

/// The `SubscriptionsListenResult` owed for `id`, assembled into `out`.
///
/// The id is composed in a second buffer rather than through a formatter this
/// module does not otherwise use, and the two regions must not overlap.
fn owedListenResult(id: i64, out: []u8) Error![]const u8 {
    var digits: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{id}) catch return error.HarnessFault;
    var writer = json.Writer.init(out);
    writer.slice(listen_result_head) catch return error.HarnessFault;
    writer.slice(text) catch return error.HarnessFault;
    writer.slice("}}") catch return error.HarnessFault;
    return writer.written();
}

/// The result a peer with the `wrong_result` defect owes for `id`.
///
/// A result whose required `io.modelcontextprotocol/subscriptionId` belongs to
/// another call: the most specific wrong answer this method has, and one that
/// only a comparison against the id the client sent can catch.
fn defectiveListenResult(id: i64, out: []u8) Error![]const u8 {
    return owedListenResult(id + wrong_id_offset, out);
}

/// The peer half of an exchange: answers one method, or one of the defects.
///
/// The answer is composed by hand out of `json.Writer` slices rather than
/// through `conn.respond` alone, because `wrong_id` has to name an id the
/// request did not, and a builder that is always handed the request's id
/// cannot be asked for that.
const Echo = struct {
    /// Needed by a peer that has to be told to hang up mid-run.
    // SAFETY: both supervisors assign it before starting their group; only Echo.handle reads it.
    io: Io = undefined,
    /// Told when a `hang_up` peer has answered the one request it answers.
    handoff: ?*Handoff = null,
    /// The one method this peer answers. A request for anything else gets no
    /// answer, which is what a peer that serves one method looks like.
    method: []const u8 = "",
    defect: Defect = .none,
    /// Requests answered so far. Response defects affect only the first answer;
    /// a `hang_up` peer answers no later request while its owner shuts it down.
    answered: u32 = 0,
    /// Scratch for one envelope id at a time.
    // SAFETY: bufPrint writes exactly the prefix wrongIdAnswer returns; nothing else reads it.
    id_buffer: [24]u8 = undefined,
    /// Where the result member is composed before it is spliced into the
    /// answer envelope. A third region, because it may share no byte with
    /// either the decode scratch or the answer the caller handed in.
    // SAFETY: the owed and defective builders fill it and hand back only the prefix they wrote.
    result_buffer: [512]u8 = undefined,

    fn handle(
        ctx: ?*anyopaque,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) conn.Error!?[]const u8 {
        // The context is the peer this module registered: every call site
        // installs `.ctx = &self.echo` beside `Echo.handle`, and the connection
        // routes a frame only to the handler it was given. Nothing that arrived
        // on the socket chooses this pointer.
        // zwanzig-disable-next-line: optional-unwrap
        const self: *Echo = @ptrCast(@alignCast(ctx.?));
        const request = jsonrpc.decodeRequest(frame, decode_scratch) catch return null;
        const id = switch (request.id) {
            .integer => |value| value,
            // A string id is legal JSON-RPC and is not an id this benchmark
            // mints, so this peer does not claim to answer one.
            .string => return null,
        };
        if (!std.mem.eql(u8, request.method.text, self.method)) return null;
        // The owner can be scheduled after several more frames reach this
        // reader. Once shutdown is requested, none may become a measurement.
        if (self.defect == .hang_up and self.answered != 0) return null;
        const first = self.answered == 0;
        self.answered += 1;

        if (first) {
            switch (self.defect) {
                .wrong_id => return self.wrongIdAnswer(id, answer),
                .wrong_result => {
                    const payload = self.defective(id) catch return null;
                    return conn.respond(request, payload, answer) catch null;
                },
                .refuse => return conn.methodNotFound(request, answer) catch null,
                .hang_up => {
                    if (self.handoff) |handoff| handoff.requestHangUp(self.io);
                },
                else => {},
            }
        }
        const payload = self.owed(id) catch return null;
        return conn.respond(request, payload, answer) catch null;
    }

    /// The result this peer owes for `id`.
    fn owed(self: *Echo, id: i64) Error![]const u8 {
        if (std.mem.eql(u8, self.method, conn_method)) {
            return owedCallResult(&self.result_buffer);
        }
        if (std.mem.eql(u8, self.method, http_method)) {
            return owedListenResult(id, &self.result_buffer);
        }
        return error.HarnessFault;
    }

    /// The result this peer owes when it has the `wrong_result` defect.
    fn defective(self: *Echo, id: i64) Error![]const u8 {
        if (std.mem.eql(u8, self.method, conn_method)) {
            return defectiveCallResult(&self.result_buffer);
        }
        if (std.mem.eql(u8, self.method, http_method)) {
            return defectiveListenResult(id, &self.result_buffer);
        }
        return error.HarnessFault;
    }

    /// The answer whose id is one nobody asked for.
    ///
    /// The result is the one owed, so what this defect exercises is the id and
    /// nothing else: a peer that got both wrong would be caught by whichever
    /// check ran first, and this one has to be the id.
    fn wrongIdAnswer(self: *Echo, id: i64, answer: []u8) conn.Error!?[]const u8 {
        const text = std.fmt.bufPrint(&self.id_buffer, "{d}", .{id + wrong_id_offset}) catch
            return null;
        const payload = self.owed(id) catch return null;
        var writer = json.Writer.init(answer);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        writer.slice(text) catch return null;
        writer.slice(",\"result\":") catch return null;
        writer.slice(payload) catch return null;
        writer.byte('}') catch return null;
        return writer.written();
    }
};

/// How a benchmark peer departs from the answer it owes.
///
/// Each one is a real peer behaviour that the oracle has to catch, and each is
/// carried by the same handler so the defective answer travels the whole real
/// path — socket, framing, id match — rather than being handed to the oracle
/// directly.
pub const Defect = enum {
    /// The peer answers what it owes.
    none,
    /// The peer answers the first request with an id nobody asked for, and
    /// every request after it correctly.
    wrong_id,
    /// The peer answers the first request with a result that is not the one
    /// it owes.
    wrong_result,
    /// The peer refuses the first request with a JSON-RPC error.
    refuse,
    /// The peer puts a non-message and a notification in front of its answer.
    /// Only a stream peer can do this; a JSON-RPC envelope has nowhere to put
    /// them.
    preamble,
    /// The stream peer sends a request of its own before its answer.
    peer_request,
    /// The stream peer ends the reply without sending the answer at all, and
    /// the connection peer hangs up after answering one request.
    hang_up,
    /// The stream peer keeps the reply open and never sends an event: the
    /// reader waits, and only the wall budget ends the wait.
    silent,
};

// --- Fixed storage and the one allocator ---------------------------------------

/// One end of a framed connection: the buffers, the connection over them, and
/// who released the descriptor.
///
/// The same shape `runtime_demo.Side` uses, and for the same reason: the
/// reader and the writer of a connection are two different tasks, and only
/// one of them may close the descriptor. Here that one is this type's
/// owner, reached through [`RoundTrip.collect`], which releases after the
/// group join rather than from inside a reader or a writer.
///
/// What went wrong before is why ownership is tracked explicitly. The reader
/// was assumed to be the only task that touched the descriptor, so the
/// reader released it. It is not the only one: the caller's `Conn.call`
/// writes through the very same stream, and a caller that was between its
/// `writeFrame` and its answer wait when the reader noticed the peer's
/// hangup and released had its pending write land on a descriptor number
/// `close` had already returned. `Io.Threaded` answers `EBADF` there by
/// aborting the process rather than by returning an error, so a run that
/// should have reported `PeerEnded` died instead.
const ConnSide = struct {
    // SAFETY: open assigns it first, and hangUp and releaseSafe only run once open has returned.
    io: Io = undefined,
    buffers: proto.stdio.Buffers = .{},
    // SAFETY: handed to Stream.Reader.init as its storage; the reader reads back its own bytes.
    reader_buffer: [4096]u8 = undefined,
    // SAFETY: handed to Stream.Writer.init as its storage; the writer reads back its own bytes.
    writer_buffer: [4096]u8 = undefined,
    // SAFETY: conn.Conn.init assigns it before the pump task starts, and the pump starts after that.
    connection: conn.Conn = undefined,
    // SAFETY: open assigns the descriptor it was handed before either teardown path can run.
    stream: Io.net.Stream = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces.
    // SAFETY: Stream.Reader.init assigns it, and open hands that interface to conn.Conn.init.
    reader: Io.net.Stream.Reader = undefined,
    // SAFETY: Stream.Writer.init assigns it, and open hands that interface to conn.Conn.init.
    writer: Io.net.Stream.Writer = undefined,
    /// Whether this side owns a descriptor at all, which `open` decides.
    ///
    /// This is what makes releasing safe on a side that was never opened: a
    /// refused connect reaches the owner with nothing to release, and
    /// `stream` is `undefined` there. `releaseSafe` reads this flag and not
    /// the descriptor, so that path is not a read of undefined storage.
    owned: bool = false,
    /// Whether `open` built `connection`.
    ///
    /// Tracked apart from `owned` because the two are reached at different
    /// points: the descriptor is owned before `Conn.init`, which can refuse,
    /// and the connection only exists once it has returned. `hangUp` needs
    /// the first and the second separately.
    connected: bool = false,
    closed: bool = false,
    released: bool = false,
    /// How many times the descriptor was released. Must be one, and the
    /// tests say so: a second release closes whatever the process opened
    /// next, and a missing one leaks it.
    releases: u32 = 0,

    /// Build the connection over `stream` and start the task that reads it.
    ///
    /// The two hooks are installed here and not after, because a task spawned
    /// on the group may begin before `open` returns: `conn.Conn.setHandler`
    /// and `setOrphanHandler` are legal only before the reader runs, and this
    /// is the last place that is true.
    fn open(
        self: *ConnSide,
        io: Io,
        group: *Io.Group,
        stream: Io.net.Stream,
        handler: ?conn.Handler,
        orphan: ?conn.OrphanHandler,
    ) (conn.Error || Io.ConcurrentError)!void {
        self.io = io;
        self.stream = stream;
        self.owned = true;
        // Ownership is taken before `Conn.init`, which can refuse, so a
        // refusal still leaves a descriptor this side owns and the owner's
        // release accounts for it. That is the refused-open path: it has to
        // hang up and release exactly once, neither leak it nor close it
        // twice.
        //
        // `connected` is deliberately not set here. It is false until
        // `Conn.init` returns, and `hangUp` reads it before closing the
        // connection, because stopping a `Conn` that was never built would
        // write through undefined state.
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = try conn.Conn.init(
            io,
            &self.reader.interface,
            &self.writer.interface,
            self.buffers.config(),
        );
        self.connected = true;
        if (handler) |h| self.connection.setHandler(h);
        if (orphan) |h| self.connection.setOrphanHandler(h);
        try group.concurrent(io, ConnSide.pump, .{self});
    }

    /// Read until the connection is told to stop or the peer hangs up.
    ///
    /// This task does not release the stream. It is the task that reads it,
    /// and reading is not the only thing done to a descriptor: the caller
    /// writes the same one from a task of its own, and a reader that closed
    /// it would take it away from a write already in flight. The owner
    /// releases, after the join that covers both tasks.
    fn pump(self: *ConnSide) void {
        self.connection.pump();
    }

    /// Stop the reader and wake it, without closing anything.
    ///
    /// `shutdown` before any `close`, and no `close` here at all. Closing a
    /// descriptor does not interrupt a read already blocked on it, so the
    /// peer would sit on an open description and the group would never
    /// finish; but closing it also answers a writer that is still pending on
    /// it, with `EBADF` and a process abort rather than an error.
    /// `shutdown` wakes the blocked read with end of stream and leaves the
    /// descriptor usable, which is the whole of what this call needs.
    ///
    /// `connection.close` is what makes the loop stop rather than ask again:
    /// `conn.pump` treats a zero-byte read as "ask again", so a shutdown
    /// alone lets it come straight back to the same descriptor.
    ///
    /// Safe to call more than once, and safe on a side that was never opened,
    /// which is what the deferred call on the refused-connect path reaches.
    fn hangUp(self: *ConnSide) void {
        if (self.closed) return;
        self.closed = true;
        if (!self.owned) return;
        // Skipped when `Conn.init` refused: there is no connection to stop,
        // and stopping one that was never built would write through
        // undefined state. The shutdown below still runs, so a peer with
        // bytes still in flight is not left waiting on an open description.
        if (self.connected) self.connection.close();
        // Best effort, and only ever a wake-up: `close` above has already told
        // the pump to stop, and a shutdown that cannot be sent means the peer
        // is already gone, which is the case this runs in.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        self.stream.shutdown(self.io, .both) catch {};
    }

    /// Release the descriptor, once, from the owner.
    ///
    /// The name says what the guards are for. Every path that reaches here
    /// runs after the group join, so no reader and no writer can still be on
    /// this stream and the release is the last thing done to it. The `owned`
    /// guard is what makes it legal on a side that never held a descriptor —
    /// the refused-connect path, where `stream` is `undefined` — and the
    /// `released` guard is what keeps a second call from closing whatever the
    /// process opened next.
    fn releaseSafe(self: *ConnSide) void {
        if (!self.owned or self.released) return;
        self.released = true;
        self.releases += 1;
        // Best effort before the close, which releases the descriptor whether
        // or not the shutdown reached the peer: this is the last call this
        // task makes on the stream, and a shutdown that fails here means the
        // peer has already gone.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        self.stream.shutdown(self.io, .both) catch {};
        self.stream.close(self.io);
    }
};

/// The peer half of the HTTP workload: one connection at a time.
const HttpServerSide = struct {
    // SAFETY: open hands it to Stream.Reader.init, and the reader reads back only what it wrote.
    reader_buffer: [4096]u8 = undefined,
    // SAFETY: open hands it to Stream.Writer.init, and the writer reads back only what it wrote.
    writer_buffer: [4096]u8 = undefined,
    // SAFETY: open assigns it from Stream.Reader.init before http.Server.init borrows its interface.
    stream_reader: Io.net.Stream.Reader = undefined,
    // SAFETY: open assigns it from Stream.Writer.init before http.Server.init borrows its interface.
    stream_writer: Io.net.Stream.Writer = undefined,
    // SAFETY: http.Server.init borrows it and fills one entry per derived header it decoded.
    params: [8]http.ParamHeader = undefined,
    // SAFETY: borrowed by http.Server.init for base64 decoding, and read only as far as it wrote.
    head_scratch: [256]u8 = undefined,
    // SAFETY: borrowed by http.Server.init as the request body buffer, filled as the peer sends it.
    body: [4096]u8 = undefined,
    // SAFETY: borrowed by http.Server.init to decode the body; Post.name borrows only what it wrote.
    body_scratch: [1024]u8 = undefined,
    /// Where a handler decodes, and where it composes its answer. Two arrays,
    /// because `http.Server.init` proves they are different memory.
    // SAFETY: the handler decodes into it and returns slices of it; nothing reads it beforehand.
    decode_scratch: [1024]u8 = undefined,
    // SAFETY: the handler composes its answer here and returns a slice of what it wrote.
    answer: [1024]u8 = undefined,
    // SAFETY: std.http's own chunked-transfer scratch, written through by the body writer.
    transfer: [64]u8 = undefined,
    // SAFETY: one event's framing is composed here and written out of it before the next event.
    event: [4096]u8 = undefined,
    // SAFETY: the chunked body writer's own staging buffer; it must outlive the stream.
    stream_buffer: [4096]u8 = undefined,
    // SAFETY: open assigns it before any receive or respond runs, and those only run after open.
    server: http.Server = undefined,

    fn open(self: *HttpServerSide, io: Io, stream: Io.net.Stream) void {
        self.stream_reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.stream_writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.server = http.Server.init(
            &self.stream_reader.interface,
            &self.stream_writer.interface,
            .{
                .params = &self.params,
                .head_scratch = &self.head_scratch,
                .body = &self.body,
                .body_scratch = &self.body_scratch,
                .decode_scratch = &self.decode_scratch,
                .answer = &self.answer,
                .transfer = &self.transfer,
                .event = &self.event,
                .stream = &self.stream_buffer,
            },
        );
    }
};

/// The client half of the HTTP workload, and the one allocator in this module.
///
/// `std.http.Client` reaches for its allocator when it opens a connection
/// itself. This benchmark hands it a connection it already opened, so the
/// allocation is the pool node, the connection's own read and write buffers
/// and the host name, and it is bounded by a fixed arena that is reset at the
/// top of every operation. Nothing here grows with the number of samples.
const HttpClientSide = struct {
    // SAFETY: post fills it through requestHeaders and std.http keeps the slice for the exchange.
    head: [8]wire.Header = undefined,
    // SAFETY: std.http's chunked-transfer scratch for this post, written through by its writer.
    transfer: [64]u8 = undefined,
    /// The reply body, or one event of a stream.
    // SAFETY: nextMessage fills it before returning the slice it decoded, and never reads it first.
    out: [4096]u8 = undefined,
    /// Backs the decode of the reply.
    // SAFETY: jsonrpc.decode writes it and hands back slices of it; nothing reads it first.
    decode: [1024]u8 = undefined,
    // SAFETY: requestBody's json.Writer fills it and returns exactly the prefix it wrote.
    request_buffer: [512]u8 = undefined,
    // SAFETY: the fixed pool behind arena_state; it is read only through slices it handed out.
    arena: [64 * 1024]u8 = undefined,
    // SAFETY: init wires it to the arena above before oneOp can reset it or hand out from it.
    arena_state: std.heap.FixedBufferAllocator = undefined,
    // SAFETY: init assigns it, or drive reports HarnessFault and no operation ever runs.
    host: Io.net.HostName = undefined,
    // SAFETY: init parses it before the client is built; drive stops the run if the parse failed.
    uri: std.Uri = undefined,
    /// `Mcp-Method`, and nothing else: `subscriptions/listen` is not one of
    /// the three methods section 4.2 requires an `Mcp-Name` for, and the
    /// revision header and the two-type `Accept` are the transport's own.
    spec: http.PostHeaders = .{ .method = http_method },

    fn init(self: *HttpClientSide, endpoint: *const Endpoint) Error!void {
        self.arena_state = .init(&self.arena);
        self.host = Io.net.HostName.init("127.0.0.1") catch return error.HarnessFault;
        self.uri = std.Uri.parse(endpoint.uri_text) catch return error.HarnessFault;
    }

    /// Everything one operation allocated is dead by the time the next
    /// operation begins, so the arena rewinds rather than grows.
    fn beginOp(self: *HttpClientSide) void {
        self.arena_state.reset();
    }

    /// The POST body one first-event operation sends, composed before the
    /// clock starts.
    ///
    /// The id is written per operation so a stale event from an earlier
    /// exchange cannot be mistaken for this one's answer, and the document is
    /// assembled from pieces rather than from a format string so that no brace
    /// in the JSON needs escaping.
    fn requestBody(self: *HttpClientSide, id: i64) Error![]const u8 {
        var digits: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d}", .{id}) catch return error.HarnessFault;
        var writer = json.Writer.init(&self.request_buffer);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.HarnessFault;
        writer.slice(text) catch return error.HarnessFault;
        writer.slice(",\"method\":\"" ++ http_method ++ "\",\"params\":") catch
            return error.HarnessFault;
        writer.slice(http_params) catch return error.HarnessFault;
        writer.byte('}') catch return error.HarnessFault;
        return writer.written();
    }
};

/// The endpoint a workload listens on.
///
/// Port zero and the kernel's choice read back off the listening socket, so
/// two runs — and two tests — cannot collide over a port. A Unix domain socket
/// would remove even that, and `std.http.Client` cannot reach one.
const Endpoint = struct {
    // SAFETY: open assigns it before close or port can run; a failed listen never reaches them.
    listener: Io.net.Server = undefined,
    // SAFETY: open assigns it from the parsed address before any task reaches this endpoint.
    address: Io.net.IpAddress = undefined,
    // SAFETY: bufPrint fills it and uri_text is set to exactly the prefix it wrote.
    uri_buffer: [64]u8 = undefined,
    uri_text: []const u8 = "",

    fn open(self: *Endpoint, io: Io) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.listener = try address.listen(io, .{});
        self.address = try Io.net.IpAddress.parse("127.0.0.1", self.port());
        self.uri_text = try std.fmt.bufPrint(
            &self.uri_buffer,
            "http://127.0.0.1:{d}/mcp",
            .{self.port()},
        );
    }

    fn close(self: *Endpoint, io: Io) void {
        self.listener.deinit(io);
    }

    fn port(self: *const Endpoint) u16 {
        return self.listener.socket.address.getPort();
    }
};

/// What the two tasks of a workload tell each other.
///
/// A few flags and one condition carry the whole handshake, and the flags are
/// what the condition means, because a signal with no waiter yet is dropped: a
/// client that finishes first must still be seen by a peer that has not begun
/// to wait. Every wait here is a cancelation point, which is what lets the
/// wall budget end a run whose peer never flushes — and every wait says
/// whether it was woken, told the client is finished, or cancelled, so no
/// caller carries on into a blocking call that can no longer be ended.
const Handoff = struct {
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// The client is finished, successfully or not, and no further connection
    /// is coming. Read under `mutex`.
    client_done: bool = false,
    /// The client has connected and the kernel has the connection queued.
    connection_queued: bool = false,
    /// The client holds the first event of the reply it is being sent.
    event_observed: bool = false,
    /// A `hang_up` peer wants its own caller to hang up.
    hang_up_requested: bool = false,
    /// Why a wait ended.
    ///
    /// The reason is the caller's whole decision, and it is not detail: under
    /// `Io.Threaded` a task that has acknowledged a cancelation keeps that
    /// status for the rest of its execution and its later syscalls run with
    /// no cancelation check left. A task that continues into a blocking call
    /// after a `.cancelled` wait is therefore waiting for something that can
    /// no longer arrive, and only the reason tells it not to.
    const Wait = enum {
        /// What the waiter was waiting for arrived, and the flag is consumed.
        woken,
        /// The client is finished and the thing will never arrive.
        done,
        /// This task's own wait was cut short, so no later syscall of this
        /// task is a cancelation point again.
        cancelled,
    };

    fn signalDone(self: *Handoff, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.client_done = true;
        self.condition.signal(io);
    }

    fn announceConnection(self: *Handoff, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.connection_queued = true;
        self.condition.signal(io);
    }

    /// Block until there is a connection to accept, and say why it ended.
    fn waitConnection(self: *Handoff, io: Io) Wait {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.connection_queued and !self.client_done) {
            self.condition.wait(io, &self.mutex) catch return .cancelled;
        }
        if (!self.connection_queued) return .done;
        self.connection_queued = false;
        return .woken;
    }

    /// Tell the peer the first event is in hand and the body may end now.
    fn observeEvent(self: *Handoff, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.event_observed = true;
        self.condition.signal(io);
    }
    /// Wait for the client to say it holds the first event, and say why the
    /// wait ended.
    ///
    /// Read from the flag rather than from `client_done`: a client that
    /// signalled and then finished must still be counted as having observed,
    /// or the invariant this exists for would fail on a race it is meant to
    /// rule out.
    fn waitObserved(self: *Handoff, io: Io) Wait {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.event_observed and !self.client_done) {
            self.condition.wait(io, &self.mutex) catch return .cancelled;
        }
        if (!self.event_observed) return .done;
        self.event_observed = false;
        return .woken;
    }

    fn requestHangUp(self: *Handoff, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.hang_up_requested = true;
        self.condition.signal(io);
    }

    /// Wait for a `hang_up` peer to say it has answered its one request, and
    /// say why the wait ended.
    fn waitHangUp(self: *Handoff, io: Io) Wait {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.hang_up_requested and !self.client_done) {
            self.condition.wait(io, &self.mutex) catch return .cancelled;
        }
        if (!self.hang_up_requested) return .done;
        return .woken;
    }
};

// --- Samples and statistics ----------------------------------------------------

/// One timed window: what it cost and how many operations it held.
const Window = struct {
    ns: u64 = 0,
    ops: u32 = 0,
};

/// Every window of one workload, and the running extremes of its operations.
///
/// The windows are the samples; the per-operation minimum and maximum are kept
/// as they are recorded, because storing every operation would make the
/// storage grow with `iterations` and this module does not grow.
const Latencies = struct {
    // SAFETY: closeWindow writes index count, and count bounds every read and copy of the array.
    windows: [max_samples]Window = undefined,
    count: usize = 0,
    window_ns: u64 = 0,
    window_ops: u32 = 0,
    ops: u64 = 0,
    min_op_ns: u64 = std.math.maxInt(u64),
    max_op_ns: u64 = 0,

    fn record(self: *Latencies, op_ns: u64) void {
        self.window_ns += op_ns;
        self.window_ops += 1;
        self.ops += 1;
        if (op_ns < self.min_op_ns) self.min_op_ns = op_ns;
        if (op_ns > self.max_op_ns) self.max_op_ns = op_ns;
    }

    fn closeWindow(self: *Latencies) void {
        std.debug.assert(self.count < max_samples);
        self.windows[self.count] = .{ .ns = self.window_ns, .ops = self.window_ops };
        self.count += 1;
        self.window_ns = 0;
        self.window_ops = 0;
    }

    /// Forget everything, for a phase whose samples are not samples.
    fn reset(self: *Latencies) void {
        self.* = .{};
    }

    /// Fold the windows into the numbers a caller prints.
    ///
    /// The sort is over a fixed local copy, so asking twice gives the same
    /// answer and the window order — which is the order they were measured in
    /// — survives.
    fn stats(self: *const Latencies) Stats {
        var values: [max_samples]u64 = undefined;
        var total_ns: u64 = 0;
        for (self.windows[0..self.count], 0..) |window, index| {
            values[index] = window.ns / @as(u64, @max(window.ops, 1));
            total_ns += window.ns;
        }
        const windowed = values[0..self.count];
        const window_count = windowed.len;
        std.debug.assert(window_count > 0);
        const first = windowed[0];
        insertionSort(windowed);
        return .{
            .windows = self.count,
            .ops = self.ops,
            .total_ns = total_ns,
            .first_window_ns_per_op = first,
            .min_window_ns_per_op = windowed[0],
            .max_window_ns_per_op = windowed[window_count - 1],
            .median_ns_per_op = median(windowed),
            .p90_ns_per_op = nearestRank(windowed, 90, 100),
            .p99_ns_per_op = nearestRank(windowed, 99, 100),
            .min_op_ns = if (self.ops == 0) 0 else self.min_op_ns,
            .max_op_ns = if (self.ops == 0) 0 else self.max_op_ns,
        };
    }
};

/// The statistics of one workload, in whole nanoseconds per operation.
///
/// The central value and the tails are both reported because a mean hides a
/// tail and a tail is what a caller waiting on one answer feels. Which
/// percentile rule was used is [`nearestRank`].
const Stats = struct {
    /// Timed windows folded into this.
    windows: usize = 0,
    /// Operations those windows held.
    ops: u64 = 0,
    /// All of the measured time.
    total_ns: u64 = 0,
    /// The first window on its own, before the run settles.
    first_window_ns_per_op: u64 = 0,
    min_window_ns_per_op: u64 = 0,
    max_window_ns_per_op: u64 = 0,
    median_ns_per_op: u64 = 0,
    p90_ns_per_op: u64 = 0,
    p99_ns_per_op: u64 = 0,
    /// The fastest and slowest single operation seen anywhere in the run.
    min_op_ns: u64 = 0,
    max_op_ns: u64 = 0,

    /// The mean nanoseconds one operation cost over the whole measured time.
    ///
    /// This is what the unqualified `*_ns_per_op` key carries, because it is
    /// the mean that `opsPerSecond` is the reciprocal of: a report whose rate
    /// and per-operation figure were two different statistics would leave a
    /// caller to divide one by the other and get a third. The median and the
    /// percentiles are printed under their own names, and each `*_window=`
    /// line carries that one window's own average.
    fn meanNsPerOp(self: Stats) u64 {
        if (self.ops == 0) return 0;
        return self.total_ns / self.ops;
    }

    /// Operations per second over the whole measured time, truncated to a whole
    /// operation so the report carries no decimal to round differently twice.
    ///
    /// Exact integer arithmetic rather than a floating-point quotient, so the
    /// answer cannot land on either side of the mean printed beside it. `ops`
    /// is the timed count of one run, which `checkArgs` holds at or below
    /// `max_measured_ops`, so `ops * ns_per_s` is at most 10^13 and cannot
    /// overflow a `u64`.
    fn opsPerSecond(self: Stats) u64 {
        if (self.total_ns == 0) return 0;
        return (self.ops * @as(u64, ns_per_s)) / self.total_ns;
    }
};

/// The `numerator/denominator`-th percentile of a sorted array, by nearest
/// rank: the value at position `ceil(p * n)`, clamped into the array.
///
/// Stated here because every percentile rule gives a different number on a
/// small sample, and the one this module reports is this one.
pub fn nearestRank(sorted: []const u64, numerator: u64, denominator: u64) u64 {
    std.debug.assert(sorted.len > 0);
    std.debug.assert(denominator > 0);
    const n: u64 = sorted.len;
    const rank = (@as(u128, numerator) * n + denominator - 1) / denominator;
    const index = @min(@max(rank, 1), n) - 1;
    return sorted[@intCast(index)];
}

/// The middle of a sorted array: the middle value on an odd count, and the
/// mean of the two middle values — truncated to whole nanoseconds — on an
/// even one.
pub fn median(sorted: []const u64) u64 {
    const n = sorted.len;
    std.debug.assert(n > 0);
    if (n % 2 == 1) return sorted[n / 2];
    const lower = sorted[(n - 1) / 2];
    const upper = sorted[n / 2];
    return lower + (upper - lower) / 2;
}

fn insertionSort(values: []u64) void {
    var sorted: usize = 1;
    while (sorted < values.len) : (sorted += 1) {
        const value = values[sorted];
        var at = sorted;
        while (at > 0 and values[at - 1] > value) : (at -= 1) values[at] = values[at - 1];
        values[at] = value;
    }
}

// --- The bound every workload runs under ---------------------------------------

/// Run `Work.supervise` under a wall budget, and report which ended first.
///
/// This is the fail-cleanly contract in one function. The workload is one task
/// and the budget is another; whichever finishes first decides the outcome,
/// and the loser is cancelled — a socket read, a condition wait and a `sleep`
/// are all cancelation points here — rather than waited on. A peer that never
/// flushes its first event and a peer that never answers are therefore the same
/// bounded failure, and every fixed buffer the tasks hold is released by the
/// `defer`s that unwind.
///
/// Cancelling this select cancels the workload task, and a cancelation arriving
/// while that task waits on its own `Io.Group` waits for every task in the
/// group to finish unwinding — both peers and both pumps are in it. A deadline
/// therefore cannot leave a task behind, and cannot leave a descriptor behind
/// either: the supervisor's release runs after that join on every path out of
/// it, so it runs whether the workload finished first or was cancelled.
fn bounded(comptime Work: type, io: Io, self: *Work, budget_ns: i96) Work.Outcome {
    const Race = Io.Select(union(enum) {
        work: Work.Outcome,
        deadline: void,
    });
    var slots: [2]Race.Union = undefined;
    var race: Race = .init(io, &slots);
    defer race.cancelDiscard();
    race.concurrent(.work, Work.supervise, .{self}) catch |err|
        return @as(Work.Outcome, .{ .failure = err });
    race.concurrent(.deadline, sleepBudget, .{ io, budget_ns }) catch |err|
        return @as(Work.Outcome, .{ .failure = err });

    const first = race.await() catch {
        // Only reachable if the caller's own scope is cancelled underneath
        // `drive`, which nothing here does; reporting the budget rather than a
        // cancelation keeps a bounded failure bounded.
        return @as(Work.Outcome, .{ .failure = error.WallBudgetExceeded });
    };
    return switch (first) {
        .work => |outcome| outcome,
        .deadline => @as(Work.Outcome, .{ .failure = error.WallBudgetExceeded }),
    };
}

fn sleepBudget(io: Io, budget_ns: i96) void {
    // The only way this sleep can fail is a cancelation, and the only thing
    // that can cancel it is the select that started it — which has already
    // decided the outcome by the time the error arrives, and reads nothing
    // this task holds. There is nothing left to report it to.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    Io.sleep(io, .{ .nanoseconds = budget_ns }, clock) catch {};
}

// --- The round trip workload ---------------------------------------------------

/// `iterations` `conn.Conn` round trips per window, over one live connection.
///
/// One connection for the whole run: this measures a call, not a connect, and
/// a connection per operation would put the handshake inside a boundary that is
/// supposed to hold only the request and its answer.
const RoundTrip = struct {
    // SAFETY: drive assigns it before bounded starts, so both tasks and fail see the same Io.
    io: Io = undefined,
    group: Io.Group = .init,
    iterations: u32 = 1,
    samples: u32 = 1,
    budget_ns: i96 = wall_budget_ns,
    defect: Defect = .none,
    /// Serializes the choice of the first failure; see [`fail`].
    mutex: Io.Mutex = .init,

    endpoint: Endpoint = .{},
    handoff: Handoff = .{},
    client_side: ConnSide = .{},
    peer_side: ConnSide = .{},
    echo: Echo = .{},
    outcome: Outcome = .{},

    /// Responses that named no outstanding call, counted on the client's
    /// reader task and read by the client task, so the counter is atomic.
    orphans: std.atomic.Value(u32) = .init(0),

    const Outcome = struct {
        latencies: Latencies = .{},
        ops: u64 = 0,
        /// Requests the peer answered, warm-up operations included: the peer
        /// cannot tell them from timed ones.
        answered: u32 = 0,
        /// `ConnSide.releases` for each end. One each when teardown ran.
        client_releases: u32 = 0,
        peer_releases: u32 = 0,
        failure: ?Error = null,
    };

    /// The first failure wins.
    ///
    /// A teardown that follows a diagnosed failure fails too — the peer reads
    /// a closed socket — and the second failure would be the symptom rather
    /// than the cause. Two tasks report at once, so the choice is under this
    /// workload's own mutex: a bare read-then-write lets both see `null` and
    /// leaves whichever store landed last standing, which is exactly the
    /// symptom winning.
    fn fail(self: *RoundTrip, reason: Error) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.outcome.failure == null) self.outcome.failure = reason;
    }

    /// The failure that won, read under the same lock that writes it.
    fn failure(self: *RoundTrip) ?Error {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.outcome.failure;
    }

    /// The peer task: accept one connection and let its pump own it.
    fn runPeer(self: *RoundTrip) void {
        const io = self.io;
        // `accept` is reached only from a woken wait, and the reason is the
        // whole decision: a client whose connect failed is finished and will
        // never connect again, and a task whose wait was cancelled is no
        // longer cancelled at its next syscall. An `accept` after either would
        // wait for a client that has stopped, outlive the wall budget that is
        // supposed to end it, and report `WallBudgetExceeded` in place of the
        // `SocketFailed` the client already diagnosed.
        switch (self.handoff.waitConnection(io)) {
            .woken => {},
            .done, .cancelled => return,
        }
        const stream = self.endpoint.listener.accept(io) catch {
            self.fail(error.SocketFailed);
            self.handoff.signalDone(io);
            return;
        };
        self.peer_side.open(self.io, &self.group, stream, .{
            .ctx = &self.echo,
            .call = Echo.handle,
        }, null) catch |err| {
            self.peer_side.hangUp();
            self.fail(if (err == error.ConcurrencyUnavailable) error.ConcurrencyUnavailable else error.HarnessFault);
            self.handoff.signalDone(self.io);
            return;
        };
        // A peer that answers one request and then hangs up has to be told
        // when that request has been answered. The handler runs on the reader
        // task, and a reader may not close a descriptor any writer can still
        // be on, so it asks and this task hangs the side up instead.
        if (self.echo.defect == .hang_up) {
            // Whatever ended the wait, the connection is stopped and the
            // descriptor shut down so the pump's blocked read returns. The
            // close itself is `collect`'s, after the join.
            _ = self.handoff.waitHangUp(self.io);
            self.peer_side.hangUp();
        }
    }

    /// The client task: connect, warm up, then time the windows.
    fn runClient(self: *RoundTrip) void {
        const io = self.io;
        // On every path out of this task, and before the flag that lets the
        // peer stop waiting: the peer's pump sees the end of the stream the
        // hang-up below shuts down and returns on its own.
        defer self.handoff.signalDone(io);

        const stream = self.endpoint.address.connect(io, .{ .mode = .stream }) catch {
            self.fail(error.SocketFailed);
            return;
        };
        // Announced, not assumed: the peer waits for this before it waits in
        // `accept`, so the two ends cannot deadlock on a connection one of
        // them believes has already been queued. Nothing is announced when the
        // connect fails, and that is what the peer reads instead.
        self.handoff.announceConnection(io);

        // Declared after the connect, because a side that was never opened
        // owns no descriptor to stop. This stops the connection and wakes the
        // reader; the descriptor itself is `collect`'s to close, after the
        // join that covers this task's own writes to it.
        defer self.client_side.hangUp();
        self.client_side.open(io, &self.group, stream, null, .{
            .ctx = self,
            .call = RoundTrip.orphan,
        }) catch |err| {
            self.fail(if (err == error.ConcurrencyUnavailable) error.ConcurrencyUnavailable else error.HarnessFault);
            return;
        };

        var warm: u32 = 0;
        while (warm < warmup_ops) : (warm += 1) {
            _ = self.oneOp() catch |err| {
                self.fail(err);
                return;
            };
        }

        var window: u32 = 0;
        while (window < self.samples) : (window += 1) {
            var op: u32 = 0;
            while (op < self.iterations) : (op += 1) {
                const ns = self.oneOp() catch |err| {
                    self.fail(err);
                    return;
                };
                self.outcome.latencies.record(ns);
            }
            self.outcome.latencies.closeWindow();
        }
        self.outcome.ops = self.outcome.latencies.ops;
    }

    /// One call, timed from the write to the matched answer.
    fn oneOp(self: *RoundTrip) Error!u64 {
        const io = self.io;
        const start = clock.now(io);
        const response = self.client_side.connection.call(
            conn_method,
            conn_params,
            &self.client_side.buffers.result,
            &self.client_side.buffers.out,
        ) catch |err| {
            // A response nobody asked for is a diagnosis, and the closed
            // socket that follows it is the symptom.
            if (self.orphans.load(.acquire) != 0) return error.WrongResponseId;
            return switch (err) {
                // A fault of this module's own wiring, not of the peer.
                error.TooManyPending, error.UnusableBuffer, error.OverlappingBuffers => error.HarnessFault,
                error.Framing, error.ResponseTooLarge => error.UnexpectedAnswer,
                // Transport, ConnectionClosed, FrameTooLarge, Closed: the
                // peer, or this module's own teardown, ended the call.
                else => error.PeerEnded,
            };
        };
        const end = clock.now(io);

        // The clock has stopped. What follows is the oracle. The answer's own
        // id was matched by `Conn.call` before it returned, so there is no id
        // to check here: a frame naming a call nobody made never reaches this
        // function at all, and is counted on the connection's orphan hook.
        if (response.failed()) return error.Refused;
        if (self.orphans.load(.acquire) != 0) return error.WrongResponseId;
        var expected: [512]u8 = undefined;
        const owed = owedCallResult(&expected) catch return error.HarnessFault;
        if (!std.mem.eql(u8, response.body, owed)) return error.WrongResult;
        return @intCast(start.durationTo(end).nanoseconds);
    }

    /// A response named no outstanding call: the peer answered an id nobody
    /// asked for.
    ///
    /// The count is the diagnosis and it is taken here, on the reader task,
    /// because the call that is still waiting has no way to learn it: nothing
    /// will answer it. Closing the connection releases that caller, and the
    /// client reads the count before it reads the closed socket, so the cause
    /// is not reported as the symptom. `Conn.close` is legal from any task,
    /// and this one runs where the frame was routed.
    fn orphan(ctx: ?*anyopaque, message: jsonrpc.Message) void {
        // The context is the workload that installed the hook: `runClient`
        // registers `.ctx = self` and the connection only routes frames to the
        // handler it was given, so nothing that arrived on the socket can have
        // left it null by the time this runs.
        // zwanzig-disable-next-line: optional-unwrap
        const self: *RoundTrip = @ptrCast(@alignCast(ctx.?));
        if (message.kind != .response) return;
        _ = self.orphans.fetchAdd(1, .monotonic);
        self.client_side.connection.close();
    }

    // The task the wall budget races: both ends of the workload on one group.

    // Reached only as `Work.supervise` from `bounded`, whose `Work` is a
    // comptime type parameter. That reference resolves through the parameter,
    // so an unused-declaration analysis sees a member of a type it cannot name
    // and reports this function. It runs on every workload: `drive` returns
    // the outcome below, and every number the report prints is read out of it.
    // zwanzig-disable-next-line: unused-decl
    fn supervise(self: *RoundTrip) Outcome {
        const io = self.io;
        if (checkArgs(self.iterations, self.samples)) |_| {} else |err| {
            self.fail(err);
            return self.collect();
        }
        self.echo.io = io;
        self.echo.handoff = &self.handoff;
        self.echo.method = conn_method;
        self.echo.defect = self.defect;
        self.group.concurrent(io, RoundTrip.runPeer, .{self}) catch |err| {
            self.fail(err);
            self.group.cancel(io);
            return self.collect();
        };
        self.group.concurrent(io, RoundTrip.runClient, .{self}) catch |err| {
            self.fail(err);
            self.group.cancel(io);
            return self.collect();
        };
        // Await both peers and pumps; cancellation still drains the group.

        // `Group.await` blocks until every task in the group has finished and
        // reports a cancelation only once they have, so the join has happened
        // either way; the select that owns this task has already chosen the
        // outcome, and no failure below can be told from a cancelation.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        self.group.await(io) catch {};
        return self.collect();
    }

    /// Release both descriptors, then read the counters the report prints.
    ///
    /// This is the owner half of the teardown, and it is here rather than in
    /// a reader or a writer because neither of those is the last task on the
    /// stream. The pump is the task that reads it and the client task is the
    /// one that writes it; the pump returns the moment the peer hangs up,
    /// which can be while `Conn.call` is still between writing its request
    /// and waiting for the answer. Closing there took the descriptor out from
    /// under that write, and `EBADF` on a closed descriptor is a process
    /// abort rather than an error, so the run died instead of reporting the
    /// `PeerEnded` it had diagnosed.
    ///
    /// Every path through `supervise` ends here, so every path accounts for
    /// both descriptors exactly once: a side that was never opened owns
    /// nothing and is not released, and a side whose open was refused still
    /// does.
    ///
    /// The release comes before the copies on purpose. The counts are read
    /// after the release, so a release that did not happen shows up as a zero
    /// instead of being reported as one that did.
    fn collect(self: *RoundTrip) Outcome {
        self.client_side.releaseSafe();
        self.peer_side.releaseSafe();
        // Every task that could report a failure has been joined; the read
        // goes through the same lock the writes did, so no access to the
        // field in this workload skips that discipline.
        self.outcome.failure = self.failure();
        self.outcome.answered = self.echo.answered;
        self.outcome.client_releases = self.client_side.releases;
        self.outcome.peer_releases = self.peer_side.releases;
        return self.outcome;
    }

    fn drive(self: *RoundTrip, io: Io) Outcome {
        self.io = io;
        self.endpoint.open(io) catch {
            self.fail(error.SocketFailed);
            return self.outcome;
        };
        defer self.close(io);
        return bounded(RoundTrip, io, self, self.budget_ns);
    }

    /// Cancel whatever is left, then release the listening socket.
    ///
    /// The connected streams are not this call's business: `collect` owns
    /// them and released both after the join that covered every task on them,
    /// so by the time `drive` unwinds into here both are already closed. The
    /// cancel is what keeps a task `bounded` abandoned from still running
    /// against a listener this call is about to close.
    fn close(self: *RoundTrip, io: Io) void {
        self.group.cancel(io);
        self.endpoint.close(io);
    }
};

// --- The first-event workload --------------------------------------------------

/// `iterations` first-event waits per window, one connection each.
///
/// A connection per operation is forced rather than chosen: the reply is
/// deliberately left open until this client says it holds the event, so the
/// connection cannot carry a second request. The connect is measured and
/// reported on its own, outside the first-event boundary.
const FirstEvent = struct {
    // SAFETY: drive assigns it before bounded starts, so supervise, runPeer and runClient share it.
    io: Io = undefined,
    iterations: u32 = 1,
    samples: u32 = 1,
    budget_ns: i96 = wall_budget_ns,
    defect: Defect = .none,
    /// Serializes the choice of the first failure; see [`RoundTrip.fail`].
    mutex: Io.Mutex = .init,

    endpoint: Endpoint = .{},
    handoff: Handoff = .{},
    client_side: HttpClientSide = .{},
    server_side: HttpServerSide = .{},
    echo: Echo = .{},
    outcome: Outcome = .{},
    /// Exchanges this peer has served, warm-up ones included.
    served: u32 = 0,
    /// ids this client has sent and never reused.
    next_id: i64 = 1,

    const Outcome = struct {
        latencies: Latencies = .{},
        /// Timed connects only, reported beside the first-event boundary
        /// because a connect is not what that boundary is about.
        connect_latencies: Latencies = .{},
        ops: u64 = 0,
        /// Events the client stepped over because they were not the answer.
        /// Timed operations only.
        skipped: u64 = 0,
        /// Requests the peer answered, warm-up operations included.
        answered: u32 = 0,
        /// Exchanges where the client held the event before the body ended,
        /// warm-up exchanges included.
        observations: u32 = 0,
        failure: ?Error = null,
    };

    /// The first failure wins; see [`RoundTrip.fail`].
    fn fail(self: *FirstEvent, reason: Error) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.outcome.failure == null) self.outcome.failure = reason;
    }

    /// The failure that won, read under the same lock that writes it.
    fn failure(self: *FirstEvent) ?Error {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.outcome.failure;
    }

    fn peerLimit(self: *const FirstEvent) u32 {
        return warmup_ops + self.iterations * self.samples;
    }

    /// The peer task: one connection per exchange, and the body stays open.
    fn runPeer(self: *FirstEvent) void {
        const io = self.io;
        // A peer that dies on a fault of its own must not leave the client
        // waiting for a connection nobody will accept, so every exit here ends
        // the handshake. A client that is already finished reads the flag and
        // stops, which is where it would have stopped anyway.
        defer self.handoff.signalDone(io);
        while (self.served < self.peerLimit()) {
            switch (self.handoff.waitConnection(io)) {
                .woken => {},
                // Neither of these may be followed by `accept`. A client that
                // is finished will never connect again, and a cancelled task
                // is no longer cancelled at its next syscall, so an `accept`
                // after either would wait for a client that has stopped and
                // hang the run past its wall budget.
                .done, .cancelled => return,
            }
            const connection = self.endpoint.listener.accept(io) catch {
                self.fail(error.SocketFailed);
                return;
            };
            // `shutdown` before `close`: a close on a socket whose peer still
            // has unread bytes answers with a reset, and the reset discards the
            // event this workload exists to deliver.
            defer {
                // Nothing here can be reported: the accepted connection is torn down
                // on every path out of this loop body, the paths that failed have
                // already called fail, and the close below releases the descriptor
                // whether or not the shutdown reached a peer that has already gone.
                // gate-reviewed-zlint-next-statement: suppressed-errors
                connection.shutdown(io, .both) catch {};
                connection.close(io);
            }
            self.server_side.open(io, connection);
            const post = self.server_side.server.receive() catch {
                self.fail(error.SocketFailed);
                return;
            } orelse return;
            if (!self.serve(post)) return;
            self.served += 1;
        }
    }

    /// Answer one POST with a stream whose body stays open.
    fn serve(self: *FirstEvent, post: http.Post) bool {
        const io = self.io;
        const side = &self.server_side;
        var stream = side.server.respondStream(post) catch {
            self.fail(error.SocketFailed);
            return false;
        };
        // A stream peer that never sends the answer: the client has to see the
        // body end without a valid event, which is the negative half of the
        // first-event-before-end invariant.
        if (self.echo.defect == .hang_up) {
            // The close is what ends the body; if it cannot be sent the client
            // sees the same end when the `defer` in `runPeer` closes the
            // connection, and this return value is not a measurement.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            // ziglint-ignore: Z026
            // zwanzig-disable-next-line: empty-catch-engine
            stream.close() catch {};
            return true;
        }
        // A stream peer that holds the body open and never flushes an event:
        // the reader waits, and only the wall budget ends the wait. The peer
        // stops on anything but the client's own signal, because a client
        // that will not observe is a client that is not coming back.
        if (self.echo.defect == .silent) {
            return self.handoff.waitObserved(io) == .woken;
        }
        const reply = (Echo.handle(
            &self.echo,
            post.body,
            side.server.buffers.decode_scratch,
            side.server.buffers.answer,
        ) catch return false) orelse return false;

        const preamble: []const []const u8 = switch (self.echo.defect) {
            .preamble => &.{ preamble_padding, preamble_notification },
            .peer_request => &.{peer_request_event},
            else => &.{},
        };
        for (preamble) |event| {
            stream.send(side.server.buffers.event, event) catch {
                self.fail(error.SocketFailed);
                return false;
            };
        }
        stream.send(side.server.buffers.event, reply) catch {
            self.fail(error.SocketFailed);
            return false;
        };
        // The body stays open. `Stream.close` is not called here, and the
        // client has not observed the event yet, so the peer cannot end the
        // reply before the reader holds it: this wait is the invariant, not a
        // politeness.
        const observed = self.handoff.waitObserved(io) == .woken;
        if (observed) self.outcome.observations += 1;
        // Best effort: the exchange has already been observed, which is the
        // only thing this call decides for the report, and the connection is
        // closed by `runPeer` either way.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        stream.close() catch {};
        return observed;
    }

    /// The client task: one operation per connection, warm-up then windows.
    fn runClient(self: *FirstEvent) void {
        const io = self.io;
        defer self.handoff.signalDone(io);

        var warm: u32 = 0;
        while (warm < warmup_ops) : (warm += 1) {
            _ = self.oneOp() catch |err| {
                self.fail(err);
                return;
            };
        }
        // The warm-up operations are discarded whole: the skips they stepped
        // over and the connects they paid for are not samples, and the peer's
        // own counters cannot tell them apart, so the report states which is
        // which. The connect measurement is reset before the first window
        // opens, so what is reported beside the boundary is the connects of
        // the timed exchanges and nothing else.
        self.outcome.skipped = 0;
        self.outcome.connect_latencies.reset();

        var window: u32 = 0;
        while (window < self.samples) : (window += 1) {
            var op: u32 = 0;
            while (op < self.iterations) : (op += 1) {
                const ns = self.oneOp() catch |err| {
                    self.fail(err);
                    return;
                };
                self.outcome.latencies.record(ns);
            }
            self.outcome.latencies.closeWindow();
            // One connect window per exchange window: the connect is timed
            // inside the same operation the boundary covers, so its windows
            // have to close on the same edge or the two reports would be
            // folding different operations.
            self.outcome.connect_latencies.closeWindow();
        }
        self.outcome.ops = self.outcome.latencies.ops;
    }

    /// One first-event wait, timed from the POST to the first valid event.
    fn oneOp(self: *FirstEvent) Error!u64 {
        const io = self.io;
        const side = &self.client_side;
        side.beginOp();
        var wire_client: wire.Client = .{
            .allocator = side.arena_state.allocator(),
            .io = io,
        };
        defer wire_client.deinit();

        const connect_start = clock.now(io);
        const connection = wire_client.connectTcp(side.host, self.endpoint.port(), .plain) catch
            return error.SocketFailed;
        const connect_end = clock.now(io);
        // The connect is outside the first-event boundary and is reported
        // beside it rather than hidden inside it.
        self.outcome.connect_latencies.record(
            @intCast(connect_start.durationTo(connect_end).nanoseconds),
        );
        self.handoff.announceConnection(io);

        var client: http.Client = .init(&wire_client, side.uri, .current);
        client.connection = connection;

        // Input generation, before the clock: the id is new for every
        // operation, so an answer meant for an earlier exchange cannot pass
        // for this one's, and the revision claimed in `_meta` is the one the
        // transport puts in `MCP-Protocol-Version`, so the two cannot drift.
        const id = self.next_id;
        self.next_id += 1;
        const body = side.requestBody(id) catch return error.HarnessFault;
        // SAFETY: post assigns it or oneOp returns, and this is the only place
        // exchange is closed.
        var exchange: http.Exchange = undefined;
        const start = clock.now(io);
        client.post(&exchange, body, side.spec, &side.head, &side.transfer) catch
            return error.SocketFailed;
        // `shutdown` before `close`, and both from the task that used the
        // descriptor. `Request.deinit` releases this connection to `std.http`
        // and closes it outright when the reply was not read to its end —
        // which is every operation that stops before its event — and a `close`
        // on a socket whose peer still has bytes unread answers with a reset.
        // The reset does not only discard the peer's last bytes: it tears the
        // peer's connection down while the peer is still the task that owns
        // it, and a peer whose connection is gone has nothing left to shut
        // down. The peer's own shutdown is what `runPeer` owes the client
        // before it closes, so a client that closed without this one turned
        // the peer's mandatory teardown into the fault it cannot survive.
        //
        // Best effort, and it changes nothing that follows either way: the
        // exchange is closed on this path whatever the shutdown did, and a
        // shutdown that cannot be sent means the peer is already gone.
        // ziglint-ignore: Z026
        defer {
            // gate-reviewed-zlint-next-statement: suppressed-errors
            connection.stream_reader.stream.shutdown(io, .both) catch {};
            exchange.close();
        }

        var examined: u32 = 0;
        // SAFETY: the loop assigns it from decode before the switch reads its kind and members.
        var decoded: jsonrpc.Message = undefined;
        var answer_id: i64 = 0;
        while (true) {
            const raw = (exchange.nextMessage(&side.out) catch return error.SocketFailed) orelse
                return error.StreamEndedBeforeEvent;
            examined += 1;
            if (examined > max_skippable_events) return error.NoValidEvent;
            // An event that does not decode is not a message; the transport
            // says the client steps over those, and this is the step.
            decoded = jsonrpc.decode(raw, &side.decode) catch continue;
            switch (decoded.kind) {
                .notification => continue,
                .request => return error.PeerRequest,
                .response => {},
            }
            answer_id = switch (decoded.id orelse return error.NotAResponse) {
                .integer => |value| value,
                .string => return error.NotAResponse,
            };
            break;
        }
        const end = clock.now(io);

        // The clock has stopped. What follows is the oracle.
        if (answer_id != id) return error.WrongResponseId;
        if (decoded.rpc_error != null) return error.Refused;
        const result = decoded.result orelse return error.NotAResponse;
        var expected: [512]u8 = undefined;
        const owed = owedListenResult(id, &expected) catch return error.HarnessFault;
        if (!std.mem.eql(u8, result, owed)) return error.WrongResult;
        self.outcome.skipped += @as(u64, examined - 1);

        // Said only now, with the event in hand: until this moment the peer
        // has to keep the body open, and it structurally cannot end it before
        // this signal arrives.
        self.handoff.observeEvent(io);
        return @intCast(start.durationTo(end).nanoseconds);
    }

    // The task the wall budget races: both ends of the workload on one group.

    // Reached only as `Work.supervise` from `bounded`, whose `Work` is a
    // comptime type parameter, so the same reference resolves through a type
    // the analysis cannot name and this function is reported as unused. It
    // runs on every workload: `drive` returns the outcome below.
    // zwanzig-disable-next-line: unused-decl
    fn supervise(self: *FirstEvent) Outcome {
        const io = self.io;
        if (checkArgs(self.iterations, self.samples)) |_| {} else |err| {
            self.fail(err);
            return self.outcome;
        }
        self.echo.io = io;
        self.echo.method = http_method;
        self.echo.defect = self.defect;
        var group: Io.Group = .init;
        defer group.cancel(io);
        group.concurrent(io, FirstEvent.runPeer, .{self}) catch |err| {
            self.fail(err);
            group.cancel(io);
            return self.outcome;
        };
        group.concurrent(io, FirstEvent.runClient, .{self}) catch |err| {
            self.fail(err);
            group.cancel(io);
            return self.outcome;
        };
        // The group is this task's own, so the join below is also what keeps a
        // pointer to it from outliving it. `Group.await` blocks until every
        // task in it has finished and reports a cancelation only once they
        // have, so the join has happened either way, and the select that owns
        // this task has already chosen the outcome.
        // gate-reviewed-zlint-next-statement: suppressed-errors
        // ziglint-ignore: Z026
        // zwanzig-disable-next-line: empty-catch-engine
        group.await(io) catch {};

        // Every task that could report a failure has been joined; the read
        // goes through the same lock the writes did, so no access to the
        // field in this workload skips that discipline.
        self.outcome.failure = self.failure();
        self.outcome.answered = self.echo.answered;
        return self.outcome;
    }

    fn drive(self: *FirstEvent, io: Io) Outcome {
        self.io = io;
        self.endpoint.open(io) catch {
            self.fail(error.SocketFailed);
            return self.outcome;
        };
        defer self.endpoint.close(io);
        self.client_side.init(&self.endpoint) catch |err| {
            self.fail(err);
            return self.outcome;
        };
        return bounded(FirstEvent, io, self, self.budget_ns);
    }
};

// --- The frozen entry point ----------------------------------------------------

/// What the round-trip workload observed, kept after its storage is gone.
const ConnMeasurement = struct {
    failure: ?Error = null,
    stats: Stats = .{},
    // SAFETY: measureConn copies count windows into it and the report reads only that many.
    windows: [max_samples]Window = undefined,
    window_count: usize = 0,
    measured_ops: u64 = 0,
    answered: u32 = 0,
    orphans: u32 = 0,
    client_releases: u32 = 0,
    peer_releases: u32 = 0,
};

/// What the first-event workload observed, kept after its storage is gone.
const HttpMeasurement = struct {
    failure: ?Error = null,
    stats: Stats = .{},
    // SAFETY: measureHttp copies count windows into it and the report reads only that many.
    windows: [max_samples]Window = undefined,
    window_count: usize = 0,
    connect: Stats = .{},
    measured_ops: u64 = 0,
    skipped: u64 = 0,
    answered: u32 = 0,
    /// Exchanges where the peer confirmed the client held the event while the
    /// body was still open.
    observations: u32 = 0,
};

/// Measure the round-trip workload and keep only what the report prints.
fn measureConn(io: Io, iterations: u32, samples: u32) ConnMeasurement {
    var work: RoundTrip = .{ .iterations = iterations, .samples = samples };
    const outcome = work.drive(io);
    var measured: ConnMeasurement = .{ .failure = outcome.failure };
    if (outcome.failure != null) return measured;
    measured.stats = outcome.latencies.stats();
    measured.window_count = outcome.latencies.count;
    @memcpy(
        measured.windows[0..outcome.latencies.count],
        outcome.latencies.windows[0..outcome.latencies.count],
    );
    measured.measured_ops = outcome.ops;
    measured.answered = outcome.answered;
    measured.orphans = work.orphans.load(.acquire);
    measured.client_releases = outcome.client_releases;
    measured.peer_releases = outcome.peer_releases;
    return measured;
}

/// Measure the first-event workload and keep only what the report prints.
fn measureHttp(io: Io, iterations: u32, samples: u32) HttpMeasurement {
    var work: FirstEvent = .{ .iterations = iterations, .samples = samples };
    const outcome = work.drive(io);
    var measured: HttpMeasurement = .{ .failure = outcome.failure };
    if (outcome.failure != null) return measured;
    measured.stats = outcome.latencies.stats();
    measured.window_count = outcome.latencies.count;
    @memcpy(
        measured.windows[0..outcome.latencies.count],
        outcome.latencies.windows[0..outcome.latencies.count],
    );
    measured.connect = outcome.connect_latencies.stats();
    measured.measured_ops = outcome.ops;
    measured.skipped = outcome.skipped;
    measured.answered = outcome.answered;
    measured.observations = outcome.observations;
    return measured;
}

/// The nanoseconds one window cost per operation.
fn windowNsPerOp(window: Window) u64 {
    return window.ns / @as(u64, @max(window.ops, 1));
}

/// Measure both runtime workloads and write the report to `out`.
///
/// One `key=value` per line. The workload block comes first and is a function
/// of the two requests alone; the measurement blocks follow and are the only
/// part that may differ between two runs of the same requests.
///
///   bench=runtime
///   target=<cpu arch tag>       target_os=<os tag>    optimize=<build mode>
///   iterations= samples= warmup_ops= max_measured_ops=
///   method_conn= method_http= protocol_version=
///   caveat=closed-loop single-flight ...
///
///   conn_status=ok | conn_status=<Error>
///   conn_ops= conn_windows= conn_total_ns= conn_ns_per_op= conn_ops_per_second=
///   conn_min_op_ns= conn_max_op_ns= conn_median_ns_per_op= conn_p90_ns_per_op= conn_p99_ns_per_op=
///   conn_first_window_ns_per_op= conn_min_window_ns_per_op= conn_max_window_ns_per_op=
///   conn_answered= conn_warmup_discarded= conn_orphan_responses= conn_releases_client= conn_releases_peer=
///   conn_window=<n> ops=<n> total_ns=<n> ns_per_op=<n>   (exactly `samples` lines)
///
///   http_status=ok | http_status=<Error>
///   http_ops= http_windows= http_total_ns= http_ns_per_op= http_ops_per_second=
///   http_min_op_ns= http_max_op_ns= http_median_ns_per_op= http_p90_ns_per_op= http_p99_ns_per_op=
///   http_first_window_ns_per_op= http_min_window_ns_per_op= http_max_window_ns_per_op=
///   http_answered= http_warmup_discarded= http_skipped_events= http_body_open_proofs=
///   http_connect_ops= http_connect_windows= http_connect_total_ns= http_connect_ns_per_op=
///   http_connect_min_op_ns= http_connect_max_op_ns= http_connect_median_ns_per_op=
///   http_connect_p90_ns_per_op= http_connect_p99_ns_per_op=
///   http_window=<n> ops=<n> total_ns=<n> ns_per_op=<n>   (exactly `samples` lines)
///
/// The unqualified `*_ns_per_op` key is the mean over everything measured —
/// `*_total_ns` divided by `*_ops` — and is the figure `*_ops_per_second` is
/// the reciprocal of, so the rate and the per-operation figure printed beside
/// it can never be two different statistics wearing one name. Every other
/// statistic is named for what it is: `*_median_ns_per_op`, `*_p90_ns_per_op`,
/// `*_p99_ns_per_op`, the `*_window_ns_per_op` trio, and the per-window `ns_per_op`
/// on each `*_window=` line, which is that one window's average and nothing
/// else. `http_connect_*` follows the same rule, so the connect cost and the
/// boundary that excludes it are two means and can be subtracted from one
/// another.
///
/// `conn_status` and `http_status` are printed after that workload's numbers,
/// and a workload whose oracle failed prints `status=` and no numbers at all,
/// so a number is never printed beside a workload that did not measure one.
/// The first failure is returned. The argument check runs before the first
/// write, so a refused run leaves the writer exactly as it found it rather
/// than emitting a header with nothing under it.
pub fn run(io: Io, out: *Io.Writer, iterations: u32, samples: u32) !void {
    try checkArgs(iterations, samples);

    const conn_measurement = measureConn(io, iterations, samples);
    const http_measurement = measureHttp(io, iterations, samples);

    try out.print("bench=runtime\n", .{});
    try out.print(
        "target={s} target_os={s} optimize={s}\n",
        .{
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.os.tag),
            @tagName(builtin.mode),
        },
    );
    try out.print(
        "iterations={d} samples={d} warmup_ops={d} max_measured_ops={d}\n",
        .{ iterations, samples, warmup_ops, max_measured_ops },
    );
    try out.print(
        "method_conn={s} method_http={s} protocol_version={s}\n",
        .{ conn_method, http_method, protocol_version },
    );
    try out.print(
        "caveat=closed-loop single-flight: one request in flight at a time, " ++
            "so this is service completion latency and no coordinated-omission " ++
            "correction is applied\n",
        .{},
    );

    if (conn_measurement.failure) |reason| {
        try out.print("conn_status={s}\n", .{@errorName(reason)});
    } else {
        try printStats(
            out,
            "conn",
            conn_measurement.stats,
            conn_measurement.windows,
            conn_measurement.window_count,
        );
        try out.print("conn_status=ok\n", .{});
        try out.print(
            "conn_answered={d} conn_warmup_discarded={d} conn_orphan_responses={d} " ++
                "conn_releases_client={d} conn_releases_peer={d}\n",
            .{
                conn_measurement.answered,
                @as(u64, conn_measurement.answered) - conn_measurement.measured_ops,
                conn_measurement.orphans,
                conn_measurement.client_releases,
                conn_measurement.peer_releases,
            },
        );
    }

    if (http_measurement.failure) |reason| {
        try out.print("http_status={s}\n", .{@errorName(reason)});
    } else {
        try printStats(
            out,
            "http",
            http_measurement.stats,
            http_measurement.windows,
            http_measurement.window_count,
        );
        try out.print("http_status=ok\n", .{});
        try out.print(
            "http_answered={d} http_warmup_discarded={d} http_skipped_events={d} " ++
                "http_body_open_proofs={d}\n",
            .{
                http_measurement.answered,
                @as(u64, http_measurement.answered) - http_measurement.measured_ops,
                http_measurement.skipped,
                http_measurement.observations,
            },
        );
        // The connect figures are their own measurement: the same timed
        // exchanges the boundary covers, one window each, and their
        // unqualified per-operation key is the mean for the same reason the
        // boundary's is, so a caller subtracts a mean from a mean and sees
        // what the boundary does not include rather than having to guess.
        try out.print(
            "http_connect_ops={d} http_connect_windows={d} http_connect_total_ns={d} " ++
                "http_connect_ns_per_op={d} http_connect_min_op_ns={d} " ++
                "http_connect_max_op_ns={d} http_connect_median_ns_per_op={d} " ++
                "http_connect_p90_ns_per_op={d} http_connect_p99_ns_per_op={d}\n",
            .{
                http_measurement.connect.ops,
                http_measurement.connect.windows,
                http_measurement.connect.total_ns,
                http_measurement.connect.meanNsPerOp(),
                http_measurement.connect.min_op_ns,
                http_measurement.connect.max_op_ns,
                http_measurement.connect.median_ns_per_op,
                http_measurement.connect.p90_ns_per_op,
                http_measurement.connect.p99_ns_per_op,
            },
        );
    }

    if (conn_measurement.failure) |reason| return reason;
    if (http_measurement.failure) |reason| return reason;
}

/// One workload's folded statistics and every window it measured.
fn printStats(
    out: *Io.Writer,
    prefix: []const u8,
    stats: Stats,
    windows: [max_samples]Window,
    count: usize,
) !void {
    try out.print(
        "{s}_ops={d} {s}_windows={d} {s}_total_ns={d} {s}_ns_per_op={d} {s}_ops_per_second={d}\n",
        .{
            prefix,
            stats.ops,
            prefix,
            stats.windows,
            prefix,
            stats.total_ns,
            prefix,
            stats.meanNsPerOp(),
            prefix,
            stats.opsPerSecond(),
        },
    );
    try out.print(
        "{s}_min_op_ns={d} {s}_max_op_ns={d} {s}_median_ns_per_op={d} " ++
            "{s}_p90_ns_per_op={d} {s}_p99_ns_per_op={d}\n",
        .{
            prefix,
            stats.min_op_ns,
            prefix,
            stats.max_op_ns,
            prefix,
            stats.median_ns_per_op,
            prefix,
            stats.p90_ns_per_op,
            prefix,
            stats.p99_ns_per_op,
        },
    );
    try out.print(
        "{s}_first_window_ns_per_op={d} {s}_min_window_ns_per_op={d} " ++
            "{s}_max_window_ns_per_op={d}\n",
        .{
            prefix,
            stats.first_window_ns_per_op,
            prefix,
            stats.min_window_ns_per_op,
            prefix,
            stats.max_window_ns_per_op,
        },
    );
    for (windows[0..count], 0..) |window, index| {
        try out.print(
            "{s}_window={d} ops={d} total_ns={d} ns_per_op={d}\n",
            .{ prefix, index, window.ops, window.ns, windowNsPerOp(window) },
        );
    }
}

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test "the percentile rule is nearest rank and the median is the middle" {
    // Every percentile rule gives a different answer on a small sample, so the
    // one this module reports is pinned rather than assumed.
    const sorted = [_]u64{ 10, 20, 30, 40 };
    try testing.expectEqual(@as(u64, 10), nearestRank(&sorted, 1, 100));
    try testing.expectEqual(@as(u64, 20), nearestRank(&sorted, 50, 100));
    try testing.expectEqual(@as(u64, 40), nearestRank(&sorted, 90, 100));
    try testing.expectEqual(@as(u64, 40), nearestRank(&sorted, 99, 100));
    try testing.expectEqual(@as(u64, 40), nearestRank(&sorted, 100, 100));
    // The median of an even count is the mean of the two middle values, which
    // is not p50 by nearest rank: the two rules differ here on purpose.
    try testing.expectEqual(@as(u64, 25), median(&sorted));
    const odd = [_]u64{ 10, 20, 40 };
    try testing.expectEqual(@as(u64, 20), median(&odd));
    const one = [_]u64{7};
    try testing.expectEqual(@as(u64, 7), median(&one));
    try testing.expectEqual(@as(u64, 7), nearestRank(&one, 99, 100));
    const maximum = std.math.maxInt(u64);
    try testing.expectEqual(maximum, median(&.{ maximum, maximum }));
    try testing.expectEqual(maximum - 1, median(&.{ maximum - 1, maximum }));
    try testing.expectEqual(maximum / 2, median(&.{ 0, maximum }));
    try testing.expectEqual(@as(u64, 40), nearestRank(&sorted, maximum, maximum));
    try testing.expectEqual(@as(u64, 40), nearestRank(&sorted, maximum - 1, maximum));
    try testing.expectEqual(@as(u64, 10), nearestRank(&sorted, 0, maximum));
}

test "the statistics fold windows without growing the storage" {
    // One window of two operations, then one window of a single operation:
    // the per-operation figures are the window totals divided by the
    // operations each held, not by the operations of some other window.
    var latencies: Latencies = .{};
    latencies.record(100);
    latencies.record(200);
    latencies.closeWindow();
    latencies.record(900);
    latencies.closeWindow();

    const stats = latencies.stats();
    try testing.expectEqual(@as(usize, 2), stats.windows);
    try testing.expectEqual(@as(u64, 3), stats.ops);
    try testing.expectEqual(@as(u64, 150), stats.first_window_ns_per_op);
    try testing.expectEqual(@as(u64, 150), stats.min_window_ns_per_op);
    try testing.expectEqual(@as(u64, 900), stats.max_window_ns_per_op);
    try testing.expectEqual(@as(u64, 525), stats.median_ns_per_op);
    try testing.expectEqual(@as(u64, 900), stats.p90_ns_per_op);
    try testing.expectEqual(@as(u64, 100), stats.min_op_ns);
    try testing.expectEqual(@as(u64, 900), stats.max_op_ns);
    try testing.expectEqual(@as(u64, 1200), stats.total_ns);

    // A reset is what makes a phase's numbers measurable at all; without it a
    // warm-up would be reported as a sample.
    latencies.reset();
    try testing.expectEqual(@as(usize, 0), latencies.count);
    try testing.expectEqual(@as(u64, 0), latencies.ops);
}

test "work the fixed arrays cannot hold is refused, not attempted" {
    try testing.expectError(error.BadIterations, checkArgs(0, 1));
    try testing.expectError(error.BadIterations, checkArgs(max_iterations + 1, 1));
    try testing.expectError(error.BadSamples, checkArgs(1, 0));
    try testing.expectError(error.BadSamples, checkArgs(1, max_samples + 1));
    try testing.expectError(error.WorkTooLarge, checkArgs(max_iterations, max_samples));
    try checkArgs(1, 1);
    try checkArgs(max_measured_ops, 1);
}

test "a refused run writes nothing at all" {
    // The refusal happens before the first write, so a caller that handed in a
    // writer and got an error has a writer it can still use, rather than one
    // holding a header with no measurements under it. No socket is opened
    // either: `checkArgs` runs first and neither workload ever sees the
    // request. The product case stays inside both per-parameter ranges so that
    // it is the product, and not a range, that refuses it.
    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try testing.expectError(error.BadIterations, run(testing.io, &writer, 0, 1));
    try testing.expectError(error.BadSamples, run(testing.io, &writer, 1, max_samples + 1));
    try testing.expectError(error.WorkTooLarge, run(testing.io, &writer, 200, 60));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "unavailable concurrency is not a socket fault or a measurement" {
    for ([_]Io.Limit{ .nothing, .limited(1) }) |limit| {
        var threaded: Io.Threaded = .init(testing.allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = limit,
        });
        defer threaded.deinit();
        const io = threaded.io();
        var round_trip: RoundTrip = .{};
        const round = round_trip.drive(io);
        try testing.expectEqual(@as(?Error, error.ConcurrencyUnavailable), round.failure);
        try testing.expectEqual(@as(u64, 0), round.ops);
        var first_event: FirstEvent = .{};
        const event = first_event.drive(io);
        try testing.expectEqual(@as(?Error, error.ConcurrencyUnavailable), event.failure);
        try testing.expectEqual(@as(u64, 0), event.ops);
    }
}

test "the round trip reports the result the peer owes, for every operation" {
    var round_trip: RoundTrip = .{ .iterations = 4, .samples = 3 };
    const outcome = round_trip.drive(testing.io);

    try testing.expectEqual(@as(?Error, null), outcome.failure);
    const ops: u64 = 4 * 3;
    try testing.expectEqual(ops, outcome.ops);
    try testing.expectEqual(ops, outcome.latencies.ops);
    // Every window holds the operations it was asked for, and every operation
    // reached the peer: an answer that was fabricated or dropped would show as
    // a gap between the two counts rather than as a faster run.
    try testing.expectEqual(@as(usize, 3), outcome.latencies.count);
    for (outcome.latencies.windows[0..outcome.latencies.count]) |window| {
        try testing.expectEqual(@as(u32, 4), window.ops);
    }
    try testing.expectEqual(ops + warmup_ops, @as(u64, outcome.answered));
    // The teardown ran once on each end and only once: a second release would
    // close whatever the process opened next, and a missing one would leak it.
    try testing.expectEqual(@as(u32, 1), outcome.client_releases);
    try testing.expectEqual(@as(u32, 1), outcome.peer_releases);
    try testing.expectEqual(@as(u32, 0), round_trip.orphans.load(.acquire));
}

test "a response that names nobody's call is caught, and the real answer is not it" {
    // The peer answers the first request with an id nobody asked for and every
    // request after it correctly, so the call that does arrive still completes:
    // what the oracle has to catch is the response nobody was waiting for.
    var round_trip: RoundTrip = .{ .iterations = 2, .samples = 1, .defect = .wrong_id };
    const outcome = round_trip.drive(testing.io);

    try testing.expectEqual(Error.WrongResponseId, outcome.failure.?);
    try testing.expect(round_trip.orphans.load(.acquire) != 0);
    // The operation that was answered by nobody is not a sample: a number
    // counted from it would be a number for a call this client never completed.
    try testing.expectEqual(@as(u64, 0), outcome.ops);
    try testing.expectEqual(@as(u32, 1), outcome.client_releases);
    try testing.expectEqual(@as(u32, 1), outcome.peer_releases);
}

test "a result that is not the one the peer owes is caught" {
    var round_trip: RoundTrip = .{ .iterations = 2, .samples = 1, .defect = .wrong_result };
    const outcome = round_trip.drive(testing.io);

    try testing.expectEqual(Error.WrongResult, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
    try testing.expectEqual(@as(u32, 1), outcome.client_releases);
    try testing.expectEqual(@as(u32, 1), outcome.peer_releases);
}

test "a refusal is not a result" {
    var round_trip: RoundTrip = .{ .iterations = 2, .samples = 1, .defect = .refuse };
    const outcome = round_trip.drive(testing.io);

    try testing.expectEqual(Error.Refused, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
    try testing.expectEqual(@as(u32, 1), outcome.client_releases);
    try testing.expectEqual(@as(u32, 1), outcome.peer_releases);
}

test "a hanging-up peer stops answering before its owner shuts down" {
    var handoff: Handoff = .{};
    var echo: Echo = .{
        .io = testing.io,
        .handoff = &handoff,
        .method = conn_method,
        .defect = .hang_up,
    };
    // SAFETY: the request decoder writes only the escaped strings it returns.
    var decode_scratch: [256]u8 = undefined;
    // SAFETY: Echo.handle returns only the prefix its response encoder wrote.
    var answer: [512]u8 = undefined;
    // SAFETY: jsonrpc.decode writes only the escaped strings it returns.
    var response_scratch: [256]u8 = undefined;
    const first = (try Echo.handle(
        &echo,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}",
        &decode_scratch,
        &answer,
    )) orelse return error.TestExpectedResponse;
    const response = try jsonrpc.decode(first, &response_scratch);
    try testing.expectEqual(jsonrpc.Kind.response, response.kind);
    try testing.expectEqualDeep(@as(?jsonrpc.Id, .{ .integer = 1 }), response.id);

    // No owner task runs between these calls: a queued shutdown must not let
    // the reader finish another operation while the owner waits to be scheduled.
    try testing.expectEqual(@as(?[]const u8, null), try Echo.handle(
        &echo,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\"}",
        &decode_scratch,
        &answer,
    ));
}

test "a peer that hangs up mid-run is reported, and both descriptors are released once" {
    // One answer, then the peer hangs up. The client's next call is either
    // writing or waiting on a descriptor the peer's hang-up is about to shut
    // down, which is the race the teardown discipline exists for: `shutdown`
    // wakes the blocked read without closing anything, the owner releases
    // both descriptors after the join, and nobody closes one twice.
    //
    // Before the discipline was corrected the reader released on its way out,
    // which is the whole of this test's failure: on a target slow enough for
    // the writer to still be inside `writeFrame`, the run aborted inside
    // `netWritePosix` on `EBADF` instead of reporting `PeerEnded` here.
    var round_trip: RoundTrip = .{ .iterations = 8, .samples = 1, .defect = .hang_up };
    const outcome = round_trip.drive(testing.io);

    try testing.expectEqual(@as(?Error, error.PeerEnded), outcome.failure);
    try testing.expect(outcome.ops < 8);
    try testing.expectEqual(@as(u32, 1), outcome.answered);
    try testing.expectEqual(@as(u32, 1), outcome.client_releases);
    try testing.expectEqual(@as(u32, 1), outcome.peer_releases);
}

/// A writer that is let go only once its reader has returned.
///
/// This is the task the abort used to be reachable from, split out so the
/// test below can put a gate in front of it. It writes a whole frame
/// through the very writer `conn.Conn` was handed in `open` and flushes it,
/// which is the same `netWritePosix` the connection's own write path reaches
/// and the same one that answered `EBADF`.
///
/// The releases it saw at the moment of that write are the assertion: a
/// reader that closed the descriptor on its way out would leave one there
/// and take it away from this task. The join below is what makes reading
/// that field here safe.
const GatedWrite = struct {
    // SAFETY: the test assigns it before the writer task is spawned, and the
    // task that reads it is joined before the test's storage ends.
    io: Io,
    /// The side whose descriptor is written. Nothing else in this test
    /// writes, and the pump reads the other direction of the same socket.
    side: *ConnSide,
    /// Posted by the test once the reader task has been joined.
    go: Io.Semaphore = .{},
    /// Releases the side held when this task wrote.
    releases_at_write: u32 = 0,
    /// A whole framed message, because this is the framed writer and a frame
    /// is what it exists to carry.
    frame: []const u8 = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/probe\"}\n",

    fn write(self: *GatedWrite) void {
        // The gate. A wait that cannot be met is a broken test rather than a
        // result, and there is nothing here to report it to: the posting task
        // posts unconditionally once it has joined the reader.
        self.go.wait(self.io) catch return;
        self.releases_at_write = self.side.releases;
        // The flush is what reaches the socket: the frame is shorter than the
        // writer's buffer, so without it `writeAll` would only stage bytes
        // and no syscall would be made at all.
        self.side.writer.interface.writeAll(self.frame) catch return;
        self.side.writer.interface.flush() catch return;
    }
};

test "a reader that has returned does not take the descriptor its caller writes" {
    // The regression, with the ordering pinned instead of left to the
    // scheduler.
    //
    // What went wrong: the pump read the peer's hang-up, released, and closed
    // the descriptor — while the client task was still writing on it. The
    // writer was a different task from the reader, which is the whole reason
    // the reader had no business closing. `Io.Threaded` answers `EBADF` from a
    // closed descriptor by aborting the process, so a run that should have
    // reported `PeerEnded` died instead. It only showed on slow targets,
    // which is exactly the signature of a race rather than a logic fault.
    //
    // Everything here is real and nothing is timed. A real `Io.Threaded`, a
    // real loopback listener, a real `conn.Conn`, and a real peer that really
    // hangs up. The reader task is the shipped `ConnSide.pump`, spawned by the
    // shipped `ConnSide.open`, on a group that holds nothing else — so
    // awaiting that group *is* the proof that the reader has returned, and
    // only then is the writer released through a semaphore. No sleep, no
    // retry, and no peeking at anything the run is supposed to decide.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bound = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try bound.listen(io, .{});
    defer listener.deinit(io);
    // The kernel's own choice read back off the listening socket, so this
    // cannot collide with anything else this machine is running.
    const address = try Io.net.IpAddress.parse("127.0.0.1", listener.socket.address.getPort());

    // Two groups on purpose: joining the reader's is the gate, and the writer
    // has to be somewhere else so that joining it does not wait for the very
    // task being gated.
    var reader_group: Io.Group = .init;
    defer reader_group.cancel(io);
    var writer_group: Io.Group = .init;
    defer writer_group.cancel(io);

    // Connected before the accept so the connection is already queued and
    // `accept` below cannot block the gate shut.
    const stream = try address.connect(io, .{ .mode = .stream });
    var client_side: ConnSide = .{};
    // The connection is owned by the side from here on: `open` assigns it
    // before the pump can touch it, and both groups are joined before this
    // scope's storage ends.
    try client_side.open(io, &reader_group, stream, null, null);

    var gate: GatedWrite = .{ .io = io, .side = &client_side };
    try writer_group.concurrent(io, GatedWrite.write, .{&gate});

    // The peer hangs up. `shutdown` before `close`, because a close on a
    // socket whose peer still has unread bytes answers with a reset, and this
    // is meant to be the orderly end of the stream that wakes the reader.
    const peer = try listener.accept(io);
    // Best effort: the close below releases the descriptor either way, and a
    // shutdown that cannot be sent means the peer is already gone — which is
    // the case this is arranging.
    peer.shutdown(io, .both) catch {};
    peer.close(io);

    // The reader has returned, and it released nothing: the descriptor is
    // still the caller's to write on.
    try reader_group.await(io);
    try testing.expectEqual(@as(u32, 0), client_side.releases);

    // Now the writer writes, against a descriptor whose reader has already
    // returned. Under the old discipline that write is the abort.
    gate.go.post(io);
    try writer_group.await(io);

    // Seen from the writer's own task, after the join that orders the read:
    // the reader closed nothing while this task could still be flushing.
    try testing.expectEqual(@as(u32, 0), gate.releases_at_write);

    // And the owner closes it, once, and only now that both tasks are gone.
    client_side.releaseSafe();
    try testing.expectEqual(@as(u32, 1), client_side.releases);
    client_side.releaseSafe();
    try testing.expectEqual(@as(u32, 1), client_side.releases);
}

/// A `netConnectIp` that refuses every connect, so no connect in the test
/// below reaches the network at all.
///
/// Paired with a copy of the test executor's own vtable and userdata, so this
/// is the one operation that is refused and every other one — the listener,
/// the tasks, the mutex, the clock, the budget's sleep — is the real one.
fn refusingConnectIp(
    userdata: ?*anyopaque,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.ConnectOptions,
) Io.net.IpAddress.ConnectError!Io.net.Socket {
    _ = userdata;
    _ = address;
    _ = options;
    return error.ConnectionRefused;
}

test "a client that cannot connect keeps its own diagnosis" {
    // The listener the peer waits on is real and stays open, and only the
    // client's connect is refused: nothing about the peer is faked, and the
    // refusal belongs to this test rather than to whatever a port holds. The
    // peer has to learn from the handoff that no connection is coming,
    // because an `accept` reached anyway would wait for a client that has
    // already stopped — the run would end on the wall budget, and the
    // `SocketFailed` the client diagnosed would be thrown away for a
    // `WallBudgetExceeded` that says nothing about what happened.
    var vtable = testing.io.vtable.*;
    vtable.netConnectIp = refusingConnectIp;
    const io: Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    var round_trip: RoundTrip = .{
        .iterations = 1,
        .samples = 1,
        // Finite, and far longer than two tasks and a refused connect need:
        // a budget a loaded machine could reach anyway would turn a scheduling
        // delay into the very report this test exists to rule out.
        .budget_ns = 10 * ns_per_s,
    };
    round_trip.io = io;
    round_trip.endpoint.open(io) catch return error.SkipZigTest;
    defer round_trip.endpoint.close(io);

    const outcome = bounded(RoundTrip, io, &round_trip, round_trip.budget_ns);

    // The diagnosis is the client's, and it survives the peer having nothing
    // left to wait for.
    try testing.expectEqual(Error.SocketFailed, outcome.failure.?);
    // A run that never connected opened no side at either end, so there is no
    // descriptor for a teardown to release.
    try testing.expectEqual(@as(u32, 0), outcome.client_releases);
    try testing.expectEqual(@as(u32, 0), outcome.peer_releases);
}

test "the first event is observed while the body is still open" {
    var first_event: FirstEvent = .{ .iterations = 2, .samples = 2 };
    const outcome = first_event.drive(testing.io);

    try testing.expectEqual(@as(?Error, null), outcome.failure);
    const ops: u64 = 2 * 2;
    const exchanges: u64 = ops + warmup_ops;
    try testing.expectEqual(ops, outcome.ops);
    try testing.expectEqual(ops, outcome.latencies.ops);
    try testing.expectEqual(@as(u64, 0), outcome.skipped);
    // The peer confirms, per exchange, that the client signalled with the event
    // in hand before the body ended. The signal is the only thing that lets the
    // peer end the body, so the count is the invariant itself.
    try testing.expectEqual(exchanges, @as(u64, outcome.observations));
    try testing.expectEqual(exchanges, @as(u64, outcome.answered));
    try testing.expectEqual(@as(usize, 2), outcome.latencies.count);
    // The connects are timed and reported outside the boundary, so a caller can
    // see what the per-operation figure does not include. There is one per
    // timed operation and none from the warm-up, which was discarded whole.
    try testing.expectEqual(ops, outcome.connect_latencies.ops);
    // One connect window per exchange window: the connect figures are folded
    // from closed windows like the boundary's own, so a window that was never
    // closed shows here rather than as a report of nothing.
    try testing.expectEqual(@as(usize, 2), outcome.connect_latencies.count);
}

test "an event that is not the answer is stepped over, and the answer still is one" {
    // A non-message and a notification first, on the same reply: the client has
    // to step over both and time the first event that is the answer, which is
    // what "first valid event" means. The run is two operations in one window,
    // and each operation steps over two events, so the skips are counted per
    // exchange rather than per window.
    var first_event: FirstEvent = .{ .iterations = 2, .samples = 1, .defect = .preamble };
    const outcome = first_event.drive(testing.io);

    try testing.expectEqual(@as(?Error, null), outcome.failure);
    try testing.expectEqual(@as(u64, 2), outcome.ops);
    try testing.expectEqual(@as(u64, 4), outcome.skipped);
    try testing.expectEqual(@as(u64, 2 + warmup_ops), @as(u64, outcome.observations));
    // One window of two operations, which is the shape the run asked for.
    try testing.expectEqual(@as(usize, 1), outcome.latencies.count);
}

test "a request from the peer where the answer belongs is refused, not skipped" {
    // A server must not send a request of its own on this stream, so the client
    // reports it rather than stepping over it until something decodes.
    var first_event: FirstEvent = .{ .iterations = 2, .samples = 1, .defect = .peer_request };
    const outcome = first_event.drive(testing.io);

    try testing.expectEqual(Error.PeerRequest, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
}

test "a body that ends before a valid event is reported, not counted" {
    // The negative half of the first-event-before-end invariant: the peer ends
    // the reply without sending anything, and the operation is a failure rather
    // than a fast sample.
    var first_event: FirstEvent = .{ .iterations = 2, .samples = 1, .defect = .hang_up };
    const outcome = first_event.drive(testing.io);

    try testing.expectEqual(Error.StreamEndedBeforeEvent, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
    try testing.expectEqual(@as(u32, 0), outcome.observations);
}

test "a first event for an id this client never sent is caught" {
    var first_event: FirstEvent = .{ .iterations = 1, .samples = 1, .defect = .wrong_id };
    const outcome = first_event.drive(testing.io);

    try testing.expectEqual(Error.WrongResponseId, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
}

test "a first event whose subscription id belongs to another call is caught" {
    // The required `_meta` of a `subscriptions/listen` result must equal this
    // response's own id. A peer that answers another call's id sends a
    // well-formed result of the wrong call, and the comparison against the id
    // this client sent is what catches it.
    var first_event: FirstEvent = .{ .iterations = 1, .samples = 1, .defect = .wrong_result };
    const outcome = first_event.drive(testing.io);

    try testing.expectEqual(Error.WrongResult, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
}

test "a first event that is a refusal is caught" {
    var first_event: FirstEvent = .{ .iterations = 1, .samples = 1, .defect = .refuse };
    const outcome = first_event.drive(testing.io);

    try testing.expectEqual(Error.Refused, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
}

test "a peer that never flushes the first event is ended by the wall budget" {
    // The body is opened and left empty: the reader waits for an event that is
    // not coming. Nothing else in this workload bounds that wait, so this is
    // the test of the bound itself — it must return, and it must return as the
    // budget rather than as a broken socket.
    var first_event: FirstEvent = .{
        .iterations = 4,
        .samples = 1,
        .budget_ns = 200 * 1_000_000,
        .defect = .silent,
    };
    const start = clock.now(testing.io);
    const outcome = first_event.drive(testing.io);
    const elapsed = start.durationTo(clock.now(testing.io)).nanoseconds;

    try testing.expectEqual(Error.WallBudgetExceeded, outcome.failure.?);
    try testing.expectEqual(@as(u64, 0), outcome.ops);
    // Bounded by the budget plus the unwinding, never by the workload.
    try testing.expect(elapsed < 30 * ns_per_s);
}

test "a run that outlives its wall budget is cancelled and reported" {
    // A budget no machine can meet with this much socket work, so the deadline
    // is the bound being exercised rather than a race being won: 8000 real
    // round trips cannot happen in a millisecond.
    var first_event: FirstEvent = .{
        .iterations = 1000,
        .samples = 8,
        .budget_ns = 1_000_000,
    };
    const start = clock.now(testing.io);
    const outcome = first_event.drive(testing.io);
    const elapsed = start.durationTo(clock.now(testing.io)).nanoseconds;

    try testing.expectEqual(Error.WallBudgetExceeded, outcome.failure.?);
    try testing.expect(outcome.ops < 1000 * 8);
    try testing.expect(elapsed < 30 * ns_per_s);
}

/// The first `key=` in `report`, as a count.
///
/// The key has to begin a token, so `conn_ops=` is not answered by the
/// `conn_ops_per_second=` beside it, and a key that stopped being printed
/// fails the assertion that wanted it rather than matching a longer name.
fn reportCount(report: []const u8, key: []const u8) ?u64 {
    var rest = report;
    while (std.mem.find(u8, rest, key)) |at| {
        const boundary = at == 0 or rest[at - 1] == ' ' or rest[at - 1] == '\n';
        const after = rest[at + key.len ..];
        if (boundary) {
            const end = std.mem.findAny(u8, after, " \n") orelse after.len;
            return std.fmt.parseInt(u64, after[0..end], 10) catch null;
        }
        rest = after;
    }
    return null;
}

/// How many lines of `report` begin with `key`.
fn reportLineCount(report: []const u8, key: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) count += 1;
    }
    return count;
}

/// The times of every line beginning with `key`, added up.
fn reportWindowTotal(report: []const u8, key: []const u8) ?u64 {
    var total: u64 = 0;
    var found = false;
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        total += reportCount(line, "total_ns=") orelse return null;
        found = true;
    }
    return if (found) total else null;
}

test "the report accounts for every timed operation, window and connect" {
    // The whole path: the bounds check, both real-socket workloads, then the
    // report. What is checked here is the arithmetic a caller would otherwise
    // have to do by hand, because a run that dropped an operation, closed a
    // window it never filled or reported a connect that was not one of the
    // timed exchanges still prints `ok`, and nothing else would say so.
    var buffer: [64 * 1024]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    const iterations: u32 = 2;
    const samples: u32 = 3;

    try run(testing.io, &writer, iterations, samples);

    const report = writer.buffered();
    const ops: u64 = @as(u64, iterations) * samples;
    const windows: u64 = samples;

    // Every operation asked for is one operation measured, in both workloads.
    try testing.expectEqual(ops, reportCount(report, "conn_ops=").?);
    try testing.expectEqual(ops, reportCount(report, "http_ops=").?);
    // The windows are the run's own: one per sample, and the summary total is
    // exactly what those windows hold.
    try testing.expectEqual(windows, reportLineCount(report, "conn_window="));
    try testing.expectEqual(windows, reportLineCount(report, "http_window="));
    try testing.expectEqual(
        reportCount(report, "conn_total_ns=").?,
        reportWindowTotal(report, "conn_window=").?,
    );
    try testing.expectEqual(
        reportCount(report, "http_total_ns=").?,
        reportWindowTotal(report, "http_window=").?,
    );
    // The connect is measured over the same timed exchanges, in the same
    // number of windows, and covers none of the warm-up's.
    try testing.expectEqual(ops, reportCount(report, "http_connect_ops=").?);
    try testing.expectEqual(windows, reportCount(report, "http_connect_windows=").?);
    try testing.expect(reportCount(report, "http_connect_total_ns=").? > 0);
    // The connect's unqualified per-operation figure is its own mean, like
    // the boundary's: the number a caller subtracts from `http_ns_per_op` has
    // to be the same statistic as the number it is subtracted from.
    try testing.expectEqual(
        reportCount(report, "http_connect_total_ns=").? / reportCount(report, "http_connect_ops=").?,
        reportCount(report, "http_connect_ns_per_op=").?,
    );
}

test "the unqualified per-operation key is the mean the rate is the inverse of" {
    // Windows chosen so the statistics disagree: 100 + 200 in the first, 900
    // in the second, so the run's mean is 400, its median is 525 and its
    // first window is 150. A key whose name says only `ns_per_op` is read by
    // a caller as the cost of an operation over the whole run, and the rate
    // printed beside it is the inverse of exactly that figure — so a report
    // that put another statistic there would make the two keys contradict
    // each other and the key contradict its own `total_ns` and `ops`.
    var latencies: Latencies = .{};
    latencies.record(100);
    latencies.record(200);
    latencies.closeWindow();
    latencies.record(900);
    latencies.closeWindow();

    var buffer: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try printStats(&writer, "probe", latencies.stats(), latencies.windows, latencies.count);
    const report = writer.buffered();

    // 1200 ns over 3 operations is 400, and the key carries that arithmetic
    // rather than a statistic it does not name.
    try testing.expectEqual(@as(u64, 1200), reportCount(report, "probe_total_ns=").?);
    try testing.expectEqual(@as(u64, 3), reportCount(report, "probe_ops=").?);
    try testing.expectEqual(
        reportCount(report, "probe_total_ns=").? / reportCount(report, "probe_ops=").?,
        reportCount(report, "probe_ns_per_op=").?,
    );
    // Every other statistic keeps its own name, and is a different number:
    // the median is 525, not the mean.
    try testing.expectEqual(@as(u64, 525), reportCount(report, "probe_median_ns_per_op=").?);
    // 3 operations over 1.2 us is 2.5 million per second, which is the mean
    // above inverted and not a figure derived from any other statistic.
    try testing.expectEqual(@as(u64, 2_500_000), reportCount(report, "probe_ops_per_second=").?);
    // The bare token inside a window line is that window's own average, which
    // is neither the mean nor the median of the run: 150 for the window of
    // two operations, and one line per window.
    try testing.expectEqual(@as(usize, 2), reportLineCount(report, "probe_window="));
    try testing.expectEqual(@as(u64, 150), reportCount(report, "ns_per_op=").?);
}
