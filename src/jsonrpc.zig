//! JSON-RPC 2.0, the base that MCP and ACP both sit on.
//!
//! PROTOCOLS.md section 3. A2A's JSON-RPC binding is JSON-RPC 2.0 as well.
//!
//! | Element | Value |
//! | --- | --- |
//! | `jsonrpc` | `"2.0"`, always present, always this exact string |
//! | `id` | Integer or string, `i64`. Absent, or `null` on a refusal |
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
//! The three bodies it splices — `params`, `result` and an error's `data` —
//! are validated too. They reach the wire as the caller's own bytes, so a body
//! that is not one complete JSON value is refused here rather than reported by
//! the peer that reads it back.
//!
//! ## The one `null` id, and the single place it is legal
//!
//! JSON-RPC 2.0 says that where an error occurred in detecting the id — a
//! Parse error or an Invalid Request — the error response's id "MUST be
//! Null". `{"id":null,"error":{...}}` is therefore the specification's own
//! shape for a refusal that belongs to no request, and a codec that refused
//! it outright could not read the very frame it writes when a peer refuses
//! one of ours: the refusal would be the one message this library's own
//! reader throws away.
//!
//! It is accepted on a response carrying an `error`, and nowhere else. A
//! request has an id by definition, a notification has none at all, and a
//! result is an answer to an id, so a `null` beside any of them is a member
//! present with a value the protocol does not permit — `InvalidField`, not
//! the `MalformedJson` a value of the wrong JSON type is. The rule is narrow
//! on purpose: a codec that accepted `null` anywhere an id appears would
//! match an answer against nothing, which is the fault the whole id
//! mechanism exists to prevent. `validate` and `encode` apply the same rule,
//! so the shape round trips to the same bytes and is refused everywhere it is
//! not legal.
//!
//! ## What the round trip promises
//!
//! The promise is a wire-value round trip and stable encoding, not byte
//! identity with arbitrary input. Encoding normalizes member order,
//! insignificant whitespace, integer spelling and decoded string escapes.
//! Two encodes of the same valid `Message` produce the same bytes.
//!
//! `Params.value`, `result` and `rpc_error.data` carry raw JSON lexemes and are
//! spliced verbatim. Method text, string ids and error messages are decoded
//! text and are re-escaped. Unmodeled members are skipped on decode and are
//! absent from the next encoding.
//!
//! Every encoder requires its source regions to be disjoint from the writer's
//! destination, including borrowed string ids and raw bodies. This is an
//! unchecked caller precondition in every optimize mode.
const std = @import("std");
const root = @import("root.zig");
const json = @import("json.zig");

const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

/// The one version string JSON-RPC 2.0 admits.
pub const version = "2.0";

/// A JSON-RPC request id.
///
/// An id *value* is an integer or a string, never a float and never `null`.
/// MCP states the `null` ban explicitly, and a fractional id has never been
/// legal, so both are rejected here rather than coerced.
///
/// The `null` JSON-RPC 2.0 requires on the error response of a request it
/// could not identify is not an id value. It is the specification's way of
/// saying there is none, so it is modelled as a state of the `id` *member*
/// and not as a third value of this type: see [`Message.id_null`].
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,
};

/// A method name, split once on `/`.
///
/// MCP and ACP v0.3 use the category-action form. A method with no `/` is legal
/// JSON-RPC, so both halves are then empty and `text` is the whole name.
pub const Method = struct {
    /// The whole name, which is what a caller compares against a method table.
    text: []const u8,
    /// The part before the first `/`, empty when the name carries none.
    category: []const u8,
    /// The part after the first `/`, empty when the name carries none.
    ///
    /// Only the first `/` splits, so a name like `a/b/c` keeps `b/c` here as
    /// one action rather than splitting three ways.
    action: []const u8,

    /// Split `text` once on `/`.
    ///
    /// Every field borrows `text` and nothing is copied, so the three outlive
    /// it together and it has to stay alive for as long as they are read. A
    /// name with no `/` is legal JSON-RPC, so `category` and `action` are both
    /// empty and `text` is the whole name; a caller reading an empty category
    /// is reading a name this revision does not use, not a truncation.
    ///
    /// No escaping happens here. `text` is what the caller holds, which for a
    /// method read off the wire is the decoded string, and splitting a name
    /// that had to be unescaped is a step the decoder already took.
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
    /// The member was an object or an array, held as the bytes it arrived as.
    ///
    /// The lexeme borrows the decode input and costs no scratch however deeply
    /// it nests, because a body is read as an extent rather than modelled.
    /// `encode` splices these bytes back verbatim, so they are the only
    /// representation of the body this library keeps.
    value: []const u8,
};

