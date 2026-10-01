//! Agent2Agent, version `1.0.0`.
//!
//! Values come from PROTOCOLS.md section 5, which selects from
//! `research/normative/a2a-1.0.0.md`.
//!
//! ## Field numbers are normative
//!
//! PROTOCOLS.md section 5.4: "Field numbers are normative, because they are what
//! a protobuf encoder emits." A struct's field order is not a wire layout, so
//! every message here carries a `fields` table of `Field` alongside its own
//! fields, and `assertFieldTable` checks the two against each other at comptime.
//! A renamed field, a transposed number and a missing row are then a compile
//! error rather than a silent change to what a protobuf encoder emits.
//!
//! A `oneof` is a `union(enum)`, and its tag ordinal is 0-based and is not the
//! field number, so a codec reads the number from the table and not from the
//! ordinal.
//!
//! ## Naming
//!
//! The proto package is `lf.a2a.v1`, not `a2a.v1`.
//!
//! **An enum value is its full proto name.** `TaskState.completed` is
//! `"TASK_STATE_COMPLETED"` on the wire and not `"completed"`, and `wireName`
//! returns that spelling for the two enums that have one, `TaskState` and
//! `Role`.
//!
//! **A struct field name is not a wire name.** The Zig field names are the short
//! forms PROTOCOLS.md states, and they are snake_case where ProtoJSON is
//! camelCase. `Task.context_id` is `contextId` on the wire,
//! `ListTasksRequest.status_timestamp_after` is `statusTimestampAfter` and
//! `AgentCard.icon_url` is `iconUrl`, while `AgentCard.version` is `version`.
//! Each message's `fields` table carries the wire name of every one of its
//! fields, and `jsonName`, `fieldNumber` and `findField` read it.
//!
//! **The rule that produces those names.** ProtoJSON spells a field in
//! camelCase and the proto spells the same field in snake_case, so the Zig name
//! is the camelCase name with an underscore before every capital.
//! `snakeCaseName` is that rule, and `assertFieldTable` derives every Zig field
//! name from its own row and fails the build on a typo in either column. An
//! override that equals the derivation is rejected, so `zig_name` cannot rot
//! into a second copy of the rule.
//!
//! **The one source.** Every spelling is transcribed from the `JSON name`
//! column of `research/normative/a2a-1.0.0.md` section 2, which is the normative
//! artifact cross-verified against the rendered specification's own field
//! tables. A name this library does not carry is not derived from anything.
//!
//! **The one exception.** The `SecurityScheme` arms are the only fields where
//! the normative name and the Zig name disagree. ProtoJSON spells the first one
//! `apiKeySecurityScheme`, the derivation gives `api_key_security_scheme`, and
//! the Zig name is `api_key`; the same happens for the other four arms. Those
//! five rows carry `zig_name`, and every other row carries none.
//!
//! **A map entry is one member, not two.** `SecurityRequirementEntry`,
//! `SecuritySchemeEntry` and `OAuthScope` model the synthetic protobuf map-entry
//! message, whose field 1 is the key and field 2 is the value. ProtoJSON renders
//! one entry as the single member its key names, so those rows carry `json =
//! null`: there is no member name, because the key is data. `Part.content` is
//! null for the other reason, that a `oneof` has no member name of its own.
//!
//! **What this file encodes, and what it does not.** The tables below say
//! which name and which number a field has, and the last two sections turn them
//! into codecs. Every message in the flat half and every message in the content
//! half has a decoder and an encoder: `PartContent`, `Part`, `Message`,
//! `Artifact`, `TaskStatus`, `Task`, `TaskStatusUpdateEvent`,
//! `TaskArtifactUpdateEvent`, `SendMessageRequest`, `SendMessageResponse` and
//! `StreamResponse` joined the twenty the flat half already had. What is left
//! without a codec is `AgentCard`, `SecurityScheme`, `OAuthFlows` and the five
//! `AgentExtension` and skill fields that reach a map.
//!
//! Three encodings an earlier revision of this note named as missing are not
//! encodings. `TaskStatus.timestamp` and
//! `ListTasksRequest.status_timestamp_after` are already the ISO-8601 text a
//! peer sent, so there is no `Timestamp` to convert and re-formatting one would
//! break the round trip the contract requires: re-encoding has to put back the
//! peer's bytes, and a normalised spelling is not those bytes. Every
//! `metadata`, every `PartContent.data`, every `AgentExtension.params` and
//! every `AgentCardSignature.header` is already the borrowed JSON lexeme, read
//! with `reader.rawValue`, which is what `bridge.Envelope.meta` does and why
//! that is both the cheaper and the more faithful representation.
//!
//! The one real blocker was `Part.raw`, the only `bytes` field in the module,
//! and `json.base64` is what it waited for. ProtoJSON renders `bytes` as
//! RFC 4648 section 4 base64, so `Part.raw` is `json.base64.Alphabet.standard`.
//! `AgentCardSignature.protected` and `.signature` are the other base64 pair
//! here and needed no codec at all: the normative table types both as `string`,
//! so the base64url they carry is text the message already holds and encoding
//! one is a splice.
//!
//! **A member the wire may omit is a presence here, never a default.** A
//! REQUIRED field carries no default at all, and an optional one is `?T` rather
//! than a scalar carrying its default. `{"contextId":""}` and no `contextId`
//! are two documents, `[]` and no member are two documents, and a struct that
//! holds one empty string or one empty slice for both cannot write either of
//! them back. Nine of the content-half fields were a default before this half
//! had a codec, and each of them would have made its message lossy.
//!
//! `TaskState` and `Role` are declared `enum(u8)` because PROTOCOLS.md says so.
//! The proto states no explicit backing type, and proto3's default is `int32`,
//! so `u8` is a narrowing this library chose, not a transcription. It is sound
//! because no value exceeds 8, and a tag above the declared range is
//! `error.UnknownTag` rather than a silent fallback to `unspecified`.

const std = @import("std");
const root = @import("root.zig");
const json = @import("json.zig");
const protocol = @This();

const DecodeError = root.DecodeError;
const EncodeError = root.EncodeError;

// --- 5.1 Normative source and package -------------------------------------------

/// The protobuf package. `lf.` is part of it; `a2a.v1` alone is wrong.
pub const protobuf_package = "lf.a2a.v1";

/// The fully-qualified gRPC service.
pub const grpc_service = "lf.a2a.v1.A2AService";

/// The well-known discovery path.
pub const discovery_path = "/.well-known/agent-card.json";

/// The REST media type. A SHOULD, not a MUST.
pub const rest_media_type = "application/a2a+json";

/// The JSON-RPC binding uses plain `application/json`, not the REST type.
pub const jsonrpc_media_type = "application/json";

/// The Server-Sent Events media type for the two streaming RPCs.
pub const event_stream_media_type = "text/event-stream";

/// The service parameter carrying the version, section 5.1.
pub const version_parameter = "A2A-Version";

/// The service parameter carrying activated extension URIs.
pub const extensions_parameter = "A2A-Extensions";

/// The prefix the specification gives every service parameter it defines, so
/// they can coexist with transport-defined ones, section 5.1.
///
/// `research/normative/a2a-1.0.0.md` section 5.3 quotes the rendered
/// specification verbatim: "all service parameters defined by this
/// specification will be prefixed with `a2a-`". The prefix is the lowercase
/// spelling and the two names above are the mixed-case ones, so neither
/// carries these bytes literally; the match is case-insensitive, because an
/// HTTP field name is case-insensitive and gRPC lowercases a metadata key.
///
/// Do not compose a parameter name from it. `a2a-version` is the gRPC metadata
/// spelling the section 10.2 example prints, not the name the JSON-RPC and
/// REST bindings send: those send `version_parameter`.
pub const service_parameter_prefix = "a2a-";

/// The core protocol binding identifiers, which are bare tokens rather than
/// URIs, section 5.1.
pub const binding = struct {
    pub const jsonrpc = "JSONRPC";
    pub const grpc = "GRPC";
    pub const http_json = "HTTP+JSON";
};

pub const core_bindings = [_][]const u8{
    binding.jsonrpc,
    binding.grpc,
    binding.http_json,
};

// --- 5.1 Version strings -------------------------------------------------------

/// A `Major.Minor` version, which is all `A2A-Version` may carry.
pub const Version = struct {
    major: u16,
    minor: u16,

    pub fn format(self: Version, buffer: []u8) EncodeError![]const u8 {
        const text = std.fmt.bufPrint(buffer, "{d}.{d}", .{
            self.major,
            self.minor,
        }) catch return error.BufferTooSmall;
        return text;
    }
};

/// The version an empty `A2A-Version` means.
///
/// PROTOCOLS.md section 5.1: an empty value is interpreted as `0.3`. That is a
/// compatibility rule for clients that predate the header. What this library
/// answers at `0.3` is the alias table and nothing more: the specification
/// aliases four method names for it, and anything else at `0.3` is `-32601`.
pub const empty_version: Version = .{ .major = 0, .minor = 3 };

/// Parse an `A2A-Version` value.
///
/// The format is `Major.Minor` with no patch component, and a patch component
/// MUST NOT appear. An empty value is `0.3`. A patch is rejected rather than
/// truncated: `1.0.0` is a different thing from `1.0`, and quietly reading it as
/// `1.0` would make a caller believe a version it was not sent.
pub fn parseVersion(text: []const u8) DecodeError!Version {
    if (text.len == 0) return empty_version;

    const dot = std.mem.findScalar(u8, text, '.') orelse return error.InvalidField;
    // A second dot means a patch component, which must not appear.
    if (std.mem.findScalarPos(u8, text, dot + 1, '.') != null) return error.InvalidField;

    const major = std.fmt.parseInt(u16, text[0..dot], 10) catch return error.InvalidField;
    if (dot + 1 >= text.len) return error.InvalidField;
    const minor = std.fmt.parseInt(u16, text[dot + 1 ..], 10) catch return error.InvalidField;
    return .{ .major = major, .minor = minor };
}

// --- 5.2 Enums -----------------------------------------------------------------

/// The task lifecycle state.
///
/// Field names are the short forms PROTOCOLS.md states. `wireName` returns the
/// ProtoJSON spelling, which is the full proto name.
pub const TaskState = enum(u8) {
    unspecified = 0,
    submitted = 1,
    working = 2,
    completed = 3,
    failed = 4,
    /// Spelled with one L, as the proto does.
    canceled = 5,
    input_required = 6,
    rejected = 7,
    auth_required = 8,

    /// The ProtoJSON spelling, which is the full proto enum name.
    pub fn wireName(self: TaskState) []const u8 {
        return switch (self) {
            .unspecified => "TASK_STATE_UNSPECIFIED",
            .submitted => "TASK_STATE_SUBMITTED",
            .working => "TASK_STATE_WORKING",
            .completed => "TASK_STATE_COMPLETED",
            .failed => "TASK_STATE_FAILED",
            .canceled => "TASK_STATE_CANCELED",
            .input_required => "TASK_STATE_INPUT_REQUIRED",
            .rejected => "TASK_STATE_REJECTED",
            .auth_required => "TASK_STATE_AUTH_REQUIRED",
        };
    }

    /// Look a state up by its ProtoJSON spelling.
    ///
    /// Only the wire spelling matches. The Zig field names are a library
    /// convenience and no peer sends them, so accepting `submitted` here would
    /// accept a value the specification does not define on the wire.
    pub fn fromWireName(text: []const u8) ?TaskState {
        inline for (@typeInfo(TaskState).@"enum".fields) |field| {
            const value: TaskState = @field(TaskState, field.name);
            if (std.mem.eql(u8, text, value.wireName())) return value;
        }
        return null;
    }

    /// Parse a ProtoJSON enum value. A tag this library does not know is
    /// `error.UnknownTag`, never a fallback to `unspecified`.
    pub fn parse(text: []const u8) DecodeError!TaskState {
        return fromWireName(text) orelse error.UnknownTag;
    }

    /// Map a numeric tag to a state.
    ///
    /// PROTOCOLS.md section 5.2: a tag above the declared range is
    /// `error.UnknownTag`, never a silent fallback to `unspecified`, because a
    /// peer that moved on would otherwise look like one that said nothing.
    pub fn fromTag(tag: u8) DecodeError!TaskState {
        if (tag > task_state_max) return error.UnknownTag;
        inline for (@typeInfo(TaskState).@"enum".fields) |field| {
            const value: TaskState = @field(TaskState, field.name);
            if (@intFromEnum(value) == tag) return value;
        }
        // Every tag from 0 to `task_state_max` is declared, so this is only
        // reachable if a future tag opens a gap. A gap is an unknown tag too,
        // not a fallback.
        return error.UnknownTag;
    }
};

/// The four terminal states, section 5.2.
pub const terminal_states = [_]TaskState{
    .completed,
    .failed,
    .canceled,
    .rejected,
};

/// The two interrupted states, section 5.2.
pub const interrupted_states = [_]TaskState{
    .input_required,
    .auth_required,
};

/// Whether a state is terminal.
///
/// This is what `SubscribeToTask` and a further message both check: a terminal
/// task cannot accept more work, and the specification returns
/// `UnsupportedOperationError` rather than accepting it.
pub fn isTerminal(state: TaskState) bool {
    for (terminal_states) |terminal| {
        if (terminal == state) return true;
    }
    return false;
}

pub fn isInterrupted(state: TaskState) bool {
    for (interrupted_states) |interrupted| {
        if (interrupted == state) return true;
    }
    return false;
}

/// Who sent a message.
pub const Role = enum(u8) {
    unspecified = 0,
    user = 1,
    agent = 2,

    pub fn wireName(self: Role) []const u8 {
        return switch (self) {
            .unspecified => "ROLE_UNSPECIFIED",
            .user => "ROLE_USER",
            .agent => "ROLE_AGENT",
        };
    }

    pub fn parse(text: []const u8) DecodeError!Role {
        inline for (@typeInfo(Role).@"enum".fields) |field| {
            const value: Role = @field(Role, field.name);
            if (std.mem.eql(u8, text, value.wireName())) return value;
        }
        return error.UnknownTag;
    }

    /// Map a numeric tag to a role, the numeric counterpart of `parse`.
    ///
    /// A tag above `role_max`, or a gap in the declared range, is
    /// `error.UnknownTag` rather than `unspecified`.
    pub fn fromTag(tag: u8) DecodeError!Role {
        if (tag > role_max) return error.UnknownTag;
        inline for (@typeInfo(Role).@"enum".fields) |field| {
            const value: Role = @field(Role, field.name);
            if (@intFromEnum(value) == tag) return value;
        }
        return error.UnknownTag;
    }
};

/// The highest declared `TaskState` tag, for the range check on the wire.
pub const task_state_max: u8 = 8;
/// The highest declared `Role` tag.
pub const role_max: u8 = 2;

// --- 5.4 Field numbers and ProtoJSON names ---------------------------------------

/// One field of a protobuf message.
///
/// PROTOCOLS.md section 5.4: "Field numbers are normative, because they are what
/// a protobuf encoder emits." A struct's field order is not a wire layout, so
/// every message here carries a `fields` table beside its own fields and
/// `assertFieldTable` checks the two against each other at comptime.
pub const Field = struct {
    /// The field number, 1-based and never reused within a message.
    number: u32,
    /// The ProtoJSON member name, or null for a field that has no member name of
    /// its own: a synthetic map entry, which ProtoJSON renders as the one member
    /// its key names, and a `oneof` the struct holds as a single field.
    json: ?[]const u8,
    /// The Zig field name, or null when `snakeCaseName` derives it from `json`.
    /// It is not null only where the normative name and the Zig name disagree.
    zig_name: ?[]const u8 = null,
};

/// The lowercase letters, indexed by `head - 'A'` for a capital `head`.
const lower_alphabet = "abcdefghijklmnopqrstuvwxyz";

/// The snake_case name a ProtoJSON camelCase member name implies.
///
/// PROTOCOLS.md section 5.1: JSON field names are camelCase, and the proto spells
/// the same field in snake_case. The Zig name is the camelCase name with an
/// underscore before every capital, so `contextId` gives `context_id`. A digit
/// takes no underscore, so `oauth2MetadataUrl` gives `oauth2_metadata_url` and
/// not `oauth_2_metadata_url`.
///
/// The result is a comptime string and nothing is allocated at any stage, not
/// even transiently. The name is built by `++` from a string literal and
/// one-character slices of one, recursing on the length of a comptime-known
/// name, so it folds at comptime. There is deliberately no buffer: a slice of a
/// local escapes as a runtime value, and that is true of a `var`, of a
/// `comptime var`, and of a local of a `comptime` block alike, so no shape that
/// writes into a local can return one.
pub fn snakeCaseName(comptime json_name: []const u8) []const u8 {
    return comptime blk: {
        if (json_name.len == 0) break :blk "";
        const head = json_name[0];
        if (std.ascii.isUpper(head)) {
            // `isUpper` is ASCII, so `head` is in `'A'..'Z'` and the index is 0
            // to 25. Taking the lowercased letter from a literal keeps the
            // result free of any pointer into a local.
            const index: usize = @as(usize, head) - 'A';
            break :blk "_" ++ lower_alphabet[index .. index + 1] ++ snakeCaseName(json_name[1..]);
        }
        // Everything else passes through unchanged: a lowercase letter, a digit
        // and an underscore are all already in their final form. Testing for
        // `isLower` here instead would turn the digit in `oauth2MetadataUrl`
        // into an underscore, which is the one thing this function must not do.
        break :blk json_name[0..1] ++ snakeCaseName(json_name[1..]);
    };
}

/// The number that follows a `oneof` holding a message's leading numbers, or 0
/// when the message does not start with one.
///
/// A `oneof` occupies as many numbers as it has members, so the field beside it
/// is numbered after the last member and not after the field that holds it.
/// `Part` is the only message here that starts that way: its `content` oneof is
/// numbers 1 to 4, so `metadata` is 5. A union that is a field in its own right,
/// `OAuth2SecurityScheme.flows`, is numbered 2 like any other field, which is why
/// only the first field is examined.
fn numberAfterLeadingOneof(comptime T: type) u32 {
    const first = switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.fields.len == 0) return 0 else s.fields[0],
        else => return 0,
    };
    const oneof = switch (@typeInfo(first.type)) {
        .@"union" => |u| u,
        else => return 0,
    };
    if (oneof.tag_type == null) return 0;
    return @intCast(oneof.fields.len + 1);
}

/// Assert that `T`'s `fields` table agrees with `T`'s own fields.
///
/// One row per field, in field order, and three things are checked: the row names
/// the field, the row carries the number the proto declares, and an override
/// that restates the derivation is rejected. A renamed field, a misspelled
/// member name, an override that duplicates the rule, a transposed number and a
/// missing row are then compile errors rather than a silent change to what a
/// protobuf encoder emits. The field count, the field names and the numbers are
/// all covered here, where the old count-and-name pair covered only the first.
fn assertFieldTable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| assertTable(T, s.fields),
        .@"union" => |u| assertTable(T, u.fields),
        else => @compileError(std.fmt.comptimePrint(
            "{s} is neither a struct nor a tagged union, so it is not a message",
            .{@typeName(T)},
        )),
    }
}

/// The body of `assertFieldTable`, for a struct or for a tagged union.
///
/// `members` is `[]const StructField` in one case and `[]const UnionField` in the
/// other. The loop reads only the name, which both carry, so one body checks
/// both shapes.
fn assertTable(comptime T: type, comptime members: anytype) void {
    const table = T.fields;
    if (table.len != members.len) {
        @compileError(std.fmt.comptimePrint(
            "{s} has {d} fields but its field table has {d} rows",
            .{ @typeName(T), members.len, table.len },
        ));
    }
    // `comptime` on the call, for the same reason as in `snakeCaseName`: a
    // `const` binding is a runtime value, and this one decides a branch.
    const after_oneof = comptime numberAfterLeadingOneof(T);
    inline for (table, members, 0..) |entry, member, index| {
        const derived: ?[]const u8 = if (entry.json) |json_name|
            snakeCaseName(json_name)
        else
            null;
        // An override that equals the derivation is a second copy of the rule,
        // and it rots the moment the rule changes.
        if (entry.zig_name) |zig_name| {
            if (derived) |expected| {
                if (comptime std.mem.eql(u8, zig_name, expected)) {
                    @compileError(std.fmt.comptimePrint(
                        "{s} field {d} overrides the Zig name to '{s}', which '{s}'" ++
                            " already derives",
                        .{ @typeName(T), index, zig_name, entry.json.? },
                    ));
                }
            }
        }
        // A row with neither a member name nor a Zig name cannot name its field,
        // and that is a transcription error rather than a wire fact. This is an
        // `if` and not an `orelse` because `@compileError` is only legal in a
        // comptime branch, and an `orelse` operand is a runtime position.
        if (entry.json == null and entry.zig_name == null) {
            @compileError(std.fmt.comptimePrint(
                "{s} field {d} has neither a ProtoJSON name nor a Zig name",
                .{ @typeName(T), index },
            ));
        }
        const expected_name: []const u8 = entry.zig_name orelse derived.?;
        if (comptime !std.mem.eql(u8, member.name, expected_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} field {d} is named '{s}', but its table row says '{s}'",
                .{ @typeName(T), index, member.name, expected_name },
            ));
        }
        const expected_number: u32 = if (index == 0)
            1
        else if (index == 1 and after_oneof != 0)
            after_oneof
        else
            table[index - 1].number + 1;
        if (entry.number != expected_number) {
            @compileError(std.fmt.comptimePrint(
                "{s} field {d} is number {d}, but its table row says {d}",
                .{ @typeName(T), index, expected_number, entry.number },
            ));
        }
    }
}

/// The ProtoJSON member name of message `T`'s field `index`.
///
/// Null for a field with no member name of its own, which is a `oneof` the
/// struct holds as one field and a synthetic map entry. A map entry's member
/// name is the map's key, and a key is data rather than a name.
pub fn jsonName(comptime T: type, comptime index: usize) ?[]const u8 {
    return T.fields[index].json;
}

/// The field number of message `T`'s field `index`.
pub fn fieldNumber(comptime T: type, comptime index: usize) u32 {
    return T.fields[index].number;
}

/// The index of the field of message `T` that ProtoJSON spells `member_name`,
/// or null.
///
/// A member no field of `T` carries is null rather than a guess, which is what
/// lets a decoder reject a name a newer revision added.
///
/// The parameter is not called `json`: that is the module holding the reader
/// and the writer every decoder below is built from, and a parameter of that
/// name would shadow it for the whole file.
pub fn findField(comptime T: type, member_name: []const u8) ?usize {
    inline for (T.fields, 0..) |entry, index| {
        const name = entry.json orelse continue;
        if (std.mem.eql(u8, name, member_name)) return index;
    }
    return null;
}

/// `Task`, field numbers 1 to 6.
pub const Task = struct {
    /// 1. Required, server-generated for a new task.
    id: []const u8,
    /// 2.
    ///
    /// Optional, and carried as presence rather than as a `[]const u8 = ""`
    /// default: a peer that wrote `"contextId":""` and a peer that wrote no
    /// `contextId` sent two documents, and one empty string cannot write either
    /// of them back.
    context_id: ?[]const u8 = null,
    /// 3. Required, and it carries no default: section 2.2 of
    /// `research/normative/a2a-1.0.0.md` marks it REQUIRED, and PROTOCOLS.md
    /// section 5.4 leaves its note empty, so the normative artifact is the only
    /// thing that says so. A defaulted `status` is a task the proto forbids.
    status: TaskStatus,
    /// 4.
    ///
    /// A `[]const Artifact = &.{}` default would make `"artifacts":[]` and no
    /// `artifacts` the same value, and an encoder could then not put back the
    /// bytes of the one the peer did not write. Null is the absent list and a
    /// zero-length slice is the empty one, and the two are told apart.
    artifacts: ?[]const Artifact = null,
    /// 5. Soft-deprecated in favour of a timeline, retained through 1.x.
    ///
    /// Optional, and for the reason `artifacts` above is.
    history: ?[]const Message = null,
    /// 6.
    metadata: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "id" },
        .{ .number = 2, .json = "contextId" },
        .{ .number = 3, .json = "status" },
        .{ .number = 4, .json = "artifacts" },
        .{ .number = 5, .json = "history" },
        .{ .number = 6, .json = "metadata" },
    };
};

comptime {
    assertFieldTable(Task);
}

/// `TaskStatus`, field numbers 1 to 3.
pub const TaskStatus = struct {
    /// 1. Required.
    state: TaskState,
    /// 2.
    message: ?Message = null,
    /// 3. ISO-8601 UTC in JSON.
    timestamp: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "state" },
        .{ .number = 2, .json = "message" },
        .{ .number = 3, .json = "timestamp" },
    };
};

comptime {
    assertFieldTable(TaskStatus);
}

/// `Message`, field numbers 1 to 8.
pub const Message = struct {
    /// 1. Required.
    message_id: []const u8,
    /// 2.
    ///
    /// A presence, not a `[]const u8 = ""` default: `"contextId":""` and no
    /// `contextId` are two documents and a single empty string is not either of
    /// them.
    context_id: ?[]const u8 = null,
    /// 3.
    ///
    /// A presence, for the reason `context_id` above is one.
    task_id: ?[]const u8 = null,
    /// 4. Required.
    role: Role,
    /// 5. Required.
    ///
    /// A REQUIRED `repeated` field is satisfied by an empty array, so this one
    /// carries no default and no emptiness rule: `[]` is a message with no
    /// parts, and only the absence of the member is `error.MissingField`. The
    /// elements live in the caller's storage; see `ContentArena`.
    parts: []const Part,
    /// 6.
    metadata: ?[]const u8 = null,
    /// 7. Extension URIs.
    ///
    /// Optional, and so a presence: `[]` is an empty activation list and no
    /// `extensions` member is no activation list, and the two are different
    /// requests. The elements live in `ContentArena.strings`.
    extensions: ?[]const []const u8 = null,
    /// 8.
    ///
    /// Optional, and a presence, for the reason `extensions` above is one.
    reference_task_ids: ?[]const []const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "messageId" },
        .{ .number = 2, .json = "contextId" },
        .{ .number = 3, .json = "taskId" },
        .{ .number = 4, .json = "role" },
        .{ .number = 5, .json = "parts" },
        .{ .number = 6, .json = "metadata" },
        .{ .number = 7, .json = "extensions" },
        .{ .number = 8, .json = "referenceTaskIds" },
    };
};

comptime {
    assertFieldTable(Message);
}

/// The `content` `oneof` of `Part`.
///
/// The discriminator is which member is present, not a `kind` field: the proto
/// has no `kind`, and a decoder switching on one would drop every part. These
/// four members are the numbers 1 to 4 that `Part` holds in its `content` field.
pub const PartContent = union(enum) {
    /// Field 1.
    text: []const u8,
    /// Field 2. Base64 in JSON.
    raw: []const u8,
    /// Field 3.
    url: []const u8,
    /// Field 4. Any JSON value.
    data: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "text" },
        .{ .number = 2, .json = "raw" },
        .{ .number = 3, .json = "url" },
        .{ .number = 4, .json = "data" },
    };
};

comptime {
    assertFieldTable(PartContent);
}

/// `Part`, field numbers 1 to 7.
///
/// The `content` oneof holds numbers 1 to 4 as one Zig field, so this table has
/// four rows for four fields. Row 0 is the `oneof` itself and carries no member
/// name, and a codec writes the member it is holding under the number
/// `PartContent` gives that member.
pub const Part = struct {
    /// One of fields 1 to 4.
    content: PartContent,
    /// 5.
    metadata: ?[]const u8 = null,
    /// 6.
    filename: ?[]const u8 = null,
    /// 7. Available for every part type.
    media_type: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = null, .zig_name = "content" },
        .{ .number = 5, .json = "metadata" },
        .{ .number = 6, .json = "filename" },
        .{ .number = 7, .json = "mediaType" },
    };
};

comptime {
    assertFieldTable(Part);
}

/// `Artifact`, field numbers 1 to 6.
pub const Artifact = struct {
    /// 1. Required.
    artifact_id: []const u8,
    /// 2.
    name: ?[]const u8 = null,
    /// 3.
    description: ?[]const u8 = null,
    /// 4. Required.
    ///
    /// A REQUIRED `repeated` field is satisfied by an empty array, for the
    /// reason `Message.parts` is: `[]` is an artifact with no parts and only
    /// the absence of the member is `error.MissingField`. The elements live in
    /// `ContentArena.parts`.
    parts: []const Part,
    /// 5.
    metadata: ?[]const u8 = null,
    /// 6.
    ///
    /// Optional, and so a presence rather than an empty-slice default: `[]` is
    /// an empty activation list and no member is none at all. The elements live
    /// in `ContentArena.strings`.
    extensions: ?[]const []const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "artifactId" },
        .{ .number = 2, .json = "name" },
        .{ .number = 3, .json = "description" },
        .{ .number = 4, .json = "parts" },
        .{ .number = 5, .json = "metadata" },
        .{ .number = 6, .json = "extensions" },
    };
};

comptime {
    assertFieldTable(Artifact);
}

/// `TaskStatusUpdateEvent`, field numbers 1 to 4.
///
/// The `final` boolean was removed in 1.0. Stream closure is the terminal
/// signal, and there is no done-marker to miss.
pub const TaskStatusUpdateEvent = struct {
    /// 1.
    task_id: []const u8,
    /// 2. Required, and it carries no default for the same reason: section 2.4
    /// marks `context_id` REQUIRED and PROTOCOLS.md section 5.4 leaves its note
    /// empty. An empty `context_id` is a value the proto does not allow.
    context_id: []const u8,
    /// 3.
    status: TaskStatus,
    /// 4.
    metadata: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "taskId" },
        .{ .number = 2, .json = "contextId" },
        .{ .number = 3, .json = "status" },
        .{ .number = 4, .json = "metadata" },
    };
};

comptime {
    assertFieldTable(TaskStatusUpdateEvent);
}

/// `TaskArtifactUpdateEvent`, field numbers 1 to 6.
pub const TaskArtifactUpdateEvent = struct {
    /// 1.
    task_id: []const u8,
    /// 2. Required, and it carries no default for the same reason: section 2.8
    /// marks `context_id` REQUIRED and PROTOCOLS.md section 5.4 leaves its note
    /// empty. An empty `context_id` is a value the proto does not allow.
    context_id: []const u8,
    /// 3.
    artifact: Artifact,
    /// 4.
    append: ?bool = null,
    /// 5. Marks artifact completion, not task completion.
    last_chunk: ?bool = null,
    /// 6.
    metadata: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "taskId" },
        .{ .number = 2, .json = "contextId" },
        .{ .number = 3, .json = "artifact" },
        .{ .number = 4, .json = "append" },
        .{ .number = 5, .json = "lastChunk" },
        .{ .number = 6, .json = "metadata" },
    };
};

comptime {
    assertFieldTable(TaskArtifactUpdateEvent);
}

/// `SendMessageConfiguration`, field numbers 1 to 4.
pub const SendMessageConfiguration = struct {
    /// 1. Optional, because `[]` and no member are the same list and different
    /// bytes, and an encoder that writes one of them for the other changes a
    /// request rather than restating it.
    ///
    /// The elements live in the caller's storage; see
    /// `decodeSendMessageConfiguration`.
    accepted_output_modes: ?[]const []const u8 = null,
    /// 2.
    task_push_notification_config: ?TaskPushNotificationConfig = null,
    /// 3.
    history_length: ?i32 = null,
    /// 4. Default false, which means blocking.
    ///
    /// This inverts the 0.3 `blocking` default, which was non-blocking. Reading
    /// a 0.3 default as if it were a 1.0 one would make a caller wait on a call
    /// that returns immediately.
    ///
    /// The proto declares the field a singular `bool`, so ProtoJSON rejects
    /// `null` for it and no peer sends one. It is `?bool` anyway, and a decoder
    /// still refuses a `null`: absent and false mean the same thing to a
    /// caller and are two different documents to the encoder, so a peer that
    /// wrote `"returnImmediately":false` is a peer whose bytes have to come
    /// back.
    return_immediately: ?bool = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "acceptedOutputModes" },
        .{ .number = 2, .json = "taskPushNotificationConfig" },
        .{ .number = 3, .json = "historyLength" },
        .{ .number = 4, .json = "returnImmediately" },
    };
};

comptime {
    assertFieldTable(SendMessageConfiguration);
}

// --- 5.4 Push notification configuration ---------------------------------------

/// `AuthenticationInfo`, field numbers 1 to 2.
///
/// The proto declares `scheme` singular, not repeated: it names the one scheme
/// the webhook credential belongs to, and the pair fills the
/// `Authorization: {scheme} {credentials}` line of the webhook request.
pub const AuthenticationInfo = struct {
    /// 1. Required.
    scheme: []const u8,
    /// 2. The credential that goes with `scheme`.
    ///
    /// Optional rather than an empty string, because the two are different
    /// requests: no credential is a scheme sent without a secret, and an empty
    /// credential is a secret that happens to be blank.
    credentials: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "scheme" },
        .{ .number = 2, .json = "credentials" },
    };
};

comptime {
    assertFieldTable(AuthenticationInfo);
}

/// `TaskPushNotificationConfig`, field numbers 1 to 6.
///
/// This one message is the create-request body, the create response, and the
/// get and list response. The proto has no separate `*Request` wrapper for it,
/// which is why the create RPC's request type is this message.
pub const TaskPushNotificationConfig = struct {
    /// 1.
    tenant: ?[]const u8 = null,
    /// 2. Server-generated on create.
    id: ?[]const u8 = null,
    /// 3. The task this config delivers notifications for.
    task_id: ?[]const u8 = null,
    /// 4. Required. Where the agent posts the `StreamResponse`.
    url: []const u8,
    /// 5. A token unique for this task or session. It is a field of its own
    /// because it is what a webhook receiver checks on receipt, not only part
    /// of an `Authorization` line.
    token: ?[]const u8 = null,
    /// 6. Fills the `Authorization` line of the webhook request.
    authentication: ?AuthenticationInfo = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "id" },
        .{ .number = 3, .json = "taskId" },
        .{ .number = 4, .json = "url" },
        .{ .number = 5, .json = "token" },
        .{ .number = 6, .json = "authentication" },
    };
};

comptime {
    assertFieldTable(TaskPushNotificationConfig);
}

/// The `payload` `oneof` of `SendMessageResponse`, field numbers 1 and 2.
pub const SendMessageResponse = union(enum) {
    /// 1.
    task: Task,
    /// 2.
    message: Message,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "task" },
        .{ .number = 2, .json = "message" },
    };
};

comptime {
    assertFieldTable(SendMessageResponse);
}

/// The `payload` `oneof` of `StreamResponse`, field numbers 1 to 4.
pub const StreamResponse = union(enum) {
    /// 1.
    task: Task,
    /// 2.
    message: Message,
    /// 3.
    status_update: TaskStatusUpdateEvent,
    /// 4.
    artifact_update: TaskArtifactUpdateEvent,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "task" },
        .{ .number = 2, .json = "message" },
        .{ .number = 3, .json = "statusUpdate" },
        .{ .number = 4, .json = "artifactUpdate" },
    };
};

comptime {
    assertFieldTable(StreamResponse);
}

/// The send RPC's request. `message` is required by the proto.
pub const SendMessageRequest = struct {
    /// 1.
    ///
    /// A presence, and the same shape every other request in this file gives its
    /// tenant. A peer that wrote `"tenant":""` asked for the empty tenant, which
    /// is not the same request as asking for none, and a `[]const u8 = ""` would
    /// answer the first with the second.
    tenant: ?[]const u8 = null,
    /// 2. Required.
    message: Message,
    /// 3.
    configuration: ?SendMessageConfiguration = null,
    /// 4. Borrowed ProtoJSON `Struct`.
    metadata: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "message" },
        .{ .number = 3, .json = "configuration" },
        .{ .number = 4, .json = "metadata" },
    };
};

comptime {
    assertFieldTable(SendMessageRequest);
}

/// Fetch one task, optionally including this many history messages.
pub const GetTaskRequest = struct {
    /// 1.
    tenant: ?[]const u8 = null,
    /// 2. Required.
    id: []const u8,
    /// 3. Explicit proto3 presence.
    history_length: ?i32 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "id" },
        .{ .number = 3, .json = "historyLength" },
    };
};

comptime {
    assertFieldTable(GetTaskRequest);
}

pub const ListTasksRequest = struct {
    /// 1.
    tenant: ?[]const u8 = null,
    /// 2.
    context_id: ?[]const u8 = null,
    /// 3. Explicit presence in this library, though the proto declares the
    /// field singular.
    ///
    /// The proto gives `TaskState` an implicit presence, so `unspecified` and
    /// an absent member are the same value on the wire and `fromTag` says so.
    /// They are two documents though, and the encoder has to put back the one
    /// that arrived: a peer that wrote `"status":"TASK_STATE_UNSPECIFIED"` is a
    /// peer that filtered, and a re-encode that drops the member changes what
    /// it asked for. See the codec section's note on presence.
    status: ?TaskState = null,
    /// 4. If present, 1 to 100 inclusive; see `isValidPageSize`.
    page_size: ?i32 = null,
    /// 5.
    page_token: ?[]const u8 = null,
    /// 6.
    history_length: ?i32 = null,
    /// 7. ISO-8601 UTC in ProtoJSON, carried as the text the peer wrote.
    ///
    /// There is no `Timestamp` to convert and none is wanted. Re-encoding has
    /// to put back the peer's bytes, and a normalised spelling of the same
    /// instant is not those bytes.
    status_timestamp_after: ?[]const u8 = null,
    /// 8. Explicit presence; absent defaults to false.
    include_artifacts: ?bool = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "contextId" },
        .{ .number = 3, .json = "status" },
        .{ .number = 4, .json = "pageSize" },
        .{ .number = 5, .json = "pageToken" },
        .{ .number = 6, .json = "historyLength" },
        .{ .number = 7, .json = "statusTimestampAfter" },
        .{ .number = 8, .json = "includeArtifacts" },
    };
};

