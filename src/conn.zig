//! A JSON-RPC 2.0 connection, driven by an `Io`.
//!
//! The codec decodes bytes. This drives them: it frames them, matches a
//! response to the request that asked for it, and dispatches what arrives from
//! the peer. Everything above it — MCP, ACP, the mcp-over-acp binding — is a
//! thin layer of method names and negotiation on top of this.
//!
//! ## The shape of the problem
//!
//! A connection is bidirectional and concurrent. The caller issues requests and
//! blocks on their answers; the peer issues requests of its own and expects
//! answers to those; notifications flow both ways with no answer at all. One
//! reader therefore has to sort each inbound frame into one of four cases, and
//! the three that are not "a response I asked for" must not block, or a peer
//! waiting on its own request would deadlock against us.
//!
//! ## A handler must not block
//!
//! Handlers run on the reader task, inline. A handler that makes an outbound
//! call on the same connection deadlocks: the reader that would deliver that
//! call's response is the very task now waiting for it. A handler that needs
//! to call back must copy the frame, spawn its own task, and use a connection
//! of its own. This is the ordinary structured-concurrency rule, and the
//! alternative — spawning handlers here — would need the frame copied out of
//! the framer's buffer, which is the one buffer this layer refuses to allocate.
//!
//! ## The response that belongs to nobody
//!
//! A response can name no outstanding call, and it arrives here three ways: a
//! `null` id, which JSON-RPC 2.0 requires where the id could not be
//! determined from the Request — a Parse error, or an Invalid Request for a
//! batch or for a value that is not a request object; a string id, which is
//! legal on the wire while this connection allocates its own ids as integers;
//! and an id naming a call that has already returned.
//! [`setOrphanHandler`] is where all three are told: it runs inline on the
//! reader task, is handed the decoded [`jsonrpc.Message`], and returns
//! nothing, because there is no id to answer on and nothing this connection
//! could usefully say back. [`OrphanHandler`] says why it is one hook and not
//! three, and what it is not.
//!
//! The third of the three is the one that is not a peer's mistake.
//! PROTOCOLS.md 4.4 makes `subscriptions/listen` a single long-lived response
//! stream, `call` returns on its first response, and so every response after
//! that one has no call behind it: the scan in `deliver` finds no slot and the
//! frame used to leave the connection having been seen by nobody at all. It is
//! told now, and that is the whole of what is bought — [`OrphanHandler`] says
//! the three things a caller still cannot do with what it is handed.
//!
//! ## Four regions, and why no two of them may share a byte
//!
//! A handler is handed two buffers and they are not interchangeable: the frame
//! is decoded into the first, and the answer is written into the second. One
//! buffer cannot serve both, because the escape offset `json.Reader` keeps is
//! per reader and not per buffer. A reader decoding a string carrying an escape
//! starts at offset 0 again, so a handler that decodes into the region it
//! writes its answer into has the writer's first bytes land on the decoded
//! name it is about to compare. That is a wrong answer rather than an error,
//! and it is silent, which is the only kind of fault worth a pair of names.
//!
//! The framer's buffer is a third region live at the same moment. The slice a
//! frame is decoded from is a window on it, so an escape unescaped into
//! `decode_scratch` can land on the very bytes being read — the same silence,
//! arrived at from the other side.
//!
//! The pending table is a fourth, and the one overlap that is worse than a
//! wrong answer: `claim` writes a slot from the task that called while the
//! reader task writes the framer, so a caller that carved one array into both
//! gets two tasks writing the same bytes at once.
//!
//! [`Conn.init`] refuses every one of those pairs, and refuses a buffer with
//! no room, because all of them are wiring faults a caller cannot see from a
//! peer.
//!
//! ## Ending a connection
//!
//! [`Conn.close`] marks the connection dead, releases every task waiting in
//! [`Conn.call`], and stops the reader at its next frame boundary. What it
//! cannot do is interrupt a read already blocked on a socket, so the caller
//! still has to shut the transport down and then close it, and still has to
//! await or cancel the group its reader was spawned on. The connection owns
//! the reader's decision to stop; the caller owns the reader's task.
//!
//! ## Allocation
//!
//! `ARCHITECTURE.md` section 4 lets the runtime take an allocator where its
//! state is genuinely dynamic, and the one structure here that would qualify
//! is the pending-request table. Nothing here takes one. That table is a
//! caller-supplied `[]Slot` whose length is the caller's own answer to the
//! question a growing table would ask, and everything else is a buffer the
//! caller hands over: [`Conn.init`] takes the frame buffer, the pending table
//! and the two handler regions, and `call` takes the encode buffer and the
//! result buffer. So the path from bytes to a decoded message allocates
//! nothing, and [`Conn`] carries no allocator.
//!
//! The table is bounded rather than a map because that is what makes
//! exhaustion reportable. A call that finds every slot taken returns
//! [`error.TooManyPending`] having sent nothing and leaves the connection
//! usable. A map would grow instead, because a peer can open calls faster
//! than we answer them, and the bound a caller can check would be gone.

const std = @import("std");
const framing = @import("framing.zig");
const json = @import("json.zig");
const jsonrpc = @import("jsonrpc.zig");
const root = @import("root.zig");

const Io = std.Io;

/// What the connection can be asked to do.
///
/// Deliberately not `DecodeError`: a frame that will not fit, a closed pipe
/// and a peer that answers with an error are transport and session conditions,
/// and folding them into the wire error set would let a caller mistake a dead
/// socket for a peer speaking a protocol this library does not implement.
pub const Error = error{
    /// A write or flush failed. Delivery may be partial; the connection is
    /// marked dead and cannot be reused.
    Transport,
    /// The waiting call was canceled. Its slot is released; the connection
    /// stays usable. The request may already have executed at the peer.
    Canceled,
    /// The connection closed before an answer arrived. Local close, peer EOF
    /// and transport read failure all reach this condition.
    ConnectionClosed,
    /// More outstanding requests than the caller's table has slots. Nothing
    /// was sent, so the caller's id sequence is untouched.
    TooManyPending,
    /// An inbound response did not fit `call`'s result buffer. The request was
    /// sent and may have executed; the slot is released and no body is returned.
    ResponseTooLarge,
    /// A locally encoded message did not fit its output buffer. Nothing is
    /// sent; output bytes may be dirty. A call's reserved id is not reused.
    EncodeBufferTooSmall,
    /// A constructed message has invalid UTF-8, invalid raw JSON or an invalid
    /// JSON-RPC field combination. Nothing is sent; growing a buffer cannot fix it.
    InvalidMessage,
    /// A frame did not fit the caller's frame buffer.
    FrameTooLarge,
    /// The message carries a raw newline, so writing it would split one
    /// message into two the peer cannot decode. The transport is healthy and
    /// stays usable, but these same bytes fail the same way however often
    /// they are sent, so the caller must fix the message rather than retry
    /// it. `params` is spliced in verbatim, so a newline in a caller's own
    /// JSON reaches here.
    Framing,
    /// A buffer the connection was handed has no room, so the connection cannot
    /// work at all: a zero frame buffer refuses every frame, a zero pending
    /// table fails every call, and a zero decode or answer region fails the
    /// first thing that needs it.
    ///
    /// Reported by `init` rather than at the first message, because a caller
    /// with no peer to blame has nothing else to go on.
    UnusableBuffer,
    /// Two of the regions the connection was handed share a byte.
    ///
    /// The one fault the pair of names exists to make impossible, and the one
    /// a caller cannot see: the connection still runs, and the answers it
    /// writes are wrong.
    OverlappingBuffers,
    /// The caller used the connection after it closed.
    Closed,
};

/// What a peer answered to a request.
///
/// Copies share the caller's result bytes. Keep that storage alive and do not
/// reuse it while reading this response; no cleanup or allocation is owned here.
pub const Response = struct {
    /// The `result` member as raw JSON when the peer answered, or the whole
    /// `error` object re-serialised into this buffer when the peer refused:
    /// `code`, `message`, and `data` when the peer sent one. Borrows the
    /// caller's result buffer.
    body: []const u8,
    /// The JSON-RPC error code, or null when the call succeeded.
    error_code: ?i32 = null,

    /// Whether the peer refused the call rather than answering it.
    ///
    /// `error_code` is null exactly when this is false, so a caller that
    /// checks it never has to know the field is nullable. Read this before
    /// `body`: a peer error arrives as a successful return carrying the
    /// `error` member in `body`, so a caller that reads only `body` reports a
    /// refusal as a result and calls a tool failure a success.
    pub fn failed(self: Response) bool {
        return self.error_code != null;
    }
};

/// A handler for a request or notification from the peer.
///
/// It is handed two regions and they are not interchangeable. `decode_scratch`
/// is where the frame may be decoded into, and `answer` is where the reply is
/// written. A handler that decodes into the second has the writer's first bytes
/// land on the value it is about to read, because the escape offset
/// `json.Reader` keeps is per reader and not per buffer; see the module doc.
///
/// The answer may borrow either region. The connection writes it out before it
/// reads the next frame, so either is live for exactly as long as it is needed.
///
/// Returning null means "no answer", which is correct for a notification
/// and leaves a peer's request unanswered. An error is not a refusal: a
/// request that returns one is answered with an internal error, because a
/// peer left waiting on a request that already arrived is worse than an
/// answer it did not want. See the module doc for why this runs inline.
///
/// The function and `ctx` are borrowed. Keep the context at a stable address
/// through its last invocation; null `ctx` is passed through unchanged. A null
/// function declines all frames. Calls run synchronously on the one pump task.
/// `frame` borrows the framer and is valid only during this invocation;
/// `decode_scratch` and `answer` borrow Config storage and must not be retained.
/// Do not reenter `call` or `pump` on this connection. A returned answer must
/// stay readable through the following synchronous write; it may borrow either
/// supplied region or other storage that the callback owner keeps alive.
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (
        ctx: ?*anyopaque,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) Error!?[]const u8 = null,

    fn invoke(
        self: Handler,
        frame: []const u8,
        decode_scratch: []u8,
        answer: []u8,
    ) Error!?[]const u8 {
        const func = self.call orelse return null;
        return func(self.ctx, frame, decode_scratch, answer);
    }
};

