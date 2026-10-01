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
requires a vendor prefix. Four bare key names are excepted: the three W3C trace
context keys the schema defines bare, and `progressToken`, which it also defines
bare.

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
| `progressToken` | `ProgressToken` = string or number. Bare key, exempt from the prefix rule: the schema defines it without one. **Optional** — an opt-in on the request. The same name is a **required payload member** of `notifications/progress`, which is not a `_meta` key; 4.11.2 states both |

### 4.4 Method inventory

Core, `2026-07-28`. `server/discover` is the only mandatory server method.

| Method | Direction | Notes |
| --- | --- | --- |
| `server/discover` | client to server | Mandatory. Cacheable result. `supportedVersions`, `capabilities`, optional `instructions` |
| `tools/list` | client to server | Cacheable result |
| `tools/call` | client to server | May return `input_required` under MRTR |
| `resources/list` | client to server | Cacheable result |
| `resources/read` | client to server | Cacheable result. May return `input_required` under MRTR |
| `resources/templates/list` | client to server | Cacheable result |
| `prompts/list` | client to server | Cacheable result |
| `prompts/get` | client to server | May return `input_required` under MRTR |
| `completion/complete` | client to server | |
| `subscriptions/listen` | client to server | Single long-lived response stream for opted-in notifications |
| `notifications/progress` | server to client | Request-scoped; travels on the originating request's response stream. 4.11.3 |
| `notifications/message` | server to client | Request-scoped. A server MUST NOT emit it for a request that did not set `io.modelcontextprotocol/logLevel`. 4.11.3 |
| `notifications/cancelled` | both | A server sends it only for a `subscriptions/listen` teardown, and a client sends it to cancel a request. 4.11.3 |
| `notifications/resources/updated` | server to client | Carries the `uri`. 4.11.3 |
| `notifications/resources/list_changed` | server to client | `params` optional. 4.11.3 |
| `notifications/tools/list_changed` | server to client | `params` optional. 4.11.3 |
| `notifications/prompts/list_changed` | server to client | `params` optional. 4.11.3 |
| `notifications/subscriptions/acknowledged` | server to client | Carries the subscription filter. 4.11.3, 4.11.4 |

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

#### 4.8.1 `ClientCapabilities`

Carried on every request at `2026-07-28` and later, as
`params._meta["io.modelcontextprotocol/clientCapabilities"]`. Transcribed from
`schema/2026-07-28/schema.ts` L711–L786, reproduced in
[`research/normative/mcp-2026-07-28-schema.md`](research/normative/mcp-2026-07-28-schema.md)
§9 with its JSDoc intact. Every member is optional and the object declares no
required member at all, so `{}` is a well-formed declaration meaning "no
optional capability".

| Member | Type | Required | Notes |
| --- | --- | --- | --- |
| `experimental` | `{ [key: string]: JSONObject }` | No | Non-standard capabilities |
| `roots` | `{}` — the empty object type | No | **@deprecated** (SEP-2577). Any JSON object satisfies it; the artifact declares no member |
| `sampling` | `{ context?: JSONObject; tools?: JSONObject }` | No | **@deprecated** (SEP-2577). Both inner members optional |
| `elicitation` | `{ form?: JSONObject; url?: JSONObject }` | No | Both inner members optional. The artifact gives these two **no JSDoc** |
| `extensions` | `{ [key: string]: JSONObject }` | No | Keys are extension identifiers and MUST carry a prefix. `{}` value means support with no settings |

#### 4.8.2 `ServerCapabilities`

Carried as `capabilities` on the `server/discover` result at `2026-07-28` and
later. Transcribed from L788–L883, reproduced in the same document §9. Also
every member optional, and — unlike a result — the artifact declares **no**
`[key: string]: unknown` index signature on it. Its openness comes from the doc
comment alone, which is the distinction 4.10.6 relies on.

| Member | Type | Required | Notes |
| --- | --- | --- | --- |
| `experimental` | `{ [key: string]: JSONObject }` | No | Non-standard capabilities |
| `logging` | `JSONObject` | No | **@deprecated** (SEP-2577) |
| `completions` | `JSONObject` | No | |
| `prompts` | `{ listChanged?: boolean }` | No | Whether `notifications/prompts/list_changed` may be sent. Not the payload |
| `resources` | `{ subscribe?: boolean; listChanged?: boolean }` | No | Both inner members optional. `subscribe` now means resource updates via the `resourceSubscriptions` filter, not the removed `resources/subscribe` RPC |
| `tools` | `{ listChanged?: boolean }` | No | Whether `notifications/tools/list_changed` may be sent. Not the payload |
| `extensions` | `{ [key: string]: JSONObject }` | No | Same key rules as the client map |

#### 4.8.3 Open sets, and what a capability is not

Both interfaces carry a sentence that differs between them in exactly one word —
`any client can define` on `ClientCapabilities`, `any server can define` on
`ServerCapabilities` — and a search of all 3,197 lines finds that sentence shape
exactly twice, on these two declarations and nowhere else:

> Known capabilities are defined here, in this schema, but this is not a closed
> set: any *client* / any *server* can define its own, additional capabilities.

So a capability object is **open at the member level**, and the source says so in
prose rather than in the type. A key outside the five or seven named above is not
an error and is not a decode failure; it is carried and written back, which 2
requires of anything a decoder accepts. The interfaces themselves declare no index
signature, so unlike a result they do not *advertise* openness by type either — a
difference in how the source expresses it, not in what it permits. 4.10.6 has the
measurement.

Three things follow that are easy to get wrong, so they are stated:

- **A capability is never a notification payload.** `prompts.listChanged`,
  `resources.subscribe`, `resources.listChanged` and `tools.listChanged` are
  `boolean` members that say whether the server may send that notification. The
  notification's own shape is 4.11. The string `notifications/` occurs in no
  capability interface in the artifact.
