//! Golden-vector decode tests over the specifications' own worked examples.
//!
//! Every fixture under `test/golden/` is either a verbatim JSON block lifted
//! out of `research/normative/`, a verbatim member inside the location its own
//! section makes normative, or a document whose member names are verbatim
//! from the schema tables in the same files. The table below records where
//! each fixture came from. A hand-written unit test only catches a regression
//! if the author happened to write the same case twice; these vectors make the
//! normative examples themselves the regression net, so a change to a tag, a
//! spelling or a required member moves one of them.
//!
//! Three of them go back out as well — both `bridge` encoders and the MCP
//! interim-result encoder. A member a decoder accepted and then did not write
//! back re-encodes to a document that still decodes cleanly, so nothing
//! downstream ever reports the loss. No fixture under `test/golden/` carries
//! the ACP carrier `_meta` that loss is about, and the step did not call
//! either `bridge` encoder at all, so the two tests below wrap the normative
//! payloads in the carrier the RFD names and compare the written bytes against
//! them literally. That is the only coverage those two encoders have in the
//! default step, and it is the coverage the binding's own loss class needs.
//!
//! The same class reaches the MCP result objects, and the one open-set vector
//! there carries what it needs to carry: `mcp_mrtr_result.json` holds a `_meta`
//! and a vendor key the `InputRequiredResult` shape does not model, so the
//! round trip below compares every byte the encoder wrote against a literal
//! rather than against a second decode of the same fixture.
//!
//! ## Provenance
//!
//! Verbatim JSON blocks, copied without reformatting, or a verbatim member
//! inside the location its own section makes normative:
//!
//! | Fixture | Source |
//! | --- | --- |
//! | `mcp_message_request.json` | `research/normative/acp-v1-v2.md` 10a, the `mcp-over-acp` RFD worked example |
//! | `a2a_jsonrpc_error.json` | `research/normative/a2a-1.0.0.md` 6.4, the JSON-RPC error envelope |
//! | `a2a_rest_error.json` | `research/normative/a2a-1.0.0.md` 6.4, the HTTP+JSON/REST error envelope |
//! | `a2a_agent_card_signature.json` | `research/normative/a2a-1.0.0.md` 7.2, the `signatures` shape |
//! | `mcp_client_capabilities.json` | `research/normative/mcp-2026-07-28.md` 6, `ClientCapabilities` |
//! | `mcp_client_capabilities_meta.json` | `research/normative/mcp-2026-07-28.md`
//!   6, the `clientCapabilities` fixture line, inside the `_meta` the
//!   compatibility matrix in the same section makes normative |
//! | `mcp_server_capabilities.json` | `research/normative/mcp-2026-07-28.md` 6, `ServerCapabilities` |
//! | `acp_initialize_capabilities_v1.json` | `research/normative/acp-v1-v2.md` 10e, the v1 RFD fragment |
//! | `acp_initialize_capabilities_v2.json` | `research/normative/acp-v1-v2.md` 10e, the v2 RFD fragment |
//!
//! Member names verbatim, values chosen here because the specification
//! publishes the shape and not an example document:
//!
//! | Fixture | Source |
//! | --- | --- |
//! | `mcp_mrtr_result.json` | `mcp-2026-07-28.md` 10, the `InputRequiredResult`
//!   interface, and section 2 for the two members that interface does not
//!   model: the reserved `io.modelcontextprotocol/serverInfo` key every result
//!   `_meta` carries, and the key grammar a vendor key is spelled with |
//! | `mcp_mrtr_result_bare.json` | `mcp-2026-07-28.md` 10, the *"At least one of
//!   `inputRequests` or `requestState` MUST be present"* sentence — the one
//!   document here a receiver must refuse, so it is a vector too |
//! | `acp_session_new_request.json` | `acp-v1-v2.md` 3a and 10e, the v1 `session/new`
//!   required list and the server declaration |
//! | `acp_permission_outcome_selected.json` | `acp-v1-v2.md` 5b, the `selected` branch of `RequestPermissionOutcome` |
//! | `acp_permission_outcome_cancelled.json` | `acp-v1-v2.md` 5b, the `cancelled` branch |
//! | `acp_permission_request_v1.json` | `acp-v1-v2.md` 5a and 5c, the v1 required lists |
//! | `jsonrpc_request.json`, `jsonrpc_notification.json` | `mcp-2026-07-28.md`
//!   section 1, the JSON-RPC message table. The `progressToken` the
//!   notification carries is the one member whose placement the sources answer
//!   differently; see the note at that test |
//! | `bridge_outcome_error.json` | `acp-v1-v2.md` 10d, `-32022` inside the outcome carrier |
//! | `bridge_outcome_result.json` | `mcp-2026-07-28-schema.md` 4, the
//!   `CallToolResult` declaration, whose required `content` is the member this
//!   fixture exists to carry |

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
    mcp_mrtr_result_bare: []const u8 = @embedFile("golden/mcp_mrtr_result_bare.json"),
    mcp_server_capabilities: []const u8 = @embedFile("golden/mcp_server_capabilities.json"),
};

const fixture: Fixture = .{};

