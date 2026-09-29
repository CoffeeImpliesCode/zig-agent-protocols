# Agent-UI protocol wire values: AG-UI 1.0, A2UI v1.0, MCP Apps 2026-01-26

Verbatim transcription of the enumerable wire values of three agent-UI protocols,
each from its own primary machine-readable artifact. Nothing here is summarised to
a count: where a source enumerates a set, every member is written out. Values are
copied from the source artifacts, not from prose describing them.

- Research date: 2026-09-29
- Contract: [`../../PROTOCOLS.md`](../../PROTOCOLS.md) — the normative wire values
- Evidence: this file, transcribed from the artifacts named per table

The three protocols are independent. They share no wire namespace, no version
scheme, and no discovery mechanism. AG-UI streams events over HTTP; A2UI ships
component trees inside A2A messages; MCP Apps is an MCP extension whose transport
is the MCP host's own. Where two of them use a similar name — `protocolVersion`,
`metadata`, an extension identifier — the spellings are the same string and the
meanings are unrelated.

## Artifact provenance

| # | Artifact | URL | What it established |
| --- | --- | --- | --- |
| 1 | AG-UI 1.0 normative JSON Schema (draft 2020-12), 2838 lines | `https://ag-ui.com/spec/1.0/schema.json` | `/$defs/EventType.enum` (31 values), `/$defs/Event.oneOf` (31 `$ref` arms, same order), the `BaseEvent`/`Attributable` mixins, `Metadata`, `RunAgentInput`, `RunFinishedOutcome`, `Interrupt`, `ResumeEntry`, `SubagentFinishedOutcome`, `TokenUsage`, `AgentCapabilities` |
| 2 | AG-UI events index | `https://docs.ag-ui.com/spec/1.0/events/index.md` | The eight families, the producer-requirement rule, the consumer-acceptance rule |
| 3 | AG-UI run lifecycle | `https://docs.ag-ui.com/spec/1.0/events/lifecycle.md` | The stream-open rule, the stream-close rule, the step-closure rule, token-usage accounting, several-runs-on-one-stream |
| 4 | AG-UI `RunAgentInput` | `https://docs.ag-ui.com/spec/1.0/basic/run-input.md` | Per-field obligations, the `protocolVersion` OPTIONAL rule, tools/context/state/forwardedProps/resume semantics |
| 5 | AG-UI streaming patterns | `https://docs.ag-ui.com/spec/1.0/basic/patterns/streaming.md` | Open-content-close discipline, chunked-form spelling, which events close a chunk stream |
| 6 | AG-UI interrupt/resume patterns | `https://docs.ag-ui.com/spec/1.0/basic/patterns/interrupt-resume.md` | The interrupt/resume contract; `Interrupt.reason` is an open string with no enumeration |
| 7 | AG-UI metadata | `https://docs.ag-ui.com/spec/1.0/basic/metadata.md` | The reserved `ag-ui` key, merge rules, per-family merge targets |
| 8 | AG-UI versioning | `https://docs.ag-ui.com/spec/1.0/basic/versioning.md` | The two `protocolVersion` fields, `MAJOR.MINOR` comparison, downgrade rules, retired shapes |
| 9 | AG-UI HTTP+SSE transport | `https://docs.ag-ui.com/spec/1.0/basic/transports/http-sse.md` | LF framing, one event per `data:` payload, `text/event-stream`, error handling, absence of resumption |
| 10 | AG-UI HTTP+Protobuf transport | `https://docs.ag-ui.com/spec/1.0/basic/transports/http-protobuf.md` | `Accept` negotiation, `application/vnd.ag-ui.event+proto`, the 4-byte big-endian length prefix, frame abutment |
| 11 | A2UI v1.0 candidate specification | `https://a2ui.org/specification/v1.0-a2ui/` | Status line, envelope message structure, the `createSurface`/`root` prose, UI composition model, UAX #31 rules, the reserved `@` prefix, capability and metadata key names, catalog resolution order |
| 12 | A2UI agent-to-renderer schema | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/agent_to_renderer.json` | The six-member root `oneOf`, per-message `required`, inner field types, `Component`/`ComponentsList` |
| 13 | A2UI common types schema | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/common_types.json` | The 21 `$defs` names, `ChildList`, the five `Dynamic*` types, `DataBinding`, `Surface`, `IndexSystemFunction`, `Action`, `FunctionCall`, `FunctionResponse`, `Extensions` |
| 14 | A2UI renderer-to-agent schema | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/renderer_to_agent.json` | `minProperties`/`maxProperties` 2, the four `oneOf` members, the validation-error code enum |
| 15 | A2UI A2A extension specification | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/extensions/a2a/docs/a2ui_extension_specification.md` | Extension URI, `X-A2A-Extensions`, `application/a2ui+json`, the renderer/agent capability key names, AgentCard placement |
| 16 | A2UI renderer capabilities schema | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/renderer_capabilities.json` | `a2uiRendererCapabilities` shape |
| 17 | A2UI agent capabilities schema | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/agent_capabilities.json` | `v1.0.supportedCatalogIds`, `v1.0.acceptsInlineCatalogs` |
| 18 | A2UI renderer data model schema | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/renderer_data_model.json` | `a2uiRendererDataModel` shape |
| 19 | A2UI basic catalog | `https://raw.githubusercontent.com/a2ui-project/a2ui/main/catalogs/basic/v1/catalog.json` | The well-known `catalogId` and `$id` |
| 20 | MCP Apps SEP-1865, Stable `2026-01-26` | `https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx` | The whole MCP Apps section: `ui://`, MIME type, extension id, `UIResourceMeta`, `McpUiResourceCsp`, the mandatory default CSP, every `ui/*` name, `HostCapabilities`, `HostContext`, `McpUiAppCapabilities`, the `visibility` enum, the deprecated key, the sandbox-proxy rules |
| 21 | AG-UI 1.0 deprecation registry | `https://raw.githubusercontent.com/ag-ui-protocol/ag-ui/main/DEPRECATIONS.md` | The five retired `THINKING_*` events and their `REASONING_*` replacements, the retired `binary` content part, the retired `subAgents` capability key, the shim locations, the 2027-09-17 expiry |

Spec header for artifact 20, verbatim: `# SEP-1865: MCP Apps: Interactive
User Interfaces for MCP` · `**Track:** Extensions` · `**Status:** Stable
(2026-01-26)` · `**Created:** 2025-11-21`.

Status line for artifact 11, verbatim: `**Version:** 1.0 **Status:** Candidate
**Created:** Nov 20, 2025 **Last Updated:** Jun 8, 2026`.

**AG-UI source precedence, verbatim from artifact 4's site:** *"If the two ever
disagree about structure, the schema wins and this document has a bug."* The
concepts pages under `docs.ag-ui.com/concepts/` are not in the `spec/1.0` tree and
are non-normative; where they disagree with `schema.json`, this file follows the
schema and records the disagreement.

---

## AG-UI 1.0

## AG-UI event `type` values — 31 values, eight families

Source: `https://ag-ui.com/spec/1.0/schema.json` — `/$defs/EventType.enum` and
`/$defs/Event.oneOf` (31 `$ref` arms, in the same order as the enum). Family
grouping: `https://docs.ag-ui.com/spec/1.0/basic/index.md` §"The events" and
`https://docs.ag-ui.com/spec/1.0/events/index.md`.

Producer-requirement legend, verbatim from `events/index.md`: *"Only the run
lifecycle is mandatory for a producer — every other family is a feature it emits
when it has something to say with it. A consumer MUST accept all of them: an
event from a family a consumer has no use for is still a well-formed event, not
unrecognised material."*

### Runs and steps (pattern: lifecycle)

Source: `schema.json` `/$defs/EventType.enum`; `https://docs.ag-ui.com/spec/1.0/events/lifecycle.md`.

| # | `type` | Required for producer | Basis, verbatim |
| --- | --- | --- | --- |
| 1 | `RUN_STARTED` | **yes** | `lifecycle.md`: "A stream MUST begin with `RUN_STARTED` or `RUN_ERROR`." |
| 2 | `RUN_FINISHED` | **yes, if the run did not fail** | "A run ends with `RUN_FINISHED` or `RUN_ERROR`" |
| 3 | `RUN_ERROR` | **yes, in place of `RUN_FINISHED`** | same |
| 4 | `STEP_STARTED` | no | schema: "for producers whose frameworks have a step concept worth surfacing" |
| 5 | `STEP_FINISHED` | no | must close an opened step; no step need ever be opened |

Note: `STEP_STARTED` and `STEP_FINISHED` sit inside the nominally mandatory
lifecycle family but are not themselves mandatory.

### Text messages (pattern: streaming) — none required

Source: `schema.json` `/$defs/EventType.enum`.

| # | `type` |
| --- | --- |
| 6 | `TEXT_MESSAGE_START` |
| 7 | `TEXT_MESSAGE_CONTENT` |
| 8 | `TEXT_MESSAGE_END` |
| 9 | `TEXT_MESSAGE_CHUNK` |

### Tool calls (pattern: streaming) — none required

Source: `schema.json` `/$defs/EventType.enum`.

| # | `type` |
| --- | --- |
| 10 | `TOOL_CALL_START` |
| 11 | `TOOL_CALL_ARGS` |
| 12 | `TOOL_CALL_END` |
| 13 | `TOOL_CALL_CHUNK` |
| 14 | `TOOL_CALL_RESULT` |