/// Told about a response that named no outstanding call.
///
/// One event, three frames. A `null` id, which is what JSON-RPC 2.0 requires
/// where the id could not be determined from the Request. A string id, which
/// is legal on the wire while this connection allocates its own ids as
/// integers. And an id naming a call that has already returned, which is the
/// ordinary shape of the second and every later response on a
/// `subscriptions/listen` stream: PROTOCOLS.md 4.4 makes that one long-lived
/// response stream, `call` returns on its first, and each response after it
/// has no call left behind it. Each of the three left this connection having
/// been seen by nobody: the scan found no slot and fell through, and the
/// `null` id returned before it. `route` is the only other place a decoded
/// frame could go, so a frame that matched no call was the last place this
/// layer could lose one.
///
/// It is one hook and not three because the three frames mean the same thing
/// to whoever is reading them: the peer sent a response and nothing was
/// waiting for it. One per case would make an application that wants all
/// three install all three, and a caller reading one would not see the frames
/// the other two were given. It is also the whole of the hook that covered
/// only the `null` id, which this replaces rather than sits beside: that case
/// is one of these three, and a second hook for it would tell one frame twice
/// over to whoever installed both. The decoded message keeps the cases apart
/// — it is handed whole, so `id_null` says which shape arrived, `id` says what
/// the peer named, and `rpc_error` against `result` says whether it refused
/// or answered — and a caller switches on one message rather than assembling
/// a picture out of three callbacks.
///
/// It is a hook of its own rather than a fourth case for [`Handler`]. A
/// handler is handed a frame and returns the answer to it, and none of these
/// frames has an answer: there is no id to answer on, so an answer written
/// here would be a response sent in answer to a response. They are not a
/// request or a notification either, so a handler typed against
/// [`jsonrpc.Request`] would have to decline all three on every path, which is
/// the shape that made them invisible in the first place.
///
/// **It is not a stream reader, and the frames it is handed do not make it
/// one.** There is no `Conn.stream`, and the three things one would have to
/// answer are all unanswered here on purpose.
///
/// - **Where a value stays valid.** Message strings borrow the frame or decode
///   scratch; raw JSON lexemes borrow the frame. Both are valid only during
///   the callback. Copy bytes into independent storage to retain them.
/// - **What a slow consumer does.** The callback runs synchronously and blocks
///   the pump; no queue, backpressure buffer or concurrent delivery is added.
/// - **When it stops.** Nothing marks an end. A consumer cannot tell a
///   subscription the peer finished from a peer that hung up from a
///   connection this one closed, because the next thing to arrive is either
///   another message or silence, and silence is all three at once.
///
/// So the hook makes a lost response visible, which is the precondition for
/// the rest of it, and no more than that. A caller that needs a stream copies
/// the frames it wants into a buffer it owns, counts them, and says how it
/// expects the stream to end — none of which this connection does for it.
///
/// Runs inline on the reader task and takes the rule a handler takes: it must
/// not make an outbound call on this connection, because the reader that would
/// deliver that answer is the very task now waiting for it. The pending table
/// is unlocked before it runs, so a consumer that blocks blocks the reader
/// and the reader is the only thing that can deliver it anything further.
///
/// The function and optional `ctx` are borrowed until the last invocation.
/// Keep the context alive at a stable address; null is passed through. A null
/// function drops unmatched responses. The callback may read synchronized
/// metadata or close the connection, but must not reenter `call` or `pump`.
pub const OrphanHandler = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque, message: jsonrpc.Message) void = null,

    fn invoke(self: OrphanHandler, message: jsonrpc.Message) void {
        const func = self.call orelse return;
        func(self.ctx, message);
    }
};

/// The answer to `request` carrying `result`, written into `out`.
///
/// The slice returned borrows `out`, and it is what a [`Handler`] hands back
/// to have its connection write it. A result is written in the `result`
/// member and a refusal in the `error` member, and the two are separate
/// functions because a builder that took one could not tell which was meant.
///
/// `result` is spliced verbatim, the way `Conn.call` splices caller `params`.
/// A caller that hands a refusal object here writes it inside a result, and
/// the peer reads a failure as an answer; the framing cannot see that, because
/// it is a well-formed result member carrying the caller's own text.
///
/// Inputs must stay readable for this call and must not overlap `out`.
/// `InvalidMessage` rejects an invalid request/result; `EncodeBufferTooSmall`
/// reports local storage shortage. Either failure returns no slice and may
/// leave dirty output bytes. No I/O, blocking or allocation occurs here.
pub fn respond(request: jsonrpc.Request, result: []const u8, out: []u8) Error![]const u8 {
    var writer = json.Writer.init(out);
    jsonrpc.encodeResponse(request, result, null, &writer) catch |err| return encodeFailure(err);
    return writer.written();
}

/// The answer to `request` carrying `object` as its error, written into `out`.
///
/// Separate from [`respond`] so a refusal is a value a caller passes here and
/// never a member a builder has to be told to emit. `object.data` is carried
/// when it is set, and omitted when it is not.
///
/// The request, message text and raw `data` must be valid and must not overlap
/// `out`; all are read during this call only. The returned slice borrows `out`
/// until it is reused. Errors and dirty-output residue match `respond`.
pub fn errorResponse(request: jsonrpc.Request, object: jsonrpc.Error, out: []u8) Error![]const u8 {
    var writer = json.Writer.init(out);
    jsonrpc.encodeResponse(request, null, object, &writer) catch |err| return encodeFailure(err);
    return writer.written();
}

/// The `-32601` answer for a method this peer does not have, written into
/// `out`.
///
/// The code is `jsonrpc`'s own and the message is the name PROTOCOLS.md 3.1
/// gives it, so a session layer gates a method and answers it with one call
/// rather than assembling the frame itself.
pub fn methodNotFound(request: jsonrpc.Request, out: []u8) Error![]const u8 {
    return errorResponse(request, .{
        .code = @backingInt(jsonrpc.StandardError.method_not_found),
        .message = "Method not found",
    }, out);
}

/// Keep local storage shortage distinct from an invalid constructed message.
fn encodeFailure(err: root.EncodeError) Error {
    return switch (err) {
        error.BufferTooSmall => error.EncodeBufferTooSmall,
        error.InvalidField, error.UnknownTag => error.InvalidMessage,
    };
}

/// Whether two caller-supplied regions share a byte.
///
/// Pointer arithmetic rather than a content comparison, because the question is
/// where the bytes are and not what is in them. An empty region overlaps
/// nothing, because its end is its start, which is why `init` refuses an empty
/// region on its own account rather than through this.
///
/// A shared byte is fatal rather than untidy because the escape offset
/// `json.Reader` keeps is per reader and not per buffer. A second reader
/// decoding a string with an escape starts at offset 0 again, so it writes
/// over whatever the first left there: a value the first borrowed is compared
/// with bytes the second produced, and the answer is wrong rather than an error.
///
/// `init` is not the only caller. A session layer that hands a handler two of
/// its own regions checks them through here too, so one rule covers the
/// connection's pair and a session's.
pub fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start < b_start + b.len and b_start < a_start + a.len;
}

/// One outstanding request awaiting its answer.
///
/// Storage belongs to the caller but Conn owns its live state under its mutex.
/// `Conn.init` initializes undefined storage. Do not read, mutate or copy live
/// slots from another task. `result` borrows one call's buffer until that call
/// releases the slot. A snapshot after all tasks finish owns no resources.
pub const Slot = struct {
    id: i64 = 0,
    used: bool = false,
    answered: bool = false,
    /// True when the inbound answer did not fit `result`. The request may have
    /// executed, so this does not authorize replay. Conn releases the slot and
    /// reports `ResponseTooLarge`; it returns no partial response.
    overflowed: bool = false,
    is_error: bool = false,
    error_code: i32 = 0,
    /// Where the reader copies the answer. This is the caller's own buffer, so
    /// the reader never allocates and never hands back a dangling pointer.
    result: []u8 = &.{},
    /// Bytes written into `result`.
    len: usize = 0,
};

