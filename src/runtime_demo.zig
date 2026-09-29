//! A working MCP server and client over stdio, in one process.
//!
//! The point of this example is that it is not a mock. A real connection, a
//! real `Io`, a real socket pair, real JSON-RPC frames, and the same
//! [`conn.Conn`] a server binary would use. The codec in `src/*.zig` has its
//! own tests, but a codec that has only ever been tested against slices has
//! never been driven by a transport, and that is the gap this closes.
//!
//! The server answers `tools/list` and `tools/call`; the client calls both and
//! prints what came back. Everything is caller-owned buffers, so the example
//! doubles as a check that the API is usable without an allocator.
//!
//! Run it with `zig build run`.

const std = @import("std");
const proto = @import("zig-agent-proto");

const conn = proto.conn;
const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;
const mcp_session = proto.mcp_session;

const Io = std.Io;

/// A server that answers the two methods this example exercises.
const ToolServer = struct {
    calls: usize = 0,

    fn handle(ctx: ?*anyopaque, frame: []const u8, scratch: []u8) conn.Error!?[]const u8 {
        const self: *ToolServer = @ptrCast(@alignCast(ctx.?));
        const message = jsonrpc.decode(frame, scratch) catch return null;
        if (message.kind != .request) return null;

        const id = message.id orelse return null;
        const method = message.method orelse return null;
        self.calls += 1;

        // The scratch is this connection's handler buffer, so the answer can
        // borrow it for the length of the write.
        var writer = json.Writer.init(scratch);
        writer.slice("{\"jsonrpc\":\"2.0\",\"id\":") catch return null;
        var id_buffer: [24]u8 = undefined;
        const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{id.integer}) catch return null;
        writer.slice(id_text) catch return null;
        writer.slice(",\"result\":") catch return null;

        if (std.mem.eql(u8, method.text, "tools/list")) {
            writer.slice("{\"tools\":[{\"name\":\"echo\",\"description\":\"echo it back\"}]}") catch return null;
        } else if (std.mem.eql(u8, method.text, "tools/call")) {
            writer.slice("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"echo\"}]}") catch return null;
        } else {
            // A method this server does not have gets the specification's
            // code, not a guess and not silence.
            writer.slice("{\"code\":-32601,\"message\":\"Method not found\"}") catch return null;
        }
        writer.byte('}') catch return null;
        return writer.written();
    }
};

/// One end of the connection: the buffers and the connection over them.
const Side = struct {
    buffers: proto.stdio.Buffers = .{},
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
    connection: conn.Conn = undefined,
    stream: Io.net.Stream = undefined,
    /// Held here rather than as locals in `open`: the connection keeps raw
    /// pointers to both interfaces, and a local would dangle the moment `open`
    /// returned.
    reader: Io.net.Stream.Reader = undefined,
    writer: Io.net.Stream.Writer = undefined,

    fn open(self: *Side, io: Io, group: *Io.Group, stream: Io.net.Stream, handler: ?conn.Handler) void {
        self.stream = stream;
        self.reader = Io.net.Stream.Reader.init(stream, io, &self.reader_buffer);
        self.writer = Io.net.Stream.Writer.init(stream, io, &self.writer_buffer);
        self.connection = conn.Conn.init(io, &self.reader.interface, &self.writer.interface, self.buffers.config());
        if (handler) |h| self.connection.setHandler(h);
        group.async(io, pump, .{&self.connection});
    }

    fn pump(c: *conn.Conn) void {
        c.pump();
    }
};