comptime {
    assertFieldTable(ListTasksRequest);
}

pub const ListTasksResponse = struct {
    /// 1. Required, but may be empty.
    tasks: []const Task,
    /// 2. Required; an empty string marks the last page.
    next_page_token: []const u8,
    /// 3. Required.
    page_size: i32,
    /// 4. Required.
    total_size: i32,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tasks" },
        .{ .number = 2, .json = "nextPageToken" },
        .{ .number = 3, .json = "pageSize" },
        .{ .number = 4, .json = "totalSize" },
    };
};

comptime {
    assertFieldTable(ListTasksResponse);
}

pub const CancelTaskRequest = struct {
    /// 1.
    tenant: ?[]const u8 = null,
    /// 2. Required.
    id: []const u8,
    /// 3. Borrowed ProtoJSON `Struct`.
    metadata: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "id" },
        .{ .number = 3, .json = "metadata" },
    };
};

comptime {
    assertFieldTable(CancelTaskRequest);
}

pub const SubscribeToTaskRequest = struct {
    /// 1.
    tenant: ?[]const u8 = null,
    /// 2. Required.
    id: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "id" },
    };
};

comptime {
    assertFieldTable(SubscribeToTaskRequest);
}

pub const GetTaskPushNotificationConfigRequest = struct {
    /// 1.
    tenant: ?[]const u8 = null,
    /// 2. Required.
    task_id: []const u8,
    /// 3. Required.
    id: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "taskId" },
        .{ .number = 3, .json = "id" },
    };
};

comptime {
    assertFieldTable(GetTaskPushNotificationConfigRequest);
}

pub const DeleteTaskPushNotificationConfigRequest = struct {
    /// 1.
    tenant: ?[]const u8 = null,
    /// 2. Required.
    task_id: []const u8,
    /// 3. Required.
    id: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
        .{ .number = 2, .json = "taskId" },
        .{ .number = 3, .json = "id" },
    };
};

comptime {
    assertFieldTable(DeleteTaskPushNotificationConfigRequest);
}

/// The source proto declares `tenant` first, but assigns it field 4.
pub const ListTaskPushNotificationConfigsRequest = struct {
    /// 1. Required.
    task_id: []const u8,
    /// 2. Plain `int32`, not `optional int32` as in `ListTasksRequest`, and
    /// therefore still recorded as presence here: the two documents
    /// `"pageSize":0` and no `pageSize` are the same request and different
    /// bytes, and only one of them can be written back.
    page_size: ?i32 = null,
    /// 3.
    page_token: ?[]const u8 = null,
    /// 4.
    tenant: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "taskId" },
        .{ .number = 2, .json = "pageSize" },
        .{ .number = 3, .json = "pageToken" },
        .{ .number = 4, .json = "tenant" },
    };
};

comptime {
    assertFieldTable(ListTaskPushNotificationConfigsRequest);
}

pub const ListTaskPushNotificationConfigsResponse = struct {
    /// 1.
    configs: []const TaskPushNotificationConfig = &.{},
    /// 2. Unlike `ListTasksResponse.next_page_token`, this is not required.
    next_page_token: []const u8 = "",

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "configs" },
        .{ .number = 2, .json = "nextPageToken" },
    };
};

comptime {
    assertFieldTable(ListTaskPushNotificationConfigsResponse);
}

pub const GetExtendedAgentCardRequest = struct {
    /// 1.
    tenant: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tenant" },
    };
};

comptime {
    assertFieldTable(GetExtendedAgentCardRequest);
}

/// The `DeleteTaskPushNotificationConfig` response is `google.protobuf.Empty`.
pub const Empty = struct {
    /// The message declares no field, so the table is empty and a codec writes
    /// an empty object.
    pub const fields = [_]Field{};
};

comptime {
    assertFieldTable(Empty);
}

// --- 5.3 Service and bindings --------------------------------------------------

/// The HTTP verb and path template of an RPC binding.
pub const HttpBinding = struct {
    verb: []const u8,
    path: []const u8,
};

/// One RPC, its request and response, and its HTTP binding.
pub const Rpc = struct {
    name: []const u8,
    request: []const u8,
    response: []const u8,
    http: HttpBinding,
    /// True for the two streaming RPCs, whose response is a server-sent event
    /// stream rather than a single message.
    streaming: bool = false,

    /// Resolve the RPC's declared protobuf request to its Zig payload type.
    pub fn requestType(comptime self: Rpc) type {
        return messageType(self.request);
    }

    /// Resolve the RPC's declared protobuf response to its Zig payload type.
    pub fn responseType(comptime self: Rpc) type {
        return messageType(self.response);
    }

    fn messageType(comptime name: []const u8) type {
        if (std.mem.eql(u8, name, "google.protobuf.Empty")) return Empty;
        if (!@hasDecl(protocol, name)) @compileError("A2A RPC references an undeclared message: " ++ name);
        return @field(protocol, name);
    }
};

/// The eleven RPCs, section 5.3.
///
/// There is no mandatory binding: an agent declares an ordered
/// `supportedInterfaces` and a client picks the first entry it supports.
pub const rpcs = [_]Rpc{
    .{
        .name = "SendMessage",
        .request = "SendMessageRequest",
        .response = "SendMessageResponse",
        .http = .{ .verb = "POST", .path = "/message:send" },
    },
    .{
        .name = "SendStreamingMessage",
        .request = "SendMessageRequest",
        .response = "StreamResponse",
        .http = .{ .verb = "POST", .path = "/message:stream" },
        .streaming = true,
    },
    .{
        .name = "GetTask",
        .request = "GetTaskRequest",
        .response = "Task",
        .http = .{ .verb = "GET", .path = "/tasks/{id}" },
    },
    .{
        .name = "ListTasks",
        .request = "ListTasksRequest",
        .response = "ListTasksResponse",
        .http = .{ .verb = "GET", .path = "/tasks" },
    },
    .{
        .name = "CancelTask",
        .request = "CancelTaskRequest",
        .response = "Task",
        .http = .{ .verb = "POST", .path = "/tasks/{id}:cancel" },
    },
    .{
        .name = "SubscribeToTask",
        .request = "SubscribeToTaskRequest",
        .response = "StreamResponse",
        // The proto binds this to GET; the rendered prose says POST. The proto
        // is the normative artifact, so GET is what this library carries, and
        // the conflict is recorded here rather than silently resolved.
        .http = .{ .verb = "GET", .path = "/tasks/{id}:subscribe" },
        .streaming = true,
    },
    .{
        .name = "CreateTaskPushNotificationConfig",
        .request = "TaskPushNotificationConfig",
        .response = "TaskPushNotificationConfig",
        .http = .{ .verb = "POST", .path = "/tasks/{task_id}/pushNotificationConfigs" },
    },
    .{
        .name = "GetTaskPushNotificationConfig",
        .request = "GetTaskPushNotificationConfigRequest",
        .response = "TaskPushNotificationConfig",
        .http = .{ .verb = "GET", .path = "/tasks/{task_id}/pushNotificationConfigs/{id}" },
    },
    .{
        .name = "ListTaskPushNotificationConfigs",
        .request = "ListTaskPushNotificationConfigsRequest",
        .response = "ListTaskPushNotificationConfigsResponse",
        .http = .{ .verb = "GET", .path = "/tasks/{task_id}/pushNotificationConfigs" },
    },
    .{
        .name = "DeleteTaskPushNotificationConfig",
        .request = "DeleteTaskPushNotificationConfigRequest",
        // The proto returns `google.protobuf.Empty` here, so a deleted config is
        // not read back. PROTOCOLS.md's table gives `TaskPushNotificationConfig`
        // for this response, and section 5.1 declares the proto "the single
        // normative artifact", so the proto wins.
        .response = "google.protobuf.Empty",
        .http = .{ .verb = "DELETE", .path = "/tasks/{task_id}/pushNotificationConfigs/{id}" },
    },
    .{
        .name = "GetExtendedAgentCard",
        .request = "GetExtendedAgentCardRequest",
        .response = "AgentCard",
        .http = .{ .verb = "GET", .path = "/extendedAgentCard" },
    },
};

comptime {
    for (rpcs) |rpc| {
        _ = rpc.requestType();
        _ = rpc.responseType();
    }
}

/// The prefix of every RPC's secondary HTTP binding, section 5.3.
pub const tenant_binding_prefix = "/{tenant}";

/// A method name that version `0.3` spelled differently from `1.0`.
pub const MethodAlias = struct {
    /// The `0.3` JSON-RPC `method` string, in the slash form.
    v0_3: []const u8,
    /// The `1.0` JSON-RPC `method` string, which is the bare RPC name.
    v1_0: []const u8,
};

/// The four method names aliased at version `0.3`, section 5.3.
///
/// `0.3` used the slash form and `1.0` uses the RPC name, so only these four
/// resolve; anything else at `0.3` returns `-32601`. The table carries the
/// `0.3` spelling *and* the `1.0` name it stands for, so a server can both
/// recognise a `0.3` request and dispatch it to the RPC it names.
pub const v0_3_method_aliases = [_]MethodAlias{
    .{ .v0_3 = "message/send", .v1_0 = "SendMessage" },
    .{ .v0_3 = "message/stream", .v1_0 = "SendStreamingMessage" },
    .{ .v0_3 = "tasks/get", .v1_0 = "GetTask" },
    .{ .v0_3 = "tasks/cancel", .v1_0 = "CancelTask" },
};

/// The versions this library implements, section 5.1.
///
/// `1.0` is the binding itself; `0.3` is the compatibility reading an empty
/// `A2A-Version` selects. Anything else is `VersionNotSupportedError`,
/// `-32009`.
pub const supported_versions = [_]Version{
    .{ .major = 1, .minor = 0 },
    empty_version,
};

/// Whether this library implements a protocol version.
pub fn isVersionSupported(version: Version) bool {
    for (supported_versions) |supported| {
        if (supported.major == version.major and supported.minor == version.minor) return true;
    }
    return false;
}

/// The `1.0` method name a `0.3` slash-form name aliases, or null.
///
/// This is the direction a server needs: a `0.3` request says
/// `message/send`, and the handler it reaches is the `SendMessage` RPC. The
/// other direction is a no-op, because the `1.0` name is the RPC name itself.
pub fn aliasToCurrent(method_name: []const u8) ?[]const u8 {
    for (v0_3_method_aliases) |alias| {
        if (std.mem.eql(u8, alias.v0_3, method_name)) return alias.v1_0;
    }
    return null;
}

/// The RPC's secondary `/{tenant}` binding, section 5.3.
///
/// Every RPC has exactly one `additional_bindings` entry, its primary path
/// with a leading `/{tenant}` segment. The table is walked `inline`, so each
/// path is joined at comptime and the result borrows static memory; nothing
/// allocates. The proto writes its path variables as `{id=*}` where the
/// specification table writes `{id}`; the prefix is one leading segment either
/// way, so the join is unaffected.
pub fn tenantBindingPath(rpc_name: []const u8) ?[]const u8 {
    inline for (rpcs) |rpc| {
        if (std.mem.eql(u8, rpc.name, rpc_name)) return tenant_binding_prefix ++ rpc.http.path;
    }
    return null;
}

/// Whether a JSON-RPC method name is valid at the requested version.
///
/// A version this library does not implement is false for every name, so a
/// caller raises `VersionNotSupportedError`, `-32009`, rather than reporting an
/// unsupported revision as a missing method. At `0.3` only the four aliased
/// slash-form names are accepted; at `1.0` the RPC names stand as they are. A
/// name that is neither is method-not-found, not a guess.
pub fn isMethodValidAt(version: Version, method_name: []const u8) bool {
    if (!isVersionSupported(version)) return false;
    // `0.3` used the slash form and the specification aliases exactly four
    // names. Anything else at `0.3` is `-32601`, so an RPC that exists at `1.0`
    // but is not one of the four is *not* valid there, and a `1.0` name is not
    // either: that spelling did not exist at `0.3`.
    const is_zero_three = version.major == empty_version.major and
        version.minor == empty_version.minor;
    if (is_zero_three) {
        for (v0_3_method_aliases) |alias| {
            if (std.mem.eql(u8, alias.v0_3, method_name)) return true;
        }
        return false;
    }
    for (rpcs) |rpc| {
        if (std.mem.eql(u8, rpc.name, method_name)) return true;
    }
    return false;
}

// --- 5.4 Pagination ------------------------------------------------------------

/// `ListTasksRequest.page_size` bounds, section 5.4.
pub const page_size_min: i32 = 1;
pub const page_size_max: i32 = 100;

/// The default cap when `page_size` is unspecified.
pub const page_size_default: i32 = 50;

pub fn isValidPageSize(page_size: i32) bool {
    return page_size >= page_size_min and page_size <= page_size_max;
}

/// Whether a `next_page_token` means another page exists.
///
/// The field is always present and is the empty string on the last page. An
/// absent field is a decode error, so a client must never infer "no more pages"
/// from absence.
pub fn hasNextPage(next_page_token: []const u8) bool {
    return next_page_token.len != 0;
}

// --- 5.6 Errors ----------------------------------------------------------------

/// The gRPC status names A2A maps onto.
pub const GrpcStatus = struct {
    pub const not_found = "NOT_FOUND";
    pub const failed_precondition = "FAILED_PRECONDITION";
    pub const invalid_argument = "INVALID_ARGUMENT";
    pub const internal = "INTERNAL";
};

/// The gRPC status numbers, from `google/rpc/code.proto`.
pub const grpc_code_not_found: u8 = 5;
pub const grpc_code_failed_precondition: u8 = 9;
pub const grpc_code_invalid_argument: u8 = 3;
pub const grpc_code_internal: u8 = 13;

/// The `google.rpc.ErrorInfo` domain that identifies an A2A error.
pub const error_domain = "a2a-protocol.org";

/// The nine A2A-specific errors, section 5.6.
///
/// Six of the nine collapse onto HTTP 400 and gRPC FAILED_PRECONDITION, so the
/// status is not discriminating and the `ErrorInfo` reason is the only way to
/// tell them apart. A reason this library does not know becomes an explicit
/// unmapped variant rather than a guess.
pub const A2aError = enum(i32) {
    task_not_found = -32001,
    task_not_cancelable = -32002,
    push_notification_not_supported = -32003,
    unsupported_operation = -32004,
    content_type_not_supported = -32005,
    invalid_agent_response = -32006,
    extended_agent_card_not_configured = -32007,
    extension_support_required = -32008,
    version_not_supported = -32009,

    /// The `ErrorInfo.reason`, which is the type name in UPPER_SNAKE_CASE with
    /// the `Error` suffix removed. `TaskNotFoundError` becomes
    /// `TASK_NOT_FOUND`.
    pub fn reason(self: A2aError) []const u8 {
        return switch (self) {
            .task_not_found => "TASK_NOT_FOUND",
            .task_not_cancelable => "TASK_NOT_CANCELABLE",
            .push_notification_not_supported => "PUSH_NOTIFICATION_NOT_SUPPORTED",
            .unsupported_operation => "UNSUPPORTED_OPERATION",
            .content_type_not_supported => "CONTENT_TYPE_NOT_SUPPORTED",
            .invalid_agent_response => "INVALID_AGENT_RESPONSE",
            .extended_agent_card_not_configured => "EXTENDED_AGENT_CARD_NOT_CONFIGURED",
            .extension_support_required => "EXTENSION_SUPPORT_REQUIRED",
            .version_not_supported => "VERSION_NOT_SUPPORTED",
        };
    }

    pub fn grpcStatus(self: A2aError) []const u8 {
        return switch (self) {
            .task_not_found => GrpcStatus.not_found,
            .content_type_not_supported => GrpcStatus.invalid_argument,
            .invalid_agent_response => GrpcStatus.internal,
            // The other six all share FAILED_PRECONDITION.
            else => GrpcStatus.failed_precondition,
        };
    }

    pub fn grpcCode(self: A2aError) u8 {
        return switch (self) {
            .task_not_found => grpc_code_not_found,
            .content_type_not_supported => grpc_code_invalid_argument,
            .invalid_agent_response => grpc_code_internal,
            else => grpc_code_failed_precondition,
        };
    }

    pub fn httpStatus(self: A2aError) u16 {
        return switch (self) {
            .task_not_found => 404,
            .invalid_agent_response => 500,
            // The other seven all share 400.
            else => 400,
        };
    }

    pub fn fromCode(code: i32) ?A2aError {
        return switch (code) {
            -32001 => .task_not_found,
            -32002 => .task_not_cancelable,
            -32003 => .push_notification_not_supported,
            -32004 => .unsupported_operation,
            -32005 => .content_type_not_supported,
            -32006 => .invalid_agent_response,
            -32007 => .extended_agent_card_not_configured,
            -32008 => .extension_support_required,
            -32009 => .version_not_supported,
            else => null,
        };
    }
};

/// The specification's own range statement, verbatim: A2A-specific errors use
/// codes in the range `-32001` to `-32099`.
///
/// Both bounds are negative, so the numerically smaller one is `-32099`. The
/// names say which end of the interval each is, and the check is
/// `range_min <= code and code <= range_max`.
pub const error_range_min: i32 = -32099;
pub const error_range_max: i32 = -32001;

/// What an `ErrorInfo` detail classifies to, section 5.6.
///
/// PROTOCOLS.md: "A decoder keys on the `reason`, not the code alone, and a
/// `reason` it does not know becomes an explicit unmapped variant rather than
/// a guess." So a reason this library does know resolves to `known`, and only
/// an unrecognised one, a foreign domain, or an absent domain are unmapped.
/// The name is historical; the three unmapped variants are the ones it was
/// declared for.
///
/// The nine codes collapse onto three status pairs, so a peer may send a reason
/// from a newer revision. That one is carried as its own variant rather than
/// mapped onto the closest known error, because a guess here would attribute
/// the wrong cause to a failure.
pub const UnmappedReason = union(enum) {
    /// A reason in the `a2a-protocol.org` domain that this library does know.
    known: A2aError,
    /// A reason in the `a2a-protocol.org` domain that this library does not know.
    unknown_a2a: []const u8,
    /// A detail from a different domain entirely.
    other_domain: struct { domain: []const u8, reason: []const u8 },
    /// A well-formed reason with no domain at all.
    missing_domain: []const u8,
};

/// Resolve an `ErrorInfo` reason to an A2A error, or to an explicit unmapped
/// variant.
///
/// The domain is checked first, because a reason outside `a2a-protocol.org` is
/// not an A2A error whatever it says. Only then is the reason itself resolved:
/// a known one names its error, and an unknown one stays in its own variant.
pub fn classifyReason(domain: ?[]const u8, reason: []const u8) UnmappedReason {
    const present = domain orelse return .{ .missing_domain = reason };
    if (!std.mem.eql(u8, present, error_domain)) {
        return .{ .other_domain = .{ .domain = present, .reason = reason } };
    }
    if (errorForReason(reason)) |known| return .{ .known = known };
    // A well-formed reason may still be one this library does not know, from a
    // newer revision. It stays in its own variant rather than being mapped onto
    // the closest known error.
    return .{ .unknown_a2a = reason };
}

/// Look up the A2A error a known reason names.
pub fn errorForReason(reason: []const u8) ?A2aError {
    inline for (@typeInfo(A2aError).@"enum".fields) |field| {
        const value: A2aError = @field(A2aError, field.name);
        if (std.mem.eql(u8, reason, value.reason())) return value;
    }
    return null;
}

// --- 5.5 Agent Card ------------------------------------------------------------

/// The field number the proto reserves for the next `AgentCard` field. Field 15
/// is the lowest unused, and the proto's `// Next ID: 20` marker reserves
/// through 19.
pub const agent_card_next_id: i32 = 20;

/// A field of `AgentCard` the specification removed in 1.0 relative to 0.3.
pub const removed_agent_card_fields = [_][]const u8{
    "url",
    "protocolVersion",
    "preferredTransport",
    "additionalInterfaces",
    "supportsAuthenticatedExtendedCard",
};

/// `AgentInterface`, field numbers 1 to 4.
pub const AgentInterface = struct {
    /// 1. Required. Absolute HTTPS in production.
    url: []const u8,
    /// 2. Required. A core binding token or a custom binding URI.
    protocol_binding: []const u8,
    /// 3.
    tenant: ?[]const u8 = null,
    /// 4. Required. `Major.Minor` only, never a patch.
    protocol_version: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "url" },
        .{ .number = 2, .json = "protocolBinding" },
        .{ .number = 3, .json = "tenant" },
        .{ .number = 4, .json = "protocolVersion" },
    };
};

comptime {
    assertFieldTable(AgentInterface);
}

/// `AgentCardSignature`. The `protected` and `signature` members are required;
/// `header` is optional.
pub const AgentCardSignature = struct {
    /// 1. Required. Base64url-encoded JWS protected header.
    protected: []const u8,
    /// 2. Required. Base64url-encoded signature value.
    signature: []const u8,
    /// 3. The JWS unprotected header, as a JSON object rather than base64url.
    header: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "protected" },
        .{ .number = 2, .json = "signature" },
        .{ .number = 3, .json = "header" },
    };
};

comptime {
    assertFieldTable(AgentCardSignature);
}

/// `AgentProvider`, field numbers 1 to 2.
pub const AgentProvider = struct {
    /// 1. Required.
    url: []const u8,
    /// 2. Required.
    organization: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "url" },
        .{ .number = 2, .json = "organization" },
    };
};

comptime {
    assertFieldTable(AgentProvider);
}

/// `AgentCapabilities`, field numbers 1 to 4.
///
/// The three booleans are proto3 `optional`, so they are `?bool` and not
/// `bool`: an agent that did not answer is not an agent that answered no, and
/// only presence records which of the two a peer said.
pub const AgentCapabilities = struct {
    /// 1.
    streaming: ?bool = null,
    /// 2.
    push_notifications: ?bool = null,
    /// 3.
    extensions: []const AgentExtension = &.{},
    /// 4. Gates `GetExtendedAgentCard`.
    extended_agent_card: ?bool = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "streaming" },
        .{ .number = 2, .json = "pushNotifications" },
        .{ .number = 3, .json = "extensions" },
        .{ .number = 4, .json = "extendedAgentCard" },
    };
};

comptime {
    assertFieldTable(AgentCapabilities);
}

/// `AgentExtension`, field numbers 1 to 4.
///
/// No field carries a REQUIRED annotation, not even `uri`, so a peer may
/// declare an extension this library cannot name and a decoder still has to
/// hold the object rather than reject the card.
pub const AgentExtension = struct {
    /// 1. An extension URI. The proto types it a plain `string` and does not
    /// constrain its form, so it is not a URL field.
    uri: ?[]const u8 = null,
    /// 2.
    description: ?[]const u8 = null,
    /// 3. A plain `bool` on the wire, so ProtoJSON rejects `null` for it and a
    /// decoder refuses one. It is `?bool` anyway: false is a flow that proceeds
    /// without the extension, and `"required":false` is what a peer writes when
    /// it means that, so the member is a fact about the document and not only
    /// about the value.
    required: ?bool = null,
    /// 4. Extension settings, kept as the raw JSON the caller borrowed.
    params: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "uri" },
        .{ .number = 2, .json = "description" },
        .{ .number = 3, .json = "required" },
        .{ .number = 4, .json = "params" },
    };
};

comptime {
    assertFieldTable(AgentExtension);
}

/// `AgentSkill`, field numbers 1 to 8.
pub const AgentSkill = struct {
    /// 1. Required. The identifier a message names.
    id: []const u8,
    /// 2. Required.
    name: []const u8,
    /// 3. Required.
    description: []const u8,
    /// 4. Required, and required for the same reason a skill has to say what
    /// it is for: an untagged skill is not discoverable.
    tags: []const []const u8,
    /// 5. Example prompts, which the proto does not require.
    examples: []const []const u8 = &.{},
    /// 6. Narrows `AgentCard.default_input_modes` for this skill.
    input_modes: []const []const u8 = &.{},
    /// 7. Narrows `AgentCard.default_output_modes` for this skill.
    output_modes: []const []const u8 = &.{},
    /// 8. The scopes this skill needs. A skill that asks for a scope the
    /// client did not activate is what `ExtensionSupportRequiredError`
    /// follows from.
    security_requirements: []const SecurityRequirement = &.{},

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "id" },
        .{ .number = 2, .json = "name" },
        .{ .number = 3, .json = "description" },
        .{ .number = 4, .json = "tags" },
        .{ .number = 5, .json = "examples" },
        .{ .number = 6, .json = "inputModes" },
        .{ .number = 7, .json = "outputModes" },
        .{ .number = 8, .json = "securityRequirements" },
    };
};

comptime {
    assertFieldTable(AgentSkill);
}

/// `AgentCard`, field numbers 1 to 14, listed in `fields`.
///
/// Eight fields are REQUIRED and six are not, and those eight carry no default
/// here: a card that omits one is a decode error, not a card the library
/// quietly filled in.
pub const AgentCard = struct {
    /// 1. Required.
    name: []const u8,
    /// 2. Required.
    description: []const u8,
    /// 3. Required and ordered. The first entry is the preferred interface,
    /// so the order is part of the contract, not a convenience.
    supported_interfaces: []const AgentInterface,
    /// 4.
    provider: ?AgentProvider = null,
    /// 5. Required. Never carries a patch component.
    ///
    /// PROTOCOLS.md section 5.1: "Patch versions MUST NOT appear in a request,
    /// a response, or an Agent Card." A card version is otherwise free text, so
    /// `parseVersion` is what a consumer reads it with and `1.0.0` is a value no
    /// peer may send.
    version: []const u8,
    /// 6. `optional` in the proto, so presence is explicit.
    documentation_url: ?[]const u8 = null,
    /// 7. Required.
    capabilities: AgentCapabilities,
    /// 8. Keyed by the scheme name a `SecurityRequirement` names.
    security_schemes: []const SecuritySchemeEntry = &.{},
    /// 9. Each entry is an alternative to the next; the schemes inside one
    /// entry are a conjunction.
    security_requirements: []const SecurityRequirement = &.{},
    /// 10. Required.
    default_input_modes: []const []const u8,
    /// 11. Required.
    default_output_modes: []const []const u8,
    /// 12. Required.
    skills: []const AgentSkill,
    /// 13. A JWS signature over the canonicalized card, `signatures` excluded.
    signatures: []const AgentCardSignature = &.{},
    /// 14. `optional` in the proto, so presence is explicit.
    icon_url: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "name" },
        .{ .number = 2, .json = "description" },
        .{ .number = 3, .json = "supportedInterfaces" },
        .{ .number = 4, .json = "provider" },
        .{ .number = 5, .json = "version" },
        .{ .number = 6, .json = "documentationUrl" },
        .{ .number = 7, .json = "capabilities" },
        .{ .number = 8, .json = "securitySchemes" },
        .{ .number = 9, .json = "securityRequirements" },
        .{ .number = 10, .json = "defaultInputModes" },
        .{ .number = 11, .json = "defaultOutputModes" },
        .{ .number = 12, .json = "skills" },
        .{ .number = 13, .json = "signatures" },
        .{ .number = 14, .json = "iconUrl" },
    };
};

comptime {
    assertFieldTable(AgentCard);
}

// --- 5.7 Security schemes ------------------------------------------------------

/// `StringList`, field 1.
///
/// The JSON name is `list`, singular, because the proto wraps the message in a
/// `protolint:disable REPEATED_FIELD_NAMES_PLURALIZED` directive. A decoder
/// that pluralised the name would read nothing.
pub const StringList = struct {
    /// 1.
    list: []const []const u8 = &.{},

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "list" },
    };
};

comptime {
    assertFieldTable(StringList);
}

/// One `SecurityRequirement.schemes` entry: a scheme name and the scopes it
/// needs.
///
/// A protobuf map reaches the wire as a repeated synthetic message whose field
/// 1 is the key and field 2 is the value. ProtoJSON renders the same entry as
/// the single member the key names, so neither half of this struct is a member
/// of its own and `json` is null on both rows.
pub const SecurityRequirementEntry = struct {
    /// 1, the map key.
    name: []const u8,
    /// 2, the map value.
    list: StringList,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = null, .zig_name = "name" },
        .{ .number = 2, .json = null, .zig_name = "list" },
    };
};

comptime {
    assertFieldTable(SecurityRequirementEntry);
}

/// One `AgentCard.security_schemes` entry: a scheme name and its definition.
///
/// A map entry is the single member the key names in ProtoJSON, so `json` is
/// null on both rows. See `SecurityRequirementEntry`.
pub const SecuritySchemeEntry = struct {
    /// 1, the map key. It is what a `SecurityRequirement` names.
    name: []const u8,
    /// 2, the map value.
    scheme: SecurityScheme,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = null, .zig_name = "name" },
        .{ .number = 2, .json = null, .zig_name = "scheme" },
    };
};

comptime {
    assertFieldTable(SecuritySchemeEntry);
}

/// `SecurityRequirement`, field 1.
///
/// Every scheme named in one requirement must hold, which is what makes a
/// requirement a conjunction. The requirements in a card's list are
/// alternatives to each other.
pub const SecurityRequirement = struct {
    /// 1.
    schemes: []const SecurityRequirementEntry = &.{},

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "schemes" },
    };
};

comptime {
    assertFieldTable(SecurityRequirement);
}

/// `APIKeySecurityScheme.location`, which the proto leaves unconstrained and
/// the receiver must therefore enforce.
pub const ApiKeyLocation = enum {
    query,
    header,
    cookie,

    pub fn parse(text: []const u8) DecodeError!ApiKeyLocation {
        if (std.mem.eql(u8, text, "query")) return .query;
        if (std.mem.eql(u8, text, "header")) return .header;
        if (std.mem.eql(u8, text, "cookie")) return .cookie;
        return error.UnknownTag;
    }

    pub fn string(self: ApiKeyLocation) []const u8 {
        return @tagName(self);
    }
};

/// The `SecurityScheme` `oneof` on `scheme`, section 5.7.
///
/// ProtoJSON spells each member with the full `SecurityScheme` suffix and the
/// Zig member name drops it, so all five rows override the derived name. The
/// proto spells the first one `api_key_security_scheme`, ProtoJSON spells it
/// `apiKeySecurityScheme`, and this library calls it `api_key`.
pub const SecurityScheme = union(enum) {
    /// Variant 1. Requires `location` (2) and `name` (3).
    api_key: ApiKeySecurityScheme,
    /// Variant 2. Requires `scheme` (2).
    http_auth: HttpAuthSecurityScheme,
    /// Variant 3. Requires `flows` (2).
    oauth2: OAuth2SecurityScheme,
    /// Variant 4. Requires `open_id_connect_url` (2).
    open_id_connect: OpenIdConnectSecurityScheme,
    /// Variant 5. Only an optional `description` (1).
    mtls: MutualTlsSecurityScheme,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "apiKeySecurityScheme", .zig_name = "api_key" },
        .{ .number = 2, .json = "httpAuthSecurityScheme", .zig_name = "http_auth" },
        .{ .number = 3, .json = "oauth2SecurityScheme", .zig_name = "oauth2" },
        .{ .number = 4, .json = "openIdConnectSecurityScheme", .zig_name = "open_id_connect" },
        .{ .number = 5, .json = "mtlsSecurityScheme", .zig_name = "mtls" },
    };
};

comptime {
    assertFieldTable(SecurityScheme);
}

/// The `OAuthFlows` `oneof` on `flow`, section 5.7.
pub const OAuthFlows = union(enum) {
    /// 1.
    authorization_code: AuthorizationCodeOAuthFlow,
    /// 2.
    client_credentials: ClientCredentialsOAuthFlow,
    /// 3. Deprecated in favour of authorization code plus PKCE.
    implicit: ImplicitOAuthFlow,
    /// 4. Deprecated in favour of authorization code plus PKCE, or device code.
    password: PasswordOAuthFlow,
    /// 5.
    device_code: DeviceCodeOAuthFlow,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "authorizationCode" },
        .{ .number = 2, .json = "clientCredentials" },
        .{ .number = 3, .json = "implicit" },
        .{ .number = 4, .json = "password" },
        .{ .number = 5, .json = "deviceCode" },
    };
};

comptime {
    assertFieldTable(OAuthFlows);
}

/// One entry of a flow's `scopes`, which the proto types `map<string, string>`.
///
/// The key is a scope name and the value its short description, as in the
/// OpenAPI 3.2 Security Scheme Object this proto mirrors. PROTOCOLS.md
/// section 5.7 does not restate what the value means, so the field names
/// follow the OpenAPI object rather than a second reading of the proto.
///
/// A map entry is the single member the key names in ProtoJSON, so `json` is
/// null on both rows. See `SecurityRequirementEntry`.
pub const OAuthScope = struct {
    /// 1, the map key.
    name: []const u8,
    /// 2, the map value.
    description: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = null, .zig_name = "name" },
        .{ .number = 2, .json = null, .zig_name = "description" },
    };
};

comptime {
    assertFieldTable(OAuthScope);
}

/// `AuthorizationCodeOAuthFlow`, field numbers 1 to 5.
pub const AuthorizationCodeOAuthFlow = struct {
    /// 1. Required.
    authorization_url: []const u8,
    /// 2. Required.
    token_url: []const u8,
    /// 3. Absent when the authorization server issues no refresh token.
    refresh_url: ?[]const u8 = null,
    /// 4. Required. What the flow can obtain, and what a client has to ask
    /// for; an empty list is a flow that authorizes nothing.
    scopes: []const OAuthScope,
    /// 5. A plain `bool`, because the proto declares the field singular and it
    /// therefore has no presence bit. False is a published flow without PKCE,
    /// which is a weaker flow rather than an absent one.
    pkce_required: bool = false,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "authorizationUrl" },
        .{ .number = 2, .json = "tokenUrl" },
        .{ .number = 3, .json = "refreshUrl" },
        .{ .number = 4, .json = "scopes" },
        .{ .number = 5, .json = "pkceRequired" },
    };
};

comptime {
    assertFieldTable(AuthorizationCodeOAuthFlow);
}

/// `ClientCredentialsOAuthFlow`, field numbers 1 to 3.
///
/// There is no authorization URL because there is no user to send: the client
/// is the thing being authorized.
pub const ClientCredentialsOAuthFlow = struct {
    /// 1. Required.
    token_url: []const u8,
    /// 2.
    refresh_url: ?[]const u8 = null,
    /// 3. Required.
    scopes: []const OAuthScope,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tokenUrl" },
        .{ .number = 2, .json = "refreshUrl" },
        .{ .number = 3, .json = "scopes" },
    };
};

comptime {
    assertFieldTable(ClientCredentialsOAuthFlow);
}

/// `ImplicitOAuthFlow`, field numbers 1 to 3. **Deprecated** in the proto,
/// verbatim: "Use Authorization Code + PKCE instead."
///
/// No field is REQUIRED, so a peer may send an empty one and a decoder has to
/// hold it rather than reject the card.
pub const ImplicitOAuthFlow = struct {
    /// 1.
    authorization_url: ?[]const u8 = null,
    /// 2.
    refresh_url: ?[]const u8 = null,
    /// 3.
    scopes: []const OAuthScope = &.{},

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "authorizationUrl" },
        .{ .number = 2, .json = "refreshUrl" },
        .{ .number = 3, .json = "scopes" },
    };
};

comptime {
    assertFieldTable(ImplicitOAuthFlow);
}

/// `PasswordOAuthFlow`, field numbers 1 to 3. **Deprecated** in the proto,
/// verbatim: "Use Authorization Code + PKCE or Device Code."
///
/// No field is REQUIRED, so a peer may send an empty one and a decoder has to
/// hold it rather than reject the card. The deprecation comment is the whole
/// of what the proto says about it.
pub const PasswordOAuthFlow = struct {
    /// 1.
    token_url: ?[]const u8 = null,
    /// 2.
    refresh_url: ?[]const u8 = null,
    /// 3.
    scopes: []const OAuthScope = &.{},

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "tokenUrl" },
        .{ .number = 2, .json = "refreshUrl" },
        .{ .number = 3, .json = "scopes" },
    };
};

comptime {
    assertFieldTable(PasswordOAuthFlow);
}

/// `DeviceCodeOAuthFlow`, field numbers 1 to 4.
///
/// The only flow with a `device_authorization_url`, and the only one that
/// works on a device with no input: it is where the user is sent to type the
/// code the client is displaying.
pub const DeviceCodeOAuthFlow = struct {
    /// 1. Required.
    device_authorization_url: []const u8,
    /// 2. Required.
    token_url: []const u8,
    /// 3.
    refresh_url: ?[]const u8 = null,
    /// 4. Required.
    scopes: []const OAuthScope,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "deviceAuthorizationUrl" },
        .{ .number = 2, .json = "tokenUrl" },
        .{ .number = 3, .json = "refreshUrl" },
        .{ .number = 4, .json = "scopes" },
    };
};

comptime {
    assertFieldTable(DeviceCodeOAuthFlow);
}

pub const ApiKeySecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    location: ApiKeyLocation,
    /// 3. Required.
    name: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "description" },
        .{ .number = 2, .json = "location" },
        .{ .number = 3, .json = "name" },
    };
};

comptime {
    assertFieldTable(ApiKeySecurityScheme);
}

pub const HttpAuthSecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    scheme: []const u8,
    /// 3.
    bearer_format: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "description" },
        .{ .number = 2, .json = "scheme" },
        .{ .number = 3, .json = "bearerFormat" },
    };
};

comptime {
    assertFieldTable(HttpAuthSecurityScheme);
}

pub const OAuth2SecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    flows: OAuthFlows,
    /// 3.
    oauth2_metadata_url: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "description" },
        .{ .number = 2, .json = "flows" },
        .{ .number = 3, .json = "oauth2MetadataUrl" },
    };
};

comptime {
    assertFieldTable(OAuth2SecurityScheme);
}

pub const OpenIdConnectSecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    open_id_connect_url: []const u8,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "description" },
        .{ .number = 2, .json = "openIdConnectUrl" },
    };
};

