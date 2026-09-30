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
//! ## Allocation
//!
//! `ARCHITECTURE.md` section 4 allows this layer an allocator, because a
//! pending-request table has a size set by concurrency and cannot be a
//! fixed-size array of the right length. Everything else stays caller-owned:
//! the frame buffer, the encode buffer, the decode scratch and the handler
//! scratch all belong to the caller, so the path from bytes to a decoded
//! message still allocates nothing.
//!
//! The pending table is a caller-supplied array of slots rather than a map.
//! That is deliberate: a connection then has a *known* upper bound on
//! outstanding requests and reports exhaustion, instead of growing without
//! limit because a peer opened calls faster than we answered them.

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
    /// The transport failed: the socket closed or the read errored. The
    /// connection is dead and cannot be reused.
    Transport,
    /// A call waited for an answer that cannot arrive, because the connection
    /// closed first. The fault is the peer's, not ours.
    ConnectionClosed,
    /// More outstanding requests than the caller's table has slots. Nothing
    /// was sent, so the caller's id sequence is untouched.
    TooManyPending,
    /// The response did not fit the caller's result buffer.
    ResponseTooLarge,
    /// A frame did not fit the caller's frame buffer.
    FrameTooLarge,
    /// The message carries a raw newline, so writing it would split one
    /// message into two the peer cannot decode. The transport is healthy and
    /// stays usable, but these same bytes fail the same way however often
    /// they are sent, so the caller must fix the message rather than retry
    /// it. `params` is spliced in verbatim, so a newline in a caller's own
    /// JSON reaches here.
    Framing,
    /// The caller used the connection after it closed.
    Closed,
};

/// What a peer answered to a request.
pub const Response = struct {
    /// The `result` member as raw JSON, or the `error` member as raw JSON when
    /// the peer answered with an error. Borrows the caller's result buffer.
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
/// Returning null means "no answer", which is correct for a notification
/// and leaves a peer's request unanswered. An error is not a refusal: a
/// request that returns one is answered with an internal error, because a
/// peer left waiting on a request that already arrived is worse than an
/// answer it did not want. See the module doc for why this runs inline.
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (
        ctx: ?*anyopaque,
        frame: []const u8,
        scratch: []u8,
    ) Error!?[]const u8 = null,

    fn invoke(self: Handler, frame: []const u8, scratch: []u8) Error!?[]const u8 {
        const func = self.call orelse return null;
        return func(self.ctx, frame, scratch);
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
        .code = @intFromEnum(jsonrpc.StandardError.method_not_found),
        .message = "Method not found",
    }, out);
}

/// The one place a `jsonrpc` encode failure becomes an `Error`.
///
/// `jsonrpc` reports a short `out` as `error.BufferTooSmall`, which is not a
/// member of `Error`, and this layer has always reported that as
/// [`error.ResponseTooLarge`]. Writing it out at every call site let one of
/// them be a size fault and another a different one; there is now one.
///
/// `error.InvalidField` and `error.UnknownTag` name a body the encoder refuses,
/// and a caller told `ResponseTooLarge` about one of those would grow a buffer
/// and try again forever. Neither can reach a wrapper, and the reason is in the
/// code underneath rather than in this switch:
///
/// - `json.Writer` has three write methods and every failure in all three is
///   `BufferTooSmall`. `byte` and `slice` return it from their bounds check;
///   `string` propagates `writeString`, whose every failure is a `byte`, a
///   `slice`, or a `bufPrint` that is itself mapped to `BufferTooSmall`. The
///   set it declares is wider than the set it returns, and nothing in
///   `json.zig` produces the other two members at all.
/// - `json.Writer.string` escapes every byte the JSON grammar forbids and
///   checks nothing, so a message carrying one — or a byte that is not UTF-8 —
///   is written through rather than refused. There is no `InvalidField` to be
///   had for a body it cannot carry, because it never refuses one.
/// - `jsonrpc.writeId` and `jsonrpc.writeErrorObject` add no failure of their
///   own over those three methods but a `bufPrint` already mapped to
///   `BufferTooSmall`, and `encodeResponse`'s own `InvalidField` is the
///   one-of rule, which a builder satisfies before the rule is checked.
///
/// So one member can fire and the other two cannot, which is why `Error` is not
/// widened with a member nothing produces, and why all three answer the same
/// value here. That is right while the proof above holds and wrong the moment
/// it stops: a caller told its buffer is short about a body it cannot encode
/// grows the buffer and tries again forever. A test pins the closure — a
/// message the JSON grammar cannot carry is written through, not refused — and
/// fails the day it opens, which is when the two answers have to be told apart
/// and `Error` has to carry the difference.
fn encodeFailure(err: root.EncodeError) Error {
    return switch (err) {
        error.BufferTooSmall => error.ResponseTooLarge,
        error.InvalidField => error.ResponseTooLarge,
        error.UnknownTag => error.ResponseTooLarge,
    };
}

