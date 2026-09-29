# Agent Client Protocol — normative wire values, v1 and v2 draft

This document transcribes the wire vocabulary of the Agent Client Protocol (ACP) at two
revisions: v1, which is stable, and v2, which is a draft. Every value below was read out of
the protocol's own machine-readable artifacts — the released JSON Schemas
`schema/v1/schema.json` and `schema/v2/schema.json`, the authoritative method registries
`schema/v1/meta.json` and `schema/v2/meta.json` — and cross-checked against the normative
prose at `agentclientprotocol.com`. Nothing here is paraphrased into a count: every
enumeration, every method string, every tagged-union value and every `required` list is
written out row by row, because the earlier pass that fed [`PROTOCOLS.md`](../../PROTOCOLS.md)
kept the method registries and the capability gating but dropped the variant strings, and a
decoder built from a method table alone still cannot parse a single `session/update`.

- Research date: 2026-09-29
- Contract: [`../../PROTOCOLS.md`](../../PROTOCOLS.md) — the normative wire values
- Evidence: this file, transcribed from the artifacts named per table

## Artifact provenance

| Artifact | URL | What it established here |
| --- | --- | --- |
| `schema/v1/meta.json` | `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/v1/meta.json` | Authoritative v1 method registry: `version`, and the full `agentMethods` / `clientMethods` / `protocolMethods` string maps. Source for the v1 method tables and the v1 schema artifact version |
| `schema/v1/schema.json` | `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/v1/schema.json` (5861 lines) | All v1 types, the `x-method` and `x-side` markers on every request/response struct, field defaults, `required` lists, and the closed `oneOf` discriminator enums |
| `schema/v2/meta.json` | `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/v2/meta.json` | Authoritative v2 draft method registry: `version`, and the reduced method surface (no `fs/*`, no `terminal/*`, no `session/load`, no `session/set_mode`) |
| `schema/v2/schema.json` | `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/v2/schema.json` (7031 lines) | All v2 types, the 16 named `sessionUpdate` variants plus `other`, `RequestPermissionSubject`, the `anyOf` catch-all pattern, and `AbsolutePath` |
| `Cargo.toml` (workspace) | `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/Cargo.toml` | Crate layout (`agent-client-protocol-schema`, `schema/v1`, `schema/v2`, `schema-generator`) and the `agent-client-protocol-schema` workspace version |
| docs.rs crate index | `https://docs.rs/crate/agent-client-protocol-schema/latest` | Latest crate release, the release list, the normative statement that `protocolVersion` determines wire shape, and that the stable ACP protocol version is `1` |
| v1 overview | `https://agentclientprotocol.com/protocol/v1/overview.md` | v1 baseline / optional method classification |
| v1 initialization | `https://agentclientprotocol.com/protocol/v1/initialization.md` | v1 capabilities and the version-negotiation algorithm |
| v1 transports | `https://agentclientprotocol.com/protocol/v1/transports.md` | v1 framing rules and the Streamable HTTP draft status |
| v2 overview | `https://agentclientprotocol.com/protocol/v2/overview.md` | v2 draft baseline set, batch support, the conditional `auth/login` + `auth/logout` rule, and the `capabilities` / `info` renames |
| v2 initialization | `https://agentclientprotocol.com/protocol/v2/initialization.md` | v2 draft capabilities and negotiation, including the `protocolVersion: 2` example payload |
| v2 transports | `https://agentclientprotocol.com/protocol/v2/transports.md` | v2 draft transport rules and the normative JSON-RPC batch handling list |
| mcp-over-acp RFD (nikomatsakis) | `https://agentclientprotocol.com/rfds/mcp-over-acp.md` | `mcp/message`, its request/notification envelope, the outcome carrier, the five binding failure codes, and the proposed `acp` capability. **Not present in either published schema** |

**Side convention.** In the published schemas every request/response struct carries sibling
keys `x-side` and `x-method`. `x-side: "agent"` marks a method **on the Agent**, called by
the Client. `x-side: "client"` marks a method **on the Client**, called by the Agent.
`x-side: "protocol"` marks a side-independent message. `schema/vN/meta.json` is the
authoritative name registry and is preferred here over the prose.

**Legend.** `R` = listed in the type's `required` array. `opt` = optional, absent from
`required`. `{}`-cap = a capability that is an object whose presence, even as `{}`, enables
the feature. `bool-cap` = a capability that is a JSON boolean. `NOT ESTABLISHED IN SOURCE` =
absent from all primary sources consulted for this document.

## 1. Every JSON-RPC method string

`Source:` `schema/v1/meta.json` (`agentMethods`, `clientMethods`, `protocolMethods`) and
`schema/v2/meta.json`, with params and result types from `$defs.<Type>` in
`schema/v1/schema.json` and `schema/v2/schema.json`; baseline/optional classification from
`/protocol/v1/overview.md` and `/protocol/v2/overview.md`.

### 1a. Agent-side surface (`x-side: "agent"`) — Client calls Agent

| Method string | v1 | v2 draft | Params | Result | Classification |
| --- | --- | --- | --- | --- | --- |
| `initialize` | yes | yes | `InitializeRequest` | `InitializeResponse` | **baseline** (both) |
| `authenticate` | yes | **no** | `AuthenticateRequest` | `AuthenticateResponse` | **baseline** (v1) |
| `auth/login` | no | yes | `LoginAuthRequest` | `LoginAuthResponse` | **conditional baseline** (v2): agent MUST implement iff `authMethods` is non-empty |
| `logout` | yes | **no** | `LogoutRequest` | `LogoutResponse` | **optional** (v1), gated by `agentCapabilities.auth.logout` = `{}` |
| `auth/logout` | no | yes | `LogoutAuthRequest` | `LogoutAuthResponse` | **conditional baseline** (v2), same `authMethods` rule |
| `session/new` | yes | yes | `NewSessionRequest` | `NewSessionResponse` | **baseline** (both) |
| `session/load` | yes | **no** | `LoadSessionRequest` | `LoadSessionResponse` | **optional** (v1), gated by `agentCapabilities.loadSession` = `true` |
| `session/list` | yes | yes | `ListSessionsRequest` | `ListSessionsResponse` | v1: **optional**, gated by `sessionCapabilities.list` = `{}`. v2: **baseline** under `capabilities.session` |
| `session/delete` | yes | yes | `DeleteSessionRequest` | `DeleteSessionResponse` | **optional** both, gated by `sessionCapabilities.delete` / `capabilities.session.delete` = `{}` |
| `session/resume` | yes | yes | `ResumeSessionRequest` | `ResumeSessionResponse` | v1: **optional**, gated by `sessionCapabilities.resume` = `{}`. v2: **baseline** |
| `session/close` | yes | yes | `CloseSessionRequest` | `CloseSessionResponse` | v1: **optional**, gated by `sessionCapabilities.close` = `{}`. v2: **baseline** |
| `session/set_mode` | yes | **no** | `SetSessionModeRequest` | `SetSessionModeResponse` | **optional** (v1), ungated; listed under "Optional Methods" |
| `session/set_config_option` | yes | yes | `SetSessionConfigOptionRequest` | `SetSessionConfigOptionResponse` | present in both `meta.json`; classification **NOT ESTABLISHED IN SOURCE** — absent from both `overview.md` baseline and optional lists |
| `session/prompt` | yes | yes | `PromptRequest` | `PromptResponse` | **baseline** (both) |
| `session/cancel` (notification) | yes | yes | `CancelNotification` (v1) / `CancelSessionNotification` (v2) | — | **baseline** notification (both) |
| `_`-prefixed extension | yes | yes | `ExtRequest` | `ExtResponse` | optional; `ExtRequest` and `ExtResponse` have **no `type`, no `properties` and no `x-method`** in either schema — opaque |

`schema/v1/meta.json` `agentMethods`, verbatim: `initialize`, `authenticate`,
`session_new` = `session/new`, `session_load` = `session/load`,
`session_set_mode` = `session/set_mode`,
`session_set_config_option` = `session/set_config_option`,
`session_prompt` = `session/prompt`, `session_cancel` = `session/cancel`,
`session_list` = `session/list`, `session_delete` = `session/delete`,
`session_resume` = `session/resume`, `session_close` = `session/close`, `logout`.
Thirteen entries.

`schema/v2/meta.json` `agentMethods`, verbatim: `initialize`, `auth_login` = `auth/login`,
`session_new` = `session/new`,
`session_set_config_option` = `session/set_config_option`,
`session_prompt` = `session/prompt`, `session_cancel` = `session/cancel`,
`session_list` = `session/list`, `session_delete` = `session/delete`,
`session_resume` = `session/resume`, `session_close` = `session/close`,
`auth_logout` = `auth/logout`. Eleven entries.

