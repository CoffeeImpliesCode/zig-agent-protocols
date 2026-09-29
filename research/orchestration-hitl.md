# Orchestration and human-in-the-loop across agent protocols

Evidence for two questions the wire formats do not answer. The first: where
multi-agent orchestration actually lives, given that no protocol standardises it
and A2A states in its own words that it is not one. The second: how the four
protocols that do carry a human decision — MCP, ACP, A2A and AG-UI — represent a
pause, a decision and a resume, and how far apart those representations are. A
closing section records Arazzo 1.1.0, the one declared candidate for declarative
orchestration, and what it can and cannot express today. Agent registries,
discovery and per-vendor consumer surfaces are out of scope; they have their own
documents.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

### The orchestration layer has no standard

No specification defines orchestration. Every orchestration semantic in
production use today — sequential, concurrent, handoff, group chat, supervisor,
router-worker, fan-out/fan-in — is implemented inside a framework or a SaaS
product. A2A standardises the transport between an orchestrator and a remote
agent, and nothing above it.

| Project | Version on the research date | Dated | Governance | License |
| --- | --- | --- | --- | --- |
| A2A Protocol | `1.0.0` (site callout) / `v1.0.1` (repo tag) | 2026-03-12 / 2026-05-26 | Linux Foundation; TSC: AWS, Cisco, Google, IBM Research, Microsoft, Salesforce, SAP, ServiceNow | Apache-2.0 |
| Microsoft Agent Framework | 1.0 | 2026-04-03 | Microsoft | Open source (MIT) |
| AutoGen | maintenance mode | since ~Oct 2025 | community-managed | MIT |
| AG2 | 1.1.0 (PyPI) | 2026 | volunteer group (Chi Wang, Qingyun Wu) | Apache-2.0 / MIT lineage |
| LangGraph / LangSmith | A2A endpoint at `/a2a/{assistant_id}`; `langgraph-api` >= 0.4.21; `historyScope` + A2UI in 0.15.0 (unpublished stable) | live | LangChain | MIT |
| CrewAI | docs at v1.15.23 | live | CrewAI Inc | — |
| OpenAI Agents SDK | docs `lastmod` 2026-09-28 | live | OpenAI | MIT |
| Google ADK | 2.0 GA (Python/TS/Go/Java) | 2026 | Google | Apache-2.0 |
| Arazzo Specification | 1.1.0 | 2026-05-17 | OpenAPI Initiative, under the Linux Foundation | Apache-2.0 |