/// Keep an encoded request so the example can show exactly what went out.
///
/// The current revision has no handshake, so this is where the `_meta`
/// wrapper carrying the client capabilities becomes visible.
fn keepEncoded(into: []u8, into_len: *usize, encoded: []const u8) void {
    const text = encoded;
    const n = @min(text.len, into.len);
    @memcpy(into[0..n], text[0..n]);
    into_len.* = n;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    defer stdout.flush() catch {};

    try out.print("zig-agent-proto runtime example\n\n", .{});
    try out.print("  zig       {s}\n", .{@tagName(@import("builtin").cpu.arch)});
    try out.print("  mcp       {s} (pinned)\n", .{mcp.latest_protocol_version});
    try out.print("  a2a       1.0.0\n", .{});
    try out.print("  acp       1 (v2 gated)\n\n", .{});

    // A real socket pair, so this is the same code path a subprocess would
    // take over a pipe. stdio is the normative ACP transport and one of the two
    // MCP ones; a socket exercises the identical framing and JSON-RPC.
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/zig-agent-proto-example-{d}.sock", .{
        std.os.linux.getpid(),
    });
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var server_side: Side = .{};
    var client_side: Side = .{};
    var tools: ToolServer = .{};
    // One buffer per response, so each is reported as what it was rather than
    // as a slice of a concatenation.
    var list_reply: [2048]u8 = undefined;
    var list_len: usize = 0;
    var call_reply: [2048]u8 = undefined;
    var call_len: usize = 0;
    var last_sent: [2048]u8 = undefined;
    var last_sent_len: usize = 0;

    const Peer = struct {
        io: Io,
        group: *Io.Group,
        server: *Io.net.Server,
        side: *Side,
        handler: *ToolServer,

        fn run(self: *@This()) void {
            const stream = self.server.accept(self.io) catch return;
            // The reader runs on the shared group and ends by itself when the
            // client hangs up, so this task has nothing left to do.
            self.side.open(self.io, self.group, stream, .{ .ctx = self.handler, .call = ToolServer.handle });
        }
    };

    const Client = struct {
        io: Io,
        group: *Io.Group,
        address: *Io.net.UnixAddress,
        side: *Side,
        list_reply: []u8,
        list_len: *usize,
        call_reply: []u8,
        call_len: *usize,
        last_sent: []u8,
        last_sent_len: *usize,
        failed: bool = false,

        /// Record the last request as it went on the wire.
        fn remember(self: *@This(), encoded: []u8, length: usize) void {
            keepEncoded(self.last_sent, self.last_sent_len, encoded[0..length]);
        }

        fn run(self: *@This()) void {
            const stream = self.address.connect(self.io) catch {
                self.failed = true;
                return;
            };
            self.side.open(self.io, self.group, stream, null);

            // A session pinned to the current revision. There is no handshake
            // here, so the capabilities ride on each request in `_meta`.
            var session = mcp_session.Client.init(&self.side.connection, .current);
            session.capabilities = "{\"tools\":{}}";

            var result_buffer: [4096]u8 = undefined;
            var out_buffer_local: [4096]u8 = undefined;
            var params_buffer: [4096]u8 = undefined;

            const listed = session.request(
                "tools/list",
                null,
                &result_buffer,
                &out_buffer_local,
                &params_buffer,
            ) catch {
                self.failed = true;
                return;
            };
            if (listed.len <= self.list_reply.len) {
                @memcpy(self.list_reply[0..listed.len], listed);
                self.list_len.* = listed.len;
            }
            self.remember(&out_buffer_local, self.side.connection.lastEncodedLen());

            const called = session.request(
                "tools/call",
                "{\"name\":\"echo\"}",
                &result_buffer,
                &out_buffer_local,
                &params_buffer,
            ) catch {
                self.failed = true;
                return;
            };
            if (called.len <= self.call_reply.len) {
                @memcpy(self.call_reply[0..called.len], called);
                self.call_len.* = called.len;
            }
            self.remember(&out_buffer_local, self.side.connection.lastEncodedLen());

            self.side.stream.shutdown(self.io, .both) catch {};
            self.side.stream.close(self.io);
        }
    };

    // One group drives both ends. Two would deadlock: the client blocks waiting
    // for an answer only the peer's task can produce.
    var group: Io.Group = .init;
    var peer = Peer{
        .io = io,
        .group = &group,
        .server = &server,
        .side = &server_side,
        .handler = &tools,
    };
    var client = Client{
        .io = io,
        .group = &group,
        .address = &address,
        .side = &client_side,
        .list_reply = &list_reply,
        .list_len = &list_len,
        .call_reply = &call_reply,
        .call_len = &call_len,
        .last_sent = &last_sent,
        .last_sent_len = &last_sent_len,
    };

    group.async(io, Peer.run, .{&peer});
    group.async(io, Client.run, .{&client});
    // Join, do not cancel: cancelling here would stop both tasks before they
    // ran. The client hangs up when it is done, the peer sees end of file, and
    // both pumps return on their own.
    group.await(io) catch {};

    if (client.failed) {
        try out.print("the exchange failed\n", .{});
        return;
    }

    try out.print("tools/list ->\n  {s}\n", .{list_reply[0..list_len]});
    try out.print("tools/call ->\n  {s}\n", .{call_reply[0..call_len]});
    try out.print("\nlast request on the wire:\n  {s}\n", .{last_sent[0..last_sent_len]});
    try out.print("server handled {d} request(s)\n", .{tools.calls});
}