### 1b. Client-side surface (`x-side: "client"`) — Agent calls Client

| Method string | v1 | v2 draft | Params | Result | Classification |
| --- | --- | --- | --- | --- | --- |
| `session/request_permission` | yes | yes | `RequestPermissionRequest` | `RequestPermissionResponse` | **baseline** (both) |
| `fs/read_text_file` | yes | **removed** | `ReadTextFileRequest` | `ReadTextFileResponse` | **optional** (v1), gated by `fs.readTextFile` = `true` |
| `fs/write_text_file` | yes | **removed** | `WriteTextFileRequest` | `WriteTextFileResponse` | **optional** (v1), gated by `fs.writeTextFile` = `true` |
| `terminal/create` | yes | **removed** | `CreateTerminalRequest` | `CreateTerminalResponse` | **optional** (v1), gated by `terminal` = `true` |
| `terminal/output` | yes | **removed** | `TerminalOutputRequest` | `TerminalOutputResponse` | **optional** (v1), gated by `terminal` = `true` |
| `terminal/release` | yes | **removed** | `ReleaseTerminalRequest` | `ReleaseTerminalResponse` | **optional** (v1), gated by `terminal` = `true` |
| `terminal/wait_for_exit` | yes | **removed** | `WaitForTerminalExitRequest` | `WaitForTerminalExitResponse` | **optional** (v1), gated by `terminal` = `true` |
| `terminal/kill` | yes | **removed** | `KillTerminalRequest` | `KillTerminalResponse` | **optional** (v1), gated by `terminal` = `true` |
| `elicitation/create` | yes | yes | `CreateElicitationRequest` | `CreateElicitationResponse` | **optional** both, gated per mode by `elicitation.form` / `elicitation.url` = `{}` |
| `session/update` (notification) | yes | yes | `SessionNotification` (v1) / `UpdateSessionNotification` (v2) | — | **baseline** notification (both) |
| `elicitation/complete` (notification) | yes | yes | `CompleteElicitationNotification` | — | **optional** notification (both) |
| `_`-prefixed extension (notification) | yes | yes | `ExtNotification` | — | optional; opaque in the schema |

`schema/v1/meta.json` `clientMethods`, verbatim: `session_request_permission`,
`session_update`, `fs_write_text_file`, `fs_read_text_file`, `terminal_create`,
`terminal_output`, `terminal_release`, `terminal_wait_for_exit`, `terminal_kill`,
`elicitation_create`, `elicitation_complete`. Eleven entries.

`schema/v2/meta.json` `clientMethods`, verbatim: `session_request_permission`,
`session_update`, `elicitation_create`, `elicitation_complete`. Four entries.

### 1c. Protocol-level

`Source:` `schema/v1/meta.json` `protocolMethods`, identical in `schema/v2/meta.json`.

| Method string | v1 | v2 draft | Params | Classification |
| --- | --- | --- | --- | --- |
| `$/cancel_request` | yes | yes | `CancelRequestNotification` | notification, `x-side: "protocol"`. `required: ["requestId"]` |

`RequestId`, identical in both versions: `anyOf` of `null` (`"title": "Null"`),
`{"type": "integer", "format": "int64"}`, `{"type": "string"}`.

## 2. `initialize` — request, response, and both capability trees

`Source:` `schema/v1/schema.json` `$defs.InitializeRequest`, `$defs.InitializeResponse`,
`$defs.ClientCapabilities`, `$defs.AgentCapabilities` and their nested capability structs;
`schema/v2/schema.json` same paths.

### 2a. v1 `InitializeRequest` — `required: ["protocolVersion"]`

| JSON name | Type | Req | Default | Notes |
| --- | --- | --- | --- | --- |
| `protocolVersion` | `ProtocolVersion` | **R** | — | `$ref #/$defs/ProtocolVersion` |
| `clientCapabilities` | `ClientCapabilities` | opt | `{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false,"auth":{"terminal":false}}` | carries `x-deserialize-default-on-error: true` |
| `clientInfo` | `Implementation` \| `null` | opt | — | |
| `_meta` | `["object","null"]`, `additionalProperties: true` | opt | — | |

### 2b. v1 `InitializeResponse` — `required: ["protocolVersion"]`

| JSON name | Type | Req | Default | Notes |
| --- | --- | --- | --- | --- |
| `protocolVersion` | `ProtocolVersion` | **R** | — | |
| `agentCapabilities` | `AgentCapabilities` | opt | `{"loadSession":false,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false},"mcpCapabilities":{"http":false,"sse":false},"sessionCapabilities":{},"auth":{}}` | |
| `authMethods` | `array` of `AuthMethod` | opt | `[]` | carries `x-deserialize-skip-invalid-items: true` |
| `agentInfo` | `Implementation` \| `null` | opt | — | schema note: "in future versions of the protocol, this will be required" |
| `_meta` | `["object","null"]` | opt | — | |

### 2c. v1 `ClientCapabilities`

| Field | Type | Req | Default |
| --- | --- | --- | --- |
| `fs` | `FileSystemCapabilities` | opt | `{"readTextFile":false,"writeTextFile":false}` |
| `terminal` | `boolean` | opt | `false` |
| `session` | `ClientSessionCapabilities` \| `null` | opt | — |
| `auth` | `AuthCapabilities` | opt | `{"terminal":false}` |
| `elicitation` | `ElicitationCapabilities` \| `null` | opt | — |
| `_meta` | object \| null | opt | — |

Nested v1 client capability structs:

| Struct | Field | Type | Req | Default |
| --- | --- | --- | --- | --- |
| `FileSystemCapabilities` | `readTextFile` | `boolean` | opt | `false` |
| `FileSystemCapabilities` | `writeTextFile` | `boolean` | opt | `false` |
| `FileSystemCapabilities` | `_meta` | object \| null | opt | — |
| `ClientSessionCapabilities` | `configOptions` | `SessionConfigOptionsCapabilities` \| `null` | opt | — |
| `ClientSessionCapabilities` | `_meta` | object \| null | opt | — |
| `SessionConfigOptionsCapabilities` | `boolean` | `BooleanConfigOptionCapabilities` \| `null` | opt | — |
| `SessionConfigOptionsCapabilities` | `_meta` | object \| null | opt | — |
| `BooleanConfigOptionCapabilities` | `_meta` | object \| null | opt | — (empty marker object, no other fields) |
| `AuthCapabilities` | `terminal` | `boolean` | opt | `false` |
| `AuthCapabilities` | `_meta` | object \| null | opt | — |
| `ElicitationCapabilities` | `form` | `ElicitationFormCapabilities` \| `null` | opt | — |
| `ElicitationCapabilities` | `url` | `ElicitationUrlCapabilities` \| `null` | opt | — |
| `ElicitationCapabilities` | `_meta` | object \| null | opt | — |
| `ElicitationFormCapabilities` | `_meta` | object \| null | opt | — (empty marker object) |
| `ElicitationUrlCapabilities` | `_meta` | object \| null | opt | — (empty marker object) |

### 2d. v1 `AgentCapabilities`

| Field | Type | Req | Default |
| --- | --- | --- | --- |
| `loadSession` | `boolean` | opt | `false` |
| `promptCapabilities` | `PromptCapabilities` | opt | `{"image":false,"audio":false,"embeddedContext":false}` |
| `mcpCapabilities` | `McpCapabilities` | opt | `{"http":false,"sse":false}` |
| `sessionCapabilities` | `SessionCapabilities` | opt | `{}` |
| `auth` | `AgentAuthCapabilities` | opt | `{}` |
| `_meta` | object \| null | opt | — |

Nested v1 agent capability structs:

| Struct | Field | Type | Req | Default |
| --- | --- | --- | --- | --- |
| `PromptCapabilities` | `image` | `boolean` | opt | `false` |
| `PromptCapabilities` | `audio` | `boolean` | opt | `false` |
| `PromptCapabilities` | `embeddedContext` | `boolean` | opt | `false` |
| `PromptCapabilities` | `_meta` | object \| null | opt | — |
| `McpCapabilities` | `http` | `boolean` | opt | `false` |
| `McpCapabilities` | `sse` | `boolean` | opt | `false` |
| `McpCapabilities` | `_meta` | object \| null | opt | — |
| `SessionCapabilities` | `list` | `SessionListCapabilities` \| `null` | opt | — |
| `SessionCapabilities` | `delete` | `SessionDeleteCapabilities` \| `null` | opt | — |
| `SessionCapabilities` | `additionalDirectories` | `SessionAdditionalDirectoriesCapabilities` \| `null` | opt | — |
| `SessionCapabilities` | `resume` | `SessionResumeCapabilities` \| `null` | opt | — |
| `SessionCapabilities` | `close` | `SessionCloseCapabilities` \| `null` | opt | — |
| `SessionCapabilities` | `_meta` | object \| null | opt | — |
| `AgentAuthCapabilities` | `logout` | `LogoutCapabilities` \| `null` | opt | — |
| `AgentAuthCapabilities` | `_meta` | object \| null | opt | — |