A2A's normative source is `spec/a2a.proto`, organised in three layers — canonical
data model, abstract operations, protocol bindings — with JSON-RPC, gRPC and
HTTP+JSON bindings
([specification](https://a2a-protocol.org/latest/specification/)). The repository
read 26k GitHub stars on 2026-09-29
([A2A](https://github.com/a2aproject/A2A)).

The A2A specification site's "Latest Released Version" callout still reads
`1.0.0` while the repository has shipped `v1.0.1` since 2026-05-26
([releases](https://github.com/a2aproject/A2A/releases.atom)). A version-hygiene
inconsistency between the two official surfaces.

### Human-in-the-loop, four protocols side by side

| | MCP (rev. 2026-07-28) | ACP (v1 stable, v2 draft) | A2A 1.0 | AG-UI 1.0 |
| --- | --- | --- | --- | --- |
| Pause representation | `resultType: "input_required"` on any result; or Tasks extension status `input_required` | `state_update` with `state: requires_action` | `TASK_STATE_INPUT_REQUIRED`, `TASK_STATE_AUTH_REQUIRED` | `RUN_FINISHED` with `outcome.type: "interrupt"` |
| Blocking? | The initial request terminates; the client retries | `session/prompt` returns at insert; `session/request_permission` is a separate concurrent request | Blocking calls return on terminal **or** interrupted state | The run ends; a new run carries `resume[]` |
| Resume representation | Retry the same method with a new JSON-RPC id, `inputResponses` + the echoed `requestState` | A new `session/prompt`; agents **SHOULD** re-emit `running` | "a new message with the same `taskId` and `contextId`" | `RunAgentInput.resume[{interruptId, status, payload?, metadata?}]` |
| Decision vocabulary | `accept` / `decline` / `cancel` | `allow_once` / `allow_always` / `reject_once` / `reject_always`; v2 adds a tagged-union `subject` | none — an ordinary `Message` | `status: "resolved" \| "cancelled"`; denial lives in the payload |
| Response schema | `requestedSchema` (form mode, flat JSON Schema) | `title`, `description`, `subject` — no machine-checked response schema | none | `responseSchema`, validated on resume |
| Expiry / TTL | none in core; **SHOULD**-level TTL inside `requestState` | NOT ESTABLISHED IN SOURCE | none | `expiresAt`, enforced; stale resume is a `RunError` |
| Idempotency rule | none stated | none stated | none | normative: same `(threadId, interruptId, status, payload)` is safe to replay |
| Fail-closed rule | none | "MUST NOT treat it as approval" if the outcome is not understood | none | partial or invalid resume is a `RunError`, not silence |
| Async out-of-band completion signal | **removed** 2026-07-28 | `elicitation/complete` notification, stabilized 2026-07-24 | none | n/a — the run has ended |
| Approval verb | **none** | permission request is tool-call-bound | none | `reason: "tool_call"` binds a pending call |

Sources per row: MCP from the
[MRTR pattern](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)
and [elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation);
ACP from the [v1→v2 migration guide](https://agentclientprotocol.com/protocol/v2/migration.md)
and the [v2 permission RFD](https://agentclientprotocol.com/rfds/v2/permission-requests);
A2A from the [specification](https://a2a-protocol.org/latest/specification/);
AG-UI from [Interrupts](https://docs.ag-ui.com/concepts/interrupts).

### Arazzo

| Property | Value |
| --- | --- |
| Version | 1.1.0, published 17 May 2026 |
| Normative text | [spec.openapis.org/arazzo/latest.html](https://spec.openapis.org/arazzo/latest.html) |
| Editor's draft | [github.com/OAI/Arazzo-Specification](https://github.com/OAI/Arazzo-Specification) |
| Editors | Frank Kilcommins, Nick Denny, Kevin Duffey |
| Contributing body | OpenAPI Initiative |
| Copyright | © 2026 the Linux Foundation |
| License | Apache-2.0 |
| Version scheme | `major.minor.patch`; patch versions are corrections only, and tooling SHOULD NOT distinguish `1.0.0` from `1.0.1` |

## What it does

### 1. A2A disclaims orchestration in its own words

The A2A landing page carries a "What A2A Is Not" section
([a2a-protocol.org](https://a2a-protocol.org/latest/)):

> Not a sub-agent or tool-call protocol. A2A does not specify how an agent talks
> to its own sub-agents or how it invokes tools.

The same section states A2A is not an SDK and not a messaging application. What
A2A provides is a client/server transport plus a task model. The gap between
"task model" and "orchestration" is the subject of the rest of this section.
`[INFERENCE]` The recurring adoption pattern is convergence on A2A as a pluggable
*participant type* that an existing orchestrator can call, not convergence on A2A
as an orchestration model: every framework below implements its own control flow
and uses A2A only at the edges.

**What A2A does supply**, per the specification
([specification](https://a2a-protocol.org/latest/specification/)): an
`AgentCard` for discovery with three strategies — well-known URI
`/.well-known/agent-card.json`, a catalog- or registry-supplied card, and a
direct endpoint; the JSON-RPC methods `SendMessage`, `SendStreamingMessage`,
`GetTask`, `ListTasks`, `CancelTask`, `GetExtendedAgentCard`, `SubscribeToTask`;
four v0.3 aliases `message/send`, `message/stream`, `tasks/get`, `tasks/cancel`,
with everything else returning `-32601`; OAuth 2.0 device code plus PKCE (implicit
and password flows removed in 1.0), mTLS in `SecuritySchemes`, `signatures` on
the AgentCard, and a `tenant` field on gRPC requests. Extensions are
`AgentCapabilities.extensions[]` of `AgentExtension{uri, description, required,
params}`, activated by the `A2A-Extensions` request header and echoed in the
response ([extensions](https://a2a-protocol.org/latest/topics/extensions/)).

`TaskState` has six terminal values — `SUBMITTED`, `WORKING`, `COMPLETED`,
`FAILED`, `CANCELED`, `REJECTED` — and two interrupted values,
`INPUT_REQUIRED` and `AUTH_REQUIRED`.

### 2. What each orchestration implementation actually provides

#### Microsoft Agent Framework 1.0 (2026-04-03)

Agent Framework unifies Semantic Kernel and AutoGen. Five orchestrations are
stable at 1.0 — *sequential*, *concurrent*, *handoff*, *group chat*,
*Magentic-One* — each with "streaming, checkpointing, human-in-the-loop
approvals, and pause/resume" over a graph-based workflow engine with declarative
YAML topologies
([1.0 announcement](https://devblogs.microsoft.com/agent-framework/microsoft-agent-framework-version-1-0/)).

`A2AAgent` wraps any A2A endpoint as a standard `AIAgent`, and
`A2ACardResolver.GetAIAgentAsync()` resolves a card to an agent in one call
across all three discovery strategies. The same page documents `PreferredBindings`
defaulting to HTTP+JSON, SSE streaming, `ContinuationToken` polling and stream
reconnection
([A2A integration](https://learn.microsoft.com/en-us/agent-framework/integrations/by-component/agent-services/a2a),
`ms.date` 2026-09-16).

The 1.0 announcement lists "A2A 1.0 support" as **coming soon**. Agent Framework
1.0 also ships AG-UI, CopilotKit and ChatKit adapters in preview, and can use the
GitHub Copilot SDK and the Claude Code SDK as agent harnesses inside its
orchestrations.

#### AG2 1.1.0 and the Network

AG2 is the AutoGen fork and has split: `ag2` (the protocol-driven framework,
`Agent` + `Network`) and `ag2-classic` (the `autogen` namespace,
`ConversableAgent`, `GroupChat`, swarms). The PyPI page states that `ag2>=1.0` is
**not** a drop-in upgrade — "The agent model, orchestration, and imports all
changed" — and that its purpose is to "orchestrate multiple agents over a hub and
typed channels using the Network"
([PyPI](https://pypi.org/project/ag2/)). Latest version read 1.1.0, 36K weekly
downloads, with `context.input()` and a `hitl_hook` for human input, volunteer
maintained.

The `Network` is a distinct orchestration model
([Network overview](https://docs.ag2.ai/docs/user-guide/network/overview/)):
hub-and-spoke, with one authoritative `Hub` holding a `Passport` (identity), a
`Resume` (capability claims and observed track record), a `Rule` (per-agent
access, rate, inbox and limits), and an `Envelope` — the hub-stamped wire record
`{event_type, event_data, sender_id, audience, causation_id}`. Channels keep
write-ahead logs. `HubListener` observes post hoc; `HubArbiter` gates before a
decision. Four channel adapters govern the `ACTIVE → CLOSED` transition:

| Adapter | Participants | Shape |
| --- | --- | --- |
| `conversation` | 2 | free-form |
| `consulting` | 2 | strict one-question-one-response |
| `discussion` | 2+ | round-robin |
| `workflow` | 2+ | declarative `TransitionGraph` with `TerminateTarget` / `max_turns` |

`LocalLink` runs in-process and swaps to `WsLink` for cross-process. The whole
model is framework-local, with no A2A or MCP wire compatibility. `HumanClient` is
a first-class non-LLM participant in the network.

#### LangGraph and the LangSmith Agent Server

The A2A support lives in the deployment platform, not the library. The LangSmith
Agent Server exposes `/a2a/{assistant_id}` with the Agent Card at
`GET /.well-known/agent-card.json?assistant_id=…`, speaks A2A **v1.0 JSON-RPC**,
and additionally accepts the four v0.3 method names
([server A2A docs](https://docs.langchain.com/langsmith/server-a2a)).

What it does not do, per the same page: the gRPC and HTTP+JSON bindings are
unimplemented; `SubscribeToTask` and every `*TaskPushNotificationConfig` method
return `-32601`; `historyLength` above 10 returns `-32602`; a terminal `taskId`
returns `-32004`. A2UI v0.9 is opt-in via `metadata.a2a.a2ui: true`, and
`contextId` maps to `thread_id` for tracing. The non-standard `historyScope`
extension takes `task` or `context`, default `context`, settable through
`configuration`, through `params`, or through the header
`LangGraph-A2A-History-Scope: task`, and is advertised in
`capabilities.extensions`.

Meanwhile the `langgraph` core library has an open feature request,
[issue 7398](https://github.com/langchain-ai/langgraph/issues/7398), opened
2026-04-03, labelled `external`, with no assignee. Its own text: "there is no
built-in way to attach A2A metadata to a LangGraph graph or serve it as an
A2A-compliant endpoint." It proposes `langgraph.a2a.AgentCard`,
`Pregel.with_agent_card()` and `serve_a2a()`. The CLI already carries a
`disable_a2a` deployment flag. The `external` label is LangChain's stated
position that A2A is a deployment concern. `[INFERENCE]`

#### CrewAI

A2A is a first-class delegation primitive on both sides:
`Agent(a2a=A2AClientConfig(endpoint=…))` to delegate, `A2AServerConfig` to serve
([v1.15.23 docs](https://docs.crewai.com/v1.15.23/en/learn/a2a-agent-delegation)).
`A2AClientConfig` exposes `endpoint` (typically a `.well-known/agent-card.json`
path), `auth` across four schemes (Bearer, OAuth2 client credentials, API key
via header/query/cookie, HTTP basic), `timeout=120`, `max_turns=10`,
`response_model`, `fail_fast=True`, `trust_remote_completion_status=False`,
`updates` (`StreamingConfig` / `PollingConfig` / `PushNotificationConfig`),
`accepted_output_modes`, `extensions`, `client_extensions`, and `transport`
(preferred and supported bindings plus gRPC sizes and keepalive). A **list** of
configs is accepted and the LLM picks the delegate. `fail_fast=False` degrades
gracefully: connection errors are injected into context so the LLM can route
elsewhere. `A2AConfig` is deprecated for removal in v2.0.0.

#### OpenAI Agents SDK — A2A absence verified

Two framework-local primitives. *Handoffs* are presented to the model as a tool
named `transfer_to_<agent_name>`, after which the specialist is the active agent
for the rest of the turn, configured through
`handoff(agent, tool_name_override, tool_description_override, on_handoff,
input_type, input_filter, is_enabled, nest_handoff_history)`. *Agents as tools*
(`Agent.as_tool()`) leaves the manager holding the conversation. Code-level
orchestration is also documented: structured-output dispatch, chaining,
`asyncio.gather` fan-out, and a while-loop evaluator
([handoffs](https://openai.github.io/openai-agents-python/handoffs/),
[multi-agent](https://openai.github.io/openai-agents-python/multi_agent/)).

**There is no A2A surface.** This is a verified absence, not an unexamined gap:
the documentation sitemap contains `mcp/`, `multi_agent/` and
`ref/mcp/{manager,server,util}` and zero `a2a` or `agent-to-agent` pages
([sitemap.xml](https://openai.github.io/openai-agents-python/sitemap.xml), read
2026-09-28).

The guardrail scope is stated and lossy: "Handoffs stay within a single run. Input
guardrails still apply only to the first agent in the chain, and output guardrails
only to the agent that produces the final output."

#### Google ADK

The A2A section is badged "Supported in ADK: Python, Go, Java (Experimental)"
with symmetric quickstarts per language — *Consuming* (use a remote A2A agent) and
*Exposing* (be reachable over A2A) — and a dedicated "A2A Extension — V2
Implementation" for Python. ADK 2.0 GA adds graph workflows and "collaborative
agents"
([adk.dev/a2a](https://adk.dev/a2a/)).

#### Copilot Studio

The A2A-native product orchestrator. Generative orchestration has two topologies:
*inline agents* (child topics sharing the parent's context) and *connected
agents* (separate orchestrators). The documented pattern is a routing rule, not a
protocol feature: "Treat the entire connected agent as an agentic tool with a
description, from the perspective of the parent"
([multi-agent patterns](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/multi-agent-patterns),
`ms.date` 2026-05-21). Four topologies are named: Router-Worker, Sequential
Pipelines, Parallel Fan-out/Fan-in, and Hierarchical
Supervisor/Sub-orchestrator.

`Add agent → A2A agent` takes an **endpoint URL**, not a card URL, plus auth
(None, API key, or OAuth 2.0); name and description auto-populate when the agent
publishes a card at the standard `.well-known` URL
([A2A agent connection](https://learn.microsoft.com/en-us/microsoft-copilot-studio/add-agent-agent-to-agent),
`ms.date` 2026-08-26). It runs on custom-connector infrastructure, so on-prem and
VNET agents are reachable.

### 3. Human-in-the-loop

#### 3.1 MCP under the 2026-07-28 MRTR pattern

The premise needs one correction before the comparison holds. The
`elicitation/create` **JSON-RPC request** is gone. The changelog states that MRTR
"replaces the previous approach of sending server-initiated requests… The
previous pattern of server-initiated requests is no longer supported. This is a
breaking change"
([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)).
The `ElicitRequest` **type** and the method *string* survive as a value inside a
map, with no server-initiated request carrying it:

```json
{
  "resultType": "input_required",
  "inputRequests": {
    "github_login": {
      "method": "elicitation/create",
      "params": {
        "mode": "form",
        "message": "Please provide your GitHub username",
        "requestedSchema": {}
      }
    }
  },
  "requestState": "opaque, integrity-protected blob"
}
```

**Mechanism.** The client sends `tools/call`, or `resources/read`, or
`prompts/get` — the only three methods that may return `InputRequiredResult`. The
server returns `InputRequiredResult` and the initial request **terminates**. The
client gathers input, retries the *same* method under a **new JSON-RPC id**
carrying `inputResponses` keyed by the server-assigned string ids plus the exact
`requestState` echoed back, and the server reconstitutes state and returns a
`complete` result. Every result carries a required `resultType`, `"complete"` or
`"input_required"`, and clients MUST treat a missing field from an older server as
`"complete"`
([MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)).

Because the 2026-07-28 revision removed all protocol-level sessions and the
`Mcp-Session-Id` header, a user decision in MCP is stateless, sessionless, and
survives arbitrary load balancing: no shared storage, no sticky routing, with
context carried in the server's own `requestState`.

**The decision model** is three actions in both modes
([elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation)):
`accept` — approved and submitted, with `content` populated in form mode and
omitted in URL mode; `decline` — explicitly declined; `cancel` — dismissed
without choosing. The server-side handling is prescribed: accept → process,
decline → offer alternatives, cancel → prompt again later.

**Mode split.** `form` is in-band structured data under a restricted flat JSON
Schema (string, number, boolean, enum; formats `email`, `uri`, `date`,
`date-time`). `url` is out-of-band navigation, and data other than the URL never
reaches the client. Capability is per-request, in
`_meta.io.modelcontextprotocol/clientCapabilities.elicitation` as
`{form:{}, url:{}}`, where `{}` means form-only. Servers MUST NOT request
credentials in form mode: "Servers **MUST** use URL mode for interactions
involving such sensitive information."

**MCP has no approval verb.** This is the load-bearing finding for the
comparison. There is no `approve` or `deny` method and no tool-execution gate
anywhere in the protocol. Approval is a form-mode elicitation with a boolean in
`requestedSchema`, and enforcement is client policy: clients "SHOULD implement
user approval controls" and "SHOULD allow users to decline elicitation requests at
any time." The specification's hard MUSTs concern secrets, phishing and UI
attribution — not whether a destructive tool call may execute. A client can
satisfy the specification and never ask.

**What was removed in the same revision.** Changelog minor item 11 removed
`notifications/elicitation/complete` and the `elicitationId` field of URL-mode
requests, both of which had been introduced only in 2025-11-25. The stated
reason: "the client learns the outcome of an out-of-band interaction by retrying
the original request, so a server-initiated completion signal — and the
identifier used to correlate it — no longer fit the protocol." For URL mode —
OAuth consent, payment confirmation, credential entry — the client must now offer
manual controls: "Clients **SHOULD** provide manual controls that let the user
retry or cancel the original request." Correlating an elicitation across retries
is the server's problem, encoded in its own `requestState` id.

**Async approvals: the Tasks extension** (`io.modelcontextprotocol/tasks`,
SEP-2663) moved out of the core protocol in the same revision. It replaces the
blocking `tasks/result` with polling `tasks/get` plus `tasks/update` for
client-to-server input, removes `tasks/list`, and lets servers return handles
unsolicited. States are `working`, `input_required`, `completed`, `failed`,
`cancelled`; methods `tasks/get`, `tasks/update`, `tasks/cancel`; notification
`notifications/tasks`. It is opted into per request via
`{"clientCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}` and
is documented for "human approvals… CI pipelines". `inputRequests` is the
**blocking set by definition**; partial `inputResponses` leave the task
`input_required` until the rest arrive
([Tasks extension](https://modelcontextprotocol.io/extensions/tasks/overview)).

**Security posture**, the deepest of the four protocols and largely a consequence
of `requestState` being attacker-controlled:

- Servers **MUST** treat `requestState` as attacker-controlled input and
  integrity-protect it (HMAC or AEAD) if it influences authorization, resource
  access, or business logic.
- Servers **SHOULD** embed an authenticated principal, a short TTL, and a
  digest of the originating request to bound replay; single-use invariants
  **MUST** be enforced server-side.
- A **phishing attack on URL mode** is documented: Alice's client displays a URL,
  victim Bob clicks it, and the tokens bind to Alice's session. The mitigation is
  a "connect URL" on the MCP server's own domain that verifies the session
  cookie's `sub` matches the elicitation's `sub` before redirecting to the
  third-party authorization server.
- Clients **MUST NOT** pre-fetch the URL, **MUST** show the full URL before
  consent, **MUST** highlight the domain, **SHOULD** warn on punycode, and
  **MUST** open it so the client and LLM cannot inspect the content — on iOS
  `SFSafariViewController` qualifies and `WKWebView` does not.
- Servers **MUST** bind the elicitation to client and user identity, and
  **MUST NOT** rely on client-provided user identification.

**Deprecated alongside.** SEP-2577 deprecated Roots, Sampling and Logging on
2026-07-28, with earliest removal at the "first revision released on or after
2027-07-28". The `InputRequests` value type remains
`ElicitRequest | CreateMessageRequest | ListRootsRequest`, so `roots/list` and
`sampling/createMessage` are typed but deprecated — pass directories as tool
parameters, call LLM provider APIs directly — while `logging/setLevel` is gone in
favour of per-request
`_meta.io.modelcontextprotocol/logLevel`. Also deprecated: Dynamic Client
Registration (RFC 7591) in favour of Client ID Metadata Documents, the
`includeContext: "thisServer"` / `"allServers"` values, and the HTTP+SSE
transport
([deprecated registry](https://modelcontextprotocol.io/specification/2026-07-28/deprecated)).
Elicitation itself is **not** on the deprecated list.

**The unresolved audience question.** The `input_required` state is
self-contradictory in the specification's own text: the states table describes it
as "input from the client" while the worked example describes it as "an
elicitation to the user", and the value union mixes host-answered members
(sampling, roots) with user-answered members (elicitation) with nothing on the
wire distinguishing them. This is raised as an open working-group question in
[agents-wg issue 27, "Steering"](https://github.com/modelcontextprotocol/agents-wg/issues/27),
opened 2026-09-11 and still open on the research date. That issue names the
orchestration gap directly — "**An orchestrator narrowing a subagent.** The host
is itself an agent whose inputs changed after it delegated. The ordinary case in
agent-to-agent deployments" — and then enumerates why neither protocol can express
it: no carrier for client-initiated steering (no message, instruction or guidance
field on `tasks/update`), no representation of non-blocking requests, no
acknowledgement of the right shape (the `tasks/update` ack is empty and
eventually consistent — the server MAY ack before its status reflects the
responses), and no ordering (`notifications/tasks` carries no sequence number, and
the Tasks specification contains no ordering language at all). It also records
that the value union is "collapsing onto the member whose text presumes a human,
at the point where agent-to-agent chains need the opposite", and cross-references
A2A #2125, #1992, #2129, #2149 and #1582.

#### 3.2 ACP

**v1 permissions** are tool-call-bound and, on the option model, richer than
anything else in the set. `session/request_permission` returns options carrying
`optionId`, `name`, and `kind` drawn from `allow_once`, `allow_always`,
`reject_once`, `reject_always`.

**v2 redesign** (draft 2026-07-20; the RFD's revision history runs initial draft
2026-07-02, command subject added 2026-07-14) requires `title`, makes
`description` optional, and adds an optional `subject` tagged union. The `subject`
is a direct fix for a v1 anti-pattern the RFD names: "it also tempts agents to
put permission prompt text into `ToolCallUpdate.title` or
`ToolCallUpdate.content`… Using them for permission-only UI copy can accidentally
change the tool call shown elsewhere." The variants are `type: "tool_call"`, which
carries genuine `ToolCall` state; `type: "command"`, which is self-contained and
requires `command` plus an **absolute** `cwd`, with optional `toolCallId`,
`terminalId` and `_meta`, and which states that "Approval authorizes the Agent to
execute the command; it never asks the Client to execute it"; and an omitted
subject for approval without structured context
([v2 permission RFD](https://agentclientprotocol.com/rfds/v2/permission-requests)).

**The fail-closed rule**, verbatim from the v2 migration guide: "an Agent that
receives an outcome it does not understand **MUST NOT** treat it as approval"
([migration guide](https://agentclientprotocol.com/protocol/v2/migration.md)). It
is the only protocol-level unknown-outcome clause among the four.

**The v2 prompt lifecycle** is the substantive HITL change, and it runs opposite
to MCP's direction. `session/prompt` no longer owns the turn; it returns
`{messageId}` as soon as the user message is *inserted*. All foreground progress
and completion move to `session/update` → `state_update` with
`state: running | idle | requires_action` and a `stopReason`. `requires_action`
is the explicit blocked-on-the-user signal, and agents **SHOULD** emit it while
awaiting a permission response, then `running` again once resolved.
`session/request_permission` stays a blocking JSON-RPC request *concurrent with*
the already-completed prompt request, so an approval can be pending while the
client has been told the turn was accepted. Clients respond to all pending
permission requests with `cancelled` when cancelling. v2 removes
`fs/read_text_file`, `fs/write_text_file`, all `terminal/*`, `session/set_mode`
and `session/load`, directing agents to "use client-provided MCP servers when the
Agent needs Client-side tools".

**Elicitation was stabilized on 2026-07-24** — the `elicitation/create` method
plus the optional `elicitation/complete` notification, form and URL modes,
per-mode client advertisement at init, and explicit session, tool-call and
request scopes
([announcement](https://agentclientprotocol.com/announcements/elicitation-stabilized)).
The updates index dates the same item 2026-07-22, a two-day discrepancy between
the index and the announcement page
([updates](https://agentclientprotocol.com/updates)). Request Cancellation
(`$/cancel_request`) stabilized 2026-06-29; Tool Call Names stabilized
2026-09-17.

**v2 adoption posture.** The v2 draft announcement, from Ben Brandt on 2026-07-20,
is explicit: "gate your implementation behind the version negotiation AND feature
flags. Don't ship it by default in production until we are closer to
stabilization." Version negotiation is per-connection only — "a single connection
always speaks exactly one negotiated version after `initialize`" — and the
migration guide requires supporting both, because "an Agent that drops v1 cuts
itself off from existing Clients"
([v2 draft](https://agentclientprotocol.com/announcements/acp-v2-draft)).

#### 3.3 A2A

**What exists in 1.0** is two interrupted states:
`TASK_STATE_INPUT_REQUIRED` ("the agent requires additional user input to
proceed") and `TASK_STATE_AUTH_REQUIRED`. Blocking calls return on a terminal
state **or** an interrupted one, and `return_immediately: true` can return an
`input_required` task. Resume is: "The client continues the interaction by sending
a new message with the same `taskId` and `contextId`." Follow-up messages preserve
`contextId`; sending to a terminal task is `UnsupportedOperationError`
([specification](https://a2a-protocol.org/latest/specification/)).

That is the whole 1.0 HITL surface. There is no `ElicitResult`, no
`accept`/`decline`/`cancel` enumeration, no response schema, no `requestState`,
no integrity requirement on the resume payload, and no approve/deny semantics. A
human decision is an ordinary `Message` — a normal agent turn. There is no way to
distinguish "the user approved" from "the user typed a correction", and nothing
binds the message to a specific pending ask.

`AUTH_REQUIRED` carries a specific rule: the agent **MUST** transition to it,
**MUST** include a `TaskStatus` message explaining the required authorization,
and **MUST** arrange to receive credentials out of band. It **SHOULD** keep active
response streams open and **SHOULD** accept messages while in that state "to
negotiate, correct, or reject an authorization request". Nothing prevents the
client from resuming without sending credentials, and the agent may then continue
processing on its own — so the state machine cannot be relied on to enforce
anything.

**The v1.1 elicitation proposal is unmerged.**
[PR 2149](https://github.com/a2aproject/A2A/pull/2149), "feat: add elicitations
for additive input-required (ADR-002)", opened 2026-08-18 against `dev-1.1`. The
design introduces `Elicitation{elicitationId, state, metadata}` with
`ElicitationState` of `WAITING | BLOCKED | RESOLVED`; `Task.elicitations` as the
authoritative set plus `TaskStatus.elicitations` as a **delta** delivered on the
existing `TaskStatusUpdateEvent` — "No new streaming event type" — and
`SendMessageRequest.elicitationId` as an optional client **hint**, with servers
required not to reject a message solely because the field is absent, unknown, or
already `RESOLVED`. The stated rationale is A2A's distinguishing claim: a single
agent message may raise **several** elicitations, which neither a blocking
single-prompt model nor MCP's blocking input set can express.

Status is contested, not merely pending. darrelmiller (Microsoft, Partner API
Architect) commented on 2026-09-01: "We need to make a call as to whether we need
this in the v1.1 spec." The date on which the TSC decides is **NOT ESTABLISHED IN
SOURCE**.

**The constraint that shaped the design** is documented in the merged sibling
[PR 2129](https://github.com/a2aproject/A2A/pull/2129) (timeline / ADR-002):
A2A cannot safely add new stream event types. a2a-go, a2a-java and a2a-rs
"hard-error on an unrecognised event (java's `StreamingEventKind` is a `sealed`
interface)", a2a-python "raises on strict `ParseDict`", and a2a-js and the Python
gRPC client "silently drop it". That is why `elicitations` rides the existing
`TaskStatusUpdateEvent` rather than defining a new one. The same PR
soft-deprecates `Task.history` and the three `history_length` parameters in favour
of a repeated `TimelineEntry timeline` and `timeline_length`, retained through
v1.x and removed in 2.0. `TimelineEntry` is a `oneof { Message message;
TaskStatus status }` plus an `int64 generation`; fail-open is normative, clients
MUST skip unrecognized `oneof` kinds even though `generation` still counts.

The roadmap, last updated 2026-09-15, lists "Elicitation & Multi-Turn Workflows
(#2149, #2143) — **Explore** structured human-in-the-loop interaction models and
multi-round negotiation patterns informed by telecom industry use cases". The
operative verb is Explore
([roadmap](https://a2a-protocol.org/latest/roadmap/)).

**The A2A/MCP conversation is live.** The MCP agents-wg "Steering" issue cites
A2A directly: "A2A hit the same case and is worth looking into", and records that
"A2A considered the same question and deliberately kept its equivalent state
audience-agnostic, on the grounds that this is what lets one construct serve both
user-to-agent and agent-to-agent". A2A #2125 is steering as an opt-in extension;
A2A #1582, closed, had "four candidate behaviours for a message arriving at a
working task, none made normative"; #1992 is the multi-turn epic.

#### 3.4 AG-UI interrupts

AG-UI's model is a **terminal outcome, not a pause**. The run ends carrying an
interrupt:

```json
{
  "type": "RUN_FINISHED",
  "threadId": "thread-1",
  "runId": "run-1",
  "outcome": {
    "type": "interrupt",
    "interrupts": [
      {
        "id": "int-abc123",
        "reason": "tool_call",
        "message": "Send email to a@b.com with subject 'Hi'?",
        "toolCallId": "tc-001",
        "responseSchema": {
          "type": "object",
          "properties": { "approved": { "type": "boolean" } },
          "required": ["approved"]
        }
      }
    ]
  }
}
```

The client starts a **new run** on the same thread carrying
`resume: [{interruptId, status: "resolved" | "cancelled", payload?, metadata?}]`.
`outcome` is optional and its absence means legacy success, so pre-1.0 producers
remain valid. `RunError` is the sole error event; the outcome enumeration has no
"error" variant
([Interrupts](https://docs.ag-ui.com/concepts/interrupts)).

**The eight normative contract rules** are the most complete HITL specification
in the ecosystem:

1. The resumed run uses the same `threadId` as the interrupted run.
2. `resume[].interruptId` must reference an `id` from that run's `interrupts[]`;
   `parentRunId` is orthogonal.
3. **Cover all open interrupts** — one `resume` array must address every open
   interrupt. Partial resumes are unsupported.
4. **Pending interrupts block new input** — any `RunAgentInput` on that thread
   must include a `resume`; a non-conforming input produces a `RunError`.
5. Idempotent: the same `(threadId, interruptId, status, payload)` is safe to
   replay.
6. The payload is validated against `responseSchema`; a mismatch produces a
   `RunError`.
7. `expiresAt` is enforced; a stale resume produces a `RunError`.
8. Graceful: missing or invalid payloads produce a `RunError`, not silence.

**The reason taxonomy** has three spec-defined core values with mandated routing
hints: `tool_call` (`toolCallId` MUST be set), `input_required` (`responseSchema`
SHOULD be set), and `confirmation` (free-standing yes/no). Custom reasons are
valid and SHOULD be namespaced `<framework>:<name>` — `langgraph:database_modification`,
`mastra:workflow_suspend` are the documented examples, and `core:` is reserved.
"For unknown reasons, clients must not error. Render from `message`,
`responseSchema`, and `metadata`."

**Approve-with-edits, with the schema as capability signal.** The recommended
`responseSchema` for a tool-bound interrupt adds an `editedArgs` object property
described as "Full replacement of the tool args. Not merged." Its presence in the
schema **is** the signal that the client may offer edit UI — the payload shape
doubles as feature detection. No other protocol in this set lets a client learn
from the payload that editing is supported.

**Denials are data, not status.** "Denials are expressed inside the payload (for
example, `{ approved: false }`), not as a separate status." `cancelled` means the
user abandoned without providing meaningful input and `payload` should be
omitted. A `resolved` + `approved:false` resume and a `cancelled` resume are
therefore distinguishable, but there is no protocol-level "denied" audit term.

**The audit trail spans two runs.** For `reason: "tool_call"`, the chain is
`ToolCallArgs` from the interrupted run (the proposal) → `RunAgentInput.resume`
payload from the resumed run (the decision plus any edits) → `ToolCallResult` from
the resumed run (the outcome). "The agent does **not** re-emit
`ToolCallStart`/`ToolCallArgs`/`ToolCallEnd` in the resumed run — it emits
`ToolCallResult` against the original `toolCallId`." Proposal, decision and
execution are three distinct events.

**Resume-mode agnosticism is enforced at the boundary.** "At the moment of
interrupt, the agent must emit any state required for resume via `StateSnapshot`
and `MessagesSnapshot` events **before** the `RunFinished` event that carries the
interrupt." Replay-style and checkpoint-style continuations are therefore
observably identical on the wire, and framework-native checkpointing is an
implementation optimization rather than a protocol concern.

**Subagents.** `Interrupt.subagentRunId` attributes each interrupt; a producer
emitting subagent lifecycle events closes the subagent with
`outcome: { type: "suspended" }`, and "attribution here is valid on its own" since
lifecycle events are optional. `RunStarted.parentRunId` gives git-like branching
over threads.

#### 3.5 How the four compare

`[INFERENCE]` Three of the four put human-in-the-loop on a **state machine** the
client must hold — AG-UI `outcome`, A2A `TaskState`, ACP `state_update` — rather
than on a callback. MCP is the outlier in going stateless, which is why it is the
only one of the four whose decision survives arbitrary load balancing, and also
the only one that deleted its async completion signal, which pushes URL mode
onto manual client retry and cancel controls.

Each of the four is the only one of the set to have some property:

| Property | Sole holder |
| --- | --- |
| Protocol-level fail-closed unknown-outcome rule | ACP |
| Documented active account-takeover attack and mitigation | MCP |
| Idempotent, expiry-enforced resume by contract | AG-UI |
| Four-kind permission option model | ACP |
| Multi-elicitation, non-blocking pending-request set | none — A2A's design is unmerged |
| Capability signal readable from the response payload | AG-UI |

### 4. Arazzo 1.1.0

Arazzo describes **sequences of API calls and their dependencies** for achieving a
defined outcome, layered over API descriptions. It is the workflow-composition
sibling to OpenAPI, not a transport protocol
([specification](https://spec.openapis.org/arazzo/latest.html)).

**The Arazzo Specification Object** fixed fields are `arazzo` (the required
version string), `$self` (a root-level URI-reference for identity-based
resolution, new in 1.1, which MUST NOT contain a fragment), `info` (required),
`sourceDescriptions` (required, at least one), `workflows` (required, at least
one), and `components` (optional). Step Objects carry `stepId`, `operationId` or
`operationPath`, `parameters`, `requestBody`, `successCriteria`, `outputs`,
`onSuccess`/`onFailure`, and — in 1.1 — `dependsOn`, `action`, `correlationId` and
`timeout`. Action Objects (`type: retry` and others) carry `criteria`,
`retryLimit` and `retryAfter`, and in 1.1 also `workflowId` and `parameters` for
**chained workflow calls**. The canonical example in the 1.1 announcement is a
`refreshTokenFlow` retried on `$statusCode == 401` with a regex criterion over
`$response.header.WWW-Authenticate`.

Data types are JSON Schema Draft 2020-12 with OpenAPI-style `format` refinements
`int32`, `int64`, `float`, `double`, `password`. Runtime expressions are
`$inputs.*`, `$steps.<stepId>.outputs.*`, `$workflows.*`,
`$sourceDescriptions.*`, `$url`, `$response.*`, `$message.payload.*` (1.1),
`$statusCode` and `$self`.

**The 1.1 headline feature is AsyncAPI.** `sourceDescriptions[].type` gains
`asyncapi` alongside `openapi` and `arazzo`. Async steps reference `operationId`
or `channelPath` and declare `action: send | receive`, with a `correlationId`
that must align with the referenced AsyncAPI document and a `timeout` in
milliseconds bounding the step. The worked example in the
[1.1 announcement](https://www.openapis.org/blog/2026/05/19/announcing-arazzo-specification-1-1)
is a payment flow with a `WaitForUserAck` step — a receive whose
`successCriteria` is `$message.payload.status == "ok"` — which is Arazzo's own
primitive form of human-in-the-loop, and the closest thing in the specification to
an actor gate.

Other 1.1 additions: the **Selector Object** for fine-grained extraction
(`context` plus `selector` plus `type` ∈ `jsonpath` | `xpath` | `jsonpointer`),
available in workflow outputs, step outputs, request bodies, parameter values and
payload replacements; the **Expression Type Object**, renamed from Criterion
Expression Type Object, which pins a version (`jsonpath` → `rfc9535` by default
or `draft-goessner-dispatch-jsonpath-00`; `xpath` → `xpath-31` by default,
`xpath-30`, `xpath-20`, `xpath-10`; `jsonpointer` → `rfc6901`); `querystring` as
a Parameter `in` value, aligning with OpenAPI 3.2; and `dependsOn` for explicit
step ordering, which "establishes prerequisite relationships; it does not trigger
execution". 1.1 also adds a complete ABNF grammar for runtime expressions, a
formal source-description resolution ordering, and explicit truthy/falsy
semantics for success criteria.

**The parsing requirements are normative and strict.** Every document in an
Arazzo Description MUST be fully parsed to find reference targets before
resolving references. Fragmentary parsing is "strongly discouraged" and produces
undefined, implementation-defined behavior. When a Source Description `url` is
absolute, implementations **MUST** resolve by **identity** (matching `$self`),
not by location. Base URI resolution follows RFC 3986 §5.1.1–5.1.4 with `$self`
taking precedence. Referencing by any other identifier "is not interoperable and
relying on it is **NOT RECOMMENDED**". JSON Pointer (RFC 6901) is the SHOULD
interpretation for fragments, and `$ref` in workflow `inputs` and
`components.inputs` MUST support both JSON Pointer and plain-name `$anchor`
fragments.

#### What Arazzo 1.1.0 cannot express

OAI's published post-1.1 roadmap lists, verbatim:

- **gRPC, GraphQL, SOAP, MCP, and A2A step support**
- **Actor-in-loop (human or agent) support**
- Transformer and function support
- Loops

Stated as the three capabilities absent today:

1. **It cannot call an MCP tool or an A2A agent.** `sourceDescriptions[].type` is
   limited to `openapi`, `arazzo` and `asyncapi`. A step's target is an
   `operationId` or `operationPath` in a source description, so there is no wire
   form for an MCP `tools/call` or an A2A `SendMessage`.
2. **It has no first-class approval or actor gate.** There is no analogue of
   AG-UI's interrupt and resume contract, ACP's option kinds, or MCP's
   accept/decline/cancel. The `WaitForUserAck` pattern is a receive with a
   timeout, so `$message.payload` on an AsyncAPI receive is a polling deadline,
   not a human acknowledgement, and a normative resume representation for a paused
   workflow is **NOT ESTABLISHED IN SOURCE** — no such construct is described.
3. **It cannot express an agent's non-determinism.** Arazzo is built for sequences
   specified in advance. A model choosing which agent to call next is not
   expressible; the closest construct is a fixed `workflowId` chain, which is
   exactly the deterministic orchestration the agent layer lacks. `[INFERENCE]`

## What changed recently

| Date | Event |
| --- | --- |
| 2025-07-30 | A2A 0.3.0: Agent Card well-known URI renamed `agent.json` → `agent-card.json`; `signatures` added; mTLS in `SecuritySchemes`; `GetExtendedAgentCard` |
| 2025-10 | Microsoft introduces Agent Framework (AutoGen + Semantic Kernel) and puts AutoGen in maintenance mode; the AutoGen README banner reads "AutoGen is now in maintenance mode. It will not receive new features or enhancements and is community managed going forward" |
| 2026-01-29 | A2A `v1.0.0-rc` |
| 2026-02 | Agent Framework reaches Release Candidate; feature surface locked |
| 2026-03-09 | ACP Registry RFD moved to Completed |
| 2026-03-12 | **A2A 1.0.0.** Separates application-protocol definition from transport mapping. Adds `tasks/list` with filtering and cursor pagination, native multi-tenancy, OAuth modernization (drops implicit and password, adds device code plus PKCE), flattened `FilePart`/`DataPart` into `Part`, removal of redundant `final` from `TaskStatusUpdateEvent`, `extendedAgentCard` moved into `AgentCapabilities`, `supportsAuthenticatedExtendedCard` → `supportsExtendedAgentCard`, and `v1s` renamed out of URL bindings |
| 2026-04-03 | **Microsoft Agent Framework 1.0** for .NET and Python. The announcement lists A2A 1.0 support as "coming soon" |
| 2026-04-03 | LangGraph issue #7398 opens, requesting declarative A2A agent cards in the core library |
| 2026-04-09 | Linux Foundation one-year A2A release: **>150 organizations**, up from >50 in April 2025; 22k+ GitHub stars; five production SDKs (Python, JS, Java, Go, .NET); Azure AI Foundry and Copilot Studio from May 2025, AWS Bedrock AgentCore Runtime from Nov 2025; ecosystem extended to payments via AP2 with 60+ organizations |
| 2026-05-17 | **Arazzo 1.1.0 published**, with AsyncAPI source descriptions, chained workflow execution, the Selector Object and the Expression Type Object |
| 2026-05-19 | Arazzo 1.1 announcement, which also publishes the post-1.1 roadmap |
| 2026-05-26 | A2A `v1.0.1` |
| 2026-06-25 | ACP Rust and TypeScript SDKs reach 1.0.0 |
| 2026-06-29 | ACP Request Cancellation (`$/cancel_request`) stabilized |
| 2026-07-20 | ACP v2 published in Draft, announcing the prompt lifecycle redesign, upsert updates, a diff overhaul, extensible permissions and `_-prefixed` unknown enums |
| 2026-07-22 / 2026-07-24 | ACP Elicitation stabilized — the updates index says 2026-07-22, the announcement page says 2026-07-24 |
| 2026-07-28 | **MCP revision `2026-07-28`**: MRTR (SEP-2322) replaces all bidirectional server-to-client requests; required `resultType` on every result; protocol-level sessions and the initialize handshake removed; `server/discover` added; `subscriptions/listen` added; Tasks moved to an extension; `notifications/elicitation/complete` and the URL-mode `elicitationId` removed (changelog minor item 11); SEP-2577 deprecates Roots, Sampling and Logging |
| 2026-08-18 | A2A PR #2149 opens, proposing `Elicitation` with `WAITING`/`BLOCKED`/`RESOLVED` for additive input-required. Still unmerged on the research date |
| 2026-09-01 | darrelmiller (Microsoft) states the A2A TSC has not decided whether #2149 ships in v1.1 |
| 2026-09-11 | MCP `agents-wg` issue #27 "Steering" opens, naming the orchestration-HITL gap and the `input_required` audience ambiguity |
| 2026-09-15 | A2A roadmap last updated: v1.1 (#1991), bidirectional streaming (#1995), A2A CLI (#1929), "Elicitation & Multi-Turn Workflows (#2149, #2143)" |
| 2026-09-16 | Agent Framework A2A agent-service documentation updated (`ms.date`) |
| 2026-09-17 | AG-UI protocol 1.0.0: `@ag-ui/proto`, `@ag-ui/core`, `@ag-ui/client` and `@ag-ui/encoder` all at `1.0.0`, with `PROTOCOL_VERSION` `'1.0'` as the wire version. ACP Tool Call Names stabilized the same day |
| 2026-09-29 | `@ag-ui/*@1.0.1` published, fixing `connectAgent()` on reconnect to a thread with pending interrupts |

## Evidence of adoption

**A2A is the only orchestration-adjacent protocol with foundation-scale
adoption.** The Linux Foundation release of 2026-04-09 is primary and
foundation-authoritative: more than 150 organizations, up from more than 50 in
April 2025, including AWS, Cisco, Google, IBM, Microsoft, Salesforce, SAP and
ServiceNow, with verticals in supply chain, financial services, insurance and IT
operations, and quotations from Luca Muscariello (Cisco), Rao Surapaneni (Google
Cloud), Todd Segal (Google) and Darrel Miller (Microsoft)
([press release](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year)).
Microsoft is simultaneously a TSC member and a quoted supporter — a materially
different posture from the AutoGen-to-Agent-Framework consolidation.

| Implementer | Evidence | Date |
| --- | --- | --- |
| Microsoft | A2A in Azure AI Foundry and Copilot Studio; `A2AAgent` in Agent Framework; three A2A connection families in Copilot Studio | 2026-05, 2026-04-03, 2026-08-26 |
| AWS | Bedrock AgentCore Runtime marketplace A2A server support | Nov 2025 |
| Google | ADK A2A in Python, Go and Java, bidirectional; ADK originated A2A | 2026 |
| LangChain | A2A endpoint in the production Agent Server, `langgraph-api` >= 0.4.21 | live |
| CrewAI | A2A client and server as a documented first-class primitive; gRPC transport and horizontal scaling on AMP | live |
| Cisco | AGNTCY contributed to the Linux Foundation — a competing agent discovery and composition layer, per Muscariello in the same release | 2026-04-09 |

**What is not adopted: orchestration itself.** No framework in the table above
takes its control-flow model from A2A. Each one ships its own, and each treats
A2A as a call target. The one request to move A2A into the library layer —
LangGraph #7398 — is labelled `external` with no assignee after roughly six
months. `[INFERENCE]`

**Human-in-the-loop adoption tracks implementation language rather than the
protocols.** The strongest contract, AG-UI's, is at protocol 1.0 with a consumer
side and 0.0.x integration packages. ACP's is at Draft with explicit
do-not-ship guidance. A2A's is unmerged. MCP's exists but has no approval verb,
so what is deployed is vendor client policy. `[INFERENCE]`

**Arazzo's ecosystem is real; its agent story is not.** OAI claims that "the
Arazzo tooling ecosystem has expanded significantly since 1.0. Editors,
validators, parsers, resolvers, generators, and **standalone workflow execution
engines** are all available and listed in the Arazzo repository README", and
maintains a dedicated `openapi.tools` collection. Specmatic documents Arazzo
workflow testing, contract mocking and stateful microservice verification; Redocly
published a 1.1 release post; Speakeasy maintains parse, bundle and convert
packages. Tooling claims beyond OAI's own statement — API Flows Studio, Jentic,
Symplr, `arazzo-cli`, `arazzo2openapi` — are **[UNVERIFIED]**, as they come from
secondary vendor blogs rather than read at source. Inside the agentic stack
there is no adoption at all: no agent framework, no MCP server and no A2A
implementation references Arazzo as a workflow descriptor.

## Sharp edges

### Orchestration

- **There is no orchestration protocol, and the gap is named in public.** The
  `agents-wg` "Steering" issue identifies orchestrator-narrows-subagent as the
  motivating case, calls it "the ordinary case in agent-to-agent deployments",
  and enumerates why neither MCP nor A2A can express it. Both protocols are
  designing against the same missing primitive.
- **"Cross-runtime interoperability via A2A" was a 1.0 headline claim shipped
  alongside "A2A 1.0 support coming soon."** Anyone building cross-runtime
  interop on Agent Framework 1.0 is on a pre-1.0-spec binding.
- **A2A cannot safely add stream event types**, by its maintainers' own evidence
  across five SDKs. Every near-term feature is therefore constrained to ride
  `TaskStatusUpdateEvent`. This is a structural limit on protocol evolution.
- **Binding negotiation is unsettled across four implementations**: Agent
  Framework prefers HTTP+JSON, LangSmith implements JSON-RPC only, Copilot
  Studio sends the v0.3 `message/send`, and Agent Framework 1.0 says A2A 1.0
  support is "coming soon".
- **LangSmith's `historyScope` fails silently.** A mis-cased `historyscope` key
  is silently ignored and yields full-context history with no error. Streaming
  ignores `historyScope` and `historyLength` entirely and returns no error if
  they are sent.
- **Copilot Studio ships A2A v0.3 semantics.** Its own sample payload uses
  `"method": "message/send"` and its troubleshooting tip points at
  `/.well-known/agent.json`, the path A2A renamed to `agent-card.json` on
  2025-07-30.
- **Copilot Studio's multi-agent guidance is prompt engineering, not protocol.**
  Nine best practices, all instruction-level. Nothing mechanically enforces
  routing, turn ownership or context handoff.
- **Connected-agent privilege escalation is documented, not prevented**: "if the
  parent agent isn't allowed to delete records but the connected agent can, the
  parent agent shouldn't call the connected agent in scenarios where deletion
  might happen without proper approval."
- **Agent Framework's orchestration guardrail scope is the AutoGen problem
  inherited.** Handoff chains apply input guardrails to the first agent only and
  output guardrails to the final producer only.
- **AG2's `ag2>=1.0` is a breaking rewrite, not a version bump**, and AG2 is
  volunteer-maintained by two named administrators at 36K weekly PyPI downloads.
- **AutoGen sits in maintenance mode at 61.2k stars.** Both descendants — Agent
  Framework and AG2 — cite AutoGen's own orchestration research as their
  justification. `[INFERENCE]` A2A's success is part of what split the lineage.
- **Version hygiene is slipping**: the A2A site callout reads `1.0.0` while
  `v1.0.1` has shipped for four months; Copilot Studio's troubleshooting points
  at the pre-0.3.0 path and sends the v0.3 method name.

### Human-in-the-loop

- **A2A's HITL is the weakest link in the strongest standard.** The protocol
  carrying cross-vendor interop weight has an unmerged elicitation design, a TSC
  explicitly undecided as of 2026-09-01, and a roadmap item whose verb is
  "Explore". A2A 1.0's own guiding-principles claim of "async first … long-running
  tasks and human-in-the-loop interactions" is half-implemented.
- **In A2A a human decision is an ordinary `Message`**, so "the user approved"
  and "the user typed a correction" are indistinguishable on the wire, and
  nothing binds the message to a specific pending ask.
- **`TASK_STATE_AUTH_REQUIRED` cannot be relied on to gate anything**, because a
  client may resume without sending credentials and the agent may continue.
- **MCP deleted its async completion signal and deprecated its data-gathering
  channels in the same revision.** Out-of-band approval now depends on
  client-implemented retry and cancel controls that the spec only SHOULDs, and
  the Sampling and Roots channels a server would use to pre-collect approval
  context are deprecated. If a server blocks on its own side while the client
  waits, the user sees a dead UI.
- **MCP's `input_required` is addressed to nobody in particular**, self-documented
  in the specification's own inconsistency and raised as an open working-group
  question. The value union is collapsing onto the human-facing member exactly
  when agent-to-agent chains need the host-facing one.
- **MCP's `input_required` is blocking by construction.** The Tasks extension
  documents `inputRequests` as the blocking set by definition; partial
  `inputResponses` leave the task `input_required`. Non-blocking requests have no
  representation.
- **`requestState` integrity is the server's job and is attacker-controlled.**
  The MUST is conditional — on it influencing authorization, resource access or
  business logic — so a deployment that does not hit that condition carries the
  state unauthenticated.
- **ACP v2 is Draft with explicit "do not ship in production" guidance**, and
  v1's permission model is the tool-call-bound form the v2 RFD itself documents
  as the anti-pattern. v2 also removes `fs/*`, `terminal/*` and `session/set_mode`
  from the protocol.
- **ACP has no protocol-level resume idempotency or expiry**; MCP has no
  decision schema beyond `requestedSchema`; A2A has neither.
- **AG-UI's own implementation had a live interrupt bug one release ago**:
  `connectAgent()` failed when reconnecting to a thread with pending interrupts,
  fixed in `@ag-ui/client@1.0.1` on 2026-09-29. Interrupts surviving a page
  reload was a client-package defect, not a spec gap.
- **AG-UI's maturity is uneven**: protocol core at 1.0, but
  `@ag-ui/claude-agent-sdk@0.0.4`, `@ag-ui/spring-ai@0.0.3`,
  `@ag-ui/watsonx@0.0.2` and `@ag-ui/a2a-middleware@0.0.3` are not. AG-UI↔A2A
  is a separate third-party middleware package, not core, and there are no
  independent implementations to test interop against. `[INFERENCE]`
- **ACP and MCP diverged on elicitation completion within four days.** Any
  ACP↔MCP bridge must synthesize a poll loop from an async completion signal or
  vice versa.

### Arazzo

- **The exact gap that makes Arazzo interesting is exactly what it lacks.** It is
  the one standard that could unify deterministic multi-step orchestration,
  cross-protocol calls (MCP tools plus A2A agents in one workflow) and
  actor-in-the-loop HITL in a single declarative document. All three are
  unshipped. Until MCP and A2A step support land, it is OpenAPI's workflow
  sibling.
- **Actor-in-loop is a roadmap bullet, not a design.** A workflow that pauses for
  a human has no standard resume representation, and the natural implementation
  — poll an external state — is indistinguishable from a failure. `[INFERENCE]`
- **The normative parsing rules are strict and unusual.** Implementations that
  fetch lazily will silently diverge, and `NOT RECOMMENDED`-but-legal alternative
  identifiers are an interop trap by design.
- **The `$self` requirement is not yet universal.** Identity-based referencing is
  new in 1.1, so the existing 1.0 corpus has no `$self` and resolves by
  location — precisely the ambiguity 1.1 was written to remove.
- **Tooling quality is uneven and mostly commercial.** Editors and validators
  exist; the interoperable part, a reference runner that executes a workflow
  identically, does not. There is no Arazzo TCK, unlike A2A's.
- **Overlap with A2A is nil in practice.** Arazzo sequences API calls; A2A
  delegates tasks to opaque agents. Once MCP and A2A step support ships, Arazzo
  becomes a deterministic outer shell around agent calls, which is the layer this
  document finds missing everywhere else.

## Sources

**MCP — Model Context Protocol, revision 2026-07-28**

- [Specification index and llms.txt](https://modelcontextprotocol.io/llms.txt) — current revision set; confirms elicitation is absent from the deprecated set
- [Changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog) — MRTR/SEP-2322, required `resultType`, session removal, `server/discover`, `subscriptions/listen`, Tasks to an extension, minor item 11 removing `notifications/elicitation/complete` and the URL-mode `elicitationId`, SEP-2577
- [MRTR pattern](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr) — `InputRequiredResult`, `InputRequests`/`InputResponses`, the `requestState` integrity requirement, supported-method table
- [Elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation) — form and URL modes, `accept`/`decline`/`cancel`, capability advertisement, the URL-mode phishing analysis and the connect-URL mitigation
- [Deprecated features](https://modelcontextprotocol.io/specification/2026-07-28/deprecated) — Roots, Sampling, Logging, Dynamic Client Registration, `includeContext` values, HTTP+SSE; earliest removal on or after 2027-07-28
- [Tasks extension](https://modelcontextprotocol.io/extensions/tasks/overview) — `CreateTaskResult`, `tasks/get`/`tasks/update`/`tasks/cancel`, `notifications/tasks`, the state table
- [agents-wg issue 27, "Steering"](https://github.com/modelcontextprotocol/agents-wg/issues/27) — opened 2026-09-11, open; the `input_required` audience ambiguity, no steering carrier, blocking-by-construction `inputRequests`, eventually-consistent acknowledgement, no ordering; cites A2A #2125/#1992/#2129/#2149/#1582

**A2A — Agent2Agent Protocol, 1.0.0 (2026-03-12) and v1.0.1 (2026-05-26)**

- [Specification](https://a2a-protocol.org/latest/specification/) — the three-layer model, `spec/a2a.proto` as normative source, `TaskState`, `ListTasks` pagination, `return_immediately`, the `TASK_STATE_AUTH_REQUIRED` rules, `tenant` multi-tenancy
- [Landing page](https://a2a-protocol.org/latest/) — "What A2A Is Not", governance and TSC membership, Apache-2.0, SDK list
- [Release history](https://github.com/a2aproject/A2A/releases.atom) — v1.0.1, v1.0.0, v1.0.0-rc, v0.3.0 and the `agent.json` → `agent-card.json` rename
- [v1.0 launch post](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/) — multi-binding, multi-tenancy, Signed Agent Cards, OAuth device code plus PKCE
- [PR 2149](https://github.com/a2aproject/A2A/pull/2149) — elicitation proposal, opened 2026-08-18, unmerged; TSC undecided 2026-09-01
- [PR 2129](https://github.com/a2aproject/A2A/pull/2129) — timeline and ADR-002, merged; the five-SDK hard-error and silent-drop evidence; `Task.history` soft-deprecation
- [Roadmap](https://a2a-protocol.org/latest/roadmap/) — last updated 2026-09-15; "Elicitation & Multi-Turn Workflows (#2149, #2143)"
- [Extensions](https://a2a-protocol.org/latest/topics/extensions/) — `AgentExtension`, the `A2A-Extensions` header, the official namespace

**Agent Client Protocol**

- [Updates](https://agentclientprotocol.com/updates) — the dated changelog, including the v2 Draft, Elicitation (indexed 2026-07-22), Request Cancellation, the 1.0 SDKs and Registry stabilization
- [v2 draft announcement](https://agentclientprotocol.com/announcements/acp-v2-draft) — 2026-07-20, Ben Brandt; the production guidance
- [v1 to v2 migration guide](https://agentclientprotocol.com/protocol/v2/migration.md) — `state_update`, the permission restructure, the unknown-outcome rule, the support-both-versions requirement
- [v2 permission requests RFD](https://agentclientprotocol.com/rfds/v2/permission-requests) — revisions 2026-07-02 and 2026-07-14; the `subject` tagged union and its variants
- [Elicitation stabilized](https://agentclientprotocol.com/announcements/elicitation-stabilized) — published 2026-07-24; stabilizes `elicitation/complete` alongside `elicitation/create`
- [ACP Registry](https://agentclientprotocol.com/get-started/registry) — curated, authentication-capable agents only

**AG-UI, protocol 1.0**

- [Interrupts](https://docs.ag-ui.com/concepts/interrupts) — the outcome union, the eight normative contract rules, the reason taxonomy, approve-with-edits, the two-run audit trail, the snapshot-before-interrupt boundary rule, subagent attribution
- [Events](https://docs.ag-ui.com/concepts/events) — the event taxonomy
- [Releases](https://github.com/ag-ui-protocol/ag-ui/releases.atom) — `@ag-ui/proto@1.0.0` 2026-09-17, `@ag-ui/*@1.0.1` 2026-09-29, and the 0.0.x integrations

**Microsoft**

- [AutoGen repository](https://github.com/microsoft/autogen) — the maintenance-mode banner; 61.2k stars
- [Agent Framework 1.0](https://devblogs.microsoft.com/agent-framework/microsoft-agent-framework-version-1-0/) — 2026-04-03; the stable orchestrations and "A2A 1.0 support coming soon"
- [Agent Framework A2A integration](https://learn.microsoft.com/en-us/agent-framework/integrations/by-component/agent-services/a2a) — `A2AAgent`, `A2ACardResolver`, `PreferredBindings`, `ContinuationToken`; `ms.date` 2026-09-16
- [Copilot Studio A2A agent connection](https://learn.microsoft.com/en-us/microsoft-copilot-studio/add-agent-agent-to-agent) — endpoint-URL-not-card-URL, `.well-known` auto-population, the stale `agent.json` tip; `ms.date` 2026-08-26
- [Copilot Studio multi-agent patterns](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/multi-agent-patterns) — inline and connected agents, four topologies, nine best practices, the privilege-escalation warning; `ms.date` 2026-05-21

**OpenAI, Google, LangChain, CrewAI, AG2**

- [OpenAI Agents SDK handoffs](https://openai.github.io/openai-agents-python/handoffs/) — `transfer_to_<agent>` naming, `is_enabled` evaluation order, the guardrail-scope limits
- [OpenAI Agents SDK multi-agent](https://openai.github.io/openai-agents-python/multi_agent/) — orchestration patterns
- [OpenAI Agents SDK sitemap](https://openai.github.io/openai-agents-python/sitemap.xml) — the primary-source basis for the verified absence of any A2A page
- [Google ADK A2A](https://adk.dev/a2a/) — the language support badges, consuming and exposing quickstarts, the A2A Extension V2
- [LangSmith server A2A](https://docs.langchain.com/langsmith/server-a2a) — `/a2a/{assistant_id}`, binding coverage, `historyScope`, the documented limits
- [LangGraph issue 7398](https://github.com/langchain-ai/langgraph/issues/7398) — opened 2026-04-03, label `external`, no assignee
- [CrewAI A2A agent delegation](https://docs.crewai.com/v1.15.23/en/learn/a2a-agent-delegation) — the `A2AClientConfig` reference, four auth schemes, `fail_fast` degradation
- [AG2 Network overview](https://docs.ag2.ai/docs/user-guide/network/overview/) — `Hub`, `Passport`, `Resume`, `Rule`, `Envelope`, the four channel adapters, `TransitionGraph`, `HumanClient`
- [AG2 on PyPI](https://pypi.org/project/ag2/) — the `ag2` / `ag2-classic` split, the not-a-drop-in-upgrade statement, 1.1.0, `context.input()` and `hitl_hook`

**Arazzo**

- [Arazzo Specification v1.1.0](https://spec.openapis.org/arazzo/latest.html) — published 17 May 2026; the Specification Object, JSON Schema 2020-12, the MUST-fully-parse and MUST-resolve-by-identity rules
- [Arazzo 1.1 announcement](https://www.openapis.org/blog/2026/05/19/announcing-arazzo-specification-1-1) — 2026-05-19; AsyncAPI, chained workflow execution, the Selector Object, the Expression Type Object, and the post-1.1 roadmap
- [OAI/Arazzo-Specification](https://github.com/OAI/Arazzo-Specification) — the editor's draft and tooling directory
- [openapi.tools Arazzo collection](https://openapi.tools/collections/arazzo) — the tool directory cited by OAI

**Foundations and adoption**

- [Linux Foundation, A2A one-year release](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year) — 2026-04-09; the >150-organization count, the cloud platform embeddings, the AP2 extension, and the quotations
