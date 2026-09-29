//! JSON-RPC 2.0, the base that MCP and ACP both sit on.
//!
//! PROTOCOLS.md section 3. A2A's JSON-RPC binding is JSON-RPC 2.0 as well.
//!
//! | Element | Value |
//! | --- | --- |
//! | `jsonrpc` | `"2.0"`, always present, always this exact string |
//! | `id` | Integer or string. Absent on notifications. `i64`, range-checked |
//! | `method` | String. Split once on `/` for the category-action form |
//! | `params` | Object or array. `null` and absent are distinct and preserved |
//! | `result` | Present on success, mutually exclusive with `error` |
//! | `error` | `{code, message, data?}`. `code` is `i32` |
//!
//! A message with both `result` and `error`, or with neither, is a decode error.
//! A message with an `id` and no `method` is a response; a message with a
//! `method` and no `id` is a notification; a message with both is a request.
//!
//! `encode` enforces the same shapes, because a message its own decoder would
//! reject is a caller bug and not a wire condition. It validates before it
//! writes, so a refused message leaves the writer untouched, and it omits the
//! `id` member on a notification rather than writing a null the decoder would
//! then reject.
//!
//! ## What "exact inverse" means here
//!
//! PROTOCOLS.md section 2 requires `encode(decode(b)) == b`. For a JSON format
//! that holds only up to the equivalence the format itself defines: JSON permits
//! any member order, any insignificant whitespace, and several spellings of the
//! same number. So members the library models are carried as borrowed text and
//! re-emitted verbatim, and the round trip is asserted at the value level,
//! `decode(encode(decode(b))) == decode(b)`. A member the library does not model
//! is skipped on decode, and re-encoding a message therefore drops it — a stated
//! consequence of not modelling it, not a silent mutation.

const std = @import("std");
const root = @import("root.zig");
const json = @import("json.zig");

const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

/// The one version string JSON-RPC 2.0 admits.
pub const version = "2.0";

/// A JSON-RPC request id.
///
/// An id is an integer or a string, never a float and never `null`. MCP states
/// the `null` ban explicitly, and a fractional id has never been legal, so both
/// are rejected here rather than coerced.
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,
};

/// A method name, split once on `/`.
///
/// MCP and ACP v0.3 use the category-action form. A method with no `/` is legal
/// JSON-RPC, so both halves are then empty and `text` is the whole name.
pub const Method = struct {
    text: []const u8,
    category: []const u8,
    action: []const u8,

    pub fn split(text: []const u8) Method {
        const slash = std.mem.findScalar(u8, text, '/') orelse
            return .{ .text = text, .category = "", .action = "" };
        return .{
            .text = text,
            .category = text[0..slash],
            .action = text[slash + 1 ..],
        };
    }
};

/// The `params` member, preserving the difference between the three states the
/// specification calls distinct.
pub const Params = union(enum) {
    /// The member was not present at all.
    absent,
    /// The member was present with the JSON value `null`.
    null_value,
    /// The member was an object or an array, held as borrowed JSON text.
    value: []const u8,
};

/// A JSON-RPC error object.
///
/// `data` is arbitrary JSON with no shape the base layer can assume, so it is
/// carried as borrowed text. A protocol that gives `data` a structure decodes it
/// from that text.
pub const Error = struct {
    code: i32,
    message: []const u8,
    data: ?[]const u8 = null,
};

/// What a message is, as PROTOCOLS.md section 3 defines it.
///
/// Classification is on `id` and `method` alone: `id` and no `method` is a
/// response, `method` and no `id` is a notification, and both is a request.
/// A response carrying `error` instead of `result` is still a response, so
/// there is no fourth variant. Which of the two it carries stays on the
/// message, where exactly one of `result` and `rpc_error` is set and the
/// other is null, so nothing about the wire is lost by the collapse.
///
/// SPEC-DECISIONS.md section 3 records the decision and the authority it
/// rests on.
pub const Kind = enum {
    request,
    notification,
    response,
};