`SessionCapabilities` in v1 carries no `required` key; every member is optional.

### 2e. v2 draft `InitializeRequest` — `required: ["protocolVersion", "info"]`

| JSON name | Type | Req | Default |
| --- | --- | --- | --- |
| `protocolVersion` | `ProtocolVersion` | **R** | — |
| `info` | `Implementation` | **R** | — |
| `capabilities` | `ClientCapabilities` | opt | `{}` |
| `_meta` | `["object","null"]` | opt | — |

### 2f. v2 draft `InitializeResponse` — `required: ["protocolVersion", "info"]`

| JSON name | Type | Req | Default |
| --- | --- | --- | --- |
| `protocolVersion` | `ProtocolVersion` | **R** | — |
| `info` | `Implementation` | **R** | — |
| `capabilities` | `AgentCapabilities` | opt | `{}` |
| `authMethods` | `array` of `AuthMethod` | opt | — (no `default` key in the schema) |
| `_meta` | `["object","null"]` | opt | — |

### 2g. v2 draft `ClientCapabilities`

| Field | Type | Req |
| --- | --- | --- |
| `auth` | `AuthCapabilities` \| `null` | opt |
| `elicitation` | `ElicitationCapabilities` \| `null` | opt |
| `_meta` | object \| null | opt |

`fs` and `terminal` are **absent** in v2.

| Struct | Field | Type | Req |
| --- | --- | --- | --- |
| `AuthCapabilities` | `terminal` | `TerminalAuthCapabilities` \| `null` | opt |
| `AuthCapabilities` | `_meta` | object \| null | opt |
| `ElicitationCapabilities` | `form` | `ElicitationFormCapabilities` \| `null` | opt |
| `ElicitationCapabilities` | `url` | `ElicitationUrlCapabilities` \| `null` | opt |
| `ElicitationCapabilities` | `_meta` | object \| null | opt |

In v2, `AuthCapabilities.terminal` is an **object marker, not a boolean**. The v2
`ElicitationCapabilities` struct is structurally identical to v1.

### 2h. v2 draft `AgentCapabilities`

| Field | Type | Req |
| --- | --- | --- |
| `session` | `SessionCapabilities` \| `null` | opt |
| `auth` | `AgentAuthCapabilities` \| `null` | opt |
| `_meta` | object \| null | opt |

| Struct | Field | Type | Req |
| --- | --- | --- | --- |
| `SessionCapabilities` | `prompt` | `PromptCapabilities` \| `null` | opt |
| `SessionCapabilities` | `mcp` | `McpCapabilities` \| `null` | opt |
| `SessionCapabilities` | `delete` | `SessionDeleteCapabilities` \| `null` | opt |
| `SessionCapabilities` | `additionalDirectories` | `SessionAdditionalDirectoriesCapabilities` \| `null` | opt |
| `SessionCapabilities` | `_meta` | object \| null | opt |
| `PromptCapabilities` | `image` | `PromptImageCapabilities` \| `null` | opt |
| `PromptCapabilities` | `audio` | `PromptAudioCapabilities` \| `null` | opt |
| `PromptCapabilities` | `embeddedContext` | `PromptEmbeddedContextCapabilities` \| `null` | opt |
| `PromptCapabilities` | `_meta` | object \| null | opt |
| `McpCapabilities` | `stdio` | `McpStdioCapabilities` \| `null` | opt |
| `McpCapabilities` | `http` | `McpHttpCapabilities` \| `null` | opt |
| `McpCapabilities` | `_meta` | object \| null | opt |
| `AgentAuthCapabilities` | `_meta` | object \| null | opt |

`SessionCapabilities.list`, `.resume` and `.close` are **gone** in v2; those methods became
baseline. `McpCapabilities.sse` is **removed** and `stdio` is **added**; all three v2
capabilities are objects, not booleans. `AgentAuthCapabilities.logout` is **removed**: v2
advertises `auth/logout` through a non-empty `authMethods`, not through a capability.

### 2i. `Implementation` — identical in both versions

| Field | Type | Req |
| --- | --- | --- |
| `name` | `string` | **R** |
| `title` | `["string","null"]` | opt |
| `version` | `string` | **R** |
| `_meta` | `["object","null"]` | opt |

`required: ["name","version"]`. v2 doc: "Both Clients and Agents **MUST** provide
information about their implementation in the `info` field." v1 doc: "Clients and Agents
**SHOULD** provide information about their implementation in the `clientInfo` and
`agentInfo` fields."

## 3. Session methods — params and result field lists

`Source:` `schema/v1/schema.json` and `schema/v2/schema.json`, `$defs` for every
`…Request` / `…Response` type named in the method column. Unless stated otherwise every type
in this section also carries an optional `_meta` of type `["object","null"]` with
`additionalProperties: true`.

### 3a. `session/new`

| Version | Request `required` | Request fields | Response `required` | Response fields |
| --- | --- | --- | --- | --- |
| v1 | `["cwd","mcpServers"]` | `cwd` `string` **R**; `additionalDirectories` `["string"]` opt; `mcpServers` `McpServer[]` **R**; `_meta` | `["sessionId"]` | `sessionId` `SessionId` **R**; `modes` `SessionModeState` \| `null` opt; `configOptions` `SessionConfigOption[]` \| `null` opt |
| v2 | `["cwd"]` | `cwd` `AbsolutePath` **R**; `additionalDirectories` `AbsolutePath[]` opt; `mcpServers` `McpServer[]` opt; `_meta` | `["sessionId"]` | `sessionId` **R**; `configOptions` `SessionConfigOption[]` opt — **`modes` removed** |

### 3b. `session/load` — v1 only

| Aspect | Value |
| --- | --- |
| Request `required` | `["mcpServers","cwd","sessionId"]` |
| Request fields | `mcpServers` `McpServer[]` **R**; `cwd` `string` **R**; `additionalDirectories` `["string"]` opt; `sessionId` `SessionId` **R**; `_meta` opt |
| Response `required` | *(none)* |
| Response fields | `modes` `SessionModeState` \| `null` opt; `configOptions` `SessionConfigOption[]` \| `null` opt |

### 3c. `session/resume`

| Version | Request `required` | Request fields | Response `required` | Response fields |
| --- | --- | --- | --- | --- |
| v1 | `["sessionId","cwd"]` | `sessionId` **R**; `cwd` `string` **R**; `additionalDirectories` `["string"]` opt; `mcpServers` `McpServer[]` opt | *(none)* | `modes` opt; `configOptions` opt |
| v2 | `["sessionId","cwd"]` | `sessionId` **R**; `cwd` `AbsolutePath` **R**; `additionalDirectories` `AbsolutePath[]` opt; `mcpServers` `McpServer[]` opt; **`replayFrom` `ReplayFrom` \| `null` opt** | *(none)* | `configOptions` `SessionConfigOption[]` opt — **`modes` removed** |

`ReplayFrom`, new in v2: `anyOf` of `{"type":"start"}` → `ReplayFromStart` (which carries
only `_meta`), or `other` — any string `type` other than `"start"`, `required: ["type"]`,
`additionalProperties: true`, optional `_meta`.

### 3d. `session/close`

| Version | Request `required` | Request fields | Response `required` | Response fields |
| --- | --- | --- | --- | --- |
| v1 | `["sessionId"]` | `sessionId` **R** | *(none)* | `_meta` only |
| v2 | `["sessionId"]` | `sessionId` **R** | *(none)* | `_meta` only |

### 3e. `session/prompt`

| Version | Request `required` | Request fields | Response `required` | Response fields |
| --- | --- | --- | --- | --- |
| v1 | `["sessionId","prompt"]` | `sessionId` **R**; `prompt` `ContentBlock[]` **R** | `["stopReason"]` | `stopReason` `StopReason` **R** |
| v2 | `["sessionId","prompt"]` | `sessionId` **R**; `prompt` `ContentBlock[]` **R** | `["messageId"]` | `messageId` `MessageId` **R** — **`stopReason` removed** |