- **The nested objects declare exactly the members tabulated, and nothing closes
  them.** `sampling`, `elicitation`, `prompts`, `resources` and `tools` each
  declare the members tabulated above and no index signature, while
  `experimental`, `extensions` and the `JSONObject`-typed members are open maps
  by type. But declaring a member set is not closing it, and the source closes
  none: `schema/2026-07-28/schema.ts` contains no `additionalProperties` and no
  `unevaluatedProperties` at all, and in the generated `schema.json`
  (draft 2020-12) the keyword occurs twenty times and **never with `false`** —
  these five carry no such keyword, which permits undeclared keys. So an
  undeclared member of a nested capability object is **NOT ESTABLISHED** in either
  direction, and this library does not invent a rule for it. 4.10.6 records the
  evidence and 4.10.7 the silence. The closed things here are value sets, not
  member sets: `listChanged` and `subscribe` are `boolean`, with no `string` arm
  to widen it. 4.10.6 has the whole table.
- **`elicitation: {}` means form-only.** `client/elicitation.md` makes an empty
  `elicitation` equivalent to `{ "form": {} }` for backward compatibility, and
  requires a client declaring `elicitation` to support at least one mode.
  6.7 carries the same rule on the ACP side, where each mode must be advertised
  explicitly; the two protocols deliberately differ here and an adapter between
  them must not pass an empty ACP capability set through as MCP form-only
  without saying so.

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

### 4.10 Result payloads

The method inventory in 4.4 names the methods. This section gives each one the
body it answers with. The envelope every one of them carries — `resultType`, and
`ttlMs`/`cacheScope` where the result is cacheable — is fixed in 4.6 and is not
repeated per method below.

Transcribed from `schema/2026-07-28/schema.ts`, which
[`research/normative/mcp-2026-07-28-schema.md`](research/normative/mcp-2026-07-28-schema.md)
reproduces value-by-value with artifact line ranges: the envelope and its two
bases, the ten `*ResultResponse` interfaces, the ten result interfaces they name,
`InputRequiredResult`, the `ServerResult` union, `ContentBlock` and its five
members, `ResourceContents` and its two arms, and the element types those
reference. Requirement language is from `basic/index.md` §Result Responses,
`server/tools.md`, `server/resources.md`, `server/prompts.md` and
`server/utilities/caching.md`. Every row below was checked against that extract
and against the artifact itself; where the two disagreed, the artifact won.

The sibling document [`research/normative/mcp-2026-07-28.md`](research/normative/mcp-2026-07-28.md)
carries the envelope and the MRTR arm of the same artifact and nothing else. Its
§5 transcribes `ResultType`, `Result`, `EmptyResult`, `CacheableResult`,
`PaginatedResult`, `PaginatedRequestParams` and `Cursor`, and tabulates the six
cacheable results against their `extends` clauses; its §8 is Media types and URI
schemes and carries the five `ContentBlock` discriminator literals and `Role` in
prose rather than as declarations; its §10 is MRTR and carries
`InputRequiredResult`, `InputRequests` and `InputResponses`. Outside those three
sections it has no **declaration** of the ten `*ResultResponse` interfaces, of
any `ContentBlock` member, or of `ResourceContents`, `Tool`, `PromptMessage`,
`ServerResult` or `ToolAnnotations` — `Tool` and `Role` are named there in prose
and nowhere else, which is why the extract exists.

Two values disagree, and the artifact settles both. `mcp-2026-07-28.md` §1a says
*"The three list requests extend `PaginatedRequest`"* — **four** do
(`ListPromptsRequest`, `ListResourcesRequest`, `ListResourceTemplatesRequest`,
`ListToolsRequest`), and its own method table a few lines above gives all four
`params: PaginatedRequestParams`, so the sentence under-counts its own table;
4.10.2 uses the artifact's count. And §4.10 contradicted itself inside 4.10.2:
its `PaginatedResult` row named five results, `DiscoverResult` among them, while
a paragraph below said the four list results were the only ones carrying
`nextCursor`. `DiscoverResult extends CacheableResult` (artifact L678) and does
not extend `PaginatedResult`, so the paginated set is the four, and the row and
the paragraph now agree. The error was that one cell and nothing else: 4.10.3's
`DiscoverResult` table, 4.10.5's sequence row for that result, and this
subsection's own closing paragraph were already right, so an auditor has three
agreeing places to check the corrected cell against rather than one.

**Provenance, and its limit.** The extract records sha256
`742750af…2cd` for the artifact and states that it equals the digest recorded
for the transcription of this section. No digest of this section's source bytes
is stored anywhere in the repository, so that equality cannot be checked from
inside the tree: it is the extract's assertion, not a measurement this document
can reproduce. What *is* checkable is that every declaration the extract quotes
matches the artifact at the line range it gives, and that every value below
matches that artifact — so this section agrees with the 3,197-line `schema.ts`
the URL serves today. Whether its author read those same bytes, or an earlier
revision of `main` that was six lines longer, is not recoverable here. The one
count this section got wrong is a count of `extends` clauses, not of lines.

#### 4.10.1 Method to result

| Method | Result type | Payload |
| --- | --- | --- |
| `server/discover` | `DiscoverResult` | Supported versions, server capabilities, optional instructions |
| `completion/complete` | `CompleteResult` | One page of completion values |
| `prompts/get` | `GetPromptResult` \| `InputRequiredResult` | Messages, or an MRTR interim |
| `prompts/list` | `ListPromptsResult` | One page of prompts |
| `resources/list` | `ListResourcesResult` | One page of resources |
| `resources/templates/list` | `ListResourceTemplatesResult` | One page of templates |
| `resources/read` | `ReadResourceResult` \| `InputRequiredResult` | Resource contents, or an MRTR interim |
| `subscriptions/listen` | `SubscriptionsListenResult` | Empty body; identifies the stream it closes |
| `tools/call` | `CallToolResult` \| `InputRequiredResult` | Content blocks, or an MRTR interim |
| `tools/list` | `ListToolsResult` | One page of tools |

