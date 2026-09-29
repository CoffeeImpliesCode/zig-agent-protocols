//! A demonstration of the library against real wire bytes.
//!
//! This is the `run` step. A protocol library that has only ever run its own
//! tests has never been used: this prints what each decoder actually produced,
//! from messages the specifications give verbatim, so a wrong tag value or a
//! mis-split header is visible rather than merely absent from a passing
//! assertion.
//!
//! Output goes to stdout through one buffered `std.Io.Writer` held open for
//! the whole run, so `zig build run > demo.txt` captures the lot and one
//! section's lines cannot be torn apart by the next. `std.debug.print` is the
//! wrong tool for a report: it is a debugging primitive that takes the stderr
//! lock and a 64-byte buffer per call, so the output is not one stream, and it
//! drops a write that fails rather than reporting it. Nothing here goes to
//! stderr; a section that failed is reported inline and the run continues.
//!
//! Every literal below is taken from a specification. Where a case is a
//! failure, the demo prints the error it got, because the error a hostile peer
//! provokes is as much a part of the contract as a success.

const std = @import("std");
const proto = @import("zig-agent-proto");

const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;
const acp = proto.acp;
const a2a = proto.a2a;
const bridge = proto.bridge;

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    showEverySection(out) catch |err| report(out, "the demonstration", err);
    try stdout.flush();
}

/// Run every section in order, reporting a failure rather than abandoning the
/// rest: the section that stops is the one that would have shown nothing, and
/// the other eight still say what the decoders produced.
fn showEverySection(out: *std.Io.Writer) !void {
    decodeAnMcpRequest(out) catch |err| report(out, "decodeAnMcpRequest", err);
    showRevisionGating(out) catch |err| report(out, "showRevisionGating", err);
    decodeAnMrtrResult(out) catch |err| report(out, "decodeAnMrtrResult", err);
    classifyHeaders(out) catch |err| report(out, "classifyHeaders", err);
    roundTripAStdioStream(out) catch |err| report(out, "roundTripAStdioStream", err);
    showThePermissionSafetyRule(out) catch |err| report(out, "showThePermissionSafetyRule", err);
    parseA2AVersions(out) catch |err| report(out, "parseA2AVersions", err);
    separateBridgeErrors(out) catch |err| report(out, "separateBridgeErrors", err);
    showThatHostileInputIsAnError(out) catch |err|
        report(out, "showThatHostileInputIsAnError", err);
}

/// A failed section is reported on the same stream as everything else. The
/// write cannot be reported: it is the reporting, and there is nothing above
/// this call to return an error to.
fn report(out: *std.Io.Writer, section: []const u8, err: anyerror) void {
    out.print("\n!! {s} failed: {s}\n", .{ section, @errorName(err) }) catch {};
}

fn heading(out: *std.Io.Writer, text: []const u8) !void {
    try out.print("\n== {s} ==\n", .{text});
}

fn decodeAnMcpRequest(out: *std.Io.Writer) !void {
    try heading(out, "MCP: a tools/call request");
    // A `2026-07-28` request carries the revision and the client capabilities in
    // `_meta` on every request, because that revision removed the handshake.
    const text =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"
        \\,"params":{"name":"search","arguments":{"q":"zig"}
        \\,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"
        \\,"io.modelcontextprotocol/clientCapabilities":{}}}}
    ;
    // The scratch is measured from the message rather than guessed at. This
    // one carries no escape sequence, so the reader unescapes nothing and the
    // buffer is empty; the message further down, which does carry one, is
    // sized by the same line.
    var scratch: [json.Reader.requiredScratchLen(text)]u8 = undefined;
    const message = try jsonrpc.decode(text, &scratch);
    try out.print("  kind      {s}\n", .{@tagName(message.kind)});
    try out.print("  id        {d}\n", .{message.id.?.integer});
    try out.print("  method    {s}  (category '{s}', action '{s}')\n", .{
        message.method.?.text,
        message.method.?.category,
        message.method.?.action,
    });

    const info = try mcp.lookupMethod(.current, message.method.?.text);
    try out.print("  resolved  direction={s} cacheable={} mrtr={}\n", .{
        @tagName(info.direction),
        info.cacheable,
        info.mrtr,
    });

    // Re-encoding and decoding again yields the same value.
    var buffer: [1024]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try jsonrpc.encode(message, &writer);
    const again = try jsonrpc.decode(writer.written(), &scratch);
    try out.print("  round trip id {d} method {s}: {s}\n", .{
        again.id.?.integer,
        again.method.?.text,
        if (again.kind == message.kind) "identical" else "DIFFERENT",
    });
}

fn showRevisionGating(out: *std.Io.Writer) !void {
    try heading(out, "MCP: two revisions, not one revision with a flag");
    for (mcp.removed_methods) |removed| {
        // The same name resolved against each revision. A decoder pinned to
        // the current revision refuses it; one pinned to the previous accepts.
        try out.print("  {s:<34} current={s:<14} previous={s}\n", .{
            removed.name,
            resolution(mcp.lookupMethod(.current, removed.name)),
            resolution(mcp.lookupMethod(.previous, removed.name)),
        });
    }
}

