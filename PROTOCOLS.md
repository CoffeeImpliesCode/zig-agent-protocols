# PROTOCOLS.md

The wire contract for `src/`. This document is the authority for every type name,
tag value and byte layout in the library. If the source and this document
disagree, the source is wrong.

Evidence, dated to **2026-09-29**, lives in [`research/`](research/README.md). Where
a value here is marked `NOT ESTABLISHED`, no primary source defined it and this
library does not invent one; the corresponding case is an explicit decode or encode
failure rather than a guess.

## 1. Scope

Implemented protocols, at the pinned revisions in section 8:

| Protocol | Revision pinned | Wire format |
| --- | --- | --- |
| Model Context Protocol | `2026-07-28`, with `2025-11-25` as a separately decoded revision | JSON-RPC 2.0 over stdio or Streamable HTTP |
| Agent2Agent | `1.0.0` (patch `v1.0.1`) | Protobuf/ProtoJSON, JSON-RPC 2.0, gRPC, HTTP+JSON |
| Agent Client Protocol | wire version `1`, with `2` gated | JSON-RPC 2.0 over stdio |

Explicitly not implemented, and why, is in section 9.

Every literal value in this document is transcribed from a primary artifact and
reproduced in full under [`research/normative/`](research/normative/README.md):
[`mcp-2026-07-28.md`](research/normative/mcp-2026-07-28.md),
[`a2a-1.0.0.md`](research/normative/a2a-1.0.0.md) and
[`acp-v1-v2.md`](research/normative/acp-v1-v2.md) for the three implemented
protocols, and
[`ui-protocols.md`](research/normative/ui-protocols.md),
[`commerce.md`](research/normative/commerce.md) and
[`instructions-observability.md`](research/normative/instructions-observability.md)
for the ones section 9 excludes. Those files are the authority for the values; this
document selects from them.

## 2. Encoding contract

These follow from the Zig toolchain and from the fact that every byte on these
wires is attacker-controlled input. They are not negotiable per protocol.

- **Decoding is total.** It returns a `DecodeError` and never `unreachable`. A peer
  speaking a newer version, or a peer sending a tag this library has never heard
  of, gets an error, not a panic.
- **Encoding is the exact inverse.** `decode(encode(x)) == x` and
  `encode(decode(b)) == b` for every accepted input. Both directions are tested.
- **No allocation in a decode or encode path.** The caller supplies every buffer.
  Slices borrow from the caller's arena; nothing is retained past the call.
- **Every wire integer is explicitly sized.** `i64` for JSON-RPC `id`, `i32` for
  error codes, `u8` for status enums, `i32` for protobuf field numbers' domain.
  A struct is `extern` only where a C ABI genuinely requires the layout; nothing
  here is `packed`.
- **Unknown enum tags and unknown method names are errors**, not `unreachable`
  arms and not silently mapped to a default.
- **Optionality is explicit.** A field that the spec marks optional is
  `?T` in Zig and its presence is preserved through a round trip. A field the spec
  marks required but omits on the wire is a decode error.

### 2.1 The shared decode error set

`src/root.zig` declares one error set for the whole library. Its members are the
union of the per-protocol failure modes, because a caller that decodes bytes does
not know in advance which protocol produced them.

```zig
pub const DecodeError = error{
    /// Input ended before the value was complete.
    Truncated,
    /// A byte sequence was not valid UTF-8 where the protocol requires text.
    InvalidUtf8,
    /// A JSON syntax error, or a value of the wrong JSON type.
    MalformedJson,
    /// A required field was absent.
    MissingField,
    /// A field was present with a value the protocol does not permit.
    InvalidField,
    /// An enum tag this library does not know.
    UnknownTag,
    /// A method name this library does not know for the negotiated revision.
    UnknownMethod,
    /// The peer's protocol version is not one this library implements.
    UnsupportedVersion,
    /// The caller-supplied output buffer was too small.
    BufferTooSmall,
    /// A limit the protocol states as a numeric bound was exceeded.
    LimitExceeded,
};
```

Encode returns `EncodeError`, which is smaller: `BufferTooSmall`, `InvalidField`,
`UnknownTag`. Encoding a value that could not have been decoded is a programming
error, not a wire condition.

## 3. JSON-RPC 2.0 base

MCP and ACP are both JSON-RPC 2.0. A2A's JSON-RPC binding is JSON-RPC 2.0 as well.

| Element | Value |
| --- | --- |
| `jsonrpc` | `"2.0"`, always present, always this exact string |
| `id` | Integer or string. Absent on notifications. `i64` in Zig, range-checked |
| `method` | String. Split once on `/` for the category-action form used by MCP and ACP v0.3 |
| `params` | Object or array. `null` and absent are distinct and preserved |
| `result` | Present on success, mutually exclusive with `error` |
| `error` | `{code, message, data?}`. `code` is `i32` |

A message with both `result` and `error`, or with neither, is a decode error. A
message with an `id` and no `method` is a response; a message with a `method` and
no `id` is a notification; a message with both is a request.

### 3.1 JSON-RPC standard error codes