/// A JSON-RPC error object.
///
/// `data` is arbitrary JSON with no shape the base layer can assume, so it is
/// carried as borrowed text. A protocol that gives `data` a structure decodes it
/// from that text.
pub const Error = struct {
    /// The peer's own integer, from the JSON number lexeme.
    code: i32,
    /// The peer's own text. Borrows the decode input, or the scratch buffer
    /// when the string carried an escape.
    message: []const u8,
    /// The `data` member as its bytes, or null when the member was absent.
    ///
    /// Borrowed from the decode input and never modelled: a member of the data
    /// object this library cannot name would not survive a round trip through
    /// a shape, which is the whole reason the lexeme is kept.
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
/// Every slice borrows one of the two buffers `decode` was given, and a `Message`
/// owns nothing: it is live for as long as those buffers are, and writing
/// through either of them invalidates the members that read it. Which buffer a
/// member came from is named on the member, and `decode` states the rule for
/// all of them in one place.
///
/// Slices that had to be unescaped took separate regions of that scratch, so
/// `method`, a string `id` and `rpc_error.message` can be held at once and none
/// is clobbered by the members decoded after it.
pub const Message = struct {
    /// What this message is. `encode` refuses a kind that disagrees with `id`
    /// and `method`, because `decode` derives the classification from them.
    kind: Kind,
    /// The id, when the member carried a value this library models. Null on a
    /// notification, and null on a refusal whose id could not be determined;
    /// those two are told apart by `id_null` and by `kind`.
    id: ?Id = null,
    /// The `id` member was present and was the JSON value `null`.
    ///
    /// Set only where JSON-RPC 2.0 names it: on a response carrying an
    /// `error`, because that is the answer to a request the peer could not
    /// identify. `decode` refuses it on anything carrying a `method` and on
    /// anything carrying a `result`, and `validate` refuses the same, so a
    /// message this library encodes is a message it reads back.
    ///
    /// It is a flag beside `id` rather than a third state of it, because the
    /// two answer different questions. `id` is the value a caller matches an
    /// answer by, and it is switched over exhaustively in every caller in the
    /// tree; `null` is not a value to match anything against, it is the
    /// specification's statement that there is no id at all. Widening `Id`
    /// would have put that statement into every one of those switches, and
    /// each of them would then need an arm for a case none of them can be in.
    id_null: bool = false,
    /// The method, or null on a response, which carries none.
    ///
    /// `Method.text` borrows the decode input, or the scratch buffer when the
    /// name carried an escape, and `category` and `action` are slices of it
    /// whichever buffer that was.
    method: ?Method = null,
    /// The `params` member in the state the peer sent it.
    ///
    /// `Params.value` borrows the decode input, since a body is read as an
    /// extent and decoded into nothing.
    params: Params = .absent,
    /// The `result` member, as borrowed JSON text, on a successful response.
    ///
    /// The peer's own lexeme, so it borrows the decode input and spends no
    /// scratch however deeply the value nests. `encode` splices it back as it
    /// stands rather than rebuilding a value this codec never parsed.
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

    /// The standard code `code` names, or null for a code outside table 3.1.
    ///
    /// Null is an ordinary answer, not a fault: JSON-RPC 2.0 reserves the
    /// implementation-defined ranges for the peer, and a code read out of one
    /// of them says nothing about this set. Every arm is a plain comparison,
    /// so the call neither allocates nor depends on the code being one this
    /// library ever wrote.
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
///
/// Which buffer each returned slice comes from: `result`, an error's `data` and
/// a `params` body borrow `input`, while `method`, a string `id` and an error
/// `message` borrow `input` when they carry no escape and `scratch` when they
/// do. Both buffers have to stay alive and unmodified for as long as any of
/// them is read, and they must not overlap.
///
/// On error nothing is returned and nothing survives: the tag is the whole
/// answer, and a caller that needs to know which member was wrong reads the
/// input itself. Nothing here blocks and nothing here can report
/// `error.Canceled`; the transport is what can be cancelled, and it reports
/// that itself.
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
        // A member this decoder has already taken is not taken again. RFC 8259
        // section 4 says the names within an object *should* be unique, so a
        // repeat is a document the grammar permits and a decoder still has to
        // pick one. The first occurrence wins.
        //
        // `json.memberText` resolves a repeat the same way, and its doc is the
        // argument: the caller compares what it reads against a value it
        // already holds, and the first is enough to make that comparison fail
        // closed, because a later member cannot make a comparison that has
        // already failed pass. One rule, one reason, two files.
        //
        // The case that decides it is a peer this library does not terminate.
        // A peer that sends `{"method":"safe","method":"other"}` must not have
        // `other` applied here while an intermediary that stopped at the first
        // saw `safe`: the two hold different answers to what the message said,
        // and the one that stopped at the first is the one that gets asked why.
        // A decoder and a gateway reading different members of one name is the
        // ambiguity `http.zig` refuses outright for a repeated header.
        //
        // The discarded copy is read as a value rather than stepped over
        // blindly. A document that does not parse anywhere does not parse, and
        // a peer must not be able to hide a syntax error in the second slot of
        // a name the first slot already used.
        const repeated = (saw_version and std.mem.eql(u8, key, "jsonrpc")) or
            (saw_id and std.mem.eql(u8, key, "id")) or
            (saw_method and std.mem.eql(u8, key, "method")) or
            (message.params != .absent and std.mem.eql(u8, key, "params")) or
            (saw_result and std.mem.eql(u8, key, "result")) or
            (saw_error and std.mem.eql(u8, key, "error"));

        if (repeated) {
            try reader.skipValue(scratch);
        } else if (std.mem.eql(u8, key, "jsonrpc")) {
            const text = try reader.string(scratch);
            if (!std.mem.eql(u8, text, version)) return error.UnsupportedVersion;
            saw_version = true;
        } else if (std.mem.eql(u8, key, "id")) {
            message.id = try decodeId(&reader, scratch);
            // The member was read and carried no value, which is the
            // specification's `null` and not an absent member. `saw_id`
            // cannot tell the two apart — both leave `id` unset — so the
            // state of the member is kept beside it, and the rules below
            // decide whether this message is one the specification allows it
            // on.
            message.id_null = message.id == null;
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

    // `null` is the id of an error response whose id could not be determined
    // from the Request, and it is legal nowhere else. Each of the three cases
    // has already been decided by the lines above: a message carrying a
    // `method` is a request whatever else it holds, one carrying a `result`
    // is an answer to an id, and one carrying neither was refused as
    // `MissingField` before this line. So the only question left is whether
    // this is a refusal, which is the one shape the specification gives it.
    if (message.id_null) {
        if (saw_method) return error.InvalidField;
        if (saw_result) return error.InvalidField;
        if (!saw_error) return error.InvalidField;
    }

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

fn decodeId(reader: *json.Reader, scratch: []u8) DecodeError!?Id {
    reader.skipWhitespace();
    const byte = reader.peek() orelse return error.Truncated;
    switch (byte) {
        '"' => return .{ .string = try reader.string(scratch) },
        '0'...'9', '-' => {
            const lexeme = try reader.number();
            return .{
                .integer = std.fmt.parseInt(i64, lexeme, 10) catch |err| switch (err) {
                    error.Overflow => return error.LimitExceeded,
                    // `parseInt` rejects a fractional or exponent lexeme, which
                    // is a value of the wrong JSON type rather than an
                    // overflow, so it is named as one rather than silently
                    // truncating the id.
                    error.InvalidCharacter => return error.MalformedJson,
                },
            };
        },
        // A `null` is not an id value, so there is no `Id` to return. The
        // member is present and it said `null`, which the specification uses
        // for a response whose id could not be determined, and whether this
        // message is one of those is the caller's question to answer: this
        // function reads members, and refusing it here would refuse the
        // refusal this library writes.
        'n' => {
            try reader.nullLiteral();
            return null;
        },
        // Everything else is a value of the wrong JSON type for an id, and
        // PROTOCOLS.md section 2.1 gives `MalformedJson` as "a JSON syntax
        // error, or a value of the wrong JSON type". The member is present
        // either way, so none of these is an absent id to be read as a
        // notification: no answer could ever be matched to it.
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
    var saw_data = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        // First-wins, as every member walk in this library applies it and for
        // the reason `decode` gives: a later member must not be able to make a
        // comparison that has already failed pass. A duplicate is stepped over
        // rather than read, so a second `code` cannot supply the integer the
        // first one was refused for, a second `message` cannot replace the text
        // a caller will show, and a second `data` cannot redirect a peer that
        // read the first. A member this walk has not taken is a member it never
        // will, so the flags are what the value is keyed on rather than the
        // fields.
        if (std.mem.eql(u8, key, "code")) {
            if (saw_code) {
                try reader.skipValue(scratch);
                continue;
            }
            const lexeme = try reader.number();
            // A code outside `i32` is the same fault as an id outside `i64`.
            // PROTOCOLS.md section 2.1 names `LimitExceeded` a numeric bound
            // the protocol states, which is exactly what an overflow is.
            result.code = std.fmt.parseInt(i32, lexeme, 10) catch |err| switch (err) {
                error.Overflow => return error.LimitExceeded,
                // `parseInt` rejects a fractional or exponent lexeme. That is a
                // value of the wrong JSON type rather than an overflow, and
                // `decodeId` names the same fault on an id the same way.
                error.InvalidCharacter => return error.MalformedJson,
            };
            saw_code = true;
        } else if (std.mem.eql(u8, key, "message")) {
            if (saw_message) {
                try reader.skipValue(scratch);
                continue;
            }
            result.message = try reader.string(scratch);
            saw_message = true;
        } else if (std.mem.eql(u8, key, "data")) {
            if (saw_data) {
                try reader.skipValue(scratch);
                continue;
            }
            result.data = try reader.rawValue(scratch);
            saw_data = true;
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
/// produced a half message to discard. What is validated is everything this
/// library's own decoder would reject: the shape rules of PROTOCOLS.md
/// section 3, that each spliced body is one complete JSON value the decoder
/// reads back as the same value, and that the three text members it writes
/// through `json.Writer.string` are valid UTF-8.
///
/// `BufferTooSmall` is no exception to the untouched rule: a failure rewinds
/// the writer's length to the value it arrived with, which is the state a
/// retry starts from. The bytes behind that length are not restored, so the
/// guarantee is about the message the caller has written and not about memory
/// past it. Widening the buffer is the caller's to do.
///
/// All message source regions must be disjoint from `writer.buffer`; this
/// caller precondition is unchecked in every optimize mode.
pub fn encode(message: Message, writer: *json.Writer) EncodeError!void {
    const mark = writer.len;
    errdefer writer.len = mark;

    try validate(message);

    try writer.byte('{');

    try writer.slice("\"jsonrpc\":");
    try writer.string(version);

    // A notification has no id, and that absence is what makes it one, so the
    // member is omitted rather than required. `validate` has already refused a
    // response without one, which is a different thing entirely.
    //
    // The `null` id is written where the specification names it and in the
    // spelling it names it in, so a decode of these bytes carries `id_null`
    // and an encode of that message writes the same bytes back.
    if (message.id) |id| {
        try writer.slice(",\"id\":");
        try writeId(id, writer);
    } else if (message.id_null) {
        try writer.slice(",\"id\":null");
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
/// The bodies are the one part of a frame this function has to read rather than
/// compare, so they are read last and the shape rules above stay the cheap
/// ones. The cost is one walk of the body's own bytes per spliced member, no
/// allocation, and it is paid once: this runs before the first byte, so a body
/// refused here leaves the writer untouched rather than half framed.
///
/// The rules here mirror `decode` exactly. If one of them is relaxed there, it
/// has to be relaxed here too, or a message this library reads comes back as a
/// different one after a decode and an encode.
///
/// Nothing is written until every check above has passed, so every failure
/// leaves the caller's writer at the length it arrived with and a retry after
/// widening the buffer starts from the same prefix rather than from a half
/// frame. The three text members are checked for the same reason the bodies
/// are: `json.Writer.string` does not validate them, so this is the only place
/// a message carrying a byte its own decoder refuses can still be named
/// against the caller who built it.
fn validate(message: Message) EncodeError!void {
    const has_method = message.method != null;
    if (message.result != null and message.rpc_error != null) return error.InvalidField;
    if (has_method and (message.result != null or message.rpc_error != null)) {
        return error.InvalidField;
    }
    // `id` and `id_null` are one member read two ways, so a message holding
    // both is a caller's own mistake rather than a shape any peer can send.
    if (message.id != null and message.id_null) return error.InvalidField;
    // A `null` id is legal on a refusal and nowhere else, which is the same
    // narrow rule `decode` applies: a request has an id, a notification has
    // none, and a result is an answer to one.
    if (message.id_null) {
        if (has_method) return error.InvalidField;
        if (message.result != null) return error.InvalidField;
        if (message.rpc_error == null) return error.InvalidField;
    }
    // Without a method the message is a response, and a response the peer
    // cannot match to a request is not one.
    if (!has_method and message.id == null and !message.id_null) return error.InvalidField;
    // A response with neither a result nor an error says nothing, which
    // PROTOCOLS.md section 3 calls a decode error. Writing one would put bytes
    // on the wire that this library refuses to read back.
    if (!has_method and message.result == null and message.rpc_error == null) {
        return error.InvalidField;
    }
    // `decode` derives the kind from the members and never reads a kind the
    // caller set, so a message whose kind disagrees comes back classified as
    // something else, and reading the frame `encode` wrote does not give the
    // message back. A notification carrying an `id` is the ordinary way to build
    // one: it satisfies every rule above and encodes to a frame the wire calls
    // a request.
    const derived: Kind = if (has_method)
        (if (message.id != null) .request else .notification)
    else
        .response;
    if (message.kind != derived) return error.InvalidField;

    // The three members written through `json.Writer.string`, whose UTF-8
    // precondition is the caller's and is not checked there. A stray byte
    // escapes nothing and reaches the wire inside a literal that is well formed
    // JSON and not valid text, which this module's own `decode` then refuses
    // with `error.InvalidUtf8`. The encoder refuses the same bytes here, where
    // the caller can still be told which of its values was wrong. Every string
    // arriving from a decode is already validated, so this is paid once per
    // message a caller built rather than once per frame a peer sent.
    if (message.method) |method| try requireText(method.text);
    if (message.id) |id| try requireIdText(id);
    if (message.rpc_error) |object| try requireText(object.message);
    // `params`, `result` and an error's `data` are spliced as the caller's own
    // bytes, so they are the members a shape rule cannot vouch for. Each is
    // what `decode` would read back verbatim, so each has to be what it reads.
    switch (message.params) {
        .absent, .null_value => {},
        .value => |text| try requireParamsBody(text),
    }
    if (message.result) |text| try requireJsonBody(text, 1);
    if (message.rpc_error) |object| {
        if (object.data) |data| try requireJsonBody(data, 2);
    }
}

/// Refuse text that would reach the wire as a literal this module's decoder
/// refuses.
///
/// `json.Writer.string` escapes every byte the JSON grammar forbids and passes
/// every other byte through, and it deliberately does not check that what it
/// is given is text. That is the right place for the escape and the wrong place
/// for the validation: a protocol frame carries text in a handful of named
/// members and a whole document's worth of values, so a caller here can say
/// which member was wrong. `decode` names the same fault on the far side
/// `error.InvalidUtf8`, and this names it here `error.InvalidField`.
///
/// It costs one pass over the string and no allocation, and it runs before the
/// first byte is written, so a refused message leaves the writer untouched.
fn requireText(text: []const u8) EncodeError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidField;
}

/// Require valid UTF-8 of the string arm of an id, and nothing of the integer
/// arm, which is formatted from a value that cannot carry one.
fn requireIdText(id: Id) EncodeError!void {
    switch (id) {
        .integer => {},
        .string => |text| try requireText(text),
    }
}

/// Refuse a body that is not one complete JSON value.
///
/// A body is the caller's own bytes, spliced into the frame as they stand, so
/// whatever is wrong with them reaches the peer. The encoding contract asks for
/// every value `encode` accepts to read back as the same value, and a body is
/// the one member no shape rule can vouch for: `params` holding `"not json"`
/// writes a frame this library refuses to read back. The fault is the caller's,
/// so it is `InvalidField`, which is what `root.zig` gives a value that could
/// not have been decoded.
///
/// The walk is `json.Reader`'s, so the refusals here are the refusals there: a
/// syntax error, a bad escape, a byte that is not UTF-8, a value nested past
/// `json.max_depth`, and anything left behind the value. Each is the same
/// fault here and each is `InvalidField`. `depth` charges the containers around
/// the field: one for `params` or `result`, two for `error.data`. A body accepted
/// at the bound is therefore one `decode` accepts at that same position.
///
/// This is not the framing check. The framer refuses a newline inside a frame
/// on the way to the wire and `framing.zig` is where that rule lives, so a
/// body that parses and spans lines is a framing fault this walk has nothing
/// to say about. Two faults, two places, and neither check duplicated.
///
fn requireJsonBody(text: []const u8, depth: u32) EncodeError!void {
    var reader = json.Reader.init(text);
    reader.depth = depth;
    // A value that is stepped over writes nothing, so it needs no scratch.
    const none: [0]u8 = .{};
    _ = reader.rawValue(&none) catch return error.InvalidField;
    // `rawValue` stops at the end of the first value. Text behind it would land
    // behind one colon as a second member.
    if (!reader.atEnd()) return error.InvalidField;
}

/// Refuse a `params` body that `decodeParams` would refuse.
///
/// `Params.value` is an object or an array, and a scalar is a valid JSON value
/// that is still not a params. The walk above has already proved the text is one
/// complete value, so the leading byte is all that is left to ask about, and
/// the trim takes the four bytes JSON calls whitespace, which is what the
/// reader skipped to find it.
fn requireParamsBody(text: []const u8) EncodeError!void {
    try requireJsonBody(text, 1);
    const body = std.mem.trimStart(u8, text, " \t\r\n");
    if (body.len == 0) return error.InvalidField;
    if (body[0] != '{' and body[0] != '[') return error.InvalidField;
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
///
/// `data` is spliced, so this function does not check it: both callers do, and
/// each before either opens its frame. A caller added later has to as well. The
/// check belongs before the first byte rather than in here, because a refusal
/// halfway through the object would leave a frame behind.
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
/// writer untouched, and so does a short one: a failure rewinds the writer's
/// length to the value it arrived with, which is the state a retry starts
/// from. `error.BufferTooSmall` is the caller's own buffer fault rather than a
/// wire condition.
///
/// A body is spliced verbatim, the way `Conn.call` splices caller params. A
/// raw newline inside one is caught by the framer on the way to the wire, as
/// `Conn` reports it, and is not checked a second time here: the check belongs
/// in one place and this is not it.
///
/// What is checked here is the other fault and not the framing one: a body that
/// is not one complete JSON value, which the rule above cannot see and which
/// `decode` would refuse. `encode` makes the same check in `validate`, before
/// its first byte; this one runs before the opening brace, so either way a
/// refused answer leaves the writer untouched.
///
/// The text this writes is checked too: an id string and an error `message`
/// that are not valid UTF-8 are `error.InvalidField`, for the reason `validate`
/// gives. `error.BufferTooSmall` is a short buffer and nothing else, so a
/// caller retrying with a larger one starts from the length it had.
///
/// The id is echoed in the arm it arrived in, so an integer id stays an integer
/// and a string id stays a string. A response carries no `method`, and no
/// `params` member is written: PROTOCOLS.md section 3 permits one on a
/// response, and a caller that needs it goes through `encode`.
///
/// String-id, result and error source regions must be disjoint from
/// `writer.buffer`. This is unchecked in every optimize mode.
pub fn encodeResponse(
    request: Request,
    result: ?[]const u8,
    object: ?Error,
    writer: *json.Writer,
) EncodeError!void {
    const mark = writer.len;
    errdefer writer.len = mark;

    if (result == null and object == null) return error.InvalidField;
    if (result != null and object != null) return error.InvalidField;
    // The rule above says which body, not what is in it. Both are spliced, so
    // both are read here, before the frame opens.
    // The two text members this writes through `json.Writer.string`, for the
    // reason `validate` gives. An id echoed from a decode is already valid, and
    // one a caller built by hand is the caller's to keep valid; either way the
    // frame this produces has to be one `decode` accepts.
    try requireIdText(request.id);
    if (object) |value| try requireText(value.message);
    if (result) |text| try requireJsonBody(text, 1);
    if (object) |value| {
        if (value.data) |data| try requireJsonBody(data, 2);
    }

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
///
/// `InvalidField` rejects a non-UTF-8 string id or error message, or invalid
/// raw error data, before writing. `BufferTooSmall` can leave dirty partial
/// bytes in `out`, which the caller discards. Id, message and data source
/// regions must be disjoint from `out`, unchecked in every optimize mode.
pub fn errorResponse(request: Request, object: Error, out: []u8) EncodeError![]const u8 {
    var writer = json.Writer.init(out);
    try encodeResponse(request, null, object, &writer);
    return writer.written();
}

/// The `-32601` answer for a method this peer does not have, in `out`.
///
/// The code is `StandardError.method_not_found` and the message is the name
/// table 3.1 of PROTOCOLS.md gives that code, so neither value is chosen here.
/// The envelope is `encodeResponse`'s, and the id comes back in the arm it
/// arrived in, so an integer id is echoed as an integer and a string id as a
/// string.
///
/// `conn.methodNotFound` hands the same writer the same two values, so that
/// answer and this one are byte-identical without either being a copy of the
/// other. `mcp_session.Server.methodNotFound` forwards to it rather than
/// writing a second. `acp_session` builds no `-32601` frame at all: a method
/// its version does not carry is reported to the caller as
/// `MethodNotInVersion`, before the wire.
///
/// `runtime_demo` writes the method's name as the message and
/// `bridge_session` puts it in a `data` member, both on this code, so a peer
/// can tell which method was refused.
///
/// `InvalidField` rejects a non-UTF-8 string id before writing.
/// `BufferTooSmall` can leave dirty partial bytes in `out`; discard them.
/// A string id must be disjoint from `out`, unchecked in every optimize mode.
pub fn methodNotFound(request: Request, out: []u8) EncodeError![]const u8 {
    return errorResponse(request, .{
        .code = @backingInt(StandardError.method_not_found),
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
    // A request has an id by definition, so a `null` beside one is a member
    // present with a value the protocol does not permit. `InvalidField` rather
    // than the `MalformedJson` a value of the wrong JSON type is, because
    // `null` is a value of the right JSON type that this position does not
    // admit: PROTOCOLS.md section 2.1 draws exactly that line.
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":null,"method":"m"}
    , &scratch));
    // The other half, unchanged: a fraction has never been an id, and the peer
    // that sends one gets the name of the fault it made.
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1.5,"method":"m"}
    , &scratch));
}

test "a null id is legal on a refusal and nowhere else" {
    // The one place the specification names it. A peer that refused a frame and
    // could not say which request it belonged to sends this, and a codec that
    // refused it would drop the loudest refusal it is able to write.
    var scratch: [128]u8 = undefined;
    const refusal = try decode(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
    , &scratch);
    try testing.expectEqual(Kind.response, refusal.kind);
    try testing.expect(refusal.id_null);
    try testing.expectEqual(@as(?Id, null), refusal.id);
    try testing.expectEqual(@as(i32, -32600), refusal.rpc_error.?.code);

    // A request, which has an id. A `null` beside a `method` cannot be read as
    // a notification either: the member is present, so the message is a request
    // whose id no answer could ever be matched to.
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":null,"method":"m","params":{}}
    , &scratch));
    // A result, which is an answer to an id and answers nothing here.
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":null,"result":{}}
    , &scratch));
    // A message that is neither: there is no shape here to put the id on, so
    // the member is the second fault rather than the first.
    try testing.expectError(error.MissingField, decode(
        \\{"jsonrpc":"2.0","id":null}
    , &scratch));
    // And a result beside the error, which the mutual exclusion refuses before
    // the narrow rule is reached. It is here because widening the rule to "any
    // response" is exactly the fault it exists to prevent, and this document
    // is what that widening would have let through.
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":null,"result":{},"error":{"code":1,"message":"m"}}
    , &scratch));
}