/// Render a method lookup as the short word a reader wants to see.
fn resolution(result: proto.DecodeError!mcp.MethodInfo) []const u8 {
    return if (result) |_| "resolves" else |err| @errorName(err);
}

fn decodeAnMrtrResult(out: *std.Io.Writer) !void {
    try heading(out, "MCP: an input_required result carrying a server request");
    // `requestState` is attacker-controlled, so the demo prints it and never
    // interprets it.
    const raw =
        \\{"resultType":"input_required"
        \\,"inputRequests":{"e1":{"method":"elicitation/create"
        \\,"params":{"message":"confirm?"}}}
        \\,"requestState":"eyJzdWIiOiJ1MSJ9"}
    ;
    var scratch: [256]u8 = undefined;
    const result = try mcp.decodeInputRequiredResult(raw, &scratch);
    try out.print("  resultType   {s}\n", .{result.result_type.value.?});
    try out.print("  requests     present={}\n", .{result.input_requests != null});
    try out.print("  requestState {s}  (carried, not parsed)\n", .{result.request_state.?});
    try out.print("  MRTR allowed on tools/call: {}\n", .{mcp.permitsMrtr("tools/call")});
    try out.print("  MRTR allowed on tools/list: {}\n", .{mcp.permitsMrtr("tools/list")});
}

fn classifyHeaders(out: *std.Io.Writer) !void {
    try heading(out, "MCP: header casing is a trap, so matching is case-insensitive");
    const names = [_][]const u8{
        "MCP-Protocol-Version",
        "mcp-protocol-version",
        "Mcp-Method",
        "Mcp-Name",
        "Mcp-Param-city",
        "Mcp-Session-Id",
        "Last-Event-ID",
        "x-mcp-header",
    };
    for (names) |name| {
        try out.print("  {s:<22} -> {s}\n", .{ name, @tagName(mcp.headerKind(name)) });
    }

    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    // The base64 output buffer is the caller's, sized from the input.
    var sentinel_scratch: [mcp.sentinelScratchLen("Zürich".len)]u8 = undefined;
    try mcp.encodeHeaderValue("Zürich", &writer, &sentinel_scratch);
    try out.print("  sentinel encode of 'Zürich': {s}\n", .{writer.written()});

    var scratch: [64]u8 = undefined;
    const decoded = try mcp.decodeHeaderValue(writer.written(), &scratch);
    try out.print("  decoded back: {s}\n", .{decoded});
}

