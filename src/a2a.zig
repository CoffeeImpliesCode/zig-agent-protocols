//! Agent2Agent, version `1.0.0`.
//!
//! Values come from PROTOCOLS.md section 5, which selects from
//! `research/normative/a2a-1.0.0.md`.
//!
//! ## Field numbers are normative
//!
//! PROTOCOLS.md section 5.4: "Field numbers are normative, because they are what
//! a protobuf encoder emits." A struct's field order is not a wire layout, so
//! each message here pairs a struct with a parallel table of field numbers and
//! checks the two against each other at comptime. Reordering a struct field
//! without updating its number is then a compile error rather than a silent
//! change to what a protobuf encoder emits.
//!
//! ## Naming
//!
//! The proto package is `lf.a2a.v1`, not `a2a.v1`. JSON field names are
//! camelCase, and enum values serialise as their full SCREAMING_SNAKE proto
//! names, so `TaskState.completed` is `"TASK_STATE_COMPLETED"` on the wire and
//! not `"completed"`. The Zig field names are the short forms PROTOCOLS.md
//! states; `wireName` carries the wire spelling.
//!
//! `TaskState` and `Role` are declared `enum(u8)` because PROTOCOLS.md says so.
//! The proto states no explicit backing type, and proto3's default is `int32`,
//! so `u8` is a narrowing this library chose, not a transcription. It is sound
//! because no value exceeds 8, and a tag above the declared range is
//! `error.UnknownTag` rather than a silent fallback to `unspecified`.

const std = @import("std");
const root = @import("root.zig");
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

/// The lowercase prefix the specification gives every service parameter it
/// defines, so they can coexist with transport-defined ones.
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

// --- 5.4 Field numbers ---------------------------------------------------------

/// Assert that a struct's field count matches its field-number table.
///
/// Without this the two tables drift apart silently, and the drift is invisible
/// until a peer decodes a field into the wrong place.
fn assertFieldCount(comptime T: type, comptime numbers: anytype) void {
    const declared = @typeInfo(T).@"struct".fields.len;
    const numbered = numbers.len;
    if (declared != numbered) {
        @compileError(std.fmt.comptimePrint(
            "{s} has {d} fields but {d} field numbers",
            .{ @typeName(T), declared, numbered },
        ));
    }
}

/// Assert that struct field `index` has the name the field-number table gives.
fn assertFieldName(
    comptime T: type,
    comptime index: usize,
    comptime expected: []const u8,
) void {
    const info = @typeInfo(T).@"struct".fields[index];
    if (!std.mem.eql(u8, info.name, expected)) {
        @compileError(std.fmt.comptimePrint(
            "{s} field {d} is named '{s}', but its field number is for '{s}'",
            .{ @typeName(T), index, info.name, expected },
        ));
    }
}

/// `Task`, field numbers 1 to 6.
pub const Task = struct {
    /// 1. Required, server-generated for a new task.
    id: []const u8,
    /// 2.
    context_id: []const u8 = "",
    /// 3.
    status: TaskStatus = .{ .state = .unspecified },
    /// 4.
    artifacts: []const Artifact = &.{},
    /// 5. Soft-deprecated in favour of a timeline, retained through 1.x.
    history: []const Message = &.{},
    /// 6.
    metadata: ?[]const u8 = null,
};

pub const task_field_numbers = .{ 1, 2, 3, 4, 5, 6 };

comptime {
    assertFieldCount(Task, task_field_numbers);
    assertFieldName(Task, 0, "id");
    assertFieldName(Task, 1, "context_id");
    assertFieldName(Task, 2, "status");
    assertFieldName(Task, 3, "artifacts");
    assertFieldName(Task, 4, "history");
    assertFieldName(Task, 5, "metadata");
}

/// `TaskStatus`, field numbers 1 to 3.
pub const TaskStatus = struct {
    /// 1. Required.
    state: TaskState,
    /// 2.
    message: ?Message = null,
    /// 3. ISO-8601 UTC in JSON.
    timestamp: ?[]const u8 = null,
};

pub const task_status_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(TaskStatus, task_status_field_numbers);
    assertFieldName(TaskStatus, 0, "state");
    assertFieldName(TaskStatus, 1, "message");
    assertFieldName(TaskStatus, 2, "timestamp");
}

/// `Message`, field numbers 1 to 8.
pub const Message = struct {
    /// 1. Required.
    message_id: []const u8,
    /// 2.
    context_id: []const u8 = "",
    /// 3.
    task_id: []const u8 = "",
    /// 4. Required.
    role: Role,
    /// 5. Required.
    parts: []const Part,
    /// 6.
    metadata: ?[]const u8 = null,
    /// 7. Extension URIs.
    extensions: []const []const u8 = &.{},
    /// 8.
    reference_task_ids: []const []const u8 = &.{},
};