/// A decoded JSON-RPC message.
///
/// Every slice borrows the caller's input or the caller's scratch buffer, and
/// none is retained past the decode call. Slices that had to be unescaped took
/// separate regions of that scratch, so `method` and `rpc_error.message` can be
/// held at once and neither is clobbered by the members decoded after them.
pub const Message = struct {
    kind: Kind,
    id: ?Id = null,
    method: ?Method = null,
    params: Params = .absent,
    /// The `result` member, as borrowed JSON text, on a successful response.
    result: ?[]const u8 = null,
    /// The `error` member. Named `rpc_error` because `error` is a Zig keyword,
    /// and a quoted field at every access site is worse than one honest name.
    rpc_error: ?Error = null,
};

/// The standard JSON-RPC 2.0 error codes, table 3.1 of PROTOCOLS.md.
pub const StandardError = enum(i32) {
    /// Invalid JSON was received.
    parse_error = -32700,
    /// The JSON is not a valid request object.
    invalid_request = -32600,
    /// The method does not exist for this revision.
    method_not_found = -32601,
    /// Invalid method parameters.
    invalid_params = -32602,
    /// Internal error in the peer.
    internal_error = -32603,

    pub fn fromCode(code: i32) ?StandardError {
        return switch (code) {
            -32700 => .parse_error,
            -32600 => .invalid_request,
            -32601 => .method_not_found,
            -32602 => .invalid_params,
            -32603 => .internal_error,
            else => null,
        };
    }
};

/// Decode one JSON-RPC message.
///
/// `scratch` backs any string carrying a JSON escape; pass a zero-length buffer
/// when the peer is known to send plain text. It must be large enough for every
/// escaped string in the message, since each takes its own region of it:
/// `method`, an error `message` and any escaped key are all still live when the
/// decode returns, and a shared region would corrupt the first of them.
///
/// One call decodes one message and refuses trailing data. A batch array is
/// therefore split by the transport, not by this function, which is the right
/// way round: a reader that stopped at the first closing brace would accept
/// `{a}{b}` and quietly drop the second half of the frame.
pub fn decode(input: []const u8, scratch: []u8) DecodeError!Message {
    var reader = json.Reader.init(input);
    // `kind` is derived from the members seen, and is assigned before the
    // return. The initialiser is a placeholder, not a default: every path that
    // returns a `Message` has set it.
    var message: Message = .{ .kind = .request };

    var saw_version = false;
    var saw_id = false;
    var saw_method = false;
    var saw_result = false;
    var saw_error = false;

    // An empty object has no `jsonrpc` and no `id` or `method`, so it is not a
    // message. Rejecting it here keeps the membership rules in one place.
    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "jsonrpc")) {
            const text = try reader.string(scratch);
            if (!std.mem.eql(u8, text, version)) return error.UnsupportedVersion;
            saw_version = true;
        } else if (std.mem.eql(u8, key, "id")) {
            message.id = try decodeId(&reader, scratch);
            saw_id = true;
        } else if (std.mem.eql(u8, key, "method")) {
            message.method = Method.split(try reader.string(scratch));
            saw_method = true;
        } else if (std.mem.eql(u8, key, "params")) {
            message.params = try decodeParams(&reader, scratch);
        } else if (std.mem.eql(u8, key, "result")) {
            message.result = try reader.rawValue(scratch);
            saw_result = true;
        } else if (std.mem.eql(u8, key, "error")) {
            message.rpc_error = try decodeError(&reader, scratch);
            saw_error = true;
        } else {
            try reader.skipValue(scratch);
        }
    }

    // A frame carries one message. Anything after the closing brace is either
    // a second message the transport did not split or a peer that disagrees
    // with the transport about where a frame ends, and both are worth an
    // error rather than a silent truncation.
    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_version) return error.MissingField;

    // A message with neither `id` nor `method` is not a JSON-RPC message. The
    // other three combinations are the three valid shapes: a request has both,
    // a notification has `method` alone, a response has `id` alone.
    if (!saw_id and !saw_method) return error.MissingField;
    // `result` and `error` are mutually exclusive, and a request or a
    // notification carries neither.
    if (saw_result and saw_error) return error.InvalidField;
    if (saw_method and (saw_result or saw_error)) return error.InvalidField;
    if (!saw_method and !saw_result and !saw_error) return error.MissingField;

    // `error` does not enter into it. PROTOCOLS.md section 3 classifies on
    // `id` and `method`, and a caller that needs to tell a successful
    // response from a failed one reads `rpc_error`, which is set on exactly
    // the second.
    message.kind = if (saw_method)
        (if (saw_id) .request else .notification)
    else
        .response;

    return message;
}