comptime {
    assertFieldTable(OpenIdConnectSecurityScheme);
}

pub const MutualTlsSecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,

    /// The ProtoJSON name of every field, in field order.
    pub const fields = [_]Field{
        .{ .number = 1, .json = "description" },
    };
};

comptime {
    assertFieldTable(MutualTlsSecurityScheme);
}

// --- 5.8 Extensions ------------------------------------------------------------

/// Split an `A2A-Extensions` value into the extension URIs it activates.
///
/// The value is a comma-separated list, and a header may carry optional
/// whitespace after a comma, so every URI is trimmed of space and horizontal
/// tab. Those are the two characters HTTP defines as optional whitespace; a
/// folded header has already been unfolded by the time it reaches here.
///
/// Returns how many URIs were written to `out`, which the caller sizes. Every
/// URI borrows `raw`, so nothing is allocated and nothing outlives the
/// caller's header buffer.
///
/// An empty element is `error.InvalidField` rather than a skipped entry: a
/// header the peer sent with a URI missing from it is malformed, and dropping
/// the element would leave a caller believing its neighbour was the only
/// activation. A header that is absent is not parsed at all, and one that is
/// present and empty is this error rather than an empty activation list.
pub fn parseExtensions(raw: []const u8, out: [][]const u8) DecodeError!usize {
    var written: usize = 0;
    var elements = std.mem.splitScalar(u8, raw, ',');
    while (elements.next()) |element| {
        const uri = std.mem.trim(u8, element, " \t");
        if (uri.len == 0) return error.InvalidField;
        if (written == out.len) return error.BufferTooSmall;
        out[written] = uri;
        written += 1;
    }
    return written;
}

/// Whether an extension activation list names `uri`.
pub fn activatesExtension(activations: []const []const u8, uri: []const u8) bool {
    for (activations) |activation| {
        if (std.mem.eql(u8, activation, uri)) return true;
    }
    return false;
}

/// Whether a request may proceed given a required extension.
///
/// A missing activation for a `required` extension is `ExtensionSupportRequiredError`,
/// `-32008`. The specification also forbids falling back to another version of
/// an extension automatically, so this is a boolean rather than a negotiation.
pub fn extensionSatisfied(
    activations: []const []const u8,
    required: bool,
    uri: []const u8,
) bool {
    if (activatesExtension(activations, uri)) return true;
    return !required;
}

/// The error a missing required extension produces.
pub const extension_missing_error = A2aError.extension_support_required;

// --- Codec: the flat request and config half -----------------------------------

// What this section carries
//
// Every message below is one with no `Part`, no `Message` and no `Task` in it,
// and every one of them has a decoder and an encoder. The content half is the
// next section, and it is the reason this one stopped where it did: `Part.raw`
// is the only `bytes` field in the module and `json.base64` is what a codec for
// it needs.
//
// Presence, because the round trip is byte-exact
//
// PROTOCOLS.md section 2 makes the encoder the exact inverse of the decoder,
// so a member the wire allows to omit is optional in Zig here and not a plain
// scalar carrying a default. `{"required":false}` and `{}` are two documents,
// and a struct holding one `false` for both cannot write either of them back.
// That is why `AgentExtension.required` is a `?bool` and
// `ListTasksRequest.status` is a `?TaskState`, and why `tenant` is a
// `?[]const u8` on every request below rather than the `[]const u8 = ""` the
// tables above used to declare: a peer that wrote `"tenant":""` is not a peer
// this library may answer with no `tenant` at all.
//
// The rule is not local to this section. Every message in the content half
// follows it too, and nine fields had to change shape before their encoder
// could exist; the next section's note names what it fixed.
//
// A repeated member resolves first-wins
//
// RFC 8259 section 4 says the names within an object *should* be unique, so a
// repeat is a document the grammar permits and a decoder still has to pick
// one. These take the first, for the reason `jsonrpc.decode` gives: a later
// member must not be able to make a comparison that has already failed pass.
// The discarded copy is still read as a value rather than stepped over
// blindly, so a peer cannot hide a syntax error in the second slot of a name
// the first slot already used.
//
// What a decoder does not model
//
// A member no field of a message carries is skipped, and re-encoding therefore
// drops it. That is the same stated consequence `bridge.decodeEnvelope`
// records. It is also why every `Struct` member here is carried as the
// borrowed lexeme it arrived as rather than decoded into a shape: a shape
// cannot write back a key a peer may send.
//
// Every decoder below checks `reader.atEnd()` after its member loop and never
// inside it, so a body that is one JSON value and a second one behind it are
// told apart.

/// Read an `int32` member at the width its field declares.
///
/// ProtoJSON renders a 32-bit integer as a JSON number carrying neither a
/// fraction nor an exponent, so the lexeme `json.Reader.number` scanned is
/// converted here rather than at whatever width the scan covered. A fraction,
/// an exponent or a value above `i32` is `error.InvalidField` and never a
/// truncation: `1.5` is not a page size, and `2147483648` is a number no `int32`
/// field can carry.
fn readInt32(reader: *json.Reader) DecodeError!i32 {
    return std.fmt.parseInt(i32, try reader.number(), 10) catch return error.InvalidField;
}

/// Write an `int32` member.
///
/// The buffer is a local rather than an allocation, and `-2147483648` is the
/// widest value `i32` holds, so eleven bytes is the whole of it.
fn writeInt32(writer: *json.Writer, value: i32) EncodeError!void {
    var digits: [11]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return error.BufferTooSmall;
    try writer.slice(text);
}

/// Read a `repeated string` member into caller-owned storage.
///
/// `out` is the caller's array and `scratch` is the reader's escape buffer, so
/// nothing allocates. A member with more elements than the caller reserved is
/// `error.BufferTooSmall` rather than a truncated list, because a truncated
/// list of accepted modes is a request that says something the caller did not
/// mean. An array carrying no element is well formed and writes nothing.
fn readStringList(reader: *json.Reader, out: [][]const u8, scratch: []u8) DecodeError!usize {
    var count: usize = 0;
    if (try reader.beginArray()) return count;
    while (try reader.nextArrayElement()) {
        if (count == out.len) return error.BufferTooSmall;
        out[count] = try reader.string(scratch);
        count += 1;
    }
    return count;
}

/// Write a `repeated string` member.
fn writeStringList(items: []const []const u8, writer: *json.Writer) EncodeError!void {
    try writer.byte('[');
    for (items, 0..) |item, index| {
        if (index != 0) try writer.byte(',');
        try writer.string(item);
    }
    try writer.byte(']');
}

/// Decode a `google.protobuf.Empty` response body.
///
/// The message declares no field, so every member is one this shape does not
/// model and every one of them is stepped over rather than refused. The delete
/// response is the one body a peer may decorate and still be understood, and a
/// re-encode of a decorated body drops the decoration, which is the stated
/// consequence every decoder in this library records.
pub fn decodeEmpty(raw: []const u8, scratch: []u8) DecodeError!Empty {
    var reader = json.Reader.init(raw);
    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |_| {
            try reader.skipValue(scratch);
        }
    }
    // The body is one JSON value. Bytes behind the closing brace are a second
    // document the transport did not split, and a codec that accepted them
    // would re-encode the body without them.
    if (!reader.atEnd()) return error.MalformedJson;
    return .{};
}

/// Encode a `google.protobuf.Empty` response body.
pub fn encodeEmpty(_: Empty, writer: *json.Writer) EncodeError!void {
    try writer.slice("{}");
}

/// Decode a `GetTaskRequest`.
///
/// `id` is the only REQUIRED member, and an empty one is refused for the
/// reason `TaskStatusUpdateEvent.context_id` carries no default: an empty id
/// is not a task. `historyLength` is `optional int32` in the proto and is
/// carried as a presence here, so `"historyLength":0` and no `historyLength`
/// are two requests and both survive a round trip.
pub fn decodeGetTaskRequest(raw: []const u8, scratch: []u8) DecodeError!GetTaskRequest {
    var reader = json.Reader.init(raw);
    var request: GetTaskRequest = .{ .id = "" };
    var saw_id = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "tenant")) {
            if (request.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                request.tenant = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "id")) {
            if (saw_id) {
                try reader.skipValue(scratch);
            } else {
                request.id = try reader.string(scratch);
                saw_id = true;
            }
        } else if (std.mem.eql(u8, key, "historyLength")) {
            if (request.history_length != null) {
                try reader.skipValue(scratch);
            } else {
                request.history_length = try readInt32(&reader);
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_id) return error.MissingField;
    // `encodeGetTaskRequest` refuses an empty `id` too, so a caller that
    // decoded one can always write it back.
    if (request.id.len == 0) return error.InvalidField;
    return request;
}

/// Encode a `GetTaskRequest`.
///
/// Members go out in field-number order, so a body that already reads in that
/// order comes back unchanged and one that does not comes back with the same
/// members in it. `bridge.encodeEnvelope` is the same rule for the same reason.
pub fn encodeGetTaskRequest(request: GetTaskRequest, writer: *json.Writer) EncodeError!void {
    if (request.id.len == 0) return error.InvalidField;

    try writer.byte('{');
    // The separator is written in front of each member rather than baked into
    // it, because `tenant` is optional and a comma where it stood is a
    // document no reader is right to accept.
    var separator: []const u8 = "";
    if (request.tenant) |tenant| {
        try writer.slice(separator);
        try writer.slice("\"tenant\":");
        try writer.string(tenant);
        separator = ",";
    }
    try writer.slice(separator);
    try writer.slice("\"id\":");
    try writer.string(request.id);
    if (request.history_length) |history_length| {
        try writer.slice(",\"historyLength\":");
        try writeInt32(writer, history_length);
    }
    try writer.byte('}');
}

/// Decode a `CancelTaskRequest`.
///
/// `metadata` is a `google.protobuf.Struct`, and it is carried as the borrowed
/// lexeme rather than decoded into a shape. A shape cannot write back a key a
/// peer may send, which is the defect `bridge.Envelope.meta` exists to remove,
/// and borrowing costs no scratch however deeply the object nests.
pub fn decodeCancelTaskRequest(raw: []const u8, scratch: []u8) DecodeError!CancelTaskRequest {
    var reader = json.Reader.init(raw);
    var request: CancelTaskRequest = .{ .id = "" };
    var saw_id = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "tenant")) {
            if (request.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                request.tenant = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "id")) {
            if (saw_id) {
                try reader.skipValue(scratch);
            } else {
                request.id = try reader.string(scratch);
                saw_id = true;
            }
        } else if (std.mem.eql(u8, key, "metadata")) {
            if (request.metadata != null) {
                try reader.skipValue(scratch);
            } else {
                request.metadata = try reader.rawValue(scratch);
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_id) return error.MissingField;
    if (request.id.len == 0) return error.InvalidField;
    return request;
}

/// Encode a `CancelTaskRequest`.
pub fn encodeCancelTaskRequest(request: CancelTaskRequest, writer: *json.Writer) EncodeError!void {
    if (request.id.len == 0) return error.InvalidField;

    try writer.byte('{');
    var separator: []const u8 = "";
    if (request.tenant) |tenant| {
        try writer.slice(separator);
        try writer.slice("\"tenant\":");
        try writer.string(tenant);
        separator = ",";
    }
    try writer.slice(separator);
    try writer.slice("\"id\":");
    try writer.string(request.id);
    if (request.metadata) |metadata| {
        try writer.slice(",\"metadata\":");
        try writer.slice(metadata);
    }
    try writer.byte('}');
}

/// Decode a `SubscribeToTaskRequest`.
///
/// The message declares two members and one of them is REQUIRED, so an empty
/// object is not a subscription.
pub fn decodeSubscribeToTaskRequest(
    raw: []const u8,
    scratch: []u8,
) DecodeError!SubscribeToTaskRequest {
    var reader = json.Reader.init(raw);
    var request: SubscribeToTaskRequest = .{ .id = "" };
    var saw_id = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "tenant")) {
            if (request.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                request.tenant = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "id")) {
            if (saw_id) {
                try reader.skipValue(scratch);
            } else {
                request.id = try reader.string(scratch);
                saw_id = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_id) return error.MissingField;
    if (request.id.len == 0) return error.InvalidField;
    return request;
}

/// Encode a `SubscribeToTaskRequest`.
pub fn encodeSubscribeToTaskRequest(
    request: SubscribeToTaskRequest,
    writer: *json.Writer,
) EncodeError!void {
    if (request.id.len == 0) return error.InvalidField;

    try writer.byte('{');
    if (request.tenant) |tenant| {
        try writer.slice("\"tenant\":");
        try writer.string(tenant);
        try writer.byte(',');
    }
    try writer.slice("\"id\":");
    try writer.string(request.id);
    try writer.byte('}');
}

/// Decode a `GetTaskPushNotificationConfigRequest`.
///
/// `taskId` and `id` are both REQUIRED, and both name something: the task a
/// config belongs to, and the config within it. Neither may be empty.
pub fn decodeGetTaskPushNotificationConfigRequest(
    raw: []const u8,
    scratch: []u8,
) DecodeError!GetTaskPushNotificationConfigRequest {
    var reader = json.Reader.init(raw);
    var request: GetTaskPushNotificationConfigRequest = .{ .task_id = "", .id = "" };
    var saw_task_id = false;
    var saw_id = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "tenant")) {
            if (request.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                request.tenant = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "taskId")) {
            if (saw_task_id) {
                try reader.skipValue(scratch);
            } else {
                request.task_id = try reader.string(scratch);
                saw_task_id = true;
            }
        } else if (std.mem.eql(u8, key, "id")) {
            if (saw_id) {
                try reader.skipValue(scratch);
            } else {
                request.id = try reader.string(scratch);
                saw_id = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_task_id or !saw_id) return error.MissingField;
    if (request.task_id.len == 0 or request.id.len == 0) return error.InvalidField;
    return request;
}

/// Encode a `GetTaskPushNotificationConfigRequest`.
pub fn encodeGetTaskPushNotificationConfigRequest(
    request: GetTaskPushNotificationConfigRequest,
    writer: *json.Writer,
) EncodeError!void {
    if (request.task_id.len == 0 or request.id.len == 0) return error.InvalidField;

    try writer.byte('{');
    if (request.tenant) |tenant| {
        try writer.slice("\"tenant\":");
        try writer.string(tenant);
        try writer.byte(',');
    }
    try writer.slice("\"taskId\":");
    try writer.string(request.task_id);
    try writer.slice(",\"id\":");
    try writer.string(request.id);
    try writer.byte('}');
}

/// Decode a `DeleteTaskPushNotificationConfigRequest`.
pub fn decodeDeleteTaskPushNotificationConfigRequest(
    raw: []const u8,
    scratch: []u8,
) DecodeError!DeleteTaskPushNotificationConfigRequest {
    var reader = json.Reader.init(raw);
    var request: DeleteTaskPushNotificationConfigRequest = .{ .task_id = "", .id = "" };
    var saw_task_id = false;
    var saw_id = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "tenant")) {
            if (request.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                request.tenant = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "taskId")) {
            if (saw_task_id) {
                try reader.skipValue(scratch);
            } else {
                request.task_id = try reader.string(scratch);
                saw_task_id = true;
            }
        } else if (std.mem.eql(u8, key, "id")) {
            if (saw_id) {
                try reader.skipValue(scratch);
            } else {
                request.id = try reader.string(scratch);
                saw_id = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_task_id or !saw_id) return error.MissingField;
    if (request.task_id.len == 0 or request.id.len == 0) return error.InvalidField;
    return request;
}

/// Encode a `DeleteTaskPushNotificationConfigRequest`.
pub fn encodeDeleteTaskPushNotificationConfigRequest(
    request: DeleteTaskPushNotificationConfigRequest,
    writer: *json.Writer,
) EncodeError!void {
    if (request.task_id.len == 0 or request.id.len == 0) return error.InvalidField;

    try writer.byte('{');
    if (request.tenant) |tenant| {
        try writer.slice("\"tenant\":");
        try writer.string(tenant);
        try writer.byte(',');
    }
    try writer.slice("\"taskId\":");
    try writer.string(request.task_id);
    try writer.slice(",\"id\":");
    try writer.string(request.id);
    try writer.byte('}');
}

/// Decode a `ListTaskPushNotificationConfigsRequest`.
///
/// `pageSize` is a plain `int32` here rather than the `optional int32` of
/// `ListTasksRequest`, and it is still carried as presence, because
/// `"pageSize":0` and no `pageSize` are the same page and two different
/// documents. `tenant` is field 4 in the proto although the source lists it
/// first, so it is written last here too.
pub fn decodeListTaskPushNotificationConfigsRequest(
    raw: []const u8,
    scratch: []u8,
) DecodeError!ListTaskPushNotificationConfigsRequest {
    var reader = json.Reader.init(raw);
    var request: ListTaskPushNotificationConfigsRequest = .{ .task_id = "" };
    var saw_task_id = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "taskId")) {
            if (saw_task_id) {
                try reader.skipValue(scratch);
            } else {
                request.task_id = try reader.string(scratch);
                saw_task_id = true;
            }
        } else if (std.mem.eql(u8, key, "pageSize")) {
            if (request.page_size != null) {
                try reader.skipValue(scratch);
            } else {
                request.page_size = try readInt32(&reader);
            }
        } else if (std.mem.eql(u8, key, "pageToken")) {
            if (request.page_token != null) {
                try reader.skipValue(scratch);
            } else {
                request.page_token = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "tenant")) {
            if (request.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                request.tenant = try reader.string(scratch);
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_task_id) return error.MissingField;
    if (request.task_id.len == 0) return error.InvalidField;
    return request;
}

/// Encode a `ListTaskPushNotificationConfigsRequest`.
pub fn encodeListTaskPushNotificationConfigsRequest(
    request: ListTaskPushNotificationConfigsRequest,
    writer: *json.Writer,
) EncodeError!void {
    if (request.task_id.len == 0) return error.InvalidField;

    try writer.slice("{\"taskId\":");
    try writer.string(request.task_id);
    if (request.page_size) |page_size| {
        try writer.slice(",\"pageSize\":");
        try writeInt32(writer, page_size);
    }
    if (request.page_token) |page_token| {
        try writer.slice(",\"pageToken\":");
        try writer.string(page_token);
    }
    if (request.tenant) |tenant| {
        try writer.slice(",\"tenant\":");
        try writer.string(tenant);
    }
    try writer.byte('}');
}

/// Decode a `GetExtendedAgentCardRequest`.
///
/// The message declares one member and it is optional, so `{}` is a complete
/// request: the card of the agent the caller reached, with no tenant segment.
pub fn decodeGetExtendedAgentCardRequest(
    raw: []const u8,
    scratch: []u8,
) DecodeError!GetExtendedAgentCardRequest {
    var reader = json.Reader.init(raw);
    var request: GetExtendedAgentCardRequest = .{};

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "tenant")) {
                if (request.tenant != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.tenant = try reader.string(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;
    return request;
}

/// Encode a `GetExtendedAgentCardRequest`.
pub fn encodeGetExtendedAgentCardRequest(
    request: GetExtendedAgentCardRequest,
    writer: *json.Writer,
) EncodeError!void {
    if (request.tenant) |tenant| {
        try writer.slice("{\"tenant\":");
        try writer.string(tenant);
        try writer.byte('}');
        return;
    }
    try writer.slice("{}");
}

/// Decode a `ListTasksRequest`.
///
/// No member of this request is REQUIRED, so `{}` is a complete one: the
/// first page of everything the tenant holds. `status` is a singular
/// `TaskState` in the proto and is carried as presence anyway, because
/// `"status":"TASK_STATE_UNSPECIFIED"` is a peer that filtered on an
/// unspecified state and no member is a peer that did not filter at all.
/// `statusTimestampAfter` is the ISO-8601 text the peer wrote: there is no
/// `Timestamp` here to convert, and a normalised spelling of the same instant
/// would not be the bytes that came in.
pub fn decodeListTasksRequest(raw: []const u8, scratch: []u8) DecodeError!ListTasksRequest {
    var reader = json.Reader.init(raw);
    var request: ListTasksRequest = .{};

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "tenant")) {
                if (request.tenant != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.tenant = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "contextId")) {
                if (request.context_id != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.context_id = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "status")) {
                if (request.status != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.status = try TaskState.parse(try reader.string(scratch));
                }
            } else if (std.mem.eql(u8, key, "pageSize")) {
                if (request.page_size != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.page_size = try readInt32(&reader);
                }
            } else if (std.mem.eql(u8, key, "pageToken")) {
                if (request.page_token != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.page_token = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "historyLength")) {
                if (request.history_length != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.history_length = try readInt32(&reader);
                }
            } else if (std.mem.eql(u8, key, "statusTimestampAfter")) {
                if (request.status_timestamp_after != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.status_timestamp_after = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "includeArtifacts")) {
                if (request.include_artifacts != null) {
                    try reader.skipValue(scratch);
                } else {
                    request.include_artifacts = try reader.boolean();
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;
    return request;
}

/// Encode a `ListTasksRequest`.
///
/// `status` goes out as the full proto name, because that is the spelling
/// `TaskState.parse` accepts and the only one a peer sends.
pub fn encodeListTasksRequest(request: ListTasksRequest, writer: *json.Writer) EncodeError!void {
    try writer.byte('{');
    var separator: []const u8 = "";
    if (request.tenant) |tenant| {
        try writer.slice(separator);
        try writer.slice("\"tenant\":");
        try writer.string(tenant);
        separator = ",";
    }
    if (request.context_id) |context_id| {
        try writer.slice(separator);
        try writer.slice("\"contextId\":");
        try writer.string(context_id);
        separator = ",";
    }
    if (request.status) |status| {
        try writer.slice(separator);
        try writer.slice("\"status\":");
        try writer.string(status.wireName());
        separator = ",";
    }
    if (request.page_size) |page_size| {
        try writer.slice(separator);
        try writer.slice("\"pageSize\":");
        try writeInt32(writer, page_size);
        separator = ",";
    }
    if (request.page_token) |page_token| {
        try writer.slice(separator);
        try writer.slice("\"pageToken\":");
        try writer.string(page_token);
        separator = ",";
    }
    if (request.history_length) |history_length| {
        try writer.slice(separator);
        try writer.slice("\"historyLength\":");
        try writeInt32(writer, history_length);
        separator = ",";
    }
    if (request.status_timestamp_after) |after| {
        try writer.slice(separator);
        try writer.slice("\"statusTimestampAfter\":");
        try writer.string(after);
        separator = ",";
    }
    if (request.include_artifacts) |include_artifacts| {
        try writer.slice(separator);
        try writer.slice("\"includeArtifacts\":");
        try writer.slice(if (include_artifacts) "true" else "false");
    }
    try writer.byte('}');
}

/// Decode an `AuthenticationInfo`.
///
/// `scheme` is the only REQUIRED member. `credentials` stays optional rather
/// than defaulting to the empty string, because the two are different
/// requests: no credential is a scheme sent without a secret, and an empty
/// credential is a secret that happens to be blank.
pub fn decodeAuthenticationInfo(raw: []const u8, scratch: []u8) DecodeError!AuthenticationInfo {
    var reader = json.Reader.init(raw);
    const info = try readAuthenticationInfo(&reader, scratch);
    // The message is one JSON value, and the walk above stopped at its closing
    // brace rather than at the end of the document.
    if (!reader.atEnd()) return error.MalformedJson;
    return info;
}

/// The walk `decodeAuthenticationInfo` opens, so a nested member can share its
/// reader. The scratch bump is per reader, so the strings this hands out are
/// regions of their own and not of the ones already handed out.
fn readAuthenticationInfo(
    reader: *json.Reader,
    scratch: []u8,
) DecodeError!AuthenticationInfo {
    var info: AuthenticationInfo = .{ .scheme = "" };
    var saw_scheme = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "scheme")) {
            if (saw_scheme) {
                try reader.skipValue(scratch);
            } else {
                info.scheme = try reader.string(scratch);
                saw_scheme = true;
            }
        } else if (std.mem.eql(u8, key, "credentials")) {
            if (info.credentials != null) {
                try reader.skipValue(scratch);
            } else {
                info.credentials = try reader.string(scratch);
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!saw_scheme) return error.MissingField;
    if (info.scheme.len == 0) return error.InvalidField;
    return info;
}

/// Encode an `AuthenticationInfo`.
pub fn encodeAuthenticationInfo(info: AuthenticationInfo, writer: *json.Writer) EncodeError!void {
    if (info.scheme.len == 0) return error.InvalidField;

    try writer.slice("{\"scheme\":");
    try writer.string(info.scheme);
    if (info.credentials) |credentials| {
        try writer.slice(",\"credentials\":");
        try writer.string(credentials);
    }
    try writer.byte('}');
}

/// Decode a `TaskPushNotificationConfig`.
///
/// This one message is the create-request body, the create response, and the
/// get and list response, so the decoder has to hold every member the three
/// uses carry. `url` is the only REQUIRED member and is where the agent posts
/// the `StreamResponse`; an empty URL is not a webhook and is refused.
pub fn decodeTaskPushNotificationConfig(
    raw: []const u8,
    scratch: []u8,
) DecodeError!TaskPushNotificationConfig {
    var reader = json.Reader.init(raw);
    const config = try readTaskPushNotificationConfig(&reader, scratch);
    // The configuration is one JSON value, and the `authentication` walk above
    // stopped at its closing brace rather than at the end of the document.
    if (!reader.atEnd()) return error.MalformedJson;
    return config;
}

/// The walk `decodeTaskPushNotificationConfig` opens, so
/// `decodeSendMessageConfiguration` can read one nested beside its own members
/// on the same reader.
fn readTaskPushNotificationConfig(
    reader: *json.Reader,
    scratch: []u8,
) DecodeError!TaskPushNotificationConfig {
    var config: TaskPushNotificationConfig = .{ .url = "" };
    var saw_url = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "tenant")) {
            if (config.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                config.tenant = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "id")) {
            if (config.id != null) {
                try reader.skipValue(scratch);
            } else {
                config.id = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "taskId")) {
            if (config.task_id != null) {
                try reader.skipValue(scratch);
            } else {
                config.task_id = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "url")) {
            if (saw_url) {
                try reader.skipValue(scratch);
            } else {
                config.url = try reader.string(scratch);
                saw_url = true;
            }
        } else if (std.mem.eql(u8, key, "token")) {
            if (config.token != null) {
                try reader.skipValue(scratch);
            } else {
                config.token = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "authentication")) {
            if (config.authentication != null) {
                try reader.skipValue(scratch);
            } else {
                if (try isNullMember(reader)) {
                    // `null` and an absent member agree here: the normative
                    // row types this member as a message, and a configuration
                    // with no authentication sends none rather than an empty
                    // one.
                } else {
                    config.authentication = try readAuthenticationInfo(reader, scratch);
                }
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!saw_url) return error.MissingField;
    if (config.url.len == 0) return error.InvalidField;
    return config;
}

/// Encode a `TaskPushNotificationConfig`.
pub fn encodeTaskPushNotificationConfig(
    config: TaskPushNotificationConfig,
    writer: *json.Writer,
) EncodeError!void {
    if (config.url.len == 0) return error.InvalidField;

    try writer.byte('{');
    var separator: []const u8 = "";
    if (config.tenant) |tenant| {
        try writer.slice(separator);
        try writer.slice("\"tenant\":");
        try writer.string(tenant);
        separator = ",";
    }
    if (config.id) |id| {
        try writer.slice(separator);
        try writer.slice("\"id\":");
        try writer.string(id);
        separator = ",";
    }
    if (config.task_id) |task_id| {
        try writer.slice(separator);
        try writer.slice("\"taskId\":");
        try writer.string(task_id);
        separator = ",";
    }
    try writer.slice(separator);
    try writer.slice("\"url\":");
    try writer.string(config.url);
    if (config.token) |token| {
        try writer.slice(",\"token\":");
        try writer.string(token);
    }
    if (config.authentication) |authentication| {
        try writer.slice(",\"authentication\":");
        try encodeAuthenticationInfo(authentication, writer);
    }
    try writer.byte('}');
}

/// Decode a `SendMessageConfiguration`.
///
/// `out_modes` is the caller's array of media types and `scratch` is the
/// reader's escape buffer, so nothing allocates. The order is the one
/// `acp.decodePermissionRequest` takes for the same reason: a configuration
/// with more accepted modes than the caller reserved is reported rather than
/// truncated, because a truncated list of accepted modes is a request that
/// says something the caller did not mean.
///
/// An absent `acceptedOutputModes` and an empty one are both carried, and the
/// two are told apart: the field is null for the first and a zero-length slice
/// for the second, and the encoder writes `[]` for the one and nothing for the
/// other.
pub fn decodeSendMessageConfiguration(
    raw: []const u8,
    out_modes: [][]const u8,
    scratch: []u8,
) DecodeError!SendMessageConfiguration {
    var reader = json.Reader.init(raw);
    var used: usize = 0;
    const configuration = try readSendMessageConfiguration(&reader, out_modes, &used, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return configuration;
}

/// The walk `decodeSendMessageConfiguration` opens, so `readSendMessageRequest`
/// can read one nested beside its own members on the same reader.
///
/// `used` is how much of `out` is already spoken for, which is what lets the
/// same walk fill a caller's own array and a `ContentArena.strings` it shares
/// with every other `repeated string` in a document. One walk, two callers, and
/// no second copy of the rule that `[]` and no member are told apart.
fn readSendMessageConfiguration(
    reader: *json.Reader,
    out: [][]const u8,
    used: *usize,
    scratch: []u8,
) DecodeError!SendMessageConfiguration {
    var configuration: SendMessageConfiguration = .{};

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "acceptedOutputModes")) {
                if (configuration.accepted_output_modes != null) {
                    try reader.skipValue(scratch);
                } else {
                    const count = try readStringList(reader, out[used.*..], scratch);
                    configuration.accepted_output_modes = out[used.*..][0..count];
                    used.* += count;
                }
            } else if (std.mem.eql(u8, key, "taskPushNotificationConfig")) {
                if (configuration.task_push_notification_config != null) {
                    try reader.skipValue(scratch);
                } else {
                    if (try isNullMember(reader)) {
                        // `null` and an absent member agree here, for the same
                        // reason `authentication` above does.
                    } else {
                        configuration.task_push_notification_config =
                            try readTaskPushNotificationConfig(reader, scratch);
                    }
                }
            } else if (std.mem.eql(u8, key, "historyLength")) {
                if (configuration.history_length != null) {
                    try reader.skipValue(scratch);
                } else {
                    configuration.history_length = try readInt32(reader);
                }
            } else if (std.mem.eql(u8, key, "returnImmediately")) {
                if (configuration.return_immediately != null) {
                    try reader.skipValue(scratch);
                } else {
                    configuration.return_immediately = try reader.boolean();
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    return configuration;
}

/// Encode a `SendMessageConfiguration`.
pub fn encodeSendMessageConfiguration(
    configuration: SendMessageConfiguration,
    writer: *json.Writer,
) EncodeError!void {
    try writeSendMessageConfiguration(configuration, writer);
}

/// The write half, so `writeSendMessageRequest` can place a configuration
/// beside its own members without a second walk of it.
fn writeSendMessageConfiguration(
    configuration: SendMessageConfiguration,
    writer: *json.Writer,
) EncodeError!void {
    try writer.byte('{');
    var separator: []const u8 = "";
    if (configuration.accepted_output_modes) |modes| {
        try writer.slice(separator);
        try writeMemberName(SendMessageConfiguration, 0, writer);
        try writeStringList(modes, writer);
        separator = ",";
    }
    if (configuration.task_push_notification_config) |config| {
        try writer.slice(separator);
        try writeMemberName(SendMessageConfiguration, 1, writer);
        try encodeTaskPushNotificationConfig(config, writer);
        separator = ",";
    }
    if (configuration.history_length) |history_length| {
        try writer.slice(separator);
        try writeMemberName(SendMessageConfiguration, 2, writer);
        try writeInt32(writer, history_length);
        separator = ",";
    }
    if (configuration.return_immediately) |return_immediately| {
        try writer.slice(separator);
        try writeMemberName(SendMessageConfiguration, 3, writer);
        try writer.slice(if (return_immediately) "true" else "false");
    }
    try writer.byte('}');
}

/// Decode an `AgentInterface`.
///
/// Three of the four members are REQUIRED and none of them may be empty. The
/// version is not parsed here: PROTOCOLS.md section 5.1 forbids a patch
/// component in a card, so `parseVersion` is what a consumer reads the
/// declared text with, and this decoder keeps the bytes so a re-encode puts
/// back what the agent published.
pub fn decodeAgentInterface(raw: []const u8, scratch: []u8) DecodeError!AgentInterface {
    var reader = json.Reader.init(raw);
    var interface: AgentInterface = .{
        .url = "",
        .protocol_binding = "",
        .protocol_version = "",
    };
    var saw_url = false;
    var saw_binding = false;
    var saw_version = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "url")) {
            if (saw_url) {
                try reader.skipValue(scratch);
            } else {
                interface.url = try reader.string(scratch);
                saw_url = true;
            }
        } else if (std.mem.eql(u8, key, "protocolBinding")) {
            if (saw_binding) {
                try reader.skipValue(scratch);
            } else {
                interface.protocol_binding = try reader.string(scratch);
                saw_binding = true;
            }
        } else if (std.mem.eql(u8, key, "tenant")) {
            if (interface.tenant != null) {
                try reader.skipValue(scratch);
            } else {
                interface.tenant = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "protocolVersion")) {
            if (saw_version) {
                try reader.skipValue(scratch);
            } else {
                interface.protocol_version = try reader.string(scratch);
                saw_version = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_url or !saw_binding or !saw_version) return error.MissingField;
    if (interface.url.len == 0 or interface.protocol_binding.len == 0) return error.InvalidField;
    if (interface.protocol_version.len == 0) return error.InvalidField;
    return interface;
}

/// Encode an `AgentInterface`.
pub fn encodeAgentInterface(
    interface: AgentInterface,
    writer: *json.Writer,
) EncodeError!void {
    if (interface.url.len == 0 or interface.protocol_binding.len == 0) return error.InvalidField;
    if (interface.protocol_version.len == 0) return error.InvalidField;

    try writer.slice("{\"url\":");
    try writer.string(interface.url);
    try writer.slice(",\"protocolBinding\":");
    try writer.string(interface.protocol_binding);
    if (interface.tenant) |tenant| {
        try writer.slice(",\"tenant\":");
        try writer.string(tenant);
    }
    try writer.slice(",\"protocolVersion\":");
    try writer.string(interface.protocol_version);
    try writer.byte('}');
}

/// Decode an `AgentProvider`.
pub fn decodeAgentProvider(raw: []const u8, scratch: []u8) DecodeError!AgentProvider {
    var reader = json.Reader.init(raw);
    var provider: AgentProvider = .{ .url = "", .organization = "" };
    var saw_url = false;
    var saw_organization = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "url")) {
            if (saw_url) {
                try reader.skipValue(scratch);
            } else {
                provider.url = try reader.string(scratch);
                saw_url = true;
            }
        } else if (std.mem.eql(u8, key, "organization")) {
            if (saw_organization) {
                try reader.skipValue(scratch);
            } else {
                provider.organization = try reader.string(scratch);
                saw_organization = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_url or !saw_organization) return error.MissingField;
    if (provider.url.len == 0 or provider.organization.len == 0) return error.InvalidField;
    return provider;
}

/// Encode an `AgentProvider`.
pub fn encodeAgentProvider(provider: AgentProvider, writer: *json.Writer) EncodeError!void {
    if (provider.url.len == 0 or provider.organization.len == 0) return error.InvalidField;

    try writer.slice("{\"url\":");
    try writer.string(provider.url);
    try writer.slice(",\"organization\":");
    try writer.string(provider.organization);
    try writer.byte('}');
}

/// Decode an `AgentCardSignature`.
///
/// `header` is the JWS unprotected header and ProtoJSON spells it as a JSON
/// object rather than base64url, so it is carried as the borrowed lexeme it
/// arrived as. `protected` and `signature` stay as the base64url text: this is
/// not a `bytes` field and there is nothing to convert.
pub fn decodeAgentCardSignature(
    raw: []const u8,
    scratch: []u8,
) DecodeError!AgentCardSignature {
    var reader = json.Reader.init(raw);
    var signature: AgentCardSignature = .{ .protected = "", .signature = "" };
    var saw_protected = false;
    var saw_signature = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "protected")) {
            if (saw_protected) {
                try reader.skipValue(scratch);
            } else {
                signature.protected = try reader.string(scratch);
                saw_protected = true;
            }
        } else if (std.mem.eql(u8, key, "signature")) {
            if (saw_signature) {
                try reader.skipValue(scratch);
            } else {
                signature.signature = try reader.string(scratch);
                saw_signature = true;
            }
        } else if (std.mem.eql(u8, key, "header")) {
            if (signature.header != null) {
                try reader.skipValue(scratch);
            } else {
                signature.header = try reader.rawValue(scratch);
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_protected or !saw_signature) return error.MissingField;
    if (signature.protected.len == 0 or signature.signature.len == 0) return error.InvalidField;
    return signature;
}

/// Encode an `AgentCardSignature`.
pub fn encodeAgentCardSignature(
    signature: AgentCardSignature,
    writer: *json.Writer,
) EncodeError!void {
    if (signature.protected.len == 0 or signature.signature.len == 0) return error.InvalidField;

    try writer.slice("{\"protected\":");
    try writer.string(signature.protected);
    try writer.slice(",\"signature\":");
    try writer.string(signature.signature);
    if (signature.header) |header| {
        try writer.slice(",\"header\":");
        try writer.slice(header);
    }
    try writer.byte('}');
}