### Reasoning (pattern: streaming) — none required

Source: `schema.json` `/$defs/EventType.enum`.

| # | `type` |
| --- | --- |
| 15 | `REASONING_START` |
| 16 | `REASONING_MESSAGE_START` |
| 17 | `REASONING_MESSAGE_CONTENT` |
| 18 | `REASONING_MESSAGE_END` |
| 19 | `REASONING_MESSAGE_CHUNK` |
| 20 | `REASONING_END` |
| 21 | `REASONING_ENCRYPTED_VALUE` |

### State (pattern: snapshot–delta) — none required

Source: `schema.json` `/$defs/EventType.enum`.

| # | `type` |
| --- | --- |
| 22 | `STATE_SNAPSHOT` |
| 23 | `STATE_DELTA` |
| 24 | `MESSAGES_SNAPSHOT` |

### Activity (pattern: snapshot–delta) — none required

Source: `schema.json` `/$defs/EventType.enum`.

| # | `type` |
| --- | --- |
| 25 | `ACTIVITY_SNAPSHOT` |
| 26 | `ACTIVITY_DELTA` |

### Subagents (pattern: lifecycle) — none required

Source: `schema.json` `/$defs/EventType.enum`.

| # | `type` |
| --- | --- |
| 27 | `SUBAGENT_STARTED` |
| 28 | `SUBAGENT_FINISHED` |
| 29 | `SUBAGENT_ERROR` |

### Passthrough (pattern: standalone) — none required

Source: `schema.json` `/$defs/EventType.enum`.

| # | `type` |
| --- | --- |
| 30 | `RAW` |
| 31 | `CUSTOM` |

Total: 5 + 4 + 5 + 7 + 3 + 2 + 3 + 2 = **31**, matching the enum length and the
`Event.oneOf` arm count.

## AG-UI 1.0 retired 0.x event names — the rename map

Source: `https://docs.ag-ui.com/spec/1.0/changelog.md` §"Major changes", item 4
(*"Reasoning replaces thinking"*); `https://docs.ag-ui.com/spec/1.0/basic/versioning.md`
§"Retired shapes" and §"Downgrading";
`https://docs.ag-ui.com/spec/1.0/basic/processing.md` §"What a consumer does with
unrecognised material"; the deprecation registry `versioning.md` requires, read at
`https://raw.githubusercontent.com/ag-ui-protocol/ag-ui/main/DEPRECATIONS.md`, for the
per-shape rows and the expiry dates; `https://docs.ag-ui.com/migrating-to-1-0.md`
§"What keeps working", §"Retired from the public API" and §"Retired".

| 0.x name | 1.0 name | Note |
| --- | --- | --- |
| `THINKING_START` | `REASONING_START` | Retired **event**. Opens a reasoning span, matched by `messageId` |
| `THINKING_END` | `REASONING_END` | Retired **event**. Closes that span |
| `THINKING_TEXT_MESSAGE_START` | `REASONING_MESSAGE_START` | Retired **event**. `role` is fixed to `reasoning` |
| `THINKING_TEXT_MESSAGE_CONTENT` | `REASONING_MESSAGE_CONTENT` | Retired **event**. Extends the message the row above opens |
| `THINKING_TEXT_MESSAGE_END` | `REASONING_MESSAGE_END` | Retired **event**. Closes that message |
| `{"type": "binary"}` on an input content part | an `image`, `audio`, `video` or `document` part carrying a `source` | Retired **wire name**, not an event `type`. "a legacy `binary` content part becomes the media part its media type names" |
| `subAgents` on `AgentCapabilities` | `subagents` | Retired **wire name**, not an event `type`. "the earlier `subAgents` key is not read" — no alias, so the old key is treated as unknown material |

That is the whole retired set the sources name: the migration guide counts it —
*"the five `THINKING_*` events become their `REASONING_*` equivalents"* — and the
deprecation registry carries exactly five rows of that kind, one per event row
above. No other 0.x event `type` is named as retired by any page above, so none is
listed here; **`THINKING_TEXT_MESSAGE_CHUNK` in particular is NOT ESTABLISHED IN
SOURCE** as a 0.x name, and no glob stands in for a member of the family.

The rename is not a pure respelling of the nesting discipline: *"unlike `THINKING_*`,
a reasoning message does not have to sit inside a span, and a `REASONING_START` id
does not open a reasoning message."* Separately, the content-part renames —
`InputContent` → `ContentPart`, `TextInputContent` → `TextPart`,
`InputContentSource` → `PartSource`, `InputContentDataSource` → `DataSource`,
`InputContentUrlSource` → `UrlSource` — are **definition-level, not wire-level** and
so carry no row above: *"The wire is unchanged: every `type` value is the same, only
the definition names and anchors move, and the SDKs keep the old names as aliases."*

Rule for translating a retired shape, verbatim from `versioning.md` §"Retired
shapes": *"A consumer SHOULD translate a retired shape into its replacement rather
than drop it"*, and *"That translation MUST run as middleware — before enforcement —
because enforcement judges against the current protocol, in which the retired shape is
simply unrecognised."* The pipeline order is normative and fixed:
`producer → compatibility boundary → middleware → enforcement → chunk expansion →
verification → application`. A translation that loses content *"MUST warn"* by the
downgrade rule; a lossless one may be silent. *"Once a retired shape's expiry has
passed, an implementation MAY remove the translation, after which the shape is
unrecognised like anything else."*

An unrecognised event is not an error and never aborts the run. `processing.md`
requires a consumer to **drop** it if the whole event is of an unrecognised type —
*"The consumer SHOULD emit a warning naming the type"* — or to **strip** it if it is
an unknown property or union member on an otherwise valid event, *"SHOULD emit a
warning naming the path that was removed"*. A malformed value on a field the schema
does describe is fatal. Nothing unrecognised may reach application code, which is why
the retired-shape shim has to sit ahead of enforcement rather than behind it.

**Expiry, verbatim from the registry:** *"Every shim below shipped in 1.0, released
on 2026-09-17, and every date is twelve months from that release rather than from when
the individual shim was written … After the expiry date the shim may be removed in the
next release, and the deprecated shape stops working entirely."* The dates are
provisional, so an implementation MUST NOT date its own removal from them.

**Retired shape with no 1.0 equivalent: none of the event names.** Every name the
sources retire has a replacement in the table above, and the reverse gap is named
rather than left implicit: `REASONING_MESSAGE_CHUNK` and
`REASONING_ENCRYPTED_VALUE` have **no retired 0.x predecessor** — the registry names
five replacements and no more — so a translator has nothing to translate into them.

Translation is an SDK capability, not a protocol guarantee. The Python SDK is
producer-side and has no shim: *"There is no producer-side shim; the TypeScript
client translates old streams on its side."* The .NET SDK translates nothing
inbound at all: a `{ "type": "binary" }` part *"is an unknown discriminator, and the
converter throws a `JsonException` that fails deserialisation of the whole message"*.
An implementer on either must upgrade the producer rather than rely on the boundary.

## AG-UI `RunAgentInput` — 10 fields, 3 required

Source: `https://ag-ui.com/spec/1.0/schema.json` — `/$defs/RunAgentInput`; prose
from `https://docs.ag-ui.com/spec/1.0/basic/run-input.md`.

`additionalProperties` is **not** set to `false` on `RunAgentInput`. Every event
object instead carries `unevaluatedProperties: false`, and `RunAgentInput` is
reachable as a nested `$ref` from `RunStartedEvent.input` (whose own
`unevaluatedProperties: false` closes it in that position).

| Field | JSON type | Required | Note verbatim from schema |
| --- | --- | --- | --- |
| `threadId` | `string` | **yes** | "The conversation this run belongs to." |
| `runId` | `string` | **yes** | "Identifies this run." |
| `protocolVersion` | `string` | no | "The protocol version this consumer speaks, such as \"1.0\"" |
| `parentRunId` | `string` | no | "The run that spawned this one." |
| `state` | any JSON value except `null` (`$ref: #/$defs/State`) | no | "The state the run starts from." |
| `messages` | `array` of `#/$defs/Message` | **yes** | "The conversation so far, in order." |
| `tools` | `array` of `#/$defs/Tool` | no | "The tools the agent may call. Absent means none." |
| `context` | `array` of `#/$defs/Context` | no | "Ambient information for the run. Absent means none." |
| `forwardedProps` | any JSON value except `null` | no | "Application-specific values passed through to the agent untouched." |
| `resume` | `array` of `#/$defs/ResumeEntry` | no | "Answers to the interrupts that ended a previous run, when this run continues from one." |

`required: ["threadId","runId","messages"]`.

Schema self-description, verbatim: *"Only threadId, runId and messages are
required: those are the three the SDKs already agree on, and for tools and context
an absent key and an empty array mean the same thing, so requiring them would
catch nothing a producer could get wrong."*

## AG-UI `RunFinishedOutcome` — 3-arm `oneOf`

Source: `https://ag-ui.com/spec/1.0/schema.json` — `/$defs/RunFinishedOutcome`.
Field on the event: `RunFinishedEvent.outcome` → `$ref: #/$defs/RunFinishedOutcome`,
optional. *"Absent means success, so every producer written before outcomes
existed is already conformant."*