| Code | Name | Meaning |
| --- | --- | --- |
| `-32700` | Parse error | Invalid JSON was received |
| `-32600` | Invalid Request | The JSON is not a valid request object |
| `-32601` | Method not found | The method does not exist for this revision |
| `-32602` | Invalid params | Invalid method parameters |
| `-32603` | Internal error | Internal error in the peer |

## 4. Model Context Protocol

### 4.1 Version and transport

| Constant | Value |
| --- | --- |
| `LATEST_PROTOCOL_VERSION` | `"2026-07-28"` |
| `PREVIOUS_PROTOCOL_VERSION` | `"2025-11-25"` |
| `JSONRPC_VERSION` | `"2.0"` |

Transports: `stdio` and Streamable HTTP. The HTTP+SSE transport, deprecated in
`2025-03-26` and formally deprecated in `2026-07-28`, is not implemented.

### 4.2 HTTP headers

Casing is normative. HTTP header names are case-insensitive on the wire, so
matching is case-insensitive, but these are the spellings the specification uses.

| Header | Direction | Requirement |
| --- | --- | --- |
| `MCP-Protocol-Version` | both | Carries the protocol version on Streamable HTTP |
| `Mcp-Method` | request | Required on Streamable HTTP POST from `2026-07-28`. Carries the JSON-RPC method so a gateway can route without parsing the body |
| `Mcp-Name` | request | Required on Streamable HTTP POST from `2026-07-28`. Carries the tool, resource, prompt or template name |
| `x-mcp-header` | neither | Not a header the client sends. It is a **JSON Schema extension keyword** inside `Tool.inputSchema` properties. Optional for servers; clients **MUST** support it |
| `Mcp-Param-{Name}` | request | The header a client **derives** from an `x-mcp-header: "<Name>"` annotation. Clients **MUST** support it; servers **MUST** validate and **MUST** reject on mismatch |
| `Mcp-Session-Id` | — | **Removed** in `2026-07-28`. A peer that sends it is not speaking this revision |
| `Last-Event-ID` | — | **Removed** in `2026-07-28`, with SSE resumption |

The derived header name and value are one line, verbatim from the specification:

```text
Mcp-Param-{Name}: =?base64?{Base64EncodedValue}?=
```

The `=?base64?` prefix and the `?=` suffix are case-sensitive and MUST appear
exactly as written when present. `Mcp-Name` carries the same sentinel encoding when
its source value is not plain ASCII.

Two constraints bind a decoder. `MCP-Protocol-Version` is all-caps while every other
MCP-defined header is title-case `Mcp-`; both spellings appear verbatim in the same
specification document and both are required, so a header table must not key on one
casing. And `x-mcp-header` values must be unique case-insensitively within one
`inputSchema`, and may only annotate primitive parameters.

### 4.3 Reserved `_meta` keys

The `_meta` key namespace is `io.modelcontextprotocol/`, and a key outside it
requires a vendor prefix. Three bare key names are excepted from the prefix rule
so that W3C trace context works.

| Key | Carries |
| --- | --- |
| `io.modelcontextprotocol/protocolVersion` | The client's protocol version, on every request |
| `io.modelcontextprotocol/clientCapabilities` | The client's capabilities, on every request |
| `io.modelcontextprotocol/clientInfo` | Client name and version. Clients SHOULD identify themselves on each request |
| `io.modelcontextprotocol/serverInfo` | Server name and version, in each result |
| `io.modelcontextprotocol/logLevel` | Per-request log level, replacing the removed `logging/setLevel` |
| `io.modelcontextprotocol/subscriptionId` | The subscription a notification belongs to, on the `subscriptions/listen` stream |
| `traceparent` | W3C Trace Context, exempt from the prefix rule |
| `tracestate` | W3C Trace Context, exempt from the prefix rule |
| `baggage` | W3C Baggage, exempt from the prefix rule |

### 4.4 Method inventory

Core, `2026-07-28`. `server/discover` is the only mandatory server method.

| Method | Direction | Notes |
| --- | --- | --- |
| `server/discover` | client to server | Mandatory. Returns supported versions, capabilities, identity |
| `tools/list` | client to server | Cacheable result |
| `tools/call` | client to server | May return `input_required` under MRTR |
| `resources/list` | client to server | Cacheable result |
| `resources/read` | client to server | Cacheable result. May return `input_required` under MRTR |
| `resources/templates/list` | client to server | Cacheable result |
| `prompts/list` | client to server | Cacheable result |
| `prompts/get` | client to server | May return `input_required` under MRTR |
| `subscriptions/listen` | client to server | Single long-lived response stream for opted-in notifications |
| `notifications/progress` | server to client | Request-scoped; travels on the originating request's response stream |
| `notifications/message` | server to client | Request-scoped. A server MUST NOT emit it for a request that did not set `io.modelcontextprotocol/logLevel` |

Removed in `2026-07-28`, and therefore decoded as `UnknownMethod` at that
revision: `initialize`, `notifications/initialized`, `ping`, `logging/setLevel`,
`notifications/roots/list_changed`, `resources/subscribe`, `resources/unsubscribe`,
`sampling/createMessage`, `elicitation/create` as a top-level request, `roots/list`,
`notifications/elicitation/complete`.