Exactly three of the ten may answer with `InputRequiredResult`, and then only
with `resultType: "input_required"`, which is what 4.7 already fixes. The other
seven have one result type each. `EmptyResult` — spelled `export type
EmptyResult = Result;` in the schema, the body that says success and carries no
data — is a member of the `ServerResult` union but is the declared result of
none of the ten, so a decoder must accept it as a legal result without
inventing a method for it.

`ServerResult`, verbatim, is the union of twelve types: `EmptyResult`,
`DiscoverResult`, `CompleteResult`, `GetPromptResult`, `ListPromptsResult`,
`ListResourceTemplatesResult`, `ListResourcesResult`, `ReadResourceResult`,
`SubscriptionsListenResult`, `CallToolResult`, `ListToolsResult` and
`InputRequiredResult`. `InputRequiredResult` is a member of that union and has
no method of its own; it is the `"input_required"` arm of the three rows above.

#### 4.10.2 Cacheable and paginated

Two base interfaces contribute fields, and neither has a wire discriminator: a
result is cacheable because it carries `ttlMs` and `cacheScope`, and paginated
because it carries `nextCursor`, not because it announced either. The schema
marks both for internal use, though not in the same way — `PaginatedResult` is
prefixed with a standalone `/** @internal */` (artifact L1067), while
`CacheableResult` carries `@internal` as a tag inside its own JSDoc block
(L1079).

| Base | Contributes | On which results |
| --- | --- | --- |
| `CacheableResult` | `ttlMs: number` `@minimum 0`, required; `cacheScope: "public" \| "private"`, required | **6** — `DiscoverResult`, `ListToolsResult`, `ListPromptsResult`, `ListResourcesResult`, `ListResourceTemplatesResult`, `ReadResourceResult` |
| `PaginatedResult` | `nextCursor?: Cursor`, optional; `Cursor = string` | **4** — `ListToolsResult`, `ListPromptsResult`, `ListResourcesResult`, `ListResourceTemplatesResult` |

The two sets are not the same set. `DiscoverResult` and `ReadResourceResult` are
cacheable and **not** paginated: each extends `CacheableResult` and nothing else
(artifact L678 and L1229). The four results that are paginated are exactly the
four that are also cacheable.

Those six cacheable results are exactly the six `server/utilities/caching.md`
requires servers to return caching hints for, so the schema's `extends` clauses
and the caching prose agree with no residue. `completion/complete`, `prompts/get`,
`tools/call` and `subscriptions/listen` are `extends Result` alone, and so is
the `input_required` arm.

Only the four list requests take a `cursor`, and only they are declared
`extends PaginatedRequest` with `params: PaginatedRequestParams`. A request and
its result are therefore paginated together or not at all: the four list methods
are paginated on both sides, and `resources/read` on neither — it returns a
sequence of contents with no `nextCursor`. `nextCursor` is declared exactly once
in the whole artifact, so it is the only pagination member on any of the ten.

#### 4.10.3 Payloads

Every row below sits on top of 4.6, so `resultType` is present unless the peer
is on an earlier revision, and `_meta` is optional unless the row says
otherwise. "Required" is the schema's own requiredness, not this library's
preference.

`DiscoverResult extends CacheableResult`

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `supportedVersions` | `string[]` | **Yes** | The client picks one for later requests |
| `capabilities` | `ServerCapabilities` | **Yes** | 4.8.2 — the member table, not a pointer to a shape 4.8 does not carry |
| `instructions` | `string` | No | Natural-language guidance for an LLM |
| `ttlMs` | `number` | **Yes** | 4.6 |
| `cacheScope` | `"public" \| "private"` | **Yes** | 4.6 |

`CompleteResult extends Result`

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `completion.values` | `string[]` | **Yes** | `@maxItems 100` |
| `completion.total` | `number` | No | Total options available; **may exceed** the number sent |
| `completion.hasMore` | `boolean` | No | More exist beyond this response even if `total` is absent |

`completion` itself is required, so `{"resultType":"complete"}` with no
`completion` is not a `CompleteResult`.

`GetPromptResult extends Result`

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `messages` | `PromptMessage[]` | **Yes** | One block each, not a block each carrying a list |
| `description` | `string` | No | |

`PromptMessage` is `{ role: Role; content: ContentBlock }`, both required.
`Role = "user" | "assistant"`. `content` is a **single** block, not a
sequence — the one place a `ContentBlock` stands alone.

`ListPromptsResult extends PaginatedResult, CacheableResult` carries
`prompts: Prompt[]` (required) and `nextCursor`.
`ListResourcesResult` carries `resources: Resource[]` (required) and
`nextCursor`. `ListResourceTemplatesResult` carries `resourceTemplates:
ResourceTemplate[]` (required) and `nextCursor`. `ListToolsResult` carries
`tools: Tool[]` (required) and `nextCursor`. All four also carry `ttlMs` and
`cacheScope`.

`ReadResourceResult extends CacheableResult`

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `contents` | `(TextResourceContents \| BlobResourceContents)[]` | **Yes** | No `nextCursor`; this is a sequence but not a page |

`contents` may hold more than one entry — `server/resources.md`: *"Servers **MAY**
return multiple resource contents in response to a single `resources/read`
request"* — and its two members are the text and binary forms of one resource,
chosen by which of `text` and `blob` is present. `server/resources.md` also puts
a **MUST NOT** on the empty case: *"Servers **MUST NOT** return an empty
`contents` array for a non-existent resource. An empty array is
ambiguous—it could mean the resource exists but has no content, or that it
doesn't exist at all."*