| Enum | Version | Values |
| --- | --- | --- |
| `StopReason` | v1, closed `oneOf` | `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled` |
| `StopReason` | v2, `anyOf` plus catch-all | `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`, plus `other` (free string) |

### 3f. `session/cancel` (notification) — both versions

`required: ["sessionId"]`; fields: `sessionId` `SessionId` **R**; `_meta` opt. The type is
`CancelNotification` in v1 and `CancelSessionNotification` in v2.

### 3g. `session/list`

| Version | Request `required` | Request fields | Response `required` | Response fields |
| --- | --- | --- | --- | --- |
| v1 | *(none)* | `cwd` `["string","null"]` opt; `cursor` `["string","null"]` opt; `_meta` | `["sessions"]` | `sessions` `SessionInfo[]` **R**; `nextCursor` `["string","null"]` opt |
| v2 | *(none)* | `cwd` `AbsolutePath` \| `null` opt; `cursor` `SessionListCursor` \| `null` opt; `_meta` | `["sessions"]` | `sessions` `SessionInfo[]` **R**; `nextCursor` opt |

`SessionInfo`, v1, `required: ["sessionId","cwd"]`: `sessionId`; `cwd` `string`;
`additionalDirectories` `["string"]` opt; `title` `["string","null"]` opt; `updatedAt`
`["string","null"]` opt (documented as ISO 8601, no `format` key); `_meta`.

`SessionInfo`, v2, `required: ["sessionId","cwd"]`: same field names; `cwd` and
`additionalDirectories` use `AbsolutePath`; `updatedAt` is
`{"type":["string","null"], "format":"date-time"}` (documented as RFC 3339).

### 3h. `session/delete` — both versions

| Type | `required` | Fields |
| --- | --- | --- |
| Request | `["sessionId"]` | `sessionId` **R**; `_meta` opt |
| Response | *(none)* | `_meta` only |

### 3i. `session/set_mode` — v1 only

| Type | `required` | Fields |
| --- | --- | --- |
| Request | `["sessionId","modeId"]` | `sessionId` `SessionId` **R**; `modeId` `SessionModeId` **R** |
| Response | *(none)* | `_meta` only |

### 3j. `session/set_config_option` — both versions

| Version | Request `required` | Base fields | Value union | Response `required` | Response fields |
| --- | --- | --- | --- | --- | --- |
| v1 | `["sessionId","configId"]` | `sessionId` **R**; `configId` `SessionConfigId` **R** | `anyOf`: `{"type":"boolean","value":boolean}` with `required: ["type","value"]`, or untagged `{"value": SessionConfigValueId}` with `required: ["value"]`, titled `value_id` and documented as the "default when `type` is absent on the wire" | `["configOptions"]` | `configOptions` `SessionConfigOption[]` **R** |
| v2 | `["sessionId","configId"]` | `sessionId` **R**; `configId` `SessionConfigId` **R** | `anyOf`: `{"type":"id","value":SessionConfigValueId}` with `required: ["type","value"]`; `{"type":"boolean","value":boolean}`; or `other` `{"type":<any string>, "value":<raw>}` with `required: ["type","value"]` | `["configOptions"]` | `configOptions` `SessionConfigOption[]` **R** |

| Supporting type | Version | Shape |
| --- | --- | --- |
| `SessionConfigOption` | v1 | `required: ["id","name"]`; `id`, `name`, `description` `["string","null"]` opt, `category` `SessionConfigOptionCategory` \| `null` opt |
| `SessionConfigOption` | v2 | `required: ["configId","name"]`; `configId` (renamed from `id`), `name`, `description` `["string","null"]` opt, `category` `SessionConfigOptionCategory` \| `null` opt |
| `SessionConfigOption` type union | v1 | closed `oneOf`: `{"type":"select"}`, `{"type":"boolean"}` |
| `SessionConfigOption` type union | v2 | `anyOf`: `{"type":"select"}`, `{"type":"boolean"}`, plus `other` |
| `SessionConfigOptionCategory` | v2 | `mode`, `model`, `model_config`, `thought_level`, plus an `other` catch-all |
| `SessionConfigSelect` | both | `required: ["currentValue","options"]`; `currentValue` `SessionConfigValueId`; `options` is `SessionConfigSelectOptions`, a flat `SessionConfigSelectOption[]` **or** a grouped `SessionConfigSelectGroup[]` |
| `SessionConfigBoolean` | both | `required: ["currentValue"]`; `currentValue` `boolean` |

### 3k. v1-only supporting types

| Type | `required` | Fields |
| --- | --- | --- |
| `SessionModeState` | `["currentModeId","availableModes"]` | `currentModeId`; `availableModes` `SessionMode[]` |
| `SessionMode` | `["id","name"]` | `id`; `name`; `description` opt |

### 3l. `McpServer` — request-side server declarations

| Version | Variants (`type`) | Variant `required` |
| --- | --- | --- |
| v1 | `"http"` (gated by `mcpCapabilities.http`), `"sse"` (gated by `mcpCapabilities.sse`), `"stdio"` (untagged, titled `stdio`) — "All Agents MUST support this transport" | `McpServerHttp` / `McpServerSse`: `["name","url","headers"]`. `McpServerStdio`: `["name","command","args","env"]` |
| v2 | `"http"` (gated by `session.mcp.http`), `"stdio"` (gated by `session.mcp.stdio`), plus an `other` catch-all | `McpServerHttp`: `["name","url"]` — `headers` optional. `McpServerStdio`: `["name","command"]` — `args` and `env` optional |

## 4. `session/update` — every `sessionUpdate` variant string

`Source:` `schema/v1/schema.json` `$defs.SessionUpdate` and
`schema/v2/schema.json` `$defs.SessionUpdate`, plus each payload type in `$defs`.

The notification envelope is identical in both versions: `required: ["sessionId","update"]`;
`sessionId` `SessionId`; `update` `$ref SessionUpdate`; method name `session/update`. The
envelope type is `SessionNotification` in v1 and `UpdateSessionNotification` in v2.

### 4a. v1 — exactly 11 variants, closed `oneOf`, `discriminator.propertyName: "sessionUpdate"`

| `sessionUpdate` value | Payload `$ref` | Payload `required` | Optional payload fields |
| --- | --- | --- | --- |
| `user_message_chunk` | `ContentChunk` | `content` (`ContentBlock`) | `messageId` `MessageId` \| `null`; `_meta` |
| `agent_message_chunk` | `ContentChunk` | `content` | `messageId`; `_meta` |
| `agent_thought_chunk` | `ContentChunk` | `content` | `messageId`; `_meta` |
| `tool_call` | `ToolCall` | `toolCallId`, `title` | `name` `["string","null"]`; `kind` `ToolKind`; `status` `ToolCallStatus`; `content` `ToolCallContent[]`; `locations` `ToolCallLocation[]`; `rawInput` (untyped); `rawOutput` (untyped); `_meta` |
| `tool_call_update` | `ToolCallUpdate` | `toolCallId` | `kind`; `status`; `title` `["string","null"]`; `name` `["string","null"]`; `content` `ToolCallContent[]` \| `null`; `locations` `ToolCallLocation[]` \| `null`; `rawInput`; `rawOutput`; `_meta` |
| `plan` | `Plan` | `entries` (`PlanEntry[]`) | `_meta` |
| `available_commands_update` | `AvailableCommandsUpdate` | `availableCommands` (`AvailableCommand[]`) | `_meta` |
| `current_mode_update` | `CurrentModeUpdate` | `currentModeId` (`SessionModeId`) | `_meta` |
| `config_option_update` | `ConfigOptionUpdate` | `configOptions` (`SessionConfigOption[]`) | `_meta` |
| `session_info_update` | `SessionInfoUpdate` | *(none)* | `title` `["string","null"]`; `updatedAt` `["string","null"]`; `_meta` |
| `usage_update` | `UsageUpdate` | `used` (uint64 ≥ 0), `size` (uint64 ≥ 0) | `cost` `Cost` \| `null`; `_meta` |

Supporting v1 enums and types:

| Type | Shape |
| --- | --- |
| `PlanEntry` | `required: ["content","priority","status"]` |
| `PlanEntryPriority` | `high`, `medium`, `low` |
| `PlanEntryStatus` | `pending`, `in_progress`, `completed` |
| `AvailableCommand` | `required: ["name","description"]`; `input` `AvailableCommandInput` \| `null` opt |
| `AvailableCommandInput` | untagged union, single variant titled `unstructured` → `UnstructuredCommandInput`, `required: ["hint"]` |
| `Cost` | `required: ["amount","currency"]`; `amount` `number` / `double`; `currency` `string` with **no `pattern`** |
| `ToolKind` (closed `oneOf`) | `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other` |
| `ToolCallStatus` (closed `oneOf`) | `pending`, `in_progress`, `completed`, `failed`, `cancelled` |

