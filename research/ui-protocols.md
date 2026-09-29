# UI protocols: AG-UI, A2UI, MCP Apps, WebMCP, NLWeb

This document covers the agent-to-UI layer: the five efforts that put a user-facing
surface on the far end of an agent, the one consolidation that has already happened
inside that layer, and the one axis that remains open. It does not cover the
editor-facing agent protocol, which has its own document
([`acp-agent-client.md`](acp-agent-client.md)), nor the session and method semantics
that [`mcp.md`](mcp.md) and [`a2a.md`](a2a.md) own. Nothing here is normative.

- Research date: **2026-09-29**
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

The layer is four axes, and commentary routinely merges them. Only one axis has
consolidated.

| Axis | Direction | Protocols | Home |
| --- | --- | --- | --- |
| Agent event stream | agent to client | AG-UI (also ACP, editor-shaped) | CopilotKit; Zed and JetBrains |
| Declarative UI description | agent to client | A2UI | Google, no foundation |
| Sandboxed HTML UI | MCP server to chat host | MCP Apps, absorbing mcp-ui and the OpenAI Apps SDK | MCP Core Maintainers |
| Site-exposed tools | site to browser agent | WebMCP, NLWeb | W3C Community Groups, neither a standard |

### AG-UI

Version 1.0. Packages `@ag-ui/client`, `@ag-ui/core`, `@ag-ui/encoder`, `@ag-ui/proto`
went 1.0.0 on 2026-09-17 and 1.0.1 on 2026-09-29
([releases](https://github.com/ag-ui-protocol/ag-ui/releases.atom)). Wire protocol
version is the generated `PROTOCOL_VERSION` `"1.0"`, a breaking change from 0.x
([spec](https://docs.ag-ui.com/spec/1.0/index)). This is the first normative
behavioural specification the project has published; 0.x defined shapes only, with
behaviour living in the TypeScript client ([changelog](https://docs.ag-ui.com/spec/1.0/changelog)).

Repository [ag-ui-protocol/ag-ui](https://github.com/ag-ui-protocol/ag-ui): MIT, 16.1k
stars, 1.5k forks, 4,149 commits, 208 open issues, 133 open PRs.

Governance is CopilotKit-controlled with no foundation. The `CODEOWNERS` entry
`@ag-ui-protocol/copilotkit` owns all paths, the working group is a biweekly meeting on
CopilotKit's Luma calendar, and issue and PR links point at `linear.app/copilotkit`.
Community contributors receive self-service code ownership only for their own SDK or
integration path ([CONTRIBUTING.md](https://github.com/ag-ui-protocol/ag-ui/blob/main/CONTRIBUTING.md)).
The repository carries commercial production-support and hosted-service pages. CopilotKit
raised a $27M Series A on 2026-05-05 (TechCrunch; CB Insights lists Glilot Capital
Partners, with a prior seed on 2023-10-09 and Seed II on 2024-05-24) — source URL
NOT ESTABLISHED IN SOURCE.

SDKs: TypeScript, Python and .NET are first-party. Kotlin, Go, Dart, Java, Rust, Ruby
and C++ are community. Nim, Flowise and Langflow are listed as in progress.

### A2UI

A2UI has not reached 1.0. The version table reads v1.0 = Candidate, v0.9.1 = Current
production, v0.9 = Stable, v0.8 = Legacy ([a2ui.org](https://a2ui.org/)). The v1.0 spec
header records Status Candidate, Created 2025-11-20, Last Updated 2026-06-08
([v1.0 spec](https://a2ui.org/specification/v1.0-a2ui/)); the recommended production
release v0.9.1 records Last Updated 2025-12-03
([v0.9.1 spec](https://a2ui.org/specification/v0.9.1-a2ui/)). The repository README is
blunter: "Status: Early stage public preview … The specification and implementations are
functional but are still evolving … Expect changes."

Repository [a2ui-project/a2ui](https://github.com/a2ui-project/a2ui): Apache 2.0, 16.5k
stars, 1.3k forks, 407 open issues. The organisation was formerly `google/A2UI`; AG-UI's
own documentation still links the old path.

Governance is Google-origin and GitHub-organisation-governed, with no foundation.
a2ui.org states it is "Apache 2.0 licensed, created by Google with contributions from
CopilotKit and the open source community, and is in active development on GitHub." It
was publicly announced in the Google Developers Blog on 2025-12-15 — announcement URL
NOT ESTABLISHED IN SOURCE. A2UI is not under the Linux Foundation, per its own site and
repository; A2A is, per the [Linux Foundation, 2026-04-09](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year)
(150+ organisations).

The [roadmap](https://a2ui.org/roadmap/) was last updated in June 2026 and still carries
v1.0 finalisation, a comprehensive test suite and a renderer certification programme as
**Q4 2026** targets, with SwiftUI and Jetpack Compose still listed as Q2 2026 targets.

### MCP Apps

Spec SEP-1865, Status Stable, dated 2026-01-26, created 2025-11-21, Track Extensions
([spec text](https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx)).
Extension identifier `io.modelcontextprotocol/ui`. Governance is the MCP Core
Maintainers via the extensions track described in SEP-2133: propose a SEP, build a
reference implementation in an official SDK, Core Maintainers review with final
authority, publish, adopt. The SEP mechanism itself is SEP-1724
([extension framework](https://modelcontextprotocol.io/extensions/overview)).

Repository [modelcontextprotocol/ext-apps](https://github.com/modelcontextprotocol/ext-apps):
Apache 2.0, 2.9k stars, 392 forks, **218 open issues**. Packages
`@modelcontextprotocol/ext-apps`, `/react`, `/app-bridge`, `/server`. Documentation at
[apps.extensions.modelcontextprotocol.io](https://apps.extensions.modelcontextprotocol.io/api/documents/overview.html).
The SDK is at 2.x alongside `@modelcontextprotocol/client` and `/server` v2 peers, with a
documented wire-protocol guarantee that a 2.x View renders in a 1.x host and a 2.x host
renders a 1.x View. The MCP blog post of 2026-01-26 calls it the first official MCP
extension — post URL NOT ESTABLISHED IN SOURCE.

The extension framework has four official extensions as of 2026-09, and the core
protocol version in its negotiation examples is `2026-07-28`
([extension framework](https://modelcontextprotocol.io/extensions/overview)).

#### mcp-ui, absorbed predecessor

Repository [idosal/mcp-ui](https://github.com/idosal/mcp-ui) under the MCP-UI-Org
organisation: Apache 2.0, 5.2k stars, 399 forks, 65 open issues; TypeScript, Ruby and
Python SDKs. Alive and repositioned, not deprecated. Its README states that
"`@mcp-ui/*` packages implement the MCP Apps standard. `@mcp-ui/client` is the
recommended SDK for MCP Apps Hosts" and that the packages "are fully compliant with the
MCP Apps specification and ready for production use." [mcpui.dev](https://mcpui.dev/)
leads with "MCP Apps Standard" and calls the packages "a community playground for future
enhancements." Both renderers ship: `AppRenderer` for MCP Apps hosts and
`UIResourceRenderer` for legacy MCP-UI hosts that embed resources in tool responses, with
a Legacy MCP-UI Adapter guide for the old shape.

Release cadence has slowed sharply ([releases](https://github.com/MCP-UI-Org/mcp-ui/releases.atom)):

| Version | Date | Note |
| --- | --- | --- |
| client/server v6.0.0 | 2026-01-26 | Title "mcp-ui → mcp apps!"; breaking |
| v6.1.0 | 2026-02-13 | Experimental message support |
| client v7.0.0 | 2026-03-12 | |
| client v7.1.0 | 2026-05-01 | `hostInfo` / `hostCapabilities` props |
| client v7.1.1 | 2026-05-09 | Last release as of the research date |

#### OpenAI Apps SDK, absorbed predecessor

The name "Apps SDK" is retired as OpenAI's primary product name;
[developers.openai.com/apps-sdk](https://developers.openai.com/apps-sdk) now serves the
Plugins documentation, with "Apps SDK" still reachable as a separate section. The build
guide's first section is "Start with MCP Apps": "ChatGPT implements the open MCP Apps
standard for UI returned by an MCP server"
([chatgpt-ui](https://developers.openai.com/plugins/build/chatgpt-ui)). The reference
page opens "Start with the open standard … OpenAI extensions are optional and live in
`window.openai`" ([reference](https://developers.openai.com/plugins/reference)).

A plugin is the installable unit: Skills (`SKILL.md` plus scripts and references) and/or
an MCP server with tools, `structuredContent` and optional UI resources, plus lifecycle
hooks for the Codex runtime. "ChatGPT and Codex share one universal plugin directory."
Four sanctioned shapes: skills-only, MCP-server-only, skills+MCP, MCP-with-UI
([plugin concepts](https://developers.openai.com/plugins/concepts/plugins)).

ChatKit remains live with two paths, custom server integration (ChatKit Python/JS SDK
against any agentic service) and the legacy Agent Builder-hosted path. OpenAI is
deprecating Agent Builder with shutdown scheduled 2026-11-30. Distribution is
`chatkit.js` from `cdn.platform.openai.com`, `@openai/chatkit-react`,
`github.com/openai/chatkit-js`, and `POST /v1/chatkit/sessions` with
`OpenAI-Beta: chatkit_beta=v1`; a per-end-user `user` identifier is required, which the
docs state as an explicit security note
([ChatKit guide](https://developers.openai.com/api/docs/guides/chatkit)).

Launch date is disputed between two effectively primary sources: OpenAI's own page
"Introducing apps in ChatGPT and the new Apps SDK", dated 2025-10-06 by TechCrunch, and
SEP-1865, which states "OpenAI's Apps SDK, launched in November 2025"
[UNVERIFIED: which is authoritative].

### WebMCP

W3C Web Machine Learning Community Group, Draft Community Group Report dated
2026-09-29, editors Brandon Walderman (Microsoft), Khushal Sagar (Google) and Dominic
Farolino (Google), under the W3C Community Contributor License Agreement
([draft](https://webmachinelearning.github.io/webmcp)). The document disclaims standard
status in its own text: "It is not a W3C Standard nor is it on the W3C Standards Track."

[ChromeStatus feature 5117755740913664](https://chromestatus.com/api/v0/features?q=webmcp)
(Blink component `Blink>Agentic Platform>WebMCP`, web feature `document-modelcontext`):
created 2025-07-08, last updated 2026-09-28, `shipping_year: 2026`, Chrome status
"Proposed", intent stage "None".

| Field | Value |
| --- | --- |
| DevTrial | `desktop_first: 146` |
| Origin trial | `4163014905550602241`, "WebMCP" |
| OT range | `desktop_first 149`, `desktop_last 156`, extension requested 2026-09-28 to 162 |
| Use counter | `kModelContextRegisterTool`, bucket 5791 |
| `tag_review_status` | Pending |
| `security_review_status` | Pending |
| `privacy_review_status` | Pending |
| `intent_to_ship_url` | `null` |
| `announcement_url` | `null` |
| Firefox | No signal |
| Safari | No signal |

WPT coverage is tracked at [wpt.fyi/results/webmcp](https://wpt.fyi/results/webmcp); the
IDL and basic usage are tested, with a note that the harness may need extending "for the
user agent to call certain tools."

### NLWeb

Microsoft origin, announced 2025-05-19 at Build ("Introducing NLWeb: Bringing
conversational interfaces directly to the web") — announcement URLs NOT ESTABLISHED IN
SOURCE.

Governance is a W3C Community Group and a thin one. The group was
[proposed 2025-10-16 by Ramanathan Guha](https://www.w3.org/community/nlweb/) (supporters
Enrico Zimuel, Ramanathan Guha, David Dennison, Stelios Sartzetakis, Chelsea Carter,
Baris Gultekin, Christopher DiBona, Ivo Brett) and launched 2025-10-20. W3C's own post
states that the group "must now choose a chair" and that "W3C's hosting of this group
does not imply endorsement of the activities." As of the research date the Community
Group page still shows only the launch post: no chair, no published report, no draft, no
meeting notes. Support address `NLWebSup@microsoft.com`.

Repository [nlweb-ai/NLWeb](https://github.com/nlweb-ai/NLWeb): MIT, 6.3k stars, 699
forks, 65 open issues, Python. Trademark use is governed by Microsoft's guidelines.

The canonical spec URL, `https://nlweb.ai/spec`, fails TLS validation
(`ERR_TLS_CERT_ALTNAME_INVALID`) on fetch. Directly observed 2026-09-29.

The repository is near-dormant. The most recent commit is 2026-06-10, a Dependabot
merge; the last substantive non-dependabot change is 2026-05-11, a `mermaid` bump inside
`openai-apps-sdk-integration/` ([commit history](https://github.com/nlweb-ai/NLWeb/commits/main)).
Approximately 3.5 months without a human change.

## What it does

### AG-UI

Two roles, which a participant may hold simultaneously. A **producer** emits the stream:
an agent, proxy, bridge or test double. A **consumer** receives it: a client SDK, UI,
recorder or proxy. Conformance is judged per stream.

The model is one request in, one ordered stream of typed events out. The single inbound
message is `RunAgentInput`; the reply is an event envelope with `type` as discriminator.
The 1.0 specification enumerates **eight event families and thirty-one event types**
([events](https://docs.ag-ui.com/spec/1.0/events)):

| Family | Events | Pattern |
| --- | --- | --- |
| Runs and steps | `RUN_STARTED` `RUN_FINISHED` `RUN_ERROR` `STEP_STARTED` `STEP_FINISHED` | lifecycle |
| Text messages | `TEXT_MESSAGE_*` | streaming |
| Tool calls | `TOOL_CALL_*` | streaming |
| Reasoning | `REASONING_*` | streaming |
| State | `STATE_SNAPSHOT` `STATE_DELTA` `MESSAGES_SNAPSHOT` | snapshot-delta |
| Activity | `ACTIVITY_SNAPSHOT` `ACTIVITY_DELTA` | snapshot-delta |
| Subagents | `SUBAGENT_STARTED` `SUBAGENT_FINISHED` `SUBAGENT_ERROR` | lifecycle |
| Passthrough | `RAW` `CUSTOM` | standalone |

Only the run lifecycle is mandatory for a producer. A consumer must accept all families;
an event from an unused family is well-formed, not unrecognised.

Shared state uses the snapshot-delta pattern: `STATE_SNAPSHOT` replaces wholesale,
`STATE_DELTA` amends by JSON Patch, `MESSAGES_SNAPSHOT` carries the conversation. State
and messages round-trip through the consumer on every run, which is why the spec forbids
secrets in them and requires consumers to treat reasoning and encrypted artefacts with
conversation-level confidentiality.

Human-in-the-loop became first-class in 1.0. `RUN_FINISHED` carries an optional
`outcome`: absent or `success` means success, `interrupt` carries what the run is waiting
for, and `cancelled` marks a deliberate stop. `Interrupt` entries appear on the run input
and the interrupt-resume pattern binds them. A run that stops on a frontend tool call
finishes as success, never as an interrupt, and may name unanswered calls in
`pendingToolCallIds`.

A transport is a binding, and semantics are identical across all of them. The binding
contract requires ordered complete delivery, delivery of `RunAgentInput` before any event,
a termination signal distinguishable from truncation, and an out-of-stream error path for
a structurally invalid input. Two standard bindings share the request half
([transports](https://docs.ag-ui.com/spec/1.0/basic/transports)):

1. **HTTP + SSE.** An implementation that speaks HTTP must support it.
2. **HTTP + Protobuf.** Optional, negotiated by media type, 4-byte length-prefixed frames
   generated from the same schema, with cross-implementation parity pinned by a shared
   byte corpus.

Custom transports are permitted; JSON ones should use the SSE framing. A truncated run
has no outcome: a consumer must not synthesise `RUN_FINISHED` and must not report success.

Authentication is deliberately absent. The spec states: "Authentication and
authorization are properties of the binding and the application, not of the protocol:
AG-UI defines no credential." Middleware runs before enforcement; 1.0 added a
post-middleware enforcement pipeline that strips against the schema and validates.
Unrecognised events and fields survive translation to enforcement, which drops the event,
strips unknown members and warns; a malformed known value is fatal.

Versioning is in-band: the consumer declares `RunAgentInput.protocolVersion`, the producer
answers on `RUN_STARTED.protocolVersion`, and absence identifies a pre-versioning peer.
Retired shapes (`THINKING_*`, the `subAgents` key) are translated at the compatibility
boundary rather than dropped.

The 1.0 specification sets an explicit division of authority: the schema governs
structure, the document governs behaviour, and "if the two disagree about structure, the
schema wins and this document has a bug."

### A2UI

The stated philosophy is "safe like data, but expressive like code." An agent sends a
declarative JSON description; the client renders it with its own native component library.
The agent may only request components from a catalog the client pre-approves. The Smart
Wrapper registry pattern lets a client substitute any component, including secure iframe
containers, keeping sandboxing and trust ladders in the client's hands. There is no code
execution and no crossing of a trust boundary with an HTML or JavaScript bundle.

In v1.0 each message contains exactly one of six envelope keys: `createSurface`,
`updateComponents`, `updateDataModel`, `deleteSurface`, `callRendererFunction`,
`agentFunctionResponse`. v0.9.1 had four; the two function-call keys are the new
client-to-server RPC. v1.0 also allows the initial component tree and data model to be
embedded in `createSurface`, giving single-message UI instantiation.

The object model is an adjacency list. A surface holds a flat list of components related
by `id` reference, one of which must be `"id": "root"`, mounting under an implicit
canonical `Surface` container that always has `"child": "root"` and cannot be modified by
`updateComponents`. Data binding uses `Dynamic*` types accepting a literal, a JSON Pointer
`path`, or a `FunctionCall`. A `ChildList` is either a static `array` of `ComponentId` or a
`template` object with a `componentId` and a binding `path`. `catalogId` is a string,
conventionally URI-shaped, that need not resolve to anything. `surfaceId` is globally
unique for the renderer's lifetime; recreating an existing one without deleting it is an
error. `sendDataModel: true` makes the renderer attach the full surface data model to
every outbound message.

v1.0 ships three schemas: `common_types.json`, `agent_to_renderer.json` for the envelope,
and `catalogs/basic/catalog.json`. The envelope is catalog-agnostic through a placeholder
`$ref: "catalog.json#/$defs/anyComponent"`, so a client swaps in its own catalog. Custom
catalogs carry hard typing obligations: single child references must use `ComponentId`
and lists must use `ChildList`. A catalog that uses `{"type":"string"}` for a child id
makes the validator treat the id as literal text and skip existence checking entirely.

Transport is explicitly agnostic, with a four-part contract: reliable ordered delivery,
because A2UI is stateful and reordering corrupts the UI; message framing over JSONL,
WebSocket frames or SSE events; a metadata mechanism for `sendDataModel` and capability
exchange; and an optional bidirectional channel for `action` messages. Named bindings are
AG-UI, described as "the standard transport binding for Agent-to-User Interaction"; A2A
via a formal extension; MCP over tool calls, outputs and resource subscriptions; plus
SSE+JSON-RPC, WebSockets and REST.

The A2A extension is concrete
([v1.0 A2A extension spec](https://a2ui.org/specification/v1.0-a2ui-extension-specification/)).
The extension URI is `https://a2ui.org/a2a-extension/a2ui/v1.0`, with the version encoded
in the URI. Activation is optional, via the `X-A2A-Extensions` header on JSON-RPC/HTTP or
`sendMessageParams.metadata["X-A2A-Extensions"]` on gRPC. Negotiation is de facto: the
renderer attaches `message.metadata["a2uiRendererCapabilities"]` shaped as
`{ "v1.0": { supportedCatalogIds: [...] } }`, and agents may advertise the extension in
`AgentCard.capabilities.extensions[].params` with `supportedCatalogIds` and
`acceptsInlineCatalogs`. The payload is an A2A `DataPart` with
`data.metadata["mimeType"] = "application/a2ui+json"`; `data` is a non-transactional
array processed sequentially, atomic only per message. The spec carries a live footnote:
"do not use `accepted_output_modes: ['a2ui']` (which is not an A2UI standard) to trigger
A2UI."

### MCP Apps

The mechanism is an iframe containing an HTML and JavaScript bundle, delivered as an MCP
`ui://` resource.

- **Resource declaration.** URIs must use the `ui://` scheme. In the MVP, `mimeType` must
  be `text/html;profile=mcp-app`; "other content types are reserved for future
  extensions." Content arrives via `resources/read` as `text` or as base64 `blob` and must
  be a valid HTML5 document. Resources are declared at tool-registration time, which
  enables host prefetching, template/data separation and host-side review at connection
  time.
- **Tool to UI linkage.** The tool descriptor carries `_meta: { ui: { resourceUri:
  "ui://weather/forecast" } }`.
- **Three entities.** The **Server** declares tools and UI resources. The **Host** is the
  chat client that embeds views and proxies communication. The **View** is the UI in a
  sandboxed iframe. Host-to-View communication is JSON-RPC over `postMessage`, its own MCP
  dialect rather than stdio or HTTP. The View's `App` and the Host's `AppBridge` both
  subclass `Protocol` from `@modelcontextprotocol/client`, while a separate outer `Client`
  connects the Host to the real server; the spec is explicit that keeping those connections
  separate "preserves the Apps-only iframe handshake and prevents iframe capabilities from
  leaking into the server connection."

The five lifecycle phases ([overview](https://apps.extensions.modelcontextprotocol.io/api/documents/overview.html)):

| Phase | Messages |
| --- | --- |
| 1. Discovery | `resources/list` with `ui://` resources; `tools/list` with `_meta.ui` |
| 2. Initialization | View `ui/initialize`; Host `McpUiInitializeResult`; View `ui/notifications/initialized`; optional `ui/notifications/tool-input-partial` (0..n) then `ui/notifications/tool-input` |
| 3. Data delivery | `ui/notifications/tool-result` with `content` and optional `structuredContent`, or `ui/notifications/tool-cancelled` |
| 4. Interactive | View to Host: `tools/call`, `resources/read`, `ui/message`, `ui/update-model-context`, `ui/open-link`, `notifications/message`. Host to View: `ui/notifications/host-context-changed`, `ui/notifications/size-changed` |
| 5. Teardown | Host sends `ui/resource-teardown` and should await a response to prevent data loss |

`ui/initialize` is the only handshake on the iframe channel and is "authoritative for
Apps capabilities and identity." `ui/notifications/initialized` is the public View-ready
signal. `structuredContent` goes to the UI and is not added to model context.

Tool visibility defaults to `["model","app"]`. `["app"]` hides a tool from the model
while leaving it callable by the View via `tools/call`, which is how refresh buttons,
pagination and form submission stay out of the agent's context.

Host context carries theme, locale, timezone, display mode (`inline`, `fullscreen` or
`pip`), container dimensions and platform. Views declare supported modes, hosts declare
provided modes, and the host always has final say over its own UI. Theming uses CSS custom
properties with fallbacks such as `--color-background-primary`, changeable live.

Negotiation is progressive enhancement. Hosts advertise in the `extensions` field of
`io.modelcontextprotocol/clientCapabilities`, for example
`{ "io.modelcontextprotocol/ui": { "mimeTypes": ["text/html;profile=mcp-app"] } }`;
servers advertise in the `server/discover` response's `capabilities.extensions`. Both
sides must declare. If a host does not support the extension, tools still work and return
text.

The security model has five parts
([SEP-1865](https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx)):

1. **Sandboxed iframe** with no host DOM, cookies or storage, all communication through
   `postMessage` so the channel is auditable.
2. **Server-declared CSP** in `_meta.ui.csp` with four origin lists: `connectDomains` to
   `connect-src`, `resourceDomains` to `img-src`/`script-src`/`style-src`/`font-src`/`media-src`
   with wildcards allowed, `frameDomains` to `frame-src`, and `baseUriDomains` to
   `base-uri`. It is restrictive by default: if `ui.csp` is omitted the host must use
   exactly `default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self'
   'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none';`.
   A host may restrict further but must not allow undeclared domains, and should log CSP
   configurations.
3. **`permissions`** for `camera`, `microphone`, `geolocation` and `clipboardWrite`, mapped
   to the inner iframe `allow` attribute and Permission Policy. Apps should not assume
   they are granted and must feature-detect.
4. **Double-iframe sandbox proxy for web hosts**, using the reserved methods
   `ui/notifications/sandbox-proxy-ready` and
   `ui/notifications/sandbox-resource-ready`, the latter carrying `html` plus optional
   `sandbox` attribute override, `csp` and `permissions`. Desktop and native hosts render
   the View directly; web hosts render a same-host-controlled proxy iframe on a different
   origin which then renders the inner iframe.
5. **A per-resource `domain` field** for a dedicated sandbox origin, explicitly
   host-dependent. The spec's own examples are `*.claudemcpcontent.com` and
   `*.oaiusercontent.com`.

#### The `window.openai` compatibility surface

OpenAI publishes the mapping between its extensions and the standard
([chatgpt-ui](https://developers.openai.com/plugins/build/chatgpt-ui)):

| Goal | MCP Apps standard | ChatGPT compatibility alias |
| --- | --- | --- |
| Link tool to UI resource | `_meta.ui.resourceUri` | `_meta["openai/outputTemplate"]` |
| Receive tool input | `ui/initialize` plus `ui/notifications/tool-input` | `window.openai.toolInput` |
| Receive tool results | `ui/notifications/tool-result` | `window.openai.toolOutput` |
| Call a tool from the UI | `tools/call` | `window.openai.callTool` |
| Send a follow-up message | `ui/message` | `window.openai.sendFollowUpMessage` |

Also retained as compatibility fields: `_meta["openai/visibility"]`, an alias of
`_meta.ui.visibility`; `_meta["openai/widgetAccessible"]`; `_meta["openai/profile"]`;
`_meta["openai/toolInvocation/invoking"]` and `/invoked`; `_meta["openai/fileParams"]`;
and `window.openai.toolResponseMetadata`, the canonical widget-only result metadata that
preserves the full MCP envelope including hidden `_meta`.

Genuinely ChatGPT-only extensions, all on `window.openai`: `requestModal({params,
template})`, where the template URI is another `ui://` URI from the same server;
`requestCheckout` for Instant Checkout; `uploadFile(file, {library})`; `selectFiles()`;
`getFileDownloadUrl({fileId})`; `requestDisplayMode`; `requestClose()`;
`notifyIntrinsicHeight`; `openExternal({href, redirectUrl})`; `setOpenInAppUrl`;
`widgetState` and `setWidgetState`; and context values `theme`, `displayMode`, `maxHeight`,
`safeArea`, `view`, `userAgent` and `locale`, delivered through an `openai:set_globals`
event with a `useOpenAiGlobal` React helper.

The substantive idea inherited from the Apps SDK lineage is the decoupled data-tool and
render-tool pattern. Do not attach a widget template to every tool. Data tools fetch,
compute and mutate, returning `structuredContent` and no template; render tools take
prepared data and return the template. Only the render tool carries
`_meta.ui.resourceUri`. The stated rationale is that attaching a template to every call
makes the host re-render the iframe too often, while splitting lets the model fetch and
reason over data before deciding to render, "making it much more likely that it will
accomplish the user's specific expressed goal." The worked example is
`render_listings_widget`, and the docs note the pattern "is part of the MCP Apps
architecture."

Presentation modes are inline card, inline carousel, fullscreen and picture-in-picture,
with the guidance "Choose the smallest presentation that lets people understand the
result." Host-backed navigation mirrors the iframe's history into the host's UI, so a
React Router `BrowserRouter` works.

The UI layer is model-independent because rendering happens server-side inside the MCP
server; model availability is gated by plan and workspace, not by model. No primary source
ties a specific model snapshot to widget behaviour [UNVERIFIED].

### WebMCP

The mechanism is a browser API that lets a page register JavaScript tools with the
browser's agent, or an extension's. The spec's framing: "Web pages that use WebMCP can be
thought of as Model Context Protocol (MCP) servers that implement tools in client-side
script instead of on the backend." This is site-to-agent tool exposure, the inverse
direction from the other four entries
([Chrome documentation](https://developer.chrome.com/docs/ai/webmcp)).

`document.modelContext` is a `ModelContext` holding a tool map of tool-definition structs:
`name` (1 to 128 characters, ASCII alphanumerics plus `_-.`, unique in the map), `title`
(string or null), `description`, `input schema` as a stringified JSON Schema, `execute
steps`, `annotations`, and `exposed origins`, initially empty. Annotations are four
booleans: `read-only hint`, `untrusted content hint`, `consequential hint` and `debugging`.

The API surface is `navigator.modelContext` and `document.modelContext`, with
`registerTool({name, title, description, inputSchema, execute, annotations,
exposedOrigins})` returning a promise, `executeTool()`, and the events `toolchange` and
`toolcancel`, the latter a `ToolCancelEvent` carrying `toolName`. A declarative variant
registers tools from HTML form-element attributes, synthesising a JSON Schema from the
form and generating execute steps that fill the form and its form-associated elements.

The pending-execution model has two levels. A local pending tool execution map lives on
each `ModelContext`'s internal context, and a pending tool executions map lives on the
traversable navigable, mutated only in parallel "to simulate the single, authoritative
'browser process' that most modern browsers implement, where execution tracking sits
outside any individual Document process's event loop, and is accessed asynchronously via
some inter-process communication mechanism."

Cross-document exposure requires both that the target document is allowed to use the
`tools` feature and that the tool is exposed to that origin, either same-origin or listed
in `exposedOrigins`. `notifyDocumentsOfToolChange` walks inclusive descendant navigables
and fires `toolchange` where allowed, and the spec documents that `toolchange` timing
cannot be relied upon relative to other queued tasks; parent and child ordering is
guaranteed, the post-register task is not. Unloading-document cleanup removes pending
executions and either completes them, when the caller survives and the target dies, or
cancels them, when the target survives and the caller dies.

Gating is by the `tools` Permissions Policy, which defaults to `self` so cross-origin
iframes are off unless `allow="tools"`, and by origin isolation: WebMCP is disabled in any
document with `document.domain` set or `Origin-Agent-Cluster: ?0`, "to ensure that the
document's origin remains stable throughout the tool's lifetime."

Debuggability is first-class: a dedicated DevTools Protocol domain lists registered tools,
invokes tools and logs all agent calls, and declarative-registration problems such as
missing names or descriptions are reported through the Audits domain.

### NLWeb

The mechanism is a server-side semantic layer, in two parts. The protocol is a site's
natural-language endpoint, `/ask`, returning JSON in Schema.org terms. The reference
implementation, `AskAgent`, reads existing structured markup — products, recipes,
attractions, reviews — to answer queries. The stated thesis is that "Schema.org and
related semi-structured formats like RSS — used by over 100 million websites — have become
not just de facto syndication mechanisms, but also a semantic layer for the web," and
that "NLWeb is to MCP/A2A what HTML is to HTTP."

Every NLWeb instance is also an MCP server, exposing a core `ask` method returning
Schema.org. A2A support is described as "soon" in the README, meaning it is not
implemented.

Modules are `AskAgent` (the core NL query agent with LLM and vector-store connectors),
`AgentFinder` (agent discovery and routing), `DataFinder` (NL to SQL for HubSpot, Dynamics
365 and Jira), `ModelRouter` (LLM routing and scoring for cost) and `NLWebScorer` (neural
rankers). Supported platforms are Windows, macOS and Linux. Supported vector stores are
Qdrant, Snowflake, Milvus, Azure AI Search, Elasticsearch, Postgres and Cloudflare
AutoRAG. Supported models are OpenAI, DeepSeek, Gemini, Anthropic, Inception and
HuggingFace. Setup guides exist for Azure; GCP and AWS are listed as coming soon. CI/CD
pipelines are explicitly not included.

The project's own README is explicit about its role: "NLWeb provides practical
implementation code — not as the definitive solution, but as proof-of-concept
demonstrations showing one possible approach." It also states that most production
deployments will use their own user interface, integrate NLWeb directly into their
application environment, and connect to live databases instead of duplicating content to
avoid freshness issues. The bundled `static/` web UI is a sample, not the product.

NLWeb is not an agent-to-UI protocol. It is site-to-agent semantics with a demonstration
chat front end.

## What changed recently

### AG-UI

| Date | Change |
| --- | --- |
| 2025-04-09 | Initial public release, the only entry in the official What's New changelog, which has not been updated since [UNVERIFIED: the date as printed; the project surfaced publicly in May 2025] |
| Late 2025 | A2UI and MCP Apps added to AG-UI's "Generative UI" table; A2A middleware; AWS Strands, Claude Agent SDK, Claude Managed Agents, Langroid, Oracle Agent Spec, Bedrock AgentCore |
| 2026-05-05 | CopilotKit raises a $27M Series A |
| 2026-09-17 | **AG-UI 1.0.0** |
| 2026-09-23 | `ag_ui_strands` 0.4.1 adopts the 1.0 part renames, breaking |
| 2026-09-29 | **AG-UI 1.0.1**, `@ag-ui/client` only |

The 1.0 changelog is the largest single revision in the protocol's life. Ten major
changes: the normative specification exists; runs report `outcome`; subagents via
`subagentRunId` and `SUBAGENT_*`; `THINKING_*` retired in favour of `REASONING_*` including
`REASONING_ENCRYPTED_VALUE`; `ACTIVITY_SNAPSHOT` and `ACTIVITY_DELTA` amend
object-content messages by JSON Patch; unknown-versus-malformed made normative; rules for
the chunked streaming form, where the first chunk must carry `messageId` and role for text
and `toolCallId` and `toolCallName` for tool calls, with conflicting repeats fatal; a binary
wire in the form of HTTP+Protobuf; `AgentCapabilities` moved into the schema and
generated; and tool results carrying content parts. Ten minor changes include normative
metadata merge with last-write-wins, no recursion and a reserved `ag-ui` key;
absent-means-absent with no `null`; per-provider token usage with subagent accounting
boundaries; multimodal input parts including a new `file` source for provider-uploaded
bytes; and in-band version negotiation.

### A2UI

| Date | Change |
| --- | --- |
| 2025-11-20 | v0.8 and v0.9.1 spec records created |
| 2025-12-03 | v0.9.1 last updated: standardises `application/a2ui+json`; relaxes `surfaceId` constraints |
| 2025-12-15 | Public announcement, Google Developers Blog |
| Q4 2025 | v0.8.0 spec; A2A extension; Flutter, Angular and Lit renderers; AG-UI/CopilotKit integration; Apache 2.0 public release |
| Q2 2026 | v0.9 with the "prompt-first" shift, web core and renderers updated, official React renderer, theming, A2UI Agents SDK (Python) |
| 2026-06-08 | v1.0 candidate last updated |
| 2026-06 | Roadmap last updated; v1.0 finalisation and a renderer certification programme still targeted for Q4 2026 |

The prompt-first shift embeds the specification in the model's prompt rather than
constraining generation with a structured-output schema. The acknowledged cost, stated in
the spec, is that it "requires more complex post-generation validation, as the LLM is not
strictly constrained by the schema."

The 2026-06-08 v1.0 candidate revision adds client-to-server RPC — `callRendererFunction`,
`callAgentFunction`, `rendererFunctionResponse`, `agentFunctionResponse` — verified against
runtime catalog definitions; single-message UI instantiation; removal of the rigid `theme`
block under the name "Decoupled Branding", renamed `surfaceProperties`; catalog functions
refactored to object maps for O(1) lookup with `$schema` and `$id`; and UAX #31 Unicode
naming with `@` reserved for system context evaluations such as `@index`.

### MCP Apps and its absorbed predecessors

| Date | Change |
| --- | --- |
| 2025-10-06 or November 2025 | Apps SDK and apps in ChatGPT launch; the two dates conflict between primary sources [UNVERIFIED] |
| 2025-11-21 | SEP-1865 created |
| 2026-01-26 | **MCP Apps goes Stable as the first official MCP extension** |
| 2026-01-26 | mcp-ui v6.0.0, release title "mcp-ui → mcp apps!" |
| 2026-01-26 | OpenAI, VS Code and Goose ship MCP Apps support the same day ([VS Code blog](https://code.visualstudio.com/blogs/2026/01/26/mcp-apps-support)) |
| 2026-02-13 to 2026-05-09 | mcp-ui ships experimental message support, then `AppRenderer` host props; last release 2026-05-09 |
| 2026 (exact date NOT ESTABLISHED IN SOURCE) | SDK 2.x with MCP core SDK v2 peers and a 1.x/2.x wire-compatibility guarantee; four agent skills ship — `create-mcp-app`, `migrate-oai-app`, `add-app-to-server`, `convert-web-app` — installable via `/plugin marketplace add modelcontextprotocol/ext-apps` |
| 2026-08-24 to 2026-09-05 | Codex `mcp-server` deprecated then removed; the replacement `app-server` is experimental and "isn't supported for production workloads" |
| 2026-09 | Four official extensions and a published client matrix; core protocol version `2026-07-28` in the negotiation examples |

OpenAI's own surface moved five times in roughly one quarter: Apps SDK to Plugins in the
documentation, the app directory to the Plugin Directory on 2026-07-09 [UNVERIFIED: the
exact date is quoted in localized Help Center versions, not in the current English
revision], custom GPTs retiring into plugins, Agent Builder shutting down 2026-11-30, and
the product-model split where "app" means a service connector and "plugin" means the
package ([help article](https://help.openai.com/en/articles/11487775-connected-apps-in-chatgpt),
[release notes](https://openai.com/products/release-notes/rss.xml)).

Further dated OpenAI items: plugins buildable and installable in Codex on 2026-03-25;
role-specific Codex plugins for Business and Enterprise on 2026-06-02 and 2026-06-05, with
66 single-purpose skills and Enterprise plugin sharing on by default; ChatGPT Work
introduced 2026-07-09; a Data plugin in ChatGPT Work and Codex on 2026-09-10; the planned
custom GPT retirement announced 2026-09-11; multi-account plugin connections 2026-09-17;
plugins in Voice 2026-09-23; and custom GPT Enterprise retirement dates of 2026-09-17,
2026-09-25 and 2026-12-11.

### WebMCP

| Date | Change |
| --- | --- |
| 2025-07-08 | ChromeStatus entry created; blink-dev intent thread |
| 2025-11-12 | W3C "AI Agents and The Web" workshop minutes discuss WebMCP alongside NLWeb and MCP-UI |
| Chrome M146 | Chrome DevTrial, `desktop_first: 146`, Android 146 |
| 2026-05-18 | [developer.chrome.com/docs/ai/webmcp](https://developer.chrome.com/docs/ai/webmcp) published, covering both APIs, origin-trial enrolment, `chrome://flags/#enable-webmcp-testing`, origin isolation and Permissions Policy, the Model Context Tool Inspector extension, and an explicit Limitations section |
| 2026-08-07 | That page last updated |
| 2026-09-17 | CG draft regenerated; Bikeshed metadata `updated Thu Sep 17 15:24:44 2026` |
| 2026-09-28 | Origin-trial extension requested, `desktop_last` 149 to 156 to 162, because origin-trial feedback produced API improvements still being implemented |
| 2026-09-29 | Draft Community Group Report dated; the same page has previously rendered a status line of 26 August 2026 |

### NLWeb

| Date | Change |
| --- | --- |
| 2025-05-19 | Microsoft announcement at Build |
| 2025-10-16 | W3C Community Group proposed by Ramanathan Guha |
| 2025-10-20 | W3C Community Group launched; still no chair |
| 2025-11-12 | W3C "AI Agents and The Web" workshop treats NLWeb and WebMCP as the two live approaches |
| 2026-05-11 | Last substantive non-dependabot change, a `mermaid` bump inside `openai-apps-sdk-integration/` |
| 2026-06-10 | Most recent commit, a Dependabot merge |
| 2026-09-29 | `nlweb.ai/spec` fails TLS validation |

## Evidence of adoption

### AG-UI

First-party integrations per AG-UI's own tables
([introduction](https://docs.ag-ui.com/introduction)): Microsoft Agent Framework, Google
ADK, AWS Strands Agents, AWS Bedrock AgentCore, Mastra, Pydantic AI, Agno, LlamaIndex,
AG2 and Oracle Agent Spec. Partnerships: LangChain, CrewAI and A2A, as middleware.
Community: Claude Agent SDK, Claude Managed Agents and Langroid. Clients: CopilotKit,
Terminal+Agent, Slack and Teams via the CopilotKit Channels SDK and the OpenTag reference
app, and React Native. Generative-UI targets: A2UI and MCP Apps.

These tables are maintained by the project itself, so the framework claims are
vendor-asserted. Two are independently corroborated: Microsoft documents the integration
at `learn.microsoft.com/en-us/agent-framework/integrations/by-component/ui/ag-ui`, a page
stating "last verified: 2026-09-05", and AWS ships a developer-guide contract page named
`runtime-agui-protocol-contract.html` — full URL NOT ESTABLISHED IN SOURCE. No
equivalent independent page was found for Google ADK.

### A2UI

The Google ecosystem is the base. The Flutter GenUI SDK (`github.com/flutter/genui`)
states it "uses A2UI under the hood". Google ADK is in progress, and the flagship
quickstart is "a Gemini powered ADK agent and Lit renderer". The Lit and Angular renderers
are credited to Google teams, Opal and Angular, in the Q4 2025 milestones. CopilotKit
contributes the AG-UI binding and ships an A2UI runtime. AG2 ships a documented
`A2UIAgent`. Lynx ships an A2UI v0.9 ReactLynx renderer.

The roadmap's renderer table ([roadmap](https://a2ui.org/roadmap/)):

| Renderer | Status as of the June 2026 roadmap |
| --- | --- |
| Web Core Lib | Stable |
| Lit Web Components | Stable |
| Angular | Stable |
| Flutter via GenUI | Stable |
| React (official) | Stable |
| Lynx / ReactLynx | Stable, v0.9 |
| SwiftUI | Planned, Q2 2026 |
| Jetpack Compose | Planned, Q2 2026 |
| Vue, Svelte/SvelteKit, ShadCN | Proposed |

No shipped end-user product built natively on A2UI was found in primary sources
[UNVERIFIED: any claim that A2UI ships inside a Google consumer or Cloud product]. The
Google Developers Blog post describes research across teams and an internal A2A
experiment, not an A2UI deployment.

### MCP Apps

The [official client matrix](https://modelcontextprotocol.io/extensions/client-matrix) at
the research date:

| Host | MCP Apps |
| --- | --- |
| Claude (web) | Confirmed |
| Claude Desktop | Confirmed |
| VS Code GitHub Copilot | Confirmed |
| Microsoft 365 Copilot | Confirmed |
| Goose | Confirmed |
| Postman | Confirmed |
| MCPJam | Confirmed |
| ChatGPT | Confirmed |
| Cursor | Confirmed |
| Archestra.AI | Confirmed |
| PostHog Code | Confirmed |

ChatGPT is listed as Partial for Skills over MCP, which is a different capability. Host
documentation linked from ext-apps includes `claude.com/docs/connectors/building/mcp-apps/`,
`code.visualstudio.com/blogs/2026/01/26/mcp-apps-support`, Goose, Postman, MCPJam,
mcp-use Inspector and Alpic. Pre-standard mcp-ui adopters credited in SEP-1865 are
Postman, HuggingFace, Shopify, Goose and ElevenLabs. At SDK level, TypeScript, Python and
Ruby come via mcp-ui, and the official MCP Python SDK v2 ships an `apps` module.

One discrepancy: ChatGPT is confirmed by OpenAI's documentation and by the client matrix,
but it is absent from ext-apps' own "Supported Clients" badge row, which still lists the
Claude, VS Code, Goose, Postman, MCPJam, mcp-use and Alpic set
[INFERENCE: stale README art; the matrix is the more current source].

On the OpenAI side, the directory is populated: Zendesk and OneNote on 2026-09-03, Data
on 2026-09-10, Healthcare Public Data and Epic, College Educator, K-12 Educator and
College Student, and partner credit promotions for Stripe, QuickBooks, HubSpot, Gusto,
Dropbox and Canva on 2026-09-08. Third-party surface visible in the documentation
includes `@openai/apps-sdk-ui`, `github.com/openai/openai-apps-sdk-examples`, the
"Submit your Claude Code plugin to OpenAI" guide, and the official `migrate-oai-app`
agent skill in the MCP repository.

OpenAI also ships Excalidraw, Cesium, Three.js and Shadertoy as official reference MCP
Apps [UNVERIFIED: no source URL for this claim was captured; URL NOT ESTABLISHED IN
SOURCE].

### WebMCP

The origin trial is live with third-party support (`ot_has_third_party_support: true`) and
a public use counter, `kModelContextRegisterTool`, bucket 5791. ChromeStatus's own
web-framework signal reads: "Chrome web store features about 9 different extensions with
WebMCP on their title and 4* or more ratings," plus the official Model Context Tool
Inspector extension. ChromeStatus activation risks record that "There are several Chrome
extensions already available that allow cloud-LLM-based agents to discover and call WebMCP
tools. It is also possible to use the Prompt API to call WebMCP tools using on-device
models."

First-party demonstrations in `GoogleChromeLabs/webmcp-tools` are WebMCP zaMaker
(imperative), a React flight search (imperative) and Le Petit Bistro (declarative), plus an
appointment-booking comparison of DOM scraping against tool calling. Firefox and Safari
both show "No signal."

A slide by Andrea Volpini of WordLift at the W3C and GS1 "Ecommerce for Humans and AI
Agents" event in September 2026 asserts "W3C WebMCP co-authored by Microsoft and Google ·
adopted by OpenAI" ([slide](https://www.w3.org/2026/09/ecommerce-agents/slides/Andrea_Volpini.pdf)).
This is vendor commentary at a conference, not a W3C or OpenAI statement, and is not
treated as adoption evidence [UNVERIFIED]. Separately, Google argued at the same event that
"better surfaces can reduce the need for smarter retrieval," with a reported +29.6% and
+29.8% from a navigable entity page and the identifier arXiv:2603.10700 [UNVERIFIED:
single-sourced through the event; primary URL and paper NOT ESTABLISHED IN SOURCE].

### NLWeb

Nothing verifiable from primary sources. What exists is 6.3k GitHub stars, Microsoft
ownership, a W3C Community Group with no output, an Azure setup guide, and a January 2026
Microsoft TechCommunity PostgreSQL walkthrough [UNVERIFIED: any third-party production
NLWeb deployment. The TechCommunity post and a February 2026 InfoWorld piece are vendor and
community content, not deployment evidence]. There is no shipper list, no conformance
programme and no Community Group output.

## Sharp edges

### AG-UI

- **Single-vendor governance with a commercial overlay.** No foundation, no neutral
  charter, no published decision process beyond `CODEOWNERS`. The specification's authority
  model and the funding model point the same direction.
- **The README under-counts the event types.** The repository README still says agents
  emit events "compatible with one of AG-UI's ~16 standard event types", while the 1.0
  specification enumerates 31 event types in eight families
  ([spec events](https://docs.ag-ui.com/spec/1.0/events)). The README has not been
  reconciled with 1.0. An implementation driven from the README alone under-builds.
- **1.0 part renames break typed consumers.** `InputContent` becomes `ContentPart`,
  `TextInputContent` becomes `TextPart`, `ImageInputContent` becomes `ImagePart`, and
  `InputContentSource` becomes `PartSource` with `DataSource` and `UrlSource`. The wire is
  unchanged and the SDKs keep old names as aliases, but generated types change. Every
  binding outside TypeScript, Python and .NET is community-maintained with no obligation to
  have migrated.
- **The generative-UI track is the least mature part.** The AG-UI-native generative-UI
  document is still Status Draft ([generative UI draft](https://docs.ag-ui.com/drafts/generative-ui))
  and records its own blockers: OpenAI enforces a 1024-character tool-description limit
  while Gemini and Anthropic do not; classes, nesting, `$ref` and `oneOf` are not reliably
  supported across providers; and injecting a large UI description language degrades agent
  performance.
- **The generative-UI mechanisms are bolted on.** A2UI and MCP Apps are listed as AG-UI
  integration targets. There is no normative AG-UI statement of how an A2UI payload or an
  MCP App travels an AG-UI stream; that is vendor-side, in CopilotKit middleware.
- **The trust boundary is explicitly outside the protocol.** The specification's security
  section states that it "cannot enforce these principles." `CUSTOM` and `RAW` passthrough
  events are opt-in escape hatches with deliberately unspecified limits.
- **The Protobuf binding is optional and the parity guarantee is a byte corpus, not a
  conformance suite.**

### A2UI

- **The candidate has stalled.** v1.0 was last updated 2026-06-08 and the recommended
  production version v0.9.1 was last touched 2025-12-03, while the roadmap still carries
  Q4 2026 targets for finalisation and a certification programme that does not exist.
- **The v0.9 to v1.0 delta is large and mostly breaking.** The envelope schema is renamed
  (`server_to_client.json` to `agent_to_renderer.json`), the capability and data-model
  metadata keys are renamed (`a2uiClientCapabilities` to `a2uiRendererCapabilities`,
  `a2uiClientDataModel` to `a2uiRendererDataModel`, `server_to_agent` to
  `renderer_to_agent`), `theme` is removed outright, and a new RPC direction is added.
- **Validator blindness is a specification-level footgun.** The catalog typing rules are
  the only mechanism by which automated validators detect structural links. A plausible
  custom catalog using `{"type":"string"}` for a child id compiles, ships, and silently
  loses tree-integrity checking. The spec states the rule but cannot enforce it across
  third-party catalogs.
- **Self-declared preview status with 407 open issues** against a specification the README
  disclaims as still evolving.
- **Prompt-first traded safety for expressiveness** and moved validation burden onto every
  renderer.
- **Transport-agnosticism cuts both ways.** A2UI inherits whatever ordering, framing and
  backpressure each binding actually provides, with no cross-binding conformance suite.
- **Ecosystem asymmetry.** The two renderers that matter most for mobile are unshipped, so
  rendering natively across web, mobile and desktop currently holds only through Flutter, a
  single framework owned by one vendor.
- **A CopilotKit dependency inside a Google-origin protocol's happy path.** Some A2UI
  scaffolds from `npx create-ag-ui-app@latest` use CopilotKit's A2UI runtime under the hood.

### MCP Apps

- **The default CSP does not prevent injection into the app's own frame.** The mandatory
  default policy includes `script-src 'self' 'unsafe-inline'`. That defends the host and
  the network, not the app's own document. There is no subresource-integrity mechanism, no
  per-resource signing and no nonce mechanism.
- **The sandbox origin is explicitly non-portable.** `_meta.ui.domain` is host-defined and
  the spec's own examples, `*.claudemcpcontent.com` and `*.oaiusercontent.com`, differ
  between hosts. A server author cannot reason about origin identity across hosts, and a
  View cannot assume a stable origin for OAuth callbacks, CORS or API-key allowlists.
- **Host support is uneven in kind, not only in degree.** The client matrix is binary
  checkmarks, but the feature surface is not. A host may support `inline` but not `pip`,
  may not enforce the double-iframe proxy, may restrict which tools a View may call, or
  may disable `sendOpenLink`. The host has "final say over its own UI", so portable UI is
  a floor rather than a ceiling, and there is no conformance level.
- **"Servers declare, hosts enforce" is a trust inversion with no server-visible audit
  path.** The host should log CSP configurations, but the server cannot verify which policy
  was applied. A negligent or malicious host is undetectable by a conforming server.
- **HTML-only MVP.** `text/html;profile=mcp-app` is the sole normative content type, with
  other content types reserved for future extensions. There is no declarative non-HTML
  path in the standard.
- **Framework examples are examples, not requirements.** React, Vue, Svelte, Preact, Solid
  and vanilla ship as starters, and the `App` class is "a convenience wrapper, not a
  requirement." Implementable over raw `postMessage`, which is good for interoperability
  and bad for a reference conformance suite.
- **218 open issues** on a specification marked Stable.
- **The breaking-change policy is identifier-based.** The framework states that "If a
  breaking change is unavoidable, use a new identifier", for example
  `io.modelcontextprotocol/my-extension-v2` — deliberate fragmentation, in tension with
  extensions evolving independently of the core protocol.
- **mcp-ui's release drought is a supply-chain concern for the recommended host SDK.** No
  release in approximately 4.5 months while the spec evolves and MCP core moved to 2.x.

#### Absorbed predecessors

- **OpenAI's naming is a three-layer confusion.** "App" (service connector), "plugin" (the
  package), "Apps SDK" (the retired doc-set name, still the URL) and "widget/component"
  (the UI) coexist. The current English help article no longer carries the migration date;
  only localized versions do.
- **The compatibility layer is a fork risk.** `window.openai.toolInput` may legitimately be
  `null` for approval-gated tools, because ChatGPT does not preload gated arguments and
  delivers them after approval via `ui/notifications/tool-input`. OpenAI's own guidance,
  "Avoid branching on a host or product name. Test for the capability your UI needs", is
  simultaneously correct and an admission that the portable layer is insufficient
  [INFERENCE].
- **The most valuable app features are the least portable.** Checkout, the file library,
  modals, picture-in-picture, intrinsic-height reporting and external-link vetting are all
  `window.openai`-only. Portability holds for charts and forms, not for commerce flows.
  Instant Checkout is covered in [`commerce.md`](commerce.md).
- **Deprecation pile-up.** Agent Builder shuts down 2026-11-30; custom GPTs retire with
  Enterprise dates of 2026-09-17, 2026-09-25 and 2026-12-11; Codex `mcp-server` was removed
  2026-09-05; the replacement `app-server` is experimental and unsupported for production.
  Four overlapping migrations inside one quarter.
- **ChatKit's future is tied to Agent Builder's death.** The hosted path is explicitly a
  transition, with the destination the self-hosted advanced ChatKit integration.
- **The decoupled data-tool and render-tool pattern is advice, not specification.** It is
  documented as a best practice and as "part of the MCP Apps architecture" but has no
  normative status, and nothing stops a host re-rendering a widget on every call.

### WebMCP

- **A specification hole is readable in the normative text.** For declaratively registered
  tools, `execute steps` are "a set of 'internal' steps that have not been defined yet,
  that describe how to fill out a `<form>` and its form-associated elements." The
  declarative API, which carries the whole zero-refactor pitch, has no defined execution
  semantics in the CG draft. They live in a separate explainer and in Chrome's own
  documentation.
- **`toolchange` is explicitly non-deterministic in ordering.** The specification says so
  and still relies on cross-document notification. A client building a tool index from
  `toolchange` has to be defensive.
- **The event-loop model is aspirational.** The traversable-navigable browser-process map
  with in-parallel mutation and simulated IPC is a modelling device, not an interoperable
  requirement. A non-Chromium engine has no reason to implement it this way, and it is the
  interop surface that matters.
- **Security is delegated entirely to agents.** The ChromeStatus security risks state:
  "Sites may consume and expose sensitive information when their WebMCP tools are called by
  agents … LLM-based agents are susceptible to attacks such as indirect prompt injection,
  which can cause an exploited agent to exfiltrate sensitive information in its context to
  an attacker." Mitigation is a recommendation to agents plus a `secure-tools` guidance
  page. There is no host-enforced consent gate in the specification, in contrast to MCP
  Apps, where a server-declared, host-enforced CSP is normative. The `consequential` and
  `untrusted content` annotation hints are advisory only.
- **Discoverability is broken by construction.** Chrome's own Limitations section: "Clients
  and browsers must visit a site directly to know if it has callable tools." There is no
  index, registry or discovery protocol.
- **No headless story.** "While it may be possible to run WebMCP tools in headless
  environments, this API is primarily designed for local browser workflows with a human in
  the loop."
- **Refactoring burden on complex sites.** "If your site is highly complex, you likely need
  to refactor or add JavaScript to handle application and interface state." The
  ChromeStatus ergonomics risk records that "there is a risk that site authors … will need
  to duplicate functionality that currently exists to drive the user interface," mitigated
  only aspirationally.
- **Every review gate is Pending.** TAG, security and privacy review are all Pending,
  `intent_stage` is "None", `intent_to_ship_url` and `announcement_url` are both `null`.
  The 2026 shipping year is intent, not commitment.
- **Single-vendor momentum.** Chrome is the only engine with any signal, and the
  origin-trial extension to M162 is itself evidence of API churn.
- **`document.domain` silently disables WebMCP** with no diagnostic.

### NLWeb

- **No governance output in eleven months.** A Community Group that has not chosen a chair,
  published a draft or held a recorded meeting is not a standards track. The specification
  lives on a domain that is currently broken.
- **The specification URL fails TLS today.** `nlweb.ai/spec` returns
  `ERR_TLS_CERT_ALTNAME_INVALID` on 2026-09-29. For a project whose claim is a
  foundational layer for the AI web, the canonical specification is unreachable.
- **Repository dormancy.** No human commit in approximately 3.5 months; every recent
  commit is a Dependabot merge. The `openai-apps-sdk-integration/` directory is itself
  telling — an integration with a different vendor's SDK, last changed by a `mermaid`
  patch.
- **A2A support is aspirational.** "Every NLWeb instance also acts as an MCP server and
  soon A2A." More than a year after launch, the second transport does not exist.
- **The reference implementation is a demonstration and says so**, yet it is the actual
  deliverable. A site adopting NLWeb adopts 574+ files of Python, with committed
  `.hypothesis` and `.claude` directories, rather than a specification.
- **The vector-store and LLM-broker architecture is built on a 2025-vintage assumption**
  that model choice is a cost-routing problem. Google's September 2026 argument that
  "better surfaces can reduce the need for smarter retrieval" points the other way
  [UNVERIFIED, single-sourced as above]. This is a different layer carrying the same
  warning that retrieval machinery is displaced by structural markup.
- **Positioning against WebMCP is unresolved.** NLWeb is server-side, per-site, Python,
  MCP-wrapping, and needs a deployment per site. WebMCP is a browser platform API,
  declarative, zero-deploy for existing forms, behind a Chrome origin trial with a live
  use counter. They are not compatible, a site would plausibly do both, and no primary
  source describes a joint path.

## Overlaps and consolidation

### What actually merged: MCP Apps absorbed both predecessors

The [overview](https://apps.extensions.modelcontextprotocol.io/api/documents/overview.html)
states the motivation directly: "Before MCP Apps, each host implemented UI support
differently. MCP-UI, OpenAI's Apps SDK, and custom implementations all solved similar
problems with incompatible approaches. Server developers had to maintain separate adapters
for each host, and security models varied."

SEP-1865 confirms both were inputs. mcp-ui "developed the bi-directional communication
model and the HTML, external URL, and remote DOM content types", with adopters Postman,
HuggingFace, Shopify, Goose and ElevenLabs. The specification also states that "The
architecture of both the Apps SDK and MCP-UI have both significantly informed the design of
this specification."

Three dated markers mark the merge:

| Date | Marker |
| --- | --- |
| 2026-01-26 | mcp-ui client and server v6.0.0 released with the title "mcp-ui → mcp apps!" |
| 2026 (exact date NOT ESTABLISHED IN SOURCE) | The official MCP repository ships a `migrate-oai-app` agent skill, alongside `create-mcp-app`, `add-app-to-server` and `convert-web-app` |
| 2026-09 (exact date NOT ESTABLISHED IN SOURCE) | OpenAI's own documentation instructs "Start with MCP Apps" and demotes `window.openai` to compatibility aliases |

mcp-ui is not legacy code. It is the recommended host SDK for MCP Apps, Apache 2.0, last
released 2026-05-09. What remains of the old model is the legacy `UIResourceRenderer`
path and the Legacy MCP-UI Adapter guide. The claim "mcp-ui is deprecated" is false.

OpenAI's own surface area consolidated separately, in five renames and migrations across
one quarter: Apps SDK to Plugins in the documentation, the app directory to the Plugin
Directory on 2026-07-09, custom GPTs retiring into plugins between 2026-09-17 and
2026-12-11, Agent Builder shutting down 2026-11-30, and Codex `mcp-server` removed
2026-09-05.

### What remains genuinely contested: declarative JSON versus sandboxed HTML

This is the live axis, and both sides are active. A2UI's thesis is no code execution, a
client-owned component catalog, and an agent restricted to pre-approved components.
MCP Apps' thesis is server-owned HTML and JavaScript in a sandboxed iframe with a
server-declared, host-enforced CSP. The risk envelopes differ categorically and neither
side is attempting to absorb the other. AG-UI's documentation lists A2UI and MCP Apps as
parallel generative-UI targets, and A2UI's specification names AG-UI as "the standard
transport binding" while also being carried over MCP and A2A.

The two are composable: A2UI over AG-UI into an application, or MCP Apps inside an
MCP-host conversation. CopilotKit ships both. The "competition" framing between them is
wrong; what is contested is iframe HTML against declarative JSON
[INFERENCE: drawn from the two specifications' own security models, not stated in either].

Three signals indicate the layer's centre of gravity has moved from agent-authored UI
descriptions to server-shipped sandboxed HTML: OpenAI's decoupled data-tool and
render-tool pattern with widget templates on render tools only; MCP Apps reaching eleven
hosts including ChatGPT, Claude, VS Code and Microsoft 365 Copilot; and OpenAI shipping
Excalidraw, Cesium, Three.js and Shadertoy as reference MCP Apps [UNVERIFIED: source URL
NOT ESTABLISHED IN SOURCE]. A2UI's adoption surface is by contrast renderers and
framework demonstrations.

A third mechanism exists inside AG-UI itself. The AG-UI "Generative User Interfaces"
draft, authored by Markus Ecker, a CopilotKit maintainer, proposes a
`generateUserInterface(description, data, output)` frontend tool plus a pluggable
secondary generator emitting JSON Schema plus uiSchema, React, or anything else. Its
status is Draft, and it exists because hand-written tool renderers are limiting.

Two further genuine competitions, both outside this document's scope but adjacent to it:

- **AG-UI against ACP in the agent-to-client niche.** Both are agent-to-frontend protocols
  with streaming and tool calls. ACP, from Zed Industries and JetBrains, is editor-shaped
  with a public RFD process ([ACP updates](https://agentclientprotocol.com/updates)); AG-UI
  is web and application-shaped with broader framework adoption. Same slot, different
  audiences. ACP's mechanism is covered in [`acp-agent-client.md`](acp-agent-client.md).
  [UNVERIFIED: any head-to-head competitive dynamic; no primary source positions them
  against each other.]
- **WebMCP against NLWeb in the site-to-agent niche.** A server-side, per-site Python stack
  wrapping MCP against a declarative browser platform API. No primary source proposes
  interoperability between them.

A2A is connective tissue for A2UI rather than a competitor to it: 150+ organisations and
major cloud platforms per the Linux Foundation on 2026-04-09, A2A shipped 1.0, and the
A2UI A2A extension rides it with a versioned extension URI and
`application/a2ui+json` DataParts. See [`a2a.md`](a2a.md).

### The naming trap

"AG-UI" and "A2UI" are routinely confused, and the two names differ by one character in
one position while describing different layers. AG-UI is the transport and interaction
protocol, the event stream between an agent and a client. A2UI is the declarative UI
format, the JSON component description an agent sends to a client. AG-UI's own
documentation carries an explicit disambiguation callout. The two are related, in that
AG-UI is the declared standard transport for A2UI, but they are not alternative names for
one thing, and an implementation of one does not implement the other.

Two further collisions sit in the same layer. "MCP-UI", the community project now
repositioned as an SDK implementing MCP Apps, against "MCP Apps", the standard. And
"Apps SDK", the retired OpenAI documentation name that survives as a URL, against
"Plugins", the current name.

### Cross-cutting sharp edges

1. **Two of the five have no independent governance.** AG-UI is CopilotKit's; A2UI is
   Google's, with no foundation and a self-declared "early stage public preview". Both
   have the shape of standards and both carry vendor-fork risk. See
   [`governance.md`](governance.md).
2. **Only two have a foundation or foundation-adjacent home.** MCP Apps sits with the MCP
   Core Maintainers under the SEP process with a published interop matrix, by far the
   best-governed of the set, and A2A sits under the Linux Foundation. WebMCP is a W3C
   Community Group and says it is not a standard; NLWeb is a W3C Community Group that has
   produced nothing.
3. **"Standard" means four different things in this layer.** A normative specification on
   a standards track: none of the five. A Core-Mainer extension: MCP Apps. A Community
   Group draft behind a browser origin trial: WebMCP. A vendor-run open-source protocol
   with a 1.0 specification and a governance-to-spec mismatch: AG-UI. A pre-1.0 preview:
   A2UI.
4. **The security models are not comparable across the layer.** MCP Apps has a
   host-enforced, server-declared, restrictive-default CSP plus a sandboxed iframe. A2UI
   has no code execution at all and a client-owned catalog. WebMCP delegates security to
   the agent and names prompt injection as the risk with no host gate. AG-UI puts it
   explicitly out of scope and pushes obligations to implementors. Choosing among these is
   a security decision before it is a protocol decision. See [`security.md`](security.md).
5. **The `ui://` plus `_meta` pattern is the de-facto interoperability key for
   server-rendered UI**, whether via MCP Apps or via A2UI carried over MCP with a different
   MIME type. A server author shipping one HTML UI today reaches MCP Apps hosts; a
   declarative UI reaches renderer authors. These are different populations.
6. **Every major vendor is shipping a deprecation inside the same window.** OpenAI's Agent
   Builder on 2026-11-30, custom GPTs by 2026-12-11, Codex `mcp-server` already gone
   2026-09-05; mcp-ui quiet since 2026-05-09; ChatKit pivoting away from its hosted path.
7. **Two of the five have no deployed consumer base.** NLWeb has no verified third-party
   deployment, and A2UI at v0.9.1 has no shipped product found in primary sources. WebMCP
   has real shipping momentum but no deployed protocol adoption outside Chrome and roughly
   nine Chrome extensions.

The AG-UI human-in-the-loop machinery and the MCP Apps tool-visibility mechanism are
covered further in [`orchestration-hitl.md`](orchestration-hitl.md); per-vendor protocol
support is in [`platform-support.md`](platform-support.md).

## Sources

### AG-UI

- Specification index: <https://docs.ag-ui.com/spec/1.0/index>
- Changelog, 1.0 against 0.x: <https://docs.ag-ui.com/spec/1.0/changelog>
- Events, eight families and thirty-one types: <https://docs.ag-ui.com/spec/1.0/events>
- Transports and binding contract: <https://docs.ag-ui.com/spec/1.0/basic/transports>
- Supported integrations: <https://docs.ag-ui.com/introduction>
- Repository: <https://github.com/ag-ui-protocol/ag-ui>
- Release feed: <https://github.com/ag-ui-protocol/ag-ui/releases.atom>
- Contribution gates: <https://github.com/ag-ui-protocol/ag-ui/blob/main/CONTRIBUTING.md>
- Generative UI draft, Status Draft: <https://docs.ag-ui.com/drafts/generative-ui>
- Microsoft Agent Framework integration page, last verified 2026-09-05:
  `learn.microsoft.com/en-us/agent-framework/integrations/by-component/ui/ag-ui` — full
  URL NOT ESTABLISHED IN SOURCE
- CopilotKit funding: TechCrunch and CB Insights, 2026-05-05 — URLs NOT ESTABLISHED IN
  SOURCE

### A2UI

- Home and version table: <https://a2ui.org/>
- v0.9.1 specification: <https://a2ui.org/specification/v0.9.1-a2ui/>
- v1.0 candidate specification: <https://a2ui.org/specification/v1.0-a2ui/>
- v1.0 A2A extension specification:
  <https://a2ui.org/specification/v1.0-a2ui-extension-specification/>
- Roadmap, last updated June 2026: <https://a2ui.org/roadmap/>
- Repository: <https://github.com/a2ui-project/a2ui>
- Flutter GenUI SDK: `github.com/flutter/genui` — full URL NOT ESTABLISHED IN SOURCE
- Google Developers Blog announcement, 2025-12-15 — URL NOT ESTABLISHED IN SOURCE
- A2A under the Linux Foundation, 2026-04-09:
  <https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year>

### MCP Apps, mcp-ui and the OpenAI Apps SDK

- SEP-1865 specification text, Stable 2026-01-26:
  <https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx>
- Overview, architecture and lifecycle:
  <https://apps.extensions.modelcontextprotocol.io/api/documents/overview.html>
- Extension client matrix: <https://modelcontextprotocol.io/extensions/client-matrix>
- Extension framework and SEP process: <https://modelcontextprotocol.io/extensions/overview>
- ext-apps repository: <https://github.com/modelcontextprotocol/ext-apps>
- mcp-ui site: <https://mcpui.dev/>
- mcp-ui release feed: <https://github.com/MCP-UI-Org/mcp-ui/releases.atom>
- mcp-ui repository: <https://github.com/idosal/mcp-ui>
- OpenAI developer documentation root, serving Plugins: <https://developers.openai.com/apps-sdk>
- Add UI to your MCP server: <https://developers.openai.com/plugins/build/chatgpt-ui>
- window.openai reference: <https://developers.openai.com/plugins/reference>
- Plugin concepts: <https://developers.openai.com/plugins/concepts/plugins>
- ChatKit guide: <https://developers.openai.com/api/docs/guides/chatkit>
- Connected apps in ChatGPT help article:
  <https://help.openai.com/en/articles/11487775-connected-apps-in-chatgpt>
- OpenAI release notes feed: <https://openai.com/products/release-notes/rss.xml>
- VS Code MCP Apps support, 2026-01-26:
  <https://code.visualstudio.com/blogs/2026/01/26/mcp-apps-support>

### WebMCP

- W3C Draft Community Group Report: <https://webmachinelearning.github.io/webmcp>
- ChromeStatus feature 5117755740913664: <https://chromestatus.com/api/v0/features?q=webmcp>
- Chrome developer documentation, published 2026-05-18:
  <https://developer.chrome.com/docs/ai/webmcp>
- WPT results: <https://wpt.fyi/results/webmcp>
- W3C and GS1 "Ecommerce for Humans and AI Agents", WordLift slide:
  <https://www.w3.org/2026/09/ecommerce-agents/slides/Andrea_Volpini.pdf>

### NLWeb

- W3C Community Group page: <https://www.w3.org/community/nlweb/>
- Repository: <https://github.com/nlweb-ai/NLWeb>
- Commit history: <https://github.com/nlweb-ai/NLWeb/commits/main>
- Specification at `https://nlweb.ai/spec` — failed TLS validation on 2026-09-29

### Adjacent

- Agent Client Protocol updates: <https://agentclientprotocol.com/updates>