Removed or deprecated server-to-client methods retain their *types* as values
inside `InputRequiredResult.inputRequests`; see 4.6.

### 4.5 Error codes

| Range | Owner |
| --- | --- |
| `-32700` to `-32603` | JSON-RPC standard, table 3.1 |
| `-32000` to `-32019` | Implementation-defined. Existing SDK usage is grandfathered |
| `-32020` to `-32099` | Reserved for the specification |

| Code | Name |
| --- | --- |
| `-32020` | `HeaderMismatch` |
| `-32021` | `MissingRequiredClientCapability` |
| `-32022` | `UnsupportedProtocolVersion` |

The resource-not-found code changed from `-32002` to `-32602` in `2026-07-28`, to
match the JSON-RPC specification. A decoder pinned to `2025-11-25` accepts
`-32002`; a decoder pinned to `2026-07-28` does not.

### 4.6 The result envelope

Every result carries `resultType`.

| Value | Meaning |
| --- | --- |
| `"complete"` | An ordinary result |
| `"input_required"` | An interim result. The client answers and retries the original request |

A result from a peer on an earlier revision omits `resultType`. A client MUST
treat that as `"complete"`. The generated JSON Schema types `resultType` as a bare
`string` with no enum, so the decoder enforces the two values itself.

Cacheable results add two required fields.

| Field | Type | Notes |
| --- | --- | --- |
| `ttlMs` | `u64` | Freshness hint in milliseconds |
| `cacheScope` | enum | `"private"` or `"public"`. Controls whether shared intermediaries may cache |

### 4.7 Multi Round-Trip Requests

The pattern that replaced every server-initiated request.

```
client -> server   tools/call {name, arguments, _meta{...}}
server -> client   resultType: "input_required", inputRequests, requestState
client -> server   tools/call {name, arguments, inputResponses, requestState, _meta{...}}   [new id]
server -> client   resultType: "complete", ...
```

| Field | Type | Notes |
| --- | --- | --- |
| `inputRequests` | map from server-assigned string id to a request object | Keys are server-chosen strings. Only `tools/call`, `resources/read` and `prompts/get` may return this |
| `inputResponses` | map keyed by the same ids | Carried on the retry |
| `requestState` | opaque string | **Attacker-controlled.** A server MUST integrity-protect it if it influences authorization |

An MRTR retry uses a new JSON-RPC `id`. Reusing the original `id` is a protocol
violation and this library does not generate it.

### 4.8 Capabilities

On `2026-07-28` and later there is no handshake, so capabilities are per request.

```
client -> server   _meta["io.modelcontextprotocol/clientCapabilities"] = { ... }
server -> client   server/discover result -> capabilities = { ... }
```

On `2025-11-25` and earlier the same object is carried in the `initialize` request
and response instead. The two paths are not symmetric, which is why a decoder is
pinned to one revision rather than branching on a flag.

Extension support is an `extensions` map from extension identifier to that
extension's settings object. An empty object `{}` means supported with no settings.

| Extension identifier | Repo | Status |
| --- | --- | --- |
| `io.modelcontextprotocol/ui` | `ext-apps` | `2026-01-26` Stable. MCP Apps |
| `io.modelcontextprotocol/tasks` | `ext-tasks` | `2026-07-28`. Async task execution |
| `io.modelcontextprotocol/skills` | `ext-skills` | SEP-2640 Final 2026-09-13 |
| `io.modelcontextprotocol/oauth-client-credentials` | `ext-auth` | Machine-to-machine auth |
| `io.modelcontextprotocol/enterprise-managed-authorization` | `ext-auth` | Centralized enterprise policy |

Extension methods:

| Method | Extension |
| --- | --- |
| `tasks/get`, `tasks/update`, `tasks/cancel`, `notifications/tasks` | tasks |
| `skills/list`, `skills/get`, `resources/directory/read` | skills |

URI schemes and media types:

| Constant | Value |
| --- | --- |
| `ui://` | MCP Apps UI resource scheme |
| `skill://` | Skills extension resource scheme |
| `text/html;profile=mcp-app` | MCP Apps required MIME type |
| `sha256:<64 lowercase hex>` | Skills extension resource digest format |

### 4.9 Deprecated feature registry

Present in the specification, functional for now, and not to be adopted. Earliest
removal is the first revision released on or after **2027-07-28**, with a
90-day floor on any expedited removal.

| Feature | Status |
| --- | --- |
| Roots | Deprecated |
| Sampling | Deprecated |
| Logging | Deprecated |
| Dynamic Client Registration | Deprecated in favour of Client ID Metadata Documents |
| HTTP+SSE transport | Deprecated |
| `includeContext` values `"thisServer"` and `"allServers"` | Deprecated |

No feature has reached the Removed state.

## 5. Agent2Agent

### 5.1 Normative source and package

`specification/a2a.proto` is the single normative artifact. The generated JSON
is not committed and is explicitly non-normative. The generated JSON Schema
artifact is currently 404.