`CallToolResult extends Result` — not `CacheableResult`, so `tools/call` results
carry no `ttlMs` and no `cacheScope`.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `content` | `ContentBlock[]` | **Yes** | Unstructured result. Present and empty is well formed |
| `structuredContent` | `unknown` | No | **Any** JSON value, conforming to the tool's `outputSchema` if it has one |
| `isError` | `boolean` | No | Absent means false. A tool's own failure belongs here, not in a JSON-RPC error, so the model can see it |

`SubscriptionsListenResult extends Result` has no payload member at all: the
body is empty apart from `_meta`. Its `_meta` is the one place a result's
`_meta` is **required**, and the narrowed type requires one key of its own —
`SubscriptionsListenResultMetaObject` carries
`"io.modelcontextprotocol/subscriptionId": RequestId`, required, whose value is
the JSON-RPC `id` of the `subscriptions/listen` request and equals this
response's own `id`. The result is sent only on a graceful teardown; an abrupt
transport close carries no response.

`InputRequiredResult` is a result the artifact declares and none of the ten
methods above names as its own: it is the `"input_required"` arm of three of
them. Its payload members are `inputRequests?: InputRequests` and
`requestState?: string`, and the artifact types **both as optional** — while
requiring one of them in prose, in the type's own doc comment: *"At least one of
`inputRequests` or `requestState` MUST be present."* (artifact L575). The
requirement is therefore **established, not silent**, and a decoder that reads
only the two optional markers will admit a body the artifact forbids;
`src/mcp.zig` refuses one with `error.MissingField`. The two markers are how the
member set is written, not a statement that either may be absent.

#### 4.10.4 `ContentBlock`

`ContentBlock` is the union of five named members, discriminated by a `type`
string that is **required** in all five and is the member's only tag:

```ts
export type ContentBlock =
  TextContent | ImageContent | AudioContent | ResourceLink | EmbeddedResource;
```

| `type` | Interface | Fields beyond `type` |
| --- | --- | --- |
| `"text"` | `TextContent` | `text: string` (required); `annotations?`; `_meta?` |
| `"image"` | `ImageContent` | `data: string` (required, `@format byte`, base64); `mimeType: string` (required); `annotations?`; `_meta?` |
| `"audio"` | `AudioContent` | `data: string` (required, `@format byte`, base64); `mimeType: string` (required); `annotations?`; `_meta?` |
| `"resource_link"` | `ResourceLink` | `ResourceLink extends Resource`, so every `Resource` field, plus the `type` tag |
| `"resource"` | `EmbeddedResource` | `resource: TextResourceContents \| BlobResourceContents` (required); `annotations?`; `_meta?` |

`data` on the image and audio members is a base64 **string**, not bytes:
`server/prompts.md` states for image content that *"The image data **MUST** be
base64-encoded and include a valid MIME type"* and the same for audio, so a
decoder that validates the alphabet is reading a rule the specification states
and not one it inferred from `@format byte`.

Two consequences a decoder has to get right. `ResourceLink` is a `Resource`
with a `type` added, so a `Resource` inside `resources/list` has **no** `type`
member while a `ResourceLink` inside a content block does — the same underlying
object appears on the wire with and without the tag depending on which result
carries it. And `EmbeddedResource.resource` and `ReadResourceResult.contents`
are unions with **no discriminator at all**: see 4.10.6.

`Resource`, `ResourceTemplate`, `Prompt`, `Tool`, `PromptArgument`, `Icon` and
`Annotations` are the element types, and their member sets are fixed. `Tool`
carries `inputSchema` (required, and its root `type` is the literal `"object"`)
and optional `outputSchema`, both open JSON Schema objects rather than library
types, and `ToolAnnotations` is five optional members. `Resource` and
`ResourceTemplate` and `Prompt` and `Tool` all take `name` from
`BaseMetadata` plus optional `title`, and optional `icons?: Icon[]`.

#### 4.10.5 Caller-owned sequences

Which payloads are a sequence and which are a single value, because the decode
shapes differ and the difference is not visible from the method name. In this
library a sequence is an `out: []T` slice the caller supplies plus a returned
count, and a single value is a struct in the returned result; a `[]T` the
decoder allocates is not available under 2.

| Result | Sequence member | Element |
| --- | --- | --- |
| `DiscoverResult` | `supportedVersions` | `string` |
| `CompleteResult` | `completion.values` | `string`, capped at 100 |
| `GetPromptResult` | `messages` | `PromptMessage`, each holding one `ContentBlock` |
| `ListPromptsResult` | `prompts` | `Prompt` |
| `ListResourcesResult` | `resources` | `Resource` |
| `ListResourceTemplatesResult` | `resourceTemplates` | `ResourceTemplate` |
| `ReadResourceResult` | `contents` | `TextResourceContents \| BlobResourceContents` |
| `CallToolResult` | `content` | `ContentBlock` |
| `ListToolsResult` | `tools` | `Tool` |
| `SubscriptionsListenResult` | none | — |

`nextCursor` is not a sequence: it is one optional string, and it is the only
pagination member on any of the ten. Two of these rows are the ones a decoder
cannot get right from the field name alone: `contents` is a sequence with no
`nextCursor`, and `content` is a sequence of a tagged union while
`PromptMessage.content` is one block of the same union.

Nesting below the top level: `Prompt.arguments?: PromptArgument[]`,
`Icons.icons?: Icon[]`, `Icon.sizes?: string[]` and `Annotations.audience?:
Role[]` are sequences inside an element, so an element type either carries its
own `out` slice or gives up on those members. `Tool.inputSchema` and
`Tool.outputSchema` are open JSON Schema objects and are not library-typed
sequences at all.

#### 4.10.6 Open sets, closed sets, and one silence