### 4b. v2 draft — 16 named variants plus an `other` catch-all

`Source:` `schema/v2/schema.json` `$defs.SessionUpdate`. The union is `anyOf` with **17
branches**. Branch 17 has `title: "other"`, a free `string` `sessionUpdate` that must not
equal any of the 16 named values, `required: ["sessionUpdate"]` and
`additionalProperties: true`. Stated convention: values beginning with `_` are reserved for
implementation-specific extensions; unknown non-`_` values are reserved for future ACP
variants.

| `sessionUpdate` value | Payload `$ref` | Payload `required` | Optional payload fields |
| --- | --- | --- | --- |
| `user_message_chunk` | `ContentChunk` | `messageId` (`MessageId`), `content` (`ContentBlock`) | `_meta` |
| `user_message` | `UserMessage` | `messageId` | `content` `["ContentBlock[]", null]`; `_meta` |
| `agent_message_chunk` | `ContentChunk` | `messageId`, `content` | `_meta` |
| `agent_message` | `AgentMessage` | `messageId` | `content` `["ContentBlock[]", null]`; `_meta` |
| `agent_thought_chunk` | `ContentChunk` | `messageId`, `content` | `_meta` |
| `agent_thought` | `AgentThought` | `messageId` | `content` `["ContentBlock[]", null]`; `_meta` |
| `state_update` | `StateUpdate` | `state` (see 4c) | `_meta` |
| `tool_call_content_chunk` | `ToolCallContentChunk` | `toolCallId`, `content` (`ToolCallContent`) | `_meta` |
| `tool_call_update` | `ToolCallUpdate` | `toolCallId` | `name` `["string","null"]`; `title` `["string","null"]`; `kind` `ToolKind` \| `null`; `status` `ToolCallStatus` \| `null`; `content` `["ToolCallContent[]", null]`; `locations` `["ToolCallLocation[]", null]`; `rawInput`; `rawOutput`; `_meta` |
| `terminal_update` | `TerminalUpdate` | `terminalId` | `command` `["string","null"]`; `cwd` `AbsolutePath` \| `null`; `output` `TerminalOutput` \| `null`; `exitStatus` `TerminalExitStatus` \| `null`; `_meta` |
| `terminal_output_chunk` | `TerminalOutputChunk` | `terminalId`, `data` | `_meta` |
| `plan_update` | `PlanUpdate` | `plan` (`PlanUpdateContent`) | `_meta` |
| `available_commands_update` | `AvailableCommandsUpdate` | `availableCommands` (`AvailableCommand[]`) | `_meta` |
| `config_option_update` | `ConfigOptionUpdate` | `configOptions` (`SessionConfigOption[]`) | `_meta` |
| `session_info_update` | `SessionInfoUpdate` | *(none)* | `title`; `updatedAt` (`format: "date-time"`); `_meta` |
| `usage_update` | `UsageUpdate` | `used`, `size` (uint64 ≥ 0) | `cost` `Cost` \| `null`; `_meta` |
| *any other string* | `other` | `sessionUpdate` | free `sessionUpdate`; `additionalProperties: true` |

### 4c. v2 `StateUpdate` — the payload behind `state_update`

An `anyOf` with a discriminator-less tag field named `state`.

| `state` value | Payload | Payload fields |
| --- | --- | --- |
| `running` | `RunningStateUpdate` | `_meta` only |
| `idle` | `IdleStateUpdate` | `stopReason` `StopReason` \| `null` opt; `_meta` |
| `requires_action` | `RequiresActionStateUpdate` | `_meta` only |
| *any other string* | `other` | free `state`; `required: ["state"]`; `additionalProperties: true` |

### 4d. v2 supporting types

| Type | Shape |
| --- | --- |
| `UserMessage`, `AgentMessage`, `AgentThought` | all `required: ["messageId"]`, with patch semantics: omitted = no change, `null` = clear, a concrete array = replace |
| `ContentChunk` (v2) | `required: ["messageId","content"]` — **`messageId` is required in v2 and optional in v1** |
| `TerminalOutput` | `required: ["data"]`; `data` is `{"type":"string","contentEncoding":"base64"}` |
| `TerminalOutputChunk` | `required: ["terminalId","data"]`; `data` is `contentEncoding: "base64"`, documented as "Independently base64-encoded" |
| `TerminalExitStatus` | `exitCode` `["integer","null"]` `uint32` ≥ 0 opt; `signal` `["string","null"]` opt; `_meta`. No `required` key |
| `PlanUpdate` | `required: ["plan"]` |
| `PlanUpdateContent` | `{"type":"items"}` → `PlanItems` with `required: ["planId","entries"]`, or `other` |
| `PlanEntryStatus` (v2) | `pending`, `in_progress`, `completed`, `cancelled`, plus `other` |
| `AvailableCommandInput` (v2) | now **tagged**: `{"type":"text"}` → `TextCommandInput` with `required: ["hint"]`, plus an `other` catch-all |
| `Cost.currency` (v2) | gains `"pattern": "^[A-Z]{3}$"` |
| `ToolKind` (v2) | the v1 ten values plus an `other` catch-all branch titled `unknown` |
| `ToolCallStatus` (v2) | the v1 five values plus an `other` catch-all |

**Variants removed in v2:** `tool_call`, replaced by the upsert `tool_call_update`;
`plan`, replaced by `plan_update`; `current_mode_update`, folded into session config options
carrying `category: "mode"`.

## 5. Permission model

`Source:` `schema/v1/schema.json` and `schema/v2/schema.json` `$defs.RequestPermissionRequest`,
`$defs.RequestPermissionResponse`, `$defs.RequestPermissionOutcome`,
`$defs.PermissionOption`, `$defs.PermissionOptionKind`, and in v2
`$defs.RequestPermissionSubject`.

### 5a. `session/request_permission` request

| Version | `required` | Fields |
| --- | --- | --- |
| v1 | `["sessionId","toolCall","options"]` | `sessionId` `SessionId` **R**; `toolCall` `ToolCallUpdate` **R**; `options` `PermissionOption[]` **R** (no `minItems`); `_meta` opt |
| v2 | `["sessionId","title","options"]` | `sessionId` **R**; `title` `string` **R**; `description` `["string","null"]` opt; `subject` `RequestPermissionSubject` \| `null` opt; `options` `PermissionOption[]` **R** with **`"minItems": 1`**; `_meta` opt |

### 5b. Response — identical shape in both versions

`required: ["outcome"]`; `outcome` `$ref RequestPermissionOutcome`; `_meta` opt.

`RequestPermissionOutcome`, `discriminator.propertyName: "outcome"`:

| `outcome` value | Payload | Payload `required` |
| --- | --- | --- |
| `cancelled` | none (terminal branch) | `["outcome"]` |
| `selected` | `SelectedPermissionOutcome` | `["outcome"]`, plus `optionId` `PermissionOptionId` **R** |
| *any other string* | **no catch-all branch is declared in v1 or in v2** | — |

v1 `cancelled` doc, verbatim: "When a client sends a `session/cancel` notification to cancel
an ongoing prompt turn, it **MUST** respond to all pending `session/request_permission`
requests with this `Cancelled` outcome." v2 encodes the same two variants as `anyOf` instead
of `oneOf`; no third catch-all branch is declared for `RequestPermissionOutcome`.

### 5c. `PermissionOption` — identical in both versions

`required: ["optionId","name","kind"]`; `optionId` `PermissionOptionId` (string); `name`
`string`; `kind` `PermissionOptionKind`; `_meta` opt.

### 5d. `PermissionOptionKind` — every value

| Value | v1 | v2 draft |
| --- | --- | --- |
| `allow_once` | yes | yes |
| `allow_always` | yes | yes |
| `reject_once` | yes | yes |
| `reject_always` | yes | yes |
| *any other string* | **no** — closed `oneOf` | **yes** — `anyOf` plus an `other` branch |

### 5e. v2 `RequestPermissionSubject` — new in v2

An `anyOf` with tag field `type`. The `toolCall` field moves out of the request root and
into this union.

