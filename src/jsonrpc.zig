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
/// separate regions of that scratch, so `method`, a string `id` and
/// `rpc_error.message` can be held at once and none is clobbered by the members
/// decoded after it.
pub const Message = struct {
    /// What this message is. `encode` refuses a kind that disagrees with `id`
    /// and `method`, because `decode` derives the classification from them.
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

/// A decoded request: the shape a caller who intends to answer it wants.
///
/// `Message` is the general shape, and a handler reading one decides what it
/// holds before it does anything else. This is that shape with the members
/// which make answering meaningless removed, so a notification and a response
/// are not `Request` values at all. A builder takes a `Request`, so there is
/// nothing to hand it that it must not answer.
///
/// The slices borrow the caller's input and scratch exactly as `Message` does.
/// See `decodeRequest` for which buffer each one comes from.
pub const Request = struct {
    /// The id the answer echoes.
    id: Id,
    /// The method the caller called.
    method: Method,
    /// The params the caller sent, in the state the caller sent them.
    params: Params,
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
/// `method`, a string `id`, an error `message` and any escaped key are all still
/// live when the decode returns, and a shared region would corrupt the first of
/// them.
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

/// Decode one message and keep it only if it is a request.
///
/// The scan is `decode`'s and this projects the result, so the two cannot
/// disagree about what a member is, and a request cannot decode one way here
/// and another way there. The bump-offset scratch discipline is `decode`'s
/// for the same reason: this function adds no walk of its own that could spend
/// a region twice.
///
/// Two refusals, both members of `DecodeError`. A message with no `id` is
/// `MissingField`, because a message nobody can match an answer to is a
/// notification. A message carrying `result` or `error` is `InvalidField`,
/// because it is a response, and that is read before its absent `method` so a
/// response is never reported as an incomplete request.
///
/// A notification and a response are therefore not `Request` values at all,
/// which is the point of the type: a builder takes a `Request`, so there is
/// nothing to hand it that it must not answer.
///
/// `method.text` and a string `id` borrow `input`, and an escaped one borrows
/// `scratch`. The value is live only while both buffers are.
pub fn decodeRequest(input: []const u8, scratch: []u8) DecodeError!Request {
    const message = try decode(input, scratch);
    // Read before the id and the method, because a response carries an id: the
    // `result` and the `error` are what say what the message is, and the
    // missing `method` behind them would name a different fault.
    if (message.result != null or message.rpc_error != null) return error.InvalidField;
    const id = message.id orelse return error.MissingField;
    // `decode` has refused every message that carries neither a method nor a
    // result, and the line above has refused every message that carries a
    // result, so a message that reaches here has a method. The check is
    // written out rather than unwrapped because an unwrap is a panic on a path
    // the two lines above already closed.
    const method = message.method orelse return error.MissingField;
    return .{ .id = id, .method = method, .params = message.params };
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
            // A code outside `i32` is the same fault as an id outside `i64`.
            // PROTOCOLS.md section 2.1 names `LimitExceeded` a numeric bound
            // the protocol states, which is exactly what an overflow is.
            result.code = std.fmt.parseInt(i32, lexeme, 10) catch |err| switch (err) {
                error.Overflow => return error.LimitExceeded,
                // `parseInt` rejects a fractional or exponent lexeme. That is a
                // type error rather than an overflow, and `decodeId` reports it
                // as one.
                error.InvalidCharacter => return error.InvalidField,
            };
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
        try writeId(id, writer);
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

    if (message.rpc_error) |object| try writeErrorObject(object, writer);

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
    // `decode` derives the kind from the members and never reads a kind the
    // caller set, so a message whose kind disagrees comes back classified as
    // something else and `decode(encode(x)) != x`. A notification carrying an
    // `id` is the ordinary way to build one: it satisfies every rule above and
    // encodes to a frame the wire calls a request.
    const derived: Kind = if (has_method)
        (if (message.id != null) .request else .notification)
    else
        .response;
    if (message.kind != derived) return error.InvalidField;
}

/// Write an id in the arm it arrived in.
///
/// PROTOCOLS.md section 3 states that an id is an integer or a string, so both
/// arms are a form the protocol admits and neither is a fallback for the
/// other. A string goes through the writer as a JSON string, so a quote or a
/// control byte in it is escaped rather than spliced into the frame.
///
/// The integer is formatted into a buffer that outlives the write. A helper
/// returning a slice into its own stack frame would dangle here.
fn writeId(id: Id, writer: *json.Writer) EncodeError!void {
    switch (id) {
        .integer => |value| {
            var digits: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch
                return error.BufferTooSmall;
            try writer.slice(text);
        },
        .string => |text| try writer.string(text),
    }
}

/// Write the `error` member, with the comma that separates it from the member
/// before it. The brace that closes the frame is the caller's, because the
/// frame is not only an error.
fn writeErrorObject(object: Error, writer: *json.Writer) EncodeError!void {
    try writer.slice(",\"error\":{\"code\":");
    var digits: [16]u8 = undefined;
    const code = std.fmt.bufPrint(&digits, "{d}", .{object.code}) catch {
        return error.BufferTooSmall;
    };
    try writer.slice(code);
    try writer.slice(",\"message\":");
    try writer.string(object.message);
    if (object.data) |data| {
        try writer.slice(",\"data\":");
        try writer.slice(data);
    }
    try writer.byte('}');
}

/// Write the answer to `request`: a result or an error, and exactly one.
///
/// The two bodies are separate parameters so the rule is expressible. No
/// result and no error is `InvalidField`, and a result beside an error is
/// `InvalidField`. That is the same rule `validate` applies to a whole
/// `Message`, and a builder that took only a result could not enforce the
/// first half of it. The second half is the one a caller gets wrong: a handler
/// that puts an error object inside a result has told the peer the call
/// succeeded, and a client that reads only the result reports a refusal as the
/// answer.
///
/// The rule is applied before a byte is written, so a refused answer leaves the
/// writer untouched. A short writer is `error.BufferTooSmall`, which is the
/// caller's own buffer fault rather than a wire condition.
///
/// A body is spliced verbatim, the way `Conn.call` splices caller params. A
/// raw newline inside one is caught by the framer on the way to the wire, as
/// `Conn` reports it, and is not checked a second time here: the check belongs
/// in one place and this is not it.
///
/// The id is echoed in the arm it arrived in, so an integer id stays an integer
/// and a string id stays a string. A response carries no `method`, and no
/// `params` member is written: PROTOCOLS.md section 3 permits one on a
/// response, and a caller that needs it goes through `encode`.
pub fn encodeResponse(
    request: Request,
    result: ?[]const u8,
    object: ?Error,
    writer: *json.Writer,
) EncodeError!void {
    if (result == null and object == null) return error.InvalidField;
    if (result != null and object != null) return error.InvalidField;

    try writer.byte('{');
    try writer.slice("\"jsonrpc\":");
    try writer.string(version);
    try writer.slice(",\"id\":");
    try writeId(request.id, writer);

    if (result) |text| {
        try writer.slice(",\"result\":");
        try writer.slice(text);
    }
    if (object) |value| try writeErrorObject(value, writer);

    try writer.byte('}');
}

/// The answer to `request` that carries `object` as its error, in `out`.
///
/// The buffer form of `encodeResponse`, for a caller that holds a buffer
/// rather than a writer. The returned slice is the prefix of `out` this call
/// wrote, and it borrows that buffer.
pub fn errorResponse(request: Request, object: Error, out: []u8) EncodeError![]const u8 {
    var writer = json.Writer.init(out);
    try encodeResponse(request, null, object, &writer);
    return writer.written();
}

/// The `-32601` answer for a method this peer does not have, in `out`.
///
/// The code is `StandardError.method_not_found` and the message is the name
/// table 3.1 of PROTOCOLS.md gives that code. The bytes are the ones the
/// hand-written builders in `mcp_session` and `acp_session` write, member for
/// member and comma for comma, so a cutover to this one changes nothing on the
/// wire.
pub fn methodNotFound(request: Request, out: []u8) EncodeError![]const u8 {
    return errorResponse(request, .{
        .code = @intFromEnum(StandardError.method_not_found),
        .message = "Method not found",
    }, out);
}

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

test "an out-of-range error code is LimitExceeded, as an out-of-range id is" {
    // Both are the same fault read through the same `DecodeError`: the number
    // does not fit the width the protocol states for it. Before the two paths
    // agreed, a peer learned about it from a `code` and from an `id` in two
    // different ways, and neither way said the bound was a bound.
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.LimitExceeded, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":99999999999999999999,"message":"m"}}
    , &scratch));
    try testing.expectError(error.LimitExceeded, decode(
        \\{"jsonrpc":"2.0","id":99999999999999999999,"method":"m"}
    , &scratch));
    // The other arm, which the two paths also share: a fraction is a type
    // fault rather than an overflow, so it stays `InvalidField`.
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":1.5,"message":"m"}}
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

test "encode refuses a kind the members do not agree with, and writes nothing" {
    // `decode` classifies on `id` and `method` and ignores the kind it is given,
    // so each of these encodes to a frame the wire calls something else, and
    // `decode(encode(x)) != x` held for every one before the rule.
    var buffer: [128]u8 = undefined;

    // The ordinary way to build one: a notification that carries an id. Every
    // shape rule accepts it, and the wire reads it as a request.
    var notification_with_id = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .notification,
            .id = .{ .integer = 1 },
            .method = Method.split("notifications/cancelled"),
        },
        &notification_with_id,
    ));
    try testing.expectEqual(@as(usize, 0), notification_with_id.written().len);

    // The same fault in the other direction: the members say request.
    var request_called_response = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .response,
            .id = .{ .integer = 1 },
            .method = Method.split("tools/call"),
        },
        &request_called_response,
    ));
    try testing.expectEqual(@as(usize, 0), request_called_response.written().len);

    // A method-free message with an id is a response whatever it claims.
    var response_called_notification = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .notification, .id = .{ .integer = 1 }, .result = "{}" },
        &response_called_notification,
    ));
    try testing.expectEqual(@as(usize, 0), response_called_notification.written().len);
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