/// A live connection over a framed, byte-oriented transport.
///
/// Construct with `init`; do not assemble or mutate its state fields directly.
/// The connection retains the `io` capability and borrows its backend,
/// `reader`, `writer` and all `Config` storage. Keep the backend and borrowed
/// storage alive until the last use of the connection, including `close` and
/// the metadata getters, and until all calls and the pump have ended.
/// Reader and writer addresses must stay fixed. Once tasks hold `*Conn`, do not
/// move or copy the connection; its mutexes and slot table name one live state.
///
/// Concurrent calls and notifications are supported with separate caller
/// buffers. Run exactly one `pump`, on independent execution, and install
/// callbacks before it starts. Metadata getters are synchronized snapshots,
/// not per-call receipts. `close` changes state but owns no task or transport:
/// shut down the transport, join or cancel the caller-owned group, then release
/// transport and buffers. There is no `deinit` and no per-message allocation.
pub const Conn = struct {
    /// Executor capability copied by `init`, not ownership of its provider.
    /// Every operation that locks uses this stored capability. Its backend must
    /// outlive the last operation on this connection; do not use the connection
    /// after that backend is deinitialized.
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    framer: framing.Framer,
    slots: []Slot,
    handler: Handler,
    /// Told about a response that named no outstanding call. See
    /// [`OrphanHandler`].
    orphan: OrphanHandler = .{},
    /// The region an inbound frame is decoded into, and the region a handler
    /// is handed to decode one into.
    ///
    /// It is the region a handler's borrows live in: a decoded method name, an
    /// unescaped option id, a `Request` sliced out of the frame. None of them
    /// outlives the handler, and all of them are invalid the moment the next
    /// frame is decoded here.
    ///
    /// It must not share a byte with `answer` or with the framer's buffer.
    /// The escape offset `json.Reader` keeps is per reader and not per buffer,
    /// so a handler decoding a string with an escape starts at offset 0 again
    /// and writes over whatever the reader that decoded the request left
    /// there: an answer carrying an escape lands exactly on a name the
    /// request borrowed from this buffer, and the comparison that follows is
    /// between a value and itself. The frame is a window on the framer's
    /// buffer, so an escape unescaped into this region can land on the very
    /// bytes being read. `init` refuses both pairs.
    decode_scratch: []u8,
    /// The region a handler writes its answer into, and the region this
    /// connection writes a refusal into.
    ///
    /// A handler is handed this to write into, so nothing it decoded into
    /// `decode_scratch` is borrowed from here and nothing written here can
    /// land on a value the handler is still reading. Must not share a byte
    /// with `decode_scratch` or with the framer's buffer; `init` refuses both
    /// pairs.
    answer: []u8,

    /// Monotonic, never reused, so a late answer to a dead request cannot be
    /// mistaken for a live one.
    next_id: i64 = 1,
    /// Bytes written into the caller's `out` buffer by the most recent
    /// `call` or `notify`.
    ///
    /// One field serves the whole connection, so it has one issuer: the value
    /// belongs to the task that made the most recent `call` or `notify` and to
    /// no other. Two tasks may call at once and each has its own `out` buffer,
    /// so a task that reads this after the other task's call learns a length
    /// for a frame it did not write and slices its own buffer with it.
    last_encoded_len: usize = 0,
    closed: bool = false,
    /// Set when the peer sent a frame the caller's frame buffer cannot hold.
    ///
    /// Published with `closed` under `state_mutex`; a later local close does
    /// not replace the reason. Waiting calls read it under that same lock to
    /// distinguish an oversized peer frame from other closure.
    peer_frame_too_large: bool = false,
    /// Serialises writes. Two tasks may call at once, and a frame interleaved
    /// with another is two malformed frames on the wire.
    write_mutex: Io.Mutex = .init,
    /// Guards the pending table, `closed`, `peer_frame_too_large`, `next_id`,
    /// `last_encoded_len` and the waiting condition.
    ///
    /// Taken uncancelable everywhere it is taken. Every section is short and
    /// holds nothing that blocks, and the one place a task may be cancelled
    /// while it holds this is the condition wait inside it, which hands the
    /// lock back on the way out either way. A cancelation that arrived at the
    /// lock instead would leave a claimed slot with nothing pointing at it,
    /// and a caller cannot free one it does not know about.
    state_mutex: Io.Mutex = .init,
    wake: Io.Condition = .init,

    /// Borrowed storage for one connection. All four regions must be nonempty
    /// and pairwise disjoint; `init` checks this before changing any slot.
    /// Keep the regions alive and exclusively managed by this connection until
    /// its tasks finish. Sizes are caller policy, not protocol defaults.
    pub const Config = struct {
        /// Assembles frames, and is the buffer a frame is read out of as well
        /// as written into. Must be large enough for the largest message the
        /// peer may send, must not have no room at all, and must share no byte
        /// with any of the three regions below.
        frame_buffer: []u8,
        /// One slot per call that may be outstanding at once, and not none.
        /// Written by the task that calls as well as by the reader task, so
        /// it must share no byte with any of the other three regions.
        pending: []Slot,
        /// Where a frame is decoded into. See [`Conn.decode_scratch`].
        decode_scratch: []u8,
        /// Where an answer is written. See [`Conn.answer`].
        answer: []u8,
    };

    /// A connection over `config`'s buffers, or the reason it cannot be one.
    ///
    /// The two refusals are wiring faults rather than wire conditions, and
    /// `init` is the only place that can see them: by the time a peer has sent
    /// anything, a buffer with no room and a pair of regions that overlap look
    /// the same as a peer being difficult.
    ///
    /// Borrows the interfaces, their backend capability and all configured
    /// storage. Success clears every pending slot and retains these references;
    /// failure changes no slot and acquires no transport ownership. `io` must
    /// serve the interfaces and outlive all operations. Init does no I/O.
    pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, config: Config) Error!Conn {
        // Refused before anything is written, so a caller's pending table is
        // left exactly as it was handed over rather than half-initialised by a
        // connection that was never built.

        // A buffer with no room is a connection that cannot work, and the first
        // message or the first call is a poor place to hear about it. Named one
        // at a time so the error says which buffer the caller sized wrong.
        if (config.frame_buffer.len == 0) return error.UnusableBuffer;
        if (config.pending.len == 0) return error.UnusableBuffer;
        if (config.decode_scratch.len == 0) return error.UnusableBuffer;
        if (config.answer.len == 0) return error.UnusableBuffer;
        // Every pair of the four regions, because three of them are live at
        // once on the reader task and the fourth is live there and on the
        // task that calls. A shared byte is the one fault this pair of names
        // exists to make impossible, and the one fault a caller cannot see:
        // the connection runs, the answers come back, and they are wrong.

        // `decode_scratch` against `answer`: the escape offset `json.Reader`
        // keeps is per reader and not per buffer, so a second reader decoding
        // a string with an escape starts at offset 0 again and writes over
        // whatever the first left there.
        if (overlaps(config.decode_scratch, config.answer)) return error.OverlappingBuffers;
        // The frame buffer against either handler region: the slice a frame
        // is decoded from is a window on the framer's buffer, and the escape
        // the decoder writes into `decode_scratch` lands on the very bytes
        // being read.
        if (overlaps(config.frame_buffer, config.decode_scratch)) return error.OverlappingBuffers;
        if (overlaps(config.frame_buffer, config.answer)) return error.OverlappingBuffers;
        // The pending table against any of the other three: `claim` writes a
        // slot from the task that called while the reader task writes the
        // framer, so this pair is a race on bytes rather than a wrong answer.
        const table = std.mem.sliceAsBytes(config.pending);
        if (overlaps(table, config.frame_buffer)) return error.OverlappingBuffers;
        if (overlaps(table, config.decode_scratch)) return error.OverlappingBuffers;
        if (overlaps(table, config.answer)) return error.OverlappingBuffers;

        // Every slot starts free.

        // The array is storage this type now owns, and a caller that declares
        // it `undefined` — which is what every buffer in this library is
        // declared as — has not built a table of free slots. In ReleaseSafe
        // the stack those slots land on is whatever the previous test left
        // there, so `used` reads as true and the first call answers
        // `error.TooManyPending` with no peer on the wire at all. Debug hides
        // it by zeroing the frame.
        for (config.pending) |*slot| slot.* = .{};
        return .{
            .io = io,
            .reader = reader,
            .writer = writer,
            .framer = framing.Framer.init(config.frame_buffer),
            .slots = config.pending,
            .handler = .{},
            .decode_scratch = config.decode_scratch,
            .answer = config.answer,
        };
    }

    /// Install the handler that answers the peer's requests and
    /// notifications.
    ///
    /// Legal only before the reader task starts. `init` leaves the field
    /// null and nothing guards it: `dispatch` reads it once per inbound
    /// frame, on the reader task, and takes no lock for the read. Set it on
    /// the task that owns the connection before `pump` runs, or from the
    /// reader task itself between frames. A swap from another task while
    /// the reader runs is a data race, and a ctx that swap frees can be
    /// read by an invocation already in progress.
    ///
    /// A request that arrives before a handler is installed gets no answer
    /// at all. A null handler declines every frame, `dispatch` reads that
    /// as "no answer" rather than as a failure, and the peer waits on a
    /// request that already arrived. A notification is dropped instead,
    /// which is correct.
    ///
    /// A frame already in the framer's buffer is not held back for a later
    /// handler: it goes to whichever handler is installed when `route`
    /// reaches it.
    ///
    /// A response never reaches the handler. `route` sends one to the
    /// pending table, where it is matched to a call by id, so this neither
    /// intercepts nor answers an outstanding `call`. The response that
    /// belongs to no call goes to [`setOrphanHandler`] instead, because a
    /// handler is handed a frame to answer and that frame has no answer.
    pub fn setHandler(self: *Conn, handler: Handler) void {
        self.handler = handler;
    }

    /// Install the hook that hears a response no outstanding call is waiting
    /// for.
    ///
    /// Legal only before the reader task starts, on the same terms and for the
    /// same reason as [`setHandler`]: `deliver` reads the field once per
    /// inbound response, on the reader task, and takes no lock for the read.
    ///
    /// Nothing is installed by default, and a connection with no hook drops
    /// these frames exactly as it did before one existed. The hook is the only
    /// way to see one, so installing it after `pump` has begun has already
    /// lost every frame that arrived in between.
    pub fn setOrphanHandler(self: *Conn, handler: OrphanHandler) void {
        self.orphan = handler;
    }

    /// Length of the last successfully encoded call or notification.
    ///
    /// A synchronized connection-wide snapshot, not a receipt for this task.
    /// To slice your own `out`, exclude other issuers from encoding until this
    /// read. Failed encoding leaves the previous length unchanged. This takes
    /// a short uncancelable state lock and performs no I/O.
    pub fn lastEncodedLen(self: *Conn) usize {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.last_encoded_len;
    }

    /// Snapshot of the next request id; this does not reserve it.
    ///
    /// Another caller may consume the id before your call. Takes a short
    /// uncancelable state lock and performs no I/O.
    pub fn nextId(self: *Conn) i64 {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.next_id;
    }

    /// Send a request and wait for its response.
    ///
    /// `params` is one JSON object, array or literal null; a null slice omits
    /// the member. Whitespace around literal null is normalized. Raw newlines
    /// are refused with `Framing`; invalid JSON or UTF-8 is `InvalidMessage`.
    /// `out` receives the request and `result` receives the response.
    ///
    /// All arguments must remain alive until return. Writable `out` and `result`
    /// must be disjoint from each other, from readable method/params bytes, from
    /// the four Config regions and from interface buffers. Each concurrent
    /// operation needs its own writable regions. These per-call alias rules are
    /// caller preconditions, not checks performed by `init`.
    ///
    /// Blocks on writing and on a response; the independent pump must run.
    /// A canceled condition wait returns `Canceled` without closing. Writer
    /// cancellation is erased by `Io.Writer` to a write failure and returns
    /// `Transport`. Delivery and remote effects may already have occurred on
    /// cancellation, closure, transport failure or `ResponseTooLarge`; no retry
    /// is performed. Encode failures send nothing but consume the reserved id.
    /// Output/result bytes may be dirty on any error; no response borrow is
    /// returned. On success `Response.body` borrows `result` until its reuse.
    ///
    /// Every path out of here gives the slot it claimed back, including a
    /// request that never went out, a connection that died under it and a
    /// wait that failed. A caller's table is bounded, so a slot that survived
    /// any one of those is a slot nothing would ever free, and enough of them
    /// refuse every later call on a connection that is otherwise healthy.
    pub fn call(
        self: *Conn,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
    ) Error!Response {
        // The slot and the id are taken together, under one mutex, and the id
        // second. Two tasks may call at once, and a response is matched by id
        // alone, so a read and an increment done outside the mutex let two
        // calls take the same id and one of them answer the other. The
        // multi-round-trip rule requires a retry to be a genuinely new call,
        // and that starts here. `open` refuses a dead connection here, so
        // the two faults a caller can be told about are told apart from one
        // consistent read of the state rather than from a fast path that
        // raced it.
        const opened = try self.open(result);

        // Encode before the id is published to the writer path: a request that
        // cannot be encoded must not leave a slot occupied.
        const encoded = self.encodeRequest(opened.id, method, params, out) catch |err| {
            self.release(opened.slot);
            return err;
        };
        self.writeFrame(encoded) catch |err| {
            self.release(opened.slot);
            // A write that fails for any other reason marks the connection
            // dead, because a task blocked in `call` on it would otherwise
            // wait on a writer that cannot write, for good. `error.Framing`
            // is this caller's own bytes and leaves the connection usable,
            // which is the same line `notify` and `dispatch` draw.
            if (err == error.Transport) self.close();
            return err;
        };

        // Wait for the answer. The lock is taken uncancelable and the wait
        // inside it is the cancelation point, because the two are not the
        // same thing: `Io.Condition` releases a blocked waiter when its task
        // is cancelled, and a cancelation arriving between them must not
        // leave a slot behind that nothing points at again.
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        while (!opened.slot.answered and !self.closed) {
            // `wait` hands the mutex back on the way out, on the error path
            // as much as on the return, so the slot is freed with the lock
            // this task already holds.
            self.wake.wait(self.io, &self.state_mutex) catch {
                releaseLocked(opened.slot);
                return error.Canceled;
            };
        }
        if (!opened.slot.answered) {
            releaseLocked(opened.slot);
            return if (self.peer_frame_too_large) error.FrameTooLarge else error.ConnectionClosed;
        }
        const answer: Response = .{
            .body = result[0..opened.slot.len],
            .error_code = if (opened.slot.is_error) opened.slot.error_code else null,
        };
        const overflowed = opened.slot.overflowed;
        releaseLocked(opened.slot);
        if (overflowed) return error.ResponseTooLarge;
        return answer;
    }

    /// Send a notification: a method with no id, which expects no answer.
    ///
    /// Uses the same params, lifetime and buffer-separation rules as `call`,
    /// without a result buffer or id reservation. It blocks only on writing;
    /// success means locally written and flushed, not acknowledged by the peer.
    /// `InvalidMessage`, `EncodeBufferTooSmall` and `Framing` send nothing and
    /// keep the connection usable. A write failure, including cancellation
    /// erased by `Io.Writer`, returns `Transport` and marks it dead. Output
    /// bytes may be dirty on failure and stay caller-owned on success.
    pub fn notify(self: *Conn, method: []const u8, params: ?[]const u8, out: []u8) Error!void {
        if (self.isClosed()) return error.Closed;
        const encoded = try self.encodeNotification(method, params, out);
        self.writeFrame(encoded) catch |err| {
            if (err == error.Transport) self.close();
            return err;
        };
    }

    /// Read frames and route them until the transport ends or the connection
    /// closes.
    ///
    /// The reader task's whole job. It blocks in the `readVec` that asks for
    /// more bytes, so a peer that goes quiet costs nothing.
    ///
    /// It stops on a closed connection rather than only on the end of the
    /// stream. A reader that ignored `closed` kept routing and answering on a
    /// connection it had been told was dead, and a caller joining its group
    /// never finished for as long as the peer kept the socket open. What the
    /// reader cannot do is interrupt a read already blocked on that socket:
    /// [`close`] is the decision, and shutting the transport down and then
    /// closing it, and awaiting or cancelling the group, is still the
    /// caller's.
    ///
    /// Run on `Io.Group.concurrent`, not `async`, so waiting cannot execute
    /// inline on a caller that still needs to send. Reader errors, EOF and
    /// cancellation represented by its `Io.Reader` close the connection and
    /// return no error value. Join or cancel this task before releasing buffers.
    pub fn pump(self: *Conn) void {
        while (!self.isClosed()) {
            // Take every complete frame before asking for more bytes, or a
            // busy peer would keep the framer full of unprocessed frames.
            while (self.framer.next()) |frame| {
                self.route(frame);
                // Between frames rather than only between reads, because a
                // handler that reported a dead transport, or a caller that
                // closed the connection, closes it from in here.
                if (self.isClosed()) return;
            }

            self.framer.slide();
            const space = self.framer.freeSpace();
            if (space.len == 0) {
                // A frame fills the buffer and still has no newline in it, so
                // the delimiter is not coming and the frame will never fit.
                // Dropping the buffer and reading on would not recover: the
                // tail of this frame is still on the wire. End the connection
                // and publish its reason with closure in one lock section.
                self.state_mutex.lockUncancelable(self.io);
                if (!self.closed) {
                    self.peer_frame_too_large = true;
                    self.closed = true;
                    self.wake.broadcast(self.io);
                }
                self.state_mutex.unlock(self.io);
                return;
            }
            // `readVec`, not `readSliceShort`: the latter means "fill this
            // buffer completely", so it would block waiting for the remaining
            // kilobytes of a frame that has already fully arrived. This one
            // performs a single read and reports end of stream as an error.

            // A count of zero is not the end of the stream. The standard says
            // so in as many words, and a reader in positional mode over a pipe
            // returns zero because it falls back to streaming, which is the
            // transport `stdio.zig` builds this connection over. Reading zero
            // as the end shuts the pump down on its first read and no peer
            // byte is ever seen.
            var slots = [_][]u8{space};
            const got = self.reader.readVec(&slots) catch {
                // End of stream and a read error end the connection the same
                // way, and the pump reports neither: a task waiting in `call`
                // learns of both from the close.
                self.close();
                return;
            };
            // Nothing this time, so ask again. The next read is where the
            // blocking happens, because the one just returned has nothing
            // buffered to hand over.
            if (got == 0) continue;
            self.framer.filled(got);
        }
    }

    /// Sort one inbound frame into its case and act on it.
    fn route(self: *Conn, frame: []const u8) void {
        const message = jsonrpc.decode(frame, self.decode_scratch) catch {
            // Not a message this library can read. There is no id to answer
            // on, so there is nothing to send; dropping it is the only
            // correct action and is what the codec's totality rule implies.
            return;
        };
        switch (message.kind) {
            .response => self.routeResponse(message),
            .request, .notification => self.dispatch(frame),
        }
    }

    /// Hand a response to the call waiting for it, or to the application when
    /// no call can be waiting for it.
    ///
    /// Three frames arrive here and they are one event: the peer sent a
    /// response and no outstanding call can take it. A `null` id is the
    /// specification's own id for a response whose request it could not
    /// identify, and the peer refused something and could not say which — the
    /// one frame JSON-RPC 2.0 says an application must be told about rather
    /// than matched. A string id is not one this connection allocates. And an
    /// id naming a call that has already returned is the ordinary shape of the
    /// second and every later response on a `subscriptions/listen` stream.
    ///
    /// All three are told, and all three used to be dropped here with nothing
    /// written anywhere. The hook runs after `deliver` has given the pending
    /// table back, so it is called with no lock held.
    fn routeResponse(self: *Conn, message: jsonrpc.Message) void {
        if (self.deliver(message)) return;
        self.orphan.invoke(message);
    }

    /// Hand a response to the call waiting for it, and say whether one was.
    ///
    /// False is the whole of what this function knows about correlation: the
    /// table had no slot for this frame, so nobody was waiting for it and
    /// there is no buffer anywhere that a caller could read it out of. The
    /// caller reports the frame itself; this one holds no lock to report it
    /// under.
    fn deliver(self: *Conn, message: jsonrpc.Message) bool {
        // A string id is legal on the wire, but this connection allocates its
        // own ids as integers, so a string id cannot be one of ours and there
        // is nothing to match it against. A `null` id is the specification's
        // id for a response whose request it could not identify, which says
        // the same thing. Neither names a slot, so neither is looked up and
        // both leave here the way a frame with no owner leaves any other
        // connection: reported rather than dropped.
        const id: ?i64 = if (message.id) |named| switch (named) {
            .integer => |value| value,
            .string => null,
        } else null;
        const wanted = id orelse return false;

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        var matched = false;
        for (self.slots) |*slot| {
            if (!slot.used or slot.id != wanted or slot.answered) continue;
            if (message.rpc_error) |rpc_error| {
                slot.is_error = true;
                slot.error_code = rpc_error.code;
                // The error object is re-serialised from its members rather
                // than borrowed, because `rpc_error.message` may have been
                // unescaped into the decode scratch and the caller wants one
                // consistent buffer.
                slot.len = writeErrorBody(slot.result, rpc_error);
                // A serialised error object is at least ten bytes, so a length
                // of zero is the one value that cannot be a body that small.
                // Without this the caller gets an empty body with `error_code`
                // set and reads a refusal as an answer, and the retry the
                // slot documents, with a larger buffer, never fires.
                if (slot.len == 0) slot.overflowed = true;
            } else {
                const body = message.result orelse "null";
                slot.is_error = false;
                slot.error_code = 0;
                if (body.len > slot.result.len) {
                    slot.overflowed = true;
                    slot.len = 0;
                } else {
                    @memcpy(slot.result[0..body.len], body);
                    slot.len = body.len;
                }
            }
            slot.answered = true;
            matched = true;
            break;
        }
        self.wake.signal(self.io);
        return matched;
    }

    /// Answer a request from the peer, or note a notification.
    fn dispatch(self: *Conn, frame: []const u8) void {
        // The regions are the connection's own, in the order the handler sees
        // them, and the two carry the same names everywhere a handler is
        // called. Two places invoke one: this, and `http.Server.answer` in
        // `http.zig`, which hands over the two buffers from its own set. Ten
        // files supply one, and a change to this signature breaks every one of
        // them: `stdio.zig`, `mcp_session.zig`, `acp_session.zig`,
        // `bridge_session.zig`, `runtime_demo.zig`, `sessions_demo.zig`,
        // `http_demo.zig`, `http.zig`'s own test driver, and
        // `test/loopback_test.zig`. That list is why it is written down.

        // `decode_scratch` is the region the reader has just classified the
        // frame in, and lending it out is safe because the classification is
        // made by then and nothing here reads the message again.
        const answer = self.handler.invoke(frame, self.decode_scratch, self.answer) catch |err| {
            // A handler that failed did not decline the request. It tried to
            // answer and could not, and silence would leave the peer waiting on
            // a request that already arrived, so a request is answered with the
            // error it is owed. A transport that failed under the handler's
            // own hand takes the connection with it, because nothing else
            // written to it would arrive either.
            if (err == error.Transport) self.close();
            self.refuse(frame);
            return;
        };
        const body = answer orelse return;
        // The answer is composed and there is no second one to send, so a
        // write that fails here is not retried. It does not follow that the
        // connection is finished: `error.Framing` names the handler's own
        // bytes, which fail the same way however often they are sent, so the
        // transport stays usable and the peer can still be served. Every
        // other failure is the transport's, and takes the connection with it,
        // because a task blocked in `call` on it would otherwise wait on a
        // writer that cannot write. `call` and `notify` draw this same line.
        self.writeFrame(body) catch |err| {
            if (err == error.Transport) self.close();
            return;
        };
    }

    /// Answer a request whose handler failed, so the peer is not left waiting
    /// on a request that already arrived.
    ///
    /// The envelope is the shared builder's, so the error object cannot be
    /// written anywhere but the `error` member. What is left here is the
    /// decision a builder cannot make: a handler that failed is this peer's own
    /// internal error, and a notification has no id to answer on, so one it
    /// failed on is dropped exactly as one it declined is.
    ///
    /// The frame is decoded again here rather than read from the `Message` the
    /// reader already holds, because the handler has just been handed
    /// `decode_scratch` to decode into and whatever it left there is not this
    /// function's to trust. The frame is still the framer's, and nothing is
    /// borrowed: a handler that returned an error borrowed nothing.
    ///
    /// The refusal goes into `answer`, the region the handler was handed to
    /// write into, so it cannot land on a value the handler was still reading.
    /// That is the whole reason the two regions are separate and the reason is
    /// invisible here: with one region, this line wrote over the id it was
    /// about to echo.
    fn refuse(self: *Conn, frame: []const u8) void {
        // A notification has no id to answer on, so `decodeRequest` refuses it
        // and nothing is written, exactly as for a handler that declined one.
        const request = jsonrpc.decodeRequest(frame, self.decode_scratch) catch return;
        const body = errorResponse(request, .{
            .code = @backingInt(jsonrpc.StandardError.internal_error),
            .message = "this peer could not serve the request",
        }, self.answer) catch return;
        // A handler fault does not excuse a failed transport write. Wake
        // pending calls and stop the pump rather than waiting for another
        // read to discover a writer that already failed.
        self.writeFrame(body) catch |err| {
            if (err == error.Transport) self.close();
        };
    }

    /// The peer's error object, written into the caller's result buffer.
    ///
    /// Re-serialised from the decoded members rather than borrowed, and every
    /// member of it: `data` is arbitrary JSON carried as the peer's own bytes,
    /// and a body without it is not the object the peer sent. `jsonrpc`'s
    /// outbound builder writes the same three members, so a refusal this
    /// library sends is one it can read back.
    fn writeErrorBody(out: []u8, rpc_error: jsonrpc.Error) usize {
        var writer = json.Writer.init(out);
        writer.slice("{\"code\":") catch return 0;
        var number: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&number, "{d}", .{rpc_error.code}) catch return 0;
        writer.slice(text) catch return 0;
        writer.slice(",\"message\":") catch return 0;
        writer.string(rpc_error.message) catch return 0;
        if (rpc_error.data) |data| {
            writer.slice(",\"data\":") catch return 0;
            writer.slice(data) catch return 0;
        }
        writer.byte('}') catch return 0;
        return writer.len;
    }

    fn writeFrame(self: *Conn, bytes: []const u8) Error!void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        // `framing.writeFrame` refuses a message carrying a raw newline by
        // returning `error.WriteFailed`, which is also what a short write
        // returns, so the two are told apart here against the same delimiter
        // the framing module uses. A caller's `params` blob is spliced in
        // verbatim, and reporting that as a transport failure would call a
        // healthy connection dead and invite a retry that fails identically.
        if (std.mem.findScalar(u8, bytes, framing.delimiter) != null) return error.Framing;
        framing.writeFrame(bytes, self.writer) catch return error.Transport;
        self.writer.flush() catch return error.Transport;
    }

    /// Mark the connection dead and release everyone waiting on it.
    ///
    /// Waiting calls wake. Unless their wait is canceled, they report
    /// `error.FrameTooLarge` if the pump already recorded an oversized peer
    /// frame, otherwise `error.ConnectionClosed`. A `pump` returns at its next
    /// frame boundary instead of routing on a dead connection. Idempotent and
    /// legal from any task, including a handler: closing is not a refusal, and
    /// a caller that
    /// hangs up mid-answer still leaves the peer with the answers already
    /// written.
    ///
    /// The lock is taken uncancelable, because this is the one section a
    /// cancelation must not be able to interrupt. A close that returned
    /// without setting `closed` would release nobody, and the caller that
    /// asked for it has no other way to release them.
    ///
    /// It does not touch the transport, and it cannot. A read already blocked
    /// on a socket is not interrupted by anything this layer does, so a caller
    /// that ends a connection still has to shut the transport down and then
    /// close it, in that order, and still has to await or cancel the group
    /// its reader was spawned on. What a connection owns here is the reader's
    /// decision to stop, not the reader's task.
    pub fn close(self: *Conn) void {
        self.state_mutex.lockUncancelable(self.io);
        self.closed = true;
        self.wake.broadcast(self.io);
        self.state_mutex.unlock(self.io);
    }

    /// Whether the connection has been marked dead, read under the mutex that
    /// `close` writes it under.
    fn isClosed(self: *Conn) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.closed;
    }

    /// Claim a free slot for `result` and give it the next request id, or
    /// report why a request cannot be started at all.
    ///
    /// One lock section, and the id is taken second, because
    /// [`error.TooManyPending`] promises the caller's id sequence is
    /// untouched. An id burned by a table with no room is a hole in a sequence
    /// whose whole point is that a late answer to a dead request cannot be
    /// mistaken for a live one.
    ///
    /// Claim before write is the other half of the same rule, and it is what
    /// `Scripted.gate` pins: an answer delivered before the slot exists is
    /// dropped, and the call then waits for a message that has already gone
    /// by. Taking the slot first would fix the id but lose that, so the two
    /// are published together here and the slot is never visible without its
    /// id.
    fn open(self: *Conn, result: []u8) Error!Open {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);

        // A peer that hung up and a peer that overflowed our frame buffer are
        // different faults, so the caller is told which. Read under the mutex
        // `close` writes them under: the fast path is the one place in this
        // file that used to touch both without it, and a caller that saw the
        // two inconsistently would be told `Closed` for a `FrameTooLarge` or
        // the reverse.
        if (self.closed) {
            return if (self.peer_frame_too_large) error.FrameTooLarge else error.Closed;
        }
        for (self.slots) |*slot| {
            if (slot.used) continue;
            const id = self.next_id;
            self.next_id += 1;
            slot.* = .{ .id = id, .used = true, .result = result };
            return .{ .id = id, .slot = slot };
        }
        return error.TooManyPending;
    }

    /// A slot claimed for one request, with the id that request carries.
    const Open = struct {
        id: i64,
        slot: *Slot,
    };

    /// Free a claimed slot, taking the mutex for it.
    ///
    /// Uncancelable, like every section this connection takes the mutex for.
    /// A `release` that returned without freeing left a slot that nothing
    /// pointed at again and nothing would ever free, and a table of those
    /// refuses every call on a healthy connection.
    fn release(self: *Conn, slot: *Slot) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        releaseLocked(slot);
    }

    /// Free a slot whose `state_mutex` the caller already holds.
    ///
    /// `Io.Mutex` is not reentrant, so a caller that already holds the lock —
    /// `call` does, while it reads its answer out of the slot — must not call
    /// `release` or it deadlocks against itself.
    fn releaseLocked(slot: *Slot) void {
        slot.used = false;
        slot.len = 0;
    }

    fn encodeRequest(
        self: *Conn,
        id: i64,
        method: []const u8,
        params: ?[]const u8,
        out: []u8,
    ) Error![]const u8 {
        if (params) |text| {
            if (std.mem.indexOfScalar(u8, text, '\n') != null) return error.Framing;
        }
        var writer = json.Writer.init(out);
        jsonrpc.encode(.{
            .kind = .request,
            .id = .{ .integer = id },
            .method = jsonrpc.Method.split(method),
            .params = rpcParams(params),
        }, &writer) catch |err| return encodeFailure(err);
        self.recordEncodedLen(writer.len);
        return writer.written();
    }

    fn encodeNotification(
        self: *Conn,
        method: []const u8,
        params: ?[]const u8,
        out: []u8,
    ) Error![]const u8 {
        if (params) |text| {
            if (std.mem.indexOfScalar(u8, text, '\n') != null) return error.Framing;
        }
        var writer = json.Writer.init(out);
        jsonrpc.encode(.{
            .kind = .notification,
            .method = jsonrpc.Method.split(method),
            .params = rpcParams(params),
        }, &writer) catch |err| return encodeFailure(err);
        self.recordEncodedLen(writer.len);
        return writer.written();
    }

    fn recordEncodedLen(self: *Conn, len: usize) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.last_encoded_len = len;
    }

    fn rpcParams(params: ?[]const u8) jsonrpc.Params {
        const text = params orelse return .absent;
        if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "null")) return .null_value;
        return .{ .value = text };
    }
};