/// One outstanding request awaiting its answer.
pub const Slot = struct {
    id: i64 = 0,
    used: bool = false,
    answered: bool = false,
    /// True when the answer did not fit `result` and the caller must retry
    /// with a larger buffer. The slot is still released, so the connection
    /// does not leak it.
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
pub const Conn = struct {
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    framer: framing.Framer,
    slots: []Slot,
    handler: Handler,
    /// Scratch for decoding an inbound frame. Separate from `handler_scratch`
    /// because a decoded message borrows the first while the handler is still
    /// using the second; sharing one buffer would have the handler overwrite
    /// the message it was dispatched with.
    decode_scratch: []u8,
    handler_scratch: []u8,

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
    /// The reason a connection died: a peer that hung up and a peer that
    /// overflowed our buffer are different faults, and only one of them is
    /// ours. Written before `shutdown`, whose lock and broadcast are what make
    /// the write visible, and read in `call`, where it decides which of the two
    /// errors a caller gets.
    peer_frame_too_large: bool = false,
    /// Serialises writes. Two tasks may call at once, and a frame interleaved
    /// with another is two malformed frames on the wire.
    write_mutex: Io.Mutex = .init,
    /// Guards the pending table, `closed`, `peer_frame_too_large`, and the
    /// waiting condition.
    state_mutex: Io.Mutex = .init,
    wake: Io.Condition = .init,

    pub const Config = struct {
        /// Assembles frames. Must be large enough for the largest message the
        /// peer may send.
        frame_buffer: []u8,
        /// One slot per call that may be outstanding at once.
        pending: []Slot,
        decode_scratch: []u8,
        handler_scratch: []u8,
    };

    pub fn init(io: Io, reader: *Io.Reader, writer: *Io.Writer, config: Config) Conn {
        // Every slot starts free.
        //
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
            .handler_scratch = config.handler_scratch,
        };
    }

    pub fn setHandler(self: *Conn, handler: Handler) void {
        self.handler = handler;
    }

    /// The length of the request or notification most recently written into
    /// a caller's encode buffer.
    ///
    /// One field serves the whole connection, so it has one issuer: read it
    /// on the task that made the most recent `call` or `notify`, and nowhere
    /// else. Two tasks may call at once, and a read after the other task's
    /// call reports a length for a frame this task did not write.
    pub fn lastEncodedLen(self: *const Conn) usize {
        return self.last_encoded_len;
    }

    /// The id the next request will carry. Reported so a caller can predict
    /// and test the id sequence rather than having to parse the wire.
    pub fn nextId(self: *const Conn) i64 {
        return self.next_id;
    }

    /// Send a request and wait for its response.
    ///
    /// `params` is the raw JSON of the `params` member, or null to omit it.
    /// `out` receives the encoded request, so a proxy or a log can have the
    /// exact bytes. `result` receives the answer and is returned borrowed.
    pub fn call(
        self: *Conn,
        method: []const u8,
        params: ?[]const u8,
        result: []u8,
        out: []u8,
    ) Error!Response {
        // The connection may already be dead, in which case there is nothing
        // to send. A peer that hung up and a peer that overflowed our frame
        // buffer are different faults, so the caller is told which.
        if (self.closed) {
            return if (self.peer_frame_too_large) error.FrameTooLarge else error.Closed;
        }

        // Taken under the mutex, because two tasks may call at once. A
        // response is matched by id alone, so a read and an increment done
        // outside the mutex let two calls take the same id and one of them
        // answer the other. The multi-round-trip rule requires a retry to be a
        // genuinely new call, and that starts here.
        const id = self.takeId() orelse return error.Transport;
        const slot = self.claim(id, result) orelse return error.TooManyPending;

        // Encode before the id is published to the writer path: a request that
        // cannot be encoded must not leave a slot occupied.
        const encoded = self.encodeRequest(id, method, params, out) catch |err| {
            self.release(slot);
            return err;
        };
        self.writeFrame(encoded) catch |err| {
            self.release(slot);
            return err;
        };

        self.state_mutex.lock(self.io) catch return error.Transport;
        defer self.state_mutex.unlock(self.io);
        while (!slot.answered and !self.closed) {
            self.wake.wait(self.io, &self.state_mutex) catch return error.Transport;
        }
        if (!slot.answered) {
            releaseLocked(slot);
            return if (self.peer_frame_too_large) error.FrameTooLarge else error.ConnectionClosed;
        }
        const answer: Response = .{
            .body = result[0..slot.len],
            .error_code = if (slot.is_error) slot.error_code else null,
        };
        const overflowed = slot.overflowed;
        releaseLocked(slot);
        if (overflowed) return error.ResponseTooLarge;
        return answer;
    }

    /// Send a notification: a method with no id, which expects no answer.
    ///
    /// A frame that did not go out is reported, never swallowed. `params` is
    /// spliced into the message verbatim, so a newline in it is enough to
    /// break the framing, and `error.Framing` says so without condemning a
    /// transport that is working. A write that fails for any other reason
    /// marks the connection dead, because a task blocked in `call` on it would
    /// otherwise wait on a writer that cannot write.
    pub fn notify(self: *Conn, method: []const u8, params: ?[]const u8, out: []u8) Error!void {
        if (self.closed) return error.Closed;
        const encoded = self.encodeNotification(method, params, out) catch return error.ResponseTooLarge;
        self.writeFrame(encoded) catch |err| {
            if (err == error.Transport) self.shutdown();
            return err;
        };
    }

    /// Read frames and route them until the transport ends.
    ///
    /// The reader task's whole job. It blocks in the `readVec` that asks for
    /// more bytes, so a peer that goes quiet costs nothing.
    pub fn pump(self: *Conn) void {
        while (true) {
            // Take every complete frame before asking for more bytes, or a
            // busy peer would keep the framer full of unprocessed frames.
            while (self.framer.next()) |frame| self.route(frame);

            self.framer.slide();
            const space = self.framer.freeSpace();
            if (space.len == 0) {
                // A frame fills the buffer and still has no newline in it, so
                // the delimiter is not coming and the frame will never fit.
                // Dropping the buffer and reading on would not recover: the
                // tail of this frame is still on the wire, and it would be
                // read as the start of the next one. The connection ends here,
                // and the reason is recorded so a task waiting in `call` can be
                // told that the fault was ours.
                self.peer_frame_too_large = true;
                self.shutdown();
                return;
            }
            // `readVec`, not `readSliceShort`: the latter means "fill this
            // buffer completely", so it would block waiting for the remaining
            // kilobytes of a frame that has already fully arrived. This one
            // performs a single read and reports end of stream as an error.
            //
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
                // learns of both from the shutdown.
                self.shutdown();
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
            .response => self.deliver(message),
            .request, .notification => self.dispatch(frame, message),
        }
    }

    /// Hand a response to the call waiting for it.
    fn deliver(self: *Conn, message: jsonrpc.Message) void {
        // A string id is legal on the wire, but this connection allocates its
        // own ids as integers, so a string id cannot be one of ours and there
        // is nothing to match it against.
        const id = switch (message.id orelse return) {
            .integer => |value| value,
            .string => return,
        };

        self.state_mutex.lock(self.io) catch return;
        defer self.state_mutex.unlock(self.io);

        for (self.slots) |*slot| {
            if (!slot.used or slot.id != id or slot.answered) continue;
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
            break;
        }
        self.wake.signal(self.io);
    }

    /// Answer a request from the peer, or note a notification.
    fn dispatch(self: *Conn, frame: []const u8, message: jsonrpc.Message) void {
        const answer = self.handler.invoke(frame, self.handler_scratch) catch |err| {
            // A handler that failed did not decline the request. It tried to
            // answer and could not, and silence would leave the peer waiting on
            // a request that already arrived, so a request is answered with the
            // error it is owed. A transport that failed under the handler's
            // own hand takes the connection with it, because nothing else
            // written to it would arrive either.
            if (err == error.Transport) self.shutdown();
            self.refuse(message);
            return;
        };
        const body = answer orelse return;
        // The answer is composed and there is no second one to send, so a
        // write that fails here ends the connection instead of being retried.
        self.writeFrame(body) catch {
            self.shutdown();
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
    fn refuse(self: *Conn, message: jsonrpc.Message) void {
        if (message.kind != .request) return;
        // A request decoded by `route` carries a method, and `decodeRequest`
        // would have refused the message without one. Written out rather than
        // unwrapped because unwrapping is a trap on a path the kind check has
        // already narrowed, not closed.
        const request: jsonrpc.Request = .{
            .id = message.id orelse return,
            .method = message.method orelse return,
            .params = message.params,
        };
        // The handler failed, so nothing it wrote into the scratch is still
        // borrowed and the envelope can be built over it.
        const body = errorResponse(request, .{
            .code = @intFromEnum(jsonrpc.StandardError.internal_error),
            .message = "this peer could not serve the request",
        }, self.handler_scratch) catch return;
        self.writeFrame(body) catch {};
    }

    fn writeErrorBody(out: []u8, rpc_error: jsonrpc.Error) usize {
        var writer = json.Writer.init(out);
        writer.slice("{\"code\":") catch return 0;
        var number: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&number, "{d}", .{rpc_error.code}) catch return 0;
        writer.slice(text) catch return 0;
        writer.slice(",\"message\":") catch return 0;
        writer.string(rpc_error.message) catch return 0;
        writer.byte('}') catch return 0;
        return writer.len;
    }

    fn writeFrame(self: *Conn, bytes: []const u8) Error!void {
        self.write_mutex.lock(self.io) catch return error.Transport;
        defer self.write_mutex.unlock(self.io);
        // `framing.writeFrame` refuses a message carrying a raw newline by
        // returning `error.WriteFailed`, which is also what a short write
        // returns, so the two are told apart here against the same delimiter
        // the framing module uses. A caller's `params` blob is spliced in
        // verbatim, and reporting that as a transport failure would call a
        // healthy connection dead and invite a retry that fails identically.
        if (std.mem.indexOfScalar(u8, bytes, framing.delimiter) != null) return error.Framing;
        framing.writeFrame(bytes, self.writer) catch return error.Transport;
        self.writer.flush() catch return error.Transport;
    }

    /// Mark the connection dead and release everyone waiting on it.
    fn shutdown(self: *Conn) void {
        self.state_mutex.lock(self.io) catch return;
        self.closed = true;
        self.wake.broadcast(self.io);
        self.state_mutex.unlock(self.io);
    }

    fn claim(self: *Conn, id: i64, result: []u8) ?*Slot {
        self.state_mutex.lock(self.io) catch return null;
        defer self.state_mutex.unlock(self.io);
        for (self.slots) |*slot| {
            if (slot.used) continue;
            slot.* = .{ .id = id, .used = true, .result = result };
            return slot;
        }
        return null;
    }

    /// Take the next request id under the mutex.
    fn takeId(self: *Conn) ?i64 {
        self.state_mutex.lock(self.io) catch return null;
        defer self.state_mutex.unlock(self.io);
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn release(self: *Conn, slot: *Slot) void {
        self.state_mutex.lock(self.io) catch return;
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
        var writer = json.Writer.init(out);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch |err| return encodeFailure(err);
        var id_buffer: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{id}) catch
            return error.ResponseTooLarge;
        writer.slice(id_text) catch |err| return encodeFailure(err);
        writer.slice(",\"method\":") catch |err| return encodeFailure(err);
        writer.string(method) catch |err| return encodeFailure(err);
        if (params) |text| {
            writer.slice(",\"params\":") catch |err| return encodeFailure(err);
            writer.slice(text) catch |err| return encodeFailure(err);
        }
        writer.byte('}') catch |err| return encodeFailure(err);
        self.last_encoded_len = writer.len;
        return writer.written();
    }

    fn encodeNotification(
        self: *Conn,
        method: []const u8,
        params: ?[]const u8,
        out: []u8,
    ) Error![]const u8 {
        var writer = json.Writer.init(out);
        writer.slice("{\"jsonrpc\":\"2.0\",\"method\":") catch |err| return encodeFailure(err);
        writer.string(method) catch |err| return encodeFailure(err);
        if (params) |text| {
            writer.slice(",\"params\":") catch |err| return encodeFailure(err);
            writer.slice(text) catch |err| return encodeFailure(err);
        }
        writer.byte('}') catch |err| return encodeFailure(err);
        self.last_encoded_len = writer.len;
        return writer.written();
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
        if (data.len == 0) return 0;
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| count += try self.copy(bytes);
        var i: usize = 0;
        while (i < splat) : (i += 1) count += try self.copy(data[data.len - 1]);
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

/// Answers every request with a fixed envelope, and counts the requests it
/// saw, so a test can tell a dispatched frame from a dropped one.
const FixedAnswer = struct {
    calls: usize = 0,

    fn handle(ctx: ?*anyopaque, _: []const u8, scratch: []u8) Error!?[]const u8 {
        const self: *FixedAnswer = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
        @memcpy(scratch[0..body.len], body);
        return scratch[0..body.len];
    }
};

/// A handler that cannot answer, for the case where the peer has to be told.
const Failing = struct {
    fn handle(_: ?*anyopaque, _: []const u8, _: []u8) Error!?[]const u8 {
        return error.Transport;
    }
};

/// One `call` on a task of its own, so a test can drive a call and a pump over
/// one group and read the outcome after both have finished.
const Caller = struct {
    connection: *Conn,
    result: []u8,
    out: []u8,
    answer: ?(Error!Response) = null,

    fn run(self: *@This()) void {
        self.answer = self.connection.call(
            "tools/call",
            "{\"name\":\"echo\"}",
            self.result,
            self.out,
        );
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
    var handler_scratch: [64]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&.{});
    const connection = Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
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
    var handler_scratch: [256]u8 = undefined;
    var out_buffer: [256]u8 = undefined;
    var source = Scripted{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}\n",
        .silent_reads = 1,
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
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
    var handler_scratch: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var out_buffer: [256]u8 = undefined;
    var reader = Io.Reader.fixed("");
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
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

test "a notification that did not go out is reported, and it takes the connection with it" {
    // A notification whose write failed looked delivered, and the connection
    // stayed open, so a task blocked in `call` waited for an answer on a writer
    // that cannot write.
    var frame_buffer: [256]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [128]u8 = undefined;
    var handler_scratch: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var result: [128]u8 = undefined;
    var reader = Io.Reader.fixed("");
    // A writer with nowhere to put a byte: every write fails.
    var writer = Io.Writer.failing;
    var connection = Conn.init(testing.io, &reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
    });

    try testing.expectError(
        error.Transport,
        connection.notify("notifications/progress", null, &out),
    );
    // The connection is dead, so a task waiting in `call` is released rather
    // than left blocked on a writer that cannot write.
    try testing.expectError(error.Closed, connection.call("tools/list", null, &result, &out));
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
    var handler_scratch: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    // Far too small for the error object the peer sends.
    var result: [8]u8 = undefined;
    var sent: [256]u8 = undefined;
    var gate: Io.Event = .unset;
    var source = Scripted{
        .io = io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601," ++
            "\"message\":\"no such method\"}}\n",
        .gate = &gate,
    };
    var recorder = Recorder{ .io = io, .sent = &sent, .gate = &gate };
    var connection = Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
    });
    var caller = Caller{ .connection = &connection, .result = &result, .out = &out };

    // Both tasks on one group, because the call blocks on an answer only the
    // pump can deliver.
    var group: Io.Group = .init;
    group.async(io, Caller.run, .{&caller});
    group.async(io, pumpTask, .{&connection});
    group.await(io) catch {};

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
    var handler_scratch: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    // Big enough for the serialised error object, so the answer comes back
    // rather than being refused for want of room.
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    var gate: Io.Event = .unset;
    var source = Scripted{
        .io = io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601," ++
            "\"message\":\"no such method\"}}\n",
        .gate = &gate,
    };
    var recorder = Recorder{ .io = io, .sent = &sent, .gate = &gate };
    var connection = Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
    });
    var caller = Caller{ .connection = &connection, .result = &result, .out = &out };

    var group: Io.Group = .init;
    group.async(io, Caller.run, .{&caller});
    group.async(io, pumpTask, .{&connection});
    group.await(io) catch {};

    const answer = try caller.answer.?;
    try testing.expect(answer.failed());
    try testing.expectEqual(@as(?i32, -32601), answer.error_code);
    // The body carries the error object and not a result, which is precisely
    // why reading it without `failed` is the mistake this accessor removes.
    try testing.expect(std.mem.indexOf(u8, answer.body, "\"code\":-32601") != null);
    try testing.expect(std.mem.indexOf(u8, answer.body, "result") == null);

    // The other end of the rule: a call the peer answered is not a refusal,
    // and no code on a success is a failure.
    const answered: Response = .{ .body = "{}" };
    try testing.expect(!answered.failed());
}