test "decodeRequest refuses a notification and a response" {
    // The reason the type exists. A builder takes a `Request`, so a message
    // that is not one never reaches a builder, and each refusal names the
    // shape the message actually has: a caller handed the wrong one looks for
    // the wrong fault in its own handler.
    var scratch: [128]u8 = undefined;

    // A notification has a method and no id, and nothing answers it.
    try testing.expectError(error.MissingField, decodeRequest(
        \\{"jsonrpc":"2.0","method":"notifications/cancelled"}
    , &scratch));

    // A response has an id and no method, and it is already an answer.
    try testing.expectError(error.InvalidField, decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"result":{}}
    , &scratch));
    // An error response is a response too, so it is refused the same way.
    try testing.expectError(error.InvalidField, decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}
    , &scratch));
    // And a string id, so the refusal does not depend on the arm.
    try testing.expectError(error.InvalidField, decodeRequest(
        \\{"jsonrpc":"2.0","id":"a","result":{}}
    , &scratch));
}

test "an answer carries the id the request arrived with" {
    // Both id arms, crossed with the three states of `params`. An answer is a
    // response, so it carries the id and no method, and the method and the
    // params are what the handler read rather than what it owes back. The six
    // expectations pin each half: the params survive the projection, and the
    // id comes back in the arm it arrived in.
    const cases = [_]struct {
        source: []const u8,
        answer: []const u8,
        params: Params,
    }{
        .{
            .source = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\"}",
            .answer = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}",
            .params = .absent,
        },
        .{
            .source = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":null}",
            .answer = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}",
            .params = .null_value,
        },
        .{
            .source = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"search\"}}",
            .answer = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}",
            .params = .{ .value = "{\"name\":\"search\"}" },
        },
        .{
            .source = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"tools/call\"}",
            .answer = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"ok\":true}}",
            .params = .absent,
        },
        .{
            .source = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"tools/call\",\"params\":null}",
            .answer = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"ok\":true}}",
            .params = .null_value,
        },
        .{
            .source = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"tools/call\",\"params\":[1,2]}",
            .answer = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"ok\":true}}",
            .params = .{ .value = "[1,2]" },
        },
    };

    for (cases) |case| {
        var scratch: [256]u8 = undefined;
        const request = try decodeRequest(case.source, &scratch);
        try testing.expectEqualStrings("tools/call", request.method.text);
        try testing.expectEqualStrings("tools", request.method.category);
        try testing.expectEqualStrings("call", request.method.action);
        switch (case.params) {
            .absent => try testing.expect(request.params == .absent),
            .null_value => try testing.expect(request.params == .null_value),
            .value => |text| {
                const raw = switch (request.params) {
                    .value => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                try testing.expectEqualStrings(text, raw);
            },
        }

        var out: [256]u8 = undefined;
        var writer = json.Writer.init(&out);
        try encodeResponse(request, "{\"ok\":true}", null, &writer);
        try testing.expectEqualStrings(case.answer, writer.written());

        const answered = try decode(writer.written(), &scratch);
        try testing.expectEqual(Kind.response, answered.kind);
        // A response carries no method. One that did would be refused by
        // `decode` as a document that cannot exist, and the frame above holds
        // no method member.
        try testing.expectEqual(@as(?Method, null), answered.method);
        try testing.expectEqualStrings("{\"ok\":true}", answered.result.?);
    }
}