// --- Tests ----------------------------------------------------------------------

const testing = std.testing;

test {
    // Zig analyses only what a test reaches, so name the module rather than
    // trusting a build to discover it.
    testing.refAllDecls(@This());
}

/// A reader a test scripts, for the two facts about a byte stream that a
/// slice-driven test cannot reach: a read may report nothing without that
/// being the end of the stream, and a frame buffer can fill before a delimiter
/// arrives.
const Scripted = struct {
    io: Io,
    /// Bytes the pump has not been given yet.
    bytes: []const u8,
    /// How many reads answer with nothing before a byte is delivered.
    silent_reads: usize = 0,
    /// Waited on before the first byte, when set.
    ///
    /// A call and a pump cannot be started in an order that decides a test: an
    /// answer delivered before `call` has claimed a slot is dropped, and the
    /// call then waits for a message that has already gone by. Gating the
    /// reader on the writer removes that race, because `call` claims its slot
    /// before it writes anything.
    gate: ?*Io.Event = null,
    reads: usize = 0,
    reader: Io.Reader = .{
        .vtable = &.{ .stream = stream, .readVec = readVec },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },

    fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *Scripted = @fieldParentPtr("reader", r);
        if (self.gate) |gate| {
            self.gate = null;
            gate.wait(self.io) catch return error.EndOfStream;
        }
        self.reads += 1;
        if (self.reads <= self.silent_reads) return 0;
        if (self.bytes.len == 0) return error.EndOfStream;
        const n = @min(data[0].len, self.bytes.len);
        @memcpy(data[0][0..n], self.bytes[0..n]);
        self.bytes = self.bytes[n..];
        return n;
    }

    /// Never reached: every read goes through `readVec`, because that is the
    /// method whose contract these tests are about.
    fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        return error.EndOfStream;
    }
};