fn decodeId(reader: *json.Reader, scratch: []u8) DecodeError!Id {
    reader.skipWhitespace();
    const byte = reader.peek() orelse return error.Truncated;
    switch (byte) {
        '"' => return .{ .string = try reader.string(scratch) },
        '0'...'9', '-' => {
            const lexeme = try reader.number();
            return .{
                .integer = std.fmt.parseInt(i64, lexeme, 10) catch |err| switch (err) {
                    error.Overflow => return error.LimitExceeded,
                    // `parseInt` rejects a fractional or exponent lexeme. That is a
                    // type error, not an overflow, so it is reported as such rather
                    // than silently truncating the id.
                    error.InvalidCharacter => return error.InvalidField,
                },
            };
        },
        // An explicit `null` id is a decoding error, not an absent id.
        'n' => return error.InvalidField,
        else => return error.MalformedJson,
    }
}

fn decodeParams(reader: *json.Reader, scratch: []u8) DecodeError!Params {
    reader.skipWhitespace();
    const byte = reader.peek() orelse return error.Truncated;
    switch (byte) {
        'n' => {
            try reader.nullLiteral();
            return .null_value;
        },
        '{', '[' => return .{ .value = try reader.rawValue(scratch) },
        else => return error.MalformedJson,
    }
}

fn decodeError(reader: *json.Reader, scratch: []u8) DecodeError!Error {
    var result: Error = .{ .code = 0, .message = "" };
    var saw_code = false;
    var saw_message = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "code")) {
            const lexeme = try reader.number();
            result.code = std.fmt.parseInt(i32, lexeme, 10) catch return error.InvalidField;
            saw_code = true;
        } else if (std.mem.eql(u8, key, "message")) {
            result.message = try reader.string(scratch);
            saw_message = true;
        } else if (std.mem.eql(u8, key, "data")) {
            result.data = try reader.rawValue(scratch);
        } else {
            try reader.skipValue(scratch);
        }
    }

    // `code` and `message` are required; `data` is the only optional member.
    if (!saw_code or !saw_message) return error.MissingField;
    return result;
}

/// Encode a message into `writer`.
///
/// The caller owns the buffer, so a short buffer is `error.BufferTooSmall`
/// rather than an allocation.
///
/// The message is validated before a byte is written, so a rejected one leaves
/// the writer untouched and a caller can report the error without having
/// produced a half message to discard.
pub fn encode(message: Message, writer: *json.Writer) EncodeError!void {
    try validate(message);

    try writer.byte('{');

    try writer.slice("\"jsonrpc\":");
    try writer.string(version);

    // A notification has no id, and that absence is what makes it one, so the
    // member is omitted rather than required. `validate` has already refused a
    // response without one, which is a different thing entirely.
    if (message.id) |id| {
        try writer.slice(",\"id\":");
        switch (id) {
            .integer => |number| {
                // Formatted into a buffer that outlives the write. A helper
                // returning a slice into its own frame would dangle here.
                var digits: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&digits, "{d}", .{number}) catch {
                    return error.BufferTooSmall;
                };
                try writer.slice(text);
            },
            .string => |text| try writer.string(text),
        }
    }

    if (message.method) |method| {
        try writer.slice(",\"method\":");
        try writer.string(method.text);
    }

    switch (message.params) {
        .absent => {},
        .null_value => try writer.slice(",\"params\":null"),
        .value => |text| {
            try writer.slice(",\"params\":");
            try writer.slice(text);
        },
    }

    if (message.result) |text| {
        try writer.slice(",\"result\":");
        try writer.slice(text);
    }

    if (message.rpc_error) |object| {
        try writer.slice(",\"error\":{\"code\":");
        {
            var digits: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&digits, "{d}", .{object.code}) catch {
                return error.BufferTooSmall;
            };
            try writer.slice(text);
        }
        try writer.slice(",\"message\":");
        try writer.string(object.message);
        if (object.data) |data| {
            try writer.slice(",\"data\":");
            try writer.slice(data);
        }
        try writer.byte('}');
    }

    try writer.byte('}');
}

