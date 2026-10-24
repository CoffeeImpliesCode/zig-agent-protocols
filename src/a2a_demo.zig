//! A working A2A `1.0` agent and client over real sockets, in one process.
//!
//! This is the JSON-RPC binding of Agent2Agent at its pinned revision, driven
//! end to end: the client discovers the agent through the well-known path, reads
//! the card, picks the first interface it speaks, and sends three unary
//! `SendMessage` calls to the endpoint the card advertises. The agent answers one
//! with a `Task`, one with a `Message` and one with a JSON-RPC error, and the
//! client reads all three as the three different things they are.
//!
//! Nothing about the endpoint is guessed. The card publishes
//! `/agents/echo/a2a-v1?tenant=acme`, which is neither a default nor the `/rpc` a
//! client would reach for, and the query is part of the endpoint: a client that
//! dropped it would be calling something else. The port is the kernel's choice
//! and the card is written with it, so the client has to read the card to learn
//! where to POST.
//!
//! Every buffer below belongs to the caller, on both sides, so this example
//! doubles as a check that the binding is usable without an allocator. The one
//! allocator is the one `std.http.Client` takes for its own connection pool, and
//! no connection outlives the task that opened it.
//!
//! The two tasks share one group and one handoff, and the group is waited on
//! with a deadline. The handoff is what makes every wait answerable: a client
//! that fails before it connects says so, and a server that is about to accept
//! does not begin. The deadline is the backstop, and it is a real cancelation
//! rather than a timeout that only gets reported: whichever of the two finished
//! first, the other is cancelled, and a cancelation that reaches the task
//! awaiting the group unwinds the group with it.
//!
//! Every way out of either task names the step it stopped at and what stopped
//! it there. "The exchange failed" is not a report of a wire: the body prints
//! the first cause either task recorded, so a run that regresses says which
//! call broke and still exits non-zero.
//!
//! Run it with `zig build run-a2a`.

const std = @import("std");
const proto = @import("zig-agent-protocols");

const a2a = proto.a2a;
const a2a_http = proto.a2a_http;
const Io = std.Io;
/// The standard library's HTTP, which the binding is written on.
const wire = std.http;

const testing = std.testing;

// --- What this example is about -------------------------------------------------

/// The version both ends speak, written as the wire spells it.
///
/// The two are cross-checked at compile time, so this example cannot advertise
/// one revision and send another: the card's `protocolVersion` and the
/// `A2A-Version` header are the same string and the binding's own version is
/// the one that has to match.
const version_text = "1.0";

comptime {
    if (a2a_http.version.major != 1 or a2a_http.version.minor != 0) {
        @compileError("this example speaks 1.0 and the binding moved to " ++
            std.fmt.comptimePrint("{d}.{d}", .{
                a2a_http.version.major,
                a2a_http.version.minor,
            }));
    }
}

/// The endpoint the card publishes, query included.
///
/// A path a client would never guess and a query it must not drop: this is the
/// whole point of reading the card instead of composing a URL.
const rpc_path = "/agents/echo/a2a-v1?tenant=acme";

/// Which of the three answers a `SendMessage` can have.
const Arm = enum { task, message, peer_error };

/// The three calls this example makes, in order. The agent answers by the
/// wording of each, so one handler covers all three answers, and the client
/// knows which arm it asked for rather than inferring it from the answer.
const asks = [_]struct { text: []const u8, arm: Arm }{
    .{ .text = "task please", .arm = .task },
    .{ .text = "message please", .arm = .message },
    .{ .text = "refuse please", .arm = .peer_error },
};

/// The card this example serves, and the storage every list it names.
///
/// `a2a.AgentCard` is a borrowed value: the lists it names are the caller's,
/// not the card's, and it says so in the one place that matters here. A list
/// written as `&.{...}` inside the function that composes a card is a
/// temporary in that function's block, so a card built by returning a struct
/// literal publishes whatever the next call left in a frame that is gone by
/// the time the server encodes it. The endpoint is the one fact a client
/// cannot do without, so every list is a field here and the card is composed
/// in place.
const Card = struct {
    // SAFETY: `compose` writes element 0; every call site composes before `value` reads it.
    interfaces: [1]a2a.AgentInterface = undefined,
    // SAFETY: `compose` writes element 0; the card borrows it as `[0..1]`.
    input_modes: [1][]const u8 = undefined,
    // SAFETY: `compose` writes element 0; the card borrows it as `[0..1]`.
    output_modes: [1][]const u8 = undefined,
    // SAFETY: `compose` writes element 0; the skill borrows it as `[0..1]`.
    tags: [1][]const u8 = undefined,
    // SAFETY: `compose` writes element 0; the skill borrows it as `[0..1]`.
    examples: [1][]const u8 = undefined,
    // SAFETY: `compose` writes element 0; the skill borrows it as `[0..1]`.
    skill_input_modes: [1][]const u8 = undefined,
    // SAFETY: `compose` writes element 0; the skill borrows it as `[0..1]`.
    skill_output_modes: [1][]const u8 = undefined,
    // SAFETY: `compose` writes element 0 after the lists the skill borrows are set.
    skills: [1]a2a.AgentSkill = undefined,
    // SAFETY: `compose` assigns it last, and `value` returns that assignment.
    card: a2a.AgentCard = undefined,

    /// Compose the card that advertises `interface_url` into this struct.
    fn compose(self: *Card, interface_url: []const u8) void {
        self.interfaces[0] = .{
            .url = interface_url,
            .protocol_binding = a2a.binding.jsonrpc,
            .protocol_version = version_text,
        };
        self.input_modes[0] = "text/plain";
        self.output_modes[0] = "text/plain";
        self.tags[0] = "demo";
        self.examples[0] = "message please";
        self.skill_input_modes[0] = "text/plain";
        self.skill_output_modes[0] = "text/plain";
        self.skills[0] = .{
            .id = "echo",
            .name = "Echo",
            .description = "Answers whatever it is asked, in one of three ways.",
            .tags = self.tags[0..1],
            .examples = self.examples[0..1],
            .input_modes = self.skill_input_modes[0..1],
            .output_modes = self.skill_output_modes[0..1],
        };
        self.card = .{
            .name = "echo",
            .description = "Answers a message, works a task, and refuses on request.",
            .supported_interfaces = self.interfaces[0..1],
            .version = version_text,
            .capabilities = .{},
            .default_input_modes = self.input_modes[0..1],
            .default_output_modes = self.output_modes[0..1],
            .skills = self.skills[0..1],
        };
    }

    /// The composed card, whose every list is storage in this struct.
    fn value(self: *const Card) a2a.AgentCard {
        return self.card;
    }
};