test "a result answer and an error answer are different documents" {
    // A peer that completes a call and a peer that refuses one send the same
    // frame around the same id. A handler that writes the error object inside
    // the result has sent a success with a refusal in it, and a client that
    // reads only the result reports the refusal as the answer. The two answers
    // are therefore pinned apart by the member each one carries and the
    // member each one does not.
    var scratch: [128]u8 = undefined;
    const request = try decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    , &scratch);
    var out: [256]u8 = undefined;

    var answered = json.Writer.init(&out);
    try encodeResponse(request, "{\"content\":[]}", null, &answered);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[]}}",
        answered.written(),
    );
    const success = try decode(answered.written(), &scratch);
    try testing.expectEqualStrings("{\"content\":[]}", success.result.?);
    try testing.expectEqual(@as(?Error, null), success.rpc_error);
    try testing.expect(std.mem.indexOf(u8, answered.written(), "\"error\"") == null);

    var refused = json.Writer.init(&out);
    try encodeResponse(request, null, .{
        .code = -32602,
        .message = "unknown tool",
        .data = "{\"name\":\"nope\"}",
    }, &refused);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602," ++
            "\"message\":\"unknown tool\",\"data\":{\"name\":\"nope\"}}}",
        refused.written(),
    );
    const failure = try decode(refused.written(), &scratch);
    // The member the success carries is absent here, not present and empty.
    // This is the assertion a builder that wrote the error inside the result
    // fails.
    try testing.expectEqual(@as(?[]const u8, null), failure.result);
    try testing.expect(std.mem.indexOf(u8, refused.written(), "\"result\"") == null);
    try testing.expectEqual(@as(i32, -32602), failure.rpc_error.?.code);
    try testing.expectEqualStrings("unknown tool", failure.rpc_error.?.message);
    try testing.expectEqualStrings("{\"name\":\"nope\"}", failure.rpc_error.?.data.?);

    // Both frames classify as a response, because that is what PROTOCOLS.md
    // section 3 calls a message with an id and no method, and `Kind` has no
    // fourth member for a failure. The difference a caller acts on is the
    // member, and the two lines above are where it is pinned.
    try testing.expectEqual(Kind.response, success.kind);
    try testing.expectEqual(Kind.response, failure.kind);
}

