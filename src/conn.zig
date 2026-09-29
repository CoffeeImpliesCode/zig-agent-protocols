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
};

/// A handler for a request or notification from the peer.
///
/// Returning null means "no answer", which is correct for a notification and
/// leaves a peer's request unanswered. See the module doc for why this runs
/// inline.
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
    /// `call` or `notify`. Reported rather than returned because the buffer is
    /// the caller's, and a caller that cannot learn the length cannot log or
    /// proxy what went out.
    last_encoded_len: usize = 0,
    closed: bool = false,
    /// Serialises writes. Two tasks may call at once, and a frame interleaved
    /// with another is two malformed frames on the wire.
    write_mutex: Io.Mutex = .init,
    /// Guards the pending table, `closed`, and the waiting condition.
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
    /// the caller's encode buffer. Valid immediately after `call` or `notify`.
    ///
    /// Concurrent callers on one connection each get their own buffer, so
    /// this is only meaningful to the task whose buffer it is.
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
        if (self.closed) return error.Closed;

        const id = self.next_id;
        // Claimed and incremented together, on the assumption that the caller
        // is the only one issuing on this connection. Two calls sharing an id
        // would let one steal the other's answer, and the multi-round-trip
        // rule requires a retry to be a genuinely new call.
        self.next_id += 1;
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
            slot.used = false;
            return error.ConnectionClosed;
        }
        const answer: Response = .{
            .body = result[0..slot.len],
            .error_code = if (slot.is_error) slot.error_code else null,
        };
        const overflowed = slot.overflowed;
        slot.used = false;
        if (overflowed) return error.ResponseTooLarge;
        return answer;
    }

    /// Send a notification: a method with no id, which expects no answer.
    pub fn notify(self: *Conn, method: []const u8, params: ?[]const u8, out: []u8) Error!void {
        if (self.closed) return error.Closed;
        const encoded = self.encodeNotification(method, params, out) catch return error.ResponseTooLarge;
        self.writeFrame(encoded) catch return;
    }

    /// Read frames and route them until the transport ends.
    ///
    /// The reader task's whole job. It blocks in `readSliceShort`, so a peer
    /// that goes quiet costs nothing.
    pub fn pump(self: *Conn) void {
        while (true) {
            // Take every complete frame before asking for more bytes, or a
            // busy peer would keep the framer full of unprocessed frames.
            while (self.framer.next()) |frame| self.route(frame);

            self.framer.slide();
            const space = self.framer.freeSpace();
            if (space.len == 0) {
                // A frame fills the buffer and still has no newline in it, so
                // it will never fit. Drop it and keep reading: closing is the
                // caller's decision, not ours.
                self.framer.reset();
                continue;
            }
            // `readVec`, not `readSliceShort`: the latter means "fill this
            // buffer completely", so it would block waiting for the remaining
            // kilobytes of a frame that has already fully arrived. This one
            // performs a single read, waits for at least one byte, and reports
            // end of stream rather than silence.
            var slots = [_][]u8{space};
            const got = self.reader.readVec(&slots) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => {
                    self.shutdown();
                    return;
                },
            };
            if (got == 0) {
                self.shutdown();
                return;
            }
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
            .request, .notification => self.dispatch(frame),
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
    fn dispatch(self: *Conn, frame: []const u8) void {
        const answer = self.handler.invoke(frame, self.handler_scratch) catch return;
        const body = answer orelse return;
        self.writeFrame(body) catch return;
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

    fn release(self: *Conn, slot: *Slot) void {
        self.state_mutex.lock(self.io) catch return;
        defer self.state_mutex.unlock(self.io);
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
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.ResponseTooLarge;
        var id_buffer: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{id}) catch return error.ResponseTooLarge;
        writer.slice(id_text) catch return error.ResponseTooLarge;
        writer.slice(",\"method\":") catch return error.ResponseTooLarge;
        writer.string(method) catch return error.ResponseTooLarge;
        if (params) |text| {
            writer.slice(",\"params\":") catch return error.ResponseTooLarge;
            writer.slice(text) catch return error.ResponseTooLarge;
        }
        writer.byte('}') catch return error.ResponseTooLarge;
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
        writer.slice("{\"jsonrpc\":\"2.0\",\"method\":") catch return error.ResponseTooLarge;
        writer.string(method) catch return error.ResponseTooLarge;
        if (params) |text| {
            writer.slice(",\"params\":") catch return error.ResponseTooLarge;
            writer.slice(text) catch return error.ResponseTooLarge;
        }
        writer.byte('}') catch return error.ResponseTooLarge;
        self.last_encoded_len = writer.len;
        return writer.written();
    }
};