test "a null id is written back as the refusal frame it arrived as" {
    // The one frame whose every member is fixed, so it is the one that has to
    // come back as itself: it is what `acp_session.refusalBody` writes for a
    // batch frame this session must not accept, and a peer has to receive the
    // refusal this library would have written. `id_null` is what puts the `id`
    // back, and an id written as absent decodes as `MissingField` — a peer
    // told the refusal was a notification learns nothing from it.
    const source = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600," ++
        "\"message\":\"Invalid Request\"}}";
    var scratch: [128]u8 = undefined;
    const decoded = try decode(source, &scratch);

    var out: [128]u8 = undefined;
    var writer = json.Writer.init(&out);
    try encode(decoded, &writer);
    // Member for member and spelling for spelling, for the reason above.
    try testing.expectEqualStrings(source, writer.written());

    // The other direction. The value decoded from the re-encoded frame is the
    // value decoded from the original, which is the round trip the module doc
    // states at the value level.
    var other: [128]u8 = undefined;
    const again = try decode(writer.written(), &other);
    try testing.expectEqual(decoded.kind, again.kind);
    try testing.expectEqual(decoded.id, again.id);
    try testing.expectEqual(decoded.id_null, again.id_null);
    try testing.expectEqual(decoded.rpc_error.?.code, again.rpc_error.?.code);
    try testing.expectEqualStrings(decoded.rpc_error.?.message, again.rpc_error.?.message);
    try testing.expectEqual(@as(?[]const u8, null), again.result);
}