| Constant | Value |
| --- | --- |
| Protobuf package | `lf.a2a.v1` |
| gRPC service | `A2AService` |
| Discovery path | `/.well-known/agent-card.json` |
| Media type | `application/a2a+json` |
| Service parameter, version | `A2A-Version` |
| Service parameter, extensions | `A2A-Extensions` |

Serialization is ProtoJSON per ADR-001: camelCase field names, enum values as
their protobuf names, `google.protobuf.Timestamp` as ISO-8601 UTC.

`A2A-Version` carries `Major.Minor` with no patch component. **An empty value is
interpreted as `0.3`.** Patch versions MUST NOT appear in a request, a response,
or an Agent Card.

### 5.2 Enums

```zig
pub const TaskState = enum(u8) {
    unspecified = 0,
    submitted = 1,
    working = 2,
    completed = 3,
    failed = 4,
    canceled = 5,
    input_required = 6,
    rejected = 7,
    auth_required = 8,
};
```

| Value | Number | Class |
| --- | --- | --- |
| `TASK_STATE_UNSPECIFIED` | 0 | |
| `TASK_STATE_SUBMITTED` | 1 | |
| `TASK_STATE_WORKING` | 2 | |
| `TASK_STATE_COMPLETED` | 3 | terminal |
| `TASK_STATE_FAILED` | 4 | terminal |
| `TASK_STATE_CANCELED` | 5 | terminal |
| `TASK_STATE_INPUT_REQUIRED` | 6 | interrupted |
| `TASK_STATE_REJECTED` | 7 | terminal |
| `TASK_STATE_AUTH_REQUIRED` | 8 | interrupted |

```zig
pub const Role = enum(u8) {
    unspecified = 0,
    user = 1,
    agent = 2,
};
```

| Value | Number |
| --- | --- |
| `ROLE_UNSPECIFIED` | 0 |
| `ROLE_USER` | 1 |
| `ROLE_AGENT` | 2 |

`enum(u8)` rather than `enum(i32)` is safe here because no value exceeds 8. A tag
above the declared range is `DecodeError.UnknownTag`, never a silent fallback to
`unspecified`.

### 5.3 Service and bindings

There is no mandatory binding. An agent declares an ordered `supportedInterfaces`
and a client picks the first entry it supports. Every RPC has a `/{tenant}/...`
secondary HTTP binding.

| RPC | Request | Response | HTTP |
| --- | --- | --- | --- |
| `SendMessage` | `SendMessageRequest` | `SendMessageResponse` | `POST /message:send` |
| `SendStreamingMessage` | `SendMessageRequest` | `stream StreamResponse` | `POST /message:stream` |
| `GetTask` | `GetTaskRequest` | `Task` | `GET /tasks/{id}` |
| `ListTasks` | `ListTasksRequest` | `ListTasksResponse` | `GET /tasks` |
| `CancelTask` | `CancelTaskRequest` | `Task` | `POST /tasks/{id}:cancel` |
| `SubscribeToTask` | `SubscribeToTaskRequest` | `stream StreamResponse` | `GET /tasks/{id}:subscribe` |
| `CreateTaskPushNotificationConfig` | `TaskPushNotificationConfig` | `TaskPushNotificationConfig` | `POST /tasks/{task_id}/pushNotificationConfigs` |
| `GetTaskPushNotificationConfig` | `GetTaskPushNotificationConfigRequest` | `TaskPushNotificationConfig` | `GET /tasks/{task_id}/pushNotificationConfigs/{id}` |
| `ListTaskPushNotificationConfigs` | `ListTaskPushNotificationConfigsRequest` | `ListTaskPushNotificationConfigsResponse` | `GET /tasks/{task_id}/pushNotificationConfigs` |
| `DeleteTaskPushNotificationConfig` | `DeleteTaskPushNotificationConfigRequest` | `TaskPushNotificationConfig` | `DELETE /tasks/{task_id}/pushNotificationConfigs/{id}` |
| `GetExtendedAgentCard` | `GetExtendedAgentCardRequest` | `AgentCard` | `GET /extendedAgentCard` |

The JSON-RPC binding uses the same names as the RPCs. Version `0.3` used the
slash form; only four method names are aliased for it, and anything else at `0.3`
returns `-32601`.

`SubscribeToTask` returns `UnsupportedOperationError` for a task already in a
terminal state.

### 5.4 Core messages

Field numbers are normative, because they are what a protobuf encoder emits.

`Task`

| # | Field | Type | Notes |
| --- | --- | --- | --- |
| 1 | `id` | string | Required. Server-generated for a new task |
| 2 | `context_id` | string | |
| 3 | `status` | `TaskStatus` | |
| 4 | `artifacts` | repeated `Artifact` | |
| 5 | `history` | repeated `Message` | Soft-deprecated in favour of `timeline`; retained through 1.x, removed in 2.0 |
| 6 | `metadata` | `Struct` | |

`TaskStatus`

| # | Field | Type | Notes |
| --- | --- | --- | --- |
| 1 | `state` | `TaskState` | Required |
| 2 | `message` | `Message` | |
| 3 | `timestamp` | `Timestamp` | ISO-8601 UTC |

`Message`