| `type` value | Payload | Payload `required` | Payload fields |
| --- | --- | --- | --- |
| `tool_call` | `ToolCallPermissionSubject` | `["toolCall"]` | `toolCall` `ToolCallUpdate` **R** (no `_meta` declared) |
| `command` | `CommandPermissionSubject` | `["command","cwd"]` | `command` `string` **R**; `cwd` `AbsolutePath` **R**; `toolCallId` `ToolCallId` \| `null` opt; `terminalId` `TerminalId` \| `null` opt; `_meta` opt |
| *any other string* | `other` | `["type"]` | free `type`; `additionalProperties: true` |

`subject` itself is optional on the request: "Omitted or `null` both mean no structured
subject was provided."

## 6. Elicitation

`Source:` `schema/v1/schema.json` and `schema/v2/schema.json` `$defs.CreateElicitationRequest`,
`$defs.CreateElicitationResponse`, `$defs.ElicitationFormMode`, `$defs.ElicitationUrlMode`,
`$defs.ElicitationSchema`, `$defs.ElicitationPropertySchema`,
`$defs.CompleteElicitationNotification`; prose from `/protocol/v1/initialization.md` and
`/protocol/v2/initialization.md`.

### 6a. `elicitation/create` request — `required: ["message"]` in both versions

| Field | Type | v1 | v2 | Notes |
| --- | --- | --- | --- | --- |
| `message` | `string` | **R** | **R** | |
| `mode` | tag field | **R** per branch | **R** per branch | `form`, `url`, and in v2 any other string |
| `_meta` | `["object","null"]` | opt | opt | |

| Field | Type | v1 | v2 |
| --- | --- | --- | --- |
| `mode` = `form` | `ElicitationFormMode` | yes | yes |
| `mode` = `url` | `ElicitationUrlMode` | yes | yes |
| `mode` = any other string | `other`, `required: ["mode"]`, `unevaluatedProperties: true` | **no** | **yes** |

Scope — an `anyOf` in both versions, either:

| Scope type | `required` | Fields |
| --- | --- | --- |
| `ElicitationSessionScope` | `["sessionId"]` | `sessionId`; `toolCallId` opt |
| `ElicitationRequestScope` | `["requestId"]` | `requestId` `RequestId` |

Mode payload fields:

| Type | `required` | Fields |
| --- | --- | --- |
| `ElicitationFormMode` | `["requestedSchema"]` | `requestedSchema` `ElicitationSchema`; scope fields via the `anyOf` above |
| `ElicitationUrlMode` | `["elicitationId","url"]` | `elicitationId` `ElicitationId` (string); `url` `{"type":"string","format":"uri"}`; scope fields via the `anyOf` above |
| `ElicitationSchema` | *(none)* | `type` `$ref ElicitationSchemaType` (const `"object"`, default `"object"`); `title` `["string","null"]` opt; `properties` `object` default `{}` with `additionalProperties: {$ref ElicitationPropertySchema}`; `required` `["string"]` \| `null` opt; `description` opt; `_meta` opt |

`ElicitationPropertySchema` variants, by `type` const:

| `type` const | Established here |
| --- | --- |
| `string` | yes |
| `number` | yes |
| `integer` | yes |
| `array` | named only in the doc text ("Multi-select enums use the `Array` variant"); the branch itself was not read directly |
| `boolean` | **NOT ESTABLISHED IN SOURCE** |

### 6b. `elicitation/create` response — no `required` array in either version

`action` is the tag; every branch has `required: ["action"]`.

| `action` value | v1 | v2 | Payload |
| --- | --- | --- | --- |
| `accept` | yes | yes | `ElicitationAcceptAction` — `content` is `["object","null"]` with `additionalProperties: {$ref ElicitationContentValue}`; **no `required`** |
| `decline` | yes | yes | none |
| `cancel` | yes | yes | none |
| *any other string* | **no** | **yes** — `title: "other"`, `additionalProperties: true` | free `action` |

### 6c. `elicitation/complete` (notification) — identical in both versions

`required: ["elicitationId"]`; `elicitationId` `ElicitationId`; `_meta` opt. The struct
carries `x-method: "elicitation/complete"` and `x-side: "client"`.

### 6d. Gating capability

`clientCapabilities.elicitation.form` = `{}` advertises form mode;
`clientCapabilities.elicitation.url` = `{}` advertises URL mode. Both versions' spec text is
explicit: "A present object advertises each mode only through its corresponding non-null
`form` or `url` field. Empty and all-null objects are valid but advertise no supported modes.
Unlike MCP, ACP does not treat `{}` as form support."

## 7. Client filesystem and terminal methods, and their v2 removal status

`Source:` `schema/v1/schema.json` `$defs` for each request/response type and
`$defs.FileSystemCapabilities`; `schema/v2/meta.json` and `schema/v2/schema.json` for the
absence of the same methods; `/protocol/v2/overview.md`.

| Method string | v1 | Gating capability key (exact path) | Capability type | v2 status |
| --- | --- | --- | --- | --- |
| `fs/read_text_file` | yes | `clientCapabilities.fs.readTextFile` | `boolean`, default `false` | **REMOVED** — absent from `schema/v2/meta.json` `clientMethods`, absent from `schema/v2/schema.json` (no `fs`, no `FileSystemCapabilities`, no `x-method`), and absent from `/protocol/v2/overview.md` |
| `fs/write_text_file` | yes | `clientCapabilities.fs.writeTextFile` | `boolean`, default `false` | **REMOVED** — as above |
| `terminal/create` | yes | `clientCapabilities.terminal` | `boolean`, default `false` | **REMOVED** |
| `terminal/output` | yes | `clientCapabilities.terminal` | `boolean` | **REMOVED** |
| `terminal/release` | yes | `clientCapabilities.terminal` | `boolean` | **REMOVED** |
| `terminal/wait_for_exit` | yes | `clientCapabilities.terminal` | `boolean` | **REMOVED** |
| `terminal/kill` | yes | `clientCapabilities.terminal` | `boolean` | **REMOVED** |

v1 schema descriptions, verbatim: `fs.readTextFile` — "Whether the Client supports
`fs/read_text_file` requests."; `fs.writeTextFile` — "Whether the Client supports
`fs/write_text_file` requests."; `terminal` — "Whether the Client support all `terminal/*`
methods."

**The v2 replacement is not a rename.** Terminal state is now agent-owned and reported
read-only through `session/update`, via the new variants `terminal_update`
(`TerminalUpdate`) and `terminal_output_chunk` (`TerminalOutputChunk`). There is no v2
method to create, kill or release a terminal.

v1 request and result field lists:

| Method | Request `required` | Request fields | Response `required` | Response fields |
| --- | --- | --- | --- | --- |
| `fs/read_text_file` | `["sessionId","path"]` | `sessionId`; `path` `string`; `line` `["integer","null"]` `uint32` opt; `limit` `["integer","null"]` `uint32` opt; `_meta` | `["content"]` | `content` `string` |
| `fs/write_text_file` | `["sessionId","path","content"]` | `sessionId`; `path` `string`; `content` `string`; `_meta` | *(none)* | `_meta` only |
| `terminal/create` | `["sessionId","command"]` | `sessionId`; `command` `string`; `args` `["string"]` opt; `env` `EnvVariable[]` opt; `cwd` `["string","null"]` opt; `outputByteLimit` `["integer","null"]` `uint64` ≥ 0 opt; `_meta` | `["terminalId"]` | `terminalId` |
| `terminal/output` | `["sessionId","terminalId"]` | `sessionId`; `terminalId`; `_meta` | NOT ESTABLISHED IN SOURCE | `TerminalOutputResponse`: `output`, `exitStatus`, `truncated` |
| `terminal/release` | `["sessionId","terminalId"]` | `sessionId`; `terminalId`; `_meta` | NOT ESTABLISHED IN SOURCE | `ReleaseTerminalResponse` |
| `terminal/wait_for_exit` | `["sessionId","terminalId"]` | `sessionId`; `terminalId`; `_meta` | NOT ESTABLISHED IN SOURCE | `WaitForTerminalExitResponse`: `exitStatus` |
| `terminal/kill` | `["sessionId","terminalId"]` | `sessionId`; `terminalId`; `_meta` | NOT ESTABLISHED IN SOURCE | `KillTerminalResponse` |

## 8. Transports

`Source:` `https://agentclientprotocol.com/protocol/v1/transports.md` and
`https://agentclientprotocol.com/protocol/v2/transports.md`, corroborated against the root
`anyOf` of `schema/v1/schema.json` and `schema/v2/schema.json`.