pub const message_field_numbers = .{ 1, 2, 3, 4, 5, 6, 7, 8 };

comptime {
    assertFieldCount(Message, message_field_numbers);
    assertFieldName(Message, 0, "message_id");
    assertFieldName(Message, 1, "context_id");
    assertFieldName(Message, 2, "task_id");
    assertFieldName(Message, 3, "role");
    assertFieldName(Message, 4, "parts");
    assertFieldName(Message, 5, "metadata");
    assertFieldName(Message, 6, "extensions");
    assertFieldName(Message, 7, "reference_task_ids");
}

/// The `content` `oneof` of `Part`.
///
/// The discriminator is which member is present, not a `kind` field: the proto
/// has no `kind`, and a decoder switching on one would drop every part.
pub const PartContent = union(enum) {
    /// Field 1.
    text: []const u8,
    /// Field 2. Base64 in JSON.
    raw: []const u8,
    /// Field 3.
    url: []const u8,
    /// Field 4. Any JSON value.
    data: []const u8,
};

/// `Part`, field numbers 1 to 7.
pub const Part = struct {
    /// One of fields 1 to 4.
    content: PartContent,
    /// 5.
    metadata: ?[]const u8 = null,
    /// 6.
    filename: ?[]const u8 = null,
    /// 7. Available for every part type.
    media_type: ?[]const u8 = null,
};

pub const part_field_numbers = .{ 1, 2, 3, 4, 5, 6, 7 };

comptime {
    // The content oneof occupies the first four numbers as a single Zig field,
    // so the Zig struct has four fields against seven numbers.
    if (@typeInfo(Part).@"struct".fields.len != 4) {
        @compileError("Part must keep content, metadata, filename, media_type");
    }
    assertFieldName(Part, 0, "content");
    assertFieldName(Part, 1, "metadata");
    assertFieldName(Part, 2, "filename");
    assertFieldName(Part, 3, "media_type");
}

/// The four `oneof` members, keyed by their field numbers.
pub const part_content_field_number = struct {
    pub const text = 1;
    pub const raw = 2;
    pub const url = 3;
    pub const data = 4;
};

/// `Artifact`, field numbers 1 to 6.
pub const Artifact = struct {
    /// 1. Required.
    artifact_id: []const u8,
    /// 2.
    name: ?[]const u8 = null,
    /// 3.
    description: ?[]const u8 = null,
    /// 4. Required.
    parts: []const Part,
    /// 5.
    metadata: ?[]const u8 = null,
    /// 6.
    extensions: []const []const u8 = &.{},
};

pub const artifact_field_numbers = .{ 1, 2, 3, 4, 5, 6 };

comptime {
    assertFieldCount(Artifact, artifact_field_numbers);
    assertFieldName(Artifact, 0, "artifact_id");
    assertFieldName(Artifact, 1, "name");
    assertFieldName(Artifact, 2, "description");
    assertFieldName(Artifact, 3, "parts");
    assertFieldName(Artifact, 4, "metadata");
    assertFieldName(Artifact, 5, "extensions");
}

/// `TaskStatusUpdateEvent`, field numbers 1 to 4.
///
/// The `final` boolean was removed in 1.0. Stream closure is the terminal
/// signal, and there is no done-marker to miss.
pub const TaskStatusUpdateEvent = struct {
    /// 1.
    task_id: []const u8,
    /// 2.
    context_id: []const u8 = "",
    /// 3.
    status: TaskStatus,
    /// 4.
    metadata: ?[]const u8 = null,
};

pub const task_status_update_event_field_numbers = .{ 1, 2, 3, 4 };

comptime {
    assertFieldCount(TaskStatusUpdateEvent, task_status_update_event_field_numbers);
    assertFieldName(TaskStatusUpdateEvent, 0, "task_id");
    assertFieldName(TaskStatusUpdateEvent, 1, "context_id");
    assertFieldName(TaskStatusUpdateEvent, 2, "status");
    assertFieldName(TaskStatusUpdateEvent, 3, "metadata");
}

/// `TaskArtifactUpdateEvent`, field numbers 1 to 6.
pub const TaskArtifactUpdateEvent = struct {
    /// 1.
    task_id: []const u8,
    /// 2.
    context_id: []const u8 = "",
    /// 3.
    artifact: Artifact,
    /// 4.
    append: ?bool = null,
    /// 5. Marks artifact completion, not task completion.
    last_chunk: ?bool = null,
    /// 6.
    metadata: ?[]const u8 = null,
};

pub const task_artifact_update_event_field_numbers = .{ 1, 2, 3, 4, 5, 6 };