/// Refuse a message `decode` would never have produced.
///
/// PROTOCOLS.md section 3 defines the three kinds, and the rules here are
/// the same membership rules `decode` applies, spelled out for a value that
/// could have been built wrong. A message holding both a result and an
/// error, or carrying a result under a method, describes a document that
/// cannot exist on the wire. Encoding it would emit bytes this library's own
/// decoder rejects, which is a programming error in the caller and not a
/// wire condition, so it is `InvalidField`.
///
/// The rules here mirror `decode` exactly. If one of them is relaxed there, it
/// has to be relaxed here too, or `decode(encode(x)) != x`.
fn validate(message: Message) EncodeError!void {
    const has_method = message.method != null;
    if (message.result != null and message.rpc_error != null) return error.InvalidField;
    if (has_method and (message.result != null or message.rpc_error != null)) {
        return error.InvalidField;
    }
    // Without a method the message is a response, and a response the peer
    // cannot match to a request is not one.
    if (!has_method and message.id == null) return error.InvalidField;
    // A response with neither a result nor an error says nothing, which
    // PROTOCOLS.md section 3 calls a decode error. Writing one would put bytes
    // on the wire that this library refuses to read back.
    if (!has_method and message.result == null and message.rpc_error == null) {
        return error.InvalidField;
    }
}

// Integer formatting is done inline in `encode` rather than through a helper:
// a helper returning a slice into its own stack frame would dangle.

const testing = std.testing;

test "decode classifies the three message shapes" {
    var scratch: [64]u8 = undefined;

    const request = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    , scratch[0..]);
    try testing.expectEqual(Kind.request, request.kind);
    try testing.expectEqual(@as(i64, 1), request.id.?.integer);
    try testing.expectEqualStrings("tools/call", request.method.?.text);

    const notification = try decode(
        \\{"jsonrpc":"2.0","method":"notifications/cancelled"}
    , &scratch);
    try testing.expectEqual(Kind.notification, notification.kind);
    try testing.expectEqual(@as(?Id, null), notification.id);

    const response = try decode(
        \\{"jsonrpc":"2.0","id":"a","result":{"resultType":"complete"}}
    , &scratch);
    try testing.expectEqual(Kind.response, response.kind);

    // An error response is still a response. The two live on the message, not
    // in a fourth kind, so a peer that answers with an error is not
    // classified as something this library invented.
    const failure = try decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}
    , &scratch);
    try testing.expectEqual(Kind.response, failure.kind);
    try testing.expectEqual(@as(?[]const u8, null), failure.result);
    try testing.expectEqual(@as(i32, -32601), failure.rpc_error.?.code);
}

test "method splits once on the slash" {
    const method = Method.split("notifications/resources/updated");
    try testing.expectEqualStrings("notifications", method.category);
    // Only the first slash splits, so the action keeps its own slash.
    try testing.expectEqualStrings("resources/updated", method.action);

    const bare = Method.split("ping");
    try testing.expectEqualStrings("ping", bare.text);
    try testing.expectEqualStrings("", bare.category);
    try testing.expectEqualStrings("", bare.action);
}

test "params absent, null and value are three distinct states" {
    var scratch: [64]u8 = undefined;

    const absent = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m"}
    , &scratch);
    try testing.expect(absent.params == .absent);

    const nulled = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","params":null}
    , &scratch);
    try testing.expect(nulled.params == .null_value);

    const valued = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":1}}
    , &scratch);
    try testing.expectEqualStrings("{\"a\":1}", valued.params.value);
}

test "an i64 id beyond f64 precision survives the round trip" {
    var scratch: [64]u8 = undefined;
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":9007199254740993,"method":"m"}
    , &scratch);
    try testing.expectEqual(@as(i64, 9007199254740993), decoded.id.?.integer);
}

test "a null or fractional id is a decode error, not a coercion" {
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":null,"method":"m"}
    , &scratch));
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":1.5,"method":"m"}
    , &scratch));
}

test "an out-of-range id is LimitExceeded" {
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.LimitExceeded, decode(
        \\{"jsonrpc":"2.0","id":99999999999999999999,"method":"m"}
    , &scratch));
}