test "encode refuses a null id anywhere but on a refusal" {
    var buffer: [128]u8 = undefined;
    // The same narrow rule `decode` applies, or a caller could write a frame
    // this library refuses to read back.
    var request = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(.{
        .kind = .request,
        .id_null = true,
        .method = Method.split("m"),
    }, &request));

    var answered = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(.{
        .kind = .response,
        .id_null = true,
        .result = "{}",
    }, &answered));

    // A message claiming both is one member read two ways, and no peer can
    // send it.
    var both = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(.{
        .kind = .response,
        .id = .{ .integer = 1 },
        .id_null = true,
        .rpc_error = .{ .code = -32600, .message = "Invalid Request" },
    }, &both));

    // Refused before a byte, so each writer is still where a retry starts.
    try testing.expectEqual(@as(usize, 0), request.written().len);
    try testing.expectEqual(@as(usize, 0), answered.written().len);
    try testing.expectEqual(@as(usize, 0), both.written().len);
}

test "a value of the wrong JSON type is MalformedJson wherever it appears" {
    // PROTOCOLS.md section 2.1 gives `MalformedJson` as "a JSON syntax error, or
    // a value of the wrong JSON type", and `InvalidField` as a field present
    // with a value the protocol does not permit. A member carrying the wrong
    // type is the first of those, and the id and the code are the two members
    // that used to say the second. One fault has one name, so a caller learns
    // it from any member rather than from the one that happens to be modelled.
    var scratch: [64]u8 = undefined;
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":true,"method":"m"}
    , &scratch));
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":{"a":1},"method":"m"}
    , &scratch));
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"method":7}
    , &scratch));
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","params":7}
    , &scratch));
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","params":"a"}
    , &scratch));
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":"-32601","message":"m"}}
    , &scratch));

    // The other member of the pair still means what it says: a field the
    // protocol does not permit beside the others, which is a document the
    // grammar admits and the specification does not.
    try testing.expectError(error.InvalidField, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","result":{}}
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
    // The other arm, which the two paths also share: a fraction is a value of
    // the wrong JSON type rather than an overflow, so it is `MalformedJson` as
    // every other wrong-typed member is.
    try testing.expectError(error.MalformedJson, decode(
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

test "a repeated error member resolves first-wins, the rule every other walk applies" {
    var scratch: [128]u8 = undefined;

    // `decode` resolves a repeated top-level member first-wins and gives the
    // reason: a later member must not be able to make a comparison that has
    // already failed pass. The error object was the one walk in this module
    // that did not, so it took the last `code`, the last `message` and the last
    // `data` — a peer could name one failure in the first slot and a different
    // one beside it, and an intermediary reading this message with a different
    // decoder would answer with the other failure.
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32021,"message":"first","data":{"a":1},"code":-32601,"message":"second","data":{"b":2}}}
    , &scratch);
    const object = decoded.rpc_error.?;
    try testing.expectEqual(@as(i32, -32021), object.code);
    try testing.expectEqualStrings("first", object.message);
    try testing.expectEqualStrings("{\"a\":1}", object.data.?);

    // A `data` whose first occurrence is the literal `null` is that member, and
    // an object beside it does not replace it: "the peer sent no data" and "the
    // peer sent some data" are two facts, and the first slot is the one this
    // library reads.
    const nulled = try decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"m","data":null,"data":{"b":2}}}
    , &scratch);
    try testing.expectEqualStrings("null", nulled.rpc_error.?.data.?);

    // The first occurrence is the one that is read as a value, so a first `code`
    // that is not an integer is refused and a valid one beside it does not
    // rescue it. Overwriting would have made the second slot the answer and
    // reported a healthy message for a broken one.
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":"-32021","message":"m","code":-32601}}
    , &scratch));
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":7,"message":"m"}}
    , &scratch));
    try testing.expectError(error.LimitExceeded, decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":99999999999,"message":"m","code":-32601}}
    , &scratch));
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