test "a request whose handler failed is answered with an error" {
    // A handler that returned an error did not decline the request; it tried
    // to answer and could not. Silence leaves the peer waiting on a request
    // that already arrived, so a request is answered with the error it is owed.
    var frame_buffer: [512]u8 = undefined;
    var pending: [2]Slot = undefined;
    var decode_scratch: [256]u8 = undefined;
    var handler_scratch: [256]u8 = undefined;
    var out_buffer: [512]u8 = undefined;
    var source = Scripted{
        .io = testing.io,
        .bytes = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/list\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n",
    };
    var writer = Io.Writer.fixed(&out_buffer);
    var connection = Conn.init(testing.io, &source.reader, &writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
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
    var handler_scratch: [128]u8 = undefined;
    var out: [256]u8 = undefined;
    var result: [256]u8 = undefined;
    var sent: [256]u8 = undefined;
    // A peer that never sends the delimiter, and sends more of it than the
    // frame buffer can hold.
    var source = Scripted{ .io = io, .bytes = "x" ** 200 };
    var recorder = Recorder{ .io = io, .sent = &sent };
    var connection = Conn.init(io, &source.reader, &recorder.writer, .{
        .frame_buffer = &frame_buffer,
        .pending = &pending,
        .decode_scratch = &decode_scratch,
        .handler_scratch = &handler_scratch,
    });
    var caller = Caller{ .connection = &connection, .result = &result, .out = &out };

    var group: Io.Group = .init;
    group.async(io, Caller.run, .{&caller});
    group.async(io, pumpTask, .{&connection});
    group.await(io) catch {};

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
    try testing.expectError(error.ResponseTooLarge, respond(request, "{}", untouched[0..0]));
    try testing.expectEqual(@as(u8, 'Z'), untouched[0]);

    // Room for a prefix and not for the frame. The error is the guarantee: the
    // writer never advances past a write it refused, so what is left in the
    // buffer is a prefix, and a caller using `try` never sees it.
    var out: [8]u8 = undefined;
    try testing.expectError(error.ResponseTooLarge, respond(request, "{\"ok\":true}", &out));
    try testing.expectError(error.ResponseTooLarge, errorResponse(request, refusal, &out));
    try testing.expectError(error.ResponseTooLarge, methodNotFound(request, &out));
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

test "a message the grammar cannot carry is written through, not refused" {
    // `encodeFailure` answers every member of `root.EncodeError` with the one
    // `Error` member for a short buffer, and this is what stops that from being
    // wrong. It holds only while a message the encoder cannot carry is written
    // through rather than refused: a caller told its buffer is short about a
    // body it cannot encode grows the buffer and tries again forever, so the
    // day a `json.Writer` check refuses one, the two answers have to be told
    // apart and `Error` has to carry the difference. The `try` below is what
    // fails on that day, because the wrapper would return an error and this
    // expects a frame.
    var scratch: [128]u8 = undefined;
    const request = try jsonrpc.decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}",
        &scratch,
    );
    var out: [128]u8 = undefined;

    // A control byte the grammar forbids, which is escaped, and a byte that is
    // not UTF-8 at all, which is not. `writeString` escapes the first kind and
    // passes the second through, so the frame carries a literal this library's
    // own reader will refuse — and the wrapper reported no error on the way,
    // which is the whole of what `encodeFailure` depends on.
    const hostile = try errorResponse(
        request,
        .{ .code = -32601, .message = "line\nbreak\x07end\xff" },
        &out,
    );
    try testing.expect(std.mem.indexOf(
        u8,
        hostile,
        "\"message\":\"line\\nbreak\\u0007end",
    ) != null);
    // The last three bytes, read off the writers rather than counted. The
    // message's own closing quote, then the brace that closes the error object
    // — `jsonrpc.writeErrorObject` writes it, because the object is a member —
    // then the brace that closes the frame, which `jsonrpc.encodeResponse`
    // writes. `jsonrpc.encode` writes the same pair for a whole `Message`, so
    // the two agree and no answer in the tree is a brace short.
    try testing.expectEqual(@as(u8, 0xff), hostile[hostile.len - 4]);
    try testing.expectEqualStrings("}}", hostile[hostile.len - 2 ..]);

    // A refusal that fits reports nothing at all, which is the other half of
    // the same rule: the two cases are one answer, not two.
    const plain = try errorResponse(
        request,
        .{ .code = -32601, .message = "no such method" },
        &out,
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601," ++
            "\"message\":\"no such method\"}}",
        plain,
    );

    // `data` travels the same way, spliced, so a refusal carrying one is not a
    // body this layer refuses either.
    const carried = try errorResponse(request, .{
        .code = -32601,
        .message = "no such method",
        .data = "{\"why\":\"unknown\"}",
    }, &out);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601," ++
            "\"message\":\"no such method\",\"data\":{\"why\":\"unknown\"}}}",
        carried,
    );
}