| Arm `$def` | Discriminator `type` `const` | Other fields | Required |
| --- | --- | --- | --- |
| `RunFinishedSuccessOutcome` | `success` | `pendingToolCallIds` — `array` of `string` (a tool call id, as carried by `TOOL_CALL_START`); optional | `type` |
| `RunFinishedInterruptOutcome` | `interrupt` | `interrupts` — `array` of `#/$defs/Interrupt`, `minItems: 1` | `type`, `interrupts` |
| `RunFinishedCancelledOutcome` | `cancelled` | none | `type` |

All three arms carry `unevaluatedProperties: false`. Success arm, verbatim:
*"Closed like every other object, which is also what keeps it from carrying the
suspended sibling's interrupts."* Cancelled arm, verbatim: *"a cancelled run has
no interrupts to carry."*

`RunFinishedEvent` other fields: `type` (`const` `RUN_FINISHED`), `threadId`
(`string`, required), `runId` (`string`, required), `result` (any JSON except
`null`, optional), `usage` (`array` of `#/$defs/TokenUsage`, optional). Inherits
`BaseEvent`: `timestamp` (`integer`, min/max ±9007199254740991, optional),
`rawEvent` (any JSON except `null`, optional), `metadata` (optional).

**Related union, same source.** `SubagentFinishedOutcome` is a `oneOf` of
`SubagentFinishedSuccessOutcome` (`type` `const` `success`) and
`SubagentFinishedSuspendedOutcome` (`type` `const` `suspended`, field
`interruptIds` — `array` of `string`).

**CONFLICT, recorded.** `https://docs.ag-ui.com/concepts/interrupts.md` gives
`type RunFinishedOutcome = | { type: "success" } | { type: "interrupt"; interrupts:
Interrupt[] }` — **two arms, no `cancelled`** — and its `Interrupt` TypeScript
type is otherwise identical to the schema's. The normative `schema.json` has
**three** arms. The concepts page is stale relative to the 1.0 schema.

## AG-UI `Interrupt` — 7 own fields plus `subagentRunId`

Source: `https://ag-ui.com/spec/1.0/schema.json` — `/$defs/Interrupt`. Composes
`Attributable` only. `unevaluatedProperties: false`.

| Field | JSON type | Required | Note verbatim from schema |
| --- | --- | --- | --- |
| `id` | `string` | **yes** | "Identifies the interrupt. A resume entry answers it by this id." |
| `reason` | `string` | **yes** | "An open string rather than an enumeration: the protocol does not attempt to classify every reason an agent might need input." |
| `message` | `string` | no | "A human-readable prompt for whoever answers." |
| `toolCallId` | `string` | no | "The tool call this interrupt concerns, when it is a tool approval." |
| `responseSchema` | `object`, `additionalProperties: true` | no | "Carried opaquely: the protocol does not constrain or validate it." |
| `expiresAt` | `string`, **unconstrained** (no `format`) | no | "Deliberately unconstrained rather than a date-time format… The documented convention is ISO 8601" |
| `metadata` | `#/$defs/Metadata` | no | "Extra information attached to this interrupt." |
| `subagentRunId` | `#/$defs/SubagentRunId` (`string`) | no | via `Attributable`; "Absent means the parent agent produced it directly." |

`Attributable` contributes the last row only; the seven own fields are `id`,
`reason`, `message`, `toolCallId`, `responseSchema`, `expiresAt`, `metadata`.

### `ResumeEntry`

Source: `https://ag-ui.com/spec/1.0/schema.json`, same `/$defs` tree.

| Field | JSON type | Required |
| --- | --- | --- |
| `interruptId` | `string` | **yes** |
| `status` | `string`, `enum: ["resolved","cancelled"]` | **yes** |
| `payload` | any JSON except `null` | no |
| `metadata` | `#/$defs/Metadata` | no |

`unevaluatedProperties: false`.

### `InterruptReason` core values — CONFLICT, both positions given

| Source | Statement |
| --- | --- |
| `schema.json` → `/$defs/Interrupt.properties.reason` | `"type": "string"` — **no `enum`**. *"An open string rather than an enumeration: the protocol does not attempt to classify every reason an agent might need input."* |
| `https://docs.ag-ui.com/spec/1.0/basic/patterns/interrupt-resume.md` | *"An interrupt's `reason` is an open string — the protocol does not attempt to classify every reason an agent might need input."* |
| `https://docs.ag-ui.com/concepts/interrupts.md` §"Reason taxonomy" — **`[UNVERIFIED]`**, non-normative concepts page outside the `spec/1.0` tree | *"`reason` is a required string. A small set of core values is spec-defined; any other string is a valid extension."* |

Core values, as listed on the concepts page only:

| Value | Semantics, verbatim | Typical companion fields, verbatim |
| --- | --- | --- |
| `tool_call` | "Interrupt bound to a specific tool call awaiting decision." | "`toolCallId` must be set." |
| `input_required` | "Agent needs structured input to continue." | "`responseSchema` should be set." |
| `confirmation` | "Free-standing yes/no decision not bound to a tool." | "`responseSchema` optional; boolean default." |

Also verbatim from that page, non-normative: *"Agents should namespace custom
reasons as `<framework>:<name>` (for example, `langgraph:database_modification`,
`mastra:workflow_suspend`). The `core:` prefix is reserved for future spec
additions."*

**No enum exists in the normative artifact.** `reason` must decode as a free-form
string.

## AG-UI HTTP + SSE binding

Source: `https://docs.ag-ui.com/spec/1.0/basic/transports/http-sse.md` (with
`.../basic/transports.md` for the binding contract and the truncation rule).

| Rule | Verbatim value |
| --- | --- |
| Method | `POST` to the agent endpoint |
| Request content type | `Content-Type: application/json` |
| Request body | "the `RunAgentInput` as a single JSON object, UTF-8 encoded" |
| Request `Accept` | `Accept: text/event-stream` |
| Response status | `200` |
| Response content type | `Content-Type: text/event-stream` |
| Frame payload | "Each SSE event's `data` payload is exactly one protocol event as a JSON object — never more than one, never a fragment. Multi-line `data:` fields join as SSE specifies." |
| Line ending | "A producer MUST frame the stream with LF (`\n`) line endings." |
| Ignored fields | "A consumer MUST ignore SSE fields other than `data` (`event:`, `id:`, `retry:`)" |
| Comments | "MUST tolerate SSE comment lines (`: keep-alive`), which producers MAY send at any cadence." |
| Termination | "The producer closes the response body after the last run's terminal event." |
| Pre-run rejection | "Input rejected before the run starts … is an HTTP error status with no event stream." |
| In-stream failure | `RUN_ERROR`; "a consumer MUST NOT infer success from `200` alone" |
| Resumption | "The binding has no stream resumption: SSE's `Last-Event-ID` mechanism is not used" |
| Truncation | "A consumer whose stream ends without a terminal event has a truncated run"; "MUST NOT synthesize a `RUN_FINISHED`" |
| Custom JSON transports | "SHOULD frame events exactly as the SSE binding does — one event object per frame" |

## AG-UI HTTP + Protobuf binding

Source: `https://docs.ag-ui.com/spec/1.0/basic/transports/http-protobuf.md`.

| Rule | Verbatim value |
| --- | --- |
| Media type (client `Accept` and response `Content-Type`) | `application/vnd.ag-ui.event+proto` |
| Admission | "Admission is what opts in — a wildcard range (`*/*`, `application/*`) admits the media type too — so a client that cannot consume protobuf MUST send an explicit `Accept` naming what it can, rather than a wildcard or down-ranked entry" |
| q-values | "relative quality values between the two media types are not consulted" |
| Producer obligation | "SHOULD answer with it whenever the client's `Accept` admits the media type with a positive quality, and MUST answer SSE otherwise" |
| **Frame length prefix** | **"A frame is a 4-byte length header — an unsigned 32-bit big-endian integer — followed by exactly that many bytes of one encoded event."** |
| Separator | "Frames abut with no separator." |
| Chunking | "A consumer MUST tolerate frames split across transport chunks and multiple frames within one chunk." |
| Truncation | "A body that ends mid-frame is a truncated run." |
| Malformed frame | "A frame whose bytes do not decode as a message is malformed transport material and fatal to the stream." |
| Wire-schema provenance | "The protobuf message definitions are generated from the same JSON Schema the SDKs are generated from; the wire schema is not a second source of truth." |
| Narrowing | Unknown *fields* skipped silently; an unknown event arm "drops the frame with a warning" |
| Protobuf implementation | OPTIONAL: "An implementation that speaks HTTP MUST support the SSE binding; the protobuf binding is OPTIONAL." |

**NOT ESTABLISHED IN SOURCE: the repository path of the generated `.proto`
file, and therefore any protobuf field number.** `api.github.com` returned HTTP
403, and the raw paths `typescript/packages/proto/ag_ui_events.proto`,
`typescript/packages/proto/src/proto/ag_ui_events.proto` and
`typescript/packages/proto/proto/ag_ui_events.proto` all returned HTTP 404. The
`@ag-ui/proto` docs page (`https://docs.ag-ui.com/sdk/js/proto.md`) is an empty
stub. The normative content is the framing rule above plus `schema.json`.