test "a short buffer leaves the writer where a retry can start" {
    // `json.Writer`'s doc tells a caller to size a buffer, retry on failure and
    // grow it. That is only true of a writer that is back where it started:
    // without the rewind the frame written up to the byte that did not fit is
    // the prefix of the next one, and the retry writes a document no peer sent.
    var small: [8]u8 = undefined;
    var buffer: [256]u8 = undefined;
    const message: Message = .{
        .kind = .request,
        .id = .{ .integer = 1 },
        .method = Method.split("tools/call"),
    };

    var writer = json.Writer.init(&small);
    try testing.expectError(error.BufferTooSmall, encode(message, &writer));
    // The length the caller handed in, so none of the half frame can be read
    // as the start of the next one.
    try testing.expectEqual(@as(usize, 0), writer.written().len);

    // The buffer is the only state a caller has to restore; the length is
    // already back where the call started.
    writer.buffer = &buffer;
    try encode(message, &writer);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}",
        writer.written(),
    );
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
    // reading that frame back does not give the message back. That held for
    // every one before the rule.
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
    // A notification is accepted input, so refusing to encode it made a whole
    // class of valid messages unwritable.
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

test "a spliced body that is not one JSON value is refused, and writes nothing" {
    // The three bodies `encode` writes as the caller's own bytes. Each of them
    // framed a document this library refuses to read back before the rule, so
    // the peer was the first thing to find out what the caller had built. A
    // body is the one member `encode` cannot compare and still has to vouch
    // for, because the frame is supposed to read back as the same message.
    var scratch: [256]u8 = undefined;
    var buffer: [256]u8 = undefined;

    // `params`, spelled the way a caller spells it: text from somewhere that is
    // not JSON at all.
    var params = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .request,
            .id = .{ .integer = 1 },
            .method = Method.split("m"),
            .params = .{ .value = "not json at all" },
        },
        &params,
    ));
    try testing.expectEqual(@as(usize, 0), params.written().len);
    // The frame that used to reach the wire, and what the peer made of it.
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","params":not json at all}
    , &scratch));

    // `result`, truncated after its first member.
    var result = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .response, .id = .{ .integer = 1 }, .result = "{\"ok\":true" },
        &result,
    ));
    try testing.expectEqual(@as(usize, 0), result.written().len);

    // An error's `data`, which is a body like any other.
    var data = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .response,
            .id = .{ .integer = 1 },
            .rpc_error = .{ .code = -32603, .message = "m", .data = "{\"why\":" },
        },
        &data,
    ));
    try testing.expectEqual(@as(usize, 0), data.written().len);

    // A `params` that is one value of a type `decodeParams` does not admit. A
    // scalar is a valid JSON value and still not a params.
    var scalar = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .request,
            .id = .{ .integer = 1 },
            .method = Method.split("m"),
            .params = .{ .value = "7" },
        },
        &scalar,
    ));
    try testing.expectEqual(@as(usize, 0), scalar.written().len);

    // Two values behind one colon is one too many, and `rawValue` stops at the
    // end of the first.
    var trailing = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .response, .id = .{ .integer = 1 }, .result = "{} {}" },
        &trailing,
    ));
    try testing.expectEqual(@as(usize, 0), trailing.written().len);
}