| # | Field | Type | Notes |
| --- | --- | --- | --- |
| 1 | `message_id` | string | Required |
| 2 | `context_id` | string | |
| 3 | `task_id` | string | |
| 4 | `role` | `Role` | Required |
| 5 | `parts` | repeated `Part` | Required |
| 6 | `metadata` | `Struct` | |
| 7 | `extensions` | repeated string | Extension URIs |
| 8 | `reference_task_ids` | repeated string | |

`Part` is a single unified type. The `oneof` is discriminated by which member is
present, not by a `kind` field.

| # | Field | Type | Notes |
| --- | --- | --- | --- |
| 1 | `text` | string | oneof `content` |
| 2 | `raw` | bytes | oneof `content`. Base64 in JSON |
| 3 | `url` | string | oneof `content` |
| 4 | `data` | `Value` | oneof `content`. Any JSON value |
| 5 | `metadata` | `Struct` | |
| 6 | `filename` | string | |
| 7 | `media_type` | string | Available for all part types |

`Artifact`

| # | Field | Type |
| --- | --- | --- |
| 1 | `artifact_id` | string, required |
| 2 | `name` | string |
| 3 | `description` | string |
| 4 | `parts` | repeated `Part`, required |
| 5 | `metadata` | `Struct` |
| 6 | `extensions` | repeated string |

`StreamResponse` and `SendMessageResponse` are `oneof` wrappers.

| Wrapper | # | Member |
| --- | --- | --- |
| `SendMessageResponse` | 1 | `Task task` |
| `SendMessageResponse` | 2 | `Message message` |
| `StreamResponse` | 1 | `Task task` |
| `StreamResponse` | 2 | `Message message` |
| `StreamResponse` | 3 | `TaskStatusUpdateEvent status_update` |
| `StreamResponse` | 4 | `TaskArtifactUpdateEvent artifact_update` |

`TaskStatusUpdateEvent` has `task_id` 1, `context_id` 2, `status` 3, `metadata` 4.
The `final` boolean was removed in 1.0; stream closure is the terminal signal.

`TaskArtifactUpdateEvent` has `task_id` 1, `context_id` 2, `artifact` 3,
`append` 4, `last_chunk` 5, `metadata` 6.

`SendMessageConfiguration`

| # | Field | Type | Notes |
| --- | --- | --- | --- |
| 1 | `accepted_output_modes` | repeated string | |
| 2 | `task_push_notification_config` | `TaskPushNotificationConfig` | |
| 3 | `history_length` | optional int32 | |
| 4 | `return_immediately` | optional bool | **Default false, which means blocking.** This inverts the 0.3 `blocking` default, and the 0.3 default was non-blocking |

`ListTasksRequest` pagination: `page_size` is 1 to 100, default at most 50.
`ListTasksResponse.next_page_token` is always present and is the empty string on
the last page. `next_page_token` empty means no further pages; a client must not
infer that from an absent field, because the field is required and its absence is
a decode error.

### 5.5 Agent Card

| # | Field | Type | Required |
| --- | --- | --- | --- |
| 1 | `name` | string | yes |
| 2 | `description` | string | yes |
| 3 | `supported_interfaces` | repeated `AgentInterface` | yes, ordered, first is preferred |
| 4 | `provider` | `AgentProvider` | no |
| 5 | `version` | string | yes |
| 6 | `documentation_url` | optional string | no |
| 7 | `capabilities` | `AgentCapabilities` | yes |
| 8 | `security_schemes` | map string to `SecurityScheme` | no |
| 9 | `security_requirements` | repeated `SecurityRequirement` | no |
| 10 | `default_input_modes` | repeated string | yes |
| 11 | `default_output_modes` | repeated string | yes |
| 12 | `skills` | repeated `AgentSkill` | yes |
| 13 | `signatures` | repeated `AgentCardSignature` | no |
| 14 | `icon_url` | optional string | no |

Removed in 1.0 relative to 0.3: top-level `url`, `protocolVersion`,
`preferredTransport`, `additionalInterfaces`, `supportsAuthenticatedExtendedCard`.

`AgentInterface`

| # | Field | Type | Required |
| --- | --- | --- | --- |
| 1 | `url` | string | yes. Absolute HTTPS in production |
| 2 | `protocol_binding` | string | yes |
| 3 | `tenant` | string | no |
| 4 | `protocol_version` | string | yes. `Major.Minor` only |

`AgentCapabilities`: `streaming` 1, `push_notifications` 2, `extensions` 3,
`extended_agent_card` 4. All optional.

`AgentExtension`: `uri` 1, `description` 2, `required` 3, `params` 4.

`AgentCardSignature`: `protected` 1 (base64url JWS protected header, required),
`signature` 2 (base64url, required), `header` 3 (unprotected values, optional).

### 5.6 Errors

A2A-specific errors occupy `-32001` to `-32009` and are identified out of band by
a `google.rpc.ErrorInfo` detail carrying `domain: "a2a-protocol.org"` and a
`reason` derived from the error type name, because several distinct A2A errors
collapse onto the same gRPC and HTTP status.