comptime {
    assertFieldCount(TaskArtifactUpdateEvent, task_artifact_update_event_field_numbers);
    assertFieldName(TaskArtifactUpdateEvent, 0, "task_id");
    assertFieldName(TaskArtifactUpdateEvent, 1, "context_id");
    assertFieldName(TaskArtifactUpdateEvent, 2, "artifact");
    assertFieldName(TaskArtifactUpdateEvent, 3, "append");
    assertFieldName(TaskArtifactUpdateEvent, 4, "last_chunk");
    assertFieldName(TaskArtifactUpdateEvent, 5, "metadata");
}

/// `SendMessageConfiguration`, field numbers 1 to 4.
pub const SendMessageConfiguration = struct {
    /// 1.
    accepted_output_modes: []const []const u8 = &.{},
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
    /// The proto declares the field a singular `bool`, so it has no presence
    /// bit and ProtoJSON rejects `null` for it. PROTOCOLS.md calls it
    /// "optional bool"; the proto's cardinality wins because absent and false
    /// are the same thing on the wire and no peer sends `null`.
    return_immediately: bool = false,
};

pub const send_message_configuration_field_numbers = .{ 1, 2, 3, 4 };

comptime {
    assertFieldCount(SendMessageConfiguration, send_message_configuration_field_numbers);
    assertFieldName(SendMessageConfiguration, 0, "accepted_output_modes");
    assertFieldName(SendMessageConfiguration, 1, "task_push_notification_config");
    assertFieldName(SendMessageConfiguration, 2, "history_length");
    assertFieldName(SendMessageConfiguration, 3, "return_immediately");
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
};

pub const authentication_info_field_numbers = .{ 1, 2 };

comptime {
    assertFieldCount(AuthenticationInfo, authentication_info_field_numbers);
    assertFieldName(AuthenticationInfo, 0, "scheme");
    assertFieldName(AuthenticationInfo, 1, "credentials");
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
};

pub const task_push_notification_config_field_numbers = .{ 1, 2, 3, 4, 5, 6 };

comptime {
    assertFieldCount(TaskPushNotificationConfig, task_push_notification_config_field_numbers);
    assertFieldName(TaskPushNotificationConfig, 0, "tenant");
    assertFieldName(TaskPushNotificationConfig, 1, "id");
    assertFieldName(TaskPushNotificationConfig, 2, "task_id");
    assertFieldName(TaskPushNotificationConfig, 3, "url");
    assertFieldName(TaskPushNotificationConfig, 4, "token");
    assertFieldName(TaskPushNotificationConfig, 5, "authentication");
}

/// The `payload` `oneof` of `SendMessageResponse`, field numbers 1 and 2.
pub const SendMessageResponse = union(enum) {
    /// 1.
    task: Task,
    /// 2.
    message: Message,
};

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
};

/// The send RPC's request. `message` is required by the proto.
pub const SendMessageRequest = struct {
    /// 1.
    tenant: []const u8 = "",
    /// 2. Required.
    message: Message,
    /// 3.
    configuration: ?SendMessageConfiguration = null,
    /// 4. Borrowed ProtoJSON `Struct`.
    metadata: ?[]const u8 = null,
};
pub const send_message_request_field_numbers = .{ 1, 2, 3, 4 };

/// Fetch one task, optionally including this many history messages.
pub const GetTaskRequest = struct {
    /// 1.
    tenant: []const u8 = "",
    /// 2. Required.
    id: []const u8,
    /// 3. Explicit proto3 presence.
    history_length: ?i32 = null,
};
pub const get_task_request_field_numbers = .{ 1, 2, 3 };

pub const ListTasksRequest = struct {
    /// 1.
    tenant: []const u8 = "",
    /// 2.
    context_id: []const u8 = "",
    /// 3.
    status: TaskState = .unspecified,
    /// 4. If present, 1 to 100 inclusive; see `isValidPageSize`.
    page_size: ?i32 = null,
    /// 5.
    page_token: []const u8 = "",
    /// 6.
    history_length: ?i32 = null,
    /// 7. ISO-8601 UTC in ProtoJSON.
    status_timestamp_after: ?[]const u8 = null,
    /// 8. Explicit presence; absent defaults to false.
    include_artifacts: ?bool = null,
};
pub const list_tasks_request_field_numbers = .{ 1, 2, 3, 4, 5, 6, 7, 8 };

pub const ListTasksResponse = struct {
    /// 1. Required, but may be empty.
    tasks: []const Task,
    /// 2. Required; an empty string marks the last page.
    next_page_token: []const u8,
    /// 3. Required.
    page_size: i32,
    /// 4. Required.
    total_size: i32,
};
pub const list_tasks_response_field_numbers = .{ 1, 2, 3, 4 };

pub const CancelTaskRequest = struct {
    /// 1.
    tenant: []const u8 = "",
    /// 2. Required.
    id: []const u8,
    /// 3. Borrowed ProtoJSON `Struct`.
    metadata: ?[]const u8 = null,
};
pub const cancel_task_request_field_numbers = .{ 1, 2, 3 };