## AG-UI in-band `protocolVersion` negotiation

Source: `https://docs.ag-ui.com/spec/1.0/basic/versioning.md` §"Version
negotiation"; `.../basic/run-input.md`; `schema.json` `/$defs/RunAgentInput` and
`/$defs/RunStartedEvent`.

| Side | Field name | Location | Type | Required in schema | Example value |
| --- | --- | --- | --- | --- | --- |
| Consumer — declares what it speaks | `protocolVersion` | `RunAgentInput.protocolVersion` | `string` | no (optional) | `"1.0"` |
| Producer — declares what *it* speaks | `protocolVersion` | `RunStartedEvent.protocolVersion` | `string` | no (optional) | `"1.0"` |

Rules, verbatim:

- *"A producer declares the version it speaks on `RUN_STARTED.protocolVersion` — its own, never an echo of the input's."*
- *"The value is a version identifier this specification publishes — the segment a frozen version lives under, `MAJOR.MINOR`, compared numerically component by component (so `1.10` is newer than `1.9`)."*
- *"A declaration a party cannot interpret is handled like a newer one: proceed, and SHOULD warn."*
- *"A producer meeting a **newer minor of a line it implements** MUST serve the run … It MAY reject, before `RUN_STARTED`, only a declaration from a major line it does not implement."*
- *"Both fields are optional in the schema because absence means something: a peer from before the protocol carried a version. An implementation of this version MUST send its declaration …"*
- *"A transport MAY mirror the declaration into its own envelope — a media-type parameter, say — for intermediaries that cannot read the body. The in-band field is authoritative."*

**Allowed values: no enumeration exists.** `protocolVersion` is a bare `string` in
the schema with no `enum`, no `pattern` and no `format`. The only value this
specification version publishes is `1.0`. **No `Accept` header or query-parameter
version field is defined by the normative spec** — the HTTP+SSE binding defines no
version header, and the protobuf media type `application/vnd.ag-ui.event+proto`
carries no version parameter.

## AG-UI reserved metadata key

Source: `schema.json` → `/$defs/Metadata`;
`https://docs.ag-ui.com/spec/1.0/basic/metadata.md` §"Keys";
`https://docs.ag-ui.com/spec/1.0/basic/index.md` §"General fields".

| Item | Verbatim |
| --- | --- |
| Reserved key | `ag-ui` |
| Schema | *"The key ag-ui is reserved for the protocol's own use; reservation is by convention, since validating the shape of a key's value would contradict being open by key."* |
| Spec | *"The `ag-ui` key is reserved for the protocol's own use. Every other key is application space; producers SHOULD prefix keys they invent with a vendor or application name, so two parties extending the same stream do not collide."* |
| Shape | `Metadata` is `type: object` with `additionalProperties: true`. *"The object itself may be absent but is never null when present."* *"Any JSON value is allowed under a key, including `null`, because a `null` there is meaningful data."* |
| Merge | key-by-key, last write wins, **MUST NOT recurse** |
| `_meta` | **NOT PRESENT IN SOURCE.** A grep of the full 1.0 `schema.json` for the literal `_meta` returns no matches. AG-UI has no `_meta` member; the open channel is spelled `metadata`. (`_meta` is the MCP Apps spelling — see the MCP Apps section.) |
| Carriers of `metadata` | `BaseEvent` (every event), `Message`, `ToolCall`, `Tool`, `Interrupt`, `ResumeEntry`, `IdentityCapabilities.metadata` |

## AG-UI adjacent normative enums in the same schema

Source: `https://ag-ui.com/spec/1.0/schema.json`.

| `$def` | `enum` / bounds |
| --- | --- |
| `TextMessageRole` | `["developer","system","assistant","user"]` |
| `Role` | `["developer","system","assistant","user","tool","activity","reasoning"]` |
| `ResumeEntry.status` | `["resolved","cancelled"]` |
| `RunFinished*Outcome.type` | `["success","interrupt","cancelled"]` |
| `SubagentFinished*Outcome.type` | `["success","suspended"]` |
| `timestamp` | `integer`, `minimum: -9007199254740991`, `maximum: 9007199254740991`. *"The unit is not constrained here, because it never has been stated normatively"* — but the prose says *"By convention the unit is milliseconds since the Unix epoch."* |
| `TokenUsage` counts | `integer`, `minimum: 0`, `maximum: 9007199254740991` |

---

## A2UI v1.0 Candidate

## A2UI envelope `oneOf` keys — agent to renderer, 6 members

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/agent_to_renderer.json`
— root `oneOf` (`$id`: `https://a2ui.org/specification/v1_0/agent_to_renderer.json`);
prose from `https://a2ui.org/specification/v1.0-a2ui/` §"Envelope message structure".

| Order | `$def` (`oneOf` member) | Wire key | Outer `required` | Inner `required` | Inner `additionalProperties` |
| --- | --- | --- | --- | --- | --- |
| 1 | `CreateSurfaceMessage` | `createSurface` | `["createSurface","version"]` | `["surfaceId"]` | `false` |
| 2 | `UpdateComponentsMessage` | `updateComponents` | `["updateComponents","version"]` | `["surfaceId","components"]` | `false` |
| 3 | `UpdateDataModelMessage` | `updateDataModel` | `["updateDataModel","version"]` | `["surfaceId","value"]` | `false` |
| 4 | `DeleteSurfaceMessage` | `deleteSurface` | `["deleteSurface","version"]` | `["surfaceId"]` | `false` |
| 5 | `CallRendererFunctionMessage` | `callRendererFunction` | `["callRendererFunction","version"]` | `["functionCallId","callFunction"]` | `false` |
| 6 | `AgentFunctionResponseMessage` | `agentFunctionResponse` | `["agentFunctionResponse","version"]` | delegates to `FunctionResponse` | `false` |

Every message also carries **`version`** with `{"const": "v1.0"}` — note the
leading `v`, which differs from the `1.0` used by AG-UI.

Spec prose, verbatim: *"every message streamed by the agent must be a JSON object
containing exactly one of the following keys: `createSurface`, `updateComponents`,
`updateDataModel`, `deleteSurface`, `callRendererFunction`, or
`agentFunctionResponse`."*

## A2UI envelope inner fields

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/agent_to_renderer.json`.

| Message | Field | Type | Required |
| --- | --- | --- | --- |
| `createSurface` | `surfaceId` | `string` | yes |
| | `catalogId` | `string` | no |
| | `sendDataModel` | `boolean` (prose: "Defaults to false") | no |
| | `components` | `$ref: #/$defs/ComponentsList` | no |
| | `dataModel` | `object`, `additionalProperties: true` | no |
| | `metadata` | `object` { `extensions` → `common_types.json#/$defs/Extensions` }, `additionalProperties: false` | no |
| `updateComponents` | `surfaceId` | `string` | yes |
| | `components` | `$ref: #/$defs/ComponentsList` | yes |
| `updateDataModel` | `surfaceId` | `string` | yes |
| | `path` | `string` — "If omitted, or set to '/', refers to the entire data model." | no |
| | `value` | **no `type` keyword at all** — any JSON, including `null` ("To delete the key/value at 'path', set 'value' explicitly to null.") | yes |
| `deleteSurface` | `surfaceId` | `string` | yes |
| `callRendererFunction` | `functionCallId` | `$ref: common_types.json#/$defs/CallId` (`string`) | yes |
| | `callFunction` | `allOf` [`FunctionCommon`, `{"required":["catalogId"]}`] | yes |

## A2UI envelope `oneOf` keys — renderer to agent, 4 members

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/renderer_to_agent.json`
(`$id`: `https://a2ui.org/specification/v1_0/renderer_to_agent.json`). Root:
`"minProperties": 2, "maxProperties": 2`.

| `oneOf` member | Wire key | Notes |
| --- | --- | --- |
| `{"required":["action","version"]}` | `action` | `required: ["name","surfaceId","sourceComponentId","timestamp","context"]`; `timestamp` is `{"type":"string","format":"date-time"}`; `context` is open (`additionalProperties: true`) |
| `{"required":["callAgentFunction","version"]}` | `callAgentFunction` | `required: ["surfaceId","functionCallId","callFunction"]`, `additionalProperties: false` |
| `{"required":["rendererFunctionResponse","version"]}` | `rendererFunctionResponse` | `$ref: common_types.json#/$defs/FunctionResponse` |
| `{"required":["error","version"]}` | `error` | `oneOf` on Validation-Failed vs Generic arms |

`error` validation-failed arm `code` enum, verbatim:
`["VALIDATION_FAILED", "UNALLOWED_PARENT", "UNALLOWED_CHILD"]`.

`surfaceId` and `functionCallId` are mutually exclusive (`oneOf` with `not:
required` on the other).

## A2UI component object fields

Source: `agent_to_renderer.json` `/$defs/Component` and `/$defs/ComponentsList`;
`common_types.json` `/$defs/ComponentCommon`.

```json
"Component": {
  "description": "A UI component for the surface, combining baseline envelope properties with the catalog component definition.",
  "allOf": [
    { "$ref": "common_types.json#/$defs/ComponentCommon" },
    { "$ref": "catalog.json#/$defs/anyComponent" },
    { "type": "object", "properties": { "component": { "not": { "const": "Surface" } } } }
  ],
  "unevaluatedProperties": false
}

"ComponentsList": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/Component" } }
```