/// The agent this example serves.
///
/// The answer borrows this struct, which is the handler contract the library
/// documents: the value is composed here and used before the next call, so
/// nothing is copied and nothing is retained past the call. Every part array
/// an answer names is a field here rather than a temporary in the function
/// that composed it, because the library encodes the answer after the handler
/// has returned and a temporary would be dead by then.
const Agent = struct {
    calls: usize = 0,
    /// The text of the request that is being answered, so the demo can show that
    /// the typed request crossed the socket.
    // SAFETY: `handle` copies the text in and sets `seen_len` from the same count.
    seen: [256]u8 = undefined,
    seen_len: usize = 0,
    // SAFETY: `message` and `task` assign element 0 before the outcome naming it returns.
    parts: [1]a2a.Part = undefined,
    // SAFETY: `task` assigns element 0 before the history entry that borrows it.
    history_parts: [1]a2a.Part = undefined,
    // SAFETY: `task` assigns element 0 before the answer's `history` slice names it.
    history: [1]a2a.Message = undefined,
    /// The normative `google.rpc.ErrorInfo` detail a JSON-RPC error carries for
    /// an A2A-specific code, as the library's own `data` member.
    // SAFETY: `refuse` bufPrints the detail and takes `detail_len` from that call.
    detail: [256]u8 = undefined,
    detail_len: usize = 0,

    // The parameter order is `Handler.call`'s own, and that function-pointer
    // type is a frozen part of the binding's published surface: a handler this
    // example writes has to match the type every other caller's does, so the
    // executor stays where the type puts it rather than moving ahead of the
    // context the same type hands back.
    fn handle(
        ctx: ?*anyopaque,
        // `Handler.call` fixes this order; moving Io would break its callers.
        // ziglint-ignore: Z023
        io: Io,
        request: a2a.SendMessageRequest,
    ) anyerror!a2a_http.Outcome {
        _ = io;
        const self: *Agent = @ptrCast(@alignCast(ctx orelse return error.NoAgent));
        self.calls += 1;
        const text = if (request.message.parts.len == 0) "" else switch (request.message.parts[0].content) {
            .text => |value| value,
            else => "",
        };
        self.seen_len = @min(text.len, self.seen.len);
        @memcpy(self.seen[0..self.seen_len], text[0..self.seen_len]);

        if (std.mem.indexOf(u8, text, "refuse") != null) return self.refuse();
        if (std.mem.indexOf(u8, text, "task") != null) return self.task(request);
        return self.message();
    }

    /// A `Message` answer: the same shape the caller sent, from the other side.
    fn message(self: *Agent) a2a_http.Outcome {
        self.parts[0] = .{ .content = .{ .text = "pong" } };
        return .{ .result = .{ .message = .{
            .message_id = "agent-1",
            .role = .agent,
            .parts = &self.parts,
        } } };
    }

    /// A `Task` answer, with the request in the task's history.
    fn task(self: *Agent, request: a2a.SendMessageRequest) a2a_http.Outcome {
        self.history_parts[0] = .{ .content = .{ .text = self.seen[0..self.seen_len] } };
        self.history[0] = .{
            .message_id = request.message.message_id,
            .role = .user,
            .parts = &self.history_parts,
        };
        self.parts[0] = .{ .content = .{ .text = "working" } };
        return .{ .result = .{ .task = .{
            .id = "task-1",
            .status = .{ .state = .working, .message = self.history[0] },
            .history = self.history[0..1],
        } } };
    }

    /// A refusal, with the `ErrorInfo` detail section 6.2 requires for an
    /// A2A-specific code: six of the nine A2A errors collapse onto `400`, so the
    /// status alone cannot say which one this is.
    fn refuse(self: *Agent) a2a_http.Outcome {
        const reason = a2a.A2aError.unsupported_operation;
        self.detail_len = (std.fmt.bufPrint(
            &self.detail,
            "{{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\"," ++
                "\"domain\":\"{s}\",\"reason\":\"{s}\"}}",
            .{ a2a.error_domain, reason.reason() },
        ) catch return .{ .peer_error = .{
            .code = @backingInt(reason),
            .message = "Unsupported operation",
        } }).len;
        return .{ .peer_error = .{
            .code = @backingInt(reason),
            .message = "Unsupported operation",
            .data = self.detail[0..self.detail_len],
        } };
    }
};