pub const SubscribeToTaskRequest = struct {
    /// 1.
    tenant: []const u8 = "",
    /// 2. Required.
    id: []const u8,
};
pub const subscribe_to_task_request_field_numbers = .{ 1, 2 };

pub const GetTaskPushNotificationConfigRequest = struct {
    /// 1.
    tenant: []const u8 = "",
    /// 2. Required.
    task_id: []const u8,
    /// 3. Required.
    id: []const u8,
};
pub const get_task_push_notification_config_request_field_numbers = .{ 1, 2, 3 };

pub const DeleteTaskPushNotificationConfigRequest = struct {
    /// 1.
    tenant: []const u8 = "",
    /// 2. Required.
    task_id: []const u8,
    /// 3. Required.
    id: []const u8,
};
pub const delete_task_push_notification_config_request_field_numbers = .{ 1, 2, 3 };

/// The source proto declares `tenant` first, but assigns it field 4.
pub const ListTaskPushNotificationConfigsRequest = struct {
    /// 1. Required.
    task_id: []const u8,
    /// 2. Plain `int32`, not `optional int32` as in `ListTasksRequest`.
    page_size: i32 = 0,
    /// 3.
    page_token: []const u8 = "",
    /// 4.
    tenant: []const u8 = "",
};
pub const list_task_push_notification_configs_request_field_numbers = .{ 1, 2, 3, 4 };

pub const ListTaskPushNotificationConfigsResponse = struct {
    /// 1.
    configs: []const TaskPushNotificationConfig = &.{},
    /// 2. Unlike `ListTasksResponse.next_page_token`, this is not required.
    next_page_token: []const u8 = "",
};
pub const list_task_push_notification_configs_response_field_numbers = .{ 1, 2 };

pub const GetExtendedAgentCardRequest = struct {
    /// 1.
    tenant: []const u8 = "",
};
pub const get_extended_agent_card_request_field_numbers = .{1};

/// The `DeleteTaskPushNotificationConfig` response is `google.protobuf.Empty`.
pub const Empty = struct {};

comptime {
    assertFieldCount(SendMessageRequest, send_message_request_field_numbers);
    assertFieldCount(GetTaskRequest, get_task_request_field_numbers);
    assertFieldCount(ListTasksRequest, list_tasks_request_field_numbers);
    assertFieldCount(ListTasksResponse, list_tasks_response_field_numbers);
    assertFieldCount(CancelTaskRequest, cancel_task_request_field_numbers);
    assertFieldCount(SubscribeToTaskRequest, subscribe_to_task_request_field_numbers);
    assertFieldCount(
        GetTaskPushNotificationConfigRequest,
        get_task_push_notification_config_request_field_numbers,
    );
    assertFieldCount(
        DeleteTaskPushNotificationConfigRequest,
        delete_task_push_notification_config_request_field_numbers,
    );
    assertFieldCount(
        ListTaskPushNotificationConfigsRequest,
        list_task_push_notification_configs_request_field_numbers,
    );
    assertFieldCount(
        ListTaskPushNotificationConfigsResponse,
        list_task_push_notification_configs_response_field_numbers,
    );
    assertFieldCount(GetExtendedAgentCardRequest, get_extended_agent_card_request_field_numbers);
    for (.{ "tenant", "message", "configuration", "metadata" }, 0..) |name, index| {
        assertFieldName(SendMessageRequest, index, name);
    }
    for (.{ "tenant", "id", "history_length" }, 0..) |name, index| {
        assertFieldName(GetTaskRequest, index, name);
    }
    for (.{
        "tenant",         "context_id",             "status",            "page_size", "page_token",
        "history_length", "status_timestamp_after", "include_artifacts",
    }, 0..) |name, index| {
        assertFieldName(ListTasksRequest, index, name);
    }
    for (.{ "tasks", "next_page_token", "page_size", "total_size" }, 0..) |name, index| {
        assertFieldName(ListTasksResponse, index, name);
    }
    for (.{ "tenant", "id", "metadata" }, 0..) |name, index| {
        assertFieldName(CancelTaskRequest, index, name);
    }
    for (.{ "tenant", "id" }, 0..) |name, index| {
        assertFieldName(SubscribeToTaskRequest, index, name);
    }
    for (.{ "tenant", "task_id", "id" }, 0..) |name, index| {
        assertFieldName(GetTaskPushNotificationConfigRequest, index, name);
        assertFieldName(DeleteTaskPushNotificationConfigRequest, index, name);
    }
    for (.{ "task_id", "page_size", "page_token", "tenant" }, 0..) |name, index| {
        assertFieldName(ListTaskPushNotificationConfigsRequest, index, name);
    }
    for (.{ "configs", "next_page_token" }, 0..) |name, index| {
        assertFieldName(ListTaskPushNotificationConfigsResponse, index, name);
    }
    assertFieldName(GetExtendedAgentCardRequest, 0, "tenant");
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

/// The `AgentCard` field-number table. Field 15 is the lowest unused, and the
/// proto's `// Next ID: 20` marker reserves through 19.
pub const agent_card_field_numbers = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };

/// The field number the proto reserves for the next `AgentCard` field.
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
};

pub const agent_interface_field_numbers = .{ 1, 2, 3, 4 };

comptime {
    assertFieldCount(AgentInterface, agent_interface_field_numbers);
    assertFieldName(AgentInterface, 0, "url");
    assertFieldName(AgentInterface, 1, "protocol_binding");
    assertFieldName(AgentInterface, 2, "tenant");
    assertFieldName(AgentInterface, 3, "protocol_version");
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
};

/// `AgentProvider`, field numbers 1 to 2.
pub const AgentProvider = struct {
    /// 1. Required.
    url: []const u8,
    /// 2. Required.
    organization: []const u8,
};

pub const agent_provider_field_numbers = .{ 1, 2 };

comptime {
    assertFieldCount(AgentProvider, agent_provider_field_numbers);
    assertFieldName(AgentProvider, 0, "url");
    assertFieldName(AgentProvider, 1, "organization");
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
};

pub const agent_capabilities_field_numbers = .{ 1, 2, 3, 4 };

comptime {
    assertFieldCount(AgentCapabilities, agent_capabilities_field_numbers);
    assertFieldName(AgentCapabilities, 0, "streaming");
    assertFieldName(AgentCapabilities, 1, "push_notifications");
    assertFieldName(AgentCapabilities, 2, "extensions");
    assertFieldName(AgentCapabilities, 3, "extended_agent_card");
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
    /// 3. A plain `bool`, because the proto declares the field singular and it
    /// therefore has no presence bit. False is a flow that proceeds without
    /// the extension, and ProtoJSON rejects `null` for it.
    required: bool = false,
    /// 4. Extension settings, kept as the raw JSON the caller borrowed.
    params: ?[]const u8 = null,
};

pub const agent_extension_field_numbers = .{ 1, 2, 3, 4 };

comptime {
    assertFieldCount(AgentExtension, agent_extension_field_numbers);
    assertFieldName(AgentExtension, 0, "uri");
    assertFieldName(AgentExtension, 1, "description");
    assertFieldName(AgentExtension, 2, "required");
    assertFieldName(AgentExtension, 3, "params");
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
};

pub const agent_skill_field_numbers = .{ 1, 2, 3, 4, 5, 6, 7, 8 };

comptime {
    assertFieldCount(AgentSkill, agent_skill_field_numbers);
    assertFieldName(AgentSkill, 0, "id");
    assertFieldName(AgentSkill, 1, "name");
    assertFieldName(AgentSkill, 2, "description");
    assertFieldName(AgentSkill, 3, "tags");
    assertFieldName(AgentSkill, 4, "examples");
    assertFieldName(AgentSkill, 5, "input_modes");
    assertFieldName(AgentSkill, 6, "output_modes");
    assertFieldName(AgentSkill, 7, "security_requirements");
}

/// `AgentCard`, field numbers 1 to 14, checked against
/// `agent_card_field_numbers`.
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
};

comptime {
    assertFieldCount(AgentCard, agent_card_field_numbers);
    assertFieldName(AgentCard, 0, "name");
    assertFieldName(AgentCard, 1, "description");
    assertFieldName(AgentCard, 2, "supported_interfaces");
    assertFieldName(AgentCard, 3, "provider");
    assertFieldName(AgentCard, 4, "version");
    assertFieldName(AgentCard, 5, "documentation_url");
    assertFieldName(AgentCard, 6, "capabilities");
    assertFieldName(AgentCard, 7, "security_schemes");
    assertFieldName(AgentCard, 8, "security_requirements");
    assertFieldName(AgentCard, 9, "default_input_modes");
    assertFieldName(AgentCard, 10, "default_output_modes");
    assertFieldName(AgentCard, 11, "skills");
    assertFieldName(AgentCard, 12, "signatures");
    assertFieldName(AgentCard, 13, "icon_url");
}

pub const agent_card_signature_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(AgentCardSignature, agent_card_signature_field_numbers);
    assertFieldName(AgentCardSignature, 0, "protected");
    assertFieldName(AgentCardSignature, 1, "signature");
    assertFieldName(AgentCardSignature, 2, "header");
}

// --- 5.7 Security schemes ------------------------------------------------------

/// The field numbers of a protobuf `map` entry.
///
/// A map reaches the wire as a repeated synthetic message whose field 1 is the
/// key and field 2 is the value, whatever the two types are, so every map entry
/// in this file is numbered from this one table instead of repeating the pair.
pub const map_entry_field_numbers = .{ 1, 2 };