| Field | Type | Required | Source |
| --- | --- | --- | --- |
| `id` | `ComponentId` = `string` | **yes** | `ComponentCommon.required: ["id"]` |
| `catalogId` | `string` | no | `ComponentCommon` |
| `accessibility` | `$ref: #/$defs/AccessibilityAttributes` | no | `ComponentCommon` |
| `metadata` | `object` { `extensions` → `Extensions` }, `additionalProperties: false` | no | `ComponentCommon` |
| `component` | catalog `anyComponent` — must be `{"const": "<Name>"}` matching the catalog key; and `not {"const":"Surface"}` | yes (in the catalog) | envelope + spec |
| *(component-specific)* | e.g. `text`, `url`, `children` | varies | catalog |

`AccessibilityAttributes` (`common_types.json`): `label` → `DynamicString`;
`description` → `DynamicString`; `live` → `{"type":"string","enum":["off","polite","assertive"],"default":"off"}`;
`hidden` → `DynamicBoolean`. `additionalProperties: false`.

**Catalog indirection**, verbatim: *"references components using a placeholder
filename: `catalog.json` (specifically `$ref: "catalog.json#/$defs/anyComponent`")"*,
and `anyComponent` carries `"discriminator": { "propertyName": "component" }`.

## A2UI root-id constraint

Three independent normative statements, all requiring `"id": "root"`.

Source: `agent_to_renderer.json` → `UpdateComponentsMessage.updateComponents.description`;
`https://a2ui.org/specification/v1.0-a2ui/` §`createSurface` and §"UI composition:
the adjacency list model".

1. `agent_to_renderer.json`: *"One of the components in one of the components lists MUST have an 'id' of 'root' to serve as the root of the component tree."*
2. Spec §`createSurface`: *"The `createSurface` message implicitly instantiates the canonical `Surface` container component (`common_types.json#/$defs/Surface`). The `Surface` component always has `"child": "root"` and cannot be modified using `updateComponents`. To render the component tree, one of the components sent to the surface MUST have `"id": "root"`, which mounts as the child of `Surface`."*
3. Spec §"UI composition: the adjacency list model": *"There must be exactly one component with the ID `root` in the component tree, acting as the root of the component tree. Until that component is defined, other component updates will have no visible effect, and they will be buffered until a root component is defined."*

`common_types.json` `/$defs/Surface`, verbatim:

```json
"Surface": {
  "title": "Surface Container Component",
  "description": "The reserved canonical container component representing an A2UI surface. The Surface component is immutable and always has 'child': 'root'.",
  "type": "object",
  "allowedParents": [],
  "properties": { "component": { "const": "Surface" }, "child": { "const": "root" } },
  "additionalProperties": false
}
```

The inverse ban, enforced in the envelope: `Component` requires
`"component": { "not": { "const": "Surface" } }`.

**Net wire rules.** `id` MUST equal the literal string `root` for the single mount
component; `"id":"root"` MUST appear in at least one `components` list for the
surface; exactly one such component per tree; `component` MUST NOT be `"Surface"`;
the `Surface` container is never sent on the wire.

## A2UI `ChildList`

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/common_types.json`
— a `$defs` key of that file, referenced as `common_types.json#/$defs/ChildList`.

```json
"ChildList": {
  "oneOf": [
    { "type": "array", "items": { "$ref": "#/$defs/ComponentId" },
      "description": "A static list of child component IDs." },
    { "type": "object",
      "description": "A template for generating a dynamic list of children from a data model list. The `componentId` is the component to use as a template.",
      "properties": { "componentId": { "$ref": "#/$defs/ComponentId" },
                      "path": { "type": "string", "description": "The path to the list of component property objects in the data model." } },
      "required": ["componentId", "path"], "additionalProperties": false }
  ]
}
```

## A2UI `common_types.json` `$defs` key list — 21 names

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/common_types.json`.

| # | `$defs` key |
| --- | --- |
| 1 | `ComponentId` |
| 2 | `CallId` |
| 3 | `AccessibilityAttributes` |
| 4 | `Extensions` |
| 5 | `ComponentCommon` |
| 6 | `Child` |
| 7 | `ChildList` |
| 8 | `DataBinding` |
| 9 | `DynamicValue` |
| 10 | `DynamicString` |
| 11 | `DynamicNumber` |
| 12 | `DynamicBoolean` |
| 13 | `DynamicStringList` |
| 14 | `FunctionCommon` |
| 15 | `IndexSystemFunction` |
| 16 | `FunctionCall` |
| 17 | `CheckRule` |
| 18 | `Checkable` |
| 19 | `Action` |
| 20 | `Surface` |
| 21 | `FunctionResponse` |

## A2UI `Dynamic*` type names

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/common_types.json`.

| Name | `oneOf` arms | `description` verbatim |
| --- | --- | --- |
| `DynamicValue` | `string` \| `number` \| `boolean` \| `array` \| `object` (`not` requiring `path` or `call`) \| `DataBinding` \| `FunctionCall` | "A value that can be a literal, a path, or a function call returning any type." |
| `DynamicString` | `string` \| `DataBinding` \| `FunctionCall` | "Represents a string" |
| `DynamicNumber` | `number` \| `DataBinding` \| `FunctionCall` | "Represents a value that can be either a literal number, a path to a number in the data model, or a function call returning a number." |
| `DynamicBoolean` | `boolean` \| `DataBinding` \| `FunctionCall` | "A boolean value that can be a literal, a path, or a function call returning a boolean." |
| `DynamicStringList` | `array` of `string` \| `DataBinding` \| `FunctionCall` | "Represents a value that can be either a literal array of strings, a path to a string array in the data model, or a function call returning a string array." |

Related types, same source:

| Type | Shape verbatim |
| --- | --- |
| `DataBinding` | `{"type":"object","properties":{"path":{"type":"string","description":"A JSON Pointer path to a value in the data model."}},"required":["path"],"additionalProperties":false}` |
| `Child` | `{"$ref": "#/$defs/ComponentId", "description": "A reference to a single child component ID."}` |
| `Extensions` | `{"type":"object","patternProperties":{"^[\\p{XID_Start}_][\\p{XID_Continue}]*$":{}},"additionalProperties":false}` |
| `FunctionCommon` | `call` (`string`, required), `catalogId` (`string`, optional) |
| `FunctionCall` | `allOf` [`FunctionCommon`, `oneOf` [`catalog.json#/$defs/anyFunction`, `#/$defs/IndexSystemFunction`]], `unevaluatedProperties: false` |
| `IndexSystemFunction` | `call` = `{"const":"@index"}` (required), `args` = object with `offset` → `DynamicNumber` (`default: 0`), `unevaluatedProperties: false`; non-schema sibling key `"returnType": "number"` |
| `FunctionResponse` | `functionCallId` (`CallId`, required), `value` (any), `error` (`{code: string, message: string}`, both required, `additionalProperties: false`); root `oneOf: [{"required":["value"]},{"required":["error"]}]`; `additionalProperties: false` |
| `CheckRule` | `condition` (`oneOf` [`DataBinding`,`FunctionCall`], required), `message` (`string`, optional); `additionalProperties: false` |
| `Action` | `oneOf` [`{event: {name (required), userMessage → DynamicString, context → object of DynamicValue}, required:["event"]}`, `{functionCall: FunctionCall, required:["functionCall"]}`]; both arms `additionalProperties: false` |

## A2UI catalog `$ref` indirection path

Source: `https://a2ui.org/specification/v1.0-a2ui/` §"Catalogs";
`agent_to_renderer.json` `/$defs/Component`;
`renderer_capabilities.json`; `agent_capabilities.json`;
`https://raw.githubusercontent.com/a2ui-project/a2ui/main/catalogs/basic/v1/catalog.json`.

| Item | Value |
| --- | --- |
| Placeholder file name in `$ref` | `catalog.json` |
| Path form | `catalog.json#/$defs/anyComponent` |
| Discriminator | `"discriminator": { "propertyName": "component" }` |
| Function path form | `catalog.json#/$defs/anyFunction` |
| Inline-catalog path form | `https://a2ui.org/specification/v1_0/catalog_definition.json` |
| Well-known catalog id | `https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json` |

The well-known catalog id is confirmed as both the `catalogId` and the `$id` in
`catalogs/basic/v1/catalog.json`, which also carries `"protocolVersion": "1.0"`.

**Resolution order, verbatim from the spec:** *"1. Explicit Component/Function-Level
`catalogId` … 2. Surface Default `catalogId` … 3. Resolution Error … **There is no
fallback** to the list of catalogs declared in `rendererCapabilities`."*

## A2UI renderer capability key names

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/json/renderer_capabilities.json`
(`$id`: `https://a2ui.org/specification/v1_0/renderer_capabilities.json`);
`.../agent_capabilities.json`; `.../renderer_data_model.json`; the A2A extension
specification §"A2A Renderer to Agent Metadata"; spec §"Capabilities and metadata".

**Transport-metadata key names — these are the wire keys:**

| Metadata key | Type | Carries |
| --- | --- | --- |
| `a2uiRendererCapabilities` | object | `renderer_capabilities.json` — root `required: ["v1.0"]` |
| `a2uiRendererDataModel` | object | `renderer_data_model.json` — `version` (`const "v1.0"`, required), `surfaces` (object, required) |
| `capabilities.extensions[].params` (agent side, A2A AgentCard) | object | `agent_capabilities.json` — root `required: ["v1.0"]` |

**`a2uiRendererCapabilities` fields:**

| Field | Type | Required | Note verbatim |
| --- | --- | --- | --- |
| `v1.0` | `object` | **yes** | "The capabilities structure for version 1.0 of the A2UI protocol." |
| `v1.0.supportedCatalogIds` | `array` of `string` | **yes** | "An array of string identifiers for each of the component and function catalogs supported by the renderer." |
| `v1.0.inlineCatalogs` | `array` of `$ref: https://a2ui.org/specification/v1_0/catalog_definition.json` | no | "This should only be provided if the agent declares 'acceptsInlineCatalogs: true' in its capabilities." |

**Agent capabilities fields** (`agent_capabilities.json`): `v1.0` (object,
**required**); `v1.0.supportedCatalogIds` (`array` of `string`);
`v1.0.acceptsInlineCatalogs` (`boolean`, `default: false`).

**Activation, verbatim from the A2A extension specification:** *"renderers and
agents can negotiate A2UI support using A2A
`message.metadata["a2uiRendererCapabilities"]`"* — optional.

## A2UI media type `application/a2ui+json`

Source: `https://raw.githubusercontent.com/a2ui-project/a2ui/main/specification/v1_0/extensions/a2a/docs/a2ui_extension_specification.md`
§"Data encoding" and §"A2A Extension activation".

| Item | Verbatim |
| --- | --- |
| Media type | `application/a2ui+json` |
| Carrier key | `DataPart.data.metadata["mimeType"]` |
| Directive | *"it must have the following metadata: `DataPart.data.metadata["mimeType"] = "application/a2ui+json"`"* |
| Payload | *"The `data` field of the `DataPart` contains a list of A2UI JSON messages … It MUST be an array of messages."* |
| Agent→renderer list schema | `agent_to_renderer_list.json` |
| Renderer→agent list schema | `renderer_to_agent_list.json` |
| Non-standard form explicitly rejected | *"you should not use `accepted_output_modes: ['a2ui']` (which is not an A2UI standard) to trigger A2UI."* |

**NOT ESTABLISHED IN SOURCE: the `oneOf` members of
`agent_to_renderer_list.json` and `renderer_to_agent_list.json`.** Both files are
referenced by the A2A extension specification; neither was fetched.

## A2UI A2A extension URI and `X-A2A-Extensions` header

Source: same A2A extension specification, §"Extension URI" and §"JSON-RPC and
HTTP transports" / §"GRPC transport".

| Item | Verbatim |
| --- | --- |
| **Extension URI** | `https://a2ui.org/a2a-extension/a2ui/v1.0` |
| Rationale | *"The URI of this extension is https://a2ui.org/a2a-extension/a2ui/v1.0 … The extension URI explicitly encodes the version (e.g., `v1.0`)."* |
| **HTTP header name** | `X-A2A-Extensions` |
| Directive | *"To activate the A2UI A2A Extension, the `X-A2A-Extensions` HTTP header includes the extension URI."* |
| HTTP example | `X-A2A-Extensions: https://a2ui.org/a2a-extension/a2ui/v1.0` |
| gRPC carrier | `sendMessageParams.metadata["X-A2A-Extensions"]` — same key name |
| AgentCard placement | `capabilities.extensions[]` entry with `uri` (the extension URI), `description`, `required`, `params` |

## A2UI UAX #31 naming rules and the reserved `@` prefix

Source: `https://a2ui.org/specification/v1.0-a2ui/` §"Catalog Entity Naming Rules"
and §"Functions"; `common_types.json` `/$defs/Extensions`.

**Canonical regular expression, verbatim:**

```
^[\p{XID_Start}_][\p{XID_Continue}]*$
```

The four rules, verbatim:

1. *"**Permitted Characters**: Identifiers must begin with a character in the Unicode property class `XID_Start` or an underscore (`_`, `U+005F`). Subsequent characters must belong to the Unicode property class `XID_Continue`."*
2. *"**Prohibited Initial Characters**: Identifiers MUST NOT begin with a decimal digit (Unicode general category `Nd`)."*
3. *"**Prohibited Symbols and Whitespace**: Identifiers MUST NOT contain any whitespace or symbols matching the Unicode character property classes `Pattern_Syntax` or `Pattern_White_Space`, other than underscores."*
4. *"**Reserved Component Names**: The protocol reserves the component type name `"Surface"` for the canonical surface container created by `createSurface`. Catalogs MUST NOT define a standard UI component named `"Surface"`."*

**Scope, verbatim:** *"all catalog entity identifiers—specifically **component
names**, **function names**, and **argument/property names**—MUST adhere strictly to
Unicode Standard Annex #31 (UAX #31) variable naming rules."* The same pattern is
enforced mechanically on extension keys by
`common_types.json#/$defs/Extensions.patternProperties`.

**Examples, verbatim.** Valid: `UserProfileCard`, `submit_form`, `item_id_1`,
`_internal_state`. Invalid: `User Card` (violates `Pattern_White_Space`); `1stItem`
(violates initial `Nd`); `submit-form`, `user#name`, `calc$val` (violate
`Pattern_Syntax`).

**Reserved `@` prefix rule, verbatim:**

> **System Namespace Rule (`@` Prefix)**: Function names beginning with `@` (e.g., `@index`) represent universal system context evaluations available across all catalogs. Custom catalogs MUST NOT define functions prefixed with `@`.

Changes-from-0.9 summary, verbatim: *"**Strict Identifier & Context
Standards**: Enforces Unicode (UAX #31) naming rules across all catalog entities
and reserves the `@` namespace for universal system context evaluations (such as
`@index`)."*

**The one `@` function defined in v1.0** —
`common_types.json#/$defs/IndexSystemFunction`: `call: {"const":"@index"}`,
`returnType: "number"`, `args.offset` → `DynamicNumber` with `default: 0`,
`unevaluatedProperties: false`. Scope rule, verbatim: *"The `@index` function MUST
ONLY be available when evaluating template items within a list rendering context
(Collection Scope) … If called outside of template iteration (e.g., directly in
the Root Scope), the renderer MUST treat it as an error or evaluate it as
invalid."* It is wired into `FunctionCall` as a `oneOf` sibling of
`catalog.json#/$defs/anyFunction`, so a `@`-prefixed name can never resolve through
a catalog.

**Other reserved prefixes**, spec §"Architectural Principles", verbatim:

- *"Official A2UI extensions are strictly reserved under the prefix `a2ui_`."*
- *"Third-party extensions MUST be prefixed with a distinct organization or product identifier separated by an underscore (e.g. an extension from a company with the domain `company.com` might be named `com_company_extension`)."*
- `Extensions` schema description, verbatim: *"Keys MUST be Unicode identifiers (UAX #31). Keys starting with 'a2ui_' are reserved for official extensions."*

**NOT ESTABLISHED IN SOURCE: UAX #31 scope for identifiers.** The spec applies
the rule to component names, function names and argument/property names;
`Extensions` enforces the same pattern on extension keys. No primary source
applies it to `surfaceId`, `catalogId` or `action.name`. Those are plain `string`
with no `pattern` in any schema.

---

## MCP Apps — SEP-1865, `2026-01-26` Stable

## MCP Apps `ui://` scheme, MIME type, extension identifier

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx`
— source for this whole section.

| Item | Verbatim | Norm |
| --- | --- | --- |
| URI scheme | `ui://` | "URI MUST start with `ui://` scheme" / `uri` doc: "MUST use the `ui://` URI scheme to distinguish UI resources from other MCP resource types." |
| MIME type | `text/html;profile=mcp-app` | "`mimeType` MUST be `text/html;profile=mcp-app` (other types reserved for future extensions)" |
| Extension identifier | `io.modelcontextprotocol/ui` | "This extension is identified as: `io.modelcontextprotocol/ui`" |
| Reservations | — | "The resource prefix `ui://` will be reserved for MCP Apps" / "The label `io.modelcontextprotocol/ui` is reserved" |
| Protocol version in the `ui/initialize` result | `"2026-01-26"` | verbatim in the spec's own example: `protocolVersion: "2026-01-26"` |
| `UIResource` fields | `uri` (`string`, required), `name` (`string`, required), `description?` (`string`), `mimeType` (`string`, required), `_meta?: { ui?: UIResourceMeta }` | |
| Content | "Content MUST be provided via either `text` (string) or `blob` (base64-encoded)"; "Content MUST be valid HTML5 document" | |
| Example uri | `ui://weather-server/dashboard-template` | |

## MCP Apps `UIResourceMeta` — full field list

Source: `apps.mdx` §`UIResourceMeta`.

| Field | Type | Optional | Doc comment verbatim |
| --- | --- | --- | --- |
| `csp` | `McpUiResourceCsp` | yes | "Content Security Policy configuration" |
| `permissions` | `object` | yes | "Sandbox permissions requested by the UI" |
| `permissions.camera` | `{}` | yes | "Request camera access" / "Maps to Permission Policy `camera` feature" |
| `permissions.microphone` | `{}` | yes | "Request microphone access" / "Maps to Permission Policy `microphone` feature" |
| `permissions.geolocation` | `{}` | yes | "Request geolocation access" / "Maps to Permission Policy `geolocation` feature" |
| `permissions.clipboardWrite` | `{}` | yes | "Request clipboard write access" / "Maps to Permission Policy `clipboard-write` feature" |
| `domain` | `string` | yes | "Dedicated origin for view … **Host-dependent:** The format and validation rules for this field are determined by each host." Examples: `a904794854a047f6.claudemcpcontent.com`, `www-example-com.oaiusercontent.com`. "If omitted, Host uses default sandbox origin (typically per-conversation)." |
| `prefersBorder` | `boolean` | yes | "Visual boundary preference … - `true`: Request visible border + background - `false`: Request no visible border + background - omitted: host decides border" |

Container: `_meta?: { ui?: UIResourceMeta }` on the resource declaration; on
`resources/read` contents the same `_meta.ui` shape repeats.

## MCP Apps `McpUiResourceCsp` — full field list

Source: `apps.mdx` §`McpUiResourceCsp`.

| Field | Type | Empty or omitted means | Maps to CSP directive |
| --- | --- | --- | --- |
| `connectDomains` | `string[]` | "no external connections (secure default)" | `connect-src` |
| `resourceDomains` | `string[]` | "no external resources (secure default)" — "Wildcard subdomains supported: `https://*.example.com`" | `img-src`, `script-src`, `style-src`, `font-src`, `media-src` |
| `frameDomains` | `string[]` | "no nested iframes allowed (`frame-src 'none'`)" | `frame-src` |
| `baseUriDomains` | `string[]` | "only same origin allowed (`base-uri 'self'`)" | `base-uri` |

All four fields optional. The identical four-key shape also appears nested under
`HostCapabilities.sandbox.csp` (host-approved) and inside
`ui/notifications/sandbox-resource-ready` `params.csp`.

## MCP Apps mandatory default CSP — verbatim

Source: `apps.mdx` §"Host Behavior".

**Requirement, verbatim:** *"**Restrictive Default:** If `ui.csp` is omitted, Host MUST use:"*

```
default-src 'none';
script-src 'self' 'unsafe-inline';
style-src 'self' 'unsafe-inline';
img-src 'self' data:;
media-src 'self' data:;
connect-src 'none';
```

Six lines, in that order.

Companion rules, verbatim: *"**No Loosening:** Host MAY further restrict but MUST NOT
allow undeclared domains"*; *"**Audit Trail:** Host SHOULD log CSP configurations for
security review"*.

**CONFLICT, both given.** A second, different CSP template appears later in the
same file under "Security Implications → Content Security Policy Enforcement →
CSP Construction from Metadata" — a TypeScript template literal that constructs a
10-line policy from metadata rather than stating the default. It is **not** the
mandatory default, and it conflicts with the block above in several directives:

```
default-src 'none';
script-src 'self' 'unsafe-inline' ${csp?.resourceDomains?.join(' ') || ''};
style-src 'self' 'unsafe-inline' ${csp?.resourceDomains?.join(' ') || ''};
connect-src 'self' ${csp?.connectDomains?.join(' ') || ''};
img-src 'self' data: ${csp?.resourceDomains?.join(' ') || ''};
font-src 'self' ${csp?.resourceDomains?.join(' ') || ''};
media-src 'self' data: ${csp?.resourceDomains?.join(' ') || ''};
frame-src ${csp?.frameDomains?.join(' ') || "'none'"};
object-src 'none';
base-uri ${csp?.baseUriDomains?.join(' ') || "'self'"};
```

Divergences: the construction template adds `font-src` and `object-src 'none'`
(absent from the normative default); it emits `connect-src 'self' …` where the
normative default says `connect-src 'none'`; and the Sandbox-proxy step list
separately names `object-src 'none'` and "Apply restrictive defaults if no CSP
metadata is provided". **The mandatory string is the six-line block above.**

## MCP Apps `ui/*` methods and notifications — complete list

Source: `apps.mdx` §"Requests (View → Host)", §"Standard MCP Messages", §"Sandbox
proxy", §"Notifications (Host → View)", §"Reserved Messages (Sandbox Proxy)".

All names verbatim. `Request`/`Notification` marks the JSON-RPC kind.

### Requests — View → Host

| # | Method | Kind | `params` | Success `result` | Note verbatim |
| --- | --- | --- | --- | --- | --- |
| 1 | `ui/open-link` | Request | `{ url: string }` | `{}` | "Host SHOULD open the URL in the user's default browser or a new tab." Error `code: -32000`. |
| 2 | `ui/message` | Request | `{ role: "user", content: { type: "text", text: string } }` | `{}` | "Host SHOULD add the message to the conversation context, preserving the specified role. Host MAY request user consent." |
| 3 | `ui/request-display-mode` | Request | `{ mode: "inline" \| "fullscreen" \| "pip" }` | `{ mode: "inline" \| "fullscreen" \| "pip" }` | "Host MUST return the resulting mode (whether updated or not) in the response to `ui/request-display-mode`." |
| 4 | `ui/update-model-context` | Request | `{ content?: ContentBlock[], structuredContent?: Record<string, unknown> }` | `{}` | "Each request overwrites the previous context sent by the View." |

### Lifecycle

| # | Method | Kind | Direction | Note verbatim |
| --- | --- | --- | --- | --- |
| 5 | `ui/initialize` | Request | View → Host | "MCP-like handshake (replaces custom iframe-ready pattern in MCP-UI)". View MUST include `appCapabilities`. Response is `McpUiInitializeResult`. |
| 6 | `ui/notifications/initialized` | Notification | View → Host | "The Host MUST NOT send any request or notification to the View before it receives an `initialized` notification." |

### Notifications — Host → View

| # | Method | Kind | `params` | Norm, verbatim |
| --- | --- | --- | --- | --- |
| 7 | `ui/notifications/tool-input` | Notification | `{ arguments: Record<string, unknown> }` | "Host MUST send this notification with the complete tool arguments after the View's initialize request completes." "sent at most once and is required before sending `ui/notifications/tool-result`" |
| 8 | `ui/notifications/tool-input-partial` | Notification | `{ arguments: Record<string, unknown> }` | "Host MAY send this notification zero or more times while the agent is streaming tool arguments" |
| 9 | `ui/notifications/tool-result` | Notification | `CallToolResult` (standard MCP type) | "Host MUST send this notification when tool execution completes (if the View is displayed during tool execution)." |
| 10 | `ui/notifications/tool-cancelled` | Notification | `{ reason: string }` | "Host MUST send this notification if the tool execution was cancelled, for any reason" |
| 11 | `ui/notifications/size-changed` | Notification | `{ width: number, height: number }` | View → Host. "The View SHOULD send this notification when rendered content body size changes". Hosts using flexible dimensions **MUST** listen. |
| 12 | `ui/notifications/host-context-changed` | Notification | `Partial<HostContext>` | "Host MAY send this notification when any context field changes" |

### Listed under Notifications but carrying an `id`, i.e. a request

| # | Method | Kind | Shape | Norm, verbatim |
| --- | --- | --- | --- | --- |
| 13 | `ui/resource-teardown` | Request (listed under Notifications) | `{ jsonrpc, id, method, params: { reason: string } }` → `result: {}` | "Host notifies View before teardown". "Host MUST send this notification before tearing down the UI resource … Host SHOULD wait for a response before tearing down the resource." |

### Reserved — Sandbox Proxy

| # | Method | Direction | `params` |
| --- | --- | --- | --- |
| 14 | `ui/notifications/sandbox-proxy-ready` | Sandbox Proxy → Host | `{}` |
| 15 | `ui/notifications/sandbox-resource-ready` | Host → Sandbox Proxy | `{ html: string, sandbox?: string, csp?: { connectDomains?, resourceDomains?, frameDomains?, baseUriDomains? }, permissions?: { camera?, microphone?, geolocation?, clipboardWrite? } }` |

**15 `ui/*` names in total.**

**Standard MCP messages the View may use** (§"Standard MCP Messages") — these are
non-`ui/`: `tools/call`, `resources/read`, `notifications/message`, `ping`.

**Name-prefix partition rules, verbatim.** Sandbox: *"for any method that doesn't
start with `ui/notifications/sandbox-`"*; Host→MCP server: *"for any method that
doesn't start with `ui/`"*.

**Display-mode enum** (§"Display Modes"): `type McpUiDisplayMode = "inline" |
"fullscreen" | "pip";` — and the same three strings recur in
`McpUiAppCapabilities.availableDisplayModes` and `HostContext.displayMode`.

## MCP Apps `HostCapabilities` — field list

Source: `apps.mdx` §`HostCapabilities`. Sent "as part of the response to
`ui/initialize` (inside `McpUiInitializeResult`)".

| Field | Type | Doc comment verbatim |
| --- | --- | --- |
| `experimental` | `{}` | "Experimental features (structure TBD)." |
| `openLinks` | `{}` | "Host supports opening external URLs." |
| `serverTools` | `{ listChanged?: boolean }` | "Host can proxy tool calls to the MCP server." / "Host supports tools/list_changed notifications." |
| `serverResources` | `{ listChanged?: boolean }` | "Host can proxy resource reads to the MCP server." / "Host supports resources/list_changed notifications." |
| `logging` | `{}` | "Host accepts log messages." |
| `sandbox` | object | "Sandbox configuration applied by the host." |
| `sandbox.permissions` | `{ camera?: {}, microphone?: {}, geolocation?: {}, clipboardWrite?: {} }` | "Permissions granted by the host (camera, microphone, geolocation, clipboard-write)." |
| `sandbox.csp` | `{ connectDomains?: string[], resourceDomains?: string[], frameDomains?: string[], baseUriDomains?: string[] }` | "CSP domains approved by the host." |

Every field optional. The `McpUiInitializeResult` example also carries
`protocolVersion`, `hostCapabilities`, `hostInfo: { name, version }` and
`hostContext`.

## MCP Apps `HostContext` — field list

Source: `apps.mdx` §`HostContext`. Returned in `McpUiInitializeResult.hostContext`.
"the Host SHOULD include UI-specific context".

| Field | Type | Doc comment verbatim |
| --- | --- | --- |
| `toolInfo` | `{ id?: RequestId, tool: Tool }` | "Metadata of the tool call that instantiated the View"; `id` = "JSON-RPC id of the `tools/call` request"; `tool` = "Contains name, inputSchema, etc…" |
| `theme` | `"light" \| "dark"` | "Current color theme preference" |
| `styles` | object | "Style configuration for theming. See Theming section for standardized variable names." |
| `styles.variables` | `Record<McpUiStyleVariableKey, string \| undefined>` | "CSS variables for theming" |
| `styles.css.fonts` | `string` | "CSS for font loading (@font-face rules or @import statements)" |
| `displayMode` | `"inline" \| "fullscreen" \| "pip"` | "How the View is currently displayed" |
| `availableDisplayModes` | `string[]` | "Display modes the host supports" — note: plain `string[]`, **not** the `McpUiDisplayMode` union |
| `containerDimensions` | `({height: number} \| {maxHeight?: number}) & ({width: number} \| {maxWidth?: number})` | "Container dimensions for the iframe. Specify either width or maxWidth, and either height or maxHeight." |
| `locale` | `string` | "User's language/region preference (BCP 47, e.g., \"en-US\")" |
| `timeZone` | `string` | "User's timezone (IANA, e.g., \"America/New_York\")" |
| `userAgent` | `string` | "Host application identifier" |
| `platform` | `"web" \| "desktop" \| "mobile"` | "Platform type for responsive design" |
| `deviceCapabilities` | `{ touch?: boolean, hover?: boolean }` | "Device capabilities such as touch" |
| `safeAreaInsets` | `{ top: number, right: number, bottom: number, left: number }` | "Safe area boundaries in pixels" |

**CONFLICT recorded on `availableDisplayModes`.** `McpUiAppCapabilities.availableDisplayModes`
is typed `Array<"inline" | "fullscreen" | "pip">`; the Host-side
`HostContext.availableDisplayModes` is the looser `string[]`. Both are verbatim.

**Companion — `McpUiAppCapabilities`** (View → Host, in
`ui/initialize.params.appCapabilities`):

| Field | Type | Doc comment verbatim |
| --- | --- | --- |
| `experimental` | `{}` | "Experimental features (structure TBD)." |
| `tools` | `{ listChanged?: boolean }` | "App exposes MCP-style tools that the host can call. App supports tools/list_changed notifications." |
| `availableDisplayModes` | `Array<"inline" \| "fullscreen" \| "pip">` | "Display modes the app supports. @example [\"inline\", \"fullscreen\"]" |

**Container-dimension mode table, verbatim:**

| Mode | Dimensions field | Meaning verbatim |
| --- | --- | --- |
| Fixed | `height` or `width` | "Host controls the size. View should fill the available space." |
| Flexible | `maxHeight` or `maxWidth` | "View controls the size, up to the specified maximum." |
| Unbounded | Field omitted | "View controls the size with no limit." |

## MCP Apps `visibility` enum

Source: `apps.mdx` §"Resource Discovery" → `McpUiToolMeta`, plus §"Visibility".

| Item | Verbatim |
| --- | --- |
| Field | `McpUiToolMeta.visibility` |
| Type | `Array<"model" \| "app">` |
| Path | `Tool._meta.ui.visibility` |
| Default | "`visibility` defaults to `[\"model\", \"app\"]` if omitted" |
| `"model"` | "Tool is visible to and callable by the agent" |
| `"app"` | "Tool is callable by the app from the same server connection only" |
| `tools/list` rule | "Host MUST NOT include tools in the agent's tool list when their visibility does not include `\"model\"` (e.g., `visibility: [\"app\"]`)" |
| `tools/call` rule | "Host MUST reject `tools/call` requests from apps for tools that don't include `\"app\"` in visibility" |
| Cross-server | "Cross-server tool calls are always blocked for app-only tools" |
| Sibling field | `McpUiToolMeta.resourceUri?: string` — "URI of UI resource for rendering tool results" |

**Enum values, exactly: `"model"` and `"app"`.** No other member appears anywhere
in the file.

## MCP Apps deprecated key still present

Source: `apps.mdx` §"Visibility" / the `Tool` interface declaration.

| Item | Verbatim |
| --- | --- |
| **Deprecated key** | `_meta["ui/resourceUri"]` — the flat slash-delimited form |
| Declared as | `"/** @deprecated Use \`ui.resourceUri\` instead. Will be removed before GA. */"` on `"ui/resourceUri"?: string;` inside `Tool._meta` |
| Deprecation notice | *"The flat `_meta[\"ui/resourceUri\"]` format is deprecated. Use `_meta.ui.resourceUri` instead. The deprecated format will be removed before GA."* |
| Replacement | `_meta.ui.resourceUri` — nested in `McpUiToolMeta` |
| Scope | The `Tool` interface only. `UIResource._meta` has no such member. |

**No other `@deprecated` marker exists in the file.** Related rejected
alternative, verbatim: *"**Flat `ui/visibility` key:** Rejected in favor of nested
structure for consistency with future `_meta.ui` fields."* — i.e. the
`visibility` key was explicitly **not** placed at `_meta["ui/visibility"]`.

## MCP Apps sandbox proxy requirements

Source: `apps.mdx` §"Sandbox proxy". This is the source of the two
`ui/notifications/sandbox-*` names and of the name-prefix partition rules above.

*"If the Host is a web page, it MUST wrap the View and communicate with it through
an intermediate Sandbox proxy."*

1. *"The Host and the Sandbox MUST have different origins."*
2. *"The Sandbox MUST have the following permissions: `allow-scripts`, `allow-same-origin`."*
3. MUST send `ui/notifications/sandbox-proxy-ready`.
4. Host MUST send `ui/notifications/sandbox-resource-ready`.
5. Sandbox MUST load with CSP enforcing `ui.csp`, `frame-src 'none'` if `frameDomains` absent, `base-uri 'self'` if `baseUriDomains` absent, `object-src 'none'`, restrictive defaults if no CSP metadata, and may set the inner iframe `allow` from `permissions`.
6. MUST forward both directions for any method not starting with `ui/notifications/sandbox-`.
7. SHOULD NOT originate requests.
8. Host MAY forward non-`ui/` View messages to the MCP Apps server.

---

## Cross-protocol conflicts consolidated

| # | Item | Sources in conflict | Position taken here |
| --- | --- | --- | --- |
| 1 | AG-UI `RunFinishedOutcome` arm count | `schema.json` `/$defs/RunFinishedOutcome` = 3 arms (`success`/`interrupt`/`cancelled`) vs `docs.ag-ui.com/concepts/interrupts.md` = 2 arms | The schema wins, per the spec's own precedence rule |
| 2 | AG-UI `Interrupt.reason` | `schema.json` and `patterns/interrupt-resume.md`: open string, no enum vs `concepts/interrupts.md`: three "spec-defined" core values | The two normative sources agree there is no enum. The core values are concepts-page-only and marked `[UNVERIFIED]` |
| 3 | MCP Apps default CSP | §"Host Behavior" six-line block (normative MUST) vs "CSP Construction from Metadata" 10-line template | The six-line block is the stated mandatory default. `font-src` and `object-src` appear only in the template |
| 4 | MCP Apps `availableDisplayModes` typing | `McpUiAppCapabilities.availableDisplayModes`: `Array<"inline"\|"fullscreen"\|"pip">` vs `HostContext.availableDisplayModes`: `string[]` | Both verbatim; the Host-side field is the looser `string[]` |
| 5 | AG-UI `.proto` file | `api.github.com` HTTP 403; three candidate `raw.githubusercontent.com` paths HTTP 404; `sdk/js/proto.md` an empty stub | **NOT ESTABLISHED IN SOURCE.** No readable primary source for protobuf field numbers |
| 6 | A2UI list wrappers | The A2A extension specification references `agent_to_renderer_list.json` and `renderer_to_agent_list.json` | **NOT ESTABLISHED IN SOURCE.** Their `oneOf` members are not in this file |
| 7 | A2UI naming scope | The spec applies UAX #31 to component names, function names and argument/property names; `Extensions` enforces the same pattern on extension keys | `surfaceId`, `catalogId` and `action.name` are plain `string` with no `pattern` in any schema. **NOT ESTABLISHED IN SOURCE** for those three |