/// A writer that keeps what was sent and, the first time anything is sent,
/// lets go of a reader waiting for it. Unbuffered, so every byte arrives
/// through `drain` and there is nothing left for `flush` to do.
const Recorder = struct {
    io: Io,
    sent: []u8,
    len: usize = 0,
    /// Released as soon as the first bytes are written, then cleared.
    gate: ?*Io.Event = null,
    writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn written(self: *const Recorder) []const u8 {
        return self.sent[0..self.len];
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Recorder = @fieldParentPtr("writer", w);
        const vector_count = data.len;
        if (vector_count == 0) return 0;
        var count: usize = 0;
        const prefix = data[0 .. vector_count - 1];
        for (prefix) |bytes| count += try self.copy(bytes);
        const last = data[prefix.len];
        var i: usize = 0;
        while (i < splat) : (i += 1) count += try self.copy(last);
        if (self.gate) |event| {
            self.gate = null;
            event.set(self.io);
        }
        return count;
    }

    fn copy(self: *Recorder, bytes: []const u8) Io.Writer.Error!usize {
        const room = self.sent.len -| self.len;
        const n = @min(bytes.len, room);
        @memcpy(self.sent[self.len..][0..n], bytes[0..n]);
        self.len += n;
        if (n < bytes.len) return error.WriteFailed;
        return n;
    }
};

/// The fixture a handler was handed, unwrapped.
///
/// Every fixture below is wired to its context by the test that declares it,
/// on the same `.ctx = &state` line as the handler is installed, and none of
/// them is installed without one. A null context is a test wired wrong rather
/// than anything a peer can bring about, and no member of [`Error`] would say
/// what a caller should do about one, so the unwrap those four handlers
/// share is written down once here rather than copied into each of them.
fn fixture(comptime T: type, ctx: ?*anyopaque) *T {
    // zwanzig-disable-next-line: optional-unwrap
    return @ptrCast(@alignCast(ctx.?));
}

/// Answers every request with a fixed envelope, and counts the requests it
/// saw, so a test can tell a dispatched frame from a dropped one.
const FixedAnswer = struct {
    calls: usize = 0,

    /// Writes a fixed envelope into the region it was handed to write into, and
    /// decodes nothing, which is the shape a handler is meant to have. The
    /// region it writes is named `answer`; `decode_scratch` is left unnamed
    /// because nothing here touches it.
    fn handle(ctx: ?*anyopaque, _: []const u8, _: []u8, answer: []u8) Error!?[]const u8 {
        const self = fixture(FixedAnswer, ctx);
        self.calls += 1;
        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
        @memcpy(answer[0..body.len], body);
        return answer[0..body.len];
    }
};

/// A handler that cannot answer, for the case where the peer has to be told.
const Failing = struct {
    fn handle(_: ?*anyopaque, _: []const u8, _: []u8, _: []u8) Error!?[]const u8 {
        return error.Transport;
    }
};

/// Records the responses that matched no outstanding call, so a test can tell
/// a told one from a dropped one.
///
/// Every slice in a decoded message borrows the reader's decode region, so
/// each one is copied into a field rather than kept as a slice. A slice would
/// be dead at the next frame, and a test asserting on it after the pump
/// returned would be asserting on whatever the reader decoded after it. A
/// string id is not copied at all: it borrows the same region, and a test
/// cannot tell one from a peer that named no id, so the arm is recorded as the
/// fact it is.
const Orphaned = struct {
    calls: usize = 0,
    /// The peer wrote `"id":null`, the specification's own id for a response
    /// whose request it could not identify.
    id_null: bool = false,
    /// The integer the peer named, or null when it named none this connection
    /// can match against.
    id: ?i64 = null,
    /// The peer named an id as a string. It is legal on the wire and it cannot
    /// be one of this connection's, so it is a response to nothing here.
    named: bool = false,
    code: i32 = 0,
    // SAFETY: `told` copies into it and sets `message_len` before any read of `[0..message_len]`.
    message: [64]u8 = undefined,
    message_len: usize = 0,
    // SAFETY: `told` copies into it and sets `result_len` before any read of `[0..result_len]`.
    result: [64]u8 = undefined,
    result_len: usize = 0,

    fn told(ctx: ?*anyopaque, message: jsonrpc.Message) void {
        const self = fixture(Orphaned, ctx);
        self.calls += 1;
        self.id_null = message.id_null;
        if (message.id) |named| switch (named) {
            .integer => |value| self.id = value,
            .string => self.named = true,
        };
        if (message.rpc_error) |object| {
            self.code = object.code;
            const n = @min(object.message.len, self.message.len);
            @memcpy(self.message[0..n], object.message[0..n]);
            self.message_len = n;
        }
        if (message.result) |text| {
            const n = @min(text.len, self.result.len);
            @memcpy(self.result[0..n], text[0..n]);
            self.result_len = n;
        }
    }

    /// The refusal's message, copied out of the frame that carried it.
    fn said(self: *const Orphaned) []const u8 {
        return self.message[0..self.message_len];
    }

    /// The result body, copied out of the frame that carried it.
    fn body(self: *const Orphaned) []const u8 {
        return self.result[0..self.result_len];
    }
};

/// A handler that overwrites the region it decoded into and then fails, which
/// is the shape the two regions were split to survive.
///
/// The scribble goes the other way from the fault the split fixes: a handler
/// used to write its answer over the name it was comparing, and this one
/// writes over the region the connection decoded the frame into. Either way the
/// connection has to build its refusal from something the handler did not
/// touch, because it cannot know how far a failing handler got.
const Scrambler = struct {
    fn handle(_: ?*anyopaque, _: []const u8, decode_scratch: []u8, _: []u8) Error!?[]const u8 {
        @memset(decode_scratch, 'x');
        return error.Framing;
    }
};

/// A handler whose first answer carries a raw newline and whose second does
/// not, so a test can tell a framing fault from a dead connection: one that
/// killed the connection answers neither.
///
/// The newline is the shape `call` and `notify` already refuse as
/// [`error.Framing`] — the caller's own text, spliced into an envelope — and a
/// handler composes an answer out of whatever it was given, so a string
/// echoed from peer content reaches the writer the same way.
const Newlinier = struct {
    calls: usize = 0,

    /// A refusal whose message carries a raw newline, which is the shape a
    /// handler composes when it echoes an error string or a path back out of
    /// peer content.
    const split = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601," ++
        "\"message\":\"no\nsuch method\"}}";
    /// A whole answer, which is what the next request gets if the connection
    /// survived the first one.
    const whole = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}";

    fn handle(ctx: ?*anyopaque, _: []const u8, _: []u8, answer: []u8) Error!?[]const u8 {
        const self = fixture(Newlinier, ctx);
        self.calls += 1;
        const body: []const u8 = if (self.calls == 1) split else whole;
        @memcpy(answer[0..body.len], body);
        return answer[0..body.len];
    }
};

