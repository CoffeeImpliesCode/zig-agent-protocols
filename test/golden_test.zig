//! Golden-vector decode tests over the specifications' own worked examples.
//!
//! Every fixture under `test/golden/` is either a verbatim JSON block lifted
//! out of `research/normative/`, or a document whose member names are verbatim
//! from the schema tables in the same files. The source line for each one is
//! recorded beside the test that decodes it. A hand-written unit test only
//! catches a regression if the author happened to write the same case twice;
//! these vectors make the normative examples themselves the regression net, so
//! a change to a tag, a spelling or a required member moves one of them.
//!
//! ## Provenance
//!
//! Verbatim JSON blocks, copied without reformatting:
//!
//! | Fixture | Source |
//! | --- | --- |
//! | `mcp_message_request.json` | `research/normative/acp-v1-v2.md` 10a, the `mcp-over-acp` RFD worked example |
//! | `a2a_jsonrpc_error.json` | `research/normative/a2a-1.0.0.md` 6.4, the JSON-RPC error envelope |
//! | `a2a_rest_error.json` | `research/normative/a2a-1.0.0.md` 6.4, the HTTP+JSON/REST error envelope |
//! | `a2a_agent_card_signature.json` | `research/normative/a2a-1.0.0.md` 7.2, the `signatures` shape |
//! | `mcp_client_capabilities.json` | `research/normative/mcp-2026-07-28.md` 6, `ClientCapabilities` |
//! | `mcp_server_capabilities.json` | `research/normative/mcp-2026-07-28.md` 6, `ServerCapabilities` |
//! | `acp_initialize_capabilities_v1.json` | `research/normative/acp-v1-v2.md` 10e, the v1 RFD fragment |
//! | `acp_initialize_capabilities_v2.json` | `research/normative/acp-v1-v2.md` 10e, the v2 RFD fragment |
//!
//! Member names verbatim, values chosen here because the specification
//! publishes the shape and not an example document:
//!
//! | Fixture | Source |
//! | --- | --- |
//! | `mcp_mrtr_result.json` | `mcp-2026-07-28.md` 4.7, the `InputRequiredResult` interface |
//! | `acp_session_new_request.json` | `acp-v1-v2.md` 3a and 10e, the v1 `session/new`
//!   required list and the server declaration |
//! | `acp_permission_outcome_selected.json` | `acp-v1-v2.md` 5b, the `selected` branch of `RequestPermissionOutcome` |
//! | `acp_permission_outcome_cancelled.json` | `acp-v1-v2.md` 5b, the `cancelled` branch |
//! | `acp_permission_request_v1.json` | `acp-v1-v2.md` 5a and 5c, the v1 required lists |
//! | `jsonrpc_request.json`, `jsonrpc_notification.json` | `mcp-2026-07-28.md` section 1, the JSON-RPC message table |
//! | `bridge_outcome_error.json` | `acp-v1-v2.md` 10d, `-32022` inside the outcome carrier |
//! | `bridge_outcome_result.json` | `mcp-2026-07-28.md` 5, a `complete` result |

const std = @import("std");
const proto = @import("zig-agent-protocols");

const json = proto.json;
const jsonrpc = proto.jsonrpc;
const mcp = proto.mcp;
const a2a = proto.a2a;
const acp = proto.acp;
const bridge = proto.bridge;

const DecodeError = proto.DecodeError;
const testing = std.testing;