/// Decode an `AgentExtension`.
///
/// No field carries a REQUIRED annotation, not even `uri`, so a peer may
/// declare an extension this library cannot name and `{}` is still an
/// extension. `params` is a `google.protobuf.Struct` and is carried as the
/// borrowed lexeme, so a setting this library does not model survives the
/// round trip; `required` is recorded as presence, so a peer that wrote
/// `"required":false` gets that member back rather than none.
pub fn decodeAgentExtension(raw: []const u8, scratch: []u8) DecodeError!AgentExtension {
    var reader = json.Reader.init(raw);
    var extension: AgentExtension = .{};

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "uri")) {
                if (extension.uri != null) {
                    try reader.skipValue(scratch);
                } else {
                    extension.uri = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "description")) {
                if (extension.description != null) {
                    try reader.skipValue(scratch);
                } else {
                    extension.description = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "required")) {
                if (extension.required != null) {
                    try reader.skipValue(scratch);
                } else {
                    extension.required = try reader.boolean();
                }
            } else if (std.mem.eql(u8, key, "params")) {
                if (extension.params != null) {
                    try reader.skipValue(scratch);
                } else {
                    extension.params = try reader.rawValue(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;
    return extension;
}

/// Encode an `AgentExtension`.
pub fn encodeAgentExtension(extension: AgentExtension, writer: *json.Writer) EncodeError!void {
    try writer.byte('{');
    var separator: []const u8 = "";
    if (extension.uri) |uri| {
        try writer.slice(separator);
        try writer.slice("\"uri\":");
        try writer.string(uri);
        separator = ",";
    }
    if (extension.description) |description| {
        try writer.slice(separator);
        try writer.slice("\"description\":");
        try writer.string(description);
        separator = ",";
    }
    if (extension.required) |required| {
        try writer.slice(separator);
        try writer.slice("\"required\":");
        try writer.slice(if (required) "true" else "false");
        separator = ",";
    }
    if (extension.params) |params| {
        try writer.slice(separator);
        try writer.slice("\"params\":");
        try writer.slice(params);
    }
    try writer.byte('}');
}

/// Decode an `ApiKeySecurityScheme`.
///
/// This is one of the four `SecurityScheme` arms that stand alone. The
/// `oauth2` arm does not, because it reaches `OAuthFlows`, whose `scopes` is a
/// `map<string, string>`: that walk is over keys rather than member names, so
/// `findField` is the wrong tool for it and the union above has no codec until
/// that arm has one. These four are decoded as the messages they are, which is
/// what a caller holding one entry of a card's `securitySchemes` needs.
pub fn decodeApiKeySecurityScheme(
    raw: []const u8,
    scratch: []u8,
) DecodeError!ApiKeySecurityScheme {
    var reader = json.Reader.init(raw);
    var scheme: ApiKeySecurityScheme = .{ .location = .query, .name = "" };
    var saw_location = false;
    var saw_name = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "description")) {
            if (scheme.description != null) {
                try reader.skipValue(scratch);
            } else {
                scheme.description = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "location")) {
            if (saw_location) {
                try reader.skipValue(scratch);
            } else {
                scheme.location = try ApiKeyLocation.parse(try reader.string(scratch));
                saw_location = true;
            }
        } else if (std.mem.eql(u8, key, "name")) {
            if (saw_name) {
                try reader.skipValue(scratch);
            } else {
                scheme.name = try reader.string(scratch);
                saw_name = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_location or !saw_name) return error.MissingField;
    // An empty header name names no header, and a query parameter with no name
    // is not a credential the receiver can read.
    if (scheme.name.len == 0) return error.InvalidField;
    return scheme;
}

/// Encode an `ApiKeySecurityScheme`.
pub fn encodeApiKeySecurityScheme(
    scheme: ApiKeySecurityScheme,
    writer: *json.Writer,
) EncodeError!void {
    if (scheme.name.len == 0) return error.InvalidField;

    try writer.byte('{');
    if (scheme.description) |description| {
        try writer.slice("\"description\":");
        try writer.string(description);
        try writer.byte(',');
    }
    try writer.slice("\"location\":");
    try writer.string(scheme.location.string());
    try writer.slice(",\"name\":");
    try writer.string(scheme.name);
    try writer.byte('}');
}

/// Decode an `HttpAuthSecurityScheme`.
pub fn decodeHttpAuthSecurityScheme(
    raw: []const u8,
    scratch: []u8,
) DecodeError!HttpAuthSecurityScheme {
    var reader = json.Reader.init(raw);
    var scheme: HttpAuthSecurityScheme = .{ .scheme = "" };
    var saw_scheme = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "description")) {
            if (scheme.description != null) {
                try reader.skipValue(scratch);
            } else {
                scheme.description = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "scheme")) {
            if (saw_scheme) {
                try reader.skipValue(scratch);
            } else {
                scheme.scheme = try reader.string(scratch);
                saw_scheme = true;
            }
        } else if (std.mem.eql(u8, key, "bearerFormat")) {
            if (scheme.bearer_format != null) {
                try reader.skipValue(scratch);
            } else {
                scheme.bearer_format = try reader.string(scratch);
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_scheme) return error.MissingField;
    if (scheme.scheme.len == 0) return error.InvalidField;
    return scheme;
}

/// Encode an `HttpAuthSecurityScheme`.
pub fn encodeHttpAuthSecurityScheme(
    scheme: HttpAuthSecurityScheme,
    writer: *json.Writer,
) EncodeError!void {
    if (scheme.scheme.len == 0) return error.InvalidField;

    try writer.byte('{');
    if (scheme.description) |description| {
        try writer.slice("\"description\":");
        try writer.string(description);
        try writer.byte(',');
    }
    try writer.slice("\"scheme\":");
    try writer.string(scheme.scheme);
    if (scheme.bearer_format) |bearer_format| {
        try writer.slice(",\"bearerFormat\":");
        try writer.string(bearer_format);
    }
    try writer.byte('}');
}