| Code | Name | gRPC | gRPC number | HTTP |
| --- | --- | --- | --- | --- |
| `-32001` | `TaskNotFoundError` | `NOT_FOUND` | 5 | `404 Not Found` |
| `-32002` | `TaskNotCancelableError` | `FAILED_PRECONDITION` | 9 | `400 Bad Request` |
| `-32003` | `PushNotificationNotSupportedError` | `FAILED_PRECONDITION` | 9 | `400 Bad Request` |
| `-32004` | `UnsupportedOperationError` | `FAILED_PRECONDITION` | 9 | `400 Bad Request` |
| `-32005` | `ContentTypeNotSupportedError` | `INVALID_ARGUMENT` | 3 | `400 Bad Request` |
| `-32006` | `InvalidAgentResponseError` | `INTERNAL` | 13 | `500 Internal Server Error` |
| `-32007` | `ExtendedAgentCardNotConfiguredError` | `FAILED_PRECONDITION` | 9 | `400 Bad Request` |
| `-32008` | `ExtensionSupportRequiredError` | `FAILED_PRECONDITION` | 9 | `400 Bad Request` |
| `-32009` | `VersionNotSupportedError` | `FAILED_PRECONDITION` | 9 | `400 Bad Request` |

The specification's own range statement is verbatim: A2A-specific errors use codes in
the range `-32001` to `-32099`.

Six of the nine collapse onto `FAILED_PRECONDITION` and `400 Bad Request`, so the
HTTP status is not discriminating and the `google.rpc.ErrorInfo` detail is the only
way to tell them apart. A decoder keys on the `reason`, not the code alone, and a
`reason` it does not know becomes an explicit unmapped variant rather than a guess.

### 5.7 Security schemes

`SecurityScheme` is a `oneof` on `scheme`, mirroring the OpenAPI 3.2 Security
Scheme Object.

| # | Variant | Fields |
| --- | --- | --- |
| 1 | `api_key_security_scheme` | `description` 1, `location` 2 required, `name` 3 required |
| 2 | `http_auth_security_scheme` | `description` 1, `scheme` 2 required, `bearer_format` 3 |
| 3 | `oauth2_security_scheme` | `description` 1, `flows` 2 required, `oauth2_metadata_url` 3 |
| 4 | `open_id_connect_security_scheme` | `description` 1, `open_id_connect_url` 2 required |
| 5 | `mtls_security_scheme` | `description` 1 |

`APIKeySecurityScheme.location` is `query`, `header` or `cookie`.

`OAuthFlows` is a `oneof`. `authorization_code` 1, `client_credentials` 2,
`implicit` 3 (deprecated), `password` 4 (deprecated), `device_code` 5.
`AuthorizationCodeOAuthFlow` carries `pkce_required` at field 5.

`SecurityRequirement.schemes` is a map from scheme name to a `StringList`.

### 5.8 Extensions

Namespace prefixes, declared by the specification and currently empty in
practice:

| Kind | Prefix | Repository convention |
| --- | --- | --- |
| Extension | `https://a2a-protocol.org/extensions/` | `ext-{name}` official, `experimental-ext-{name}` incubating |
| Custom binding | `https://a2a-protocol.org/bindings/` | `cpb-{name}`, `experimental-cpb-{name}` |

Extension URIs should carry a version. A breaking change requires a new URI; an
agent must not silently fall back to another version. Activation is by the
`A2A-Extensions` service parameter, a comma-separated URI list, echoed in the
response. A missing activation for a `required` extension is
`ExtensionSupportRequiredError`, `-32008`.

At the research date the official namespace contained no extensions. The only two
repositories are experimental, created 2026-05-14.

## 6. Agent Client Protocol

### 6.1 Version negotiation

| Constant | Value |
| --- | --- |
| Stable wire version | `1` |
| Draft wire version | `2` |

The client sends the highest integer `protocolVersion` it supports. The agent
echoes it or returns its own highest. A client that cannot speak the returned
version SHOULD disconnect.

Artifact versions are decoupled from wire compatibility and MUST NOT be used to
infer it. At the research date the crate was `1.9.1`, the v1 schema artifact
`schema-v1.23.0` and the v2 draft `schema-v2.0.0-alpha.5`. Four different numbers,
one wire version. A library that conflated them would break on every artifact
release.

### 6.2 Transport

stdio is the only normative transport.

| Rule | Requirement |
| --- | --- |
| Encoding | UTF-8 |
| Framing | Newline-delimited, no embedded newlines in a message |
| stdout | The agent MUST NOT write non-ACP bytes to stdout |
| stderr | Free for logs |

Streamable HTTP over WebSocket or HTTP is in discussion. Not implemented.

v2 additionally permits JSON-RPC batch arrays.

### 6.3 Method registry, version 1

From `schema/v1/meta.json`, verbatim. `agentMethods` are called by the Client on
the Agent. `clientMethods` are called by the Agent on the Client.
`protocolMethods` are side-independent.