| Rule | v1 | v2 draft |
| --- | --- | --- |
| Encoding | "ACP uses JSON-RPC to encode messages. JSON-RPC messages **MUST** be UTF-8 encoded." | identical |
| Defined transports | 1. `stdio`; 2. *Streamable HTTP* — "*(draft proposal in progress)*" | identical |
| Support guidance | "Agents and clients **SHOULD** support stdio whenever possible." | identical |
| Delimiter | "Messages are delimited by newlines (`\n`), and **MUST NOT** contain embedded newlines." | identical |
| Message granularity | "Messages are individual JSON-RPC requests, notifications, or responses." | "Messages are individual JSON-RPC requests, notifications, responses, or **batch arrays**." |
| stdout purity | "The agent **MUST NOT** write anything to its `stdout` that is not a valid ACP message." | identical |
| stdin purity | "The client **MUST NOT** write anything to the agent's `stdin` that is not a valid ACP message." | identical |
| stderr | "The agent **MAY** write UTF-8 strings to its standard error (`stderr`) for logging purposes. Clients **MAY** capture, forward, or ignore this logging." | identical |
| Lifecycle | the client launches the agent as a subprocess; "Close stdin, terminate subprocess" | identical |
| Custom transports | "MAY implement additional custom transport mechanisms"; they "**MUST** ensure they preserve the JSON-RPC message format and lifecycle requirements" | identical |
| Remote / HTTP status | **Streamable HTTP: in discussion, draft proposal in progress.** Not normative | **Identical wording. Still a draft proposal in progress. Not normative in v2 either.** A normative remote transport is NOT ESTABLISHED IN SOURCE in either version |

### 8a. v2-only JSON-RPC batch rules

`Source:` `https://agentclientprotocol.com/protocol/v2/transports` § "JSON-RPC batch
messages", verbatim fragments.

| Rule | Requirement |
| --- | --- |
| Batch shape | a batch **MUST** be an array with at least one value |
| Invalid JSON | `Parse error`, `code: -32700`, `id: null` |
| Empty array | a single `Invalid Request`, `code: -32600`, `id: null`; "not a response array" |
| Concurrency | the receiver **MAY** process entries as concurrent tasks in any order |
| Response container | the receiver **SHOULD** respond with an array after all Requests are processed |
| Coverage | a Response **SHOULD** exist for each Request, and **SHOULD NOT** for Notifications |
| Notifications | the receiver **MUST NOT** reply to a Notification, including within a batch |
| Ordering | responses **MAY** appear in any order |
| No responses | if there are no Response objects the receiver **MUST NOT** return an empty array |
| Invalid entries | an invalid entry produces its own `-32600` with `id: null` and does not fail the batch |
| State-changing methods | clients and agents **SHOULD NOT** batch `initialize`, `auth/login`, `session/new`, `session/resume`, `session/prompt` |

Schema corroboration: the root `anyOf` of `schema/v2/schema.json` adds `AgentBatchCall` and
`AgentBatchResponse`, both `{"type":"array","minItems":1}`. `schema/v1/schema.json` has no
batch variants.

## 9. Version negotiation and artifact version strings

`Source:` `https://agentclientprotocol.com/protocol/v1/initialization.md`,
`https://agentclientprotocol.com/protocol/v2/initialization.md`, the `ProtocolVersion` type
in both schemas, `schema/v1/meta.json`, `schema/v2/meta.json`, and
`https://docs.rs/crate/agent-client-protocol-schema/latest`.

### 9a. The `protocolVersion` value

| Item | v1 | v2 draft |
| --- | --- | --- |
| JSON type | `{"type":"integer","format":"uint16","minimum":0,"maximum":65535}` | **identical** |
| Schema doc | "Protocol version identifier. This version is only bumped for breaking changes. Non-breaking changes should be introduced via capabilities." | identical |
| Meaning | "a single integer that identifies a **MAJOR** protocol version. This version is only incremented when breaking changes are introduced." | identical |
| Example value | `1` | `2` |
| Required in `InitializeRequest`? | yes, `required: ["protocolVersion"]` | yes |
| Required in `InitializeResponse`? | yes | yes |

### 9b. The negotiation algorithm, verbatim in both versions

| Step | Requirement |
| --- | --- |
| 1 | "The `initialize` request **MUST** include the latest protocol version the Client supports." |
| 2 | "If the Agent supports the requested version, it **MUST** respond with the same version. Otherwise, the Agent **MUST** respond with the latest version it supports." |
| 3 | "If the Client does not support the version specified by the Agent in the `initialize` response, the Client **SHOULD** close the connection and inform the user about it." |
| 4 | "Clients and Agents **MUST** agree on a protocol version and act according to its specification." |
| 5 | Capability omission: "Clients and Agents **MUST** treat all capabilities omitted in the `initialize` request as **UNSUPPORTED**." |

### 9c. Schema and crate artifact version strings

| Artifact | Value | Source |
| --- | --- | --- |
| `schema/v1/meta.json` → `version` | `1` (integer) | `schema/v1/meta.json` |
| `schema/v2/meta.json` → `version` | `2` (integer) | `schema/v2/meta.json` |
| `agent-client-protocol-schema` crate, latest | `1.9.1`, released 2026-09-18 | docs.rs |
| Prior crate releases | `1.9.0`, `1.8.0` (2026-09-17), `1.7.0` (2026-08-20), `1.6.0` (2026-07-21), `1.5.0`, `1.4.0`, `1.3.0`, `1.2.0`, `1.1.0`, `1.0.0` (2026-06-24) | docs.rs |
| Workspace declaration | `agent-client-protocol-schema = { path = "…", version = "1.9.1" }` | repo root `Cargo.toml` |
| Crate README, normative | "**The current stable ACP protocol version is `1`.**" | docs.rs |
| Crate README, normative | "The Rust crate version and JSON Schema release versions describe the Rust crate and JSON Schema artifacts themselves… **Consumers should not infer wire compatibility from the crate or schema release version alone. Use the negotiated `protocolVersion`** to determine the ACP wire protocol shape and breaking-compatibility level." | docs.rs |
| Schema release attachment | "When a schema release is published, the versioned `.json` files are also attached to the corresponding [`schema-v*`] GitHub release" | docs.rs |
| The GitHub `schema-v*` release tag itself | **NOT ESTABLISHED IN SOURCE** — this extraction read `meta.json` and the docs.rs index, not the GitHub releases page | — |

## 10. `mcp/message` — the mcp-over-acp binding envelope

`Source:` `https://agentclientprotocol.com/rfds/mcp-over-acp.md` (author nikomatsakis).
**Status: RFD / draft. It is not present in either published schema.** The `mcpCapabilities`
shapes below are from the released schemas; the `acp` key is RFD-only.

### 10a. Method name and directions

| Item | Value |
| --- | --- |
| Method name | `mcp/message` — "The binding uses one method name, `mcp/message`, in two directions" |
| Direction 1 | agent-to-provider **request** invokes one MCP operation and "eventually receives one result or error" |
| Direction 2 | provider-to-agent **notification** carries an MCP notification "belonging to that active operation" |
| Not an MCP method | "`mcp/message` is this binding's ACP transport envelope, not an MCP-defined method. JSON-RPC distinguishes the two forms by the outer `id`: requests have one, notifications do not." |
| Provider-originated requests | "There are no provider-originated MCP requests." |
| MCP revision targeted | **2026-07-28 only** — "This draft targets **MCP 2026-07-28 only**. It does not emulate older MCP revisions." |
| Cancellation | reuses `$/cancel_request` on the **outer ACP id**; "this binding adds no separate cancellation method" |
| Presence in a released schema | NOT ESTABLISHED IN SOURCE — the strings `mcp/message`, `PermissionSubject` and `acp` as a capability key do not occur in `schema/v2/schema.json`; both `meta.json` files list no `mcp/*` method |

Worked example, verbatim from the RFD:

```json
{"jsonrpc":"2.0","id":20,"method":"mcp/message","params":{
  "serverId":"project-tools:7a72","requestId":"mcp-request:a11f",
  "method":"tools/call",
  "params":{"name":"echo","arguments":{"message":"hello"},
    "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
             "io.modelcontextprotocol/clientCapabilities":{},
             "io.modelcontextprotocol/clientInfo":{"name":"example-agent","version":"1"},
             "progressToken":"progress-1"}}}}
```

### 10b. Request envelope fields