test "an answer with neither body, or with both, is refused and writes nothing" {
    var scratch: [128]u8 = undefined;
    const request = try decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    , &scratch);
    var out: [128]u8 = undefined;

    // Neither. A response with no body says nothing, and PROTOCOLS.md
    // section 3 calls a message this shape unencodable.
    var silent = json.Writer.init(&out);
    try testing.expectError(
        error.InvalidField,
        encodeResponse(request, null, null, &silent),
    );
    // Refused before a byte was written, so there is no half answer to discard.
    try testing.expectEqual(@as(usize, 0), silent.written().len);

    // Both. A document carrying a result and an error cannot exist, and this
    // is the shape that writes one inside the other.
    var both = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodeResponse(
        request,
        "{}",
        .{ .code = -32603, .message = "m" },
        &both,
    ));
    try testing.expectEqual(@as(usize, 0), both.written().len);
}

test "an answer too long for its buffer is BufferTooSmall and no slice escapes" {
    // The buffer builders return a slice of the caller's buffer, so a short
    // one is the only way a truncated document could reach a caller. It does
    // not: the return is the error, and there is no slice to truncate.
    var scratch: [128]u8 = undefined;
    const request = try decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    , &scratch);

    var out: [8]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, errorResponse(
        request,
        .{ .code = -32603, .message = "internal" },
        &out,
    ));
    try testing.expectError(error.BufferTooSmall, methodNotFound(request, &out));
}