| v1 agentMethods | v1 clientMethods | protocolMethods |
| --- | --- | --- |
| `initialize` | `session/request_permission` | `$/cancel_request` |
| `authenticate` | `session/update` | |
| `session/new` | `fs/write_text_file` | |
| `session/load` | `fs/read_text_file` | |
| `session/set_mode` | `terminal/create` | |
| `session/set_config_option` | `terminal/output` | |
| `session/prompt` | `terminal/release` | |
| `session/cancel` | `terminal/wait_for_exit` | |
| `session/list` | `terminal/kill` | |
| `session/delete` | `elicitation/create` | |
| `session/resume` | `elicitation/complete` | |
| `session/close` | | |
| `logout` | | |

`session/cancel` and `session/update` are notifications. `$/cancel_request`
cancels any outstanding request by id from either side, and was stabilized
2026-06-29.

### 6.4 Method registry, version 2 draft

From `schema/v2/meta.json`, verbatim.

| v2 agentMethods | v2 clientMethods | protocolMethods |
| --- | --- | --- |
| `initialize` | `session/request_permission` | `$/cancel_request` |
| `auth/login` | `session/update` | |
| `session/new` | `elicitation/create` | |
| `session/set_config_option` | `elicitation/complete` | |
| `session/prompt` | | |
| `session/cancel` | | |
| `session/list` | | |
| `session/delete` | | |
| `session/resume` | | |
| `session/close` | | |
| `auth/logout` | | |

The v1 to v2 delta is structural, not additive:

| v1 | v2 |
| --- | --- |
| `authenticate`, `logout` | `auth/login`, `auth/logout`, gated purely on a non-empty `authMethods` |
| `clientCapabilities` | `capabilities` |
| `clientInfo`, `agentInfo` | `info`, required in both directions |
| `session/load` | `session/resume` with `replayFrom` |
| `session/set_mode`, all `SessionMode*`, `current_mode_update` | session config options with `category: "mode"` |
| all `fs/*` and `terminal/*` | removed. Agents own their own execution |
| boolean capabilities | presence-bearing `{}` objects |
| closed `oneOf` | `anyOf` plus an `other` catch-all carrying a free `type` string |

`session/request_permission` remains the only baseline Client method. The
required v2 agent method set is `session/new`, `session/list`, `session/resume`,
`session/close`, `session/prompt`, `session/cancel`, `session/update`, and it is
required whenever `capabilities.session` is present.

The Rust schema provides no cross-version conversion. An adapter must reject, not
silently drop, advertised v1 `fs` or `terminal` support when speaking v2, and the
v1 and v2 terminal models are ownership- and lifetime-incompatible.

### 6.5 Capabilities

Version 1. Omission means unsupported. This is the non-breaking extension
mechanism, and it is why an unknown capability is not a decode error.

| Client capability | Gates |
| --- | --- |
| `fs.readTextFile` | `fs/read_text_file` |
| `fs.writeTextFile` | `fs/write_text_file` |
| `terminal` | all five `terminal/*` methods |
| `auth.terminal` | terminal-mode authentication. Distinct from `terminal` |
| `elicitation.form` | form-mode elicitation |
| `elicitation.url` | URL-mode elicitation |
| `session.configOptions.boolean` | boolean session config options |

| Agent capability | Gates |
| --- | --- |
| `loadSession` | `session/load`, `session/resume` |
| `promptCapabilities.image` | image content parts |
| `promptCapabilities.audio` | audio content parts |
| `promptCapabilities.embeddedContext` | embedded context |
| `mcpCapabilities.http` | MCP over Streamable HTTP |
| `mcpCapabilities.sse` | MCP over HTTP+SSE. Annotated deprecated by the MCP specification |
| `auth.logout` | `logout` |
| `session.delete` | `session/delete` |
| `session.additionalDirectories` | additional workspace roots |

### 6.6 Permission options

`session/request_permission` is a request from the Agent to the Client.

| Field | Type | Notes |
| --- | --- | --- |
| `sessionId` | string | |
| `toolCall` | `ToolCallUpdate` | |
| `options` | array | Each `{optionId, name, kind}` |

`kind` values, verbatim: `allow_once`, `allow_always`, `reject_once`,
`reject_always`.

The response is `{outcome: {outcome: "selected", optionId}}` or
`{outcome: {outcome: "cancelled"}}`. A client MAY auto-decide by policy.

Version 2 adds a required `title`, an optional `description`, and an optional
extensible `subject`: a tagged union of `type: "tool_call"` and
`type: "command"`, the latter carrying a required `command` and an **absolute**
`cwd`. An omitted subject means approval with no structured content.

The v2 safety rule is normative and is the sharpest clause in the protocol: an
agent that receives an outcome it does not understand MUST NOT treat it as
approval. The decoder therefore surfaces an unrecognised outcome as an explicit
variant, never as a default.

### 6.7 Elicitation

`elicitation/create` with `mode` of `form` or `url`. Form mode uses a restricted
flat JSON Schema and MUST NOT request credentials. URL mode carries an
`elicitationId` and is completed by the `elicitation/complete` notification.

Response actions: `accept`, `decline`, `cancel`.

ACP's elicitation deliberately diverges from MCP: each supported mode must be
advertised explicitly, where an empty MCP capability retains the form-only
meaning. An adapter translating between them must not pass an empty ACP
capability set through as an MCP form-only capability without saying so.