/// Every fixture, with the file name it is embedded under.
///
/// Walking `Fixture` rather than restating its eighteen lines here means a
/// fixture added there is reached by the well-formedness test without a second
/// edit, and a failure there names the file rather than a line number.
const every_fixture = blk: {
    var list: [std.meta.fields(Fixture).len]struct { name: []const u8, bytes: []const u8 } = undefined;
    for (std.meta.fields(Fixture), 0..) |field, at| {
        list[at] = .{ .name = field.name, .bytes = @field(fixture, field.name) };
    }
    break :blk list;
};

/// Scratch wide enough to read any fixture whole, for the same reason.
const widest_fixture = blk: {
    var widest: usize = 0;
    for (every_fixture) |entry| widest = @max(widest, entry.bytes.len);
    break :blk widest;
};

// --- Borrow-reader helpers ----------------------------------------------------
//
// Each helper runs its own `json.Reader`, and a `Reader` hands out scratch
// regions by bumping a high-water mark that starts at zero. Two readers sharing
// one buffer would therefore overwrite each other's results, so every helper
// takes a distinct region from this pool.
//
// A helper returns the moment it finds its member, so on that path it cannot
// see a second value after the closing brace. Every path that does walk to the
// end ends in `atEnd()`, and the test below reads all eighteen documents whole,
// which is what covers the ones that return early.

/// Scratch regions handed out one at a time, so two live results never share
/// one. A helper that runs out reports the same `BufferTooSmall` the library
/// does rather than aliasing a region that is still in use.
const ScratchPool = struct {
    // SAFETY: Each region is handed to one decoder call and never reused; reads are of slices decode wrote.
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
        if (std.mem.eql(u8, name, key)) {
            const value = try reader.rawValue(scratch);
            return value;
        }
        try reader.skipValue(scratch);
    }
    if (!reader.atEnd()) return error.MalformedJson;
    return null;
}

/// The decoded string value of the member named `key`, or null when absent.
fn stringMember(input: []const u8, key: []const u8, scratch: []u8) DecodeError!?[]const u8 {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |name| {
        if (std.mem.eql(u8, name, key)) {
            const value = try reader.string(scratch);
            return value;
        }
        try reader.skipValue(scratch);
    }
    if (!reader.atEnd()) return error.MalformedJson;
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
        if (std.mem.eql(u8, name, key)) {
            const value = try reader.number();
            return value;
        }
        try reader.skipValue(scratch);
    }
    if (!reader.atEnd()) return error.MalformedJson;
    return null;
}

fn booleanMember(input: []const u8, key: []const u8, scratch: []u8) DecodeError!?bool {
    var reader = json.Reader.init(input);
    if (try reader.beginObject()) return null;
    while (try reader.nextKey(scratch)) |name| {
        if (std.mem.eql(u8, name, key)) {
            const value = try reader.boolean();
            return value;
        }
        try reader.skipValue(scratch);
    }
    if (!reader.atEnd()) return error.MalformedJson;
    return null;
}