/// `StringList`, field 1.
///
/// The JSON name is `list`, singular, because the proto wraps the message in a
/// `protolint:disable REPEATED_FIELD_NAMES_PLURALIZED` directive. A decoder
/// that pluralised the name would read nothing.
pub const StringList = struct {
    /// 1.
    list: []const []const u8 = &.{},
};

pub const string_list_field_numbers = .{1};

comptime {
    assertFieldCount(StringList, string_list_field_numbers);
    assertFieldName(StringList, 0, "list");
}

/// One `SecurityRequirement.schemes` entry: a scheme name and the scopes it
/// needs.
pub const SecurityRequirementEntry = struct {
    /// 1, the map key.
    name: []const u8,
    /// 2, the map value.
    list: StringList,
};

comptime {
    assertFieldCount(SecurityRequirementEntry, map_entry_field_numbers);
    assertFieldName(SecurityRequirementEntry, 0, "name");
    assertFieldName(SecurityRequirementEntry, 1, "list");
}

/// One `AgentCard.security_schemes` entry: a scheme name and its definition.
pub const SecuritySchemeEntry = struct {
    /// 1, the map key. It is what a `SecurityRequirement` names.
    name: []const u8,
    /// 2, the map value.
    scheme: SecurityScheme,
};

comptime {
    assertFieldCount(SecuritySchemeEntry, map_entry_field_numbers);
    assertFieldName(SecuritySchemeEntry, 0, "name");
    assertFieldName(SecuritySchemeEntry, 1, "scheme");
}

/// `SecurityRequirement`, field 1.
///
/// Every scheme named in one requirement must hold, which is what makes a
/// requirement a conjunction. The requirements in a card's list are
/// alternatives to each other.
pub const SecurityRequirement = struct {
    /// 1.
    schemes: []const SecurityRequirementEntry = &.{},
};

pub const security_requirement_field_numbers = .{1};

comptime {
    assertFieldCount(SecurityRequirement, security_requirement_field_numbers);
    assertFieldName(SecurityRequirement, 0, "schemes");
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
};

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
};

/// The `OAuthFlows` `oneof` field numbers, as a table because a union carries
/// no field order of its own to check one against.
pub const oauth_flows_field_number = struct {
    pub const authorization_code = 1;
    pub const client_credentials = 2;
    pub const implicit = 3;
    pub const password = 4;
    pub const device_code = 5;
};

/// One entry of a flow's `scopes`, which the proto types `map<string, string>`.
///
/// The key is a scope name and the value its short description, as in the
/// OpenAPI 3.2 Security Scheme Object this proto mirrors. PROTOCOLS.md
/// section 5.7 does not restate what the value means, so the field names
/// follow the OpenAPI object rather than a second reading of the proto.
pub const OAuthScope = struct {
    /// 1, the map key.
    name: []const u8,
    /// 2, the map value.
    description: []const u8,
};

comptime {
    assertFieldCount(OAuthScope, map_entry_field_numbers);
    assertFieldName(OAuthScope, 0, "name");
    assertFieldName(OAuthScope, 1, "description");
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
};

pub const authorization_code_oauth_flow_field_numbers = .{ 1, 2, 3, 4, 5 };

comptime {
    assertFieldCount(AuthorizationCodeOAuthFlow, authorization_code_oauth_flow_field_numbers);
    assertFieldName(AuthorizationCodeOAuthFlow, 0, "authorization_url");
    assertFieldName(AuthorizationCodeOAuthFlow, 1, "token_url");
    assertFieldName(AuthorizationCodeOAuthFlow, 2, "refresh_url");
    assertFieldName(AuthorizationCodeOAuthFlow, 3, "scopes");
    assertFieldName(AuthorizationCodeOAuthFlow, 4, "pkce_required");
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
};

pub const client_credentials_oauth_flow_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(ClientCredentialsOAuthFlow, client_credentials_oauth_flow_field_numbers);
    assertFieldName(ClientCredentialsOAuthFlow, 0, "token_url");
    assertFieldName(ClientCredentialsOAuthFlow, 1, "refresh_url");
    assertFieldName(ClientCredentialsOAuthFlow, 2, "scopes");
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
};

pub const implicit_oauth_flow_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(ImplicitOAuthFlow, implicit_oauth_flow_field_numbers);
    assertFieldName(ImplicitOAuthFlow, 0, "authorization_url");
    assertFieldName(ImplicitOAuthFlow, 1, "refresh_url");
    assertFieldName(ImplicitOAuthFlow, 2, "scopes");
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
};

pub const password_oauth_flow_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(PasswordOAuthFlow, password_oauth_flow_field_numbers);
    assertFieldName(PasswordOAuthFlow, 0, "token_url");
    assertFieldName(PasswordOAuthFlow, 1, "refresh_url");
    assertFieldName(PasswordOAuthFlow, 2, "scopes");
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
};