test "a text member that is not valid UTF-8 is refused, and writes nothing" {
    var buffer: [256]u8 = undefined;
    var writer = json.Writer.init(&buffer);

    // `json.Writer.string` escapes what the JSON grammar forbids and passes
    // every other byte through, and whether the string it is handed is text is
    // the caller's obligation there. A message carrying a stray byte therefore
    // framed a document that is well formed JSON and not valid text, which
    // this module's own `decode` refuses with `InvalidUtf8`: the peer was the
    // first thing to find out what the caller had built, and the caller was
    // told nothing at all.
    //
    // Every member written through that writer is named, because a rule
    // covering only the method would leave the other two open.
    const stray = "to\xffp";

    var method = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .request, .id = .{ .integer = 1 }, .method = Method.split(stray) },
        &method,
    ));
    try testing.expectEqual(@as(usize, 0), method.written().len);

    var id = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .request,
            .id = .{ .string = stray },
            .method = Method.split("tools/call"),
        },
        &id,
    ));
    try testing.expectEqual(@as(usize, 0), id.written().len);

    var message = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encode(
        .{
            .kind = .response,
            .id = .{ .integer = 1 },
            .rpc_error = .{ .code = -1, .message = stray },
        },
        &message,
    ));
    try testing.expectEqual(@as(usize, 0), message.written().len);

    // The same rule on the answer builder, which writes its own two text
    // members rather than going through `validate`.
    var scratch: [64]u8 = undefined;
    const request = try decodeRequest(
        \\{"jsonrpc":"2.0","id":"caller","method":"tools/call"}
    , &scratch);
    var answer = json.Writer.init(&buffer);
    try testing.expectError(error.InvalidField, encodeResponse(
        request,
        null,
        .{ .code = -1, .message = stray },
        &answer,
    ));
    try testing.expectEqual(@as(usize, 0), answer.written().len);

    // A refusal leaves what the caller had already committed in place, which is
    // the state its retry starts from. `Conn.call` frames into the same
    // buffer across more than one encode, so a writer that gave the committed
    // prefix back on this path would have to be rewound by hand at every call
    // site that checks its own values first.
    try writer.slice("{\"already\":\"committed\"");
    const committed = writer.len;
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .request, .id = .{ .integer = 1 }, .method = Method.split(stray) },
        &writer,
    ));
    try testing.expectEqual(committed, writer.len);
    try testing.expectEqualStrings("{\"already\":\"committed\"", writer.written());

    // And the same writer then completes a frame, so the refusal left it
    // usable rather than only unchanged.
    try writer.slice("}");
    try testing.expectEqualStrings("{\"already\":\"committed\"}", writer.written());
}