The rule from `AGENTS.md` — a decoder that accepts a member has to be able to
write it back — bites hardest here, so which sets are open has to be stated
rather than left to the implementer. Two questions have to be kept apart, because
the artifact answers them differently and an earlier revision of this table ran
them together: **is a set of values closed** — is `type` permitted to be anything
— and **is a set of members closed** — may a key the type does not name appear.
The first is answered by a literal union, and where the union is closed the
generated `schema.json` says so on the wire: the five `ContentBlock` arms emit
`"type": {"const": "text"}` … `{"const": "resource"}` and `LoggingLevel` emits an
`enum` of eight literals. The second is answered by `additionalProperties`, and
**the protocol never uses it**: zero occurrences in the 3,197-line `schema.ts`, and
twenty in the generated `schema.json` with none of them `false` — five bare `{}`
and fifteen typed maps. Under draft 2020-12 an absent keyword permits undeclared
properties, so no object type in this schema is closed. Measured over the
commit-pinned artifacts in
[`research/normative/mcp-2026-07-28-schema.md`](research/normative/mcp-2026-07-28-schema.md)
§9.

| Set | Status | Evidence |
| --- | --- | --- |
| Members of any result object | **Open** | `Result` declares `[key: string]: unknown`. `basic/index.md` §Result Responses: *"The `result` **MAY** follow any JSON object structure."* |
| `ContentBlock.type` | **Closed** — five literals | The union declaration above: no `\| string` arm, and the *"this is not a closed set"* sentence appears only on `ClientCapabilities` and `ServerCapabilities`, so the artifact's own idiom marks an open discriminator explicitly and marks this one closed by omission. The generated `schema.json` confirms it at the wire level, emitting a `const` per arm |
| Members of `TextContent`, `ImageContent`, `AudioContent`, `EmbeddedResource`, `ResourceContents`, `Resource`, `ResourceTemplate`, `Prompt`, `Tool`, `PromptArgument`, `Icon`, `Annotations`, `ToolAnnotations` | **Declared** member sets — closing **NOT ESTABLISHED** | Each declares the members 4.10.4 and 4.10.5 tabulate and no index signature, which fixes the declared set. It does not close it: none of these thirteen carries `additionalProperties` in the generated `schema.json`. The open members are separate facts, not consequences: `_meta` is a `MetaObject = Record<string, unknown>`, and `Tool` carries `inputSchema` and `outputSchema`, each `{ …; [key: string]: unknown }`, which is why 4.10.4 and 4.10.5 treat those two as open JSON Schema rather than library types |
| `Role`, `Icon.theme`, the `cacheScope` literal union | **Closed** | Literal unions. The schema writes `cacheScope: "public" \| "private"` **inline** (artifact L1109) and declares no `CacheScope` alias — the name belongs to `mcp.CacheScope` in `src/mcp.zig`, not to the artifact. 4.6 for the field |
| `InputRequests` keys | **Open** — server-assigned | 4.7 |
| `resultType` | **Closed set, open carrier** | `"complete" \| "input_required" \| string` admits any string, and `basic/index.md`: *"A `resultType` of any value unrecognized by the client **MUST** be considered invalid."* |
| Members of `ClientCapabilities` and `ServerCapabilities` | **Open** — by prose, not by signature | Neither interface declares an index signature, and both carry the *"not a closed set"* sentence. 4.8.3 |
| Nested objects inside a capability — `sampling`, `elicitation`, `prompts`, `resources`, `tools` | **Declared** member sets, **open** `JSONObject` values; closing **NOT ESTABLISHED** | Each declares exactly the members 4.8.1 and 4.8.2 tabulate and no index signature; `experimental`, `extensions` and the `JSONObject`-typed members are open maps by type. As above, declaring is not closing, and none of the five carries `additionalProperties` either. 4.8.3 |

The first row is the one that decides the encoding. A `tools/call` result the
library accepts may carry a key the shape does not name, because the source
says a result may follow any object structure, and 2 says
`encode(decode(b)) == b` for every accepted input. So a key a result type does
not model is carried as the borrowed lexeme it arrived as, which is what
`bridge.Envelope.meta` and `bridge.OutcomePayload` already do. This is the
mistake that re-opened a loss that had been closed for the life of the
repository, and it is the reason no result payload in 4.10.3 is transcribed as
a closed struct.

The member-set rows say **declared**, not closed, and that is the whole difference
between them and the first row. The first row rests on a positive statement — a
result *may* follow any object structure — so accepting an undeclared key is
following the source. The others rest on an absence: the source never says a
member set is closed, and the census above shows it never writes the keyword that
would say so. A decoder is therefore free to model exactly the declared members,
and if it also accepts an undeclared one it must write it back under 2. This
library does not reject one — there is no source clause to reject it against —
and it does not *claim* one either: the member tables in 4.8 and 4.10.3 are the
declared set, and nothing in `src/` reads a member from a nested object that a
table does not name.

**What the source does not say.** No primary source states what a receiver
does with a `ContentBlock` whose `type` is not one of the five. The schema
declares a closed union and says nothing further. Every specification page that
carries one of these results was checked for such a rule — `basic/index.md`,
`basic/versioning.md`, `server/tools.md`, `server/resources.md`,
`server/prompts.md` and `server/discover.md` — and none of them mentions an
unrecognised content type. The one clause in the protocol about ignoring what is
not recognised — *"the server **SHOULD** ignore any information it does not
recognize or need"* — is scoped to the `inputResponses` object in **request**
params, and does not reach a result's content.

The source's own idiom points one way and the risk points the other, so this is
recorded rather than resolved. The idiom: where a discriminator is meant to be
open, the schema says so explicitly, and `ResultType` is the one place it does —
it carries a `| string` arm and the prose resolves it in the same breath.
`ContentBlock` has neither. The risk: a peer may be speaking a later revision,
and 2 requires decoding to be total rather than panicking.