/// Every fact the exchange produced, copied out of the client task.
///
/// A task on the group cannot print, because the one writer belongs to the main
/// task, so the client records what it saw and `main` prints it. Every field is
/// something that crossed a socket.
const Exchange = struct {
    /// The card the client read.
    // SAFETY: `keep` copies the name in and returns the length `cardName` slices with.
    card_name: [64]u8 = undefined,
    card_name_len: usize = 0,
    card_interfaces: usize = 0,
    /// The endpoint the card advertised, formatted whole.
    // SAFETY: `discover` prints into `[0..]` and stores `writer.end` as `endpoint_len`.
    endpoint: [160]u8 = undefined,
    endpoint_len: usize = 0,
    /// The version header the client bound.
    // SAFETY: `discover` prints into `[0..]` and stores `writer.end` as `version_len`.
    version: [8]u8 = undefined,
    version_len: usize = 0,

    /// The typed task answer.
    // SAFETY: `send` keeps the id into it and stores the length `taskId` slices with.
    task_id: [64]u8 = undefined,
    task_id_len: usize = 0,
    task_state: a2a.TaskState = .unspecified,
    task_history: usize = 0,

    /// The typed message answer.
    // SAFETY: `send` keeps the id into it and stores the length `messageId` slices with.
    message_id: [64]u8 = undefined,
    message_id_len: usize = 0,
    // SAFETY: `send` keeps the part text and stores the length `messageText` slices with.
    message_text: [128]u8 = undefined,
    message_text_len: usize = 0,

    /// The JSON-RPC error answer, kept as the peer sent it.
    error_code: i32 = 0,
    // SAFETY: `send` keeps the peer message and stores the length `errorMessage` slices with.
    error_message: [128]u8 = undefined,
    error_message_len: usize = 0,
    // SAFETY: `send` keeps the `data` member and stores the length `errorDetail` slices with.
    error_detail: [256]u8 = undefined,
    error_detail_len: usize = 0,
    error_status: u16 = 0,

    /// The HTTP statuses the three calls were answered on, which is the client's
    /// own report rather than the server's.
    task_status: u16 = 0,
    message_status: u16 = 0,

    /// How many calls the agent handled, and whether either end gave up.
    server_calls: usize = 0,
    client_failed: bool = false,
    server_failed: bool = false,
    expired: bool = false,

    /// Which step ended the exchange and what ended it there, so a failure is
    /// reported as the fact that caused it rather than as an outcome.
    // SAFETY: `note` keeps the stage into it and stores the length `stageText` slices with.
    stage: [24]u8 = undefined,
    stage_len: usize = 0,
    // SAFETY: `note` keeps the reason into it and stores the length `reasonText` slices with.
    reason: [64]u8 = undefined,
    reason_len: usize = 0,

    fn cardName(self: *const Exchange) []const u8 {
        return self.card_name[0..self.card_name_len];
    }

    fn endpointText(self: *const Exchange) []const u8 {
        return self.endpoint[0..self.endpoint_len];
    }

    fn versionText(self: *const Exchange) []const u8 {
        return self.version[0..self.version_len];
    }

    fn taskId(self: *const Exchange) []const u8 {
        return self.task_id[0..self.task_id_len];
    }

    fn messageId(self: *const Exchange) []const u8 {
        return self.message_id[0..self.message_id_len];
    }

    fn messageText(self: *const Exchange) []const u8 {
        return self.message_text[0..self.message_text_len];
    }

    fn errorMessage(self: *const Exchange) []const u8 {
        return self.error_message[0..self.error_message_len];
    }

    fn errorDetail(self: *const Exchange) []const u8 {
        return self.error_detail[0..self.error_detail_len];
    }

    fn stageText(self: *const Exchange) []const u8 {
        return self.stage[0..self.stage_len];
    }

    fn reasonText(self: *const Exchange) []const u8 {
        return self.reason[0..self.reason_len];
    }

    /// Record the step that ended the exchange, and what ended it there.
    ///
    /// A task on the group cannot print, and a failure that is only a flag says
    /// nothing about the wire, so this is the one line the body has for it. The
    /// first cause is kept: whatever the other end failed on afterwards is
    /// this one answering for itself.
    fn note(self: *Exchange, at: []const u8, why: []const u8) void {
        if (self.stage_len != 0) return;
        self.stage_len = Exchange.keep(&self.stage, at);
        self.reason_len = Exchange.keep(&self.reason, why);
    }

    /// Keep a slice the client was handed, which borrows its own buffers.
    fn keep(destination: []u8, value: []const u8) usize {
        const len = @min(value.len, destination.len);
        @memcpy(destination[0..len], value[0..len]);
        return len;
    }
};

/// The endpoint, listened on and ready to be accepted.
///
/// Port zero, and the kernel's choice read back off the listening socket, so two
/// runs of this file cannot collide over a port. The card is written with that
/// port, which is what forces the client to read the card.
const Endpoint = struct {
    // SAFETY: `open` assigns the listening socket before `port` reads its address.
    listener: Io.net.Server = undefined,
    // SAFETY: `open` bufPrints the whole URL into it and `url` borrows that run.
    url_buffer: [96]u8 = undefined,
    url: []const u8 = "",
    /// The origin a client is pointed at: scheme, host and port and nothing
    /// else, so the discovery GET has to build the well-known path itself.
    // SAFETY: `open` bufPrints the origin into it and `origin` borrows that run.
    origin_buffer: [64]u8 = undefined,
    origin: []const u8 = "",

    fn open(self: *Endpoint, io: Io) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.listener = try address.listen(io, .{});
        const chosen = self.port();
        self.url = try std.fmt.bufPrint(&self.url_buffer, "http://127.0.0.1:{d}{s}", .{ chosen, rpc_path });
        self.origin = try std.fmt.bufPrint(&self.origin_buffer, "http://127.0.0.1:{d}", .{chosen});
    }

    fn close(self: *Endpoint, io: Io) void {
        self.listener.deinit(io);
    }

    /// The port the kernel gave out.
    fn port(self: *const Endpoint) u16 {
        return self.listener.socket.address.getPort();
    }
};