| Envelope field | Type | Req | Rule (verbatim) |
| --- | --- | --- | --- |
| `serverId` | non-null `string` | **R** | "required non-null strings on both requests and notifications"; "names a server declared by its provider"; "must not be rebound to a different registration, including after removal" |
| `requestId` | non-null `string` | **R** | "caller-generated opaque string identifying one logical MCP request… used as the inner MCP JSON-RPC ID"; "A caller uses a fresh `requestId` for each operation" |
| `method` | non-null `string` | **R** | the inner MCP method, for example `tools/call`, `notifications/progress`, `server/discover`, `subscriptions/listen` |
| `params` | object \| `null` | opt | "accepts an object or `null` and is optional at the envelope level. Omission and `null` both mean no inner parameters; positional arrays are invalid." |
| `_meta` | object | opt | "An optional outer `_meta` object alongside `serverId` is ACP envelope metadata. Omission and `null` are equivalent." |

### 10c. Response carrier — exactly one of `result` or `error`

| Member | Shape | Rule (verbatim) |
| --- | --- | --- |
| `result` | `{"result": <any JSON value, including explicit null>}` | the successful inner outcome |
| `error` | `{"error": {"code": <integer, required>, "message": <string, required>, "data": <optional>}}` | "a non-null object with required integer `code` and string `message`; optional `data` distinguishes omission from explicit `null`." |
| carrier `_meta` | object | "An optional carrier `_meta` contains ACP metadata and is separate from the inner outcome's metadata." |

### 10d. Binding failure codes — outer ACP errors

| Code | Meaning (verbatim) |
| --- | --- |
| `-32602` | Malformed ACP envelope or duplicate active `(serverId, requestId)` |
| `-32800` | ACP operation cancelled |
| `-33000` | Binding resource limit exceeded |
| `-33001` | Server registration unavailable |
| `-33002` | Backend or transport failed without a valid MCP outcome |

"These binding-specific codes do not allocate new meanings in MCP's reserved `-32000`
through `-32019` range." A version mismatch uses MCP's `-32022`
(`UnsupportedProtocolVersion`) **inside the outcome carrier**.

### 10e. Server declaration and the `acp` capability

Server declaration, in `session/new` and peers: `{"type": "acp", "name": "project-tools",
"serverId": "project-tools:7a72"}`.

| | v1 published | v2 draft published | RFD proposal (v1) | RFD proposal (v2) |
| --- | --- | --- | --- | --- |
| Path | `InitializeResponse.agentCapabilities.mcpCapabilities` | `InitializeResponse.capabilities.session.mcp` | same as v1 | same as v2 |
| Declared fields | `http` `boolean` d=`false`; `sse` `boolean` d=`false`; `_meta` | `stdio` `McpStdioCapabilities` \| `null`; `http` `McpHttpCapabilities` \| `null`; `_meta` | adds `acp` | adds `acp` |
| v1 RFD fragment | — | — | `{"agentCapabilities": {"mcpCapabilities": {"acp": true}}}` — "Omission is equivalent to `false`." | — |
| v2 RFD fragment | — | — | — | `{"capabilities": {"session": {"mcp": {"acp": {}}}}}` — "omission or `null` means support is not advertised, and `{}` advertises support" |
| `acp` in a published schema? | **NO** | **NO** | — | — |

`mcpCapabilities` does not occur in `schema/v2/schema.json` at all; v2 renamed it to
`capabilities.session.mcp`. The `McpServer` union in the published v2 schema has exactly the
branches `http`, `stdio` and the `other` catch-all — **no `acp` branch**, so the RFD's
`{"type":"acp", …}` declaration would currently fall through to `other`.

**Source conflict, both values stated.** The mcp-over-acp RFD specifies `mcp/message`, a
`{"type":"acp"}` server declaration, and the `mcpCapabilities.acp` /
`capabilities.session.mcp.acp` capability key. The published `schema/v1/schema.json`
`McpCapabilities` has only `http` and `sse`; the published `schema/v2/schema.json`
`McpCapabilities` has only `stdio` and `http`, and `McpServer` has no `acp` variant. Both
`meta.json` files list no `mcp/*` method. These are a draft RFD and released schemas, and
they disagree today.

## 11. Source conflicts and doc/schema inconsistencies found

`Source:` the schema and prose files named in Artifact provenance, read against each other.

| # | Finding |
| --- | --- |
| 1 | v1 `SessionCapabilities` prose references a snake_case capability that does not exist: "Note: `session/load` is still handled by the top-level `load_session` capability." The actual property is `loadSession` (camelCase), and `initialization.md` calls it `loadSession`. By the spec's own convention rule this prose is wrong |
| 2 | v1 `initialization.md` "Session Capabilities" documents only 2 of the 5 capability keys. It lists `delete` and `additionalDirectories`; the schema also defines `list`, `resume` and `close` |
| 3 | v1 `initialization.md` File System capability paths omit the `fs.` prefix (`readTextFile`, `writeTextFile`) while the same page and the schema use `fs.readTextFile` / `fs.writeTextFile` |
| 4 | v1 `initialization.md` never documents `session/list`, `session/resume`, `session/close`, `session/delete` or `session/set_config_option` in the baseline or optional list of `overview.md`; they appear only in `meta.json` and the schema, gated by `sessionCapabilities.*` |
| 5 | `session/set_config_option` has no baseline/optional classification in either version's prose, yet appears in both `meta.json` `agentMethods` |
| 6 | v1 `NewSessionRequest` requires `mcpServers`; v2 does not. v1 `required: ["cwd","mcpServers"]` against v2 `required: ["cwd"]` |
| 7 | `SessionConfigOption` renames `id` to `configId` between v1 and v2 with no compatibility shim |
| 8 | the `session/set_config_option` value union changes shape: v1's default is an *untagged* `{"value": <id>}` (titled `value_id`); v2 requires an explicit `"type": "id"` and adds a catch-all |
| 9 | v1 `Cost.currency` is unconstrained; v2 constrains it with `"pattern": "^[A-Z]{3}$"` |
| 10 | v1 `SessionInfo.updatedAt` and `SessionInfoUpdate.updatedAt` have no `format` (documented as ISO 8601); v2 sets `"format": "date-time"` (documented as RFC 3339) |
| 11 | v1 `session/prompt` result carries `stopReason`; v2 carries `messageId` and relocates the stop reason into an idle `state_update` |
| 12 | v1 has two tool-call variants (`tool_call` and `tool_call_update`) with different shapes; v2 has one (`tool_call_update`, an upsert) plus `tool_call_content_chunk` |
| 13 | `AvailableCommandInput` in v1 is untagged (a single `unstructured` variant with no `type` field); in v2 it is tagged `"type": "text"`. A v1 reader that switches on `type` will not see a tag in v1 payloads |
| 14 | v1 `SessionNotification` against v2 `UpdateSessionNotification` — same wire shape, different `$defs` name; wire-compatible, name-incompatible for code generators |
| 15 | the mcp-over-acp RFD and the released schemas disagree on `mcp/message`, the `McpServer` `type: "acp"` declaration, and the `acp` capability key. See section 10e |
| 16 | v1 `McpServerHttp` and `McpServerSse` require `headers`; v2 `McpServerHttp` does not, and v2 `McpServerStdio` drops the `args` and `env` requirements |

## 12. Values explicitly not established

`Source:` the full set of primary artifacts listed in Artifact provenance.

| Value | Status |
| --- | --- |
| `ElicitationPropertySchema` `boolean` variant | **NOT ESTABLISHED IN SOURCE** — the v1 union branches read were `string`, `number`, `integer`; the doc text names an `Array` variant. A `boolean` branch was not confirmed |
| `ContentBlock` full variant string list, both versions | **NOT ESTABLISHED IN SOURCE** — referenced throughout, but the `$defs` body was not read |
| `ToolCallContent` full variant string list, both versions | **NOT ESTABLISHED IN SOURCE** — referenced throughout; the v2 body was observed to begin with `{"type":"content"}`, `{"type":"diff"}` and a terminal variant that began at the cut |
| Baseline/optional classification for `session/set_config_option`, either version | **NOT ESTABLISHED IN SOURCE** |
| A normative remote or HTTP transport, either version | **NOT ESTABLISHED IN SOURCE** — Streamable HTTP is a draft proposal in progress in both |
| `mcp/message` in any released schema artifact | **NOT ESTABLISHED IN SOURCE** — it is RFD-only |
| `TerminalOutputResponse`, `ReleaseTerminalResponse`, `WaitForTerminalExitResponse`, `KillTerminalResponse` full field lists, v1 | **NOT ESTABLISHED IN SOURCE** — the request shapes were confirmed; see section 7 for the partial field lists that were |
| The GitHub `schema-v*` release tag numbering | **NOT ESTABLISHED IN SOURCE** — see section 9c |