test "an unknown top-level member is skipped, not a decode error" {
    var scratch: [128]u8 = undefined;
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","extensionField":{"a":[1,2]}}
    , &scratch);
    try testing.expectEqual(Kind.request, decoded.kind);
}

test "a repeated member is resolved first-wins, the rule json.memberText applies" {
    var scratch: [128]u8 = undefined;

    // The case the rule exists for: a peer that sends two methods must not have
    // the second one applied here while an intermediary that stopped at the
    // first saw the safe one.
    const decoded = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"safe","method":"other"}
    , &scratch);
    try testing.expectEqualStrings("safe", decoded.method.?.text);

    // The same through `decodeRequest`, which is the entry point a dispatcher
    // reads and therefore the answer that gets acted on.
    const request = try decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"safe","method":"other"}
    , &scratch);
    try testing.expectEqualStrings("safe", request.method.text);

    // Every modelled member resolves the same way, `params` included: its three
    // states are why it is asked of the message and not of a flag.
    const body = try decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":1},"params":{"b":2}}
    , &scratch);
    try testing.expectEqualStrings("{\"a\":1}", body.params.value);

    // A repeated version fails closed. The first is the one an intermediary
    // that read only the version member saw, so a peer cannot write a frame
    // that reads as 2.0 here and as something else there.
    try testing.expectError(error.UnsupportedVersion, decode(
        \\{"jsonrpc":"1.0","jsonrpc":"2.0","id":1,"method":"m"}
    , &scratch));

    // The discarded copy is read as a value rather than stepped over, so a
    // syntax error hidden in the second slot is still a syntax error.
    try testing.expectError(error.MalformedJson, decode(
        \\{"jsonrpc":"2.0","id":1,"method":"m","method":[}
    , &scratch));
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

test "an answer whose body is not JSON is refused, and writes nothing" {
    var scratch: [128]u8 = undefined;
    const request = try decodeRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call"}
    , &scratch);
    var out: [256]u8 = undefined;

    // The result arm, which is where `Conn.respond` splices the caller's own
    // text.
    var result = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodeResponse(
        request,
        "not json at all",
        null,
        &result,
    ));
    try testing.expectEqual(@as(usize, 0), result.written().len);

    // The error arm's `data`, through the writer and through the buffer form.
    // Both refuse before either opens its frame.
    var data = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encodeResponse(
        request,
        null,
        .{ .code = -32603, .message = "m", .data = "}}" },
        &data,
    ));
    try testing.expectEqual(@as(usize, 0), data.written().len);
    try testing.expectError(error.InvalidField, errorResponse(request, .{
        .code = -32603,
        .message = "m",
        .data = "}}",
    }, &out));
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