test "a wrong version string is UnsupportedVersion" {
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.UnsupportedVersion, decode(
        \\{"jsonrpc":"1.0","id":1,"method":"m"}
    , &scratch));
    try testing.expectError(error.MissingField, decode(
        \\{"id":1,"method":"m"}
    , &scratch));
}

test "both result and error, or neither, is a decode error" {
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"m"}}
    , &scratch));
    try testing.expectError(error.MissingField, decode(
        \\{"jsonrpc":"2.0","id":1}
    , &scratch));
    try testing.expectError(error.MissingField, decode(
        \\{}
    , &scratch));
}

test "a request carrying result or error is a decode error" {
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","result":{}}
    , &scratch));
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","error":{"code":1,"message":"m"}}
    , &scratch));
}

test "params on a response is carried, not refused" {
    // PROTOCOLS.md section 3 lists no such prohibition, and its decode-error
    // list is exhaustive. Refusing a member the specification permits is a
    // rule the library invented, and a peer that sends one gets no answer at
    // all. `Params` already models the three states, so it round trips.
    var scratch: [64]u8 = undefined;
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"result":{},"params":{"trace":"t"}}
    , &scratch);
    try testing.expectEqual(Kind.response, decoded.kind);
    try testing.expectEqualStrings("{\"trace\":\"t\"}", decoded.params.value);
}

test "a result member is carried verbatim including nested structure" {
    var scratch: [128]u8 = undefined;
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","ttlMs":5000}}
    , &scratch);
    try testing.expectEqualStrings(
        "{\"resultType\":\"complete\",\"ttlMs\":5000}",
        decoded.result.?,
    );
}

test "error data is carried as borrowed text" {
    var scratch: [128]u8 = undefined;
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32021,"message":"m","data":{"requiredCapabilities":{}}}}
    , &scratch);
    try testing.expectEqualStrings("{\"requiredCapabilities\":{}}", decoded.rpc_error.?.data.?);
}

test "an error object missing code or message is a decode error" {
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.MissingField, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"message":"m"}}
    , &scratch));
    try testing.expectError(error.MissingField, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":1}}
    , &scratch));
}

test "standard error codes match the table" {
    try testing.expectEqual(@as(?StandardError, .parse_error), StandardError.fromCode(-32700));
    try testing.expectEqual(@as(?StandardError, .invalid_request), StandardError.fromCode(-32600));
    try testing.expectEqual(@as(?StandardError, .method_not_found), StandardError.fromCode(-32601));
    try testing.expectEqual(@as(?StandardError, .invalid_params), StandardError.fromCode(-32602));
    try testing.expectEqual(@as(?StandardError, .internal_error), StandardError.fromCode(-32603));
    try testing.expectEqual(@as(?StandardError, null), StandardError.fromCode(-32020));
}

test "encode then decode reproduces the value" {
    var scratch: [256]u8 = undefined;
    const source =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"search","arguments":{"q":"zig"}}}
    ;
    const first = try decode(source, &scratch);

    var buffer: [512]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encode(first, &writer);

    const second = try decode(writer.written(), &scratch);
    try testing.expectEqual(first.kind, second.kind);
    try testing.expectEqual(first.id.?.integer, second.id.?.integer);
    try testing.expectEqualStrings(first.method.?.text, second.method.?.text);
    try testing.expectEqualStrings(first.params.value, second.params.value);
}

test "encode then decode reproduces a negative error code exactly" {
    var scratch: [256]u8 = undefined;
    const source =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"HeaderMismatch"}}
    ;
    const first = try decode(source, &scratch);

    var buffer: [256]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encode(first, &writer);
    try testing.expect(std.mem.find(u8, writer.written(), "-32020") != null);

    const second = try decode(writer.written(), &scratch);
    try testing.expectEqual(@as(i32, -32020), second.rpc_error.?.code);
}

test "encode reports BufferTooSmall rather than truncating" {
    var buffer: [8]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    const message: Message = .{
        .kind = .request,
        .id = .{ .integer = 1 },
        .method = Method.split("tools/call"),
    };
    try testing.expectError(error.BufferTooSmall, encode(message, &writer));
}