`mcp.ResultType` is the precedent already in the tree for the representation:
the wire string is kept as borrowed text in `ResultType.value`, and the set the
source defines is exposed separately through `known()`. A `ContentBlock` decoder
that keeps the `type` lexeme and exposes the five-member set the same way
satisfies both halves — it writes back anything it accepted, and it does not
claim a value the source does not state. Whether an unrecognised `type`
additionally yields `DecodeError.UnknownTag`, which is what 2 says it does for
an unknown enum tag, or is carried as the lexeme with the decision left to the
caller as `ResultType` does, is a **decision** for
[`SPEC-DECISIONS.md`](SPEC-DECISIONS.md) and not a transcription. 4.10 states
the two sets and the evidence; it does not pick.

#### 4.10.7 Where the source is silent

Every row below is `NOT ESTABLISHED` in the preamble's sense: no primary source
defines it, this library does not invent one, and the corresponding case is an
explicit decode failure rather than a guess.

- **A `TextResourceContents` carrying `blob`, or a `BlobResourceContents`
  carrying `text`.** The two differ only by which required member is present,
  so an object with both satisfies both union members and the source does not
  say which to read. Both of the places these appear — `ReadResourceResult
  .contents` and `EmbeddedResource.resource` — depend on that choice.
- **A block with neither `text` nor `blob`**, which is well-formed JSON and
  matches neither member.
- **An array element that is not an object at all.** A JSON string in
  `tools/call`'s `content` is not one of the five.
- **The bound on `nextCursor`, and on `supportedVersions`, `prompts`,
  `resources`, `resourceTemplates`, `tools`, `messages` and `contents`.** Only
  `completion.values` carries a numeric bound, `@maxItems 100`. The rest are
  bounded by whatever the transport imposes.
- **Whether `annotations.priority` is an integer or a real.** The schema types
  it `number` with `@minimum 0` and `@maximum 1`; it does not narrow to an
  integer, and the `Resource` example in `server/resources.md` uses `0.8`.
- **Any requirement on the order of `content`.** The schema does not constrain
  it, and `server/tools.md` asks servers to return tools in a deterministic
  order for caching, which is guidance rather than a wire rule.
- **A member no type names, on an object that is not a result.** A capability
  object, a nested `sampling` / `elicitation` / `prompts` / `resources` / `tools`
  object, a notification params object, or a `TextContent`: the schema types none
  of them closed, and no primary source says what a receiver does with a key it
  does not recognise. This is the mirror image of the first row, and it is a
  silence in the other direction — the first row has *"MAY follow any JSON object
  structure"* to lean on and this has nothing.

### 4.11 Notification payloads

4.4 names the notification methods. This section gives each one the body it
carries, on the same terms as 4.10: the schema's own requiredness, not this
library's preference.

Transcribed from `schema/2026-07-28/schema.ts`, which
[`research/normative/mcp-2026-07-28-schema.md`](research/normative/mcp-2026-07-28-schema.md)
§10 reproduces value-by-value with artifact line ranges: the notification base
chain, `NotificationMetaObject`, `RequestMetaObject`'s `progressToken`,
`ProgressToken`, `SubscriptionFilter`, `LoggingLevel`, all eight notification
interfaces, the five params interfaces they name, and both notification unions.
The sibling
[`research/normative/mcp-2026-07-28.md`](research/normative/mcp-2026-07-28.md)
§1b tabulates the same eight one line each; its table lists the payload members
and agrees with every declaration below, but states no requiredness, so this
section and the §10 declarations are where the two required-vs-optional `params`
rows and the inherited `_meta` are established.

#### 4.11.1 The base, and the inherited `_meta`

Every notification is a `JSONRPCNotification`: `jsonrpc: "2.0"`, a `method`
literal, and **no `id`** — which is the whole difference from a request and the
reason a notification never correlates with a response.

`NotificationParams` has exactly one member and it is optional:
`_meta?: NotificationMetaObject`. All eight shapes inherit it, so
`{"method":"notifications/tools/list_changed"}` with no `params` at all is well
formed, and so is `params` present but empty. A notification's `_meta` is
**open** — `NotificationMetaObject extends MetaObject`, and `MetaObject =
Record<string, unknown>` — and its one named key,
`io.modelcontextprotocol/subscriptionId`, is optional in the type but required by
the artifact's own doc comment *conditionally*: a server MUST include it on
every notification delivered via a `subscriptions/listen` stream, and it is
absent on a notification not delivered on one, which is why the type makes it
optional. That is established, not a silence. 4.3 carries the key.

The open `{ [key: string]: any }` on the internal `Notification` base is a
separate layer: it exists so an unofficial extension can add `params` keys
without touching `NotificationParams`, and each of the eight narrows `params`
again in its own declaration.

#### 4.11.2 `progressToken`, the two declarations, and why they differ

`ProgressToken = string | number`. It appears twice in the artifact and the two
declarations have **opposite requiredness**, which reads like a contradiction and
is not:

| Where | Declaration | Requiredness | Meaning |
| --- | --- | --- | --- |
| `RequestMetaObject.progressToken` — a **`_meta` key on a request** | `progressToken?: ProgressToken` (artifact L67) | Optional | An **opt-in**: if specified, the caller requests out-of-band progress for that request. The receiver is not obligated to provide it |
| `ProgressNotificationParams.progressToken` — a **payload member of the notification** | `progressToken: ProgressToken` (artifact L1013) | Required | The token to associate the notification with, and it is not in `_meta` at all |

The second is required precisely because the first is opt-in: a well-formed
`notifications/progress` can only exist for a request that carried the token, so
the payload member must echo it. Nothing needs fixing and nothing needs
relocating; 4.3 already lists `progressToken` as a bare `_meta` key on the
request side, and this section is the only place the notification-side member is
stated.

The generated `schema.json` says the same thing in its own `required` arrays, so
the difference is not a TypeScript optionality marker that the wire might soften:
`RequestMetaObject.required` is
`["io.modelcontextprotocol/clientCapabilities","io.modelcontextprotocol/protocolVersion"]`
and does **not** contain `progressToken`, while
`ProgressNotificationParams.required` is `["progress","progressToken"]`. Two
required members there, so `notifications/progress` cannot be well formed without
echoing a token it was given.