/// A handler that closes its own connection on the first request, so the
/// second one shows whether the reader stopped.
const Closer = struct {
    connection: *Conn,
    calls: usize = 0,

    fn handle(ctx: ?*anyopaque, _: []const u8, _: []u8, answer: []u8) Error!?[]const u8 {
        const self = fixture(Closer, ctx);
        self.calls += 1;
        if (self.calls == 1) {
            self.connection.close();
        }
        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
        @memcpy(answer[0..body.len], body);
        return answer[0..body.len];
    }
};

/// One `call` on a task of its own, so a test can drive a call and a pump over
/// one group and read the outcome after both have finished.
const Caller = struct {
    connection: *Conn,
    result: []u8,
    out: []u8,
    answer: ?(Error!Response) = null,

    fn run(self: *Caller) void {
        self.answer = self.connection.call(
            "tools/call",
            "{\"name\":\"echo\"}",
            self.result,
            self.out,
        );
    }
};

/// A [`Caller`] that waits for an event before it calls, so a test can order
/// two calls on one connection and know which of them is second.
///
/// The event is the one a [`Recorder`] sets on its first drain, so "second"
/// means "after the first call's request reached the writer" rather than
/// "whichever task the scheduler ran first".
const GatedCaller = struct {
    caller: *Caller,
    gate: *Io.Event,

    fn run(self: *GatedCaller) void {
        self.gate.waitUncancelable(self.caller.connection.io);
        self.caller.run();
    }
};

/// The reader task of a call test, spawned on the group the test awaits.
fn pumpTask(connection: *Conn) void {
    connection.pump();
}

test "a pending table of garbage is a table of free slots" {
    // The connection owns the slot table it is handed, so it clears it. A
    // caller's array is no exception: every buffer in this library is declared
    // `undefined`, and in ReleaseSafe the stack those slots land on is whatever
    // the previous test left there, so an uncleared `used` flag answers the
    // first call with `error.TooManyPending` and no peer on the wire at all.
    // Debug hides it by zeroing the frame, so the table is poisoned here and
    // the test fails in Debug too if the clearing is ever removed.
    var pending: [3]Slot = undefined;
    for (&pending) |*slot| {
        slot.* = .{ .id = -1, .used = true, .answered = true, .result = &.{} };
    }

    var frame_buffer: [64]u8 = undefined;
    var decode_scratch: [64]u8 = undefined;
    var answer: [64]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&.{});
    const connection = try Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });

    try testing.expectEqual(@as(usize, 3), connection.slots.len);
    for (connection.slots) |slot| try testing.expect(!slot.used);
}

test "a read of nothing is not the end of the stream" {
    // `readVec` may report nothing without that meaning the stream ended, and
    // a reader in positional mode over a pipe reports exactly that because it
    // falls back to streaming. That is the transport `stdio.zig` builds this
    // connection over, so a pump that reads zero as the end shuts down on its
    // first read and never sees a peer byte.
    var state: FixedAnswer = .{};
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out_buffer: [256]u8 = undefined;
    var source: Scripted = .{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}\n",
        .silent_reads = 1,
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = try Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    connection.setHandler(.{ .ctx = &state, .call = FixedAnswer.handle });

    connection.pump();

    // The frame that arrived after the empty read was decoded and dispatched,
    // and its answer went back out.
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n",
        writer.buffered(),
    );
    // The stream really did end, and only then did the pump stop.
    try testing.expectEqual(@as(usize, 0), source.bytes.len);
    try testing.expect(connection.closed);
}

test "a notification whose params carry a newline is a framing fault, and the connection survives it" {
    // `params` is the caller's own JSON, spliced in verbatim, so a newline in
    // it is enough. Reporting that as a transport failure would call a healthy
    // connection dead, and the retry that message invites would fail the same
    // way, because the caller's bytes have not changed.
    var frame_buffer: [256]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [128]u8 = undefined;
    var answer: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var out_buffer: [256]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = try Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });

    try testing.expectError(
        error.Framing,
        connection.notify("notifications/progress", "{\"progress\":1}\n", &out),
    );
    // Nothing went out, so the peer never saw half a message.
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    // The transport is alive, so the next notification leaves whole.
    const notification =
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"," ++
        "\"params\":{\"progress\":1}}";
    try connection.notify("notifications/progress", "{\"progress\":1}", &out);
    try testing.expectEqualStrings(notification ++ "\n", writer.buffered());
    // The field measures the caller's encode buffer, which holds the message;
    // the framer adds the delimiter on its way to the writer, so the frame is a
    // byte longer than the field and the two are not the same quantity. The
    // field's use is slicing the buffer it was handed.
    try testing.expectEqualStrings(notification, out[0..connection.lastEncodedLen()]);
    try testing.expect(!connection.closed);
}

test "local encode refusals do not write or kill the connection" {
    var frame_buffer: [256]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [128]u8 = undefined;
    var answer: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var result: [128]u8 = undefined;
    var sent: [256]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&sent);
    var connection = try Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });

    try testing.expectError(error.EncodeBufferTooSmall, connection.notify("tools/list", null, out[0..1]));
    try testing.expectError(error.EncodeBufferTooSmall, connection.call("tools/list", null, &result, out[0..1]));
    try testing.expectError(error.InvalidMessage, connection.notify("tools/call", "{\"x\":1}tail", &out));
    try testing.expectError(error.InvalidMessage, connection.call("tools/call", "42", &result, &out));
    try testing.expectError(error.InvalidMessage, connection.notify("\xff", null, &out));
    try testing.expectError(error.Framing, connection.notify("tools/list", "null\n", &out));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    for (pending) |slot| try testing.expect(!slot.used);

    try connection.notify("tools/list", " null ", &out);
    var decoded_scratch: [128]u8 = undefined;
    const decoded = try jsonrpc.decode(out[0..connection.lastEncodedLen()], &decoded_scratch);
    try testing.expectEqual(jsonrpc.Kind.notification, decoded.kind);
    try testing.expect(decoded.params == .null_value);
}

test "response builders distinguish invalid values from short storage" {
    var scratch: [128]u8 = undefined;
    const request = try jsonrpc.decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}",
        &scratch,
    );
    var out: [256]u8 = undefined;
    try testing.expectError(error.InvalidMessage, respond(request, "{}tail", &out));
    try testing.expectError(error.InvalidMessage, errorResponse(request, .{
        .code = -32601,
        .message = "\xff",
    }, &out));
    try testing.expectError(error.InvalidMessage, errorResponse(request, .{
        .code = -32601,
        .message = "unknown",
        .data = "{",
    }, &out));
    const bytes = try errorResponse(request, .{
        .code = -32601,
        .message = "line\nbreak\x07end",
        .data = "{\"why\":\"unknown\"}",
    }, &out);
    const decoded = try jsonrpc.decode(bytes, &scratch);
    try testing.expectEqualStrings("line\nbreak\x07end", decoded.rpc_error.?.message);
    try testing.expectEqualStrings("{\"why\":\"unknown\"}", decoded.rpc_error.?.data.?);
}

test "a notification that did not go out is reported, and it takes the connection with it" {
    // A notification whose write failed looked delivered, and the connection
    // stayed open, so a task blocked in `call` waited for an answer on a writer
    // that cannot write.
    var frame_buffer: [256]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [128]u8 = undefined;
    var answer: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var result: [128]u8 = undefined;
    var reader = Io.Reader.fixed("");
    // A writer with nowhere to put a byte: every write fails.
    var writer = Io.Writer.failing;
    var connection = try Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });

    try testing.expectError(
        error.Transport,
        connection.notify("notifications/progress", null, &out),
    );
    // The connection is dead, so a task waiting in `call` is released rather
    // than left blocked on a writer that cannot write.
    try testing.expectError(error.Closed, connection.call("tools/list", null, &result, &out));
}

test "a call cancelled while it waits gives its slot back" {
    // `Io.Condition` is used over `std.Thread.Condition` precisely so a
    // blocked waiter is released when its group is cancelled, and that makes
    // the wait fail rather than block. A call returning from a failed wait
    // still holding its slot leaks one slot per cancelled call, and a table
    // of sixteen then refuses every call on a connection that is otherwise
    // perfectly healthy.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    // A reader with nothing to say, so nothing ever answers the request.
    var source: Scripted = .{ .io = io, .bytes = "" };
    var recorder: Recorder = .{ .io = io, .sent = &sent };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };

    // The owner of a connection returns early for a reason of its own and
    // runs the `errdefer group.cancel(io)` its spawned tasks are under, which
    // is the whole point of `Io.Condition` over `std.Thread.Condition`: the
    // blocked waiter is released instead of hanging. The wait is the first
    // point in `call` that can observe a cancelation, so the slot is always
    // claimed by the time one arrives.
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Caller.run, .{&caller});
    // `cancel` returns once the task has finished, so the answer below is the
    // one the failed wait produced rather than one still being written.
    group.cancel(io);

    try testing.expectError(error.Canceled, caller.answer.?);
    // The slot the call claimed is free again, and the connection is still
    // the one it was: nothing about a cancelled wait kills it.
    for (connection.slots) |slot| try testing.expect(!slot.used);
    try testing.expect(!connection.closed);
}

test "a call whose write failed takes the connection with it" {
    // Two calls on one connection, and a writer with room for exactly one
    // frame. The first claims a slot, writes and waits for an answer that
    // never comes; the second cannot write at all. A caller that reported
    // its own write and left the connection open left the first one waiting
    // on a writer that provably cannot write, which is the hang `notify`
    // already refuses and `call` did not.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The wire form of the call `Caller.run` makes, and the size of the room
    // the recorder has: one frame and not two, so the second call's write
    // finds none left.
    const frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"echo\"}}\n";
    var sent: [frame.len]u8 = undefined;
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var waiter_out: [256]u8 = undefined;
    var waiter_result: [256]u8 = undefined;
    var breaker_out: [256]u8 = undefined;
    var breaker_result: [256]u8 = undefined;
    var reader = Io.Reader.fixed("");
    // The recorder's gate is the ordering: the call that cannot write does
    // not reach the writer until the waiting call's request is already there,
    // so which of the two is second is not left to the scheduler.
    var gate: Io.Event = .unset;
    var recorder: Recorder = .{ .io = io, .sent = &sent, .gate = &gate };
    var connection = try Conn.init(io, &reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var waiter: Caller = .{ .connection = &connection, .result = &waiter_result, .out = &waiter_out };
    var breaker: Caller = .{
        .connection = &connection,
        .result = &breaker_result,
        .out = &breaker_out,
    };
    var breaker_task: GatedCaller = .{ .caller = &breaker, .gate = &gate };

    var waiter_group: Io.Group = .init;
    defer waiter_group.cancel(io);
    try waiter_group.concurrent(io, Caller.run, .{&waiter});
    var breaker_group: Io.Group = .init;
    defer breaker_group.cancel(io);
    try breaker_group.concurrent(io, GatedCaller.run, .{&breaker_task});

    // Awaiting the call whose write fails first: it returns only after the
    // fault has been reported and the connection marked dead, so what the
    // waiter reports below is the connection's and not a cancelation.
    try breaker_group.await(io);
    // A bound rather than a decision. With the connection dead the waiter
    // was already released by the write that failed, and this returns at
    // once; without it, this is the line that releases the waiter, and the
    // assertions below are what fail.
    waiter_group.cancel(io);

    // The fault is reported, and it is the connection's: a writer that cannot
    // write leaves nothing else to be answered on.
    try testing.expect(connection.closed);
    // The call that wrote reports the connection dying under it, and the call
    // whose write failed reports its own.
    try testing.expectError(error.ConnectionClosed, waiter.answer.?);
    try testing.expectError(error.Transport, breaker.answer.?);
    // A call after that is refused rather than written to a dead writer, and
    // both slots are free again.
    try testing.expectError(
        error.Closed,
        connection.call("tools/list", null, &breaker_result, &breaker_out),
    );
    for (connection.slots) |slot| try testing.expect(!slot.used);
}

test "a table with no room for the call leaves the id sequence alone" {
    // `TooManyPending` promises the caller's id sequence is untouched, and a
    // sequence whose whole point is that a late answer to a dead request
    // cannot be mistaken for a live one does not survive a hole. The id is
    // taken after the slot, so a full table costs the caller a retry and not
    // an id.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [512]u8 = undefined;
    // One slot, so the second call on this connection has nowhere to go.
    var pending: [1]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var refused_out: [256]u8 = undefined;
    var refused_result: [256]u8 = undefined;
    var sent: [512]u8 = undefined;
    var source: Scripted = .{ .io = io, .bytes = "" };
    var gate: Io.Event = .unset;
    var recorder: Recorder = .{ .io = io, .sent = &sent, .gate = &gate };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };

    // `var`, because `Future.cancel` takes the future by mutable pointer: the
    // cancelation request is delivered at the call's wait and the slot is
    // freed on that task's own path, which is what the loop below reads.
    var parked = try io.concurrent(Caller.run, .{&caller});
    defer parked.cancel(io);
    // The gate is the ordering this test is about: the parked call has reached
    // the writer and the recorder set it. `wait` fails only on a cancelation,
    // and nothing cancels this task, so a failure is the ordering itself gone
    // wrong and is reported as one rather than stepped over to assert below on
    // a call that had not written yet.
    try gate.wait(io);

    // The parked call took the first id, so the next one will be the second.
    try testing.expectEqual(@as(i64, 2), connection.nextId());
    try testing.expectError(
        error.TooManyPending,
        connection.call("tools/list", null, &refused_result, &refused_out),
    );
    // Nothing was sent, so the id sequence did not move either. A caller
    // predicting its own ids through `nextId` is the one this promises to.
    try testing.expectEqual(@as(i64, 2), connection.nextId());

    _ = parked.cancel(io);
    for (connection.slots) |slot| try testing.expect(!slot.used);
}