/// The first element of an array, as raw JSON text, or null when empty.
fn firstArrayElement(input: []const u8, scratch: []u8) DecodeError!?[]const u8 {
    var reader = json.Reader.init(input);
    if (try reader.beginArray()) return null;
    if (!try reader.nextArrayElement()) return null;
    const value = try reader.rawValue(scratch);
    return value;
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
    if (!reader.atEnd()) return error.MalformedJson;
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

test "every fixture is one JSON value, as a decoder of any of them would require" {
    var scratch: [widest_fixture]u8 = undefined;

    // "A JSON document is exactly one value" is what every decoder this
    // library owns ends on — `decodeResultType`, `decodeInputRequiredResult`
    // and `decodeToolCallResult` each refuse a tail — so a library decoder is
    // already told when a fixture is malformed. The borrow-reader helpers
    // above are not: they stop at the member they were asked for, and the
    // three that only ever read the first one stop there by construction. This
    // reads each fixture whole, which is the only statement that reaches the
    // nine that are read through those helpers, and it is the difference
    // between "well-formed" being asserted and being true by inspection.
    for (every_fixture) |entry| {
        var reader = json.Reader.init(entry.bytes);
        try reader.skipValue(&scratch);
        if (!reader.atEnd()) {
            std.debug.print("not one JSON value: {s}.json\n", .{entry.name});
            return error.TestUnexpectedResult;
        }
    }
}

// --- The mcp-over-acp worked example ------------------------------------------

test "the RFD worked example decodes as a request carrying one envelope" {
    var pool: ScratchPool = .{};

    // The example is the only published document for this binding, so the test
    // pins the whole chain: the JSON-RPC hop, the envelope inside its params,
    // and the direction the outer id decides.
    const message = try jsonrpc.decode(
        fixture.mcp_message_request,
        try pool.next(),
    );
    try testing.expectEqual(jsonrpc.Kind.request, message.kind);
    try testing.expectEqual(@as(?i64, 20), integerId(message.id));
    const method = message.method orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("mcp/message", method.text);
    try testing.expectEqualStrings("mcp", method.category);
    try testing.expectEqualStrings("message", method.action);

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

    const inner = envelope.inner_params orelse return error.TestUnexpectedResult;
    const info = try mcp.lookupMethod(.current, envelope.inner_method);
    try testing.expectEqualStrings("tools/call", info.name);
    try testing.expect(info.direction == .client_to_server);
    // The only three methods that may return an input_required result.
    try testing.expect(info.mrtr);
    try testing.expect(mcp.permitsMrtr(envelope.inner_method));

    // The encoder, over the same normative envelope, and byte for byte. The
    // three member names and their order are written out here and the `params`
    // lexeme is the example's own bytes, so an encoder that rebuilt the member
    // from a shape would disagree here on the indentation it would have to
    // drop. `zig build test` had no coverage of `bridge.encodeEnvelope` at
    // all, and the one loss this binding exists to prevent is a member that
    // decodes and is then not written back.
    var out: [1024]u8 = undefined;
    var owed: [2048]u8 = undefined;
    var writer = json.Writer.init(&out);
    try bridge.encodeEnvelope(envelope, &writer);
    // The expected bytes are assembled with a writer rather than a `++`,
    // because the one member that is not a literal is the example's own
    // `params` lexeme and that is a runtime slice.
    var canonical = json.Writer.init(&owed);
    try canonical.slice("{\"serverId\":\"project-tools:7a72\",");
    try canonical.slice("\"requestId\":\"mcp-request:a11f\",");
    try canonical.slice("\"method\":\"tools/call\",\"params\":");
    try canonical.slice(inner);
    try canonical.byte('}');
    try testing.expectEqualStrings(canonical.written(), writer.written());
    // And those bytes decode back to the same envelope, so what is pinned
    // above is a round trip rather than one half of one.
    const again = try bridge.decodeEnvelope(writer.written(), try pool.next(), message.id);
    try testing.expectEqualStrings(envelope.server_id, again.server_id);
    try testing.expectEqualStrings(envelope.request_id, again.request_id);
    try testing.expectEqualStrings(envelope.inner_method, again.inner_method);
    try testing.expectEqualStrings(
        envelope.inner_params orelse return error.TestUnexpectedResult,
        again.inner_params orelse return error.TestUnexpectedResult,
    );

    // The same envelope with the ACP envelope `_meta` the RFD names beside
    // `serverId`. The three members are the example's own spellings and the
    // carrier is a member this binding does not model, so the only way to
    // reproduce these bytes is to carry the lexeme and write it back.
    var carrier = json.Writer.init(&owed);
    try carrier.slice("{\"serverId\":\"project-tools:7a72\",");
    try carrier.slice("\"requestId\":\"mcp-request:a11f\",");
    try carrier.slice("\"method\":\"tools/call\",\"params\":");
    try carrier.slice(inner);
    try carrier.slice(",\"_meta\":{\"trace\":\"abc\"}}");
    const carried = carrier.written();
    const carried_envelope = try bridge.decodeEnvelope(carried, try pool.next(), message.id);
    try testing.expectEqualStrings(
        "{\"trace\":\"abc\"}",
        carried_envelope.meta orelse return error.TestUnexpectedResult,
    );
    var carried_writer = json.Writer.init(&out);
    try bridge.encodeEnvelope(carried_envelope, &carried_writer);
    try testing.expectEqualStrings(carried, carried_writer.written());

    // The `_meta` the example carries names the one revision the binding
    // supports, so a version the library does not implement would show up here
    // rather than at the point of use.
    const meta = (try rawMember(inner, "_meta", try pool.next())) orelse
        return error.TestUnexpectedResult;
    const revision = (try stringMember(
        meta,
        "io.modelcontextprotocol/protocolVersion",
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(bridge.supported_revision, revision);

    // The inner `elicitation/create` in a request map would be the one method
    // the current revision allows only inside an input_required result.
    const info_map = try mcp.lookupInputRequest("elicitation/create");
    try testing.expect(info_map.direction == .server_to_client_mrtr_only);
}

// --- JSON-RPC shapes -----------------------------------------------------------

test "a request and a notification classify apart, and a notification re-encodes without an id" {
    var pool: ScratchPool = .{};

    const request = try jsonrpc.decode(fixture.jsonrpc_request, try pool.next());
    try testing.expectEqual(jsonrpc.Kind.request, request.kind);
    try testing.expectEqual(@as(?i64, 1), integerId(request.id));
    const method = request.method orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("tools/call", method.text);
    // `params` is carried as borrowed text, so the value the reader hands back
    // is the fixture's own bytes: the specification's indentation and member
    // order, and none of the whitespace it skipped.
    const expected_params = "{\n" ++
        "    \"name\": \"echo\",\n" ++
        "    \"arguments\": {\n" ++
        "      \"message\": \"hello\"\n" ++
        "    }\n" ++
        "  }";
    try testing.expectEqualStrings(expected_params, request.params.value);

    const notification = try jsonrpc.decode(fixture.jsonrpc_notification, try pool.next());
    try testing.expectEqual(jsonrpc.Kind.notification, notification.kind);
    try testing.expect(notification.id == null);
    const notification_method = notification.method orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("notifications/progress", notification_method.text);

    // `params` is borrowed whole, so the notification's own document is read
    // here rather than carried past the test. `progressToken` is the one
    // member in this file whose placement the sources answer differently, so
    // it is pinned rather than passed over: PROTOCOLS.md 4.3 lists it as a
    // bare `_meta` key, and every other document this repository holds puts it
    // under `params._meta` — the request fixtures in `src/http.zig` and the
    // retry in `src/mcp_session.zig` — while the section 1b table this fixture
    // is copied from gives `ProgressNotificationParams` a top-level
    // `progressToken`. Nothing offline settles which one a
    // `notifications/progress` params object follows, so the fixture stays
    // where the section it is copied from puts it and the assertions make the
    // placement visible rather than leaving it to inspection.
    const notification_params = "{\n" ++
        "    \"progressToken\": \"progress-1\",\n" ++
        "    \"progress\": 0.5,\n" ++
        "    \"total\": 1\n" ++
        "  }";
    try testing.expectEqualStrings(notification_params, notification.params.value);
    try testing.expectEqualStrings(
        "progress-1",
        (try stringMember(
            notification.params.value,
            "progressToken",
            try pool.next(),
        )) orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "0.5",
        (try numberMember(notification.params.value, "progress", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "1",
        (try numberMember(notification.params.value, "total", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );

    // A notification omits the member that would make it a request, so the
    // re-encoded bytes must not carry an `id` the decoder would then reject.
    var buffer: [512]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try jsonrpc.encode(notification, &writer);
    try testing.expect(std.mem.find(u8, writer.written(), "\"id\"") == null);
    const again = try jsonrpc.decode(writer.written(), try pool.next());
    try testing.expectEqual(jsonrpc.Kind.notification, again.kind);
    try testing.expectEqualStrings(
        "notifications/progress",
        (again.method orelse return error.TestUnexpectedResult).text,
    );
}

// --- MCP -----------------------------------------------------------------------

/// The MRTR decoder, through the one place this file calls it.
///
/// It takes the caller's regions in the order the ten 4.10.3 decoders take
/// them — `raw`, the store for the members this shape does not model, the
/// scratch — and `encodeInputRequiredResult` takes the value alone. Both tests
/// below are the only call sites this file has of either, so a change to that
/// pair is a change here rather than in the middle of assertions about the
/// wire.
fn decodeMrtr(
    raw: []const u8,
    store: []mcp.VerbatimMember,
    scratch: []u8,
) DecodeError!mcp.InputRequiredResult {
    return mcp.decodeInputRequiredResult(raw, store, scratch);
}

test "an input_required result carries both members and every member it does not" {
    var pool: ScratchPool = .{};
    var store: [4]mcp.VerbatimMember = undefined;

    const result = try decodeMrtr(fixture.mcp_mrtr_result, &store, try pool.next());
    try testing.expectEqualStrings(
        "input_required",
        result.result_type.value orelse return error.TestUnexpectedResult,
    );
    try testing.expect(result.result_type.known() == .input_required);
    try testing.expect(!result.result_type.isComplete());
    // Opaque and attacker-controlled: the library carries it and never reads it.
    try testing.expectEqualStrings(
        "eyJzdWIiOiJ1MSJ9",
        result.request_state orelse return error.TestUnexpectedResult,
    );

    // `inputRequests` is a map of server-assigned keys to the three request
    // types the revision allows, so the key and the inner method are what a
    // client acts on.
    const input_requests = result.input_requests orelse return error.TestUnexpectedResult;
    const entry = (try firstMember(input_requests, try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("e1", entry.key);
    const method = (try stringMember(entry.value, "method", try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("elicitation/create", method);
    const info = try mcp.lookupInputRequest(method);
    try testing.expect(info.direction == .server_to_client_mrtr_only);

    // MRTR is permitted on three methods only, and the result itself carries
    // no method name, so the caller is the one that checks.
    try testing.expect(mcp.permitsMrtr("tools/call"));
    try testing.expect(mcp.permitsMrtr("prompts/get"));
    try testing.expect(!mcp.permitsMrtr("tools/list"));

    // A result object is an open set: 4.10.6's first row, and the decision
    // SPEC-DECISIONS.md 5 records, put a member the shape does not model in
    // the decoder as the borrowed lexeme it arrived as and in the encoder as
    // the same bytes back. The fixture carries one of each kind — the `_meta`
    // every result may have and a vendor key no interface names — so what the
    // round trip below states is that rule, and not only the three members the
    // type models. Asserted here first, so a vector that quietly loses its
    // open-set members cannot make the comparison below vacuous.
    var keys: [8][]const u8 = undefined;
    try testing.expectEqual(
        @as(usize, 5),
        try memberKeys(fixture.mcp_mrtr_result, &keys, try pool.next()),
    );
    try testing.expectEqualStrings("resultType", keys[0]);
    try testing.expectEqualStrings("inputRequests", keys[1]);
    try testing.expectEqualStrings("requestState", keys[2]);
    try testing.expectEqualStrings("_meta", keys[3]);
    try testing.expectEqualStrings("vendor.example.com/audit", keys[4]);

    // The comparison is against a literal, not against a second decode of the
    // same fixture: the member names, the braces and the two scalars are the
    // literals, and the three carried values — the map and the two open-set
    // members — come back as the fixture's own bytes, its indentation
    // included. An encoder that dropped a member the decoder accepted, rebuilt
    // one from the shape rather than carrying the lexeme, or reordered them,
    // writes different bytes and fails here. That is the loss a result object
    // this library re-encodes would otherwise carry out to the peer with no
    // error anywhere.
    var out: [1024]u8 = undefined;
    var writer = json.Writer.init(&out);
    try mcp.encodeInputRequiredResult(result, &writer);
    try testing.expectEqualStrings(
        "{\"resultType\":\"input_required\",\"inputRequests\":{\n" ++
            "    \"e1\": {\n" ++
            "      \"method\": \"elicitation/create\",\n" ++
            "      \"params\": {\n" ++
            "        \"message\": \"Which environment should the migration target?\"\n" ++
            "      }\n" ++
            "    }\n" ++
            "  },\"requestState\":\"eyJzdWIiOiJ1MSJ9\",\"_meta\":{\n" ++
            "    \"io.modelcontextprotocol/serverInfo\": {\n" ++
            "      \"name\": \"example-server\",\n" ++
            "      \"version\": \"1.2.3\"\n" ++
            "    }\n" ++
            "  },\"vendor.example.com/audit\":{\n" ++
            "    \"decision\": \"pending\",\n" ++
            "    \"attempts\": [1, 2]\n" ++
            "  }}",
        writer.written(),
    );
}

test "an input_required result carrying neither optional member is refused" {
    var pool: ScratchPool = .{};
    var store: [2]mcp.VerbatimMember = undefined;

    // The rule is the schema's own doc comment on the interface — "At least
    // one of `inputRequests` or `requestState` MUST be present" — so the
    // document it forbids belongs in this set beside the one it permits. The
    // fixture above carries both members, which the rule allows, so without
    // this vector nothing in the golden step would notice the refusal going
    // away. `src/mcp.zig` states the same rule in its own unit test; what this
    // one adds is the document, which is what the step pins everywhere else.
    try testing.expectError(
        error.MissingField,
        decodeMrtr(fixture.mcp_mrtr_result_bare, &store, try pool.next()),
    );
}

test "the capability objects walk to every member the schema names" {
    var pool: ScratchPool = .{};

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

    // `roots` is a presence object the shape spells with no member and no
    // whitespace inside it, so the borrowed value is exactly those two bytes.
    const roots = (try rawMember(fixture.mcp_client_capabilities, "roots", try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("{}", roots);

    // `experimental` is the member whose value does carry whitespace inside
    // it: one after the opening brace, and one between the braces of the empty
    // object it holds. A reader that expected `}` straight after `{`, or that
    // trimmed the whitespace out of the value it borrows, would hand back
    // bytes other than the specification's own example.
    const experimental = (try rawMember(
        fixture.mcp_client_capabilities,
        "experimental",
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("{ \"<key>\": { } }", experimental);

    var sampling_keys: [4][]const u8 = undefined;
    const sampling = (try rawMember(
        fixture.mcp_client_capabilities,
        "sampling",
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;
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
    try testing.expectEqualStrings("logging", server_keys[1]);
    try testing.expectEqualStrings("completions", server_keys[2]);
    try testing.expectEqualStrings("prompts", server_keys[3]);
    try testing.expectEqualStrings("resources", server_keys[4]);
    try testing.expectEqualStrings("tools", server_keys[5]);
    try testing.expectEqualStrings("extensions", server_keys[6]);

    // v1 and v2 of this protocol disagree about the form, so a boolean here is
    // the value the schema publishes rather than an empty object.
    const resources = (try rawMember(
        fixture.mcp_server_capabilities,
        "resources",
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;
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
    var pool: ScratchPool = .{};

    // The compatibility matrix states the normative location: from
    // `2026-07-28` the client capabilities are `params._meta[...]` on every
    // request. This fixture is that `_meta` object, and the value under the
    // key is the extension fixture the specification publishes for the Apps
    // extension.
    const meta = (try rawMember(fixture.mcp_client_capabilities_meta, "_meta", try pool.next())) orelse
        return error.TestUnexpectedResult;
    const capabilities = (try rawMember(
        meta,
        mcp.meta_key.client_capabilities,
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;

    // The key is inside the namespace MCP reserves for itself, and the
    // extension key inside the `extensions` map is an official identifier
    // rather than a vendor's own. A second label that merely starts the same
    // way is not reserved, which is the boundary the rule draws.
    try testing.expect(mcp.isReservedMetaPrefix(mcp.meta_prefix));
    try testing.expect(mcp.isReservedMetaPrefix(mcp.extension_id.ui));
    try testing.expect(!mcp.isReservedMetaPrefix("com.example.mcp/"));
    try testing.expect(!mcp.isReservedMetaPrefix("io.modelcontextprotocolX/"));

    const extensions = (try rawMember(capabilities, "extensions", try pool.next())) orelse
        return error.TestUnexpectedResult;
    const entry = (try firstMember(extensions, try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings(mcp.extension_id.ui, entry.key);

    // The extension carries its own settings, and `mimeTypes` is the one the
    // Apps extension publishes.
    const mime_text = (try firstArrayElement(
        (try rawMember(entry.value, "mimeTypes", try pool.next())) orelse
            return error.TestUnexpectedResult,
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;
    var mime_reader = json.Reader.init(mime_text);
    try testing.expectEqualStrings(
        "text/html;profile=mcp-app",
        try mime_reader.string(try pool.next()),
    );
    try testing.expect(mime_reader.atEnd());
}

// --- ACP -----------------------------------------------------------------------

test "a session/new request frames, decodes, and resolves in the v1 registry" {
    var pool: ScratchPool = .{};

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
    const method = message.method orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("session/new", method.text);

    const info = try acp.lookupMethod(.stable, method.text);
    try testing.expectEqual(acp.Side.agent, info.side);
    try testing.expect(!info.notification);
    // Baseline in both versions, so it is callable without a capability.
    try testing.expectEqualStrings("", info.gate);
    try testing.expectEqualStrings(
        "",
        (try acp.lookupMethod(.draft, method.text)).gate,
    );

    const params = message.params.value;
    const cwd = (try stringMember(params, "cwd", try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expect(acp.isAbsolutePath(cwd));
    try testing.expectEqualStrings("/home/user/project", cwd);

    // The `{"type": "acp", ...}` server declaration, verbatim from the RFD.
    // The published v2 schema has no `acp` branch, so the library carries the
    // three values the draft names rather than modelling the union.
    const servers = (try rawMember(params, "mcpServers", try pool.next())) orelse
        return error.TestUnexpectedResult;
    const server = (try firstArrayElement(servers, try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        bridge.server_declaration.kind,
        (try stringMember(server, "type", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        bridge.server_declaration.name,
        (try stringMember(server, "name", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        bridge.server_declaration.server_id,
        (try stringMember(server, "serverId", try pool.next())) orelse
            return error.TestUnexpectedResult,
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
    var pool: ScratchPool = .{};

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
    var pool: ScratchPool = .{};
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

    // The three fields the user reads and an outcome names back, on every
    // option the fixture offers.
    try testing.expectEqualStrings("opt-allow-once", request.options[0].option_id);
    try testing.expectEqualStrings("Allow once", request.options[0].name);
    try testing.expectEqual(
        acp.PermissionOptionKind.allow_once,
        knownKind(request.options[0]) orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings("opt-allow-always", request.options[1].option_id);
    try testing.expectEqualStrings("Always allow", request.options[1].name);
    try testing.expectEqual(
        acp.PermissionOptionKind.allow_always,
        knownKind(request.options[1]) orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings("opt-reject-once", request.options[2].option_id);
    try testing.expectEqualStrings("Reject", request.options[2].name);
    try testing.expectEqual(
        acp.PermissionOptionKind.reject_once,
        knownKind(request.options[2]) orelse return error.TestUnexpectedResult,
    );

    // v1 is a closed `oneOf` of the kinds the schema names, so every option
    // here decodes to a known kind and `grants` answers for each one instead
    // of reporting a kind this library does not know.
    try testing.expectEqual(
        true,
        request.options[0].grants() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqual(
        true,
        request.options[1].grants() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqual(
        false,
        request.options[2].grants() orelse return error.TestUnexpectedResult,
    );

    // The `ToolCallUpdate` is carried verbatim, so the identifier the agent
    // assigned is still readable in the decoded value.
    const call_id = (try stringMember(request.tool_call, "toolCallId", try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("call-1", call_id);
}

test "the RFD acp capability decodes as a boolean at v1 and a presence object at v2" {
    var pool: ScratchPool = .{};
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
    try testing.expectEqual(
        true,
        v1_acp.value orelse return error.TestUnexpectedResult,
    );
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
    var pool: ScratchPool = .{};

    const failure = try bridge.decodeOutcome(fixture.bridge_outcome_error, try pool.next());
    const error_text = switch (failure) {
        .@"error" => |payload| payload.text,
        .result => return error.TestUnexpectedResult,
    };
    // `-32022` is MCP's `UnsupportedProtocolVersion`, and the draft places it
    // inside the carrier rather than on the outer ACP message.
    try testing.expectEqualStrings(
        "-32022",
        (try numberMember(error_text, "code", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "Unsupported protocol version",
        (try stringMember(error_text, "message", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );
    // It is an MCP error the caller reports, not a transport failure it
    // retries, at either level.
    try testing.expect(!bridge.isBindingFailure(-32022, .outer));
    try testing.expect(!bridge.isBindingFailure(-32022, .inner));

    // `-32602` is the one number both spaces use, and the level is the only
    // thing that tells them apart.
    try testing.expect(bridge.isBindingFailure(-32602, .outer));
    try testing.expect(!bridge.isBindingFailure(-32602, .inner));
    // The binding allocates outside both MCP code ranges: the
    // implementation-defined `-32000` to `-32019` and the `-32020` to `-32099`
    // the specification reserves for itself. So the first range's two edges,
    // the second range's first code, and the `-32022` this fixture's carrier
    // holds are all MCP codes that a binding failure never reports.
    try testing.expect(!bridge.isBindingFailure(-32000, .outer));
    try testing.expect(!bridge.isBindingFailure(-32019, .outer));
    try testing.expect(!bridge.isBindingFailure(-32020, .outer));
    try testing.expect(!bridge.isBindingFailure(-32022, .outer));

    const success = try bridge.decodeOutcome(fixture.bridge_outcome_result, try pool.next());
    const result_text = switch (success) {
        .result => |payload| payload.text,
        .@"error" => return error.TestUnexpectedResult,
    };
    // The inner outcome is an ordinary MCP result, so the MCP decoder runs on
    // the bytes the binding carried through.
    const result_type = try mcp.decodeResultType(result_text, try pool.next());
    try testing.expectEqualStrings(
        "complete",
        result_type.value orelse return error.TestUnexpectedResult,
    );
    try testing.expect(result_type.isComplete());

    // `content` is the member this fixture was selected for — it is what makes
    // a `CallToolResult` that document rather than any other result — and the
    // provenance row above names the declaration it is copied from, so it is
    // read here rather than carried through the carrier unread.
    const content = (try rawMember(result_text, "content", try pool.next())) orelse
        return error.TestUnexpectedResult;
    const block = (try firstArrayElement(content, try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "text",
        (try stringMember(block, "type", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "hello",
        (try stringMember(block, "text", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );

    // The encoder, over the same normative outcome, and byte for byte. Neither
    // fixture under `test/golden/` carries a carrier `_meta`, and
    // `bridge.encodeOutcome` was not called by this step at all, so the default
    // test run had no coverage of the exact loss the outcome encoder exists to
    // prevent: a carrier accepted by the decoder and then not written back.
    //
    // The frame around the payload is written with a writer because the
    // payload itself is the fixture's own lexeme, indentation and all, and an
    // encoder that rebuilt it from a shape would have to produce different
    // bytes to pass. The member name and the brace are the literals, and they
    // are what pins the frame.
    var out: [1024]u8 = undefined;
    var owed: [2048]u8 = undefined;
    var writer = json.Writer.init(&out);
    try bridge.encodeOutcome(success, &writer);
    var canonical = json.Writer.init(&owed);
    try canonical.slice("{\"result\":");
    try canonical.slice(result_text);
    try canonical.byte('}');
    try testing.expectEqualStrings(canonical.written(), writer.written());

    // And the carrier, which is the member the whole comparison is for. The
    // object under `_meta` names keys this binding does not model, which is
    // the reason it is carried as text at all.
    var carrier = json.Writer.init(&owed);
    try carrier.slice("{\"result\":");
    try carrier.slice(result_text);
    try carrier.slice(",\"_meta\":{\"trace\":\"t\",\"vendor\":[1]}}");
    const carried_result = carrier.written();
    const result_arm = try bridge.decodeOutcome(carried_result, try pool.next());
    try testing.expectEqualStrings(
        "{\"trace\":\"t\",\"vendor\":[1]}",
        result_arm.result.meta orelse return error.TestUnexpectedResult,
    );
    var carried = json.Writer.init(&out);
    try bridge.encodeOutcome(result_arm, &carried);
    try testing.expectEqualStrings(carried_result, carried.written());

    // The same on the error arm, so a rejection cannot reach the peer stripped
    // of the metadata the caller put beside it.
    var error_carrier = json.Writer.init(&owed);
    try error_carrier.slice("{\"error\":");
    try error_carrier.slice(error_text);
    try error_carrier.slice(",\"_meta\":{\"trace\":\"t\"}}");
    const carried_error = error_carrier.written();
    const error_arm = try bridge.decodeOutcome(carried_error, try pool.next());
    try testing.expectEqualStrings(
        "{\"trace\":\"t\"}",
        error_arm.@"error".meta orelse return error.TestUnexpectedResult,
    );
    var carried_error_writer = json.Writer.init(&out);
    try bridge.encodeOutcome(error_arm, &carried_error_writer);
    try testing.expectEqualStrings(carried_error, carried_error_writer.written());
}

// --- A2A -----------------------------------------------------------------------

test "the A2A JSON-RPC error envelope maps to the error its ErrorInfo names" {
    var pool: ScratchPool = .{};

    const message = try jsonrpc.decode(fixture.a2a_jsonrpc_error, try pool.next());
    try testing.expectEqual(jsonrpc.Kind.response, message.kind);
    try testing.expectEqual(@as(?i64, 2), integerId(message.id));
    try testing.expect(message.result == null);

    const object = message.rpc_error orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, -32001), object.code);
    try testing.expectEqualStrings("Task not found", object.message);
    // The `data` member rides along, and it is what distinguishes this error
    // from the standard JSON-RPC codes: six of the nine A2A errors collapse
    // onto one status pair, so the code alone cannot name the cause.
    const data = object.data orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, data, "["));

    const known = a2a.A2aError.fromCode(object.code) orelse
        return error.TestUnexpectedResult;
    try testing.expect(known == .task_not_found);
    try testing.expectEqualStrings("TASK_NOT_FOUND", known.reason());
    // The A2A-specific codes live in their own range, and `-32001` is the
    // numerically highest of the nine because the whole range is negative, so
    // the code this envelope carries is the range's own upper bound and the
    // ceiling of all nine.
    try testing.expectEqual(a2a.error_range_max, object.code);
    var lowest: i32 = a2a.error_range_max;
    var highest: i32 = a2a.error_range_min;
    inline for (@typeInfo(a2a.A2aError).@"enum".fields) |field| {
        const code: i32 = @intFromEnum(@field(a2a.A2aError, field.name));
        lowest = @min(lowest, code);
        highest = @max(highest, code);
    }
    try testing.expect(lowest >= a2a.error_range_min);
    try testing.expectEqual(object.code, highest);
    try testing.expectEqual(@as(i32, -32009), lowest);

    // The ErrorInfo inside `data` is what a decoder keys on, and it agrees with
    // the code the envelope carries.
    const detail = (try firstArrayElement(data, try pool.next())) orelse
        return error.TestUnexpectedResult;
    const reason = (try stringMember(detail, "reason", try pool.next())) orelse
        return error.TestUnexpectedResult;
    const domain = (try stringMember(detail, "domain", try pool.next())) orelse
        return error.TestUnexpectedResult;
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
    var pool: ScratchPool = .{};

    // The HTTP+JSON/REST binding has no `jsonrpc` member, so this document is
    // not a JSON-RPC response and reading it as one would invent an `id`.
    try testing.expectError(
        error.MissingField,
        jsonrpc.decode(fixture.a2a_rest_error, try pool.next()),
    );

    const error_object = (try rawMember(fixture.a2a_rest_error, "error", try pool.next())) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "404",
        (try numberMember(error_object, "code", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "NOT_FOUND",
        (try stringMember(error_object, "status", try pool.next())) orelse
            return error.TestUnexpectedResult,
    );

    // Six of the nine A2A errors collapse onto `FAILED_PRECONDITION` and
    // `400 Bad Request`, so the status is not discriminating and the `reason`
    // is the only discriminator, which is why the specification requires the
    // ErrorInfo object in `details`.
    const detail = (try firstArrayElement(
        (try rawMember(error_object, "details", try pool.next())) orelse
            return error.TestUnexpectedResult,
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;
    const reason = (try stringMember(detail, "reason", try pool.next())) orelse
        return error.TestUnexpectedResult;
    const domain = (try stringMember(detail, "domain", try pool.next())) orelse
        return error.TestUnexpectedResult;
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
    var pool: ScratchPool = .{};

    const protected = (try stringMember(
        fixture.a2a_agent_card_signature,
        "protected",
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;
    const signature = (try stringMember(
        fixture.a2a_agent_card_signature,
        "signature",
        try pool.next(),
    )) orelse return error.TestUnexpectedResult;

    // §8.4.2 spells the signing input with `BASE64URL`, so both members are
    // base64url without padding. A standard-alphabet decoder that accepted the
    // bytes would have to have substituted `-` and `_` for `+` and `/`, which
    // would change the signature.
    try testing.expect(std.mem.findScalar(u8, protected, '=') == null);
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

test "the AgentCard signature fixture decodes through the codec and re-encodes to its canonical form" {
    var pool: ScratchPool = .{};

    // The fixture is pretty-printed, so it is not the bytes the encoder writes.
    // The two differ in whitespace and in nothing else, which is the whole of
    // what this pins. Reading two members out by hand, as the test above does,
    // says nothing about whether the decoder takes the document as a whole.
    const signature = try a2a.decodeAgentCardSignature(
        fixture.a2a_agent_card_signature,
        try pool.next(),
    );
    try testing.expectEqualStrings(
        "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpPU0UiLCJraWQiOiJrZXktMSIsImpr" ++
            "dSI6Imh0dHBzOi8vZXhhbXBsZS5jb20vYWdlbnQvandrcy5qc29uIn0",
        signature.protected,
    );
    try testing.expectEqualStrings(
        "QFdkNLNszlGj3z3u0YQGt_T9LixY3qtdQpZmsTdDHDe3fXV9y9-B3m2-XgC" ++
            "pzuhiLt8E0tV6HXoZKHv4GtHgKQ",
        signature.signature,
    );
    // The shape declares two required members and one optional, and the
    // published example carries neither `header` nor a patch component in the
    // version it does carry. A decoder that invented a member would be reading
    // something the fixture does not have.
    try testing.expect(signature.header == null);

    var out: [512]u8 = undefined;
    var writer = json.Writer.init(&out);
    try a2a.encodeAgentCardSignature(signature, &writer);
    try testing.expectEqualStrings(
        "{\"protected\":\"eyJhbGciOiJFUzI1NiIsInR5cCI6IkpPU0UiLCJraWQiOiJr" ++
            "ZXktMSIsImprdSI6Imh0dHBzOi8vZXhhbXBsZS5jb20vYWdlbnQvandrcy5" ++
            "qc29uIn0\",\"signature\":\"QFdkNLNszlGj3z3u0YQGt_T9LixY3qtdQp" ++
            "ZmsTdDHDe3fXV9y9-B3m2-XgCpzuhiLt8E0tV6HXoZKHv4GtHgKQ\"}",
        writer.written(),
    );

    // And the canonical form decodes back to the same two members, so what is
    // pinned above is the pair agreeing rather than one of them alone.
    const again = try a2a.decodeAgentCardSignature(writer.written(), try pool.next());
    try testing.expectEqualStrings(signature.protected, again.protected);
    try testing.expectEqualStrings(signature.signature, again.signature);
}