pub const device_code_oauth_flow_field_numbers = .{ 1, 2, 3, 4 };

comptime {
    assertFieldCount(DeviceCodeOAuthFlow, device_code_oauth_flow_field_numbers);
    assertFieldName(DeviceCodeOAuthFlow, 0, "device_authorization_url");
    assertFieldName(DeviceCodeOAuthFlow, 1, "token_url");
    assertFieldName(DeviceCodeOAuthFlow, 2, "refresh_url");
    assertFieldName(DeviceCodeOAuthFlow, 3, "scopes");
}

pub const ApiKeySecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    location: ApiKeyLocation,
    /// 3. Required.
    name: []const u8,
};

pub const api_key_security_scheme_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(ApiKeySecurityScheme, api_key_security_scheme_field_numbers);
    assertFieldName(ApiKeySecurityScheme, 0, "description");
    assertFieldName(ApiKeySecurityScheme, 1, "location");
    assertFieldName(ApiKeySecurityScheme, 2, "name");
}

pub const HttpAuthSecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    scheme: []const u8,
    /// 3.
    bearer_format: ?[]const u8 = null,
};

pub const http_auth_security_scheme_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(HttpAuthSecurityScheme, http_auth_security_scheme_field_numbers);
    assertFieldName(HttpAuthSecurityScheme, 0, "description");
    assertFieldName(HttpAuthSecurityScheme, 1, "scheme");
    assertFieldName(HttpAuthSecurityScheme, 2, "bearer_format");
}

pub const OAuth2SecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    flows: OAuthFlows,
    /// 3.
    oauth2_metadata_url: ?[]const u8 = null,
};

pub const oauth2_security_scheme_field_numbers = .{ 1, 2, 3 };

comptime {
    assertFieldCount(OAuth2SecurityScheme, oauth2_security_scheme_field_numbers);
    assertFieldName(OAuth2SecurityScheme, 0, "description");
    assertFieldName(OAuth2SecurityScheme, 1, "flows");
    assertFieldName(OAuth2SecurityScheme, 2, "oauth2_metadata_url");
}

pub const OpenIdConnectSecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
    /// 2. Required.
    open_id_connect_url: []const u8,
};

pub const open_id_connect_security_scheme_field_numbers = .{ 1, 2 };

comptime {
    assertFieldCount(OpenIdConnectSecurityScheme, open_id_connect_security_scheme_field_numbers);
    assertFieldName(OpenIdConnectSecurityScheme, 0, "description");
    assertFieldName(OpenIdConnectSecurityScheme, 1, "open_id_connect_url");
}

pub const MutualTlsSecurityScheme = struct {
    /// 1.
    description: ?[]const u8 = null,
};

pub const mutual_tls_security_scheme_field_numbers = .{1};