fn roundTripAStdioStream(out: *std.Io.Writer) !void {
    try heading(out, "ACP: newline-delimited stdio framing");
    // Two messages on one stream, the second without its delimiter yet.
    const stream =
        \\{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp"}}
        \\{"jsonrpc":"2.0","method":"session/cancel"}
    ;
    var rest: []const u8 = stream;
    var index: usize = 0;
    while (rest.len != 0) {
        const frame = try acp.nextFrame(rest);
        index += 1;
        var scratch: [256]u8 = undefined;
        const message = try jsonrpc.decode(frame.bytes, &scratch);
        try out.print("  frame {d}: {s} {s} (terminated={})\n", .{
            index,
            @tagName(message.kind),
            message.method.?.text,
            !frame.unterminated,
        });
        const info = try acp.lookupMethod(.stable, message.method.?.text);
        try out.print("          side={s} notification={}\n", .{
            @tagName(info.side),
            info.notification,
        });
        rest = frame.rest;
    }
    try out.print("  frames read: {d}\n", .{index});
}

fn showThePermissionSafetyRule(out: *std.Io.Writer) !void {
    try heading(out, "ACP: an outcome an agent does not understand is not approval");
    // Quoted rather than multiline: consecutive `\\` literals in an array
    // initializer concatenate into one element, which would make this a single
    // case instead of four.
    const cases = [_][]const u8{
        "{\"outcome\":\"selected\",\"optionId\":\"opt-1\"}",
        "{\"outcome\":\"cancelled\"}",
        "{\"outcome\":\"approved\"}",
        "{\"outcome\":\"allow_once\",\"optionId\":\"opt-1\"}",
    };
    for (cases, 0..) |case, index| {
        var scratch: [128]u8 = undefined;
        const result = acp.decodePermissionOutcome(case, &scratch) catch |err| {
            try out.print("  case {d}: error.{s}\n", .{ index + 1, @errorName(err) });
            continue;
        };
        switch (result) {
            .cancelled => try out.print("  case {d}: cancelled\n", .{index + 1}),
            .selected => |id| try out.print("  case {d}: selected {s}\n", .{ index + 1, id }),
        }
    }
    try out.print("  An agent MUST NOT treat an unrecognised outcome as approval.\n", .{});
}

fn parseA2AVersions(out: *std.Io.Writer) !void {
    try heading(out, "A2A: A2A-Version is Major.Minor, and empty means 0.3");
    const headers = [_][]const u8{ "", "0.3", "1.0", "1.0.0", "1", "x.y" };
    for (headers) |header| {
        const shown: []const u8 = if (header.len == 0) "<empty>" else header;
        const version = a2a.parseVersion(header) catch |err| {
            try out.print("  A2A-Version: {s:<10} -> error.{s}\n", .{ shown, @errorName(err) });
            continue;
        };
        try out.print("  A2A-Version: {s:<10} -> {d}.{d}\n", .{
            shown,
            version.major,
            version.minor,
        });
    }

    try out.print("\n  TaskState wire names and classification:\n", .{});
    inline for (@typeInfo(a2a.TaskState).@"enum".fields) |field| {
        const value: a2a.TaskState = @field(a2a.TaskState, field.name);
        const class = if (a2a.isTerminal(value))
            "terminal"
        else if (a2a.isInterrupted(value))
            "interrupted"
        else
            "-";
        try out.print("    {d}  {s:<26} {s}\n", .{ @intFromEnum(value), value.wireName(), class });
    }

    try out.print("\n  The nine A2A errors; six share one status pair:\n", .{});
    inline for (@typeInfo(a2a.A2aError).@"enum".fields) |field| {
        const value: a2a.A2aError = @field(a2a.A2aError, field.name);
        try out.print("    {d}  {s:<38} http {d}  grpc {s}\n", .{
            @intFromEnum(value),
            value.reason(),
            value.httpStatus(),
            value.grpcStatus(),
        });
    }
}

fn separateBridgeErrors(out: *std.Io.Writer) !void {
    try heading(out, "mcp-over-acp: an inner MCP error is a successful outer response");
    var scratch: [256]u8 = undefined;

    // A successful outer response carrying an inner MCP error object.
    const inner = try bridge.decodeOutcome(
        \\{"error":{"code":-32602,"message":"unknown tool"}}
    , &scratch);
    try out.print("  outer: success, inner: {s}\n", .{
        if (inner == .@"error") "MCP error" else "MCP result",
    });

    // A binding-level failure is an outer error with its own code. The level is
    // explicit, so an inner code can never be read as a binding failure.
    for ([_]i32{ -32602, -32800, -33000, -33001, -33002 }) |code| {
        try out.print("  outer code {d}: binding failure = {}\n", .{
            code,
            bridge.isBindingFailure(code, .outer),
        });
    }
    // An inner code is never a binding failure, even at a code the outer space
    // also uses. `-32602` is the collision the level tag exists for.
    for ([_]i32{ -32000, -32001, -32020, -32602 }) |code| {
        try out.print("  inner code {d}: binding failure = {}\n", .{
            code,
            bridge.isBindingFailure(code, .inner),
        });
    }
}

fn showThatHostileInputIsAnError(out: *std.Io.Writer) !void {
    try heading(out, "Hostile input is an error, never a panic");
    var scratch: [64]u8 = undefined;

    // Quoted rather than multiline, for the same reason as the other case
    // array: consecutive `\\` literals concatenate.
    const cases = [_][]const u8{
        // A `null` id, which JSON-RPC permits and MCP forbids.
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"tools/call\"}",
        // Both result and error on one message.
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":1,\"message\":\"m\"}}",
        // Neither, on a response.
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        // Truncated mid-object.
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a",
    };
    for (cases, 0..) |case, index| {
        if (jsonrpc.decode(case, &scratch)) |_| {
            try out.print("  case {d}: decoded\n", .{index + 1});
        } else |err| {
            try out.print("  case {d}: error.{s}\n", .{ index + 1, @errorName(err) });
        }
    }

    // Nesting is bounded, so a hostile peer cannot exhaust the stack.
    var deep: [proto.json.max_depth + 8]u8 = undefined;
    @memset(deep[0 .. proto.json.max_depth + 4], '[');
    var reader = json.Reader.init(deep[0 .. proto.json.max_depth + 4]);
    const deep_name: []const u8 = if (reader.skipValue("")) |_| "accepted" else |err| @errorName(err);
    try out.print("  {d} open brackets -> {s}\n", .{ proto.json.max_depth + 4, deep_name });

    // An id past f64 precision, which an f64 round trip would corrupt.
    var wide: [128]u8 = undefined;
    const wide_message = try jsonrpc.decode(
        \\{"jsonrpc":"2.0","id":9007199254740993,"method":"m"}
    , &wide);
    try out.print("  id 9007199254740993 survives as i64 {d}\n", .{wide_message.id.?.integer});

    // The scratch a decode needs is measured from the message, not guessed.
    // A string with no escape borrows the input and costs nothing, which is
    // why the message above needed no buffer at all. This one carries `\/`,
    // so its method is unescaped into a region of the caller's, and the
    // whole decoded method is what has to fit: ten bytes. The same
    // expression sizes any message, and the size follows the wire.
    const escaped =
        \\{"jsonrpc":"2.0","id":1,"method":"tools\/call"}
    ;
    var sized: [json.Reader.requiredScratchLen(escaped)]u8 = undefined;
    const escaped_message = try jsonrpc.decode(escaped, &sized);
    try out.print("  escaped method needs {d} scratch bytes, decoded '{s}'\n", .{
        sized.len,
        escaped_message.method.?.text,
    });
}