/// The fixture bytes, embedded at compile time.
///
/// Embedding rather than reading keeps `zig build test` hermetic: a fixture
/// that is deleted or renamed fails the build instead of quietly skipping.
const Fixture = struct {
    a2a_agent_card_signature: []const u8 = @embedFile("golden/a2a_agent_card_signature.json"),
    a2a_jsonrpc_error: []const u8 = @embedFile("golden/a2a_jsonrpc_error.json"),
    a2a_rest_error: []const u8 = @embedFile("golden/a2a_rest_error.json"),
    acp_initialize_capabilities_v1: []const u8 = @embedFile("golden/acp_initialize_capabilities_v1.json"),
    acp_initialize_capabilities_v2: []const u8 = @embedFile("golden/acp_initialize_capabilities_v2.json"),
    acp_permission_outcome_cancelled: []const u8 = @embedFile("golden/acp_permission_outcome_cancelled.json"),
    acp_permission_outcome_selected: []const u8 = @embedFile("golden/acp_permission_outcome_selected.json"),
    acp_permission_request_v1: []const u8 = @embedFile("golden/acp_permission_request_v1.json"),
    acp_session_new_request: []const u8 = @embedFile("golden/acp_session_new_request.json"),
    bridge_outcome_error: []const u8 = @embedFile("golden/bridge_outcome_error.json"),
    bridge_outcome_result: []const u8 = @embedFile("golden/bridge_outcome_result.json"),
    jsonrpc_notification: []const u8 = @embedFile("golden/jsonrpc_notification.json"),
    jsonrpc_request: []const u8 = @embedFile("golden/jsonrpc_request.json"),
    mcp_client_capabilities: []const u8 = @embedFile("golden/mcp_client_capabilities.json"),
    mcp_client_capabilities_meta: []const u8 = @embedFile("golden/mcp_client_capabilities_meta.json"),
    mcp_message_request: []const u8 = @embedFile("golden/mcp_message_request.json"),
    mcp_mrtr_result: []const u8 = @embedFile("golden/mcp_mrtr_result.json"),
    mcp_server_capabilities: []const u8 = @embedFile("golden/mcp_server_capabilities.json"),
};

const fixture: Fixture = .{};

// --- Borrow-reader helpers ----------------------------------------------------
//
// Each helper runs its own `json.Reader`, and a `Reader` hands out scratch
// regions by bumping a high-water mark that starts at zero. Two readers sharing
// one buffer would therefore overwrite each other's results, so every helper
// takes a distinct region from this pool.

/// Scratch regions handed out one at a time, so two live results never share
/// one. A helper that runs out reports the same `BufferTooSmall` the library
/// does rather than aliasing a region that is still in use.
const ScratchPool = struct {
    buffers: [16][256]u8 = undefined,
    used: usize = 0,

    fn next(self: *ScratchPool) DecodeError![]u8 {
        if (self.used == self.buffers.len) return error.BufferTooSmall;
        const buffer = self.buffers[self.used][0..];
        self.used += 1;
        return buffer;
    }
};

/// A member of a borrowed object: its key, and its value as raw JSON text.
const Member = struct {
    key: []const u8,
    value: []const u8,
};

/// The raw JSON text of the member named `key`, or null when it is absent.
fn rawMember(input: []const u8, key: []const u8, scratch: []u8) DecodeError!?[]const u8 {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |name| {
        if (std.mem.eql(u8, name, key)) return try reader.rawValue(scratch);
        try reader.skipValue(scratch);
    }
    return null;
}

/// The decoded string value of the member named `key`, or null when absent.
fn stringMember(input: []const u8, key: []const u8, scratch: []u8) DecodeError!?[]const u8 {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |name| {
        if (std.mem.eql(u8, name, key)) return try reader.string(scratch);
        try reader.skipValue(scratch);
    }
    return null;
}

/// The number lexeme of the member named `key`, or null when absent.
///
/// The lexeme is returned rather than a parsed value so the test can pin the
/// bytes the specification published, including a sign and a decimal point.
fn numberMember(input: []const u8, key: []const u8, scratch: []u8) DecodeError!?[]const u8 {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |name| {
        if (std.mem.eql(u8, name, key)) return try reader.number();
        try reader.skipValue(scratch);
    }
    return null;
}

fn booleanMember(input: []const u8, key: []const u8, scratch: []u8) DecodeError!?bool {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |name| {
        if (std.mem.eql(u8, name, key)) return try reader.boolean();
        try reader.skipValue(scratch);
    }
    return null;
}

/// The first element of an array, as raw JSON text, or null when empty.
fn firstArrayElement(input: []const u8, scratch: []u8) DecodeError!?[]const u8 {
    var reader = json.Reader.init(input);
    if (try reader.beginArray()) return null;
    if (!try reader.nextArrayElement()) return null;
    return try reader.rawValue(scratch);
}

/// The first member of an object, key and raw value together.
fn firstMember(input: []const u8, scratch: []u8) DecodeError!?Member {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return null;
    const key = (try reader.nextKey(scratch)) orelse return null;
    return .{ .key = key, .value = try reader.rawValue(scratch) };
}