test "a peer error too large for the result buffer is reported, not read as an answer" {
    // A peer's error object is re-serialised into the caller's result buffer,
    // and a buffer too small for it yields nothing. Storing that nothing as the
    // answer's length without also recording the overflow hands back an empty
    // body with `error_code` set, which reads as a refusal carrying no reason,
    // and the retry with a larger buffer that the slot documents never fires.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    // Far too small for the error object the peer sends.
    var result: [8]u8 = undefined;
    var sent: [256]u8 = undefined;
    var gate: Io.Event = .unset;
    var source: Scripted = .{
        .io = io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601," ++
            "\"message\":\"no such method\"}}\n",
        .gate = &gate,
    };
    var recorder: Recorder = .{ .io = io, .sent = &sent, .gate = &gate };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };

    // Both tasks on one group, because the call blocks on an answer only the
    // pump can deliver.
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Caller.run, .{&caller});
    try group.concurrent(io, pumpTask, .{&connection});
    try group.await(io);

    try testing.expectError(error.ResponseTooLarge, caller.answer.?);
    // The slot is released either way, so the table does not leak it.
    for (connection.slots) |slot| try testing.expect(!slot.used);
    // The request really did go out before the answer came back.
    try testing.expect(std.mem.startsWith(
        u8,
        recorder.written(),
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"",
    ));
}

test "a peer error is a refusal, and `failed` is what says so" {
    // A peer that answers with `error` produces an ordinary return, because
    // nothing went wrong on the wire. A caller that reads `body` alone then
    // reads the `error` object as a result and calls a tool failure a success,
    // which is the contract AGENTS.md states and the one `failed` exists to
    // make impossible to get wrong.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    // Big enough for the serialised error object, so the answer comes back
    // rather than being refused for want of room.
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    var gate: Io.Event = .unset;
    var source: Scripted = .{
        .io = io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601," ++
            "\"message\":\"no such method\"}}\n",
        .gate = &gate,
    };
    var recorder: Recorder = .{ .io = io, .sent = &sent, .gate = &gate };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Caller.run, .{&caller});
    try group.concurrent(io, pumpTask, .{&connection});
    try group.await(io);

    const replied = try (caller.answer orelse return error.TestUnexpectedResult);
    try testing.expect(replied.failed());
    try testing.expectEqual(@as(?i32, -32601), replied.error_code);
    // The body carries the error object and not a result, which is precisely
    // why reading it without `failed` is the mistake this accessor removes.
    try testing.expect(std.mem.indexOf(u8, replied.body, "\"code\":-32601") != null);
    try testing.expect(std.mem.indexOf(u8, replied.body, "result") == null);

    // The other end of the rule: a call the peer answered is not a refusal,
    // and no code on a success is a failure.
    const answered: Response = .{ .body = "{}" };
    try testing.expect(!answered.failed());
}

test "a peer's error data reaches the caller" {
    // `data` is a member of the error object on the wire and a member of the
    // one this library sends, so re-serialising the object without it took
    // away the structured detail a caller has to act on — silently, with no
    // error anywhere. `errorResponse` carries `data` and the test below pins
    // that, so without this the loss was one-directional: this library sent
    // a member it could never read back.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    var gate: Io.Event = .unset;
    var source: Scripted = .{
        .io = io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602," ++
            "\"message\":\"Invalid params\",\"data\":{\"tool\":\"nope\"}}}\n",
        .gate = &gate,
    };
    var recorder: Recorder = .{ .io = io, .sent = &sent, .gate = &gate };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Caller.run, .{&caller});
    try group.concurrent(io, pumpTask, .{&connection});
    try group.await(io);

    const replied = try (caller.answer orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(?i32, -32602), replied.error_code);
    // Every member of the object the peer sent, in the order PROTOCOLS.md 3.1
    // gives them and with `data` spliced the way the wire carried it.
    try testing.expectEqualStrings(
        "{\"code\":-32602,\"message\":\"Invalid params\",\"data\":{\"tool\":\"nope\"}}",
        replied.body,
    );
}

test "a refusal whose id is null is told to the application, not dropped" {
    // A peer that refuses a frame it could not read, or a batch array it must
    // not accept, answers with a `null` id: JSON-RPC 2.0 says that is the id
    // where the id could not be determined from the Request. Such a frame
    // belongs to no call, so nothing in the pending table can match it, and
    // before the hook it was dropped with every other response that matched no
    // slot. The peer that wrote it learned nothing, and so did whoever was
    // waiting to hear what became of a frame it had sent.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    var gate: Io.Event = .unset;
    // The refusal first and the answer the call is waiting for second. A frame
    // with no id must consume no slot and wake nobody, and only a call that is
    // still answered afterwards shows that it did not.
    var source: Scripted = .{
        .io = io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600," ++
            "\"message\":\"Invalid Request\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n",
        .gate = &gate,
    };
    var recorder: Recorder = .{ .io = io, .sent = &sent, .gate = &gate };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var state: Orphaned = .{};
    connection.setOrphanHandler(.{ .ctx = &state, .call = Orphaned.told });

    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Caller.run, .{&caller});
    try group.concurrent(io, pumpTask, .{&connection});
    try group.await(io);

    // Told once, with what the peer actually said rather than with a guess at
    // which request it belonged to. `id_null` is what says which of the three
    // frames arrived, and it is on the message rather than implied by the
    // absence of an id.
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expect(state.id_null);
    try testing.expectEqual(@as(?i64, null), state.id);
    try testing.expectEqual(@as(i32, -32600), state.code);
    try testing.expectEqualStrings("Invalid Request", state.said());

    // Nothing was sent back. There is no id to answer on, so a frame this
    // connection did answer would be a response in answer to a response, and
    // the only thing on the wire is the request the caller made.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
            "\"params\":{\"name\":\"echo\"}}\n",
        recorder.written(),
    );

    // The call behind the refusal is untouched by it: the frame matched no
    // slot, so it woke no caller and took none.
    const replied = try (caller.answer orelse return error.TestUnexpectedResult);
    try testing.expect(!replied.failed());
    try testing.expectEqualStrings("{\"ok\":true}", replied.body);
}

test "a response on a call that has already returned is told to the application" {
    // PROTOCOLS.md 4.4 makes `subscriptions/listen` one long-lived response
    // stream, and `call` returns on its first response, so every response
    // after that one has no slot behind it. The scan in `deliver` found
    // nothing and the frame left the connection having been seen by nobody:
    // a consumer could not tell a finished subscription from a dropped one,
    // and could not log the frame it was never handed. It is handed now.
    //
    // Both frames carry the id of one call. That is what the stream sends and
    // what makes this the interesting case: the second is not a late answer
    // to a live call, because a slot that is already answered is never matched
    // twice.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    var gate: Io.Event = .unset;
    var source: Scripted = .{
        .io = io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"uri\":\"first\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"uri\":\"second\"}}\n",
        .gate = &gate,
    };
    var recorder: Recorder = .{ .io = io, .sent = &sent, .gate = &gate };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var state: Orphaned = .{};
    connection.setOrphanHandler(.{ .ctx = &state, .call = Orphaned.told });

    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Caller.run, .{&caller});
    try group.concurrent(io, pumpTask, .{&connection});
    try group.await(io);

    // The caller got the first response, so the stream started and the call
    // is over. The second is nobody's, and it says so by being told.
    const replied = try (caller.answer orelse return error.TestUnexpectedResult);
    try testing.expect(!replied.failed());
    try testing.expectEqualStrings("{\"uri\":\"first\"}", replied.body);

    // Told once, with the whole message: the id the peer named, that it named
    // an id rather than a null, and the body it carried. An application that
    // logs the result can now say what it dropped and what it kept.
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expect(!state.id_null);
    try testing.expectEqual(@as(?i64, 1), state.id);
    try testing.expectEqual(@as(i32, 0), state.code);
    try testing.expectEqualStrings("{\"uri\":\"second\"}", state.body());

    // And the connection carried on: the frame took no slot and the table is
    // as it was, so the caller's next request has room to be claimed.
    for (connection.slots) |slot| try testing.expect(!slot.used);
}

test "a response with a string id is told to the application, not dropped" {
    // A string id is legal on the wire and this connection allocates integer
    // ids, so the frame cannot be one of ours and there is nothing in the
    // pending table to match it against. It used to return out of the id
    // switch, which is the same drop the null-id case took before it had a
    // hook of its own, and the peer is told nothing either way.
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out_buffer: [512]u8 = undefined;
    var source: Scripted = .{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":\"sub-1\",\"result\":{\"uri\":\"a\"}}\n",
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = try Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var state: Orphaned = .{};
    connection.setOrphanHandler(.{ .ctx = &state, .call = Orphaned.told });

    connection.pump();

    // Told, and told as what it is: an id this connection never allocated, so
    // the message carries it as a string rather than as a number that would
    // read as one of ours.
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expect(state.named);
    try testing.expect(!state.id_null);
    try testing.expectEqual(@as(?i64, null), state.id);
    try testing.expectEqualStrings("{\"uri\":\"a\"}", state.body());

    // Nothing went back out. There is no id to answer on, so an answer here
    // would be a response in answer to a response.
    try testing.expectEqualStrings("", writer.buffered());
}

test "a request whose handler failed is answered with an error" {
    // A handler that returned an error did not decline the request; it tried
    // to answer and could not. Silence leaves the peer waiting on a request
    // that already arrived, so a request is answered with the error it is owed.
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out_buffer: [512]u8 = undefined;
    var source: Scripted = .{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/list\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n",
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = try Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    connection.setHandler(.{ .call = Failing.handle });

    connection.pump();

    // The request is answered, and only the request: a notification has no id
    // to answer on, so one the handler failed on is dropped, as one it
    // declined is.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32603," ++
            "\"message\":\"this peer could not serve the request\"}}\n",
        writer.buffered(),
    );
    // The handler reported a dead transport, so nothing else would arrive
    // either and the connection is finished rather than left half open.
    try testing.expect(connection.closed);
}

test "a failed internal-error write ends the pump before another request" {
    const State = struct {
        calls: usize = 0,

        fn handle(ctx: ?*anyopaque, _: []const u8, _: []u8, _: []u8) Error!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return error.InvalidMessage;
        }
    };
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var reader = Io.Reader.fixed(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"first\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"second\"}\n",
    );
    var writer = Io.Writer.failing;
    var connection = try Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var state: State = .{};
    connection.setHandler(.{ .ctx = &state, .call = State.handle });
    connection.pump();
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expect(connection.closed);
}