test "an id is echoed in the arm it arrived in" {
    // PROTOCOLS.md section 3 admits an integer and a string, and each comes
    // back as the arm it arrived in. A string id goes through the JSON string
    // writer, so a quote in it is escaped rather than closing the frame.
    var numeric_scratch: [128]u8 = undefined;
    var string_scratch: [128]u8 = undefined;
    var out: [256]u8 = undefined;

    // A value wider than an f64 holds is not re-spelled on the way out.
    const numeric = try decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":-9007199254740993,\"method\":\"m\"}",
        &numeric_scratch,
    );
    var numeric_out = json.Writer.init(&out);
    try encodeResponse(numeric, "{}", null, &numeric_out);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":-9007199254740993,\"result\":{}}",
        numeric_out.written(),
    );

    const named = try decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"m\"}",
        &string_scratch,
    );
    // The id decodes to the text the peer sent, unescaped once.
    try testing.expectEqualStrings("a\"b", named.id.string);
    var named_out = json.Writer.init(&out);
    try encodeResponse(named, "{}", null, &named_out);
    // And the answer carries the same text escaped back.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"result\":{}}",
        named_out.written(),
    );
    const answered = try decode(named_out.written(), &string_scratch);
    try testing.expectEqualStrings("a\"b", answered.id.?.string);
}

test "errorResponse returns the whole frame in the caller's buffer" {
    var scratch: [128]u8 = undefined;
    const request = try decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}",
        &scratch,
    );
    var out: [256]u8 = undefined;
    const answer = try errorResponse(request, .{
        .code = -32021,
        .message = "needs more",
        .data = "{\"reason\":\"capabilities\"}",
    }, &out);
    // The `data` arm travels as the caller's own JSON, spliced as it stands.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021," ++
            "\"message\":\"needs more\",\"data\":{\"reason\":\"capabilities\"}}}",
        answer,
    );
}

test "methodNotFound writes the bytes the hand-written builders write" {
    // The two session layers build this frame by hand, and a cutover to this
    // one must not move a byte. Both expectations are copied from those
    // builders, one per id arm.
    var numeric_scratch: [128]u8 = undefined;
    var string_scratch: [128]u8 = undefined;
    var out: [256]u8 = undefined;

    const numeric = try decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"no/such\"}",
        &numeric_scratch,
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601," ++
            "\"message\":\"Method not found\"}}",
        try methodNotFound(numeric, &out),
    );

    const named = try decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"no/such\"}",
        &string_scratch,
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"error\":{\"code\":-32601," ++
            "\"message\":\"Method not found\"}}",
        try methodNotFound(named, &out),
    );

    // A peer that reads the refusal back finds an error object, not a result.
    const peer = try decodeRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"no/such\"}",
        &numeric_scratch,
    );
    const refusal = try decode(try methodNotFound(peer, &out), &numeric_scratch);
    try testing.expectEqual(Kind.response, refusal.kind);
    try testing.expectEqual(@as(?[]const u8, null), refusal.result);
    try testing.expectEqual(@as(i32, -32601), refusal.rpc_error.?.code);
    try testing.expectEqualStrings("Method not found", refusal.rpc_error.?.message);
}