/// Decode an `OpenIdConnectSecurityScheme`.
pub fn decodeOpenIdConnectSecurityScheme(
    raw: []const u8,
    scratch: []u8,
) DecodeError!OpenIdConnectSecurityScheme {
    var reader = json.Reader.init(raw);
    var scheme: OpenIdConnectSecurityScheme = .{ .open_id_connect_url = "" };
    var saw_url = false;

    if (try reader.beginObject()) return error.MissingField;

    while (try reader.nextKey(scratch)) |key| {
        if (std.mem.eql(u8, key, "description")) {
            if (scheme.description != null) {
                try reader.skipValue(scratch);
            } else {
                scheme.description = try reader.string(scratch);
            }
        } else if (std.mem.eql(u8, key, "openIdConnectUrl")) {
            if (saw_url) {
                try reader.skipValue(scratch);
            } else {
                scheme.open_id_connect_url = try reader.string(scratch);
                saw_url = true;
            }
        } else {
            try reader.skipValue(scratch);
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;

    if (!saw_url) return error.MissingField;
    if (scheme.open_id_connect_url.len == 0) return error.InvalidField;
    return scheme;
}

/// Encode an `OpenIdConnectSecurityScheme`.
pub fn encodeOpenIdConnectSecurityScheme(
    scheme: OpenIdConnectSecurityScheme,
    writer: *json.Writer,
) EncodeError!void {
    if (scheme.open_id_connect_url.len == 0) return error.InvalidField;

    try writer.byte('{');
    if (scheme.description) |description| {
        try writer.slice("\"description\":");
        try writer.string(description);
        try writer.byte(',');
    }
    try writer.slice("\"openIdConnectUrl\":");
    try writer.string(scheme.open_id_connect_url);
    try writer.byte('}');
}

/// Decode a `MutualTlsSecurityScheme`.
///
/// The only member is an optional description, so `{}` is a complete
/// scheme: mutual TLS is asserted by the transport and the message adds
/// nothing to it.
pub fn decodeMutualTlsSecurityScheme(
    raw: []const u8,
    scratch: []u8,
) DecodeError!MutualTlsSecurityScheme {
    var reader = json.Reader.init(raw);
    var scheme: MutualTlsSecurityScheme = .{};

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "description")) {
                if (scheme.description != null) {
                    try reader.skipValue(scratch);
                } else {
                    scheme.description = try reader.string(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!reader.atEnd()) return error.MalformedJson;
    return scheme;
}

/// Encode a `MutualTlsSecurityScheme`.
pub fn encodeMutualTlsSecurityScheme(
    scheme: MutualTlsSecurityScheme,
    writer: *json.Writer,
) EncodeError!void {
    if (scheme.description) |description| {
        try writer.slice("{\"description\":");
        try writer.string(description);
        try writer.byte('}');
        return;
    }
    try writer.slice("{}");
}

// --- Codec: the content half ----------------------------------------------------

// What this section carries
//
// Eleven messages: `PartContent`, `Part`, `Message`, `Artifact`, `TaskStatus`,
// `Task`, `TaskStatusUpdateEvent`, `TaskArtifactUpdateEvent`,
// `SendMessageRequest`, `SendMessageResponse` and `StreamResponse`. Each has a
// decoder and an encoder, and the two are exact inverses.
//
// One caller-owned arena, not nine out arrays
//
// A `Task` reaches a `Part` along four paths — its `status.message`, the `parts`
// of each of its `artifacts`, and the `parts` of each message in its `history` —
// and a `StreamResponse` reaches one along all four of its arms. The shape this
// walk would otherwise take is nine positional out arrays, which no call site
// can read and no second call site can keep consistent. So `ContentArena` is one
// struct of five caller-owned arrays with a fill level for each, and every
// decode in this section takes it.
//
// The five arrays are filled in document order and each owner takes the run that
// belongs to it, so the first message holds `arena.parts[0..2]` and the second
// holds `arena.parts[2..4]`. That is a property of the walk rather than a
// promise the caller has to keep: the reader is a cursor, it visits elements in
// the order the document spells them, and a list is consumed before the next
// list of the same kind begins. Nothing here reads ahead.
//
// Exhaustion is an error and never a truncation
//
// A member with more elements than the caller reserved is
// `error.BufferTooSmall`, for the reason `acp.decodePermissionRequest` gives: a
// task whose tenth artifact silently disappears is a task that says something
// the caller did not mean. The same holds for a `Part.raw` whose bytes outgrow
// `bytes` and for every `repeated string` in the half, because those elements
// share `strings` with each other and with `acceptedOutputModes`.
//
// The oneof is named by `PartContent`, not by `Part`
//
// `Part.fields[0]` carries `json = null`, because a `oneof` has no member name
// of its own. `findField(Part, "text")` is therefore null for every arm, and a
// decoder that dispatched on `Part` would skip all four, find no content, and
// refuse the part for it. The arm is named by `PartContent`'s own table, and the
// number a protobuf encoder writes for that arm is the number
// `PartContent.fields` gives it rather than the tag ordinal. `oneofMemberName`
// is that lookup, and it is a compile error if a tag ordinal and its row ever
// stop agreeing.
//
// `Part.raw` and which base64
//
// `Part.raw` is the only `bytes` field in the module. `research/normative/
// a2a-1.0.0.md` section 2.5 gives the proto type as `bytes` and states that the
// field "serializes as a base64 string in JSON", and ProtoJSON renders `bytes`
// as RFC 4648 section 4 base64 with `=` padding, so this is
// `json.base64.Alphabet.standard` and not the URL-safe alphabet. The
// `AgentCardSignature` pair is the different case and needed no decision: the
// same document's section 2.16 gives their proto type as `string`, and the
// base64url they carry is text the message already holds, so encoding one is a
// splice and there is nothing to convert.
//
// An empty REQUIRED string is refused; an empty REQUIRED list is not
//
// A REQUIRED string that arrives as `""` is `error.InvalidField`, for the
// reason `GetTaskRequest.id` gives: an empty task id is not a task. A REQUIRED
// `repeated` field is satisfied by `[]`, so `Message.parts` and `Artifact.parts`
// carry no emptiness rule and only the absence of the member is
// `error.MissingField`. A decoder that refused an empty part list would refuse
// a legal document.
//
// The nine presence defects this half found and fixed
//
// Every one of these is a field the wire may omit that the tables held as a
// plain value carrying a default, so an absent member and a present one
// holding that default were the same value and the encoder could not tell which
// bytes to write back. Each is named by the normative table that settles it.
//
//   `Task.context_id`                    `""`     section 2.2  no
//   `Task.artifacts`                     `&.{}`   section 2.2  no
//   `Task.history`                       `&.{}`   section 2.2  no
//   `Message.context_id`                 `""`     section 2.6  no
//   `Message.task_id`                    `""`     section 2.6  no
//   `Message.extensions`                 `&.{}`   section 2.6  no
//   `Message.reference_task_ids`         `&.{}`   section 2.6  no
//   `Artifact.extensions`                `&.{}`   section 2.7  no
//   `SendMessageRequest.tenant`          `""`     section 2.24 no
//
// The last column is the `Req` column of that table, and every row is `no`:
// each field is optional in the proto, so each may be absent, so each must be
// able to represent its absence. `SendMessageRequest.tenant` is the one that
// reads as a mistake — the eleven other requests in this file already gave
// their tenant a `?[]const u8`, and this one was left behind when the flat half
// was written.
//
// Two fields were the other way round and were not defects.
// `Task.statusUpdateEvent.context_id` and `TaskArtifactUpdateEvent.context_id`
// are REQUIRED and already carry no default, and the test above records that.
// `Message.parts` and `Artifact.parts` are REQUIRED too, and a default would
// have been wrong in a second way: a `[]const Part = &.{}` could not tell an
// absent `parts` from an empty one, and absence is the only case a decoder
// refuses there. They carry no default and no emptiness rule for that reason
// and not because an empty list is a valid part.

/// The caller-owned storage a content-half decode writes into.
///
/// Every array here is sized by the caller, and a decode that finds more
/// elements than an array holds is `error.BufferTooSmall` rather than a
/// truncated message. The `*_used` fields are the fill levels: they start at
/// zero, and every public decoder in this section resets them before it reads,
/// so one arena serves one document at a time. Reusing an arena for a second
/// document overwrites the first one's values, which is the same contract
/// `acp.decodePermissionRequest` offers its option array.
///
/// Nothing in here is retained past the call that filled it. The borrowed
/// strings and lexemes still point into the document and the caller's scratch,
/// and the decoded `Part.raw` bytes into `bytes`, so all of it dies with the
/// buffers the caller named.
pub const ContentArena = struct {
    /// Every `Part` in the document, in the order the document spells them.
    parts: []Part,
    /// The elements of `Task.artifacts`.
    artifacts: []Artifact,
    /// The elements of `Task.history`.
    messages: []Message,
    /// Every `repeated string` element in the document: the extension URIs, the
    /// reference task ids and the accepted output modes alike. They share one
    /// array because they are the same type, they are all bounded by the same
    /// caller, and sharing it is what keeps the fill level to one number.
    strings: [][]const u8,
    /// The decoded bytes of every `Part.raw`.
    bytes: []u8,

    parts_used: usize = 0,
    artifacts_used: usize = 0,
    messages_used: usize = 0,
    strings_used: usize = 0,
    bytes_used: usize = 0,

    /// An arena over storage the caller already has.
    pub fn init(
        parts: []Part,
        artifacts: []Artifact,
        messages: []Message,
        strings: [][]const u8,
        bytes: []u8,
    ) ContentArena {
        return .{
            .parts = parts,
            .artifacts = artifacts,
            .messages = messages,
            .strings = strings,
            .bytes = bytes,
        };
    }

    /// Forget what a previous decode wrote, keeping the storage.
    pub fn reset(self: *ContentArena) void {
        self.parts_used = 0;
        self.artifacts_used = 0;
        self.messages_used = 0;
        self.strings_used = 0;
        self.bytes_used = 0;
    }
};

/// The ProtoJSON member name of `oneof` member `index`, read from the table.
///
/// The number a protobuf encoder writes for that member is
/// `U.fields[index].number`; the tag ordinal is `@intFromEnum` of the member's
/// tag, which is 0-based. The two coincide only because every `oneof` in this
/// file numbers its members from 1 with no gaps, and that is a fact about the
/// table rather than about the union, so it is checked here and a disagreement
/// is a compile error rather than a part that arrives as a different arm. The
/// name comes out of the same row, so a rename in the table moves the encoder
/// with it rather than leaving a literal behind.
fn oneofMemberName(comptime U: type, comptime index: usize) []const u8 {
    const info = @typeInfo(U).@"union";
    // An `if` and not an `orelse`, for the reason `assertTable` records: a
    // `@compileError` is only legal in a comptime branch, and an `orelse`
    // operand is a runtime position.
    if (comptime info.tag_type == null) {
        @compileError(std.fmt.comptimePrint(
            "{s} is not a tagged union, so it has no oneof member names",
            .{@typeName(U)},
        ));
    }
    const tag_type = info.tag_type.?;
    const ordinal = @intFromEnum(@field(tag_type, info.fields[index].name));
    if (comptime ordinal != index) {
        @compileError(std.fmt.comptimePrint(
            "{s} member {d} has tag ordinal {d}, so a codec taking the ordinal" ++
                " for the field number writes it one below where the proto puts it",
            .{ @typeName(U), index, ordinal },
        ));
    }
    if (comptime index + 1 != U.fields[index].number) {
        @compileError(std.fmt.comptimePrint(
            "{s} member {d} is field {d}, and its tag ordinal {d} does not give it",
            .{ @typeName(U), index, U.fields[index].number, ordinal },
        ));
    }
    // An `if` and not an `orelse`, for the reason `assertTable` records: a
    // `@compileError` is only legal in a comptime branch, and an `orelse`
    // operand is a runtime position.
    if (comptime U.fields[index].json == null) {
        @compileError(std.fmt.comptimePrint(
            "{s} member {d} has no ProtoJSON name, and a oneof member always has one",
            .{ @typeName(U), index },
        ));
    }
    return U.fields[index].json.?;
}

/// Write `"name":` for member `index` of message `T`.
///
/// The name comes from the table rather than from a literal in the body, so the
/// one place a member name is transcribed stays the one place an encoder reads
/// it. A row with `json = null` is a compile error here rather than a `null`
/// that would slice, and the rows that carry one are the two kinds a member
/// name cannot describe: a synthetic map entry, whose name is its key, and a
/// `oneof` a struct holds as one field, which goes through `oneofMemberName`
/// instead because the name that goes on the wire belongs to the union's arm.
fn writeMemberName(comptime T: type, comptime index: usize, writer: *json.Writer) EncodeError!void {
    // An `if` and not an `orelse`, for the reason `assertTable` records.
    if (comptime jsonName(T, index) == null) {
        @compileError(std.fmt.comptimePrint(
            "{s} field {d} has no ProtoJSON name, so an encoder cannot spell it",
            .{ @typeName(T), index },
        ));
    }
    try writer.byte('"');
    try writer.slice(jsonName(T, index).?);
    try writer.slice("\":");
}

/// Write `bytes` as a JSON string holding its base64 text.
///
/// RFC 4648 section 4 gives `A-Za-z0-9+/` and the pad `=`, and JSON escapes none
/// of those, so the quoted form is written straight out of the encoded buffer
/// with no second escaping pass. `base64` is the caller's, sized from
/// `json.base64.encodedLen` of the largest `Part.raw` the caller will encode, and
/// `validatePart` refuses a value that does not fit it before the first byte of
/// the message is written.
fn writeBase64String(bytes: []const u8, base64: []u8, writer: *json.Writer) EncodeError!void {
    const encoded = try json.base64.encode(bytes, base64, .standard);
    try writer.byte('"');
    try writer.slice(encoded);
    try writer.byte('"');
}

/// Read the base64 text of a `Part.raw` and decode it into `arena.bytes`.
///
/// `Part.raw` is a `bytes` field, so the value on the wire is base64 and the
/// value a caller wants is the bytes. The buffer is bounded from the encoded
/// length with `decodedLen`, which overstates the result because it ignores the
/// padding, so a buffer sized from it is never short and the peer's bytes are
/// never reported as the caller's mistake. An encoded length that is not a
/// whole number of groups is `error.InvalidField`, which is what
/// `json.base64.decode` would say about it and is said here so the bound can be
/// computed.
fn readRawPart(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError![]const u8 {
    const encoded = try reader.string(scratch);
    const bound = json.base64.decodedLen(encoded.len) orelse return error.InvalidField;
    const start = arena.bytes_used;
    if (start + bound > arena.bytes.len) return error.BufferTooSmall;
    const decoded = try json.base64.decode(encoded, arena.bytes[start..][0..bound], .standard);
    arena.bytes_used = start + decoded.len;
    return arena.bytes[start..][0..decoded.len];
}

/// Consume a `null` and report it, when the next value is one.
///
/// A message member sent as `null` is the member missing and wearing a key.
/// The document is well formed and it names a member whose value is no
/// message, so this leaves the field null for the caller's own
/// `error.MissingField` check to report rather than handing `null` to
/// `beginObject`, which would call it a syntax error and blame the peer's
/// grammar for a field the peer did send. Every message member in this half
/// asks first, so one member has three answers and not four: absent and `null`
/// are both `MissingField`, and a value that is neither is whatever the
/// member's own walk says.
fn isNullMember(reader: *json.Reader) DecodeError!bool {
    reader.skipWhitespace();
    if (reader.peek() != 'n') return false;
    try reader.nullLiteral();
    return true;
}

/// Read a `repeated string` member into the arena's element storage.
///
/// The fill starts where the arena already stands, so two lists in one document
/// take two runs of one array and neither overwrites the other. An array
/// carrying no element is well formed and takes a zero-length run.
fn readStrings(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError![]const []const u8 {
    const start = arena.strings_used;
    const count = try readStringList(reader, arena.strings[start..], scratch);
    arena.strings_used = start + count;
    return arena.strings[start..][0..count];
}

/// Read a `repeated Part` member into the arena.
///
/// Exhaustion is `error.BufferTooSmall` for the reason `readStrings` gives it
/// for a list of strings, and for the stronger reason that a `Part` is content
/// rather than a hint: dropping the last part of a message is dropping what the
/// message says.
fn readParts(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError![]const Part {
    const start = arena.parts_used;
    if (try reader.beginArray()) return arena.parts[start..start];
    var count: usize = 0;
    while (try reader.nextArrayElement()) {
        if (start + count == arena.parts.len) return error.BufferTooSmall;
        arena.parts[start + count] = try readPart(reader, arena, scratch);
        count += 1;
    }
    arena.parts_used = start + count;
    return arena.parts[start..][0..count];
}

/// Read the `PartContent` member `key` names.
///
/// The arm is chosen by the name that arrived and the name is the table's, so
/// this is the walk that makes the oneof a `union(enum)` at all. The four arms
/// below are the four members of the union and `findField` only ever returns an
/// index below `fields.len`, so the `else` is not reachable from the wire; it is
/// `error.InvalidField` rather than `unreachable` because decoding is total and
/// this library does not have a branch a peer can reach that traps.
fn readPartContentMember(
    key: []const u8,
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!PartContent {
    const arm = findField(PartContent, key) orelse return error.InvalidField;
    return switch (arm) {
        0 => PartContent{ .text = try reader.string(scratch) },
        1 => PartContent{ .raw = try readRawPart(reader, arena, scratch) },
        2 => PartContent{ .url = try reader.string(scratch) },
        3 => PartContent{ .data = try reader.rawValue(scratch) },
        else => error.InvalidField,
    };
}

/// The walk `decodePartContent` opens, so `readPart` can read one beside its own
/// members on the same reader.
fn readPartContentObject(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!?PartContent {
    var found: ?PartContent = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            // First-wins, and the discarded arm is still read as a value rather
            // than stepped over blindly, for the reason the section above gives
            // for a repeated member: a peer must not be able to hide a syntax
            // error in the slot a name already used.
            if (found != null or findField(PartContent, key) == null) {
                try reader.skipValue(scratch);
            } else {
                found = try readPartContentMember(key, reader, arena, scratch);
            }
        }
    }

    return found;
}

/// The walk `decodePart` opens, so `readParts` can read one per element.
fn readPart(reader: *json.Reader, arena: *ContentArena, scratch: []u8) DecodeError!Part {
    var content: ?PartContent = null;
    var metadata: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var media_type: ?[]const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            // The oneof is asked first. `Part.fields[0]` has no member name, so
            // every arm name is a `PartContent` row, and putting that question
            // first is what stops a future row on either table from making the
            // arm unreachable.
            if (findField(PartContent, key) != null) {
                if (content != null) {
                    try reader.skipValue(scratch);
                } else {
                    content = try readPartContentMember(key, reader, arena, scratch);
                }
            } else if (std.mem.eql(u8, key, "metadata")) {
                if (metadata != null) {
                    try reader.skipValue(scratch);
                } else {
                    metadata = try reader.rawValue(scratch);
                }
            } else if (std.mem.eql(u8, key, "filename")) {
                if (filename != null) {
                    try reader.skipValue(scratch);
                } else {
                    filename = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "mediaType")) {
                if (media_type != null) {
                    try reader.skipValue(scratch);
                } else {
                    media_type = try reader.string(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    return .{
        // A `Part` MUST carry exactly one arm, section 4.1.6 of the rendered
        // specification as `research/normative/a2a-1.0.0.md` quotes it, so a
        // part with no content member is a missing field and not an empty part.
        .content = content orelse return error.MissingField,
        .metadata = metadata,
        .filename = filename,
        .media_type = media_type,
    };
}

/// The walk `decodeMessage` opens, so `readTaskStatus` and `readTask` can read
/// one nested beside their own members on the same reader.
fn readMessage(reader: *json.Reader, arena: *ContentArena, scratch: []u8) DecodeError!Message {
    var message_id: []const u8 = "";
    var saw_message_id = false;
    var context_id: ?[]const u8 = null;
    var task_id: ?[]const u8 = null;
    var role: Role = .unspecified;
    var saw_role = false;
    var parts: ?[]const Part = null;
    var metadata: ?[]const u8 = null;
    var extensions: ?[]const []const u8 = null;
    var reference_task_ids: ?[]const []const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "messageId")) {
                if (saw_message_id) {
                    try reader.skipValue(scratch);
                } else {
                    message_id = try reader.string(scratch);
                    saw_message_id = true;
                }
            } else if (std.mem.eql(u8, key, "contextId")) {
                if (context_id != null) {
                    try reader.skipValue(scratch);
                } else {
                    context_id = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "taskId")) {
                if (task_id != null) {
                    try reader.skipValue(scratch);
                } else {
                    task_id = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "role")) {
                if (saw_role) {
                    try reader.skipValue(scratch);
                } else {
                    role = try Role.parse(try reader.string(scratch));
                    saw_role = true;
                }
            } else if (std.mem.eql(u8, key, "parts")) {
                if (parts != null) {
                    try reader.skipValue(scratch);
                } else {
                    parts = try readParts(reader, arena, scratch);
                }
            } else if (std.mem.eql(u8, key, "metadata")) {
                if (metadata != null) {
                    try reader.skipValue(scratch);
                } else {
                    metadata = try reader.rawValue(scratch);
                }
            } else if (std.mem.eql(u8, key, "extensions")) {
                if (extensions != null) {
                    try reader.skipValue(scratch);
                } else {
                    extensions = try readStrings(reader, arena, scratch);
                }
            } else if (std.mem.eql(u8, key, "referenceTaskIds")) {
                if (reference_task_ids != null) {
                    try reader.skipValue(scratch);
                } else {
                    reference_task_ids = try readStrings(reader, arena, scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!saw_message_id) return error.MissingField;
    if (message_id.len == 0) return error.InvalidField;
    if (!saw_role) return error.MissingField;
    return .{
        .message_id = message_id,
        .context_id = context_id,
        .task_id = task_id,
        .role = role,
        // `parts` is REQUIRED and an empty array satisfies it, so the absence
        // of the member is what is missing and not the absence of elements.
        .parts = parts orelse return error.MissingField,
        .metadata = metadata,
        .extensions = extensions,
        .reference_task_ids = reference_task_ids,
    };
}

/// The walk `decodeArtifact` opens, so `readTask` and
/// `readTaskArtifactUpdateEvent` can read one nested beside their own members.
fn readArtifact(reader: *json.Reader, arena: *ContentArena, scratch: []u8) DecodeError!Artifact {
    var artifact_id: []const u8 = "";
    var saw_artifact_id = false;
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var parts: ?[]const Part = null;
    var metadata: ?[]const u8 = null;
    var extensions: ?[]const []const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "artifactId")) {
                if (saw_artifact_id) {
                    try reader.skipValue(scratch);
                } else {
                    artifact_id = try reader.string(scratch);
                    saw_artifact_id = true;
                }
            } else if (std.mem.eql(u8, key, "name")) {
                if (name != null) {
                    try reader.skipValue(scratch);
                } else {
                    name = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "description")) {
                if (description != null) {
                    try reader.skipValue(scratch);
                } else {
                    description = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "parts")) {
                if (parts != null) {
                    try reader.skipValue(scratch);
                } else {
                    parts = try readParts(reader, arena, scratch);
                }
            } else if (std.mem.eql(u8, key, "metadata")) {
                if (metadata != null) {
                    try reader.skipValue(scratch);
                } else {
                    metadata = try reader.rawValue(scratch);
                }
            } else if (std.mem.eql(u8, key, "extensions")) {
                if (extensions != null) {
                    try reader.skipValue(scratch);
                } else {
                    extensions = try readStrings(reader, arena, scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!saw_artifact_id) return error.MissingField;
    if (artifact_id.len == 0) return error.InvalidField;
    return .{
        .artifact_id = artifact_id,
        .name = name,
        .description = description,
        .parts = parts orelse return error.MissingField,
        .metadata = metadata,
        .extensions = extensions,
    };
}

/// The walk `decodeTaskStatus` opens, so `readTask` and
/// `readTaskStatusUpdateEvent` can read one nested beside their own members.
fn readTaskStatus(reader: *json.Reader, arena: *ContentArena, scratch: []u8) DecodeError!TaskStatus {
    var state: TaskState = .unspecified;
    var saw_state = false;
    var message: ?Message = null;
    var timestamp: ?[]const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "state")) {
                if (saw_state) {
                    try reader.skipValue(scratch);
                } else {
                    state = try TaskState.parse(try reader.string(scratch));
                    saw_state = true;
                }
            } else if (std.mem.eql(u8, key, "message")) {
                if (message != null) {
                    try reader.skipValue(scratch);
                } else {
                    if (try isNullMember(reader)) {
                        // `null` and an absent member agree, and the check
                        // after the loop is what reports the difference.
                    } else {
                        message = try readMessage(reader, arena, scratch);
                    }
                }
            } else if (std.mem.eql(u8, key, "timestamp")) {
                if (timestamp != null) {
                    try reader.skipValue(scratch);
                } else {
                    // The ISO-8601 text the peer wrote, and not a `Timestamp`
                    // converted here. Re-encoding has to put back the bytes that
                    // arrived, and a normalised spelling of the same instant is
                    // not those bytes.
                    timestamp = try reader.string(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!saw_state) return error.MissingField;
    return .{ .state = state, .message = message, .timestamp = timestamp };
}

/// The walk `decodeTask` opens, so `readSendMessageResponse` and
/// `readStreamResponse` can read one nested beside their own members.
fn readTask(reader: *json.Reader, arena: *ContentArena, scratch: []u8) DecodeError!Task {
    var id: []const u8 = "";
    var saw_id = false;
    var context_id: ?[]const u8 = null;
    var status: ?TaskStatus = null;
    var artifacts: ?[]const Artifact = null;
    var history: ?[]const Message = null;
    var metadata: ?[]const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "id")) {
                if (saw_id) {
                    try reader.skipValue(scratch);
                } else {
                    id = try reader.string(scratch);
                    saw_id = true;
                }
            } else if (std.mem.eql(u8, key, "contextId")) {
                if (context_id != null) {
                    try reader.skipValue(scratch);
                } else {
                    context_id = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "status")) {
                if (status != null) {
                    try reader.skipValue(scratch);
                } else {
                    if (try isNullMember(reader)) {
                        // `null` and an absent member agree here too.
                    } else {
                        status = try readTaskStatus(reader, arena, scratch);
                    }
                }
            } else if (std.mem.eql(u8, key, "artifacts")) {
                if (artifacts != null) {
                    try reader.skipValue(scratch);
                } else {
                    artifacts = try readArtifacts(reader, arena, scratch);
                }
            } else if (std.mem.eql(u8, key, "history")) {
                if (history != null) {
                    try reader.skipValue(scratch);
                } else {
                    history = try readMessages(reader, arena, scratch);
                }
            } else if (std.mem.eql(u8, key, "metadata")) {
                if (metadata != null) {
                    try reader.skipValue(scratch);
                } else {
                    metadata = try reader.rawValue(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!saw_id) return error.MissingField;
    if (id.len == 0) return error.InvalidField;
    return .{
        .id = id,
        .context_id = context_id,
        .status = status orelse return error.MissingField,
        .artifacts = artifacts,
        .history = history,
        .metadata = metadata,
    };
}

/// Read a `repeated Artifact` member into the arena.
fn readArtifacts(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError![]const Artifact {
    const start = arena.artifacts_used;
    if (try reader.beginArray()) return arena.artifacts[start..start];
    var count: usize = 0;
    while (try reader.nextArrayElement()) {
        if (start + count == arena.artifacts.len) return error.BufferTooSmall;
        arena.artifacts[start + count] = try readArtifact(reader, arena, scratch);
        count += 1;
    }
    arena.artifacts_used = start + count;
    return arena.artifacts[start..][0..count];
}

/// Read a `repeated Message` member into the arena.
fn readMessages(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError![]const Message {
    const start = arena.messages_used;
    if (try reader.beginArray()) return arena.messages[start..start];
    var count: usize = 0;
    while (try reader.nextArrayElement()) {
        if (start + count == arena.messages.len) return error.BufferTooSmall;
        arena.messages[start + count] = try readMessage(reader, arena, scratch);
        count += 1;
    }
    arena.messages_used = start + count;
    return arena.messages[start..][0..count];
}

/// The walk `decodeTaskStatusUpdateEvent` opens, so `readStreamResponse` can
/// read one beside its own members.
fn readTaskStatusUpdateEvent(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!TaskStatusUpdateEvent {
    var task_id: []const u8 = "";
    var saw_task_id = false;
    var context_id: []const u8 = "";
    var saw_context_id = false;
    var status: ?TaskStatus = null;
    var metadata: ?[]const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "taskId")) {
                if (saw_task_id) {
                    try reader.skipValue(scratch);
                } else {
                    task_id = try reader.string(scratch);
                    saw_task_id = true;
                }
            } else if (std.mem.eql(u8, key, "contextId")) {
                if (saw_context_id) {
                    try reader.skipValue(scratch);
                } else {
                    context_id = try reader.string(scratch);
                    saw_context_id = true;
                }
            } else if (std.mem.eql(u8, key, "status")) {
                if (status != null) {
                    try reader.skipValue(scratch);
                } else {
                    if (try isNullMember(reader)) {
                        // `null` and an absent member agree here too.
                    } else {
                        status = try readTaskStatus(reader, arena, scratch);
                    }
                }
            } else if (std.mem.eql(u8, key, "metadata")) {
                if (metadata != null) {
                    try reader.skipValue(scratch);
                } else {
                    metadata = try reader.rawValue(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!saw_task_id or !saw_context_id) return error.MissingField;
    if (task_id.len == 0 or context_id.len == 0) return error.InvalidField;
    return .{
        .task_id = task_id,
        .context_id = context_id,
        .status = status orelse return error.MissingField,
        .metadata = metadata,
    };
}

/// The walk `decodeTaskArtifactUpdateEvent` opens, so `readStreamResponse` can
/// read one beside its own members.
fn readTaskArtifactUpdateEvent(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!TaskArtifactUpdateEvent {
    var task_id: []const u8 = "";
    var saw_task_id = false;
    var context_id: []const u8 = "";
    var saw_context_id = false;
    var artifact: ?Artifact = null;
    var append: ?bool = null;
    var last_chunk: ?bool = null;
    var metadata: ?[]const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "taskId")) {
                if (saw_task_id) {
                    try reader.skipValue(scratch);
                } else {
                    task_id = try reader.string(scratch);
                    saw_task_id = true;
                }
            } else if (std.mem.eql(u8, key, "contextId")) {
                if (saw_context_id) {
                    try reader.skipValue(scratch);
                } else {
                    context_id = try reader.string(scratch);
                    saw_context_id = true;
                }
            } else if (std.mem.eql(u8, key, "artifact")) {
                if (artifact != null) {
                    try reader.skipValue(scratch);
                } else {
                    if (try isNullMember(reader)) {
                        // `null` and an absent member agree here too.
                    } else {
                        artifact = try readArtifact(reader, arena, scratch);
                    }
                }
            } else if (std.mem.eql(u8, key, "append")) {
                if (append != null) {
                    try reader.skipValue(scratch);
                } else {
                    append = try reader.boolean();
                }
            } else if (std.mem.eql(u8, key, "lastChunk")) {
                if (last_chunk != null) {
                    try reader.skipValue(scratch);
                } else {
                    last_chunk = try reader.boolean();
                }
            } else if (std.mem.eql(u8, key, "metadata")) {
                if (metadata != null) {
                    try reader.skipValue(scratch);
                } else {
                    metadata = try reader.rawValue(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    if (!saw_task_id or !saw_context_id) return error.MissingField;
    if (task_id.len == 0 or context_id.len == 0) return error.InvalidField;
    return .{
        .task_id = task_id,
        .context_id = context_id,
        .artifact = artifact orelse return error.MissingField,
        .append = append,
        .last_chunk = last_chunk,
        .metadata = metadata,
    };
}

/// The walk `decodeSendMessageRequest` opens, so nothing nested has to be read
/// twice.
fn readSendMessageRequest(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!SendMessageRequest {
    var tenant: ?[]const u8 = null;
    var message: ?Message = null;
    var configuration: ?SendMessageConfiguration = null;
    var metadata: ?[]const u8 = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (std.mem.eql(u8, key, "tenant")) {
                if (tenant != null) {
                    try reader.skipValue(scratch);
                } else {
                    tenant = try reader.string(scratch);
                }
            } else if (std.mem.eql(u8, key, "message")) {
                if (message != null) {
                    try reader.skipValue(scratch);
                } else if (try isNullMember(reader)) {
                    // `null` and an absent member agree, and the check after
                    // the loop is what reports the difference.
                } else {
                    message = try readMessage(reader, arena, scratch);
                }
            } else if (std.mem.eql(u8, key, "configuration")) {
                if (configuration != null) {
                    try reader.skipValue(scratch);
                } else if (try isNullMember(reader)) {
                    // `null` and an absent member agree here too.
                } else {
                    // The accepted modes are `repeated string` like every other
                    // list in the half, so they come from the arena's element
                    // storage rather than from a second array the caller would
                    // have to size.
                    configuration = try readSendMessageConfiguration(
                        reader,
                        arena.strings,
                        &arena.strings_used,
                        scratch,
                    );
                }
            } else if (std.mem.eql(u8, key, "metadata")) {
                if (metadata != null) {
                    try reader.skipValue(scratch);
                } else {
                    metadata = try reader.rawValue(scratch);
                }
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    return .{
        .tenant = tenant,
        .message = message orelse return error.MissingField,
        .configuration = configuration,
        .metadata = metadata,
    };
}

/// The walk `decodeSendMessageResponse` opens.
///
/// The union is the whole message, so the object carries one member out of the
/// two its table names and every other member is a name no row carries. The
/// first arm named wins, for the reason every repeated member in this file does,
/// and the discarded arm is still read as a value so a peer cannot hide a
/// syntax error behind it.
fn readSendMessageResponse(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!?SendMessageResponse {
    var found: ?SendMessageResponse = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (found != null) {
                try reader.skipValue(scratch);
            } else if (try isNullMember(reader)) {
                // An arm with no value is an arm that is not there, so a later
                // arm that does carry one still decides the union — the same
                // rule a repeated member takes its first occurrence under.
                //
                // This is asked before the arm name on purpose. Asking after
                // would hand `null` to `beginObject` and call a well-formed
                // document a syntax error, and it is what the order has to be
                // for `{"task":null}` to answer "no arm" rather than "broken
                // JSON".
            } else if (std.mem.eql(u8, key, oneofMemberName(SendMessageResponse, 0))) {
                found = SendMessageResponse{ .task = try readTask(reader, arena, scratch) };
            } else if (std.mem.eql(u8, key, oneofMemberName(SendMessageResponse, 1))) {
                found = SendMessageResponse{ .message = try readMessage(reader, arena, scratch) };
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    return found;
}

/// The walk `decodeStreamResponse` opens.
///
/// The same rule as `readSendMessageResponse`, over four arms instead of two.
fn readStreamResponse(
    reader: *json.Reader,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!?StreamResponse {
    var found: ?StreamResponse = null;

    const is_empty = try reader.beginObject();
    if (!is_empty) {
        while (try reader.nextKey(scratch)) |key| {
            if (found != null) {
                try reader.skipValue(scratch);
            } else if (try isNullMember(reader)) {
                // The same rule, and the same order, as
                // `readSendMessageResponse` above.
            } else if (std.mem.eql(u8, key, oneofMemberName(StreamResponse, 0))) {
                found = StreamResponse{ .task = try readTask(reader, arena, scratch) };
            } else if (std.mem.eql(u8, key, oneofMemberName(StreamResponse, 1))) {
                found = StreamResponse{ .message = try readMessage(reader, arena, scratch) };
            } else if (std.mem.eql(u8, key, oneofMemberName(StreamResponse, 2))) {
                found = StreamResponse{ .status_update = try readTaskStatusUpdateEvent(
                    reader,
                    arena,
                    scratch,
                ) };
            } else if (std.mem.eql(u8, key, oneofMemberName(StreamResponse, 3))) {
                found = StreamResponse{ .artifact_update = try readTaskArtifactUpdateEvent(
                    reader,
                    arena,
                    scratch,
                ) };
            } else {
                try reader.skipValue(scratch);
            }
        }
    }

    return found;
}

/// Decode a `PartContent` on its own.
///
/// The object is the `content` `oneof` written out, which is what a caller that
/// received a part from somewhere other than this library's own `Part` has.
/// A `oneof` carries exactly one member, so an object with none is
/// `error.MissingField` and an object with two is first-wins.
pub fn decodePartContent(
    raw: []const u8,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!PartContent {
    arena.reset();
    var reader = json.Reader.init(raw);
    const content = try readPartContentObject(&reader, arena, scratch);

    // The body is one JSON value, and the `data` lexeme above is a sub-slice of
    // it, so a tail behind the closing brace is a second document this function
    // would answer as though it had not arrived. The check is here rather than
    // in the loop for that reason.
    if (!reader.atEnd()) return error.MalformedJson;
    return content orelse return error.MissingField;
}

/// Decode a `Part`.
///
/// `raw` is the only `bytes` field the half has, so the base64 text under it is
/// decoded into `arena.bytes` and the `Part` holds a slice of the caller's own
/// storage. A part with no content member is `error.MissingField`, for the
/// reason the section above gives.
pub fn decodePart(raw: []const u8, arena: *ContentArena, scratch: []u8) DecodeError!Part {
    arena.reset();
    var reader = json.Reader.init(raw);
    const part = try readPart(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return part;
}

/// Decode a `Message`.
///
/// `messageId` and `role` are the only members the proto marks REQUIRED, and
/// neither may be empty. `parts` is REQUIRED too, and an empty array satisfies
/// it, so `[]` is a message with no parts and only the absence of the member is
/// refused.
pub fn decodeMessage(raw: []const u8, arena: *ContentArena, scratch: []u8) DecodeError!Message {
    arena.reset();
    var reader = json.Reader.init(raw);
    const message = try readMessage(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return message;
}

/// Decode an `Artifact`.
pub fn decodeArtifact(raw: []const u8, arena: *ContentArena, scratch: []u8) DecodeError!Artifact {
    arena.reset();
    var reader = json.Reader.init(raw);
    const artifact = try readArtifact(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return artifact;
}

/// Decode a `TaskStatus`.
pub fn decodeTaskStatus(
    raw: []const u8,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!TaskStatus {
    arena.reset();
    var reader = json.Reader.init(raw);
    const status = try readTaskStatus(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return status;
}

/// Decode a `Task`.
///
/// This is the walk the arena was designed for: a task holds its status, and
/// that status may hold a message, and the task holds artifacts and history,
/// and every message and artifact holds parts, and every part may hold bytes.
/// Nine positional out arrays is the other shape and it is not one a call site
/// can read.
pub fn decodeTask(raw: []const u8, arena: *ContentArena, scratch: []u8) DecodeError!Task {
    arena.reset();
    var reader = json.Reader.init(raw);
    const task = try readTask(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return task;
}

/// Decode a `TaskStatusUpdateEvent`.
pub fn decodeTaskStatusUpdateEvent(
    raw: []const u8,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!TaskStatusUpdateEvent {
    arena.reset();
    var reader = json.Reader.init(raw);
    const event = try readTaskStatusUpdateEvent(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return event;
}

/// Decode a `TaskArtifactUpdateEvent`.
pub fn decodeTaskArtifactUpdateEvent(
    raw: []const u8,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!TaskArtifactUpdateEvent {
    arena.reset();
    var reader = json.Reader.init(raw);
    const event = try readTaskArtifactUpdateEvent(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return event;
}

/// Decode a `SendMessageRequest`.
///
/// The accepted output modes come from `arena.strings` like every other list in
/// the half, so this is three parameters rather than four and the caller sizes
/// one element array instead of two.
pub fn decodeSendMessageRequest(
    raw: []const u8,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!SendMessageRequest {
    arena.reset();
    var reader = json.Reader.init(raw);
    const request = try readSendMessageRequest(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return request;
}

/// Decode a `SendMessageResponse`.
pub fn decodeSendMessageResponse(
    raw: []const u8,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!SendMessageResponse {
    arena.reset();
    var reader = json.Reader.init(raw);
    const response = try readSendMessageResponse(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return response orelse return error.MissingField;
}

/// Decode a `StreamResponse`.
pub fn decodeStreamResponse(
    raw: []const u8,
    arena: *ContentArena,
    scratch: []u8,
) DecodeError!StreamResponse {
    arena.reset();
    var reader = json.Reader.init(raw);
    const response = try readStreamResponse(&reader, arena, scratch);

    if (!reader.atEnd()) return error.MalformedJson;
    return response orelse return error.MissingField;
}

/// Encode a `PartContent`.
pub fn encodePartContent(
    content: PartContent,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try validatePartContent(content, base64);
    try writePartContent(content, writer, base64);
}

/// Encode a `Part`.
pub fn encodePart(part: Part, writer: *json.Writer, base64: []u8) EncodeError!void {
    try validatePart(part, base64);
    try writePart(part, writer, base64);
}

/// Encode a `Message`.
pub fn encodeMessage(message: Message, writer: *json.Writer, base64: []u8) EncodeError!void {
    try validateMessage(message, base64);
    try writeMessage(message, writer, base64);
}

/// Encode an `Artifact`.
pub fn encodeArtifact(artifact: Artifact, writer: *json.Writer, base64: []u8) EncodeError!void {
    try validateArtifact(artifact, base64);
    try writeArtifact(artifact, writer, base64);
}

/// Encode a `TaskStatus`.
pub fn encodeTaskStatus(status: TaskStatus, writer: *json.Writer, base64: []u8) EncodeError!void {
    try validateTaskStatus(status, base64);
    try writeTaskStatus(status, writer, base64);
}

/// Encode a `Task`.
pub fn encodeTask(task: Task, writer: *json.Writer, base64: []u8) EncodeError!void {
    try validateTask(task, base64);
    try writeTask(task, writer, base64);
}

/// Encode a `TaskStatusUpdateEvent`.
pub fn encodeTaskStatusUpdateEvent(
    event: TaskStatusUpdateEvent,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try validateTaskStatusUpdateEvent(event, base64);
    try writeTaskStatusUpdateEvent(event, writer, base64);
}

/// Encode a `TaskArtifactUpdateEvent`.
pub fn encodeTaskArtifactUpdateEvent(
    event: TaskArtifactUpdateEvent,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try validateTaskArtifactUpdateEvent(event, base64);
    try writeTaskArtifactUpdateEvent(event, writer, base64);
}

/// Encode a `SendMessageRequest`.
pub fn encodeSendMessageRequest(
    request: SendMessageRequest,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try validateSendMessageRequest(request, base64);
    try writeSendMessageRequest(request, writer, base64);
}

/// Encode a `SendMessageResponse`.
pub fn encodeSendMessageResponse(
    response: SendMessageResponse,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try validateSendMessageResponse(response, base64);
    try writeSendMessageResponse(response, writer, base64);
}

/// Encode a `StreamResponse`.
pub fn encodeStreamResponse(
    response: StreamResponse,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try validateStreamResponse(response, base64);
    try writeStreamResponse(response, writer, base64);
}

// The validation half
//
// Every encoder above checks its whole value before it writes its first byte,
// for the reason `acp.encodePermissionRequest` checks its whole request: a
// refusal halfway through leaves `{"id":"t","status":{"sta` in the caller's
// buffer, which is neither a message nor nothing. What is refused is a value
// the decoder could not have returned — an empty REQUIRED string, or a
// `Part.raw` that does not fit the caller's base64 buffer — and both are
// `error.InvalidField` and `error.BufferTooSmall` rather than a truncated
// document.

fn validatePartContent(content: PartContent, base64: []u8) EncodeError!void {
    switch (content) {
        .text, .url, .data => {},
        .raw => |raw| {
            if (json.base64.encodedLen(raw.len) > base64.len) return error.BufferTooSmall;
        },
    }
}

fn validatePart(part: Part, base64: []u8) EncodeError!void {
    try validatePartContent(part.content, base64);
}

fn validateParts(parts: []const Part, base64: []u8) EncodeError!void {
    for (parts) |part| try validatePart(part, base64);
}

fn validateMessage(message: Message, base64: []u8) EncodeError!void {
    if (message.message_id.len == 0) return error.InvalidField;
    try validateParts(message.parts, base64);
}

fn validateMessages(messages: []const Message, base64: []u8) EncodeError!void {
    for (messages) |message| try validateMessage(message, base64);
}

fn validateArtifact(artifact: Artifact, base64: []u8) EncodeError!void {
    if (artifact.artifact_id.len == 0) return error.InvalidField;
    try validateParts(artifact.parts, base64);
}

fn validateArtifacts(artifacts: []const Artifact, base64: []u8) EncodeError!void {
    for (artifacts) |artifact| try validateArtifact(artifact, base64);
}

fn validateTaskStatus(status: TaskStatus, base64: []u8) EncodeError!void {
    if (status.message) |message| try validateMessage(message, base64);
}

fn validateTask(task: Task, base64: []u8) EncodeError!void {
    if (task.id.len == 0) return error.InvalidField;
    try validateTaskStatus(task.status, base64);
    if (task.artifacts) |artifacts| try validateArtifacts(artifacts, base64);
    if (task.history) |history| try validateMessages(history, base64);
}

fn validateTaskStatusUpdateEvent(
    event: TaskStatusUpdateEvent,
    base64: []u8,
) EncodeError!void {
    if (event.task_id.len == 0 or event.context_id.len == 0) return error.InvalidField;
    try validateTaskStatus(event.status, base64);
}

fn validateTaskArtifactUpdateEvent(
    event: TaskArtifactUpdateEvent,
    base64: []u8,
) EncodeError!void {
    if (event.task_id.len == 0 or event.context_id.len == 0) return error.InvalidField;
    try validateArtifact(event.artifact, base64);
}

fn validateSendMessageRequest(request: SendMessageRequest, base64: []u8) EncodeError!void {
    try validateMessage(request.message, base64);
}

fn validateSendMessageResponse(
    response: SendMessageResponse,
    base64: []u8,
) EncodeError!void {
    switch (response) {
        .task => |task| try validateTask(task, base64),
        .message => |message| try validateMessage(message, base64),
    }
}

fn validateStreamResponse(response: StreamResponse, base64: []u8) EncodeError!void {
    switch (response) {
        .task => |task| try validateTask(task, base64),
        .message => |message| try validateMessage(message, base64),
        .status_update => |event| try validateTaskStatusUpdateEvent(event, base64),
        .artifact_update => |event| try validateTaskArtifactUpdateEvent(event, base64),
    }
}

// The write half
//
// Private, so a nested value is written without a second validation pass: the
// public encoder above already walked the whole tree, and a message with a
// hundred parts must not be walked a hundred times to find that out.

fn writePartContent(content: PartContent, writer: *json.Writer, base64: []u8) EncodeError!void {
    try writer.byte('{');
    switch (content) {
        .text => |text| {
            try writeMemberName(PartContent, 0, writer);
            try writer.string(text);
        },
        .raw => |raw| {
            try writeMemberName(PartContent, 1, writer);
            try writeBase64String(raw, base64, writer);
        },
        .url => |url| {
            try writeMemberName(PartContent, 2, writer);
            try writer.string(url);
        },
        .data => |data| {
            try writeMemberName(PartContent, 3, writer);
            // The lexeme the peer wrote, spliced. `Part.data` is a
            // `google.protobuf.Value` and may be any JSON value at all, so a
            // shape this library could decode would still not be able to write
            // a key a peer may send.
            try writer.slice(data);
        },
    }
    try writer.byte('}');
}

fn writePart(part: Part, writer: *json.Writer, base64: []u8) EncodeError!void {
    try writer.byte('{');
    // The `oneof` is fields 1 to 4 and `Part.fields[0]` carries no member
    // name, so the arm's name comes from the union's own row. It is always
    // written and it is always first, so the separator starts non-empty.
    switch (part.content) {
        .text => {
            try writeMemberName(PartContent, 0, writer);
            try writer.string(part.content.text);
        },
        .raw => {
            try writeMemberName(PartContent, 1, writer);
            try writeBase64String(part.content.raw, base64, writer);
        },
        .url => {
            try writeMemberName(PartContent, 2, writer);
            try writer.string(part.content.url);
        },
        .data => {
            try writeMemberName(PartContent, 3, writer);
            try writer.slice(part.content.data);
        },
    }
    const separator: []const u8 = ",";
    if (part.metadata) |metadata| {
        try writer.slice(separator);
        try writeMemberName(Part, 1, writer);
        try writer.slice(metadata);
    }
    if (part.filename) |filename| {
        try writer.slice(separator);
        try writeMemberName(Part, 2, writer);
        try writer.string(filename);
    }
    if (part.media_type) |media_type| {
        try writer.slice(separator);
        try writeMemberName(Part, 3, writer);
        try writer.string(media_type);
    }
    try writer.byte('}');
}

fn writeParts(parts: []const Part, writer: *json.Writer, base64: []u8) EncodeError!void {
    try writer.byte('[');
    for (parts, 0..) |part, index| {
        if (index != 0) try writer.byte(',');
        try writePart(part, writer, base64);
    }
    try writer.byte(']');
}

fn writeMessage(message: Message, writer: *json.Writer, base64: []u8) EncodeError!void {
    try writer.byte('{');
    try writeMemberName(Message, 0, writer);
    try writer.string(message.message_id);
    const separator: []const u8 = ",";
    if (message.context_id) |context_id| {
        try writer.slice(separator);
        try writeMemberName(Message, 1, writer);
        try writer.string(context_id);
    }
    if (message.task_id) |task_id| {
        try writer.slice(separator);
        try writeMemberName(Message, 2, writer);
        try writer.string(task_id);
    }
    try writer.slice(separator);
    try writeMemberName(Message, 3, writer);
    try writer.string(message.role.wireName());
    // `parts` is REQUIRED, so it is always written even when it is empty. An
    // encoder that omitted the empty array would answer a peer that sent `"parts":[]`
    // with a document that has no `parts` member at all.
    try writer.slice(separator);
    try writeMemberName(Message, 4, writer);
    try writeParts(message.parts, writer, base64);
    if (message.metadata) |metadata| {
        try writer.slice(separator);
        try writeMemberName(Message, 5, writer);
        try writer.slice(metadata);
    }
    if (message.extensions) |extensions| {
        try writer.slice(separator);
        try writeMemberName(Message, 6, writer);
        try writeStringList(extensions, writer);
    }
    if (message.reference_task_ids) |reference_task_ids| {
        try writer.slice(separator);
        try writeMemberName(Message, 7, writer);
        try writeStringList(reference_task_ids, writer);
    }
    try writer.byte('}');
}

fn writeArtifact(artifact: Artifact, writer: *json.Writer, base64: []u8) EncodeError!void {
    try writer.byte('{');
    try writeMemberName(Artifact, 0, writer);
    try writer.string(artifact.artifact_id);
    const separator: []const u8 = ",";
    if (artifact.name) |name| {
        try writer.slice(separator);
        try writeMemberName(Artifact, 1, writer);
        try writer.string(name);
    }
    if (artifact.description) |description| {
        try writer.slice(separator);
        try writeMemberName(Artifact, 2, writer);
        try writer.string(description);
    }
    try writer.slice(separator);
    try writeMemberName(Artifact, 3, writer);
    try writeParts(artifact.parts, writer, base64);
    if (artifact.metadata) |metadata| {
        try writer.slice(separator);
        try writeMemberName(Artifact, 4, writer);
        try writer.slice(metadata);
    }
    if (artifact.extensions) |extensions| {
        try writer.slice(separator);
        try writeMemberName(Artifact, 5, writer);
        try writeStringList(extensions, writer);
    }
    try writer.byte('}');
}

fn writeTaskStatus(status: TaskStatus, writer: *json.Writer, base64: []u8) EncodeError!void {
    try writer.byte('{');
    try writeMemberName(TaskStatus, 0, writer);
    try writer.string(status.state.wireName());
    const separator: []const u8 = ",";
    if (status.message) |message| {
        try writer.slice(separator);
        try writeMemberName(TaskStatus, 1, writer);
        try writeMessage(message, writer, base64);
    }
    if (status.timestamp) |timestamp| {
        try writer.slice(separator);
        try writeMemberName(TaskStatus, 2, writer);
        // The text the peer wrote, not a reformatted instant. The field is a
        // `google.protobuf.Timestamp` in the proto and ISO-8601 in JSON, and
        // normalising it here would replace the bytes that came in with bytes
        // this library chose.
        try writer.string(timestamp);
    }
    try writer.byte('}');
}

fn writeTask(task: Task, writer: *json.Writer, base64: []u8) EncodeError!void {
    try writer.byte('{');
    try writeMemberName(Task, 0, writer);
    try writer.string(task.id);
    const separator: []const u8 = ",";
    if (task.context_id) |context_id| {
        try writer.slice(separator);
        try writeMemberName(Task, 1, writer);
        try writer.string(context_id);
    }
    try writer.slice(separator);
    try writeMemberName(Task, 2, writer);
    try writeTaskStatus(task.status, writer, base64);
    if (task.artifacts) |artifacts| {
        try writer.slice(separator);
        try writeMemberName(Task, 3, writer);
        try writer.byte('[');
        for (artifacts, 0..) |artifact, index| {
            if (index != 0) try writer.byte(',');
            try writeArtifact(artifact, writer, base64);
        }
        try writer.byte(']');
    }
    if (task.history) |history| {
        try writer.slice(separator);
        try writeMemberName(Task, 4, writer);
        try writer.byte('[');
        for (history, 0..) |message, index| {
            if (index != 0) try writer.byte(',');
            try writeMessage(message, writer, base64);
        }
        try writer.byte(']');
    }
    if (task.metadata) |metadata| {
        try writer.slice(separator);
        try writeMemberName(Task, 5, writer);
        try writer.slice(metadata);
    }
    try writer.byte('}');
}

fn writeTaskStatusUpdateEvent(
    event: TaskStatusUpdateEvent,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try writer.byte('{');
    try writeMemberName(TaskStatusUpdateEvent, 0, writer);
    try writer.string(event.task_id);
    try writer.slice(",");
    try writeMemberName(TaskStatusUpdateEvent, 1, writer);
    try writer.string(event.context_id);
    try writer.slice(",");
    try writeMemberName(TaskStatusUpdateEvent, 2, writer);
    try writeTaskStatus(event.status, writer, base64);
    if (event.metadata) |metadata| {
        try writer.slice(",");
        try writeMemberName(TaskStatusUpdateEvent, 3, writer);
        try writer.slice(metadata);
    }
    try writer.byte('}');
}

fn writeTaskArtifactUpdateEvent(
    event: TaskArtifactUpdateEvent,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try writer.byte('{');
    try writeMemberName(TaskArtifactUpdateEvent, 0, writer);
    try writer.string(event.task_id);
    try writer.slice(",");
    try writeMemberName(TaskArtifactUpdateEvent, 1, writer);
    try writer.string(event.context_id);
    try writer.slice(",");
    try writeMemberName(TaskArtifactUpdateEvent, 2, writer);
    try writeArtifact(event.artifact, writer, base64);
    const separator: []const u8 = ",";
    if (event.append) |append| {
        try writer.slice(separator);
        try writeMemberName(TaskArtifactUpdateEvent, 3, writer);
        try writer.slice(if (append) "true" else "false");
    }
    if (event.last_chunk) |last_chunk| {
        try writer.slice(separator);
        try writeMemberName(TaskArtifactUpdateEvent, 4, writer);
        try writer.slice(if (last_chunk) "true" else "false");
    }
    if (event.metadata) |metadata| {
        try writer.slice(separator);
        try writeMemberName(TaskArtifactUpdateEvent, 5, writer);
        try writer.slice(metadata);
    }
    try writer.byte('}');
}

fn writeSendMessageRequest(
    request: SendMessageRequest,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try writer.byte('{');
    var separator: []const u8 = "";
    if (request.tenant) |tenant| {
        try writer.slice(separator);
        try writeMemberName(SendMessageRequest, 0, writer);
        try writer.string(tenant);
        separator = ",";
    }
    try writer.slice(separator);
    try writeMemberName(SendMessageRequest, 1, writer);
    try writeMessage(request.message, writer, base64);
    if (request.configuration) |configuration| {
        try writer.slice(",");
        try writeMemberName(SendMessageRequest, 2, writer);
        try writeSendMessageConfiguration(configuration, writer);
    }
    if (request.metadata) |metadata| {
        try writer.slice(",");
        try writeMemberName(SendMessageRequest, 3, writer);
        try writer.slice(metadata);
    }
    try writer.byte('}');
}

fn writeSendMessageResponse(
    response: SendMessageResponse,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try writer.byte('{');
    switch (response) {
        .task => |task| {
            try writeMemberName(SendMessageResponse, 0, writer);
            try writeTask(task, writer, base64);
        },
        .message => |message| {
            try writeMemberName(SendMessageResponse, 1, writer);
            try writeMessage(message, writer, base64);
        },
    }
    try writer.byte('}');
}

fn writeStreamResponse(
    response: StreamResponse,
    writer: *json.Writer,
    base64: []u8,
) EncodeError!void {
    try writer.byte('{');
    switch (response) {
        .task => |task| {
            try writeMemberName(StreamResponse, 0, writer);
            try writeTask(task, writer, base64);
        },
        .message => |message| {
            try writeMemberName(StreamResponse, 1, writer);
            try writeMessage(message, writer, base64);
        },
        .status_update => |event| {
            try writeMemberName(StreamResponse, 2, writer);
            try writeTaskStatusUpdateEvent(event, writer, base64);
        },
        .artifact_update => |event| {
            try writeMemberName(StreamResponse, 3, writer);
            try writeTaskArtifactUpdateEvent(event, writer, base64);
        },
    }
    try writer.byte('}');
}

const testing = std.testing;

/// Assert that every `oneof` member's field number is its tag ordinal plus one.
///
/// The comptime guard ties a member to its row. This ties the row to the tag
/// ordinal a codec switches on, which is the number that looks like the field
/// number and is not.
fn expectUnionOrdinals(comptime U: type) !void {
    // The five `oneof` types are tagged unions, so the unwrap cannot fail here.
    const tag_type = @typeInfo(U).@"union".tag_type.?;
    inline for (@typeInfo(tag_type).@"enum".fields, 0..) |tag, index| {
        const ordinal: usize = @intCast(@intFromEnum(@field(tag_type, tag.name)));
        try testing.expectEqual(index, ordinal);
        try testing.expectEqual(index + 1, U.fields[index].number);
    }
}

test "a oneof field number is the tag ordinal plus one" {
    // A `union(enum)` tag is 0-based, so the member at ordinal 0 is field 1. A
    // codec that takes `@intFromEnum(tag)` for the number writes every oneof
    // field one below where the proto puts it, so a part's `text` arrives as a
    // part's `raw` and a stream's `artifact_update` as its `task`.
    try expectUnionOrdinals(PartContent);
    try expectUnionOrdinals(SendMessageResponse);
    try expectUnionOrdinals(StreamResponse);
    try expectUnionOrdinals(SecurityScheme);
    try expectUnionOrdinals(OAuthFlows);

    // The first member of each union is field 1 and the last is field N, so the
    // offset is one at both ends rather than somewhere in the middle.
    try testing.expectEqual(@as(u32, 1), fieldNumber(PartContent, 0));
    try testing.expectEqual(@as(u32, 4), fieldNumber(PartContent, 3));
    try testing.expectEqual(@as(u32, 1), fieldNumber(SendMessageResponse, 0));
    try testing.expectEqual(@as(u32, 1), fieldNumber(StreamResponse, 0));
    try testing.expectEqual(@as(u32, 4), fieldNumber(StreamResponse, 3));
    try testing.expectEqual(@as(u32, 1), fieldNumber(SecurityScheme, 0));
    try testing.expectEqual(@as(u32, 5), fieldNumber(SecurityScheme, 4));
    try testing.expectEqual(@as(u32, 1), fieldNumber(OAuthFlows, 0));
    try testing.expectEqual(@as(u32, 5), fieldNumber(OAuthFlows, 4));
}

test "a field name is the snake_case form of the name ProtoJSON writes" {
    // The rule is why a row carries a `zig_name` at all: the proto spells a field
    // in snake_case and ProtoJSON in camelCase, so the Zig name follows from the
    // member name. A codec that wrote the Zig spelling would send `context_id`
    // where a peer reads `contextId`.
    try testing.expectEqualStrings("context_id", snakeCaseName("contextId"));
    try testing.expectEqualStrings("icon_url", snakeCaseName("iconUrl"));
    try testing.expectEqualStrings(
        "status_timestamp_after",
        snakeCaseName("statusTimestampAfter"),
    );
    // A digit takes no underscore, so `oauth2MetadataUrl` gives
    // `oauth2_metadata_url` and not `oauth_2_metadata_url`.
    try testing.expectEqualStrings("oauth2_metadata_url", snakeCaseName("oauth2MetadataUrl"));
    try testing.expectEqualStrings("list", snakeCaseName("list"));

    // Every field of a message follows the rule, with no override in sight.
    inline for (@typeInfo(AgentCard).@"struct".fields, 0..) |member, index| {
        try testing.expectEqualStrings(
            member.name,
            snakeCaseName(jsonName(AgentCard, index).?),
        );
    }
    inline for (@typeInfo(ListTasksRequest).@"struct".fields, 0..) |member, index| {
        try testing.expectEqualStrings(
            member.name,
            snakeCaseName(jsonName(ListTasksRequest, index).?),
        );
    }
}

test "the five SecurityScheme arms are the only overridden names" {
    // ProtoJSON spells the arms with the full `SecurityScheme` suffix and the Zig
    // names drop it, so all five rows override the derivation and no other row
    // in the file does.
    try testing.expectEqualStrings("apiKeySecurityScheme", jsonName(SecurityScheme, 0).?);
    try testing.expectEqualStrings("httpAuthSecurityScheme", jsonName(SecurityScheme, 1).?);
    try testing.expectEqualStrings("oauth2SecurityScheme", jsonName(SecurityScheme, 2).?);
    try testing.expectEqualStrings("openIdConnectSecurityScheme", jsonName(SecurityScheme, 3).?);
    try testing.expectEqualStrings("mtlsSecurityScheme", jsonName(SecurityScheme, 4).?);
    // The derivation would be `api_key_security_scheme`, which is neither the
    // normative name nor the Zig one, so the row has to say which it means.
    try testing.expectEqualStrings(
        "api_key_security_scheme",
        snakeCaseName(jsonName(SecurityScheme, 0).?),
    );
    // Every other union arm follows the rule with no override.
    try testing.expectEqualStrings(
        "authorization_code",
        snakeCaseName(jsonName(OAuthFlows, 0).?),
    );
    try testing.expectEqualStrings(
        "status_update",
        snakeCaseName(jsonName(StreamResponse, 2).?),
    );
}

test "a map entry has no member name because its key is data" {
    // ProtoJSON renders one map entry as the single member its key names, so
    // neither half of the entry is a member of its own and `jsonName` is null on
    // both rows. A decoder that walked the struct would look for `name` and
    // `list`, and no peer sends either.
    try testing.expectEqual(@as(?[]const u8, null), jsonName(SecurityRequirementEntry, 0));
    try testing.expectEqual(@as(?[]const u8, null), jsonName(SecurityRequirementEntry, 1));
    try testing.expectEqual(@as(?[]const u8, null), jsonName(SecuritySchemeEntry, 0));
    try testing.expectEqual(@as(?[]const u8, null), jsonName(SecuritySchemeEntry, 1));
    try testing.expectEqual(@as(?[]const u8, null), jsonName(OAuthScope, 0));
    try testing.expectEqual(@as(?[]const u8, null), jsonName(OAuthScope, 1));
    // The key is field 1 and the value field 2, on all three.
    try testing.expectEqual(@as(u32, 1), fieldNumber(OAuthScope, 0));
    try testing.expectEqual(@as(u32, 2), fieldNumber(OAuthScope, 1));
    // A `oneof` the struct holds as one field is the other null case.
    try testing.expectEqual(@as(?[]const u8, null), jsonName(Part, 0));
    try testing.expectEqualStrings("mediaType", jsonName(Part, 3).?);
}

test "findField resolves a member name and rejects one the message does not carry" {
    // `findField` returns a 0-based row index and `fieldNumber` returns the
    // number a protobuf encoder emits, so the two are one apart and are not
    // interchangeable: `supportedInterfaces` is field 3 and row 2.
    try testing.expectEqual(@as(?usize, 2), findField(AgentCard, "supportedInterfaces"));
    try testing.expectEqual(@as(u32, 3), fieldNumber(AgentCard, 2));
    try testing.expectEqual(@as(?usize, 13), findField(AgentCard, "iconUrl"));
    try testing.expectEqual(@as(?usize, 6), findField(ListTasksRequest, "statusTimestampAfter"));
    try testing.expectEqual(@as(?usize, 0), findField(SecurityScheme, "apiKeySecurityScheme"));
    // The Zig spelling is not the member name, so a decoder that asked for it
    // gets null rather than the field it meant.
    try testing.expectEqual(@as(?usize, null), findField(AgentCard, "icon_url"));
    try testing.expectEqual(@as(?usize, null), findField(AgentCard, "supported_interfaces"));
    // A name no revision of this protocol carries is null too.
    try testing.expectEqual(@as(?usize, null), findField(AgentCard, "protocolVersion"));
    // A row with no member name of its own is found under nothing.
    try testing.expectEqual(@as(?usize, null), findField(OAuthScope, "name"));
}

test "the protobuf package carries the lf prefix" {
    try testing.expectEqualStrings("lf.a2a.v1", protobuf_package);
    // `a2a.v1` alone is the assumption the extraction flagged as wrong.
    try testing.expect(!std.mem.eql(u8, protobuf_package, "a2a.v1"));
    try testing.expectEqualStrings("lf.a2a.v1.A2AService", grpc_service);
}

test "TaskState tags match the proto exactly" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(TaskState.unspecified));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(TaskState.submitted));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(TaskState.working));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(TaskState.completed));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(TaskState.failed));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(TaskState.canceled));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(TaskState.input_required));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(TaskState.rejected));
    try testing.expectEqual(@as(u8, 8), @intFromEnum(TaskState.auth_required));
}

test "TASK_STATE_CANCELED is spelled with one L" {
    // The two-L spelling appears in ACP and in the tasks extension. A2A does
    // not use it, and matching it here would accept a value no peer sends.
    try testing.expectEqualStrings("TASK_STATE_CANCELED", TaskState.canceled.wireName());
    try testing.expectEqual(@as(?TaskState, null), TaskState.fromWireName("TASK_STATE_CANCELLED"));
    // And the round trip is exact.
    inline for (@typeInfo(TaskState).@"enum".fields) |field| {
        const value: TaskState = @field(TaskState, field.name);
        try testing.expectEqual(value, try TaskState.parse(value.wireName()));
    }
}

test "an unknown TaskState tag is UnknownTag, not a fallback to unspecified" {
    try testing.expectError(error.UnknownTag, TaskState.parse("TASK_STATE_UNKNOWN"));
    try testing.expectError(error.UnknownTag, TaskState.parse("submitted"));
    try testing.expectError(error.UnknownTag, TaskState.parse("TASK_STATE_CANCELLED"));
}

test "Role tags and wire names match" {
    try testing.expectEqualStrings("ROLE_UNSPECIFIED", Role.unspecified.wireName());
    try testing.expectEqualStrings("ROLE_USER", Role.user.wireName());
    try testing.expectEqualStrings("ROLE_AGENT", Role.agent.wireName());
    // The short forms are not the wire form.
    try testing.expectError(error.UnknownTag, Role.parse("user"));
    try testing.expectEqual(Role.agent, try Role.parse("ROLE_AGENT"));
}

test "a numeric TaskState tag decodes and one above the range is UnknownTag" {
    inline for (@typeInfo(TaskState).@"enum".fields) |field| {
        const value: TaskState = @field(TaskState, field.name);
        try testing.expectEqual(value, try TaskState.fromTag(@intFromEnum(value)));
    }
    try testing.expectEqual(@as(u8, 8), task_state_max);
    try testing.expectEqual(TaskState.auth_required, try TaskState.fromTag(8));
    // Above the declared range. This must not read as `unspecified`: a peer on
    // a newer revision is not a peer that said nothing.
    try testing.expectError(error.UnknownTag, TaskState.fromTag(9));
    try testing.expectError(error.UnknownTag, TaskState.fromTag(255));
}

test "a numeric Role tag decodes and one above the range is UnknownTag" {
    try testing.expectEqual(@as(u8, 2), role_max);
    try testing.expectEqual(Role.unspecified, try Role.fromTag(0));
    try testing.expectEqual(Role.agent, try Role.fromTag(2));
    try testing.expectError(error.UnknownTag, Role.fromTag(3));
}

test "returnImmediately is a plain bool whose false means blocking" {
    // The proto declares the field singular, so there is no third state
    // between absent and false on the wire, and `null` is not a value a peer
    // sends. The Zig field is `?bool` anyway, because absent and false are the
    // same answer and two different documents, and a decoder that recorded
    // only the answer could not write the document back.
    const blocking: SendMessageConfiguration = .{};
    try testing.expectEqual(@as(?bool, null), blocking.return_immediately);
    const immediate: SendMessageConfiguration = .{ .return_immediately = true };
    try testing.expectEqual(@as(?bool, true), immediate.return_immediately);
    // The inversion matters: false blocks, so a caller that ignores the flag
    // waits, and one that reads it as 0.3's `blocking` waits too. An absent
    // member is the same call, so a caller reads null as blocking.
    try testing.expect(!(blocking.return_immediately orelse false));
}

test "the terminal set is the four stated states" {
    try testing.expectEqual(@as(usize, 4), terminal_states.len);
    try testing.expect(isTerminal(.completed));
    try testing.expect(isTerminal(.failed));
    try testing.expect(isTerminal(.canceled));
    try testing.expect(isTerminal(.rejected));
    // Submitted and working are not terminal, and input_required is not.
    try testing.expect(!isTerminal(.submitted));
    try testing.expect(!isTerminal(.working));
    try testing.expect(!isTerminal(.input_required));
    try testing.expect(!isTerminal(.unspecified));
}

test "the interrupted set is the two stated states" {
    try testing.expectEqual(@as(usize, 2), interrupted_states.len);
    try testing.expect(isInterrupted(.input_required));
    try testing.expect(isInterrupted(.auth_required));
    try testing.expect(!isInterrupted(.working));
}

test "the service parameter prefix is not the stem of the parameter names" {
    // The specification writes both names mixed case and declares the lowercase
    // `a2a-` prefix for coexistence with transport-defined parameters, so the
    // prefix is a family the names belong to, not a stem they are built from.
    // Composing one from it would send `a2a-version` where the registered name
    // is `A2A-Version`, and that is a name no primary source establishes.
    try testing.expectEqualStrings("a2a-", service_parameter_prefix);
    try testing.expectEqualStrings("A2A-Version", version_parameter);
    try testing.expectEqualStrings("A2A-Extensions", extensions_parameter);
    try testing.expect(!std.mem.eql(u8, service_parameter_prefix ++ "version", version_parameter));
    try testing.expect(!std.mem.eql(u8, service_parameter_prefix ++ "extensions", extensions_parameter));
}

test "an empty A2A-Version means 0.3" {
    const version = try parseVersion("");
    try testing.expectEqual(@as(u16, 0), version.major);
    try testing.expectEqual(@as(u16, 3), version.minor);
}

test "A2A-Version is Major.Minor with no patch component" {
    const one_zero = try parseVersion("1.0");
    try testing.expectEqual(@as(u16, 1), one_zero.major);
    try testing.expectEqual(@as(u16, 0), one_zero.minor);

    const zero_three = try parseVersion("0.3");
    try testing.expectEqual(@as(u16, 3), zero_three.minor);

    // A patch component must not appear, and is not silently truncated.
    try testing.expectError(error.InvalidField, parseVersion("1.0.0"));
    try testing.expectError(error.InvalidField, parseVersion("0.3.1"));
    try testing.expectError(error.InvalidField, parseVersion("1"));
    try testing.expectError(error.InvalidField, parseVersion("1."));
    try testing.expectError(error.InvalidField, parseVersion("x.y"));
}

test "a version round-trips through its Major.Minor form" {
    var buffer: [16]u8 = undefined;
    const text = try (Version{ .major = 1, .minor = 0 }).format(&buffer);
    try testing.expectEqualStrings("1.0", text);
    const parsed = try parseVersion(text);
    try testing.expectEqual(@as(u16, 1), parsed.major);
    try testing.expectEqual(@as(u16, 0), parsed.minor);
}

test "0.3 uses the slash form and aliases exactly four names" {
    const zero_three: Version = .{ .major = 0, .minor = 3 };
    const one_zero: Version = .{ .major = 1, .minor = 0 };

    try testing.expectEqual(@as(usize, 4), v0_3_method_aliases.len);
    for (v0_3_method_aliases) |alias| {
        // What a 0.3 peer sends is the slash form, and only that is valid.
        try testing.expect(isMethodValidAt(zero_three, alias.v0_3));
        try testing.expect(!isMethodValidAt(one_zero, alias.v0_3));
        // The table resolves it to the 1.0 RPC, which is the reverse mapping.
        try testing.expectEqualStrings(alias.v1_0, aliasToCurrent(alias.v0_3).?);
        try testing.expect(isMethodValidAt(one_zero, alias.v1_0));
        // And the 1.0 name is not a 0.3 name: that spelling did not exist then.
        try testing.expect(!isMethodValidAt(zero_three, alias.v1_0));
    }
    try testing.expectEqualStrings("SendMessage", aliasToCurrent("message/send").?);
    try testing.expectEqualStrings("CancelTask", aliasToCurrent("tasks/cancel").?);
    try testing.expectEqual(@as(?[]const u8, null), aliasToCurrent("SendMessage"));
    try testing.expectEqual(@as(?[]const u8, null), aliasToCurrent("message/get"));

    // Everything outside the four is -32601 at 0.3, including the fifth 0.3
    // slash name, which the specification does not alias.
    try testing.expect(!isMethodValidAt(zero_three, "ListTasks"));
    try testing.expect(!isMethodValidAt(zero_three, "GetExtendedAgentCard"));
    try testing.expect(!isMethodValidAt(zero_three, "tasks/resubscribe"));
    // At 1.0 the RPC names stand, aliased or not.
    for (rpcs) |rpc| {
        try testing.expect(isMethodValidAt(one_zero, rpc.name));
    }
}

test "an unimplemented version answers no method at all" {
    const one_zero: Version = .{ .major = 1, .minor = 0 };
    const zero_three: Version = .{ .major = 0, .minor = 3 };
    const two_zero: Version = .{ .major = 2, .minor = 0 };
    const zero_five: Version = .{ .major = 0, .minor = 5 };

    try testing.expect(isVersionSupported(one_zero));
    try testing.expect(isVersionSupported(zero_three));
    // `2.0` is not this library, `0.5` never existed, and `1.1` is not `1.0`.
    try testing.expect(!isVersionSupported(two_zero));
    try testing.expect(!isVersionSupported(zero_five));
    try testing.expect(!isVersionSupported(.{ .major = 1, .minor = 1 }));

    // Every method is invalid at an unimplemented version, so the caller can
    // raise VersionNotSupportedError instead of a bare method-not-found.
    for (rpcs) |rpc| {
        try testing.expect(!isMethodValidAt(two_zero, rpc.name));
        try testing.expect(!isMethodValidAt(zero_five, rpc.name));
    }
    try testing.expectEqual(@as(i32, -32009), @intFromEnum(A2aError.version_not_supported));
    try testing.expectEqualStrings(
        "VERSION_NOT_SUPPORTED",
        A2aError.version_not_supported.reason(),
    );
}

test "there is no mandatory binding and eleven RPCs are declared" {
    try testing.expectEqual(@as(usize, 11), rpcs.len);
    // Three core bindings, and an agent picks the first it supports.
    try testing.expectEqual(@as(usize, 3), core_bindings.len);
}

test "every RPC has a tenant-prefixed secondary binding" {
    try testing.expectEqualStrings("/{tenant}/message:send", tenantBindingPath("SendMessage").?);
    try testing.expectEqualStrings("/{tenant}/tasks/{id}", tenantBindingPath("GetTask").?);
    // A name that is not an RPC has no binding.
    try testing.expectEqual(@as(?[]const u8, null), tenantBindingPath("MessageSend"));
    for (rpcs) |rpc| {
        const tenant_path = tenantBindingPath(rpc.name).?;
        try testing.expect(std.mem.startsWith(u8, tenant_path, tenant_binding_prefix));
        // The prefix is added, not moved: the primary binding still stands.
        try testing.expectEqualStrings(
            rpc.http.path,
            tenant_path[tenant_binding_prefix.len..],
        );
    }
}

test "the delete RPC returns the empty message, not a config" {
    var deletes: usize = 0;
    var empty_responses: usize = 0;
    for (rpcs) |rpc| {
        if (std.mem.eql(u8, rpc.response, "google.protobuf.Empty")) empty_responses += 1;
        if (!std.mem.eql(u8, rpc.name, "DeleteTaskPushNotificationConfig")) continue;
        deletes += 1;
        // A delete returns nothing to read back, so decoding a config here
        // would wait for a body the peer never sends.
        try testing.expectEqualStrings("google.protobuf.Empty", rpc.response);
        try testing.expectEqualStrings("DeleteTaskPushNotificationConfigRequest", rpc.request);
    }
    try testing.expectEqual(@as(usize, 1), deletes);
    // Empty is this RPC's alone; the other ten return a real message.
    try testing.expectEqual(@as(usize, 1), empty_responses);
}

test "the two streaming RPCs are marked as such" {
    var streaming: usize = 0;
    for (rpcs) |rpc| {
        if (rpc.streaming) streaming += 1;
    }
    try testing.expectEqual(@as(usize, 2), streaming);
}

test "page size bounds are 1 to 100 with a default cap of 50" {
    try testing.expect(isValidPageSize(1));
    try testing.expect(isValidPageSize(50));
    try testing.expect(isValidPageSize(100));
    try testing.expect(!isValidPageSize(0));
    try testing.expect(!isValidPageSize(101));
    try testing.expectEqual(@as(i32, 50), page_size_default);
}

test "an empty nextPageToken means the last page, and absence is an error" {
    try testing.expect(!hasNextPage(""));
    try testing.expect(hasNextPage("cursor-1"));
}

test "the nine A2A error codes match the table" {
    try testing.expectEqual(@as(i32, -32001), @intFromEnum(A2aError.task_not_found));
    try testing.expectEqual(@as(i32, -32002), @intFromEnum(A2aError.task_not_cancelable));
    try testing.expectEqual(@as(i32, -32003), @intFromEnum(A2aError.push_notification_not_supported));
    try testing.expectEqual(@as(i32, -32004), @intFromEnum(A2aError.unsupported_operation));
    try testing.expectEqual(@as(i32, -32005), @intFromEnum(A2aError.content_type_not_supported));
    try testing.expectEqual(@as(i32, -32006), @intFromEnum(A2aError.invalid_agent_response));
    try testing.expectEqual(@as(i32, -32007), @intFromEnum(A2aError.extended_agent_card_not_configured));
    try testing.expectEqual(@as(i32, -32008), @intFromEnum(A2aError.extension_support_required));
    try testing.expectEqual(@as(i32, -32009), @intFromEnum(A2aError.version_not_supported));
    // All nine sit inside the range the specification states.
    inline for (@typeInfo(A2aError).@"enum".fields) |field| {
        const value: i32 = @intFromEnum(@field(A2aError, field.name));
        try testing.expect(value >= error_range_min and value <= error_range_max);
    }
}

test "the reason is the type name in upper snake case" {
    try testing.expectEqualStrings("TASK_NOT_FOUND", A2aError.task_not_found.reason());
    try testing.expectEqualStrings("TASK_NOT_CANCELABLE", A2aError.task_not_cancelable.reason());
    try testing.expectEqual(
        A2aError.task_not_found,
        errorForReason("TASK_NOT_FOUND").?,
    );
    try testing.expectEqual(@as(?A2aError, null), errorForReason("TASK_GONE"));
}

test "six of the nine errors collapse onto one status pair" {
    var failed_precondition: usize = 0;
    var bad_request: usize = 0;
    inline for (@typeInfo(A2aError).@"enum".fields) |field| {
        const value: A2aError = @field(A2aError, field.name);
        if (std.mem.eql(u8, value.grpcStatus(), GrpcStatus.failed_precondition)) {
            failed_precondition += 1;
        }
        if (value.httpStatus() == 400) bad_request += 1;
    }
    try testing.expectEqual(@as(usize, 6), failed_precondition);
    try testing.expectEqual(@as(usize, 7), bad_request);
    // The HTTP status is therefore not discriminating, which is why the reason
    // is the only way to tell these apart.
    try testing.expectEqual(
        A2aError.unsupported_operation.httpStatus(),
        A2aError.extension_support_required.httpStatus(),
    );
}

test "a reason classifies to its error and an unknown one stays unmapped" {
    // A reason this library knows resolves. PROTOCOLS.md section 5.6 keys the
    // decoder on the reason, so collapsing a known one into the unmapped
    // variant throws away the only thing that tells the errors apart.
    const known = classifyReason(error_domain, "TASK_NOT_FOUND");
    try testing.expect(known == .known);
    try testing.expectEqual(A2aError.task_not_found, known.known);
    try testing.expectEqual(A2aError.task_not_found, errorForReason(known.known.reason()).?);

    // One of the six that share HTTP 400 and FAILED_PRECONDITION, so the reason
    // really is the only thing that carries it.
    const collapsed = classifyReason(error_domain, "EXTENSION_SUPPORT_REQUIRED");
    try testing.expect(collapsed == .known);
    try testing.expectEqual(A2aError.extension_support_required, collapsed.known);

    // A reason this library does not know stays unknown; it is never mapped
    // onto the closest known error.
    const future = classifyReason(error_domain, "TASK_EXPIRED");
    try testing.expect(future == .unknown_a2a);
    try testing.expectEqualStrings("TASK_EXPIRED", future.unknown_a2a);
    try testing.expectEqual(@as(?A2aError, null), errorForReason(future.unknown_a2a));

    // The domain decides before the reason does, so a known reason under a
    // foreign domain is still not an A2A error.
    const foreign = classifyReason("example.com", "TASK_NOT_FOUND");
    try testing.expect(foreign == .other_domain);
    try testing.expectEqualStrings("example.com", foreign.other_domain.domain);

    const bare = classifyReason(null, "TASK_NOT_FOUND");
    try testing.expect(bare == .missing_domain);
    try testing.expectEqualStrings("TASK_NOT_FOUND", bare.missing_domain);
}

test "the API key location accepts exactly the three stated values" {
    try testing.expectEqual(ApiKeyLocation.query, try ApiKeyLocation.parse("query"));
    try testing.expectEqual(ApiKeyLocation.header, try ApiKeyLocation.parse("header"));
    try testing.expectEqual(ApiKeyLocation.cookie, try ApiKeyLocation.parse("cookie"));
    try testing.expectError(error.UnknownTag, ApiKeyLocation.parse("Query"));
    try testing.expectError(error.UnknownTag, ApiKeyLocation.parse("body"));
}

test "an API key location renders the spelling the location field carries" {
    // `parse` accepts three exact strings and nothing else, so a receiver that
    // writes the location back out, or compares two cards for it, has to render
    // the same three. A renderer that emitted `Query` or `HEADER` would write a
    // value its own `parse` rejects.
    try testing.expectEqualStrings("query", ApiKeyLocation.query.string());
    try testing.expectEqualStrings("header", ApiKeyLocation.header.string());
    try testing.expectEqualStrings("cookie", ApiKeyLocation.cookie.string());
    inline for (@typeInfo(ApiKeyLocation).@"enum".fields) |field| {
        const value: ApiKeyLocation = @field(ApiKeyLocation, field.name);
        try testing.expectEqual(value, try ApiKeyLocation.parse(value.string()));
    }
}

test "a required extension that is not activated is -32008" {
    const activations = [_][]const u8{"https://example.com/extensions/geolocation/v1"};
    const other = "https://example.com/extensions/citations/v1";

    // The activated extension satisfies its own requirement.
    try testing.expect(extensionSatisfied(&activations, true, activations[0]));
    // A required extension that was not activated is not satisfied, and the
    // caller raises `ExtensionSupportRequiredError` in response. The
    // specification also forbids falling back to another version, so there is
    // no substitution to make here.
    try testing.expect(!extensionSatisfied(&activations, true, other));
    // An extension that is not required may simply be skipped.
    try testing.expect(extensionSatisfied(&activations, false, other));
    try testing.expectEqual(@as(i32, -32008), @intFromEnum(extension_missing_error));
}

test "an AgentInterface carries a protocol version with no patch component" {
    try testing.expectEqual(@as(u32, 4), fieldNumber(AgentInterface, 3));
    try testing.expectEqualStrings("protocolVersion", jsonName(AgentInterface, 3).?);
    // Field 4 is the `Major.Minor` version, so this is the whole required set:
    // `url` and `protocol_binding` are the other two, and `tenant` is optional.
    const interface: AgentInterface = .{
        .url = "https://api.example.com/a2a/v1",
        .protocol_binding = binding.jsonrpc,
        .protocol_version = "1.0",
    };
    try testing.expectEqualStrings("JSONRPC", interface.protocol_binding);
    try testing.expectEqual(@as(?[]const u8, null), interface.tenant);
    // The version parses, and the patch form the `A2A-Version` header rejects is
    // the same form an interface must not publish, so both go through the one
    // parser rather than two rules that can drift.
    const parsed = try parseVersion(interface.protocol_version);
    try testing.expectEqual(@as(u16, 1), parsed.major);
    try testing.expectEqual(@as(u16, 0), parsed.minor);
    try testing.expectError(error.InvalidField, parseVersion("1.0.0"));
    try testing.expectEqual(@as(u16, 3), (try parseVersion("0.3")).minor);
}

test "the agent card field range leaves 15 free" {
    try testing.expectEqual(@as(usize, 14), AgentCard.fields.len);
    // The highest number the card uses is 14, so 15 is the lowest free one.
    try testing.expectEqual(@as(u32, 14), fieldNumber(AgentCard, 13));
    try testing.expectEqual(@as(i32, 20), agent_card_next_id);
    try testing.expectEqual(@as(usize, 5), removed_agent_card_fields.len);
}

test "AuthenticationInfo requires a scheme and keeps credentials optional" {
    try testing.expectEqualStrings("credentials", jsonName(AuthenticationInfo, 1).?);
    // `scheme` is the only REQUIRED field, so it is the only one a minimal
    // value has to set, and a missing credential is not an empty credential.
    const info: AuthenticationInfo = .{ .scheme = "Bearer" };
    try testing.expectEqualStrings("Bearer", info.scheme);
    try testing.expectEqual(@as(?[]const u8, null), info.credentials);
}

test "TaskPushNotificationConfig numbers the webhook url 4 and its token 5" {
    // The test name says so, and a codec reads both numbers from the table.
    try testing.expectEqual(@as(u32, 4), fieldNumber(TaskPushNotificationConfig, 3));
    try testing.expectEqual(@as(u32, 5), fieldNumber(TaskPushNotificationConfig, 4));
    // `url` is the only REQUIRED field. The rest is what a server fills in on
    // create, so a client that knows only where to post can still build one.
    const config: TaskPushNotificationConfig = .{
        .url = "https://client.example.com/a2a/webhook",
    };
    try testing.expectEqual(@as(?AuthenticationInfo, null), config.authentication);
    try testing.expectEqual(@as(?[]const u8, null), config.token);
    // `SendMessageConfiguration` field 2 carries the same message rather than
    // an opaque string, so a client can read the URL it will be called on.
    const configuration: SendMessageConfiguration = .{
        .task_push_notification_config = config,
    };
    try testing.expectEqualStrings(
        "https://client.example.com/a2a/webhook",
        configuration.task_push_notification_config.?.url,
    );
    // The create RPC takes and returns this one message, so the name the RPC
    // table carries names a type and not a spelling.
    var create_bodies: usize = 0;
    for (rpcs) |rpc| {
        if (!std.mem.eql(u8, rpc.request, "TaskPushNotificationConfig")) continue;
        try testing.expectEqualStrings("TaskPushNotificationConfig", rpc.response);
        create_bodies += 1;
    }
    try testing.expectEqual(@as(usize, 1), create_bodies);
}

test "StringList is field 1 and keeps the singular JSON name" {
    try testing.expectEqual(@as(u32, 1), fieldNumber(StringList, 0));
    try testing.expectEqualStrings("list", jsonName(StringList, 0).?);
    // The proto disables the pluralisation lint on this message, so the wire
    // name is `list`. A decoder that looked for `lists` would read nothing.
    const scopes: StringList = .{ .list = &.{ "openid", "a2a.tasks" } };
    try testing.expectEqual(@as(usize, 2), scopes.list.len);
    try testing.expectEqualStrings("a2a.tasks", scopes.list[1]);
}

test "a security requirement maps a scheme name to the scopes it needs" {
    try testing.expectEqual(@as(u32, 1), fieldNumber(SecurityRequirement, 0));
    try testing.expectEqual(@as(?[]const u8, null), jsonName(SecurityRequirementEntry, 0));
    const requirement: SecurityRequirement = .{ .schemes = &.{
        .{ .name = "oauth", .list = .{ .list = &.{"a2a.tasks"} } },
    } };
    try testing.expectEqual(@as(usize, 1), requirement.schemes.len);
    try testing.expectEqualStrings("oauth", requirement.schemes[0].name);
    try testing.expectEqualStrings("a2a.tasks", requirement.schemes[0].list.list[0]);
}

test "a card scheme entry pairs the name a requirement names with its scheme" {
    try testing.expectEqual(@as(u32, 1), fieldNumber(SecuritySchemeEntry, 0));
    try testing.expectEqual(@as(?[]const u8, null), jsonName(SecuritySchemeEntry, 1));
    const entries = [_]SecuritySchemeEntry{.{
        .name = "oauth",
        .scheme = .{ .oauth2 = .{
            .flows = .{ .client_credentials = .{
                .token_url = "https://auth.example.com/token",
                .scopes = &.{.{ .name = "a2a.tasks", .description = "Task access" }},
            } },
        } },
    }};
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("oauth", entries[0].name);
    try testing.expect(entries[0].scheme == .oauth2);
}

test "AgentProvider requires both a url and an organization" {
    try testing.expectEqualStrings("organization", jsonName(AgentProvider, 1).?);
    const provider: AgentProvider = .{
        .url = "https://example.com",
        .organization = "Example",
    };
    try testing.expectEqualStrings("Example", provider.organization);
}

test "an unset capability is not a capability of false" {
    try testing.expectEqual(@as(u32, 2), fieldNumber(AgentCapabilities, 1));
    try testing.expectEqualStrings("extendedAgentCard", jsonName(AgentCapabilities, 3).?);
    // The three booleans are proto3 `optional`, so absent and false are
    // different answers and only presence records which one a peer sent.
    const unset: AgentCapabilities = .{};
    try testing.expectEqual(@as(?bool, null), unset.streaming);
    try testing.expectEqual(@as(?bool, null), unset.push_notifications);
    try testing.expectEqual(@as(?bool, null), unset.extended_agent_card);
    try testing.expectEqual(@as(usize, 0), unset.extensions.len);
    const declined: AgentCapabilities = .{ .streaming = false };
    try testing.expectEqual(@as(?bool, false), declined.streaming);
}

test "AgentExtension carries required at 3 and its settings at 4" {
    // The test name says so, and the member names are what a peer sends.
    try testing.expectEqual(@as(u32, 3), fieldNumber(AgentExtension, 2));
    try testing.expectEqual(@as(u32, 4), fieldNumber(AgentExtension, 3));
    try testing.expectEqualStrings("params", jsonName(AgentExtension, 3).?);
    // `required` is a singular bool on the wire, so a peer writes `false`
    // rather than omitting it, and this field records which of the two arrived.
    const uri = "https://example.com/extensions/geolocation/v1";
    const extension: AgentExtension = .{ .uri = uri };
    try testing.expectEqual(@as(?bool, null), extension.required);
    try testing.expectEqual(@as(?[]const u8, null), extension.params);
    const demanding: AgentExtension = .{ .uri = uri, .required = true };
    try testing.expectEqual(@as(?bool, true), demanding.required);
    // A required extension the client did not activate is -32008, not a
    // silent skip, and the same extension activated does satisfy it.
    const other = [_][]const u8{"https://example.com/extensions/citations/v1"};
    try testing.expect(!extensionSatisfied(&other, demanding.required orelse false, uri));
    try testing.expect(extensionSatisfied(&.{uri}, demanding.required orelse false, uri));
    // A declaration that does not demand the extension is satisfied by an
    // activation list that does not carry it, whether it said so or not.
    try testing.expect(extensionSatisfied(&other, extension.required orelse false, uri));
}

test "AgentSkill numbers four required fields ahead of four optional ones" {
    try testing.expectEqual(@as(u32, 4), fieldNumber(AgentSkill, 3));
    try testing.expectEqualStrings("securityRequirements", jsonName(AgentSkill, 7).?);
    // Fields 1 to 4 are REQUIRED, so a minimal skill says what it is and how
    // to find it. Fields 5 to 8 narrow it or secure it.
    const skill: AgentSkill = .{
        .id = "forecast",
        .name = "Forecast",
        .description = "A seven-day forecast.",
        .tags = &.{"weather"},
    };
    try testing.expectEqual(@as(usize, 0), skill.examples.len);
    try testing.expectEqual(@as(usize, 0), skill.input_modes.len);
    try testing.expectEqual(@as(usize, 0), skill.output_modes.len);
    try testing.expectEqual(@as(usize, 0), skill.security_requirements.len);
    try testing.expectEqual(@as(u32, 8), fieldNumber(AgentSkill, 7));
}

test "the AgentCard requires exactly the eight fields the proto marks required" {
    try testing.expectEqual(@as(usize, 14), AgentCard.fields.len);
    const interfaces = [_]AgentInterface{.{
        .url = "https://api.example.com/a2a/v1",
        .protocol_binding = "JSONRPC",
        .protocol_version = "1.0",
    }};
    const skills = [_]AgentSkill{.{
        .id = "forecast",
        .name = "Forecast",
        .description = "A seven-day forecast.",
        .tags = &.{"weather"},
    }};
    // Fields 1, 2, 3, 5, 7, 10, 11 and 12 are the required ones, so this
    // literal is the whole required set. A default added to any of them would
    // quietly turn the specification's eight into fewer.
    const card: AgentCard = .{
        .name = "Weather",
        .description = "Forecasts and observations.",
        .supported_interfaces = &interfaces,
        // Field 5 is the card's own version, and PROTOCOLS.md section 5.1 puts
        // it under the same rule as the header: no patch component, so a
        // consumer parses it with the one parser and gets a `Major.Minor`.
        .version = "1.0",
        .capabilities = .{ .streaming = true },
        .default_input_modes = &.{"text/plain"},
        .default_output_modes = &.{"text/plain"},
        .skills = &skills,
    };
    // The other six are optional, and absent here.
    try testing.expectEqual(@as(?AgentProvider, null), card.provider);
    try testing.expectEqual(@as(?[]const u8, null), card.documentation_url);
    try testing.expectEqual(@as(?[]const u8, null), card.icon_url);
    try testing.expectEqual(@as(usize, 0), card.security_schemes.len);
    try testing.expectEqual(@as(usize, 0), card.security_requirements.len);
    try testing.expectEqual(@as(usize, 0), card.signatures.len);
    // `supported_interfaces` is ordered and the first entry is preferred, so
    // the list the card carries is the list the agent published.
    try testing.expectEqual(@as(usize, 1), card.supported_interfaces.len);
    try testing.expectEqualStrings("JSONRPC", card.supported_interfaces[0].protocol_binding);
    // The version the card carries is the one the rule allows, so the
    // declaration and this fixture cannot drift apart unnoticed.
    try testing.expectEqual(@as(u16, 1), (try parseVersion(card.version)).major);
    try testing.expectEqual(@as(u16, 0), (try parseVersion(card.version)).minor);
    try testing.expectError(error.InvalidField, parseVersion("1.0.0"));
}

/// Whether the field of message `T` named `field` carries a default value.
///
/// The check reads the type and not an instance, because a default is invisible
/// on any value that happens to set the field. A name `T` does not carry is a
/// compile error rather than a false, so a renamed field cannot pass as an
/// absent default.
fn hasDefault(comptime T: type, comptime field: []const u8) bool {
    return comptime blk: {
        for (@typeInfo(T).@"struct".fields) |candidate| {
            if (std.mem.eql(u8, candidate.name, field)) {
                break :blk candidate.default_value_ptr != null;
            }
        }
        @compileError(std.fmt.comptimePrint(
            "{s} has no field named '{s}'",
            .{ @typeName(T), field },
        ));
    };
}

test "a REQUIRED field carries no default and an optional one is a presence" {
    // The proto marks `Task.status`, `TaskStatusUpdateEvent.context_id` and
    // `TaskArtifactUpdateEvent.context_id` REQUIRED, so a default on any of them
    // is a message the specification does not describe: a caller who omits one
    // gets a value filled in silently rather than told the field is missing.
    // The `AgentCard` eight already follow this rule, and these three did not.
    try testing.expect(!hasDefault(Task, "status"));
    try testing.expect(!hasDefault(TaskStatusUpdateEvent, "context_id"));
    try testing.expect(!hasDefault(TaskArtifactUpdateEvent, "context_id"));

    // The over-correction is to make the fields the same tables mark optional
    // REQUIRED, which would refuse a message the proto says may omit one.
    //
    // `hasDefault` is the wrong instrument for that half and is not used here.
    // It reads `default_value_ptr`, and `?[]const u8 = null` has one, so it
    // answers true for the optional `context_id` and for the `[]const u8 = ""`
    // that was the presence defect: a check that passes on both the fix and the
    // bug pins nothing. What separates them is the type, so the type is what
    // this asserts, and the behaviour it protects is checked where it is
    // observable — an absent context decodes, in the `Message` and `Task`
    // tests below.
    try testing.expectEqual(?[]const u8, fieldType(Task, "context_id"));
    try testing.expectEqual(?[]const u8, fieldType(Message, "context_id"));
    try testing.expectEqual(?[]const u8, fieldType(Message, "task_id"));

    // The same six fields, and the ones with a default that no member name can
    // reach: an empty list and an absent list are different requests.
    try testing.expectEqual(?[]const Artifact, fieldType(Task, "artifacts"));
    try testing.expectEqual(?[]const Message, fieldType(Task, "history"));
    try testing.expectEqual(?[]const []const u8, fieldType(Message, "extensions"));
    try testing.expectEqual(?[]const []const u8, fieldType(Message, "reference_task_ids"));
    try testing.expectEqual(?[]const []const u8, fieldType(Artifact, "extensions"));
    try testing.expectEqual(?[]const u8, fieldType(SendMessageRequest, "tenant"));

    // The two REQUIRED `repeated` fields are the other side of the rule. An
    // empty array satisfies a REQUIRED `repeated` field, so these carry no
    // default and no emptiness check: only the absence of the member is a
    // missing field, and `[]` is a message with no parts.
    try testing.expectEqual([]const Part, fieldType(Message, "parts"));
    try testing.expectEqual([]const Part, fieldType(Artifact, "parts"));
}

/// The declared type of message `T`'s field `field`.
///
/// A name `T` does not carry is a compile error rather than a false, for the
/// reason `hasDefault` gives: a renamed field cannot pass as an absent one.
fn fieldType(comptime T: type, comptime field: []const u8) type {
    return comptime blk: {
        for (@typeInfo(T).@"struct".fields) |candidate| {
            if (std.mem.eql(u8, candidate.name, field)) break :blk candidate.type;
        }
        @compileError(std.fmt.comptimePrint(
            "{s} has no field named '{s}'",
            .{ @typeName(T), field },
        ));
    };
}

test "the device code flow is variant 5 and carries its own authorization URL" {
    try testing.expectEqualStrings("deviceAuthorizationUrl", jsonName(DeviceCodeOAuthFlow, 0).?);
    try testing.expectEqual(@as(u32, 5), fieldNumber(OAuthFlows, 4));
    const scopes = [_]OAuthScope{
        .{ .name = "a2a.tasks", .description = "Task read and write" },
    };
    const scheme: OAuth2SecurityScheme = .{ .flows = .{ .device_code = .{
        .device_authorization_url = "https://auth.example.com/device",
        .token_url = "https://auth.example.com/token",
        .scopes = &scopes,
    } } };
    try testing.expect(scheme.flows == .device_code);
    try testing.expectEqualStrings(
        "https://auth.example.com/device",
        scheme.flows.device_code.device_authorization_url,
    );
    try testing.expectEqual(@as(usize, 1), scheme.flows.device_code.scopes.len);
}

test "the two live OAuth flows require their URLs and their scopes" {
    try testing.expectEqualStrings("pkceRequired", jsonName(AuthorizationCodeOAuthFlow, 4).?);
    try testing.expectEqualStrings("scopes", jsonName(ClientCredentialsOAuthFlow, 2).?);
    // A machine client is not sent anywhere to log in, so the credentials
    // flow has a token URL and no authorization URL.
    const machine: ClientCredentialsOAuthFlow = .{
        .token_url = "https://auth.example.com/token",
        .scopes = &.{.{ .name = "a2a.tasks", .description = "Task read and write" }},
    };
    try testing.expectEqual(@as(?[]const u8, null), machine.refresh_url);
    // `pkce_required` defaults to false, which is a published flow without
    // PKCE rather than an absent one.
    const interactive: AuthorizationCodeOAuthFlow = .{
        .authorization_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .scopes = &.{.{ .name = "openid", .description = "OpenID Connect" }},
    };
    try testing.expect(!interactive.pkce_required);
    try testing.expectEqual(@as(?[]const u8, null), interactive.refresh_url);
    const pinned: AuthorizationCodeOAuthFlow = .{
        .authorization_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .scopes = &.{},
        .pkce_required = true,
    };
    try testing.expect(pinned.pkce_required);
}

test "the two deprecated OAuth flows have no required field" {
    try testing.expectEqualStrings("authorizationUrl", jsonName(ImplicitOAuthFlow, 0).?);
    try testing.expectEqualStrings("tokenUrl", jsonName(PasswordOAuthFlow, 0).?);
    // Neither carries a REQUIRED annotation, so a peer may send an empty one
    // and a decoder has to hold it rather than reject the whole card.
    const implicit: ImplicitOAuthFlow = .{};
    const password: PasswordOAuthFlow = .{};
    try testing.expectEqual(@as(?[]const u8, null), implicit.authorization_url);
    try testing.expectEqual(@as(usize, 0), implicit.scopes.len);
    try testing.expectEqual(@as(?[]const u8, null), password.token_url);
    try testing.expectEqual(@as(usize, 0), password.scopes.len);
    // They are variants 3 and 4, either side of device code at 5.
    try testing.expectEqual(@as(u32, 3), fieldNumber(OAuthFlows, 2));
    try testing.expectEqual(@as(u32, 4), fieldNumber(OAuthFlows, 3));
}

test "A2A-Extensions splits the specification's example and trims each URI" {
    // The example value the specification prints for the header, verbatim.
    const raw = "https://example.com/extensions/geolocation/v1," ++
        "https://standards.org/extensions/citations/v1";
    var out: [2][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try parseExtensions(raw, &out));
    try testing.expectEqualStrings("https://example.com/extensions/geolocation/v1", out[0]);
    try testing.expectEqualStrings("https://standards.org/extensions/citations/v1", out[1]);
    // A single URI is the common case and is not a special one.
    var one: [1][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try parseExtensions("https://example.com/ext", &one));
    try testing.expectEqualStrings("https://example.com/ext", one[0]);
    // Optional whitespace around an element is HTTP's, so it is trimmed.
    var spaced: [2][]const u8 = undefined;
    const spaced_raw = "  https://a.example.com/x ,\thttps://b.example.com/y  ";
    try testing.expectEqual(@as(usize, 2), try parseExtensions(spaced_raw, &spaced));
    try testing.expectEqualStrings("https://a.example.com/x", spaced[0]);
    try testing.expectEqualStrings("https://b.example.com/y", spaced[1]);
}

test "an empty element in A2A-Extensions is InvalidField" {
    var out: [2][]const u8 = undefined;
    // A header with no URI in it is malformed, and an empty element between
    // two URIs is not a skipped entry: dropping it would leave the caller
    // believing its neighbour was the only activation.
    try testing.expectError(error.InvalidField, parseExtensions("", &out));
    try testing.expectError(error.InvalidField, parseExtensions("  ", &out));
    try testing.expectError(error.InvalidField, parseExtensions(" , ", &out));
    try testing.expectError(
        error.InvalidField,
        parseExtensions("https://a.example.com/x,,", &out),
    );
}

test "A2A-Extensions reports a short output buffer rather than losing a URI" {
    const raw = "https://a.example.com/x,https://b.example.com/y";
    var one: [1][]const u8 = undefined;
    try testing.expectError(error.BufferTooSmall, parseExtensions(raw, &one));
    var two: [2][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try parseExtensions(raw, &two));
    // What came back is what the requirement check matches against.
    try testing.expect(extensionSatisfied(&two, true, "https://b.example.com/y"));
    try testing.expect(!extensionSatisfied(&two, true, "https://c.example.com/z"));
}

test "Empty decodes an empty object and refuses a second document behind it" {
    var scratch: [64]u8 = undefined;
    var out: [64]u8 = undefined;

    const empty = try decodeEmpty("{}", &scratch);
    var writer = json.Writer.init(&out);
    try encodeEmpty(empty, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    // A member this message does not model is stepped over rather than
    // refused, and a re-encode of a decorated body drops the decoration. That
    // is the stated consequence every decoder in this library records, and the
    // delete response is the one body a peer may decorate.
    const decorated = try decodeEmpty("{\"traceId\":\"abc\"}", &scratch);
    writer = json.Writer.init(&out);
    try encodeEmpty(decorated, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    // The tail is the other half. `{} trailing` skips the member loop and
    // still has to be refused, and accepting it would re-encode the body
    // without the half that arrived.
    try testing.expectError(error.MalformedJson, decodeEmpty("{} trailing", &scratch));
    try testing.expectError(error.MalformedJson, decodeEmpty("{\"a\":1} tail", &scratch));
    // Trailing whitespace is not trailing data.
    try testing.expectError(error.MalformedJson, decodeEmpty("[]", &scratch));
    _ = try decodeEmpty("{}\n", &scratch);
}

test "GetTaskRequest round-trips every member it models" {
    var scratch: [128]u8 = undefined;
    var out: [256]u8 = undefined;

    const full = "{\"tenant\":\"acme\",\"id\":\"task-1\",\"historyLength\":10}";
    const request = try decodeGetTaskRequest(full, &scratch);
    try testing.expectEqualStrings("acme", request.tenant.?);
    try testing.expectEqualStrings("task-1", request.id);
    try testing.expectEqual(@as(?i32, 10), request.history_length);
    var writer = json.Writer.init(&out);
    try encodeGetTaskRequest(request, &writer);
    try testing.expectEqualStrings(full, writer.written());

    // `"historyLength":0` and no `historyLength` are two documents, and only
    // presence tells them apart. An encoder that omitted the default would
    // answer the first with the second.
    const zero = try decodeGetTaskRequest("{\"id\":\"t\",\"historyLength\":0}", &scratch);
    try testing.expectEqual(@as(?i32, 0), zero.history_length);
    writer = json.Writer.init(&out);
    try encodeGetTaskRequest(zero, &writer);
    try testing.expectEqualStrings("{\"id\":\"t\",\"historyLength\":0}", writer.written());

    // `"tenant":""` is the same request and different bytes from no tenant at
    // all, so a `tenant` that is a plain string with a default answers this
    // one with the other.
    const blank = try decodeGetTaskRequest("{\"tenant\":\"\",\"id\":\"t\"}", &scratch);
    try testing.expectEqualStrings("", blank.tenant.?);
    writer = json.Writer.init(&out);
    try encodeGetTaskRequest(blank, &writer);
    try testing.expectEqualStrings("{\"tenant\":\"\",\"id\":\"t\"}", writer.written());

    // `id` is REQUIRED and may not be empty, and the encoder refuses the same
    // value so that anything this decoder accepts can be written back.
    try testing.expectError(error.MissingField, decodeGetTaskRequest("{}", &scratch));
    try testing.expectError(error.MissingField, decodeGetTaskRequest("{\"tenant\":\"a\"}", &scratch));
    try testing.expectError(
        error.InvalidField,
        decodeGetTaskRequest("{\"id\":\"\"}", &scratch),
    );
    // The refusal comes before the first byte, so a writer handed a value it
    // cannot encode is left untouched and can be reused with another one.
    var refusal = json.Writer.init(&out);
    try testing.expectError(
        error.InvalidField,
        encodeGetTaskRequest(.{ .id = "" }, &refusal),
    );
    try testing.expectEqual(@as(usize, 0), refusal.written().len);
    // A member the message does not model is skipped, and a repeat takes the
    // first occurrence.
    const extra = try decodeGetTaskRequest(
        "{\"id\":\"first\",\"id\":\"second\",\"unknown\":[1,2]}",
        &scratch,
    );
    try testing.expectEqualStrings("first", extra.id);
    // A tail is refused, and the check is after the member loop.
    try testing.expectError(
        error.MalformedJson,
        decodeGetTaskRequest("{\"id\":\"t\"} trailing", &scratch),
    );
}

test "CancelTaskRequest carries its metadata lexeme" {
    var scratch: [256]u8 = undefined;
    var out: [512]u8 = undefined;

    // `metadata` is a `google.protobuf.Struct`, so a key this library does not
    // model has to survive. A typed shape cannot write one back, which is the
    // defect `bridge.Envelope.meta` exists to remove.
    const body = "{\"id\":\"task-1\",\"metadata\":{\"reason\":\"user\",\"depth\":2}}";
    const request = try decodeCancelTaskRequest(body, &scratch);
    try testing.expectEqualStrings("{\"reason\":\"user\",\"depth\":2}", request.metadata.?);
    var writer = json.Writer.init(&out);
    try encodeCancelTaskRequest(request, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // A `null` metadata is the four bytes `null` and not an absent member:
    // re-encoding has to put back what arrived.
    const nulled = try decodeCancelTaskRequest("{\"id\":\"t\",\"metadata\":null}", &scratch);
    try testing.expectEqualStrings("null", nulled.metadata.?);
    writer = json.Writer.init(&out);
    try encodeCancelTaskRequest(nulled, &writer);
    try testing.expectEqualStrings("{\"id\":\"t\",\"metadata\":null}", writer.written());

    try testing.expectError(error.MissingField, decodeCancelTaskRequest("{}", &scratch));
    try testing.expectError(
        error.MalformedJson,
        decodeCancelTaskRequest("{\"id\":\"t\"} x", &scratch),
    );
}

test "SubscribeToTaskRequest round-trips and refuses an empty id" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"tenant\":\"acme\",\"id\":\"task-1\"}";
    const request = try decodeSubscribeToTaskRequest(body, &scratch);
    try testing.expectEqualStrings("acme", request.tenant.?);
    var writer = json.Writer.init(&out);
    try encodeSubscribeToTaskRequest(request, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // No tenant at all is the other shape, and it is not the empty tenant.
    const bare = try decodeSubscribeToTaskRequest("{\"id\":\"task-1\"}", &scratch);
    try testing.expectEqual(@as(?[]const u8, null), bare.tenant);
    writer = json.Writer.init(&out);
    try encodeSubscribeToTaskRequest(bare, &writer);
    try testing.expectEqualStrings("{\"id\":\"task-1\"}", writer.written());

    try testing.expectError(error.MissingField, decodeSubscribeToTaskRequest("{}", &scratch));
    try testing.expectError(
        error.MissingField,
        decodeSubscribeToTaskRequest("{\"tenant\":\"acme\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeSubscribeToTaskRequest("{\"id\":\"t\"} x", &scratch),
    );
}

test "GetTaskPushNotificationConfigRequest needs both ids and refuses a tail" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"tenant\":\"acme\",\"taskId\":\"task-1\",\"id\":\"cfg-1\"}";
    const request = try decodeGetTaskPushNotificationConfigRequest(body, &scratch);
    try testing.expectEqualStrings("task-1", request.task_id);
    try testing.expectEqualStrings("cfg-1", request.id);
    var writer = json.Writer.init(&out);
    try encodeGetTaskPushNotificationConfigRequest(request, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // Both are REQUIRED: one names the task a config belongs to and the other
    // the config within it, and neither is a request without both.
    try testing.expectError(
        error.MissingField,
        decodeGetTaskPushNotificationConfigRequest("{\"taskId\":\"t\"}", &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeGetTaskPushNotificationConfigRequest("{\"id\":\"c\"}", &scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodeGetTaskPushNotificationConfigRequest("{\"taskId\":\"t\",\"id\":\"\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeGetTaskPushNotificationConfigRequest("{\"taskId\":\"t\",\"id\":\"c\"} x", &scratch),
    );
}

test "DeleteTaskPushNotificationConfigRequest needs both ids and refuses a tail" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"taskId\":\"task-1\",\"id\":\"cfg-1\"}";
    const request = try decodeDeleteTaskPushNotificationConfigRequest(body, &scratch);
    try testing.expectEqualStrings("task-1", request.task_id);
    var writer = json.Writer.init(&out);
    try encodeDeleteTaskPushNotificationConfigRequest(request, &writer);
    try testing.expectEqualStrings(body, writer.written());

    try testing.expectError(
        error.MissingField,
        decodeDeleteTaskPushNotificationConfigRequest("{\"taskId\":\"t\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeDeleteTaskPushNotificationConfigRequest("{\"taskId\":\"t\",\"id\":\"c\"} x", &scratch),
    );
    // The response to this one is `google.protobuf.Empty`, so a config read
    // back from it would be a body the peer never sends.
    try testing.expectError(
        error.MissingField,
        decodeDeleteTaskPushNotificationConfigRequest("{}", &scratch),
    );
}

test "ListTaskPushNotificationConfigsRequest keeps an explicit zero page size" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"taskId\":\"task-1\",\"pageSize\":25,\"pageToken\":\"c1\",\"tenant\":\"acme\"}";
    const request = try decodeListTaskPushNotificationConfigsRequest(body, &scratch);
    try testing.expectEqual(@as(?i32, 25), request.page_size);
    try testing.expectEqualStrings("c1", request.page_token.?);
    // `tenant` is field 4 although the source lists it first, so it goes out
    // last and comes back where it started.
    try testing.expectEqualStrings("acme", request.tenant.?);
    var writer = json.Writer.init(&out);
    try encodeListTaskPushNotificationConfigsRequest(request, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // A plain `int32` in the proto is still presence here: `"pageSize":0` is a
    // page size a peer wrote and no `pageSize` is one it did not.
    const zero = try decodeListTaskPushNotificationConfigsRequest(
        "{\"taskId\":\"t\",\"pageSize\":0}",
        &scratch,
    );
    try testing.expectEqual(@as(?i32, 0), zero.page_size);
    writer = json.Writer.init(&out);
    try encodeListTaskPushNotificationConfigsRequest(zero, &writer);
    try testing.expectEqualStrings("{\"taskId\":\"t\",\"pageSize\":0}", writer.written());

    try testing.expectError(
        error.MissingField,
        decodeListTaskPushNotificationConfigsRequest("{}", &scratch),
    );
    // A repeated member takes the first occurrence, and the copy that is
    // discarded is still read as a value so a peer cannot hide a syntax error
    // in the second slot of a name the first slot already used.
    const repeated = try decodeListTaskPushNotificationConfigsRequest(
        "{\"taskId\":\"t\",\"pageSize\":1,\"pageSize\":2}",
        &scratch,
    );
    try testing.expectEqual(@as(?i32, 1), repeated.page_size);
    try testing.expectError(
        error.MalformedJson,
        decodeListTaskPushNotificationConfigsRequest(
            "{\"taskId\":\"t\",\"pageSize\":1,\"pageSize\":}",
            &scratch,
        ),
    );
    // A fraction and a value above `i32` are not a page size.
    try testing.expectError(
        error.InvalidField,
        decodeListTaskPushNotificationConfigsRequest("{\"taskId\":\"t\",\"pageSize\":1.5}", &scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodeListTaskPushNotificationConfigsRequest("{\"taskId\":\"t\",\"pageSize\":1e3}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeListTaskPushNotificationConfigsRequest("{\"taskId\":\"t\"} x", &scratch),
    );
}

test "ListTasksRequest keeps an explicit unspecified status" {
    var scratch: [128]u8 = undefined;
    var out: [512]u8 = undefined;

    // `"status":"TASK_STATE_UNSPECIFIED"` is a peer that filtered on an
    // unspecified state. A `status` that is a plain enum with a default answers
    // it with no member at all, which is a peer that did not filter.
    const filtered = try decodeListTasksRequest(
        "{\"status\":\"TASK_STATE_UNSPECIFIED\"}",
        &scratch,
    );
    try testing.expectEqual(@as(?TaskState, .unspecified), filtered.status);
    var writer = json.Writer.init(&out);
    try encodeListTasksRequest(filtered, &writer);
    try testing.expectEqualStrings("{\"status\":\"TASK_STATE_UNSPECIFIED\"}", writer.written());

    // Every member at once, in field order, with the timestamp left as the text
    // the peer wrote rather than a re-rendering of the instant.
    const body = "{\"tenant\":\"acme\",\"contextId\":\"ctx-1\"," ++
        "\"status\":\"TASK_STATE_WORKING\",\"pageSize\":10,\"pageToken\":\"p1\"," ++
        "\"historyLength\":5,\"statusTimestampAfter\":\"2026-01-02T03:04:05Z\"," ++
        "\"includeArtifacts\":true}";
    const request = try decodeListTasksRequest(body, &scratch);
    try testing.expectEqual(@as(?TaskState, .working), request.status);
    try testing.expectEqual(@as(?bool, true), request.include_artifacts);
    try testing.expectEqualStrings("2026-01-02T03:04:05Z", request.status_timestamp_after.?);
    writer = json.Writer.init(&out);
    try encodeListTasksRequest(request, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // `{}` is a complete request: the first page of everything.
    const bare = try decodeListTasksRequest("{}", &scratch);
    try testing.expectEqual(@as(?TaskState, null), bare.status);
    try testing.expectEqual(@as(?[]const u8, null), bare.tenant);
    writer = json.Writer.init(&out);
    try encodeListTasksRequest(bare, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    // A tag this library does not know is `UnknownTag`, never a fallback to
    // `unspecified`, which would be indistinguishable from a peer that said it.
    try testing.expectError(
        error.UnknownTag,
        decodeListTasksRequest("{\"status\":\"TASK_STATE_UNKNOWN\"}", &scratch),
    );
    // ProtoJSON spells a state with its full proto name, so the Zig short form
    // is not a value a peer sends.
    try testing.expectError(
        error.UnknownTag,
        decodeListTasksRequest("{\"status\":\"working\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeListTasksRequest("{} trailing", &scratch),
    );
}

test "GetExtendedAgentCardRequest decodes an empty object and keeps a blank tenant" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    // The only member is optional, so `{}` is a complete request.
    const bare = try decodeGetExtendedAgentCardRequest("{}", &scratch);
    try testing.expectEqual(@as(?[]const u8, null), bare.tenant);
    var writer = json.Writer.init(&out);
    try encodeGetExtendedAgentCardRequest(bare, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    const body = "{\"tenant\":\"acme\"}";
    const request = try decodeGetExtendedAgentCardRequest(body, &scratch);
    try testing.expectEqualStrings("acme", request.tenant.?);
    writer = json.Writer.init(&out);
    try encodeGetExtendedAgentCardRequest(request, &writer);
    try testing.expectEqualStrings(body, writer.written());

    const blank = try decodeGetExtendedAgentCardRequest("{\"tenant\":\"\"}", &scratch);
    writer = json.Writer.init(&out);
    try encodeGetExtendedAgentCardRequest(blank, &writer);
    try testing.expectEqualStrings("{\"tenant\":\"\"}", writer.written());

    try testing.expectError(
        error.MalformedJson,
        decodeGetExtendedAgentCardRequest("{\"tenant\":\"a\"} x", &scratch),
    );
}

test "AuthenticationInfo keeps an empty credential apart from none" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    // No credential is a scheme sent without a secret; an empty credential is a
    // secret that happens to be blank. They are different requests and both
    // come back.
    const body = "{\"scheme\":\"Bearer\",\"credentials\":\"\"}";
    const blank = try decodeAuthenticationInfo(body, &scratch);
    try testing.expectEqualStrings("", blank.credentials.?);
    var writer = json.Writer.init(&out);
    try encodeAuthenticationInfo(blank, &writer);
    try testing.expectEqualStrings(body, writer.written());

    const bare = try decodeAuthenticationInfo("{\"scheme\":\"Bearer\"}", &scratch);
    try testing.expectEqual(@as(?[]const u8, null), bare.credentials);
    writer = json.Writer.init(&out);
    try encodeAuthenticationInfo(bare, &writer);
    try testing.expectEqualStrings("{\"scheme\":\"Bearer\"}", writer.written());

    try testing.expectError(error.MissingField, decodeAuthenticationInfo("{}", &scratch));
    try testing.expectError(
        error.InvalidField,
        decodeAuthenticationInfo("{\"scheme\":\"\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeAuthenticationInfo("{\"scheme\":\"Bearer\"} x", &scratch),
    );
}

test "TaskPushNotificationConfig round-trips the create body and its nested auth" {
    var scratch: [256]u8 = undefined;
    var out: [512]u8 = undefined;

    // This one message is the create body, the create response, and the get
    // and list response, so every member the three carry has to survive.
    const body = "{\"tenant\":\"acme\",\"id\":\"cfg-1\",\"taskId\":\"task-1\"," ++
        "\"url\":\"https://client.example.com/hook\",\"token\":\"tok\"," ++
        "\"authentication\":{\"scheme\":\"Bearer\",\"credentials\":\"s3cret\"}}";
    const config = try decodeTaskPushNotificationConfig(body, &scratch);
    try testing.expectEqualStrings("https://client.example.com/hook", config.url);
    try testing.expectEqualStrings("s3cret", config.authentication.?.credentials.?);
    var writer = json.Writer.init(&out);
    try encodeTaskPushNotificationConfig(config, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // `url` is the only REQUIRED member, so a client that knows only where to
    // post can still build one.
    const minimal = try decodeTaskPushNotificationConfig(
        "{\"url\":\"https://c.example.com/hook\"}",
        &scratch,
    );
    try testing.expectEqual(@as(?AuthenticationInfo, null), minimal.authentication);
    writer = json.Writer.init(&out);
    try encodeTaskPushNotificationConfig(minimal, &writer);
    try testing.expectEqualStrings("{\"url\":\"https://c.example.com/hook\"}", writer.written());

    // A `null` authentication and an absent one agree, so it is dropped rather
    // than decoded into an object with nothing in it.
    const nulled = try decodeTaskPushNotificationConfig(
        "{\"url\":\"https://c.example.com/hook\",\"authentication\":null}",
        &scratch,
    );
    try testing.expectEqual(@as(?AuthenticationInfo, null), nulled.authentication);

    try testing.expectError(error.MissingField, decodeTaskPushNotificationConfig("{}", &scratch));
    try testing.expectError(
        error.InvalidField,
        decodeTaskPushNotificationConfig("{\"url\":\"\"}", &scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeTaskPushNotificationConfig(
            "{\"url\":\"https://c.example.com/hook\",\"authentication\":{}}",
            &scratch,
        ),
    );
    // The tail is checked after the whole walk, so a nested object beside one
    // still reports it rather than swallowing it.
    try testing.expectError(
        error.MalformedJson,
        decodeTaskPushNotificationConfig("{\"url\":\"https://c.example.com/hook\"} x", &scratch),
    );
}

test "SendMessageConfiguration keeps an empty mode list apart from none" {
    var scratch: [128]u8 = undefined;
    var out: [512]u8 = undefined;
    var modes: [2][]const u8 = undefined;

    // `[]` and no member are the same list and two documents, and only
    // presence tells them apart.
    const empty = try decodeSendMessageConfiguration(
        "{\"acceptedOutputModes\":[]}",
        &modes,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 0), empty.accepted_output_modes.?.len);
    var writer = json.Writer.init(&out);
    try encodeSendMessageConfiguration(empty, &writer);
    try testing.expectEqualStrings("{\"acceptedOutputModes\":[]}", writer.written());

    const body = "{\"acceptedOutputModes\":[\"text/plain\",\"application/json\"]," ++
        "\"taskPushNotificationConfig\":{\"url\":\"https://c.example.com/hook\"}," ++
        "\"historyLength\":3,\"returnImmediately\":false}";
    const configuration = try decodeSendMessageConfiguration(body, &modes, &scratch);
    try testing.expectEqual(@as(usize, 2), configuration.accepted_output_modes.?.len);
    try testing.expectEqualStrings("application/json", configuration.accepted_output_modes.?[1]);
    // `returnImmediately` is a plain bool on the wire, and a peer that wrote
    // `false` gets that member back rather than none.
    try testing.expectEqual(@as(?bool, false), configuration.return_immediately);
    try testing.expectEqualStrings(
        "https://c.example.com/hook",
        configuration.task_push_notification_config.?.url,
    );
    writer = json.Writer.init(&out);
    try encodeSendMessageConfiguration(configuration, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // No member at all is the third document, and the field is null for it.
    const bare = try decodeSendMessageConfiguration("{}", &modes, &scratch);
    try testing.expectEqual(@as(?[]const []const u8, null), bare.accepted_output_modes);
    writer = json.Writer.init(&out);
    try encodeSendMessageConfiguration(bare, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    // A list with more modes than the caller reserved is reported rather than
    // truncated, because a truncated list of accepted modes says something the
    // caller did not mean.
    var one: [1][]const u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        decodeSendMessageConfiguration(
            "{\"acceptedOutputModes\":[\"text/plain\",\"application/json\"]}",
            &one,
            &scratch,
        ),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeSendMessageConfiguration("{\"historyLength\":1} x", &modes, &scratch),
    );
}

test "AgentInterface round-trips its four members" {
    var scratch: [128]u8 = undefined;
    var out: [256]u8 = undefined;

    const body = "{\"url\":\"https://api.example.com/a2a/v1\"," ++
        "\"protocolBinding\":\"JSONRPC\",\"tenant\":\"acme\",\"protocolVersion\":\"1.0\"}";
    const interface = try decodeAgentInterface(body, &scratch);
    try testing.expectEqualStrings("JSONRPC", interface.protocol_binding);
    try testing.expectEqualStrings("acme", interface.tenant.?);
    // The declared text is kept, not parsed: a re-encode has to put back what
    // the agent published, and PROTOCOLS.md section 5.1 is what a consumer
    // reads it with.
    try testing.expectEqualStrings("1.0", interface.protocol_version);
    var writer = json.Writer.init(&out);
    try encodeAgentInterface(interface, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // Three of the four members are REQUIRED.
    try testing.expectError(error.MissingField, decodeAgentInterface("{}", &scratch));
    try testing.expectError(
        error.MissingField,
        decodeAgentInterface(
            "{\"url\":\"https://a\",\"protocolBinding\":\"JSONRPC\"}",
            &scratch,
        ),
    );
    try testing.expectError(
        error.InvalidField,
        decodeAgentInterface(
            "{\"url\":\"\",\"protocolBinding\":\"JSONRPC\",\"protocolVersion\":\"1.0\"}",
            &scratch,
        ),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeAgentInterface(
            "{\"url\":\"https://a\",\"protocolBinding\":\"JSONRPC\",\"protocolVersion\":\"1.0\"} x",
            &scratch,
        ),
    );
}

test "AgentProvider round-trips both required members" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"url\":\"https://example.com\",\"organization\":\"Example\"}";
    const provider = try decodeAgentProvider(body, &scratch);
    try testing.expectEqualStrings("Example", provider.organization);
    var writer = json.Writer.init(&out);
    try encodeAgentProvider(provider, &writer);
    try testing.expectEqualStrings(body, writer.written());

    try testing.expectError(error.MissingField, decodeAgentProvider("{}", &scratch));
    try testing.expectError(
        error.MissingField,
        decodeAgentProvider("{\"url\":\"https://example.com\"}", &scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodeAgentProvider("{\"url\":\"https://example.com\",\"organization\":\"\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeAgentProvider("{\"url\":\"https://a\",\"organization\":\"B\"} x", &scratch),
    );
}

test "AgentCardSignature carries its header lexeme" {
    var scratch: [128]u8 = undefined;
    var out: [256]u8 = undefined;

    // The unprotected header is a JSON object rather than base64url, so a key
    // this library does not model has to survive as the bytes that arrived.
    const body = "{\"protected\":\"eyJhbGciOiJFUzI1NiJ9\"," ++
        "\"signature\":\"MEUCIQ\",\"header\":{\"kid\":\"key-1\",\"x\":[1,2]}}";
    const signature = try decodeAgentCardSignature(body, &scratch);
    try testing.expectEqualStrings("{\"kid\":\"key-1\",\"x\":[1,2]}", signature.header.?);
    var writer = json.Writer.init(&out);
    try encodeAgentCardSignature(signature, &writer);
    try testing.expectEqualStrings(body, writer.written());

    const minimal = try decodeAgentCardSignature(
        "{\"protected\":\"a\",\"signature\":\"b\"}",
        &scratch,
    );
    try testing.expectEqual(@as(?[]const u8, null), minimal.header);
    writer = json.Writer.init(&out);
    try encodeAgentCardSignature(minimal, &writer);
    try testing.expectEqualStrings("{\"protected\":\"a\",\"signature\":\"b\"}", writer.written());

    try testing.expectError(error.MissingField, decodeAgentCardSignature("{}", &scratch));
    try testing.expectError(
        error.MissingField,
        decodeAgentCardSignature("{\"protected\":\"a\"}", &scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodeAgentCardSignature("{\"protected\":\"\",\"signature\":\"b\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeAgentCardSignature("{\"protected\":\"a\",\"signature\":\"b\"} x", &scratch),
    );
}

test "AgentExtension keeps an explicit required false and an unmodelled param" {
    var scratch: [128]u8 = undefined;
    var out: [256]u8 = undefined;

    // `"required":false` is a peer that said the extension is optional. A
    // `required` that is a plain bool with a default answers it with no member
    // at all, which is a peer that said nothing.
    const body = "{\"uri\":\"https://example.com/ext\"," ++
        "\"description\":\"Geography\",\"required\":false," ++
        "\"params\":{\"units\":\"metric\",\"unknown\":{\"a\":1}}}";
    const extension = try decodeAgentExtension(body, &scratch);
    try testing.expectEqual(@as(?bool, false), extension.required);
    try testing.expectEqualStrings(
        "{\"units\":\"metric\",\"unknown\":{\"a\":1}}",
        extension.params.?,
    );
    var writer = json.Writer.init(&out);
    try encodeAgentExtension(extension, &writer);
    try testing.expectEqualStrings(body, writer.written());

    // No field carries a REQUIRED annotation, so `{}` is still an extension.
    const bare = try decodeAgentExtension("{}", &scratch);
    try testing.expectEqual(@as(?bool, null), bare.required);
    writer = json.Writer.init(&out);
    try encodeAgentExtension(bare, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    const demanding = try decodeAgentExtension("{\"required\":true}", &scratch);
    try testing.expectEqual(@as(?bool, true), demanding.required);
    // ProtoJSON rejects `null` for a plain bool, so a decoder refuses one
    // rather than reading it as absent.
    try testing.expectError(
        error.MalformedJson,
        decodeAgentExtension("{\"required\":null}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeAgentExtension("{\"required\":false} x", &scratch),
    );
}

test "an ApiKeySecurityScheme round-trips its location" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"description\":\"Key\",\"location\":\"header\",\"name\":\"X-Key\"}";
    const scheme = try decodeApiKeySecurityScheme(body, &scratch);
    try testing.expectEqual(ApiKeyLocation.header, scheme.location);
    try testing.expectEqualStrings("X-Key", scheme.name);
    var writer = json.Writer.init(&out);
    try encodeApiKeySecurityScheme(scheme, &writer);
    try testing.expectEqualStrings(body, writer.written());

    const bare = try decodeApiKeySecurityScheme(
        "{\"location\":\"cookie\",\"name\":\"sid\"}",
        &scratch,
    );
    writer = json.Writer.init(&out);
    try encodeApiKeySecurityScheme(bare, &writer);
    try testing.expectEqualStrings("{\"location\":\"cookie\",\"name\":\"sid\"}", writer.written());

    // `location` accepts exactly the three stated spellings and nothing else.
    try testing.expectError(
        error.UnknownTag,
        decodeApiKeySecurityScheme("{\"location\":\"body\",\"name\":\"X\"}", &scratch),
    );
    try testing.expectError(error.MissingField, decodeApiKeySecurityScheme("{}", &scratch));
    try testing.expectError(
        error.InvalidField,
        decodeApiKeySecurityScheme("{\"location\":\"query\",\"name\":\"\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeApiKeySecurityScheme("{\"location\":\"query\",\"name\":\"X\"} x", &scratch),
    );
}

test "an HttpAuthSecurityScheme round-trips its bearer format" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"description\":\"Token\",\"scheme\":\"bearer\",\"bearerFormat\":\"JWT\"}";
    const scheme = try decodeHttpAuthSecurityScheme(body, &scratch);
    try testing.expectEqualStrings("JWT", scheme.bearer_format.?);
    var writer = json.Writer.init(&out);
    try encodeHttpAuthSecurityScheme(scheme, &writer);
    try testing.expectEqualStrings(body, writer.written());

    const bare = try decodeHttpAuthSecurityScheme("{\"scheme\":\"basic\"}", &scratch);
    writer = json.Writer.init(&out);
    try encodeHttpAuthSecurityScheme(bare, &writer);
    try testing.expectEqualStrings("{\"scheme\":\"basic\"}", writer.written());

    try testing.expectError(error.MissingField, decodeHttpAuthSecurityScheme("{}", &scratch));
    try testing.expectError(
        error.InvalidField,
        decodeHttpAuthSecurityScheme("{\"scheme\":\"\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeHttpAuthSecurityScheme("{\"scheme\":\"basic\"} x", &scratch),
    );
}

test "an OpenIdConnectSecurityScheme round-trips its url" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    const body = "{\"description\":\"OIDC\",\"openIdConnectUrl\":\"https://idp.example.com/.well-known/openid-configuration\"}";
    const scheme = try decodeOpenIdConnectSecurityScheme(body, &scratch);
    try testing.expectEqualStrings(
        "https://idp.example.com/.well-known/openid-configuration",
        scheme.open_id_connect_url,
    );
    var writer = json.Writer.init(&out);
    try encodeOpenIdConnectSecurityScheme(scheme, &writer);
    try testing.expectEqualStrings(body, writer.written());

    try testing.expectError(
        error.MissingField,
        decodeOpenIdConnectSecurityScheme("{}", &scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodeOpenIdConnectSecurityScheme("{\"openIdConnectUrl\":\"\"}", &scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeOpenIdConnectSecurityScheme("{\"openIdConnectUrl\":\"https://x\"} x", &scratch),
    );
}

test "a MutualTlsSecurityScheme is an empty object" {
    var scratch: [64]u8 = undefined;
    var out: [128]u8 = undefined;

    // The only member is an optional description, so `{}` is a complete
    // scheme: mutual TLS is asserted by the transport.
    const bare = try decodeMutualTlsSecurityScheme("{}", &scratch);
    try testing.expectEqual(@as(?[]const u8, null), bare.description);
    var writer = json.Writer.init(&out);
    try encodeMutualTlsSecurityScheme(bare, &writer);
    try testing.expectEqualStrings("{}", writer.written());

    const described = try decodeMutualTlsSecurityScheme("{\"description\":\"mTLS\"}", &scratch);
    try testing.expectEqualStrings("mTLS", described.description.?);
    writer = json.Writer.init(&out);
    try encodeMutualTlsSecurityScheme(described, &writer);
    try testing.expectEqualStrings("{\"description\":\"mTLS\"}", writer.written());

    try testing.expectError(
        error.MalformedJson,
        decodeMutualTlsSecurityScheme("{\"description\":\"mTLS\"} x", &scratch),
    );
}

// --- Tests: the content half ----------------------------------------------------

/// The storage one content-half test runs against.
///
/// The arena is a set of slices into these arrays and nothing outlives the test
/// that declared it, which is the same contract `ContentArena` offers a real
/// caller. A test that has to prove exhaustion builds its own smaller arrays,
/// because that is the whole point of it.
const TestStorage = struct {
    parts: [16]Part = undefined,
    artifacts: [4]Artifact = undefined,
    messages: [4]Message = undefined,
    strings: [8][]const u8 = undefined,
    bytes: [256]u8 = undefined,
    out: [4096]u8 = undefined,
    base64: [512]u8 = undefined,
    scratch: [512]u8 = undefined,
    arena: ContentArena = undefined,

    /// Point the arena at the arrays above. A method and not a field default,
    /// because a slice of a field cannot be named until the struct exists.
    fn init(self: *TestStorage) void {
        self.arena = ContentArena.init(
            &self.parts,
            &self.artifacts,
            &self.messages,
            &self.strings,
            &self.bytes,
        );
    }
};

test "a oneof is named by its own table, not by the struct that holds it" {
    // This is the trap the content half is built around. `Part.fields[0]`
    // carries `json = null` because a `oneof` has no member name of its own, so
    // `findField(Part, ...)` cannot name an arm. A decoder that dispatched on
    // `Part` would skip all four members, find no content, and answer
    // `error.MissingField` for a part that names one perfectly well.
    try testing.expectEqual(@as(?[]const u8, null), jsonName(Part, 0));
    try testing.expectEqual(@as(?usize, null), findField(Part, "text"));
    try testing.expectEqual(@as(?usize, null), findField(Part, "raw"));
    try testing.expectEqual(@as(?usize, null), findField(Part, "url"));
    try testing.expectEqual(@as(?usize, null), findField(Part, "data"));
    // The three members that are not the oneof are named by `Part` itself.
    try testing.expectEqual(@as(?usize, 1), findField(Part, "metadata"));
    try testing.expectEqual(@as(?usize, 3), findField(Part, "mediaType"));

    // The arms live in the union's table, and the union is a tagged one.
    try testing.expectEqual(@as(usize, 0), findField(PartContent, "text").?);
    try testing.expectEqual(@as(usize, 1), findField(PartContent, "raw").?);
    try testing.expectEqual(@as(usize, 2), findField(PartContent, "url").?);
    try testing.expectEqual(@as(usize, 3), findField(PartContent, "data").?);

    // And the name an encoder writes is that same row, checked against the tag
    // ordinal at comptime: a codec that took `@intFromEnum` for the number
    // writes every oneof field one below where the proto puts it.
    try testing.expectEqualStrings("text", oneofMemberName(PartContent, 0));
    try testing.expectEqualStrings("raw", oneofMemberName(PartContent, 1));
    try testing.expectEqualStrings("url", oneofMemberName(PartContent, 2));
    try testing.expectEqualStrings("data", oneofMemberName(PartContent, 3));
    try testing.expectEqualStrings("statusUpdate", oneofMemberName(StreamResponse, 2));
    try testing.expectEqualStrings("artifactUpdate", oneofMemberName(StreamResponse, 3));
    try testing.expectEqualStrings("message", oneofMemberName(SendMessageResponse, 1));
}

test "a PartContent round-trips each of its four arms" {
    var storage: TestStorage = .{};
    storage.init();

    const text = try decodePartContent("{\"text\":\"hello\"}", &storage.arena, &storage.scratch);
    try testing.expect(text == .text);
    try testing.expectEqualStrings("hello", text.text);
    var writer = json.Writer.init(&storage.out);
    try encodePartContent(text, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"text\":\"hello\"}", writer.written());

    // `data` is a `google.protobuf.Value` and may be any JSON value at all, so
    // the lexeme is spliced and a key this library does not model survives.
    const data = try decodePartContent(
        "{\"data\":{\"nested\":[1,true,null]}}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expect(data == .data);
    try testing.expectEqualStrings("{\"nested\":[1,true,null]}", data.data);
    writer = json.Writer.init(&storage.out);
    try encodePartContent(data, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"data\":{\"nested\":[1,true,null]}}", writer.written());

    // A `Value` may also be the four bytes `null`, and that is a value rather
    // than an absent member, so it comes back as those four bytes.
    const nulled = try decodePartContent("{\"data\":null}", &storage.arena, &storage.scratch);
    try testing.expectEqualStrings("null", nulled.data);
    writer = json.Writer.init(&storage.out);
    try encodePartContent(nulled, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"data\":null}", writer.written());

    // A oneof carries exactly one member, so an object with none is a missing
    // field and not an empty content.
    try testing.expectError(
        error.MissingField,
        decodePartContent("{}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodePartContent("{\"filename\":\"a.txt\"}", &storage.arena, &storage.scratch),
    );
    // Two arms is first-wins, the rule every repeated member in this file
    // follows, and the discarded arm is still read as a value.
    const two = try decodePartContent(
        "{\"url\":\"https://x\",\"text\":\"later\"}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expect(two == .url);
    try testing.expectError(
        error.MalformedJson,
        decodePartContent("{\"text\":} {\"text\":\"b\"}", &storage.arena, &storage.scratch),
    );
    // A tail is refused, and the check is after the member loop.
    try testing.expectError(
        error.MalformedJson,
        decodePartContent("{\"text\":\"a\"} trailing", &storage.arena, &storage.scratch),
    );
}

test "Part.raw is the base64 of the bytes, in the standard alphabet" {
    var storage: TestStorage = .{};
    storage.init();

    // `aGVsbG8=` is `hello` under RFC 4648 section 4.
    const part = try decodePart("{\"raw\":\"aGVsbG8=\"}", &storage.arena, &storage.scratch);
    try testing.expect(part.content == .raw);
    try testing.expectEqualStrings("hello", part.content.raw);
    // The bytes are the caller's own storage and not a sub-slice of the
    // document, which is what makes `raw` a `bytes` field rather than a string.
    try testing.expectEqual(
        @intFromPtr(storage.bytes[0..].ptr),
        @intFromPtr(part.content.raw.ptr),
    );
    var writer = json.Writer.init(&storage.out);
    try encodePart(part, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"raw\":\"aGVsbG8=\"}", writer.written());

    // The alphabet is the one the choice turns on. Three `0xFF` bytes are
    // `////` under section 4 and `____` under section 5, so a codec that had
    // taken the URL-safe alphabet would have written four underscores here and
    // the round trip would have changed the document.
    const high = try decodePart("{\"raw\":\"////\"}", &storage.arena, &storage.scratch);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff }, high.content.raw);
    writer = json.Writer.init(&storage.out);
    try encodePart(high, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"raw\":\"////\"}", writer.written());

    // A one-byte and a two-byte group are the two partial tails, and both are
    // padded to a group boundary rather than left short.
    const one = try decodePart("{\"raw\":\"AA==\"}", &storage.arena, &storage.scratch);
    try testing.expectEqualSlices(u8, &[_]u8{0}, one.content.raw);
    writer = json.Writer.init(&storage.out);
    try encodePart(one, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"raw\":\"AA==\"}", writer.written());
    const two = try decodePart("{\"raw\":\"AAA=\"}", &storage.arena, &storage.scratch);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, two.content.raw);
    writer = json.Writer.init(&storage.out);
    try encodePart(two, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"raw\":\"AAA=\"}", writer.written());

    // An empty `bytes` is a `bytes` of no bytes and not an absent part: the arm
    // is present, so the part is present.
    const empty = try decodePart("{\"raw\":\"\"}", &storage.arena, &storage.scratch);
    try testing.expectEqual(@as(usize, 0), empty.content.raw.len);
    writer = json.Writer.init(&storage.out);
    try encodePart(empty, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"raw\":\"\"}", writer.written());

    // The URL-safe spelling is what `AgentCardSignature` carries and not what
    // this field does, so a peer that sent it here is refused rather than
    // quietly accepted and written back in the other alphabet: the contract is
    // `encode(decode(b)) == b`, and accepting both alphabets would break it for
    // every document that used the second one.
    try testing.expectError(
        error.InvalidField,
        decodePart("{\"raw\":\"____\"}", &storage.arena, &storage.scratch),
    );
    // A length that is not a whole number of groups, a character outside the
    // alphabet and a quad that opens with the pad are all the peer's bytes and
    // never a trap.
    try testing.expectError(
        error.InvalidField,
        decodePart("{\"raw\":\"AAA\"}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodePart("{\"raw\":\"AA*A\"}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodePart("{\"raw\":\"=AAA\"}", &storage.arena, &storage.scratch),
    );
    // And the two `AgentCardSignature` members are the base64url text already,
    // so a splice is all an encoder does with them and there is no codec to
    // disagree with.
    const signature = try decodeAgentCardSignature(
        "{\"protected\":\"eyJhbGciOiJFUzI1NiJ9\",\"signature\":\"QFdkNLNszlGj3z3u\"}",
        &storage.scratch,
    );
    try testing.expectEqualStrings("eyJhbGciOiJFUzI1NiJ9", signature.protected);
    writer = json.Writer.init(&storage.out);
    try encodeAgentCardSignature(signature, &writer);
    try testing.expectEqualStrings(
        "{\"protected\":\"eyJhbGciOiJFUzI1NiJ9\",\"signature\":\"QFdkNLNszlGj3z3u\"}",
        writer.written(),
    );
}

test "a Part round-trips a field-order document and refuses a part with no arm" {
    var storage: TestStorage = .{};
    storage.init();

    // The members arrive in the reverse of the table's order, and they come
    // back in the table's order, so this is a round trip of the value and not of
    // the bytes: the bytes are what the field-order document above and this
    // pair check.
    const body = "{\"mediaType\":\"image/png\",\"filename\":\"a.png\"," ++
        "\"raw\":\"aGVsbG8=\",\"metadata\":{\"w\":2}}";
    const part = try decodePart(body, &storage.arena, &storage.scratch);
    try testing.expect(part.content == .raw);
    try testing.expectEqualStrings("a.png", part.filename.?);
    try testing.expectEqualStrings("image/png", part.media_type.?);
    try testing.expectEqualStrings("{\"w\":2}", part.metadata.?);
    var writer = json.Writer.init(&storage.out);
    try encodePart(part, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"raw\":\"aGVsbG8=\",\"metadata\":{\"w\":2},\"filename\":\"a.png\"," ++
            "\"mediaType\":\"image/png\"}",
        writer.written(),
    );

    // The `oneof` is always written and always first, and the three members
    // beside it are written only when they were present.
    const bare = try decodePart("{\"text\":\"a\"}", &storage.arena, &storage.scratch);
    writer = json.Writer.init(&storage.out);
    try encodePart(bare, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"text\":\"a\"}", writer.written());
    // A `null` metadata is the four bytes `null` and not an absent member.
    const nulled = try decodePart("{\"url\":\"u\",\"metadata\":null}", &storage.arena, &storage.scratch);
    writer = json.Writer.init(&storage.out);
    try encodePart(nulled, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"url\":\"u\",\"metadata\":null}", writer.written());

    // A part MUST contain exactly one of the four, so a part with no arm is a
    // missing field.
    try testing.expectError(error.MissingField, decodePart("{}", &storage.arena, &storage.scratch));
    try testing.expectError(
        error.MissingField,
        decodePart("{\"filename\":\"a\"}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodePart("{\"text\":\"a\"} trailing", &storage.arena, &storage.scratch),
    );
    // The refusal comes before the first byte, so a writer handed a value whose
    // base64 does not fit the caller's buffer is left untouched.
    var refusal = json.Writer.init(&storage.out);
    try testing.expectError(
        error.BufferTooSmall,
        encodePart(
            .{ .content = .{ .raw = storage.base64[0..300] } },
            &refusal,
            storage.base64[0..4],
        ),
    );
    try testing.expectEqual(@as(usize, 0), refusal.written().len);
}

test "a Message round-trips and tells an absent list from an empty one" {
    var storage: TestStorage = .{};
    storage.init();

    const body = "{\"referenceTaskIds\":[\"t-1\"],\"extensions\":[]," ++
        "\"parts\":[{\"text\":\"hi\"},{\"url\":\"https://x\"}]," ++
        "\"role\":\"ROLE_AGENT\",\"taskId\":\"t-1\",\"contextId\":\"c-1\"," ++
        "\"messageId\":\"m-1\"}";
    const message = try decodeMessage(body, &storage.arena, &storage.scratch);
    try testing.expectEqualStrings("m-1", message.message_id);
    try testing.expectEqualStrings("c-1", message.context_id.?);
    try testing.expectEqualStrings("t-1", message.task_id.?);
    try testing.expect(message.role == .agent);
    try testing.expectEqual(@as(usize, 2), message.parts.len);
    try testing.expectEqualStrings("hi", message.parts[0].content.text);
    // An empty list and an absent list are two documents. `"extensions":[]`
    // gives a zero-length slice and the encoder writes `[]` back; no member at
    // all gives null and the encoder writes nothing.
    try testing.expectEqual(@as(usize, 0), message.extensions.?.len);
    try testing.expectEqual(@as(usize, 1), message.reference_task_ids.?.len);
    var writer = json.Writer.init(&storage.out);
    try encodeMessage(message, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"messageId\":\"m-1\",\"contextId\":\"c-1\",\"taskId\":\"t-1\"," ++
            "\"role\":\"ROLE_AGENT\",\"parts\":[{\"text\":\"hi\"}," ++
            "{\"url\":\"https://x\"}],\"extensions\":[]," ++
            "\"referenceTaskIds\":[\"t-1\"]}",
        writer.written(),
    );

    // The bare message: two REQUIRED members and an empty part list. This is
    // where an optional `contextId` is proved optional rather than REQUIRED,
    // which is the assertion the type check above stands in for.
    const bare = try decodeMessage(
        "{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(?[]const u8, null), bare.context_id);
    try testing.expectEqual(@as(?[]const u8, null), bare.task_id);
    try testing.expectEqual(@as(?[]const []const u8, null), bare.extensions);
    try testing.expectEqual(@as(?[]const []const u8, null), bare.reference_task_ids);
    try testing.expectEqual(@as(usize, 0), bare.parts.len);
    writer = json.Writer.init(&storage.out);
    try encodeMessage(bare, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]}",
        writer.written(),
    );
    // And the presence defect this unit fixed: `"contextId":""` is a document
    // and so is no `contextId`, and a `[]const u8 = ""` would answer the first
    // with the second.
    const blank = try decodeMessage(
        "{\"messageId\":\"m\",\"contextId\":\"\",\"taskId\":\"\"," ++
            "\"role\":\"ROLE_USER\",\"parts\":[]}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqualStrings("", blank.context_id.?);
    try testing.expectEqualStrings("", blank.task_id.?);
    writer = json.Writer.init(&storage.out);
    try encodeMessage(blank, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"messageId\":\"m\",\"contextId\":\"\",\"taskId\":\"\"," ++
            "\"role\":\"ROLE_USER\",\"parts\":[]}",
        writer.written(),
    );

    // `messageId` and `role` are the two REQUIRED members, and `parts` is a
    // third: a REQUIRED `repeated` field is satisfied by `[]` and refused only
    // when the member is absent.
    try testing.expectError(
        error.MissingField,
        decodeMessage("{\"role\":\"ROLE_USER\",\"parts\":[]}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeMessage("{\"messageId\":\"m\",\"parts\":[]}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeMessage("{\"messageId\":\"m\",\"role\":\"ROLE_USER\"}", &storage.arena, &storage.scratch),
    );
    // An empty REQUIRED string is a value the proto does not allow.
    try testing.expectError(
        error.InvalidField,
        decodeMessage(
            "{\"messageId\":\"\",\"role\":\"ROLE_USER\",\"parts\":[]}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    // A role outside the declared range is an unknown tag and never a
    // fallback to `unspecified`.
    try testing.expectError(
        error.UnknownTag,
        decodeMessage(
            "{\"messageId\":\"m\",\"role\":\"ROLE_OPERATOR\",\"parts\":[]}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeMessage(
            "{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]} x",
            &storage.arena,
            &storage.scratch,
        ),
    );
    // An encoder handed a value the decoder could not have returned refuses it
    // before the first byte.
    var refusal = json.Writer.init(&storage.out);
    try testing.expectError(
        error.InvalidField,
        encodeMessage(
            .{ .message_id = "", .role = .user, .parts = &.{} },
            &refusal,
            &storage.base64,
        ),
    );
    try testing.expectEqual(@as(usize, 0), refusal.written().len);
}

test "an Artifact round-trips and keeps its own parts in the arena" {
    var storage: TestStorage = .{};
    storage.init();

    const body = "{\"parts\":[{\"raw\":\"AAEC\"},{\"text\":\"note\"}]," ++
        "\"extensions\":[\"https://x/ext/v1\"],\"metadata\":null," ++
        "\"description\":\"d\",\"name\":\"n\",\"artifactId\":\"a-1\"}";
    const artifact = try decodeArtifact(body, &storage.arena, &storage.scratch);
    try testing.expectEqualStrings("a-1", artifact.artifact_id);
    try testing.expectEqualStrings("n", artifact.name.?);
    try testing.expectEqualStrings("d", artifact.description.?);
    try testing.expectEqualStrings("null", artifact.metadata.?);
    try testing.expectEqual(@as(usize, 1), artifact.extensions.?.len);
    try testing.expectEqual(@as(usize, 2), artifact.parts.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2 }, artifact.parts[0].content.raw);
    var writer = json.Writer.init(&storage.out);
    try encodeArtifact(artifact, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"artifactId\":\"a-1\",\"name\":\"n\",\"description\":\"d\"," ++
            "\"parts\":[{\"raw\":\"AAEC\"},{\"text\":\"note\"}]," ++
            "\"metadata\":null,\"extensions\":[\"https://x/ext/v1\"]}",
        writer.written(),
    );

    // `artifactId` and `parts` are the two REQUIRED members.
    try testing.expectError(
        error.MissingField,
        decodeArtifact("{\"parts\":[]}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeArtifact("{\"artifactId\":\"a\"}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodeArtifact("{\"artifactId\":\"\",\"parts\":[]}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeArtifact("{\"artifactId\":\"a\",\"parts\":[]} x", &storage.arena, &storage.scratch),
    );
    // An empty part list is a legal artifact, and the encoder writes it back
    // rather than dropping the member.
    const empty = try decodeArtifact(
        "{\"artifactId\":\"a\",\"parts\":[]}",
        &storage.arena,
        &storage.scratch,
    );
    writer = json.Writer.init(&storage.out);
    try encodeArtifact(empty, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"artifactId\":\"a\",\"parts\":[]}", writer.written());
}

test "a TaskStatus round-trips its state, its message and its timestamp text" {
    var storage: TestStorage = .{};
    storage.init();

    // The members arrive in the reverse of the table's order.
    const body = "{\"timestamp\":\"2026-01-02T03:04:05Z\",\"message\":" ++
        "{\"messageId\":\"m\",\"role\":\"ROLE_AGENT\",\"parts\":[{\"text\":\"working\"}]}," ++
        "\"state\":\"TASK_STATE_WORKING\"}";
    const status = try decodeTaskStatus(body, &storage.arena, &storage.scratch);
    try testing.expect(status.state == .working);
    try testing.expectEqualStrings("m", status.message.?.message_id);
    // The timestamp is the ISO-8601 text the peer wrote and not a `Timestamp`
    // converted here: normalising it would replace the bytes that came in with
    // bytes this library chose.
    try testing.expectEqualStrings("2026-01-02T03:04:05Z", status.timestamp.?);
    var writer = json.Writer.init(&storage.out);
    try encodeTaskStatus(status, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"state\":\"TASK_STATE_WORKING\",\"message\":" ++
            "{\"messageId\":\"m\",\"role\":\"ROLE_AGENT\",\"parts\":[{\"text\":\"working\"}]}," ++
            "\"timestamp\":\"2026-01-02T03:04:05Z\"}",
        writer.written(),
    );

    // `state` is the only REQUIRED member, and the two optional ones are a
    // presence each.
    const bare = try decodeTaskStatus(
        "{\"state\":\"TASK_STATE_SUBMITTED\"}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(?Message, null), bare.message);
    try testing.expectEqual(@as(?[]const u8, null), bare.timestamp);
    writer = json.Writer.init(&storage.out);
    try encodeTaskStatus(bare, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"state\":\"TASK_STATE_SUBMITTED\"}", writer.written());

    try testing.expectError(
        error.MissingField,
        decodeTaskStatus("{}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.UnknownTag,
        decodeTaskStatus("{\"state\":\"TASK_STATE_PENDING\"}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeTaskStatus("{\"state\":\"TASK_STATE_WORKING\"} x", &storage.arena, &storage.scratch),
    );
    // A `null` message agrees with an absent one: the normative row types the
    // member as a message, and a status with no message sends none.
    const nulled = try decodeTaskStatus(
        "{\"state\":\"TASK_STATE_WORKING\",\"message\":null}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(?Message, null), nulled.message);
}

test "a Task round-trips four lists out of one arena without any of them sharing a run" {
    var storage: TestStorage = .{};
    storage.init();

    // One artifact and two history messages, each with its own parts, plus a
    // status that carries a message of its own: four parts in all, and the four
    // runs must not overlap or the second owner would read the first one's
    // content.
    const body = "{\"history\":[" ++
        "{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"one\"}]}," ++
        "{\"messageId\":\"m-2\",\"role\":\"ROLE_AGENT\",\"parts\":[{\"text\":\"two\"}]}]," ++
        "\"artifacts\":[{\"artifactId\":\"a-1\",\"parts\":[{\"text\":\"three\"}]}]," ++
        "\"status\":{\"state\":\"TASK_STATE_WORKING\"," ++
        "\"message\":{\"messageId\":\"m-0\",\"role\":\"ROLE_AGENT\"," ++
        "\"parts\":[{\"text\":\"four\"}]}}," ++
        "\"contextId\":\"c-1\",\"id\":\"t-1\"}";
    const task = try decodeTask(body, &storage.arena, &storage.scratch);
    try testing.expectEqualStrings("t-1", task.id);
    try testing.expectEqualStrings("c-1", task.context_id.?);
    try testing.expectEqual(@as(usize, 4), storage.arena.parts_used);
    try testing.expectEqualStrings("four", task.status.message.?.parts[0].content.text);
    try testing.expectEqualStrings("three", task.artifacts.?[0].parts[0].content.text);
    try testing.expectEqualStrings("one", task.history.?[0].parts[0].content.text);
    try testing.expectEqualStrings("two", task.history.?[1].parts[0].content.text);
    // Four distinct runs, in document order, and none of them aliasing another.
    const first = task.status.message.?.parts[0].content.text.ptr;
    try testing.expect(first != task.artifacts.?[0].parts[0].content.text.ptr);
    try testing.expect(first != task.history.?[0].parts[0].content.text.ptr);
    try testing.expect(first != task.history.?[1].parts[0].content.text.ptr);
    try testing.expect(
        task.artifacts.?[0].parts[0].content.text.ptr != task.history.?[0].parts[0].content.text.ptr,
    );
    try testing.expect(
        task.history.?[0].parts[0].content.text.ptr != task.history.?[1].parts[0].content.text.ptr,
    );

    var writer = json.Writer.init(&storage.out);
    try encodeTask(task, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"id\":\"t-1\",\"contextId\":\"c-1\",\"status\":{\"state\":\"TASK_STATE_WORKING\"," ++
            "\"message\":{\"messageId\":\"m-0\",\"role\":\"ROLE_AGENT\"," ++
            "\"parts\":[{\"text\":\"four\"}]}}," ++
            "\"artifacts\":[{\"artifactId\":\"a-1\",\"parts\":[{\"text\":\"three\"}]}]," ++
            "\"history\":[{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\"," ++
            "\"parts\":[{\"text\":\"one\"}]}," ++
            "{\"messageId\":\"m-2\",\"role\":\"ROLE_AGENT\",\"parts\":[{\"text\":\"two\"}]}]}",
        writer.written(),
    );

    // `"artifacts":[]` and no `artifacts` are two documents, and so are
    // `"history":[]` and no `history`. This is the presence defect the
    // `[]const Artifact = &.{}` default made invisible.
    const empty_lists = try decodeTask(
        "{\"id\":\"t-1\",\"status\":{\"state\":\"TASK_STATE_SUBMITTED\"}," ++
            "\"artifacts\":[],\"history\":[]}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(usize, 0), empty_lists.artifacts.?.len);
    try testing.expectEqual(@as(usize, 0), empty_lists.history.?.len);
    writer = json.Writer.init(&storage.out);
    try encodeTask(empty_lists, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"id\":\"t-1\",\"status\":{\"state\":\"TASK_STATE_SUBMITTED\"}," ++
            "\"artifacts\":[],\"history\":[]}",
        writer.written(),
    );
    const no_lists = try decodeTask(
        "{\"id\":\"t-1\",\"status\":{\"state\":\"TASK_STATE_SUBMITTED\"}}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(?[]const Artifact, null), no_lists.artifacts);
    try testing.expectEqual(@as(?[]const Message, null), no_lists.history);
    writer = json.Writer.init(&storage.out);
    try encodeTask(no_lists, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"id\":\"t-1\",\"status\":{\"state\":\"TASK_STATE_SUBMITTED\"}}",
        writer.written(),
    );

    // `id` and `status` are the two REQUIRED members, and an empty id is a
    // value the proto does not allow.
    try testing.expectError(
        error.MissingField,
        decodeTask("{\"status\":{\"state\":\"TASK_STATE_WORKING\"}}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeTask("{\"id\":\"t-1\"}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.InvalidField,
        decodeTask(
            "{\"id\":\"\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MissingField,
        decodeTask("{\"id\":\"t-1\",\"status\":{}}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeTask(
            "{\"id\":\"t-1\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}} x",
            &storage.arena,
            &storage.scratch,
        ),
    );
    var refusal = json.Writer.init(&storage.out);
    try testing.expectError(
        error.InvalidField,
        encodeTask(
            .{ .id = "", .status = .{ .state = .working } },
            &refusal,
            &storage.base64,
        ),
    );
    try testing.expectEqual(@as(usize, 0), refusal.written().len);
}

test "a TaskStatusUpdateEvent round-trips its three REQUIRED members" {
    var storage: TestStorage = .{};
    storage.init();

    const body = "{\"metadata\":{\"seq\":7},\"status\":" ++
        "{\"state\":\"TASK_STATE_COMPLETED\",\"timestamp\":\"2026-01-02T03:04:05Z\"}," ++
        "\"contextId\":\"c-1\",\"taskId\":\"t-1\"}";
    const event = try decodeTaskStatusUpdateEvent(body, &storage.arena, &storage.scratch);
    try testing.expectEqualStrings("t-1", event.task_id);
    try testing.expectEqualStrings("c-1", event.context_id);
    try testing.expect(event.status.state == .completed);
    try testing.expectEqualStrings("{\"seq\":7}", event.metadata.?);
    var writer = json.Writer.init(&storage.out);
    try encodeTaskStatusUpdateEvent(event, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"taskId\":\"t-1\",\"contextId\":\"c-1\",\"status\":" ++
            "{\"state\":\"TASK_STATE_COMPLETED\",\"timestamp\":\"2026-01-02T03:04:05Z\"}," ++
            "\"metadata\":{\"seq\":7}}",
        writer.written(),
    );

    // All three are REQUIRED, and none of them may be empty.
    try testing.expectError(
        error.MissingField,
        decodeTaskStatusUpdateEvent(
            "{\"contextId\":\"c\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MissingField,
        decodeTaskStatusUpdateEvent(
            "{\"taskId\":\"t\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MissingField,
        decodeTaskStatusUpdateEvent(
            "{\"taskId\":\"t\",\"contextId\":\"c\"}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.InvalidField,
        decodeTaskStatusUpdateEvent(
            "{\"taskId\":\"\",\"contextId\":\"c\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeTaskStatusUpdateEvent(
            "{\"taskId\":\"t\",\"contextId\":\"c\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}} x",
            &storage.arena,
            &storage.scratch,
        ),
    );
}

test "a TaskArtifactUpdateEvent round-trips the booleans it recorded as presence" {
    var storage: TestStorage = .{};
    storage.init();

    // `append:false` and `lastChunk:false` are two members a peer wrote and not
    // two absences, which is why both are `?bool` here.
    const body = "{\"metadata\":null,\"lastChunk\":false,\"append\":false," ++
        "\"artifact\":{\"artifactId\":\"a-1\",\"parts\":[{\"raw\":\"AA==\"}]}," ++
        "\"contextId\":\"c-1\",\"taskId\":\"t-1\"}";
    const event = try decodeTaskArtifactUpdateEvent(body, &storage.arena, &storage.scratch);
    try testing.expectEqual(@as(?bool, false), event.append);
    try testing.expectEqual(@as(?bool, false), event.last_chunk);
    try testing.expectEqualStrings("a-1", event.artifact.artifact_id);
    try testing.expectEqualStrings("null", event.metadata.?);
    var writer = json.Writer.init(&storage.out);
    try encodeTaskArtifactUpdateEvent(event, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"taskId\":\"t-1\",\"contextId\":\"c-1\",\"artifact\":" ++
            "{\"artifactId\":\"a-1\",\"parts\":[{\"raw\":\"AA==\"}]}," ++
            "\"append\":false,\"lastChunk\":false,\"metadata\":null}",
        writer.written(),
    );

    // The three REQUIRED members, and the two booleans as an absence.
    const bare = try decodeTaskArtifactUpdateEvent(
        "{\"taskId\":\"t-1\",\"contextId\":\"c-1\",\"artifact\":" ++
            "{\"artifactId\":\"a-1\",\"parts\":[]}}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(?bool, null), bare.append);
    try testing.expectEqual(@as(?bool, null), bare.last_chunk);
    try testing.expectEqual(@as(?[]const u8, null), bare.metadata);
    writer = json.Writer.init(&storage.out);
    try encodeTaskArtifactUpdateEvent(bare, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"taskId\":\"t-1\",\"contextId\":\"c-1\",\"artifact\":" ++
            "{\"artifactId\":\"a-1\",\"parts\":[]}}",
        writer.written(),
    );

    try testing.expectError(
        error.MissingField,
        decodeTaskArtifactUpdateEvent(
            "{\"contextId\":\"c\",\"artifact\":{\"artifactId\":\"a\",\"parts\":[]}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MissingField,
        decodeTaskArtifactUpdateEvent(
            "{\"taskId\":\"t\",\"contextId\":\"c\"}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.InvalidField,
        decodeTaskArtifactUpdateEvent(
            "{\"taskId\":\"t\",\"contextId\":\"\",\"artifact\":" ++
                "{\"artifactId\":\"a\",\"parts\":[]}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeTaskArtifactUpdateEvent(
            "{\"taskId\":\"t\",\"contextId\":\"c\",\"artifact\":" ++
                "{\"artifactId\":\"a\",\"parts\":[]}} x",
            &storage.arena,
            &storage.scratch,
        ),
    );
}

test "a SendMessageRequest round-trips its configuration out of the shared string array" {
    var storage: TestStorage = .{};
    storage.init();

    // The accepted modes are `repeated string` like every other list in the
    // half, so they take a run of the same array the message's own extension
    // URIs take. The order here puts the modes first, so the two runs are
    // disjoint and neither is the other's first element.
    const body = "{\"metadata\":{\"priority\":1}," ++
        "\"configuration\":{\"acceptedOutputModes\":[\"text/plain\"," ++
        "\"application/json\"],\"historyLength\":2,\"returnImmediately\":true}," ++
        "\"message\":{\"extensions\":[\"https://x/e/v1\"]," ++
        "\"parts\":[{\"text\":\"q\"}],\"role\":\"ROLE_USER\"," ++
        "\"messageId\":\"m-1\"}," ++
        "\"tenant\":\"acme\"}";
    const request = try decodeSendMessageRequest(body, &storage.arena, &storage.scratch);
    try testing.expectEqualStrings("acme", request.tenant.?);
    try testing.expectEqualStrings("m-1", request.message.message_id);
    try testing.expectEqualStrings("https://x/e/v1", request.message.extensions.?[0]);
    try testing.expectEqualStrings("text/plain", request.configuration.?.accepted_output_modes.?[0]);
    try testing.expectEqualStrings("application/json", request.configuration.?.accepted_output_modes.?[1]);
    try testing.expectEqual(@as(?i32, 2), request.configuration.?.history_length);
    try testing.expectEqual(@as(?bool, true), request.configuration.?.return_immediately);
    // Three runs of one array: the modes, then the message's own extension.
    try testing.expectEqual(@as(usize, 3), storage.arena.strings_used);
    try testing.expectEqualStrings("{\"priority\":1}", request.metadata.?);

    var writer = json.Writer.init(&storage.out);
    try encodeSendMessageRequest(request, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"tenant\":\"acme\",\"message\":{\"messageId\":\"m-1\"," ++
            "\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"q\"}]," ++
            "\"extensions\":[\"https://x/e/v1\"]}," ++
            "\"configuration\":{\"acceptedOutputModes\":[\"text/plain\"," ++
            "\"application/json\"],\"historyLength\":2,\"returnImmediately\":true}," ++
            "\"metadata\":{\"priority\":1}}",
        writer.written(),
    );

    // `message` is the only REQUIRED member, and `tenant` is a presence: the
    // empty tenant is a request and no tenant is another one.
    const bare = try decodeSendMessageRequest(
        "{\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]}}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(?[]const u8, null), bare.tenant);
    try testing.expectEqual(@as(?SendMessageConfiguration, null), bare.configuration);
    writer = json.Writer.init(&storage.out);
    try encodeSendMessageRequest(bare, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]}}",
        writer.written(),
    );
    const blank = try decodeSendMessageRequest(
        "{\"tenant\":\"\",\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\"," ++
            "\"parts\":[]}}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqualStrings("", blank.tenant.?);
    writer = json.Writer.init(&storage.out);
    try encodeSendMessageRequest(blank, &writer, &storage.base64);
    try testing.expectEqualStrings(
        "{\"tenant\":\"\",\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\"," ++
            "\"parts\":[]}}",
        writer.written(),
    );

    try testing.expectError(
        error.MissingField,
        decodeSendMessageRequest("{\"tenant\":\"acme\"}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeSendMessageRequest(
            "{\"message\":{\"role\":\"ROLE_USER\",\"parts\":[]}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeSendMessageRequest(
            "{\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]}} x",
            &storage.arena,
            &storage.scratch,
        ),
    );
    // A nested REQUIRED member is still a missing field, and the walk reaches
    // it rather than accepting a message with no id.
    try testing.expectError(
        error.MissingField,
        decodeSendMessageRequest(
            "{\"message\":{\"role\":\"ROLE_USER\",\"parts\":[]}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
}

test "a SendMessageResponse round-trips both arms of its oneof" {
    var storage: TestStorage = .{};
    storage.init();

    const with_task = "{\"task\":{\"id\":\"t-1\"," ++
        "\"status\":{\"state\":\"TASK_STATE_SUBMITTED\"}}}";
    const task_response = try decodeSendMessageResponse(
        with_task,
        &storage.arena,
        &storage.scratch,
    );
    try testing.expect(task_response == .task);
    try testing.expectEqualStrings("t-1", task_response.task.id);
    var writer = json.Writer.init(&storage.out);
    try encodeSendMessageResponse(task_response, &writer, &storage.base64);
    try testing.expectEqualStrings(with_task, writer.written());

    const with_message = "{\"message\":{\"messageId\":\"m-1\"," ++
        "\"role\":\"ROLE_AGENT\",\"parts\":[{\"text\":\"answer\"}]}}";
    const message_response = try decodeSendMessageResponse(
        with_message,
        &storage.arena,
        &storage.scratch,
    );
    try testing.expect(message_response == .message);
    writer = json.Writer.init(&storage.out);
    try encodeSendMessageResponse(message_response, &writer, &storage.base64);
    try testing.expectEqualStrings(with_message, writer.written());

    // The oneof is the whole message, so an object with no arm is a missing
    // field and a name no row carries is stepped over.
    try testing.expectError(
        error.MissingField,
        decodeSendMessageResponse("{}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeSendMessageResponse(
            "{\"statusUpdate\":{\"taskId\":\"t\",\"contextId\":\"c\"," ++
                "\"status\":{\"state\":\"TASK_STATE_WORKING\"}}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MalformedJson,
        decodeSendMessageResponse(
            "{\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\"," ++
                "\"parts\":[]}} x",
            &storage.arena,
            &storage.scratch,
        ),
    );
}

test "a StreamResponse round-trips all four arms under their own names" {
    var storage: TestStorage = .{};
    storage.init();

    // The four arms are four members of the object, and the number a protobuf
    // encoder writes for each is the one `StreamResponse.fields` gives it. A
    // codec that took the tag ordinal would have put `artifactUpdate` where
    // `task` belongs, and this document is what that mistake changes.
    const bodies = [_][]const u8{
        "{\"task\":{\"id\":\"t-1\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}}}",
        "{\"message\":{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\"," ++
            "\"parts\":[{\"text\":\"q\"}]}}",
        "{\"statusUpdate\":{\"taskId\":\"t-1\",\"contextId\":\"c-1\"," ++
            "\"status\":{\"state\":\"TASK_STATE_COMPLETED\"}}}",
        "{\"artifactUpdate\":{\"taskId\":\"t-1\",\"contextId\":\"c-1\"," ++
            "\"artifact\":{\"artifactId\":\"a-1\",\"parts\":[{\"text\":\"chunk\"}]}," ++
            "\"append\":true}}",
    };
    for (bodies, 0..) |body, index| {
        const response = try decodeStreamResponse(body, &storage.arena, &storage.scratch);
        switch (index) {
            0 => try testing.expect(response == .task),
            1 => try testing.expect(response == .message),
            2 => try testing.expect(response == .status_update),
            3 => try testing.expect(response == .artifact_update),
            // Not a branch a document can reach: the loop runs over four
            // bodies and the switch covers four arms. It is a decode error
            // rather than `unreachable` because this library does not have a
            // branch that traps, here or in a codec.
            else => return error.TestUnexpectedResult,
        }
        var writer = json.Writer.init(&storage.out);
        try encodeStreamResponse(response, &writer, &storage.base64);
        try testing.expectEqualStrings(body, writer.written());
    }

    // The oneof is the whole message, so an object with no arm is a missing
    // field, and a second arm is first-wins for the reason every repeated
    // member in this file is.
    try testing.expectError(
        error.MissingField,
        decodeStreamResponse("{}", &storage.arena, &storage.scratch),
    );
    const two = try decodeStreamResponse(
        "{\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]}," ++
            "\"task\":{\"id\":\"t\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}}}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expect(two == .message);
    try testing.expectError(
        error.MalformedJson,
        decodeStreamResponse(
            "{\"task\":{\"id\":\"t\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}}} x",
            &storage.arena,
            &storage.scratch,
        ),
    );
    // An arm whose own REQUIRED member is missing is still a missing field, and
    // the walk reaches inside the oneof to find it.
    try testing.expectError(
        error.MissingField,
        decodeStreamResponse(
            "{\"artifactUpdate\":{\"taskId\":\"t\",\"contextId\":\"c\"," ++
                "\"artifact\":{\"artifactId\":\"a\"}}}",
            &storage.arena,
            &storage.scratch,
        ),
    );
}

test "a null message member is a missing field, and the first arm with a value wins" {
    var storage: TestStorage = .{};
    storage.init();

    // A oneof member sent as `null` is an arm that is not there. The object is
    // well formed and it names a member, so this is a missing field and not a
    // syntax error — the caller is told the arm is absent, not that the peer
    // sent malformed JSON.
    try testing.expectError(
        error.MissingField,
        decodeStreamResponse("{\"task\":null}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeSendMessageResponse("{\"message\":null}", &storage.arena, &storage.scratch),
    );
    // A later arm that does carry a value still decides the union, for the
    // same reason a repeated member takes its first occurrence.
    const later = try decodeStreamResponse(
        "{\"task\":null,\"message\":{\"messageId\":\"m\",\"role\":\"ROLE_USER\"," ++
            "\"parts\":[]}}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expect(later == .message);

    // The same rule for a REQUIRED message member that is not in a oneof.
    try testing.expectError(
        error.MissingField,
        decodeSendMessageRequest("{\"message\":null}", &storage.arena, &storage.scratch),
    );
    try testing.expectError(
        error.MissingField,
        decodeTask(
            "{\"id\":\"t\",\"status\":null}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MissingField,
        decodeTaskStatusUpdateEvent(
            "{\"taskId\":\"t\",\"contextId\":\"c\",\"status\":null}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    try testing.expectError(
        error.MissingField,
        decodeTaskArtifactUpdateEvent(
            "{\"taskId\":\"t\",\"contextId\":\"c\",\"artifact\":null}",
            &storage.arena,
            &storage.scratch,
        ),
    );
    // And for the optional message members the flat half already had, so the
    // rule is one rule in the file and not eleven. These are optional, so a
    // `null` is the absent value rather than a missing field, and the encoder
    // writes nothing for it.
    const config = try decodeTaskPushNotificationConfig(
        "{\"url\":\"https://hooks.example.com/t\",\"authentication\":null}",
        &storage.scratch,
    );
    try testing.expectEqual(@as(?AuthenticationInfo, null), config.authentication);
    var modes: [4][]const u8 = undefined;
    const configuration = try decodeSendMessageConfiguration(
        "{\"taskPushNotificationConfig\":null,\"historyLength\":1}",
        &modes,
        &storage.scratch,
    );
    try testing.expectEqual(
        @as(?TaskPushNotificationConfig, null),
        configuration.task_push_notification_config,
    );
    const status = try decodeTaskStatus(
        "{\"state\":\"TASK_STATE_WORKING\",\"message\":null}",
        &storage.arena,
        &storage.scratch,
    );
    try testing.expectEqual(@as(?Message, null), status.message);
    var out: [256]u8 = undefined;
    var writer = json.Writer.init(&out);
    try encodeTaskStatus(status, &writer, &storage.base64);
    try testing.expectEqualStrings("{\"state\":\"TASK_STATE_WORKING\"}", writer.written());
}

test "an out array that fills is an error and never a truncation" {
    var scratch: [256]u8 = undefined;
    var base64: [64]u8 = undefined;
    var out: [1024]u8 = undefined;

    // One part slot and a document with two parts. A message whose second part
    // silently disappeared would be a message that says something the caller
    // did not mean, so the decode is refused instead.
    var one_part: [1]Part = undefined;
    var one_artifact_slot: [1]Artifact = undefined;
    var one_message_slot: [1]Message = undefined;
    var one_string_slot: [1][]const u8 = undefined;
    var byte_slots: [64]u8 = undefined;
    var part_arena = ContentArena.init(
        &one_part,
        &one_artifact_slot,
        &one_message_slot,
        &one_string_slot,
        &byte_slots,
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodeMessage(
            "{\"messageId\":\"m\",\"role\":\"ROLE_USER\"," ++
                "\"parts\":[{\"text\":\"a\"},{\"text\":\"b\"}]}",
            &part_arena,
            &scratch,
        ),
    );
    // One part is enough for the same document with one part, so the refusal is
    // the second part and not the shape.
    _ = try decodeMessage(
        "{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"a\"}]}",
        &part_arena,
        &scratch,
    );

    // The same rule for the artifact array, which is a different array reached
    // through a different document. Every arena below is the full-size one with
    // exactly one array shrunk, so each refusal names the array it came from.
    var parts: [8]Part = undefined;
    var artifacts: [2]Artifact = undefined;
    var messages: [2]Message = undefined;
    var strings: [4][]const u8 = undefined;
    var bytes: [64]u8 = undefined;

    var one_artifact: [1]Artifact = undefined;
    var one_artifact_arena = ContentArena.init(
        &parts,
        &one_artifact,
        &messages,
        &strings,
        &bytes,
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodeTask(
            "{\"id\":\"t\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}," ++
                "\"artifacts\":[{\"artifactId\":\"a\",\"parts\":[]}," ++
                "{\"artifactId\":\"b\",\"parts\":[]}]}",
            &one_artifact_arena,
            &scratch,
        ),
    );

    // And for the history array, which is the fifth slot and not the fourth.
    var one_message: [1]Message = undefined;
    var one_message_arena = ContentArena.init(
        &parts,
        &artifacts,
        &one_message,
        &strings,
        &bytes,
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodeTask(
            "{\"id\":\"t\",\"status\":{\"state\":\"TASK_STATE_WORKING\"}," ++
                "\"history\":[{\"messageId\":\"m-1\",\"role\":\"ROLE_USER\"," ++
                "\"parts\":[]},{\"messageId\":\"m-2\",\"role\":\"ROLE_USER\"," ++
                "\"parts\":[]},{\"messageId\":\"m-3\",\"role\":\"ROLE_USER\"," ++
                "\"parts\":[]}]}",
            &one_message_arena,
            &scratch,
        ),
    );

    // And for the shared string array, which is where a `repeated string` that
    // outgrows the caller's element storage lands.
    var one_string: [1][]const u8 = undefined;
    var one_string_arena = ContentArena.init(
        &parts,
        &artifacts,
        &messages,
        &one_string,
        &bytes,
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodeMessage(
            "{\"messageId\":\"m\",\"role\":\"ROLE_USER\",\"parts\":[]," ++
                "\"extensions\":[\"a\",\"b\"]}",
            &one_string_arena,
            &scratch,
        ),
    );

    // And for the decoded bytes of a `Part.raw`, the fifth array and the only
    // one holding something the codec computed rather than copied.
    //
    // The bound is `decodedLen` of the encoded text, which ignores the padding
    // and so overstates: `AAECAw==` is four bytes and the bound is six. A
    // four-byte buffer is refused and a six-byte one is not, and that is the
    // direction that matters — a buffer sized from the bound is never short,
    // whereas one sized from the result would report the peer's bytes as the
    // caller's mistake.
    var four_bytes: [4]u8 = undefined;
    var short_arena = ContentArena.init(
        &parts,
        &artifacts,
        &messages,
        &strings,
        &four_bytes,
    );
    try testing.expectError(
        error.BufferTooSmall,
        decodePart("{\"raw\":\"AAECAw==\"}", &short_arena, &scratch),
    );
    var six_bytes: [6]u8 = undefined;
    short_arena.bytes = &six_bytes;
    const decoded = try decodePart("{\"raw\":\"AAECAw==\"}", &short_arena, &scratch);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3 }, decoded.content.raw);

    // The encoder refuses the same value the same way, and it refuses before
    // the first byte rather than after.
    var refusal = json.Writer.init(&out);
    try testing.expectError(
        error.BufferTooSmall,
        encodePart(.{ .content = .{ .raw = &[_]u8{ 0, 1, 2, 3, 4 } } }, &refusal, base64[0..4]),
    );
    try testing.expectEqual(@as(usize, 0), refusal.written().len);
    // A base64 buffer that does fit takes the same value, so the refusal is the
    // buffer and not the bytes.
    var fits = json.Writer.init(&out);
    try encodePart(.{ .content = .{ .raw = &[_]u8{ 0, 1, 2, 3, 4 } } }, &fits, &base64);
    // `00 01 02 03 04` is `AAEC` then `AwQ=`: five bytes, so the tail carries
    // one pad and not two.
    try testing.expectEqualStrings("{\"raw\":\"AAECAwQ=\"}", fits.written());
}