/// Every member key of an object, in wire order, into `out`.
fn memberKeys(input: []const u8, out: [][]const u8, scratch: []u8) DecodeError!usize {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return 0;
    var count: usize = 0;
    while (try reader.nextKey(scratch)) |key| {
        if (count == out.len) return error.BufferTooSmall;
        out[count] = key;
        count += 1;
        try reader.skipValue(scratch);
    }
    return count;
}

fn findCapability(entries: []const acp.Capability, path: []const u8) ?acp.Capability {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

/// The integer an id carries, or null when the id is absent or a string.
///
/// JSON-RPC 2.0 admits both, and a fixture pins one or the other, so the test
/// reads the arm rather than comparing unions whose slice arm compares as a
/// pointer.
fn integerId(id: ?jsonrpc.Id) ?i64 {
    const value = id orelse return null;
    return switch (value) {
        .integer => |number| number,
        .string => null,
    };
}

/// The named kind of a permission option, or null for a v2 catch-all.
fn knownKind(option: acp.PermissionOption) ?acp.PermissionOptionKind {
    return switch (option.kind) {
        .known => |kind| kind,
        .other => null,
    };
}

// --- The mcp-over-acp worked example ------------------------------------------

test "the RFD worked example decodes as a request carrying one envelope" {
    var pool = ScratchPool{};

    // The example is the only published document for this binding, so the test
    // pins the whole chain: the JSON-RPC hop, the envelope inside its params,
    // and the direction the outer id decides.
    const message = try jsonrpc.decode(
        fixture.mcp_message_request,
        try pool.next(),
    );
    try testing.expectEqual(jsonrpc.Kind.request, message.kind);
    try testing.expectEqual(@as(?i64, 20), integerId(message.id));
    try testing.expectEqualStrings("mcp/message", message.method.?.text);
    try testing.expectEqualStrings("mcp", message.method.?.category);
    try testing.expectEqualStrings("message", message.method.?.action);

    const envelope = try bridge.decodeEnvelope(
        message.params.value,
        try pool.next(),
        message.id,
    );
    try testing.expectEqualStrings("project-tools:7a72", envelope.server_id);
    try testing.expectEqualStrings("mcp-request:a11f", envelope.request_id);
    try testing.expectEqualStrings("tools/call", envelope.inner_method);
    // The outer `id` is what makes this a request, so the direction is
    // agent-to-provider rather than the notification the same params bytes
    // would carry without one.
    try testing.expect(envelope.direction == .agent_to_provider);

    const inner = envelope.inner_params.?;
    const info = try mcp.lookupMethod(.current, envelope.inner_method);
    try testing.expectEqualStrings("tools/call", info.name);
    try testing.expect(info.direction == .client_to_server);
    // The only three methods that may return an input_required result.
    try testing.expect(info.mrtr);
    try testing.expect(mcp.permitsMrtr(envelope.inner_method));

    // The `_meta` the example carries names the one revision the binding
    // supports, so a version the library does not implement would show up here
    // rather than at the point of use.
    const meta = (try rawMember(inner, "_meta", try pool.next())).?;
    const revision = (try stringMember(
        meta,
        "io.modelcontextprotocol/protocolVersion",
        try pool.next(),
    )).?;
    try testing.expectEqualStrings(bridge.supported_revision, revision);

    // The inner `elicitation/create` in a request map would be the one method
    // the current revision allows only inside an input_required result.
    const info_map = try mcp.lookupInputRequest("elicitation/create");
    try testing.expect(info_map.direction == .server_to_client_mrtr_only);
}

// --- JSON-RPC shapes -----------------------------------------------------------

test "a request and a notification classify apart, and a notification re-encodes without an id" {
    var pool = ScratchPool{};

    const request = try jsonrpc.decode(fixture.jsonrpc_request, try pool.next());
    try testing.expectEqual(jsonrpc.Kind.request, request.kind);
    try testing.expectEqual(@as(?i64, 1), integerId(request.id));
    try testing.expectEqualStrings("tools/call", request.method.?.text);
    // `params` is carried as borrowed text, so the inner object survives the
    // round trip byte for byte.
    try testing.expect(std.mem.startsWith(u8, request.params.value, "{"));

    const notification = try jsonrpc.decode(fixture.jsonrpc_notification, try pool.next());
    try testing.expectEqual(jsonrpc.Kind.notification, notification.kind);
    try testing.expect(notification.id == null);
    try testing.expectEqualStrings("notifications/progress", notification.method.?.text);

    // A notification omits the member that would make it a request, so the
    // re-encoded bytes must not carry an `id` the decoder would then reject.
    var buffer: [512]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try jsonrpc.encode(notification, &writer);
    try testing.expect(std.mem.find(u8, writer.written(), "\"id\"") == null);
    const again = try jsonrpc.decode(writer.written(), try pool.next());
    try testing.expectEqual(jsonrpc.Kind.notification, again.kind);
    try testing.expectEqualStrings("notifications/progress", again.method.?.text);
}

// --- MCP -----------------------------------------------------------------------

test "an input_required result carries both members and its discriminator" {
    var pool = ScratchPool{};

    const result = try mcp.decodeInputRequiredResult(fixture.mcp_mrtr_result, try pool.next());
    try testing.expectEqualStrings("input_required", result.result_type.value.?);
    try testing.expect(result.result_type.known() == .input_required);
    try testing.expect(!result.result_type.isComplete());
    // Opaque and attacker-controlled: the library carries it and never reads it.
    try testing.expectEqualStrings("eyJzdWIiOiJ1MSJ9", result.request_state.?);

    // `inputRequests` is a map of server-assigned keys to the three request
    // types the revision allows, so the key and the inner method are what a
    // client acts on.
    const entry = (try firstMember(result.input_requests.?, try pool.next())).?;
    try testing.expectEqualStrings("e1", entry.key);
    const method = (try stringMember(entry.value, "method", try pool.next())).?;
    try testing.expectEqualStrings("elicitation/create", method);
    const info = try mcp.lookupInputRequest(method);
    try testing.expect(info.direction == .server_to_client_mrtr_only);

    // MRTR is permitted on three methods only, and the result itself carries
    // no method name, so the caller is the one that checks.
    try testing.expect(mcp.permitsMrtr("tools/call"));
    try testing.expect(mcp.permitsMrtr("prompts/get"));
    try testing.expect(!mcp.permitsMrtr("tools/list"));
}

test "the capability objects walk to every member the schema names" {
    var pool = ScratchPool{};

    // The two capability objects are the one place the revision is spelled as
    // data rather than as prose, and the deprecated members are still in the
    // shape, so the vectors pin their presence and their order.
    var client_keys: [8][]const u8 = undefined;
    const client = try memberKeys(
        fixture.mcp_client_capabilities,
        &client_keys,
        try pool.next(),
    );
    try testing.expectEqual(@as(usize, 5), client);
    try testing.expectEqualStrings("experimental", client_keys[0]);
    try testing.expectEqualStrings("roots", client_keys[1]);
    try testing.expectEqualStrings("sampling", client_keys[2]);
    try testing.expectEqualStrings("elicitation", client_keys[3]);
    try testing.expectEqualStrings("extensions", client_keys[4]);

    // `roots` is a presence object, and the shape spells it with a space
    // inside it. A reader that tested for the closing brace without skipping
    // the whitespace first would call the specification's own example
    // malformed.
    const roots = (try rawMember(fixture.mcp_client_capabilities, "roots", try pool.next())).?;
    try testing.expectEqualStrings("{}", roots);

    var sampling_keys: [4][]const u8 = undefined;
    const sampling = (try rawMember(
        fixture.mcp_client_capabilities,
        "sampling",
        try pool.next(),
    )).?;
    try testing.expectEqual(
        @as(usize, 2),
        try memberKeys(sampling, &sampling_keys, try pool.next()),
    );
    try testing.expectEqualStrings("context", sampling_keys[0]);
    try testing.expectEqualStrings("tools", sampling_keys[1]);

    var server_keys: [8][]const u8 = undefined;
    try testing.expectEqual(
        @as(usize, 7),
        try memberKeys(
            fixture.mcp_server_capabilities,
            &server_keys,
            try pool.next(),
        ),
    );
    try testing.expectEqualStrings("experimental", server_keys[0]);
    try testing.expectEqualStrings("resources", server_keys[4]);

    // v1 and v2 of this protocol disagree about the form, so a boolean here is
    // the value the schema publishes rather than an empty object.
    const resources = (try rawMember(
        fixture.mcp_server_capabilities,
        "resources",
        try pool.next(),
    )).?;
    try testing.expectEqual(
        @as(?bool, true),
        try booleanMember(resources, "subscribe", try pool.next()),
    );
    try testing.expectEqual(
        @as(?bool, true),
        try booleanMember(resources, "listChanged", try pool.next()),
    );
}

test "the per-request client capabilities ride in _meta under the reserved key" {
    var pool = ScratchPool{};

    // The compatibility matrix states the normative location: from
    // `2026-07-28` the client capabilities are `params._meta[...]` on every
    // request, and the value is the extension fixture the specification
    // publishes for the Apps extension.
    const meta = (try rawMember(fixture.mcp_client_capabilities_meta, "_meta", try pool.next())).?;
    const capabilities = (try rawMember(
        meta,
        mcp.meta_key.client_capabilities,
        try pool.next(),
    )).?;

    // The key is inside the namespace MCP reserves for itself, and the
    // extension key inside the `extensions` map is an official identifier
    // rather than a vendor's own. A second label that merely starts the same
    // way is not reserved, which is the boundary the rule draws.
    try testing.expect(mcp.isReservedMetaPrefix(mcp.meta_prefix));
    try testing.expect(mcp.isReservedMetaPrefix(mcp.extension_id.ui));
    try testing.expect(!mcp.isReservedMetaPrefix("com.example.mcp/"));
    try testing.expect(!mcp.isReservedMetaPrefix("io.modelcontextprotocolX/"));

    const extensions = (try rawMember(capabilities, "extensions", try pool.next())).?;
    const entry = (try firstMember(extensions, try pool.next())).?;
    try testing.expectEqualStrings(mcp.extension_id.ui, entry.key);

    // The extension carries its own settings, and `mimeTypes` is the one the
    // Apps extension publishes.
    const mime_text = (try firstArrayElement(
        (try rawMember(entry.value, "mimeTypes", try pool.next())).?,
        try pool.next(),
    )).?;
    var mime_reader = json.Reader.init(mime_text);
    try testing.expectEqualStrings(
        "text/html;profile=mcp-app",
        try mime_reader.string(try pool.next()),
    );
    try testing.expect(mime_reader.atEnd());
}

// --- ACP -----------------------------------------------------------------------

test "a session/new request frames, decodes, and resolves in the v1 registry" {
    var pool = ScratchPool{};

    // Stdio frames use one raw newline as a delimiter. The fixture is a
    // single-line JSON message; trim its file-ending newline before framing.
    const payload = std.mem.trimEnd(u8, fixture.acp_session_new_request, "\r\n");
    var stream: [fixture.acp_session_new_request.len + 1]u8 = undefined;
    @memcpy(stream[0..payload.len], payload);
    stream[payload.len] = acp.frame_delimiter;

    const frame = try acp.nextFrame(stream[0 .. payload.len + 1]);
    try testing.expect(!frame.unterminated);
    try testing.expectEqual(@as(usize, 0), frame.rest.len);
    const message = try jsonrpc.decode(frame.bytes, try pool.next());
    try testing.expectEqual(jsonrpc.Kind.request, message.kind);
    try testing.expectEqualStrings("session/new", message.method.?.text);

    const info = try acp.lookupMethod(.stable, message.method.?.text);
    try testing.expectEqual(acp.Side.agent, info.side);
    try testing.expect(!info.notification);
    // Baseline in both versions, so it is callable without a capability.
    try testing.expectEqualStrings("", info.gate);

    const params = message.params.value;
    const cwd = (try stringMember(params, "cwd", try pool.next())).?;
    try testing.expect(acp.isAbsolutePath(cwd));
    try testing.expectEqualStrings("/home/user/project", cwd);

    // The `{"type": "acp", ...}` server declaration, verbatim from the RFD.
    // The published v2 schema has no `acp` branch, so the library carries the
    // three values the draft names rather than modelling the union.
    const servers = (try rawMember(params, "mcpServers", try pool.next())).?;
    const server = (try firstArrayElement(servers, try pool.next())).?;
    try testing.expectEqualStrings(
        bridge.server_declaration.kind,
        (try stringMember(server, "type", try pool.next())).?,
    );
    try testing.expectEqualStrings(
        bridge.server_declaration.name,
        (try stringMember(server, "name", try pool.next())).?,
    );
    try testing.expectEqualStrings(
        bridge.server_declaration.server_id,
        (try stringMember(server, "serverId", try pool.next())).?,
    );

    // `session/load` exists at v1 and is removed at v2, so the registry answer
    // is the thing that differs between the two revisions.
    try testing.expectEqualStrings(
        "loadSession",
        (try acp.lookupMethod(.stable, "session/load")).gate,
    );
    try testing.expectError(error.UnknownMethod, acp.lookupMethod(.draft, "session/load"));
}

test "a permission outcome names an option or cancels, and nothing else is approval" {
    var pool = ScratchPool{};

    const selected = try acp.decodePermissionOutcome(
        fixture.acp_permission_outcome_selected,
        try pool.next(),
    );
    const option_id = switch (selected) {
        .selected => |id| id,
        .cancelled => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("opt-allow-once", option_id);

    const cancelled = try acp.decodePermissionOutcome(
        fixture.acp_permission_outcome_cancelled,
        try pool.next(),
    );
    try testing.expect(cancelled == .cancelled);

    // Both branches survive the encoder the two-variant union implies, and a
    // re-decode of the written bytes selects the same arm. The cancelled
    // branch names no option, so a round trip that invented an `optionId`
    // would turn a cancellation into a selection.
    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try acp.encodePermissionOutcome(selected, &writer);
    const selected_again = try acp.decodePermissionOutcome(writer.written(), try pool.next());
    const again_id = switch (selected_again) {
        .selected => |id| id,
        .cancelled => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(option_id, again_id);

    writer = json.Writer.init(&buffer);
    try acp.encodePermissionOutcome(cancelled, &writer);
    try testing.expectEqualStrings("{\"outcome\":\"cancelled\"}", writer.written());
    const cancelled_again = try acp.decodePermissionOutcome(writer.written(), try pool.next());
    try testing.expect(cancelled_again == .cancelled);
}

test "the v1 permission request decodes to the choices the user is offered" {
    var pool = ScratchPool{};
    var options: [8]acp.PermissionOption = undefined;

    const decoded = try acp.decodePermissionRequest(
        .stable,
        fixture.acp_permission_request_v1,
        &options,
        try pool.next(),
    );
    const request = switch (decoded) {
        .stable => |value| value,
        .draft => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("sess-01", request.session_id);
    try testing.expectEqual(@as(usize, 3), request.options.len);

    // The three fields the user reads and an outcome names back.
    try testing.expectEqualStrings("opt-allow-once", request.options[0].option_id);
    try testing.expectEqualStrings("Allow once", request.options[0].name);
    try testing.expectEqual(acp.PermissionOptionKind.allow_once, knownKind(request.options[0]).?);
    try testing.expectEqual(acp.PermissionOptionKind.allow_always, knownKind(request.options[1]).?);
    try testing.expectEqual(acp.PermissionOptionKind.reject_once, knownKind(request.options[2]).?);

    // v1 is a closed `oneOf`, so a fifth kind is a value the schema does not
    // define and `grants` is a definite answer for every one of the four.
    try testing.expectEqual(true, request.options[0].grants().?);
    try testing.expectEqual(false, request.options[2].grants().?);

    // The `ToolCallUpdate` is carried verbatim, so the identifier the agent
    // assigned is still readable in the decoded value.
    const call_id = (try stringMember(request.tool_call, "toolCallId", try pool.next())).?;
    try testing.expectEqualStrings("call-1", call_id);
}

test "the RFD acp capability decodes as a boolean at v1 and a presence object at v2" {
    var pool = ScratchPool{};
    var v1_entries: [8]acp.Capability = undefined;
    var v1_paths: [128]u8 = undefined;
    var v2_entries: [8]acp.Capability = undefined;
    var v2_paths: [128]u8 = undefined;

    const v1 = try acp.decodeInitializeCapabilities(
        .stable,
        .agent,
        fixture.acp_initialize_capabilities_v1,
        &v1_entries,
        &v1_paths,
        try pool.next(),
    );
    try testing.expect(v1.present);
    // v1 types everything under `mcpCapabilities` as a boolean, and
    // `false` means unsupported, so the value has to be read rather than
    // assumed from the member's presence.
    const v1_acp = findCapability(v1.entries, bridge.capability_path.v1) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(acp.CapabilityForm.boolean, v1_acp.form);
    try testing.expectEqual(true, v1_acp.value.?);
    try testing.expect(v1_acp.advertised());

    // v2 replaced every boolean with a presence object, so the same capability
    // is an empty `{}` and the path gained the `capabilities` root. The path
    // is what `isMethodSupported` is handed, so the two must not collide
    // across the cutover.
    const v2 = try acp.decodeInitializeCapabilities(
        .draft,
        .client,
        fixture.acp_initialize_capabilities_v2,
        &v2_entries,
        &v2_paths,
        try pool.next(),
    );
    try testing.expect(v2.present);
    const v2_acp = findCapability(v2.entries, bridge.capability_path.v2) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(acp.CapabilityForm.presence_object, v2_acp.form);
    try testing.expect(v2_acp.value == null);
    try testing.expect(v2_acp.advertised());
    try testing.expect(!std.mem.eql(u8, bridge.capability_path.v1, bridge.capability_path.v2));
}

// --- mcp-over-acp outcomes -----------------------------------------------------

test "a version mismatch inside the outcome carrier is not a binding failure" {
    var pool = ScratchPool{};

    const failure = try bridge.decodeOutcome(fixture.bridge_outcome_error, try pool.next());
    const error_text = switch (failure) {
        .@"error" => |text| text,
        .result => return error.TestUnexpectedResult,
    };
    // `-32022` is MCP's `UnsupportedProtocolVersion`, and the draft places it
    // inside the carrier rather than on the outer ACP message.
    try testing.expectEqualStrings(
        "-32022",
        (try numberMember(error_text, "code", try pool.next())).?,
    );
    try testing.expectEqualStrings(
        "Unsupported protocol version",
        (try stringMember(error_text, "message", try pool.next())).?,
    );
    // It is an MCP error the caller reports, not a transport failure it
    // retries, at either level.
    try testing.expect(!bridge.isBindingFailure(-32022, .outer));
    try testing.expect(!bridge.isBindingFailure(-32022, .inner));

    // `-32602` is the one number both spaces use, and the level is the only
    // thing that tells them apart.
    try testing.expect(bridge.isBindingFailure(-32602, .outer));
    try testing.expect(!bridge.isBindingFailure(-32602, .inner));
    // The binding allocates outside MCP's reserved range, so an inner code in
    // it can never be read as a binding failure.
    try testing.expect(!bridge.isBindingFailure(-32000, .outer));
    try testing.expect(!bridge.isBindingFailure(-32019, .outer));

    const success = try bridge.decodeOutcome(fixture.bridge_outcome_result, try pool.next());
    const result_text = switch (success) {
        .result => |text| text,
        .@"error" => return error.TestUnexpectedResult,
    };
    // The inner outcome is an ordinary MCP result, so the MCP decoder runs on
    // the bytes the binding carried through.
    const result_type = try mcp.decodeResultType(result_text, try pool.next());
    try testing.expectEqualStrings("complete", result_type.value.?);
    try testing.expect(result_type.isComplete());
}

// --- A2A -----------------------------------------------------------------------

test "the A2A JSON-RPC error envelope maps to the error its ErrorInfo names" {
    var pool = ScratchPool{};

    const message = try jsonrpc.decode(fixture.a2a_jsonrpc_error, try pool.next());
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    try testing.expectEqual(@as(?i64, 2), integerId(message.id));
    try testing.expect(message.result == null);

    const object = message.rpc_error.?;
    try testing.expectEqual(@as(i32, -32001), object.code);
    try testing.expectEqualStrings("Task not found", object.message);
    // The `data` member rides along, and it is what distinguishes this error
    // from the standard JSON-RPC codes: six of the nine A2A errors collapse
    // onto one status pair, so the code alone cannot name the cause.
    try testing.expect(std.mem.startsWith(u8, object.data.?, "["));

    const known = a2a.A2aError.fromCode(object.code) orelse
        return error.TestUnexpectedResult;
    try testing.expect(known == .task_not_found);
    try testing.expectEqualStrings("TASK_NOT_FOUND", known.reason());
    // The A2A-specific codes live in their own range, and `-32001` is the
    // numerically highest of the nine because the whole range is negative.
    try testing.expect(object.code >= a2a.error_range_min);
    try testing.expect(object.code <= a2a.error_range_max);

    // The ErrorInfo inside `data` is what a decoder keys on, and it agrees with
    // the code the envelope carries.
    const detail = (try firstArrayElement(object.data.?, try pool.next())).?;
    const reason = (try stringMember(detail, "reason", try pool.next())).?;
    const domain = (try stringMember(detail, "domain", try pool.next())).?;
    // The domain is a bare domain string, not a URI prefix, and it is the gate
    // on the reason lookup: the same reason under another domain is not an A2A
    // error at all.
    try testing.expectEqualStrings(a2a.error_domain, domain);
    try testing.expect(!(a2a.classifyReason("example.com", reason) == .known));

    const classified: a2a.A2aError = switch (a2a.classifyReason(domain, reason)) {
        .known => |value| value,
        .unknown_a2a, .missing_domain, .other_domain => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(known, classified);
}

test "the REST error envelope is not a JSON-RPC message and its status is not the discriminator" {
    var pool = ScratchPool{};

    // The HTTP+JSON/REST binding has no `jsonrpc` member, so this document is
    // not a JSON-RPC response and reading it as one would invent an `id`.
    try testing.expectError(
        error.MissingField,
        jsonrpc.decode(fixture.a2a_rest_error, try pool.next()),
    );

    const error_object = (try rawMember(fixture.a2a_rest_error, "error", try pool.next())).?;
    try testing.expectEqualStrings(
        "404",
        (try numberMember(error_object, "code", try pool.next())).?,
    );
    try testing.expectEqualStrings(
        "NOT_FOUND",
        (try stringMember(error_object, "status", try pool.next())).?,
    );

    // Six of the nine A2A errors share HTTP 400, so the status cannot pick one
    // out. The `reason` is the only discriminator, which is why the
    // specification requires the ErrorInfo object in `details`.
    const detail = (try firstArrayElement(
        (try rawMember(error_object, "details", try pool.next())).?,
        try pool.next(),
    )).?;
    const reason = (try stringMember(detail, "reason", try pool.next())).?;
    const domain = (try stringMember(detail, "domain", try pool.next())).?;
    const classified: a2a.A2aError = switch (a2a.classifyReason(domain, reason)) {
        .known => |value| value,
        .unknown_a2a, .missing_domain, .other_domain => return error.TestUnexpectedResult,
    };
    try testing.expect(classified == .task_not_found);
    // The status the document publishes is the one the library maps to.
    try testing.expectEqual(@as(u16, 404), classified.httpStatus());
    try testing.expectEqual(@as(u8, 5), classified.grpcCode());
}

test "the AgentCard signature shape decodes, and its protected header is the one the extraction names" {
    var pool = ScratchPool{};

    const protected = (try stringMember(
        fixture.a2a_agent_card_signature,
        "protected",
        try pool.next(),
    )).?;
    const signature = (try stringMember(
        fixture.a2a_agent_card_signature,
        "signature",
        try pool.next(),
    )).?;

    // §8.4.2 spells the signing input with `BASE64URL`, so both members are
    // base64url without padding. A standard-alphabet decoder that accepted the
    // bytes would have to have substituted `-` and `_` for `+` and `/`, which
    // would change the signature.
    try testing.expect(std.mem.findScalar(u8, signature, '=') == null);
    // The signature carries characters the standard alphabet spells `+` and
    // `/`, so a decoder reading the wrong alphabet either refuses it or
    // produces different bytes.
    try testing.expect(std.mem.findScalar(u8, signature, '-') != null);
    try testing.expect(std.mem.findScalar(u8, signature, '_') != null);

    // The protected header is the one the extraction states the value decodes
    // to, so a decoder that read the wrong alphabet or dropped a character
    // would fail on the decoded bytes rather than on a length.
    var header: [128]u8 = undefined;
    const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(protected);
    try testing.expect(size <= header.len);
    try std.base64.url_safe_no_pad.Decoder.decode(header[0..size], protected);
    try testing.expectEqualStrings(
        "{\"alg\":\"ES256\",\"typ\":\"JOSE\",\"kid\":\"key-1\"," ++
            "\"jku\":\"https://example.com/agent/jwks.json\"}",
        header[0..size],
    );

    // A `protected` header is the part the JWS covers, so the decoded bytes
    // above are the whole assertion. The signature is the part it protects,
    // and an ES256 signature is exactly two 32-byte integers.
    var signature_bytes: [64]u8 = undefined;
    const signature_size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(signature);
    try testing.expectEqual(@as(usize, 64), signature_size);
    try std.base64.url_safe_no_pad.Decoder.decode(
        signature_bytes[0..signature_size],
        signature,
    );
}