/// One end of the exchange: the buffers, and the connection over them.
///
/// The reader and the writer are fields rather than locals in the function that
/// accepts the socket, because `wire.Server` keeps raw pointers to both and a
/// local would dangle before the first request.
const Side = struct {
    // SAFETY: `open` hands this array to the stream reader it assigns below.
    reader_buffer: [4096]u8 = undefined,
    // SAFETY: `open` hands this array to the stream writer it assigns below.
    writer_buffer: [4096]u8 = undefined,
    // SAFETY: `open` assigns it from the accepted stream; no request runs before that.
    stream_reader: Io.net.Stream.Reader = undefined,
    // SAFETY: `open` assigns it from the accepted stream; no request runs before that.
    stream_writer: Io.net.Stream.Writer = undefined,
    // SAFETY: `open` builds it from the two fields above, and no request runs before it.
    http: wire.Server = undefined,

    // SAFETY: `buffers` hands it to `serve`, which reads chunk lengths into it per request.
    transfer: [256]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve`, which fills it before parsing the answer.
    body: [4096]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve` as scratch it decodes into before using.
    envelope_scratch: [2048]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve` as scratch it decodes into before using.
    payload_scratch: [2048]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve`, which encodes the answer into it.
    payload_out: [4096]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve`, which encodes the reply envelope into it.
    envelope_out: [8192]u8 = undefined,
    // SAFETY: `buffers` hands it to `serve` as the base64 run it encodes into.
    base64: [256]u8 = undefined,

    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    parts: [8]a2a.Part = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    artifacts: [2]a2a.Artifact = undefined,
    // SAFETY: `init` points the arena at it; a decoded slot is written before it is read.
    messages: [8]a2a.Message = undefined,
    // SAFETY: `init` points the arena at it; a decoded string is copied in before it is read.
    strings: [16][]const u8 = undefined,
    // SAFETY: `init` points the arena at it; a decoded run is copied in before it is read.
    bytes: [256]u8 = undefined,
    // SAFETY: `init` assigns it over the arrays above, before any call uses them.
    arena: a2a.ContentArena = undefined,

    fn init(self: *Side) void {
        self.arena = a2a.ContentArena.init(
            &self.parts,
            &self.artifacts,
            &self.messages,
            &self.strings,
            &self.bytes,
        );
    }

    fn open(self: *Side, io: Io, stream: Io.net.Stream) void {
        self.stream_reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.stream_writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.http = wire.Server.init(&self.stream_reader.interface, &self.stream_writer.interface);
    }

    fn buffers(self: *Side) a2a_http.ServerBuffers {
        return .{
            .transfer = &self.transfer,
            .body = &self.body,
            .envelope_scratch = &self.envelope_scratch,
            .payload_scratch = &self.payload_scratch,
            .payload_out = &self.payload_out,
            .envelope_out = &self.envelope_out,
            .base64 = &self.base64,
        };
    }
};

/// What the two tasks tell each other, and nothing else.
///
/// A listening socket has no way to be told that no more connections are coming,
/// so the client is the only side that can say a wait for one is safe. Both flags
/// live under the mutex and the condition is what the flags mean, because a
/// signal with no waiter yet is dropped: a client that finishes first must still
/// be seen by a server that has not begun to wait.
const Handoff = struct {
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Read and written under `mutex`, and nowhere else.
    client_done: bool = false,
    /// A connection the kernel has queued in the listener and the server has not
    /// accepted yet.
    connection_queued: bool = false,

    /// The client is finished, whether it succeeded or not, and the server may
    /// hang up.
    fn signalDone(self: *Handoff, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.client_done = true;
        self.condition.signal(io);
    }

    fn isDone(self: *Handoff, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.client_done;
    }

    /// The kernel has the connection, so `accept` returns rather than waits.
    fn announceConnection(self: *Handoff, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.connection_queued = true;
        self.condition.signal(io);
    }

    fn waitConnection(self: *Handoff, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.connection_queued and !self.client_done) {
            self.condition.wait(io, &self.mutex) catch return;
        }
        self.connection_queued = false;
    }
};

/// Serves the well-known card and the advertised endpoint, one connection.
const Serve = struct {
    io: Io,
    listener: *Io.net.Server,
    side: *Side,
    handoff: *Handoff,
    card: a2a.AgentCard,
    target: []const u8,
    agent: *Agent,
    exchange: *Exchange,
    failed: bool = false,

    fn run(self: *Serve) void {
        // The two waits below fail for different reasons and each has its own
        // answer. `serve` waits on a socket this side does not own, and the client
        // closing it is what ends that wait. `accept` waits on a listening
        // socket, which no peer can shut down, so the client announces the
        // connection it opened and only then is the accept a call that returns.
        self.handoff.waitConnection(self.io);
        if (self.handoff.isDone(self.io)) return;
        const connection = self.listener.accept(self.io) catch |err| {
            self.exchange.note("accept", @errorName(err));
            self.failed = true;
            return;
        };
        // `shutdown` before `close`. A close on a socket whose peer still has
        // unread bytes answers with a reset, and the reset discards them, so a
        // client that has not read the reply yet loses it.
        defer {
            // A shutdown that failed changes nothing: `close` below ends the socket anyway.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            connection.shutdown(self.io, .both) catch {};
            connection.close(self.io);
        }
        self.side.open(self.io, connection);

        // One connection serves every request the client makes, and the loop ends
        // on the client's own hang-up rather than on a count of the calls: the
        // reply to the last call is still in flight at that point, and a hang-up
        // that raced it would discard the answer the client has not read yet.
        while (true) {
            const answered = a2a_http.serve(
                self.io,
                &self.side.http,
                self.card,
                self.target,
                .{ .ctx = self.agent, .call = Agent.handle },
                self.side.buffers(),
                &self.side.arena,
            ) catch |err| {
                self.exchange.note("serve", @errorName(err));
                self.failed = true;
                return;
            };
            if (!answered) return;
        }
    }
};

/// Discovers the card, binds the endpoint and sends the three calls.
const Call = struct {
    io: Io,
    /// The one allocator in this example, and the one the `std.http.Client` takes
    /// for its own connection pool. Nothing on the codec path allocates.
    allocator: std.mem.Allocator,
    endpoint: *const Endpoint,
    handoff: *Handoff,
    exchange: *Exchange,
    /// The request the client sends, as a typed value over its own storage.
    // SAFETY: `send` assigns element 0 before the request borrowing it goes out.
    parts: [1]a2a.Part = undefined,
    // SAFETY: `send` assigns it from that part before `sendMessage` is called.
    request: a2a.SendMessageRequest = undefined,

    // SAFETY: `sendBuffers` hands it to the client, which fills it on every call.
    transfer: [256]u8 = undefined,
    // SAFETY: `sendBuffers` hands it to the client, which fills it on every call.
    body: [4096]u8 = undefined,
    // SAFETY: `sendBuffers` hands it to the client as decode scratch, written before read.
    scratch: [2048]u8 = undefined,
    // SAFETY: `sendBuffers` hands it to the client, which encodes the params into it.
    params: [1024]u8 = undefined,
    // SAFETY: `sendBuffers` hands it to the client, which encodes the envelope into it.
    envelope: [2048]u8 = undefined,
    // SAFETY: `sendBuffers` hands it to the client as the base64 run it encodes into.
    base64: [256]u8 = undefined,

    /// The card's own buffers, and they are not the ones above: the binding a
    /// discovery returns is the card's own text, so the array the card was read
    /// into has to outlive every call made through it. One array behind both the
    /// card and the first reply would POST to whatever the reply wrote there.
    // SAFETY: `discover` hands it to the library, which fills it per discovery.
    card_transfer: [256]u8 = undefined,
    // SAFETY: `discover` hands it to the library, which fills it per discovery.
    card_body: [4096]u8 = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_interfaces: [4]a2a.AgentInterface = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_skills: [2]a2a.AgentSkill = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_extensions: [2]a2a.AgentExtension = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_signatures: [2]a2a.AgentCardSignature = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_security_schemes: [2]a2a.SecuritySchemeEntry = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_security_requirements: [2]a2a.SecurityRequirement = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_requirement_entries: [4]a2a.SecurityRequirementEntry = undefined,
    // SAFETY: `init` points the card arena at it; a decoded entry is written before used.
    card_scopes: [4]a2a.OAuthScope = undefined,
    // SAFETY: `init` points the card arena at it; a string is copied in before it is read.
    card_strings: [16][]const u8 = undefined,
    /// Backs the card decode, and any string in it that had to be unescaped.
    // SAFETY: `discover` hands it to the decoder, which unescapes into it before reading.
    card_scratch: [2048]u8 = undefined,
    // SAFETY: `init` assigns it over the arrays above, before any call uses them.
    card_arena: a2a.CardArena = undefined,

    // SAFETY: `init` points the payload arena at it; a decoded slot is written before read.
    payload_parts: [8]a2a.Part = undefined,
    // SAFETY: `init` points the payload arena at it; a decoded slot is written before read.
    payload_artifacts: [2]a2a.Artifact = undefined,
    // SAFETY: `init` points the payload arena at it; a decoded slot is written before read.
    payload_messages: [8]a2a.Message = undefined,
    // SAFETY: `init` points the payload arena at it; a string is copied in before it is read.
    payload_strings: [16][]const u8 = undefined,
    // SAFETY: `init` points the payload arena at it; a run is copied in before it is read.
    payload_bytes: [256]u8 = undefined,
    // SAFETY: `init` assigns it over the arrays above, before any call uses them.
    payload_arena: a2a.ContentArena = undefined,

    /// The borrowed client, and with it the connection this task owns. It is
    /// released at the end of the task rather than at the end of the process, so
    /// the server's `serve` sees a hang-up rather than a wait that never ends.
    // SAFETY: `connect` assigns it, and the `deinit` in `run` only runs after that.
    http: wire.Client = undefined,
    // SAFETY: `discover` assigns it after `connect`, before any call this task makes.
    client: a2a_http.Client = undefined,
    failed: bool = false,

    fn init(self: *Call) void {
        self.card_arena = a2a.CardArena.init(
            &self.card_interfaces,
            &self.card_skills,
            &self.card_extensions,
            &self.card_signatures,
            &self.card_security_schemes,
            &self.card_security_requirements,
            &self.card_requirement_entries,
            &self.card_scopes,
            &self.card_strings,
        );
        self.payload_arena = a2a.ContentArena.init(
            &self.payload_parts,
            &self.payload_artifacts,
            &self.payload_messages,
            &self.payload_strings,
            &self.payload_bytes,
        );
    }

    fn sendBuffers(self: *Call) a2a_http.SendBuffers {
        return .{
            .transfer = &self.transfer,
            .body = &self.body,
            .scratch = &self.scratch,
            .params = &self.params,
            .envelope = &self.envelope,
            .base64 = &self.base64,
        };
    }

    /// Record why this task is giving up, and report the failure.
    ///
    /// Every path out of a client call is a `false` this returns rather than a
    /// `return false` of its own, so no way out of this task can leave the body
    /// with a flag and nothing to say.
    fn giveUp(self: *Call, stage: []const u8, why: []const u8) bool {
        self.exchange.note(stage, why);
        return false;
    }

    fn run(self: *Call) void {
        // The signal covers every path out of this task, not only the one that
        // succeeds: a failure before the connection is opened leaves the server
        // waiting for one, and a failure after it leaves the server waiting for a
        // request on a socket this task is about to close.
        defer self.handoff.signalDone(self.io);
        defer self.http.deinit();
        if (!self.connect()) {
            self.failed = true;
            return;
        }
        if (!self.discover()) {
            self.failed = true;
            return;
        }
        if (!self.sendPlannedCalls()) {
            self.failed = true;
            return;
        }
    }

    /// Open the one connection this task owns.
    ///
    /// The connection is announced to the server once `connectTcp` has returned,
    /// because from then on the kernel has it queued and the server's `accept`
    /// returns it rather than waiting. That is what keeps that accept from being
    /// a wait this task could outlive.
    fn connect(self: *Call) bool {
        self.http = .{ .allocator = self.allocator, .io = self.io };
        const host = Io.net.HostName.init("127.0.0.1") catch
            return self.giveUp("connect", "the loopback host name is not one");
        // `connectTcp` hands the connection over as one this task owns: the
        // pool counts it as in use until it is released, and the discovery GET
        // below is the request that takes it from there.
        const connection = self.http.connectTcp(host, self.endpoint.port(), .plain) catch |err|
            return self.giveUp("connect", @errorName(err));
        self.http.connection_pool.release(connection, self.io);
        self.handoff.announceConnection(self.io);
        return true;
    }

    /// Read the card, bind the endpoint it publishes, and record what it said.
    fn discover(self: *Call) bool {
        // The card is read into its own buffers, and the binding this returns is
        // that card's own text: the array the card went into has to outlive every
        // call made through it, so it is not the array a reply is read into.
        const origin = std.Uri.parse(self.endpoint.origin) catch
            return self.giveUp("discover", "the origin is not a URI");
        const found = a2a_http.discover(self.io, &self.http, origin, .{
            .transfer = &self.card_transfer,
            .body = &self.card_body,
            .scratch = &self.card_scratch,
        }, &self.card_arena) catch |err| return self.giveUp("discover", @errorName(err));

        self.exchange.card_name_len = Exchange.keep(&self.exchange.card_name, found.card.name);
        self.exchange.card_interfaces = found.card.supported_interfaces.len;
        {
            var writer: Io.Writer = .fixed(self.exchange.endpoint[0..]);
            writer.print("{f}", .{found.binding.uri.fmt(.{
                .scheme = true,
                .authority = true,
                .path = true,
                .query = true,
            })}) catch return self.giveUp("discover", "the endpoint did not fit");
            self.exchange.endpoint_len = writer.end;
        }
        {
            // The version the client binds, read from the binding rather than
            // from this example's own constant: the two are cross-checked at
            // compile time above, and printing the one the client formats into
            // the header is printing what went on the wire.
            var writer: Io.Writer = .fixed(self.exchange.version[0..]);
            writer.print("{d}.{d}", .{
                a2a_http.version.major,
                a2a_http.version.minor,
            }) catch return self.giveUp("discover", "the version did not fit");
            self.exchange.version_len = writer.end;
        }

        self.client = a2a_http.Client.init(self.io, &self.http, found.binding) catch |err|
            return self.giveUp("discover", @errorName(err));
        return true;
    }

    /// Send the three planned calls, recording what came back.
    ///
    /// A task, asked for and answered as one; a message, which is the other arm
    /// of the same `oneof`; and a refusal, which is neither arm: it is a
    /// JSON-RPC error and it arrives with an HTTP status beside it.
    fn sendPlannedCalls(self: *Call) bool {
        for (asks) |ask| {
            if (!self.send(ask.text, ask.arm)) return false;
        }
        return true;
    }

    /// One unary `SendMessage`, with the answer recorded for the arm that was
    /// asked for. A peer that answered a task with a message, or a refusal with
    /// either, fails the call rather than being recorded under the wrong heading.
    fn send(self: *Call, text: []const u8, arm: Arm) bool {
        self.parts[0] = .{ .content = .{ .text = text } };
        self.request = .{ .message = .{
            .message_id = "m-1",
            .role = .user,
            .parts = &self.parts,
        } };

        const reply = self.client.sendMessage(
            self.io,
            self.request,
            self.sendBuffers(),
            &self.payload_arena,
        ) catch |err| return self.giveUp("send", @errorName(err));

        switch (arm) {
            .task => {
                self.exchange.task_status = @backingInt(reply.status);
                const result = switch (reply.outcome) {
                    .result => |value| value,
                    .peer_error => return self.giveUp(@tagName(arm), "refused the call"),
                };
                const value = switch (result) {
                    .task => |task| task,
                    .message => return self.giveUp(@tagName(arm), "answered with a message"),
                };
                self.exchange.task_id_len = Exchange.keep(&self.exchange.task_id, value.id);
                self.exchange.task_state = value.status.state;
                self.exchange.task_history = if (value.history) |history| history.len else 0;
                return true;
            },
            .message => {
                self.exchange.message_status = @backingInt(reply.status);
                const result = switch (reply.outcome) {
                    .result => |value| value,
                    .peer_error => return self.giveUp(@tagName(arm), "refused the call"),
                };
                const value = switch (result) {
                    .message => |message| message,
                    .task => return self.giveUp(@tagName(arm), "answered with a task"),
                };
                self.exchange.message_id_len = Exchange.keep(&self.exchange.message_id, value.message_id);
                self.exchange.message_text_len = Exchange.keep(
                    &self.exchange.message_text,
                    if (value.parts.len == 0) "" else switch (value.parts[0].content) {
                        .text => |part| part,
                        else => "",
                    },
                );
                return true;
            },
            .peer_error => {
                const object = switch (reply.outcome) {
                    .peer_error => |value| value,
                    .result => return self.giveUp(@tagName(arm), "answered, not refused"),
                };
                self.exchange.error_status = @backingInt(reply.status);
                self.exchange.error_code = object.code;
                self.exchange.error_message_len = Exchange.keep(&self.exchange.error_message, object.message);
                self.exchange.error_detail_len = Exchange.keep(&self.exchange.error_detail, object.data orelse "");
                return true;
            },
        }
    }
};

/// The two supervised branches and the answer each of them gives.
///
/// `Io.Select` carries one slot per branch and writes only the branch that
/// finished, so the result is a tagged union with a field for each tag. Both
/// payloads mean the same thing: whether the deadline is what ended the wait.
const Answers = union(enum) {
    /// The group drained before the budget.
    group: bool,
    /// The budget ran out with the group still going.
    deadline: bool,
};

/// The budget the whole exchange runs under.
///
/// A demo that can hang is a demo nobody runs twice, and the wait it could hang
/// in is a socket read. So the group is waited on with a deadline, and whichever
/// of the two finished first the other is cancelled: a cancelation that reaches
/// the task awaiting the group unwinds the group with it, so the two endpoints
/// stop at their next cancelation point rather than being left behind.
const budget: Io.Duration = .fromSeconds(20);

fn joinGroup(io: Io, group: *Io.Group) bool {
    // The join is best effort on purpose: this is the branch that reports the
    // group having drained, and its own answer is the fact it returns whatever
    // the await said. A cancelation that arrives here means the other branch
    // finished first, which `supervise` already knows, so there is nothing this
    // catch could add and no state left to record it in.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    group.await(io) catch {};
    return false;
}

fn deadlineReached(io: Io, limit: Io.Duration) bool {
    // A sleep this task cannot finish still reports the deadline, because the
    // only thing that can cancel it is the group having finished first. The
    // cancelation is the answer, not a fault: `supervise` reads the branch that
    // won, so discarding the error loses nothing.
    // gate-reviewed-zlint-next-statement: suppressed-errors
    // ziglint-ignore: Z026
    // zwanzig-disable-next-line: empty-catch-engine
    std.Io.sleep(io, limit, .awake) catch {};
    return true;
}

/// Wait for the group, bounded by the budget. True when the deadline is what
/// ended the wait.
///
/// `Io.Group` has one awaiter and one canceller at a time, and this is the only
/// place either happens: the select's group task is the awaiter, and cancelling
/// it is the canceller.
fn supervise(io: Io, group: *Io.Group, limit: Io.Duration) Io.ConcurrentError!bool {
    var results: [2]Answers = undefined;
    var select: Io.Select(Answers) = .init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.group, joinGroup, .{ io, group });
    try select.concurrent(.deadline, deadlineReached, .{ io, limit });
    // `catch` and not a bare return: the select owns two tasks, and the one
    // that did not answer is still running. Leaving it behind would be the
    // one way this example could outlive its own exchange, so the same
    // cancellation that ends the wait in the ordinary case ends it here too.
    const answer = select.await() catch {
        return false;
    };
    return switch (answer) {
        .group => |expired| expired,
        .deadline => |expired| expired,
    };
}

/// Run the whole exchange: one listener, one connection, four requests.
fn run(allocator: std.mem.Allocator, io: Io) !Exchange {
    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    // The card is composed into storage this call owns rather than returned by
    // a function that borrowed it: the server encodes it from a task, long
    // after a frame that composed one would be gone.
    var published: Card = .{};
    published.compose(endpoint.url);
    var agent: Agent = .{};
    var server_side: Side = .{};
    var handoff: Handoff = .{};
    var exchange: Exchange = .{};
    server_side.init();

    var serve: Serve = .{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handoff = &handoff,
        .card = published.value(),
        .target = rpc_path,
        .agent = &agent,
        .exchange = &exchange,
    };
    var call: Call = .{
        .io = io,
        .allocator = allocator,
        .endpoint = &endpoint,
        .handoff = &handoff,
        .exchange = &exchange,
    };
    call.init();

    // One group drives both ends. Two would deadlock: the client blocks waiting
    // for an answer only the server's task can produce.
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Serve.run, .{&serve});
    try group.concurrent(io, Call.run, .{&call});
    // The select owns the join and deadline; an early exit cancels both.
    exchange.expired = try supervise(io, &group, budget);

    exchange.server_calls = agent.calls;
    exchange.server_failed = serve.failed;
    exchange.client_failed = call.failed;
    return exchange;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    // Whether this run's last flush has already been made, so the report is
    // written once and a flush that has already failed is not asked again.
    var final_flush_attempted = false;
    errdefer {
        if (!final_flush_attempted) {
            // Best effort, and only while `main` unwinds. The three failure
            // paths below print what went wrong and return an error, so the
            // reason the reader needs is still in this buffer when that
            // happens; the error that got here is the one this must not
            // replace with a fault of its own.
            // gate-reviewed-zlint-next-statement: suppressed-errors
            // ziglint-ignore: Z026
            // zwanzig-disable-next-line: empty-catch-engine
            stdout.flush() catch {};
        }
    }

    try out.print("zig-agent-protocols a2a 1.0 example\n\n", .{});
    try out.print("  protocol  A2A {s}, JSON-RPC over HTTP\n", .{version_text});
    try out.print("  endpoint  the agent advertises {s}\n", .{rpc_path});

    const exchange = try run(init.gpa, io);

    if (exchange.expired) {
        try out.print("\nthe exchange did not finish inside its budget\n", .{});
        return error.ExchangeFailed;
    }
    if (exchange.client_failed or exchange.server_failed) {
        if (exchange.stage_len == 0) {
            try out.print("\nthe exchange failed\n", .{});
        } else {
            try out.print("\nthe exchange failed at {s}: {s}\n", .{
                exchange.stageText(),
                exchange.reasonText(),
            });
        }
        return error.ExchangeFailed;
    }
    // Every planned call really was answered, and the agent really handled all
    // three: the counter is the server's own.
    if (exchange.server_calls != asks.len) {
        try out.print("\nthe agent handled {d} of {d} call(s)\n", .{
            exchange.server_calls,
            asks.len,
        });
        return error.ExchangeFailed;
    }

    try out.print("\n-- 1. discovery --\n", .{});
    try out.print("  card      {s}, {d} supported interface(s)\n", .{
        exchange.cardName(),
        exchange.card_interfaces,
    });
    try out.print("  selected  {s}\n", .{exchange.endpointText()});
    try out.print("  version   A2A-Version: {s}, bound from the card\n", .{exchange.versionText()});

    try out.print("\n-- 2. a task --\n", .{});
    try out.print("  request   \"{s}\"\n", .{asks[0].text});
    try out.print("  answer    task {s} in {s} with {d} history message(s), HTTP {d}\n", .{
        exchange.taskId(),
        @tagName(exchange.task_state),
        exchange.task_history,
        exchange.task_status,
    });

    try out.print("\n-- 3. a message --\n", .{});
    try out.print("  request   \"{s}\"\n", .{asks[1].text});
    try out.print("  answer    message {s} saying \"{s}\", HTTP {d}\n", .{
        exchange.messageId(),
        exchange.messageText(),
        exchange.message_status,
    });

    try out.print("\n-- 4. a refusal --\n", .{});
    try out.print("  request   \"{s}\"\n", .{asks[2].text});
    try out.print("  answer    JSON-RPC error {d} \"{s}\", HTTP {d}\n", .{
        exchange.error_code,
        exchange.errorMessage(),
        exchange.error_status,
    });
    try out.print("  detail    {s}\n", .{exchange.errorDetail()});

    try out.print("\nthe agent handled {d} call(s) and every one was typed\n", .{exchange.server_calls});

    // The report reaches the descriptor on this one flush: every line above
    // was still buffered, so a reader given none of them was told nothing
    // about a run that finished. That is this run's exit status rather than a
    // note nobody is left to read. The flag is set before the flush runs, so
    // the unwinding path above does not attempt this same flush again.
    final_flush_attempted = true;
    try stdout.flush();
}

// --- Tests ----------------------------------------------------------------------

test "the exchange discovers the card, and a task, a message and a refusal each arrive typed" {
    const exchange = try run(testing.allocator, testing.io);
    try testing.expect(!exchange.expired);
    try testing.expect(!exchange.client_failed);
    try testing.expect(!exchange.server_failed);

    // The card was read at the well-known path and the endpoint came from
    // it, query and all: a hard-coded path would pass on a port nothing
    // published.
    try testing.expectEqualStrings("echo", exchange.cardName());
    try testing.expectEqual(@as(usize, 1), exchange.card_interfaces);
    try testing.expectEqualStrings("1.0", exchange.versionText());
    try testing.expect(std.mem.startsWith(u8, exchange.endpointText(), "http://127.0.0.1:"));
    try testing.expect(std.mem.endsWith(u8, exchange.endpointText(), rpc_path));

    // The task arm, read as a task.
    try testing.expectEqualStrings("task-1", exchange.taskId());
    try testing.expectEqual(a2a.TaskState.working, exchange.task_state);
    try testing.expectEqual(@as(usize, 1), exchange.task_history);
    try testing.expectEqual(@as(u16, 200), exchange.task_status);

    // The message arm, read as a message, with its own members intact.
    try testing.expectEqualStrings("agent-1", exchange.messageId());
    try testing.expectEqualStrings("pong", exchange.messageText());
    try testing.expectEqual(@as(u16, 200), exchange.message_status);

    // The refusal is a JSON-RPC error and not a result, and it carries the
    // normative detail that tells it apart from the other A2A errors that
    // share its status.
    try testing.expectEqual(
        @backingInt(a2a.A2aError.unsupported_operation),
        exchange.error_code,
    );
    try testing.expectEqualStrings("Unsupported operation", exchange.errorMessage());
    try testing.expectEqual(
        a2a.A2aError.unsupported_operation.httpStatus(),
        exchange.error_status,
    );
    try testing.expect(std.mem.indexOf(u8, exchange.errorDetail(), a2a.error_domain) != null);
    try testing.expect(std.mem.indexOf(u8, exchange.errorDetail(), "UNSUPPORTED_OPERATION") != null);

    try testing.expectEqual(asks.len, exchange.server_calls);
}

test "a client that never connects leaves the server nothing to wait for" {
    // The first of the two ways this example could hang: a client that
    // failed before it opened a socket would leave the server parked in
    // `accept` with nothing to accept, and the group would never drain, so
    // the failure would never be reported.
    const io = testing.io;
    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    server_side.init();
    var agent: Agent = .{};
    var handoff: Handoff = .{};
    var published: Card = .{};
    published.compose(endpoint.url);
    var exchange: Exchange = .{};
    var serve: Serve = .{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handoff = &handoff,
        .card = published.value(),
        .target = rpc_path,
        .agent = &agent,
        .exchange = &exchange,
    };

    // The whole client task, minus the connect: what the server hears is the
    // flag, and it is set before the server ever begins to wait.
    handoff.signalDone(io);
    serve.run();

    try testing.expectEqual(@as(usize, 0), agent.calls);
    try testing.expect(!serve.failed);
}

test "a client that stops after its first call leaves the server nothing to wait for" {
    // The other way: the connection went back to the client's pool instead of
    // closing, so the server sat waiting for a request that was never coming.
    // The client releases its `std.http.Client` and sets the flag on the way
    // out, and the server stops on each of them.
    const io = testing.io;
    var endpoint: Endpoint = .{};
    try endpoint.open(io);
    defer endpoint.close(io);

    var server_side: Side = .{};
    server_side.init();
    var agent: Agent = .{};
    var handoff: Handoff = .{};
    var published: Card = .{};
    published.compose(endpoint.url);
    var exchange: Exchange = .{};
    var serve: Serve = .{
        .io = io,
        .listener = &endpoint.listener,
        .side = &server_side,
        .handoff = &handoff,
        .card = published.value(),
        .target = rpc_path,
        .agent = &agent,
        .exchange = &exchange,
    };
    var call: Call = .{
        .io = io,
        .allocator = testing.allocator,
        .endpoint = &endpoint,
        .handoff = &handoff,
        .exchange = &exchange,
    };
    call.init();

    // `Call.run` with the calls after the first left out, and with the
    // signalling where `Call.run` puts it. Discovery is still part of it: the
    // endpoint comes from the card, so a client that skipped it would have no
    // endpoint to call rather than one call of three.
    const One = struct {
        call: *Call,

        const Self = @This();

        fn run(self: *Self) void {
            defer self.call.handoff.signalDone(self.call.io);
            defer self.call.http.deinit();
            if (!self.call.connect()) {
                self.call.failed = true;
                return;
            }
            if (!self.call.discover()) {
                self.call.failed = true;
                return;
            }
            if (!self.call.send("task please", .task)) self.call.failed = true;
        }
    };
    var one: One = .{ .call = &call };

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Serve.run, .{&serve});
    try group.concurrent(io, One.run, .{&one});
    try testing.expect(!(try supervise(io, &group, budget)));

    try testing.expect(!call.failed);
    try testing.expect(!serve.failed);
    // One call of the three this example plans was answered, and the count
    // says one.
    try testing.expectEqual(@as(usize, 1), agent.calls);
    try testing.expect(agent.calls < asks.len);
    try testing.expectEqualStrings("task-1", exchange.taskId());
}