test "an answer carrying a raw newline is the handler's fault, and the connection survives it" {
    // `error.Framing` names the caller's own bytes, and the doc says the
    // transport stays usable, because these same bytes fail the same way
    // however often they are sent. A handler composes an answer out of
    // whatever it was handed — an error string echoed from peer content, a
    // tool name, a path — so the same fault arrives on this path, and killing
    // the connection for it left `call` and `notify` disagreeing with their
    // own documentation about when a message is the caller's to fix.
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out_buffer: [512]u8 = undefined;
    // Two requests in one read, so the second is in the framer's buffer when
    // the first is answered.
    var source: Scripted = .{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n",
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = try Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var state: Newlinier = .{};
    connection.setHandler(.{ .ctx = &state, .call = Newlinier.handle });

    connection.pump();

    // The first answer was refused rather than written: a raw newline would
    // have split one message into two the peer cannot decode, so the peer saw
    // no half-frame and nothing to retry. The second went out whole, which is
    // the proof the transport is alive — a connection killed by the first
    // fault answers nobody, and the handler is not even reached twice.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n",
        writer.buffered(),
    );
    try testing.expectEqual(@as(usize, 2), state.calls);
}

test "a closed connection stops its reader" {
    // The reader used to ignore `closed`, so after `close` it kept routing
    // frames and answering them on a connection it had been told was dead,
    // and a caller joining its group never finished for as long as the peer
    // kept the socket open. Two requests arrive in one read: the handler
    // closes on the first, and the second is what a reader that ignored the
    // close would go on to answer.
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out_buffer: [512]u8 = undefined;
    var source: Scripted = .{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n",
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = try Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var state: Closer = undefined;
    state = .{ .connection = &connection };
    connection.setHandler(.{ .ctx = &state, .call = Closer.handle });

    connection.pump();

    // The close was reached, and it ended the reader before the second frame.
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expect(connection.closed);
    // The first answer still went out: closing is not a refusal, and a caller
    // that hangs up mid-answer still leaves the peer with what it had.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n",
        writer.buffered(),
    );
}

test "a frame the frame buffer cannot hold ends the connection, and a call says so" {
    // Dropping the buffer and reading on does not recover: the tail of the
    // frame is still on the wire, and it is read as the start of the next one.
    // The connection ends instead, and both orderings of the two tasks report
    // the same fault, so the test does not depend on who ran first.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var frame_buffer: [64]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [128]u8 = undefined;
    var answer: [128]u8 = undefined;
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    // A peer that never sends the delimiter, and sends more of it than the
    // frame buffer can hold.
    var source: Scripted = .{ .io = io, .bytes = &@as([200]u8, @splat('x')) };
    var recorder: Recorder = .{ .io = io, .sent = &sent };
    var connection = try Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    var caller: Caller = .{ .connection = &connection, .result = &result, .out = &out };

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Caller.run, .{&caller});
    try group.concurrent(io, pumpTask, .{&connection});
    try group.await(io);

    try testing.expectError(error.FrameTooLarge, caller.answer.?);
    for (connection.slots) |slot| try testing.expect(!slot.used);
}

test "an answer echoes the id in the arm it arrived in" {
    // An answer is matched by id and by nothing else, so a peer that called
    // with a string has to be answered with that string and not with its
    // digits. The hand-written builders these replace read the integer arm
    // only, and a string id is a form the protocol admits.
    var numeric_scratch: [128]u8 = undefined;
    var named_scratch: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const numbered = try jsonrpc.decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}",
        &numeric_scratch,
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}",
        try respond(numbered, "{\"ok\":true}", &out),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601," ++
            "\"message\":\"Method not found\"}}",
        try methodNotFound(numbered, &out),
    );

    // A string id carrying a byte the JSON grammar requires escaped, so the
    // answer is not a splice of the caller's own text either.
    const named = try jsonrpc.decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"tools/list\"}",
        &named_scratch,
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"result\":{\"ok\":true}}",
        try respond(named, "{\"ok\":true}", &out),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"error\":{\"code\":-32601," ++
            "\"message\":\"Method not found\"}}",
        try errorResponse(named, .{ .code = -32601, .message = "Method not found" }, &out),
    );
}

test "a short out is refused by every builder, and writes nothing to send" {
    // A builder that returned the bytes it managed to emit would put half an
    // envelope on the wire. Each reports the shortage instead, so a handler
    // using `try` has nothing to hand back.
    var scratch: [128]u8 = undefined;
    const request = try jsonrpc.decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}",
        &scratch,
    );
    const refusal: jsonrpc.Error = .{ .code = -32601, .message = "Method not found" };

    // No room at all, so not one byte can be written and the buffer is left
    // exactly as the caller handed it over.
    var untouched: [1]u8 = undefined;
    untouched[0] = 'Z';
    try testing.expectError(error.EncodeBufferTooSmall, respond(request, "{}", untouched[0..0]));
    try testing.expectEqual(@as(u8, 'Z'), untouched[0]);

    // Room for a prefix and not for the frame. The error is the guarantee: the
    // writer never advances past a write it refused, so what is left in the
    // buffer is a prefix, and a caller using `try` never sees it.
    var out: [8]u8 = undefined;
    try testing.expectError(error.EncodeBufferTooSmall, respond(request, "{\"ok\":true}", &out));
    try testing.expectError(error.EncodeBufferTooSmall, errorResponse(request, refusal, &out));
    try testing.expectError(error.EncodeBufferTooSmall, methodNotFound(request, &out));
}

test "a result and a refusal never share a frame" {
    // The two are separate builders, so a refusal is a value a caller passes to
    // one and never a member the other has to be told to emit. A handler that
    // assembles one envelope itself can put the error object inside `result`,
    // and the client then reads a refusal as a successful call.
    var scratch: [128]u8 = undefined;
    const request = try jsonrpc.decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}",
        &scratch,
    );
    var out: [128]u8 = undefined;

    const answered = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}";
    const result = try respond(request, "{\"ok\":true}", &out);
    try testing.expectEqualStrings(answered, result);
    try testing.expect(std.mem.indexOf(u8, result, "\"error\"") == null);

    const refused = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601," ++
        "\"message\":\"no such method\"}}";
    const refusal = try errorResponse(
        request,
        .{ .code = -32601, .message = "no such method" },
        &out,
    );
    try testing.expectEqualStrings(refused, refusal);
    try testing.expect(std.mem.indexOf(u8, refusal, "\"result\"") == null);

    // And neither ever hands back an empty slice, which is what a silently
    // unwritten answer looks like to a handler that only checks the error.
    try testing.expect(result.len != 0);
    try testing.expect(refusal.len != 0);
}

test "a buffer with no room is refused before the first message" {
    // A zero frame buffer refuses every frame, a zero pending table fails every
    // call, and a zero decode or answer region fails the first thing that needs
    // it. None of those is a wire condition, and by the time a peer has spoken
    // each of them looks like a peer being difficult.
    var frame_buffer: [64]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [64]u8 = undefined;
    var answer: [64]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&.{});

    var config: Conn.Config = .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    };

    // One region at a time and restored after each, so the refusal is about
    // wiring rather than about a peer and the test says which buffer the
    // caller sized wrong.
    config.frame_buffer = &.{};
    try testing.expectError(error.UnusableBuffer, Conn.init(testing.io, &reader, &writer, config));
    config.frame_buffer = &frame_buffer;
    config.pending = &.{};
    try testing.expectError(error.UnusableBuffer, Conn.init(testing.io, &reader, &writer, config));
    config.pending = &pending;
    config.decode_scratch = &.{};
    try testing.expectError(error.UnusableBuffer, Conn.init(testing.io, &reader, &writer, config));
    config.decode_scratch = &decode_scratch;
    config.answer = &.{};
    try testing.expectError(error.UnusableBuffer, Conn.init(testing.io, &reader, &writer, config));
}

test "regions that share a byte are refused before the first message" {
    // The fault the pair of names exists to make impossible, and the one fault
    // a caller cannot see: the connection runs, answers come back, and they are
    // wrong. Nothing reports it but the caller's own review of the wiring.
    var regions: [128]u8 = undefined;
    var frame_buffer: [64]u8 = undefined;
    var pending: [2]Slot = undefined;
    var answer: [64]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&.{});

    // The same buffer twice, which is what a caller wiring this by accident
    // writes first.
    try testing.expectError(error.OverlappingBuffers, Conn.init(
        testing.io,
        &reader,
        &writer,
        .{
            .frame_buffer = &frame_buffer,
            .pending = &pending,
            .decode_scratch = &regions,
            .answer = &regions,
        },
    ));
    // And two regions carved out of one, where the overlap is only a matter of
    // where the cuts fell.
    try testing.expectError(error.OverlappingBuffers, Conn.init(
        testing.io,
        &reader,
        &writer,
        .{
            .frame_buffer = &frame_buffer,
            .pending = &pending,
            .decode_scratch = regions[0..64],
            .answer = regions[32..],
        },
    ));
    // The frame buffer is a third region live at once. The slice a frame is
    // decoded from is a window on it, and the escape the decoder unescapes
    // into `decode_scratch` lands on the very bytes being read, so the pair
    // is refused even though neither of the two handler regions is in it.
    try testing.expectError(error.OverlappingBuffers, Conn.init(
        testing.io,
        &reader,
        &writer,
        .{
            .frame_buffer = &regions,
            .pending = &pending,
            .decode_scratch = &regions,
            .answer = &answer,
        },
    ));
    // And the pending table is live at the same time on another task: a
    // `claim` writes a slot from the task that called while the reader task
    // writes the framer. That pair is a race on bytes rather than a wrong
    // answer, and it is the same silence.
    var slots: [1]Slot = undefined;
    try testing.expectError(error.OverlappingBuffers, Conn.init(
        testing.io,
        &reader,
        &writer,
        .{
            .frame_buffer = std.mem.sliceAsBytes(slots[0..1]),
            .pending = &slots,
            .decode_scratch = regions[0..32],
            .answer = regions[32..],
        },
    ));
    // Two regions that abut share no byte, and a connection built from them is
    // the ordinary case rather than a near miss.
    _ = try Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = regions[0..64],
        .answer = regions[64..],
    });
}

test "a refusal is built from the frame, not from what a failed handler left" {
    // The handler is handed `decode_scratch` to decode into, and it is the
    // region this connection decoded the frame in as well, so the bytes a
    // failing handler leaves there are not the connection's to trust. A refusal
    // that read the id out of them would echo whatever the handler overwrote.
    // The id here carries an escape, so a refusal built from the wrong region is
    // wrong in a way a plain integer id would hide.
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var answer: [256]u8 = undefined;
    var out_buffer: [512]u8 = undefined;
    var source: Scripted = .{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"tools/list\"}\n",
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = try Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .answer = &answer,
    });
    connection.setHandler(.{ .call = Scrambler.handle });

    connection.pump();

    // The id is the frame's, escaped as the frame escaped it, and the refusal
    // went into the region the handler was handed to write into, so it could
    // not have landed on anything the handler was reading.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"error\":{\"code\":-32603," ++
            "\"message\":\"this peer could not serve the request\"}}\n",
        writer.buffered(),
    );
}