test "encode refuses a response with no id" {
    var buffer: [128]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .response, .result = "{}" },
        &writer,
    ));
    // Refused before a byte was written, so the caller has nothing to discard.
    try testing.expectEqual(@as(usize, 0), writer.written().len);
}

test "a notification round trips, having no id to write" {
    // A notification is accepted input, so refusing to encode it broke
    // `encode(decode(b)) == b` for a whole class of valid messages.
    var scratch: [128]u8 = undefined;
    const source =
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}
    ;
    const first = try decode(source, &scratch);
    try testing.expectEqual(Kind.notification, first.kind);

    var buffer: [256]u8 = undefined;
    var writer = json.Writer.init(&buffer);
    try encode(first, &writer);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\"," ++
            "\"params\":{\"requestId\":7}}",
        writer.written(),
    );

    const second = try decode(writer.written(), &scratch);
    try testing.expectEqual(Kind.notification, second.kind);
    try testing.expectEqual(@as(?Id, null), second.id);
    try testing.expectEqualStrings("notifications/cancelled", second.method.?.text);
    try testing.expectEqualStrings("{\"requestId\":7}", second.params.value);
}

test "an escaped method survives the params that follow it" {
    // Both take a region of the same scratch buffer, and both are still live
    // when the decode returns. `tools/call` and the params each need an
    // escape to be in this message at all, which is what forces the issue.
    var scratch: [64]u8 = undefined;
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"tools\u002Fcall","params":{"a":"x\ny"}}
    , &scratch);
    try testing.expectEqualStrings("tools/call", decoded.method.?.text);
    try testing.expectEqualStrings("tools", decoded.method.?.category);
    try testing.expectEqualStrings("call", decoded.method.?.action);
    // `params` is carried as raw JSON text, so the `\n` is still the two-byte
    // escape sequence the peer sent, not a decoded newline.
    try testing.expectEqualStrings("{\"a\":\"x\\ny\"}", decoded.params.value);
}

test "an escaped error message survives the data that follows it" {
    // `data` is carried as raw text, and reading it walks over the escaped
    // string inside it. A scheme that unescaped into the same region as the
    // message would leave `message` reading as whatever `data` holds.
    var scratch: [128]u8 = undefined;
    // The newline between the members is the literal's own line break, which
    // JSON reads as insignificant whitespace.
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32021,
        \\"message":"line\none","data":{"a":"x\ny"}}}
    , &scratch);
    try testing.expectEqualStrings("line\none", decoded.rpc_error.?.message);
    try testing.expectEqualStrings("{\"a\":\"x\\ny\"}", decoded.rpc_error.?.data.?);
}

test "trailing data after the message is a decode error" {
    var scratch: [128]u8 = undefined;
    // Two messages in one frame, which is what a transport that failed to
    // split would deliver. Decoding the first and dropping the second is how a
    // request goes missing with nothing logged.
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m"}{"jsonrpc":"2.0","id":2,"method":"m"}
    , &scratch));
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m"}garbage
    , &scratch));
    // A trailing newline is a delimiter, not trailing data.
    _ = try decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"}\n", &scratch);
}

test "encode refuses a message decode would reject, and writes nothing" {
    var buffer: [128]u8 = undefined;

    var both = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .response,
            .id = .{ .integer = 1 },
            .result = "{}",
            .rpc_error = .{ .code = -32603, .message = "m" },
        },
        &both,
    ));
    try testing.expectEqual(@as(usize, 0), both.written().len);

    var method_bearing = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .request,
            .id = .{ .integer = 1 },
            .method = Method.split("m"),
            .result = "{}",
        },
        &method_bearing,
    ));
    try testing.expectEqual(@as(usize, 0), method_bearing.written().len);

    // A response with neither a result nor an error, which `decode` calls a
    // missing field and the specification calls unencodable.
    var silent = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .response, .id = .{ .integer = 1 } },
        &silent,
    ));
    try testing.expectEqual(@as(usize, 0), silent.written().len);
}

test "an unknown top-level member is skipped, not a decode error" {
    var scratch: [128]u8 = undefined;
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","extensionField":{"a":[1,2]}}
    , &scratch);
    try testing.expectEqual(Kind.request, decoded.kind);
}