comptime {
    assertFieldCount(MutualTlsSecurityScheme, mutual_tls_security_scheme_field_numbers);
    assertFieldName(MutualTlsSecurityScheme, 0, "description");
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

const testing = std.testing;

/// Assert that a field-number table runs 1 to its own length.
///
/// The comptime checks tie a field name to a position. This ties the position
/// to the number a protobuf encoder emits, which is the half nothing else
/// checks: a table with a gap or a repeat still passes `assertFieldCount`.
fn expectContiguousFieldNumbers(comptime numbers: anytype) !void {
    var expected: i32 = 1;
    inline for (numbers) |number| {
        try testing.expectEqual(expected, @as(i32, number));
        expected += 1;
    }
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
    // between absent and false, and `null` is not a value a peer sends.
    const blocking: SendMessageConfiguration = .{};
    try testing.expect(!blocking.return_immediately);
    const immediate: SendMessageConfiguration = .{ .return_immediately = true };
    try testing.expect(immediate.return_immediately);
    // The inversion matters: false blocks, so a caller that ignores the flag
    // waits, and one that reads it as 0.3's `blocking` waits too.
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

test "an AgentInterface version must be Major.Minor" {
    try testing.expectError(error.InvalidField, parseVersion("1.0.0"));
    try testing.expectEqual(@as(u16, 1), (try parseVersion("1.0")).major);
    try testing.expectEqual(@as(u16, 3), (try parseVersion("0.3")).minor);
}

test "the agent card field range leaves 15 free" {
    try testing.expectEqual(@as(usize, 14), agent_card_field_numbers.len);
    try testing.expectEqual(@as(i32, 20), agent_card_next_id);
    try testing.expectEqual(@as(usize, 5), removed_agent_card_fields.len);
}

test "AuthenticationInfo requires a scheme and keeps credentials optional" {
    try expectContiguousFieldNumbers(authentication_info_field_numbers);
    // `scheme` is the only REQUIRED field, so it is the only one a minimal
    // value has to set, and a missing credential is not an empty credential.
    const info: AuthenticationInfo = .{ .scheme = "Bearer" };
    try testing.expectEqualStrings("Bearer", info.scheme);
    try testing.expectEqual(@as(?[]const u8, null), info.credentials);
}

test "TaskPushNotificationConfig numbers the webhook url 4 and its token 5" {
    try expectContiguousFieldNumbers(task_push_notification_config_field_numbers);
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
    try expectContiguousFieldNumbers(string_list_field_numbers);
    // The proto disables the pluralisation lint on this message, so the wire
    // name is `list`. A decoder that looked for `lists` would read nothing.
    const scopes: StringList = .{ .list = &.{ "openid", "a2a.tasks" } };
    try testing.expectEqual(@as(usize, 2), scopes.list.len);
    try testing.expectEqualStrings("a2a.tasks", scopes.list[1]);
}

test "a security requirement maps a scheme name to the scopes it needs" {
    try expectContiguousFieldNumbers(security_requirement_field_numbers);
    try expectContiguousFieldNumbers(map_entry_field_numbers);
    const requirement: SecurityRequirement = .{ .schemes = &.{
        .{ .name = "oauth", .list = .{ .list = &.{"a2a.tasks"} } },
    } };
    try testing.expectEqual(@as(usize, 1), requirement.schemes.len);
    try testing.expectEqualStrings("oauth", requirement.schemes[0].name);
    try testing.expectEqualStrings("a2a.tasks", requirement.schemes[0].list.list[0]);
}

test "a card scheme entry pairs the name a requirement names with its scheme" {
    try expectContiguousFieldNumbers(map_entry_field_numbers);
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
    try expectContiguousFieldNumbers(agent_provider_field_numbers);
    const provider: AgentProvider = .{
        .url = "https://example.com",
        .organization = "Example",
    };
    try testing.expectEqualStrings("Example", provider.organization);
}

test "an unset capability is not a capability of false" {
    try expectContiguousFieldNumbers(agent_capabilities_field_numbers);
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
    try expectContiguousFieldNumbers(agent_extension_field_numbers);
    // `required` is a singular bool with no presence bit, so false is the
    // whole of a declaration that does not demand the extension.
    const uri = "https://example.com/extensions/geolocation/v1";
    const extension: AgentExtension = .{ .uri = uri };
    try testing.expect(!extension.required);
    try testing.expectEqual(@as(?[]const u8, null), extension.params);
    const demanding: AgentExtension = .{ .uri = uri, .required = true };
    try testing.expect(demanding.required);
    // A required extension the client did not activate is -32008, not a
    // silent skip, and the same extension activated does satisfy it.
    const other = [_][]const u8{"https://example.com/extensions/citations/v1"};
    try testing.expect(!extensionSatisfied(&other, demanding.required, uri));
    try testing.expect(extensionSatisfied(&.{uri}, demanding.required, uri));
}

test "AgentSkill numbers four required fields ahead of four optional ones" {
    try expectContiguousFieldNumbers(agent_skill_field_numbers);
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
    try testing.expectEqual(@as(i32, 8), agent_skill_field_numbers[7]);
}

test "the AgentCard requires exactly the eight fields the proto marks required" {
    try expectContiguousFieldNumbers(agent_card_field_numbers);
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
        .version = "1.0.0",
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
    try testing.expectEqual(@as(i32, 14), agent_card_field_numbers[13]);
}

test "the device code flow is variant 5 and carries its own authorization URL" {
    try expectContiguousFieldNumbers(device_code_oauth_flow_field_numbers);
    try testing.expectEqual(5, oauth_flows_field_number.device_code);
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
    try expectContiguousFieldNumbers(authorization_code_oauth_flow_field_numbers);
    try expectContiguousFieldNumbers(client_credentials_oauth_flow_field_numbers);
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
    try expectContiguousFieldNumbers(implicit_oauth_flow_field_numbers);
    try expectContiguousFieldNumbers(password_oauth_flow_field_numbers);
    // Neither carries a REQUIRED annotation, so a peer may send an empty one
    // and a decoder has to hold it rather than reject the whole card.
    const implicit: ImplicitOAuthFlow = .{};
    const password: PasswordOAuthFlow = .{};
    try testing.expectEqual(@as(?[]const u8, null), implicit.authorization_url);
    try testing.expectEqual(@as(usize, 0), implicit.scopes.len);
    try testing.expectEqual(@as(?[]const u8, null), password.token_url);
    try testing.expectEqual(@as(usize, 0), password.scopes.len);
    // They are variants 3 and 4, either side of device code at 5.
    try testing.expectEqual(3, oauth_flows_field_number.implicit);
    try testing.expectEqual(4, oauth_flows_field_number.password);
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