test "methodNotFound pins the -32601 frame, member for member" {
    // The expectation is the frame written out member by member: `jsonrpc`,
    // the id in the arm it arrived in, then an `error` object carrying the code
    // and the name table 3.1 of PROTOCOLS.md gives it, and no `result` beside
    // it. Both values are normative and the order is `encodeResponse`'s, so a
    // change that moves a comma or renames the message changes the wire this
    // library promises rather than refactoring it. Both id arms are pinned
    // because the id is echoed, and an echoed id is the member a peer matches
    // the refusal by.
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

test "error data spends both enclosing object depths" {
    const accepted = @as([json.max_depth - 2]u8, @splat('[')) ++ "0" ++ @as([json.max_depth - 2]u8, @splat(']'));
    const too_deep = @as([json.max_depth - 1]u8, @splat('[')) ++ "0" ++ @as([json.max_depth - 1]u8, @splat(']'));
    var out: [512]u8 = undefined;
    var scratch: [64]u8 = undefined;
    const request: Request = .{
        .id = .{ .integer = 1 },
        .method = Method.split("tools/call"),
        .params = .absent,
    };
    const valid_error: Error = .{ .code = -1, .message = "m", .data = accepted };
    var writer = json.Writer.init(&out);
    try encode(.{ .kind = .response, .id = request.id, .rpc_error = valid_error }, &writer);
    const decoded = try decode(writer.written(), &scratch);
    try testing.expectEqualStrings(accepted, decoded.rpc_error.?.data.?);
    writer = json.Writer.init(&out);
    try encodeResponse(request, null, valid_error, &writer);
    const answer = try decode(writer.written(), &scratch);
    try testing.expectEqualStrings(accepted, answer.rpc_error.?.data.?);

    const invalid_error: Error = .{ .code = -1, .message = "m", .data = too_deep };
    const untouched: [out.len]u8 = @splat(0xa5);
    @memcpy(&out, &untouched);
    writer = json.Writer.init(&out);
    try testing.expectError(error.InvalidField, encode(
        .{ .kind = .response, .id = request.id, .rpc_error = invalid_error },
        &writer,
    ));
    try testing.expectEqualSlices(u8, &untouched, &out);
    try testing.expectEqual(@as(usize, 0), writer.len);
    try testing.expectError(error.InvalidField, encodeResponse(request, null, invalid_error, &writer));
    try testing.expectEqualSlices(u8, &untouched, &out);
    try testing.expectEqual(@as(usize, 0), writer.len);
}