## 7. Cross-protocol composition

The only defined composition between these three protocols is the
`mcp-over-acp` RFD, which carries stateless MCP `2026-07-28` requests over an
existing ACP connection. It is a draft, and it is cheap to represent once both
protocols exist.

One method, `mcp/message`, in two directions. An Agent-to-provider request invokes
one MCP operation; a provider-to-agent notification carries an MCP notification
belonging to that operation.

| Field | Notes |
| --- | --- |
| `serverId` | Names a server declared by its provider. Not an MCP session. Must not be rebound |
| `requestId` | Caller-generated, opaque, one per logical MCP request. Preserved across ACP proxies |
| outer `id` | The ACP request id on one hop. A proxy may renumber it |

A successful outer ACP response carries exactly one inner MCP outcome, in the
`result` member as either `result` or `error`. An inner MCP error is a successful
outer response. Inner and outer error-code spaces are disjoint in meaning: an
inner `-32000` must never trigger ACP authentication.

Binding-level failures are outer ACP errors: `-32602` malformed envelope or
duplicate active `(serverId, requestId)`, `-32800` operation cancelled, `-33000`
resource limit exceeded, `-33001` server registration unavailable, `-33002`
backend or transport failed without a valid MCP outcome.

The binding supports MCP `2026-07-28` only. It does not emulate earlier revisions
and performs no MCP handshake.

## 8. Version pins

| Protocol | Pinned | Accepts | Notes |
| --- | --- | --- | --- |
| MCP | `2026-07-28` | `2025-11-25` | Two separately decoded revisions, not one revision with a flag. The installed client base is overwhelmingly on the older one, and the older one has features the newer one removed |
| A2A | `1.0.0` | `0.3` on four method aliases only | Everything else at `0.3` is `-32601`. An empty `A2A-Version` means `0.3` |
| ACP | `1` | `2` behind an explicit gate | v2 is a draft. Maintainer guidance is to gate on version negotiation and feature flags, and to keep v1 working |

`agentgateway` fixes MCP ports 8000, A2A 9000 and AG-UI 8080. Those are a
deployment product's choice, not a protocol constant, and this library does not
encode them.

## 9. Not implemented

| Excluded | Reason |
| --- | --- |
| Gateway and proxy layer | No specification exists. Two foundation projects compete for the same role with no interop story |
| Sandbox layer | No protocol. An API layer is converging but is not stable |
| Orchestration | No protocol. Arazzo's MCP and A2A step support is roadmap only |
| MCP Apps `ui/*` surface | Specified and stable, but the client support matrix is a community-maintained list. Deferred until a host is chosen |
| A2UI | `v1.0` is a Candidate, last updated 2026-06-08, with the production release older still. Deferred |
| WebMCP, NLWeb | Not shipping. WebMCP is a Community Group draft behind a browser origin trial |
| AG-UI | Declined for the same reason as A2UI: a vendor-governed 1.0 with no foundation home. Revisit if it is donated |
| Commerce, payments, identity | Not integration protocols for this library's consumers. See [`research/sota-2026-09-29.md`](research/sota-2026-09-29.md) |
| ANP, AGNTCY | Upstream adoption does not justify a wire implementation |
| MCP sampling and roots | Deprecated, earliest removal 2027-07-28 |

## 10. Sources

Every value in this document traces to one of these. Full per-claim sourcing is
in the corresponding document under [`research/`](research/README.md).

- MCP normative schema: `modelcontextprotocol/specification` at
  `schema/2026-07-28/schema.ts`, cross-checked against the generated
  `schema.json`; specification pages under
  `modelcontextprotocol.io/specification/2026-07-28/`; extension specifications in
  `modelcontextprotocol/ext-apps` and `modelcontextprotocol/ext-tasks`. See
  [`research/mcp.md`](research/mcp.md).
- A2A normative proto: `a2aproject/A2A` at `specification/a2a.proto`, tag `v1.0.0`,
  plus the rendered specification at `a2a-protocol.org/latest/specification/`.
  See [`research/a2a.md`](research/a2a.md).
- ACP normative schemas: `agentclientprotocol/agent-client-protocol` at
  `schema/v1/meta.json` and `schema/v2/meta.json`, plus the normative prose at
  `agentclientprotocol.com/protocol/v1/` and `/protocol/v2/`. See
  [`research/acp-agent-client.md`](research/acp-agent-client.md).
- MCP over ACP: the `mcp-over-acp` RFD at `agentclientprotocol.com/rfds/mcp-over-acp`.
- Normative extractions, one per protocol, are the value-level source of record:
  [`research/normative/mcp-2026-07-28.md`](research/normative/mcp-2026-07-28.md),
  [`research/normative/a2a-1.0.0.md`](research/normative/a2a-1.0.0.md),
  [`research/normative/acp-v1-v2.md`](research/normative/acp-v1-v2.md),
  [`research/normative/ui-protocols.md`](research/normative/ui-protocols.md),
  [`research/normative/commerce.md`](research/normative/commerce.md),
  [`research/normative/instructions-observability.md`](research/normative/instructions-observability.md).