#### 4.11.3 The eight shapes

Every row sits on 4.11.1, so every one has the optional inherited `_meta`. `params`
requiredness is the schema's: five rows required, three optional.

| Method | Type | `params` | Payload members beyond `_meta` |
| --- | --- | --- | --- |
| `notifications/cancelled` | `CancelledNotification` | **`CancelledNotificationParams`**, required | `requestId: RequestId` **required**; `reason?: string` |
| `notifications/progress` | `ProgressNotification` | **`ProgressNotificationParams`**, required | `progressToken: ProgressToken` **required**; `progress: number` **required**; `total?: number`; `message?: string` |
| `notifications/message` | `LoggingMessageNotification` | **`LoggingMessageNotificationParams`**, required | `level: LoggingLevel` **required**; `data: unknown` **required**; `logger?: string`. **@deprecated** (SEP-2577) |
| `notifications/resources/updated` | `ResourceUpdatedNotification` | **`ResourceUpdatedNotificationParams`**, required | `uri: string` **required**, `@format uri` |
| `notifications/subscriptions/acknowledged` | `SubscriptionsAcknowledgedNotification` | **`SubscriptionsAcknowledgedNotificationParams`**, required | `notifications: SubscriptionFilter` **required** |
| `notifications/resources/list_changed` | `ResourceListChangedNotification` | `NotificationParams`, **optional** | none |
| `notifications/tools/list_changed` | `ToolListChangedNotification` | `NotificationParams`, **optional** | none |
| `notifications/prompts/list_changed` | `PromptListChangedNotification` | `NotificationParams`, **optional** | none |

Counts read off the artifact rather than the table above: eight interfaces
extend `JSONRPCNotification`; five declare a named params interface and carry a
required `params`; three carry `params?: NotificationParams` and declare none.
`ServerNotification` is the union of all eight and `ClientNotification` is
`CancelledNotification` alone, so `notifications/cancelled` is the only one
that travels both directions and it is in both unions.

Four members in that table carry a type but no constraint, and a decoder must
not narrow them: `progress` and `total` are `number` with no integer
restriction and no `@minimum`; `data` is `unknown` and the artifact says *"Any
JSON serializable type is allowed here"*, so a string and an object are both
legal; `uri` carries `@format uri`, a JSDoc hint with no pattern or format
constraint in the type. Three of the four are **required** (`progress`, `data`,
`uri`); `total` is optional. `LoggingLevel` is the one closed literal set among
them — `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`,
`emergency`, mapping to RFC-5424 syslog severities, with no `| string` arm — and
it is the same union the request's `io.modelcontextprotocol/logLevel` uses.

Two normative requirements in this section are in the artifact's prose rather
than in a type, and both are established:

- `CancelledNotificationParams.requestId` MUST *"correspond to the ID of a
  request the client previously issued"*, and on stdio a server sends this
  notification **solely** to terminate a `subscriptions/listen` stream.
  Servers MUST NOT use it to cancel any other request.
- `SubscriptionsAcknowledgedNotification` MUST be the first message the server
  sends carrying that subscription's
  `io.modelcontextprotocol/subscriptionId`, and no notification on the
  subscription may precede it — ordered per subscription ID, not per channel,
  so messages from other subscriptions may be interleaved before it.

#### 4.11.4 `SubscriptionFilter`

The gate on a `subscriptions/listen` stream, and the payload of
`notifications/subscriptions/acknowledged` — the same type in both places. Four
members, all optional:

| Member | Type | Opts into |
| --- | --- | --- |
| `toolsListChanged` | `boolean?` | `notifications/tools/list_changed` |
| `promptsListChanged` | `boolean?` | `notifications/prompts/list_changed` |
| `resourcesListChanged` | `boolean?` | `notifications/resources/list_changed` |
| `resourceSubscriptions` | `string[]?` | `notifications/resources/updated` for those URIs. Replaces the removed `resources/subscribe` RPC |

`SubscriptionsListenRequestParams.notifications` is **required**, so `{}` — an
empty filter, meaning nothing opted in — is well formed while omitting the
member is not. Each type is **opt-in** and the server **MUST NOT** send a
notification type the client has not requested. The acknowledged notification
reports back a *subset*: *"Only includes notification types the server actually
supports"*, so an omitted member in that reply means unsupported rather than
not requested.

#### 4.11.5 Where the notification source is silent

Same sense as 4.10.7 — no primary source defines these, so this library does
not invent a value and the case is an explicit decode failure:

- **A required member of a notification params interface with the wrong type.**
  The artifact constrains none of `progress`, `data`, `uri` or `reason` beyond
  its TypeScript type, and carries no numeric bound on any of them.
- **A notification with an `id`.** `JSONRPCNotification` declares none, so an
  `id` is not part of any of the eight; the source says nothing about a peer
  that sends one anyway.
- **The bound on `resourceSubscriptions`.** `string[]` with no `@maxItems`.
- **Whether `params: null` is the same as omitting it.** The artifact types
  `params?` as an object or absent and does not say.
- **A member no notification params interface names.** None of the six declares
  an index signature, which fixes the *declared* member set, and the generated
  `schema.json` gives none of them an `additionalProperties`, which would be the
  construct that closes one. 4.10.6 has the census. So an undeclared key in
  `params` is not an error by any stated rule and is not forbidden by any
  either — the same silence as the last bullet of 4.10.7, in the same direction.
  `_meta` is the exception and is **open** by type:
  `NotificationMetaObject extends MetaObject`, `MetaObject = Record<string, unknown>`.

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

#### 6.5.1 The `acp` capability — RFD only, in no published schema

The mcp-over-acp binding advertises itself with an `acp` capability. This
library does **not** invent it, and the distinction below is the reason: the
`acp` key appears in **neither** released ACP schema. Verified on the published
artifacts: the literal `"acp"` occurs **zero** times in `schema/v1/schema.json`
and **zero** times in `schema/v2/schema.json`, and neither `meta.json` lists any
`mcp/*` method. Full transcription and the RFD fragments:
[`research/normative/acp-v1-v2.md`](research/normative/acp-v1-v2.md) §10e.

| | Published v1 | Published v2 draft | RFD proposal |
| --- | --- | --- | --- |
| Path | `agentCapabilities.mcpCapabilities` | `capabilities.session.mcp` | adds `acp` to whichever the version has |
| Declared members | `http` `boolean` d=`false`; `sse` `boolean` d=`false`; `_meta` | `stdio` `McpStdioCapabilities` \| `null`; `http` `McpHttpCapabilities` \| `null`; `_meta` | `acp` — **not in the schema** |
| `acp` present? | **NO** | **NO** | v1 `boolean`; v2 presence object |

So the two paths this library carries — `bridge.capability_path` — are:

| Version | Path | Shape | Absent means |
| --- | --- | --- | --- |
| v1 | `mcpCapabilities.acp` | `boolean` | `false`. Verbatim from the RFD: *"Omission is equivalent to `false`."* |
| v2 | `capabilities.session.mcp.acp` | **object presence**, not a boolean | Not advertised. Verbatim: *"omission or `null` means support is not advertised, and `{}` advertises support"* |

v2 removes the boolean form entirely: the same key means different things at the
two revisions, and a decoder that reads it as a boolean at v2 would misread
`{}`. That is the same reason this library pins one revision rather than
branching on a flag, which is 8's rule applied to a capability.

Two further facts that constrain what a conforming peer can do today. The
`McpServer` union in the published v2 schema has exactly the branches `http`,
`stdio` and an `other` catch-all, with **no `acp` branch** — so the RFD's
`{"type":"acp", …}` declaration falls through to `other` rather than matching a
declared arm. And v2 renamed `mcpCapabilities` wholesale to
`capabilities.session.mcp`; the v1 string does not occur in `schema/v2/schema.json`
at all.

**Source conflict, both values stated.** The RFD specifies the `acp` capability
key and the `{"type":"acp"}` server declaration; the released schemas declare
neither. These are a draft RFD and released schemas, and they disagree today.

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

### 7.1 Server declaration

The client checks the peer's ACP MCP capability, then includes a declaration in
a session setup request. `session/new` parameters are the RFD's example:

```json
{ "type": "acp", "name": "project-tools", "serverId": "project-tools:7a72" }
```

| Field | Type | In the RFD example | Obligation the RFD states |
| --- | --- | --- | --- |
| `type` | `"acp"` | yes | The discriminator. Declared in no published schema — see the limitation below |
| `name` | string | yes | None stated in prose |
| `serverId` | string | yes | Provider-generated and opaque. *"A server ID identifies one registration for the lifetime of the ACP connection and must not be rebound to a different registration, including after removal."* Distinct offerings use distinct ids |

**Requiredness is `NOT ESTABLISHED`.** The RFD shows all three in a worked
example and states obligations for `serverId`, but it declares no `required`
list and there is no published schema arm to carry one — so this document does
not mark any of the three required. A decoder accepts an object carrying the
three it recognises and writes back what it accepted; it does not refuse one
missing a member on the strength of an example.

Those three values are `bridge.server_declaration`. The provider must be ready
to serve requests when it publishes the declaration, and an agent may invoke
tools or discover the server before returning the ACP session id. One
registration may be offered to several ACP sessions, and omitting a
previously-declared server from a later setup request does not revoke a
registration another session is using.

**Published-schema limitation.** `type: "acp"` is in **no released ACP
schema**. The literal `"acp"` occurs zero times in both `schema/v1/schema.json`
and `schema/v2/schema.json`. Concretely, in the published v2 schema the
`McpServer` union has exactly three branches — `http`, `stdio` and an `other`
catch-all — and no `acp` branch, so this declaration currently validates only
by falling through to `other`. A peer built against the released schemas will
accept the object and will not give it ACP transport semantics. This library
encodes the declaration and says so; it does not claim the released schema
declares it.

### 7.2 Capability advertisement

A peer accepts `mcp/message` only if it has advertised the `acp` capability,
and the advertisement is **RFD-only**: it is in neither released ACP schema.
The two paths and their shapes, and the verbatim rules for what an absent value
means, are in **6.5.1**. In short: v1 `mcpCapabilities.acp` is a `boolean` where
omission means `false`; v2 `capabilities.session.mcp.acp` is a **presence
object** where omission or `null` means not advertised and `{}` means supported.
v2 removed the boolean form, so the same key has two different types across the
revisions.

These are ACP capabilities, separate from the MCP client capabilities carried on
each request (4.8.1) — and separate again from what the capability promises: it
advertises the MCP **transport**, not every optional MCP feature and not a
guarantee that every operation can be cancelled. MCP discovery and per-request
capabilities describe the supported features. An intermediary advertises support
only when its whole downstream chain can consume the transport, and a proxy
that provides no adaptation preserves its successor's capabilities rather than
adding this one unconditionally.

### 7.3 The `mcp/message` envelope

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
  The schema artifact this document's §4.8, §4.10 and §4.11 are transcribed from
  is also pinned at the immutable commit
  `3098fe94caa1b9e0afaaa6d30e040b61d5802471`, which serves byte-identical content
  to the `main` ref — same 98,426 bytes, same 3,197 lines, same sha256
  `742750af…2cd`. Fetch the commit-pinned URL to re-verify any `artifact L…`
  line range; `main` is a moving branch. Full provenance and the digest
  arithmetic:
  [`research/normative/mcp-2026-07-28-schema.md`](research/normative/mcp-2026-07-28-schema.md).
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
