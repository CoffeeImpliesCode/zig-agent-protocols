# Observability and Evaluation for Agent Interop

This document records the state of the observability layer as of 2026-09-29: the
signal schema (OpenTelemetry `gen_ai.*` and `mcp.*` versus OpenInference), the
propagation carrier each protocol reserves for W3C Trace Context, the aggregation
backends that ingest either dialect, and the near-empty evaluation-interchange
category. It does not define type names, tag values or byte layouts; those live
in [`../PROTOCOLS.md`](../PROTOCOLS.md). It also does not cover the identity,
gateway or security layers, which are recorded elsewhere in this directory.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

### Signal schema

Two competing attribute vocabularies exist. Both ride on OTLP. Neither is stable.

**OpenTelemetry GenAI semantic conventions.** The conventions were split out of the
core `semantic-conventions` repository into
[`open-telemetry/semantic-conventions-genai`](https://github.com/open-telemetry/semantic-conventions-genai).
The old `opentelemetry.io/docs/specs/semconv/gen-ai/*` pages are now stubs that
read "Moved ... no longer maintained in this repository".

State as declared by the project's own
[`model/manifest.yaml`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/manifest.yaml):

| Property | Value |
| --- | --- |
| `stability` | `development` |
| `schema_url` | `https://opentelemetry.io/schemas/gen-ai-dev/1.42.0-dev` |
| Core semconv dependency | `@v1.44.0[model]` |
| License | Apache-2.0 (all OTel projects) |

The
[model directory](https://github.com/open-telemetry/semantic-conventions-genai/tree/main/model)
contains exactly four namespaces: `aws-bedrock`, `gen-ai`, `mcp`, `openai`. The
docs additionally cover Anthropic and Azure AI Inference.
**There is no `a2a`, `acp` or `ag-ui` namespace.** [INFERENCE] Consequently no
backend can key an agent graph on a protocol discriminator other than
`gen_ai.operation.name` or `openinference.span.kind`.

Governance is real. GenAI is a *Specification* SIG named "Semantic Conventions and
Instrumentation: GenAI" per the
[community repository](https://raw.githubusercontent.com/open-telemetry/community/main/README.md):
general topics meet every Tuesday 9:00 PT (every other Tuesday 9:00 UTC+8), and
**agent-related topics have their own slot, every Monday 9:00 PT**, on Slack
`#otel-genai-instrumentation`. Maintainers are Liudmila Molkova (Google) and
Trask Stalnaker (Microsoft); the
[approver list](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/CONTRIBUTING.md)
includes Mike Goldsmith (Honeycomb) and Alex Hall (Pydantic/Logfire). [INFERENCE]
Two observability vendors therefore hold governance seats over a convention that
competes with one of their own products: Honeycomb ingests OTel GenAI and Pydantic
Logfire ships OpenInference instrumentation.

Maturity is low. `CHANGELOG.md` is an unreleased Towncrier stub and `README.md`
still carries a `## Schema URL — TODO` heading. The release date of the
`semantic-conventions-genai` split is NOT ESTABLISHED IN SOURCE.

**OpenInference.** Specified at
[`arize-ai.github.io/openinference/spec`](https://arize-ai.github.io/openinference/spec/),
repository [`Arize-ai/openinference`](https://raw.githubusercontent.com/Arize-ai/openinference/main/README.md).
It uses BCP-14 language. It states its own positioning:
*"complementary to OpenTelemetry"*, *"Every OpenInference trace is a valid OTLP
trace; the conventions give attribute names their AI-specific meaning."* The
repository license is [UNVERIFIED] — it was not checked against the license file.

| Axis | OTel GenAI | OpenInference |
| --- | --- | --- |
| Required discriminator | `gen_ai.operation.name` | `openinference.span.kind` |
| Span kinds | fixed by `gen_ai.operation.name` enum | `LLM`, `EMBEDDING`, `CHAIN`, `RETRIEVER`, `RERANKER`, `TOOL`, `AGENT`, `GUARDRAIL`, `EVALUATOR`, `PROMPT` |
| Attribute namespace | `gen_ai.*`, `mcp.*` | `llm.*`, `input.value`, `output.value`, `retrieval.documents`, `reranker.*`, `embedding.*`, `tool.*`, `document.*`, `message.*`, `session.id`, `user.id`, `tag.tags` |
| Stability | 100% Development | NOT ESTABLISHED IN SOURCE |
| Origin | CNCF OTel GenAI SIG | Arize |

Which one a deployment ends up with is a vendor choice, not a standards choice.
[INFERENCE] The split is observable in ingestion endpoints: backends that key on
`gen_ai.*` and backends that key on `openinference.span.kind` are separate
product surfaces, and only one accepts both.

### Propagation carrier

| Protocol | Trace-context carrier | Normative? | Spec location |
| --- | --- | --- | --- |
| **MCP** | `params._meta.traceparent` / `tracestate` / `baggage` | Yes — MUST follow W3C formats | revision `2026-07-28`, `basic/index.md`, via SEP-414 (Final) |
| **ACP** | `params._meta.traceparent` / `tracestate` / `baggage` | SHOULD on `_meta` root key names only; absent from `schema.json` | v1 `extensibility` docs |
| **A2A** | W3C HTTP headers | No — lowercase prose in a topic guide | `topics/enterprise-ready.md` |
| **AG-UI** | none | Nothing | none |

**MCP is the only normative reservation.** SEP-414, "Document OpenTelemetry Trace
Context Propagation Conventions", is
[Status Final, Standards Track, created 2025-04-25](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/seps/414-request-meta.md),
authored by Adrian Cole (@codefromthecrypt) with Marcelo Trylesinski (@Kludex) as
sponsor, PR `modelcontextprotocol/modelcontextprotocol#414`. It landed in the
current protocol revision `2026-07-28` (released 2026-07-28) as a *Minor* change.
The normative text in
[`basic/index.md`](https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md):

> **OpenTelemetry trace context:**
> As an exception to the prefix requirement above, the keys `traceparent`, `tracestate`, and `baggage` are reserved for OpenTelemetry trace context propagation. When present, their values **MUST** follow W3C Trace Context and W3C Baggage formats respectively.
> This exception exists to maintain compatibility with existing implementations and OpenTelemetry semantic conventions for MCP.

The carrier is `params._meta`, not HTTP headers. The exception to the `_meta`
prefix requirement is deliberate: the rationale is to stop implementations
namespacing it (`io.modelcontextprotocol.traceparent`), "which will break traces
and log correlation". There is **no dedicated tracing or observability page** in
the 2026-07-28 spec; all normative OTel text is this one subsection.

**MCP retired its own Logging feature in favour of OpenTelemetry.** SEP-2577,
"Deprecate Roots, Sampling, and Logging", is
[Status Final, Standards Track, created 2026-04-14](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/seps/2577-deprecate-roots-sampling-and-logging.md),
author Kurtis Van Gent. `logging/setLevel` and `notifications/message` are
**deprecated as of 2026-07-28**, with an explicit migration written into the
[changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog.md):
*"log to `stderr` (stdio) or use OpenTelemetry instead of Logging."* The
[Logging utility page](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/logging.md)
carries a normative banner to the same effect, plus a per-request
`io.modelcontextprotocol/logLevel` in `_meta` and an RFC 5424 level table. The SEP
rationale names OTel as the replacement: OpenTelemetry for structured
observability is "mature, widely adopted, and better suited to logging than an
application-protocol channel". [INFERENCE] This is the most consequential
observability change of the year — the protocol's own logging channel was retired
in favour of OTel, which makes the `_meta` trace-context reservation the only
remaining normative observability surface in the protocol.

**ACP is one notch weaker than MCP.** The
[ACP v1 extensibility page](https://agentclientprotocol.com/protocol/v1/extensibility)
says the `_meta` keys *"SHOULD be reserved for W3C trace context to guarantee
interop with existing MCP implementations and OpenTelemetry tooling"*: `traceparent`,
`tracestate`, `baggage`. ACP deliberately copied MCP's convention — SEP-414 cites
ACP PR `agentclientprotocol/agent-client-protocol#297` as the reciprocal change.
But [`schema/schema.json`](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/schema.json)
defines no `traceparent` field; a grep for `traceparent|tracestate|baggage|OpenTelemetry|tracing`
returns zero matches. [INFERENCE] A strict validator therefore drops the key
silently.

**A2A has no normative tracing.** A2A v1.0.0 shipped 2026-03-12. A grep of the
full 3,623-line
[`specification.md`](https://raw.githubusercontent.com/a2aproject/A2A/main/docs/specification.md)
for `trac(e|ing)|OpenTelemetry|observability|monitoring|b3 |traceparent` returns
only incidental hits: one guiding-principle bullet ("Address authentication,
authorization, security, privacy, tracing, and monitoring by aligning with
established enterprise practices"), three uses of "real-time monitoring of task
progress", and an "Audit and Monitoring" subsection about logging security-relevant
events. Zero normative tracing requirements, no `_meta` carrier, no `a2a.*`
attributes, no OpenTelemetry mention. The only guidance is
[non-normative prose](https://a2a-protocol.org/latest/topics/enterprise-ready/):
"A2A Clients and Servers **should** participate in distributed tracing systems.
For example, use OpenTelemetry to propagate trace context, including trace IDs and
span IDs, through standard HTTP headers, such as W3C Trace Context headers." The
word "should" is lowercase and uncapped, in a topic guide rather than the spec.

**AG-UI has nothing.** Grep of [`docs.ag-ui.com/llms.txt`](https://docs.ag-ui.com/llms.txt),
`agentic-protocols.md` and `tutorials/debugging.md` for
`traceparent|OpenTelemetry|observability|distributed tracing` returns zero matches.
[INFERENCE] Everything on the web about "AG-UI + OpenTelemetry" is blog content,
not specification.

### Aggregation

Backends split by dialect. The only verified dual-dialect ingestor is Datadog.

| Backend | Dialect ingested | Source |
| --- | --- | --- |
| Datadog | OTel GenAI 1.37+ **or** OpenInference | [docs](https://docs.datadoghq.com/llm_observability/instrument/otel_instrumentation/) |
| Honeycomb | OTel GenAI only | [docs](https://docs.honeycomb.io/send-data/use-cases/agents/) |
| Langfuse | OTel GenAI | [docs](https://langfuse.com/integrations/native/opentelemetry) |
| Braintrust | OTel, auto-converted to Braintrust `LLM` spans | [docs](https://www.braintrust.dev/docs/integrations/sdk-integrations/opentelemetry/send-traces-and-logs) |
| LangSmith | third dialect built on **OpenLLMetry**, not raw OTel GenAI | [docs](https://docs.langchain.com/langsmith/trace-with-opentelemetry) |
| Arize Phoenix / AX | OpenInference, native | [spec](https://arize-ai.github.io/openinference/spec/) |

[INFERENCE] No artifact joins multiple protocols in one graph. The only join key
is a shared W3C trace ID that each hop propagates independently; no protocol
defines the link between hops. OTel's answer is span links, which are interpreted
per backend and are not interoperable data.

## What it does

### Signal schema

**Agent spans** in the OTel GenAI conventions, all `Status: Development`, all
`Requirement level: Recommended`, per
[`gen-ai-agent-spans.md`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-agent-spans.md):

| Span | `gen_ai.operation.name` | Span name | Kind |
| --- | --- | --- | --- |
| Create agent | `create_agent` | `create_agent {gen_ai.agent.name}` | CLIENT |
| Invoke agent (remote) | `invoke_agent` | `invoke_agent {gen_ai.agent.name}` | CLIENT |
| Invoke agent (in-process) | `invoke_agent` | — | INTERNAL |
| Invoke workflow | `invoke_workflow` | — | — |
| Plan | `plan` | — | — |
| Execute tool | `execute_tool` | `execute_tool {gen_ai.tool.name}` | — |

The `gen_ai.operation.name` well-known values are `chat`, `create_agent`,
`create_memory`, `create_memory_store`, `delete_memory`, `delete_memory_store`,
`embeddings`, `execute_tool`, `fetch_response`, `generate_content`,
`invoke_agent`, `invoke_workflow`, `plan`, `retrieval`, `search_memory`,
`text_completion`, `update_memory`, `upsert_memory`. There is a memory-store
family and **no `evaluate` value**.
`gen_ai.provider.name` has 16 values: `anthropic`, `aws.bedrock`,
`azure.ai.inference`, `azure.ai.openai`, `cohere`, `deepseek`, `gcp.gemini`,
`gcp.gen_ai`, `gcp.vertex_ai`, `groq`, `ibm.watsonx.ai`, `mistral_ai`,
`moonshot_ai`, `openai`, `perplexity`, `x_ai`, and doubles as a telemetry-format
flavour discriminator.

Agent attributes: `gen_ai.agent.{id,name,version,description}`,
`gen_ai.conversation.id`, `gen_ai.system_instructions`, `gen_ai.tool.definitions`,
`gen_ai.input/output.messages`, `gen_ai.data_source.id`, and a granular token set
`gen_ai.usage.{text,image,audio}.{input,output}_tokens` with
`…cache_read/cache_write.input_tokens`.

**MCP spans and metrics**, per
[`mcp.md`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md):
`mcp.client` (CLIENT) and `mcp.server` (SERVER), span name
`{mcp.method.name} {target}` where target is `{gen_ai.tool.name}` or
`{gen_ai.prompt.name}`, with `mcp.resource.uri` explicitly excluded by default for
cardinality. Required attribute `mcp.method.name`; also `mcp.protocol.version`,
`mcp.session.id`, `mcp.resource.uri`, `jsonrpc.request.id`,
`jsonrpc.protocol.version`, `rpc.response.status_code`. Metrics are
`mcp.client.operation.duration`, `mcp.server.operation.duration`,
`mcp.client.session.duration`, `mcp.server.session.duration`. MCP recommends
*overriding* the generic `rpc` conventions: "it's RECOMMENDED to follow MCP
conventions instead of RPC semantic conventions."

Two design rules in that document matter for how a trace tree is shaped:

- Deduplication. If outer GenAI instrumentation already traces a tool execution,
  MCP instrumentation SHOULD NOT create a separate span, only add `mcp.*`
  attributes.
- Context independence. "MCP and underlying transport (such as HTTP) contexts are
  independent… The MCP client span becomes a parent of the MCP server span
  regardless of transport used; span links allow recording the transport context."

**OpenInference** adds what OTel lacks. The full reserved-attribute table is in
[`spec/semantic_conventions.md`](https://raw.githubusercontent.com/Arize-ai/openinference/main/spec/semantic_conventions.md):
`evaluation.{name,score,label,explanation,annotator_kind,identifier,metadata}`
plus the flattened collections `evaluations`, `trace.evaluations`,
`session.evaluations`, mirrored by a parallel `annotation.*` set for human and
coder feedback, and an `EVALUATOR` span kind. It also has deeper multimodal
attributes (`message_content.{type,text,image,audio,video,id,signature,data,encrypted_content}`
covering `reasoning`, `tool_use`, `redacted_thinking` and OpenAI
`encrypted_content`) and full cost accounting under `llm.cost.*`, including
`llm.cost.completion_details.reasoning` and `…cache_read/cache_write`. A recent
split distinguishes `llm.request.model_name` from `llm.response.model_name` to
capture provider-side routing.

The only bridge between the two dialects is
[`@arizeai/openinference-genai`](https://raw.githubusercontent.com/Arize-ai/openinference/main/js/packages/openinference-genai/README.md),
and its own README undercuts it: *"The OpenTelemetry GenAI conventions are still
incubating, and may include breaking changes at any time. This package will
attempt best effort conversions of **a subset**… Currently, attributes reflect
their definition as of **October 2025**."*

### Propagation carrier

MCP's non-normative example in the 2026-07-28 spec:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call",
 "params":{"name":"get_weather","arguments":{"location":"New York"},
  "_meta":{"traceparent":"00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"}}}
```

The reserved-keys table in the same page lists `traceparent`, `tracestate` and
`baggage` as "OpenTelemetry trace context propagation".

A2A's `should` is HTTP-header-only, which is a gap given that A2A's core use case
is long-running asynchronous tasks delivered by **push notifications
(server-initiated webhooks)** and **task resumption across reconnects**. Neither
carries a client trace context in the protocol. [INFERENCE] Traces will fork at
every webhook hop.

The A2A "Traceability Extension" exists but is a sample, not an official
extension. It lives at `a2aproject/a2a-samples/samples/python/extensions/traceability`
and activates via the `X-A2A-Extensions` header. Per the
[extension governance page](https://a2a-protocol.org/latest/topics/extensions/),
official extensions must use the `https://a2a-protocol.org/extensions/` URI
namespace and an `ext-` repo prefix under `a2aproject`; this one uses
`https://github.com/a2aproject/a2a-samples/extensions/traceability/v1`. It is
**not OTel-compatible**: its data model is proprietary Python
`ResponseTrace{trace_id, steps[]}` and
`Step{step_id, trace_id, parent_step_id, call_type(AGENT/TOOL/HOST), start_time, end_time, latency, cost, total_tokens, error}`,
with a `TraceStep` context manager and `ext.wrap_client()` monkey-patching. No W3C
trace context, no OTLP, no span parenting a generic OTel backend can consume. The
four extensions A2A lists as examples are Secure Passport, Timestamp, Traceability
and AGP; none is observability-as-OTel and none is official.

What does exist for A2A is SDK-level OTel integration:
`a2aproject/a2a-java/extras/opentelemetry` ("distributed tracing, metrics, and
context propagation across asynchronous boundaries") and OTel support in
`a2a-python`. [INFERENCE] These are libraries doing HTTP-level propagation, not
protocol-level conventions.

### Aggregation

[Datadog](https://docs.datadoghq.com/llm_observability/instrument/otel_instrumentation/)
ingests "either the OpenTelemetry 1.37+ semantic conventions for generative AI or
the supported OpenInference semantic conventions", with no Datadog SDK or Agent
required. It is the only backend verified to name both dialects in one sentence
and to list `opentelemetry-instrumentation-openai-v2` and
`openinference-instrumentation-openai` side by side in one tested-frameworks
table. Span links with `from`/`to` attributes render as edges in its Execution
Graph. External evals are tagged `source:otel` and require hex-to-decimal span ID
conversion. It also ships dedicated MCP pages for both directions and a
first-party [Datadog MCP server](https://docs.datadoghq.com/llm_observability/build_with_ai/mcp_server/)
with an `llmobs` toolset plus six agent skills
(`/agent-observability-eval-pipeline`, `/agent-observability-trace-rca`, …).
[INFERENCE] Observability platforms now exposing their own MCP surface closes the
loop started by MCP deprecating its logging channel.

[Honeycomb](https://docs.honeycomb.io/send-data/use-cases/agents/) takes OTel GenAI
only and requires `gen_ai.conversation.id`, `gen_ai.agent.name` and
`gen_ai.operation.name`. Agent Timeline groups on `gen_ai.agent.name`; missing
gives "Unknown", so each agent must use a unique name. It states the multi-agent
rule explicitly: *"The calling agent should emit the `invoke_agent` span, not the
agent being called. The called agent then emits its own spans under its own unique
`gen_ai.agent.name`."* It advises against sampling GenAI telemetry and ships a
full OTTL `transform` config remapping Claude Code's non-conformant
`claude_code.*` spans.

[Langfuse](https://langfuse.com/integrations/native/opentelemetry) ingests at
`/api/public/otel` with Basic auth and header
`x-langfuse-ingestion-version: 4`; without the header, data is delayed up to ten
minutes. It is the only backend found that recommends W3C Baggage plus a
`BaggageSpanProcessor` to carry `userId`, `sessionId`, `metadata` and `tags` to
every span, with a security warning that baggage crosses trust boundaries. Its
[MCP tracing page](https://langfuse.com/docs/observability/features/mcp-tracing)
documents the SEP-414 `_meta` flow end to end, contrasting separate traces at
service boundaries against linked traces, and says plainly: *"the Semantic
Conventions for GenAI attributes on traces are still evolving."*

[Braintrust](https://www.braintrust.dev/docs/integrations/sdk-integrations/opentelemetry/send-traces-and-logs)
ingests at `https://api.braintrust.dev/otel/v1/traces` with an `x-bt-parent` header
binding a trace to a project *or an experiment*. Its `BraintrustSpanProcessor`
(py and ts, with `filterAISpans`) auto-converts OTel LLM calls into Braintrust
`LLM` spans, and a separate "Link spans" doc exists for combining Braintrust and
OTel spans in one trace. [INFERENCE] Like Arize, Braintrust treats OTel as a
foreign source to be merged rather than adopted.

[LangSmith](https://docs.langchain.com/langsmith/trace-with-opentelemetry)
ingests OpenLLMetry conventions rather than raw OTel GenAI and recommends
Collector fan-out for multi-backend. It states the tradeoff: use OTel if you need
cross-service propagation or existing enterprise pipelines; use native LangSmith
format if you only need LangSmith evals, pending-run streaming and lower
overhead. It ships an official MCP server at `https://api.smith.langchain.com/mcp`
exposing traces, threads, prompts, datasets and experiments.

### Evaluation

No evaluation protocol exists. Ranked by closeness to a real standard:

1. **Span-carried eval attributes** — the only mechanism with broad working
   adoption. OpenInference's `evaluation.*` / `annotation.*` / `evaluations` /
   `trace.evaluations` / `session.evaluations` plus the `EVALUATOR` span kind, and
   OTel's `gen_ai.evaluation.{name, score.value, score.label, explanation}` (all
   Development). Both ride on OTLP, so a score attached to a span is portable
   across every backend. [INFERENCE] This is the de facto interchange mechanism
   and it is a telemetry convention, not a protocol. **No OTel `evaluate`
   operation name and no EVALUATOR span kind exist** — a checkable gap versus
   OpenInference.
2. **AAIF, `draft-schemacommons-aaif-00`** — [25 June 2026](https://datatracker.ietf.org/doc/draft-schemacommons-aaif/00/),
   B. van Bussel (Observalytics SL). Datatracker metadata: *Active Internet-Draft
   (individual)*, **RFC stream (None)**, **Intended RFC status (None)**, IESG
   state "I-D Exists", no AD, no stream, expires 2026-12-27. The datatracker
   states plainly: *"This I-D is not endorsed by the IETF and has no formal
   standing."* It nonetheless contains the most complete eval-interchange text
   found: §4.7 Telemetry (spans `aaif.agent.run`, `aaif.agent.tool_call`,
   `aaif.agent.llm_call`, `aaif.agent.memory_read/write`, `aaif.agent.handoff`;
   `telemetry.otlp_endpoint`; `telemetry.trace_context_header` default
   `traceparent`) and §4.8 Evaluation (`judge_model`, `metrics[]` with standard
   names `faithfulness`, `relevance`, `coherence`, `toxicity`,
   `hallucination_rate`, `task_completion`, `latency_ms`, `cost_usd_per_run`,
   `tool_call_accuracy`; `test_cases[]` with golden inputs and rubrics; CI gating
   on `status: active`). It also carries `sc_standard: "SC-006"`, seven
   conformance levels, `provenance.signature`, capability negotiation and Agent
   State checkpointing. Its `aaif.*` span names are not OTel GenAI, so
   [INFERENCE] adopting it would fork rather than unify the namespace.
3. **CUBE (Common Unified Benchmark Environments)** —
   [arXiv 2603.15798, submitted 2026-03-16](https://arxiv.org/abs/2603.15798),
   roughly 24 authors. MCP- and Gym-based, with layered task, benchmark, package and
   registry APIs. [INFERENCE] A research proposal, not a published specification.
4. **IEEE P3777**, "Standard for Benchmarking and Performance Metrics of AI
   Agents" — status **Active PAR**. Nothing published.
5. **ISO/IEC TR 42106:2026**, "Overview of differentiated benchmarking of AI system
   quality characteristics" — a Technical Report, overview-level, not an
   interchange format.
6. **MCP-AgentBench / MCP-Eval** — AAAI 2026 paper, LLM-as-judge protocol under MCP
   semantics. [INFERENCE] Evaluation *of* MCP, not a protocol *for* evaluation.
7. **AgentSpec** — appears as an OpenInference instrumentation target
   (`openinference-instrumentation-agentspec`). Maturity and provenance are
   [UNVERIFIED].

[INFERENCE] In practice each vendor ships its own non-interoperable dataset and
experiment format: Langfuse datasets, Braintrust projects and experiments, Phoenix
datasets, Datadog `DatasetRecordRaw[]` JSON. No format two of them can exchange
was found. The only genuinely portable eval artifact is a score attached to an
OTLP span.

## What changed recently

| Date | Change |
| --- | --- |
| 2025-04-25 | SEP-414 ("Document OpenTelemetry Trace Context Propagation Conventions") created |
| 2025-06-18 | MCP revision `2025-06-18` |
| 2025-10 | Attribute snapshot the OpenInference→OTel bridge still targets |
| 2025-11-25 | MCP revision `2025-11-25` |
| 2026-03-12 | A2A v1.0.0 ships, with no normative tracing |
| 2026-03-16 | CUBE submitted to arXiv |
| 2026-04-14 | SEP-2577 ("Deprecate Roots, Sampling, and Logging") created |
| 2026-06-25 | AAIF `draft-schemacommons-aaif-00` published |
| 2026-07-28 | MCP revision `2026-07-28` |

The 2026-07-28 MCP revision is the pivot. Changelog minor change 2 is verbatim:
"Document OpenTelemetry trace context propagation conventions for `_meta` keys
(`traceparent`, `tracestate`, `baggage`) (SEP-414)". Deprecated section 1 of the
same changelog is the load-bearing one: "Suggested migrations: ... log to `stderr`
(stdio) or use OpenTelemetry instead of Logging." The same revision also
confirmed protocol-level session removal: SEP-2567 removed `Mcp-Session-Id`,
SEP-2575 removed the handshake, and `ping` and `logging/setLevel` were removed
from the wire. A 12-month deprecation window applies.

Earlier revisions of the same protocol, for pin dating: `2026-07-28` (current) →
`2025-11-25` → `2025-06-18` → `2025-03-26` → `2024-11-05`.

Separately, the OTel GenAI conventions moved out of the core
`semantic-conventions` repository into `semantic-conventions-genai`, and now
publish under a `-dev` schema URL. The date of that split is NOT ESTABLISHED IN
SOURCE.

The result is that OTel's MCP model is already out of sync with MCP itself.
`mcp.session.id` and the metrics `mcp.client.session.duration` /
`mcp.server.session.duration` assume protocol sessions, which revision
`2026-07-28` deleted; applications now use server-minted state handles passed as
ordinary tool arguments. The `mcp.method.name` enum in
[`model/mcp/registry.yaml`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/mcp/registry.yaml)
still lists `ping` and `logging/setLevel`, both removed from the wire by that same
revision, plus the now-deprecated `notifications/message`, `sampling/createMessage`
and `roots/list`. [INFERENCE] Anyone writing an MCP collector against today's
semconv will produce dead cardinality dimensions.

Vendor documentation already lags the semconv, measurably. Honeycomb's
`use-cases/agents` page documents `gen_ai.usage.cache_creation_input_tokens` and
`gen_ai.evaluation.result`, while
[`model/gen-ai/registry.yaml`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/gen-ai/registry.yaml)
defines `gen_ai.usage.cache_write.input_tokens` and
`gen_ai.evaluation.{name,score.value,score.label,explanation}`. Langfuse links to
the old registry URL `semconv/attributes-registry/gen-ai/`, for a convention that
has since moved repositories entirely.

## Evidence of adoption

**Reference implementations named by SEP-414** — the protocol's own adoption
list, which is the strongest available signal that the `_meta` reservation is
implemented rather than merely published: C# SDK `Diagnostics.cs`; Python SDK PR
#1693; OpenInference MCP instrumentation in both Python and TypeScript; Envoy AI
Gateway `internal/tracing/tracingapi/mcp.go`; Pydantic Logfire
`_internal/integrations/mcp.py`; Stacklok ToolHive #3399.

**OpenInference instrumentation breadth**, per the
[project README](https://raw.githubusercontent.com/Arize-ai/openinference/main/README.md):
roughly 30 Python instrumentations (OpenAI, Anthropic, Bedrock, Google GenAI,
VertexAI, Mistral, Groq, Cohere, Ollama, LiteLLM, LangChain, LlamaIndex, DSPy,
CrewAI, Haystack, Agno, AG2, AutoGen, Google ADK, PydanticAI, smolagents,
Pipecat, Strands, Agentspec, BeeAI, Together, TypeSafe, Instructor, Portkey,
Guardrails, MCP), roughly 14 JavaScript, 6 Java and 3 Go. Span processors
normalise OpenLIT and OpenLLMetry into OpenInference. Native to Arize Phoenix and
Arize AX; usable with any OTLP collector. [INFERENCE] OpenInference is winning on
breadth of instrumentation, not on standardization.

**Per-vendor verification, all read from vendor documentation on 2026-09-29**:
Datadog, Honeycomb, Langfuse, Braintrust, LangSmith and Arize all document
agent-span ingestion, listed in the aggregation table above.

**Honeycomb's Mike Goldsmith is a semconv approver** per the project
[CONTRIBUTING.md](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/CONTRIBUTING.md),
and Honeycomb's Director of AI Strategy appears in the MCP 2026-07-28 release
blog noting roughly 20% of monthly interactive queries are agent-made.
[INFERENCE] Vendor participation in the convention and in the protocol's user base
is not the same as protocol adoption of the convention; neither number was
verified for MCP or A2A.

**Absent adoption, stated as a negative result:** no ecosystem adoption of AAIF;
no adoption evidence found for CUBE; nothing published for IEEE P3777.

### Normative status ladder

| Tier | Items |
| --- | --- |
| Real standard (normative, multi-vendor, protocol-governed) | W3C Trace Context and W3C Baggage; MCP SEP-414's `_meta` convention (Final, shipped in `2026-07-28`) |
| Emerging standard, still incubating | OTel GenAI semconv including `mcp.*` — real governance, 100% Development stability, already out of date against MCP `2026-07-28` |
| Documentation-level, no schema backing | ACP's `_meta` reservation; A2A's distributed-tracing "should"; everything about AG-UI |
| Vendor convention with de facto reach | OpenInference (Arize-originated, ingested by Datadog, broadest instrumentation catalogue) |
| Vendor-private | Braintrust `braintrust.*` and `x-bt-parent`; LangSmith native run format; Langfuse `langfuse.*` and its baggage-propagation pattern; Datadog `dd-otlp-source=llmobs`; Honeycomb's required-attribute set |
| Samples and proposals, not standards | A2A Traceability Extension (non-OTel sample); OWASP Agent Observability Standard (security-guardrail www-project, `aos.owasp.org`, with A2A and MCP hooks but no interop trace standard, and its A2A hook list still referencing pre-1.0 Google A2A method names); AAIF (individual I-D); CUBE (arXiv); IEEE P3777 (Active PAR); ISO/IEC TR 42106 (overview TR) |

## Sharp edges

1. **Nothing agent-specific is Stable.** Every `gen_ai.*` attribute, every
   `mcp.*` attribute, every agent and MCP span and every MCP metric is
   `development`, on a `-dev` schema URL, with an empty Towncrier changelog.
   Anything built on them is unpinned.
2. **The MCP model in semconv is already out of sync with MCP itself** — sessions,
   `ping` and `logging/setLevel` are all described against a wire that revision
   `2026-07-28` changed.
3. **Two competing dialects, and the only bridge is self-declared lossy and stale.**
   `@arizeai/openinference-genai` covers "a subset" and reflects "October 2025"
   definitions. LangSmith adds a third flavour. Datadog ingests two; nobody
   ingests three.
4. **Vendor docs lag the semconv.** Copying Honeycomb's OTTL transform verbatim
   emits attribute names the current registry does not define.
5. **MCP trace context is invisible to intermediaries.** It travels in
   `params._meta`, not headers, so an HTTP proxy, gateway, WAF or rate limiter sees
   only the HTTP trace. SEP-2028 ("forwarding `_meta` values to HTTP headers")
   would close this, and it is **NOT ESTABLISHED IN SOURCE** whether it landed;
   it is cited by SEP-414 but is absent from the published SEP index and its file
   returns 404. SEP-1788 (reserved `_meta` keys) is in the same position.
6. **A2A's asynchronous model defeats naive header propagation.** Push
   notifications and cross-reconnect resumption carry no client trace context, and
   A2A's only guidance is non-normative lowercase prose. Its only "traceability
   extension" is a non-OTel sample.
7. **ACP is the weakest carrier despite being MCP-aligned.** The reservation is
   documentation-level; `schema.json` defines no such field, so a strict validator
   drops it silently.
8. **AG-UI is a black hole for tracing.** A 1.0 spec with two transports, eight
   event families, a full event envelope and subagent attribution, and zero
   observability content. The frontend-to-agent hop must be hand-rolled.
9. **The protocols do not agree on span boundaries.** Honeycomb mandates the
   *caller* emit `invoke_agent`; OTel's `invoke_agent.client` versus
   `invoke_agent.internal` split is about process boundary, not agent boundary;
   MCP says suppress its own span when outer GenAI instrumentation already covers
   the tool call. With no cross-protocol norm, trace-tree shape is per vendor.
10. **Sampling guidance is a real production hazard.** Honeycomb explicitly warns
    against sampling GenAI telemetry because rare agentic failures hide in long
    traces. There is no equivalent head-sampling guidance in the OTel GenAI docs.
11. **Privacy is a spec-level hazard.** `gen_ai.tool.call.arguments`,
    `gen_ai.tool.call.result`, `gen_ai.prompt.variable.*` and the whole
    `gen_ai.input/output.messages` family carry prompts and PII by design and are
    flagged as potentially sensitive. MCP's SEP-414 security note says trace
    context in `_meta` "may include correlation IDs" and defers to local
    guidance. [INFERENCE] No protocol-level redaction or consent mechanism exists
    anywhere in this layer.
12. **SEP status is hard to verify from public artefacts.** SEP-2028 and SEP-1788
    are cited by SEP-414 but absent from the published SEP index, and their files
    404. Anyone building on the "companion tracing SEP" should confirm against the
    repository before relying on it.
13. **No evaluation interchange format exists**, only span-carried scores, one
    individual Internet-Draft with no IETF standing, one arXiv proposal and one
    unpublished PAR.

### The trace-join gap, stated plainly

No artifact joins multiple agent protocols in one trace graph. There is no
`a2a.*`, `acp.*` or `ag-ui.*` namespace in the OTel registry, and no protocol
defines the link between hops. MCP reserves W3C trace context normatively in
`params._meta`; ACP reserves the same key names by documentation SHOULD with no
schema field; A2A mentions HTTP headers in non-normative prose and carries no
context across its own push-notification and resumption paths; AG-UI says nothing
at all. OTel + W3C Trace Context is the whole of the answer, and span links — the
mechanism OTel offers for joining disconnected segments — are interpreted
per backend, not carried as interoperable data. A trace that crosses MCP, ACP, A2A
and AG-UI is joined by a shared `traceparent` that each hop propagates
independently and that no specification governs end to end.

## Sources

- [SEP-414: Document OpenTelemetry Trace Context Propagation Conventions](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/seps/414-request-meta.md) — Status Final, Standards Track, created 2025-04-25, author Adrian Cole, sponsor Marcelo Trylesinski, PR `modelcontextprotocol/modelcontextprotocol#414`. Source of the convention; cross-references ACP PR `agentclientprotocol/agent-client-protocol#297` and lists SEP-1788 and SEP-2028 as related. Also the reference-implementation list used for adoption evidence.
- [MCP specification 2026-07-28, `basic/index.md`](https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md) — the normative landing site for SEP-414, the reserved-`_meta`-keys table row and the non-normative example.
- [MCP specification 2026-07-28, changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog.md) — minor change 2 verbatim; deprecated section 1 migration text; session, `Mcp-Session-Id`, `ping` and `logging/setLevel` removal; 12-month deprecation window.
- [SEP-2577: Deprecate Roots, Sampling, and Logging](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/seps/2577-deprecate-roots-sampling-and-logging.md) — Status Final, Standards Track, created 2026-04-14, Kurtis Van Gent; deprecation tables and the OTel replacement rationale.
- [MCP specification 2026-07-28, Logging utility](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/logging.md) — normative deprecation banner, `io.modelcontextprotocol/logLevel` in `_meta`, RFC 5424 level table.
- [OTel GenAI semconv, `mcp.md`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md) — two spans, four metrics, the transport/MCP context-independence note and the deduplication rule.
- [OTel GenAI semconv, agent spans](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-agent-spans.md) — the six agent spans, the `gen_ai.operation.name` and `gen_ai.provider.name` enums.
- [OTel GenAI semconv, `model/manifest.yaml`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/manifest.yaml) — `stability: development`, `gen-ai-dev/1.42.0-dev` schema URL, core semconv dependency.
- [OTel GenAI semconv, `model/mcp/registry.yaml`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/mcp/registry.yaml) — Development stability for every `mcp.*` attribute; `mcp.method.name` enum still carrying methods the 2026-07-28 revision removed.
- [OTel GenAI semconv, `model/gen-ai/registry.yaml`](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/gen-ai/registry.yaml) — `gen_ai.evaluation.*` at Development; no `evaluate` operation name.
- [OTel GenAI semconv, `model/` directory](https://github.com/open-telemetry/semantic-conventions-genai/tree/main/model) — proves the four-namespace coverage and the absence of any agent-protocol namespace.
- [OTel GenAI semconv, CONTRIBUTING.md](https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/CONTRIBUTING.md) — maintainers and approvers, including Honeycomb and Pydantic Logfire seats.
- [OTel community SIG table](https://raw.githubusercontent.com/open-telemetry/community/main/README.md) — GenAI SIG meeting slots including the Monday agent-topics slot.
- [A2A 1.0 specification](https://raw.githubusercontent.com/a2aproject/A2A/main/docs/specification.md) — 3,623 lines; the grep result showing no tracing section and no OpenTelemetry mention.
- [A2A enterprise-ready topic](https://a2a-protocol.org/latest/topics/enterprise-ready/) — the only tracing guidance in the project, non-normative and HTTP-header-only.
- [A2A v1.0 announcement, 2026-03-12](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/) — TSC membership; observability absent from the feature list.
- [A2A extension governance](https://a2a-protocol.org/latest/topics/extensions/) — official namespace rules that the Traceability Extension does not follow.
- [A2A Traceability Extension analysis](https://a2aprotocol.ai/docs/guide/traceability-extension-analysis) — the proprietary Python data model proving it is not OTel-based.
- [ACP v1 extensibility](https://agentclientprotocol.com/protocol/v1/extensibility) — the `_meta` key reservation SHOULD and its stated purpose.
- [ACP `schema.json`](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/schema/schema.json) — zero matches for the reserved trace-context keys, proving the reservation is documentation-level.
- [OpenInference spec](https://arize-ai.github.io/openinference/spec/) — positioning, the ten span kinds including `EVALUATOR`.
- [OpenInference semantic conventions](https://raw.githubusercontent.com/Arize-ai/openinference/main/spec/semantic_conventions.md) — the full reserved-attribute table, `evaluation.*` / `annotation.*`, cost accounting, multimodal attributes.
- [OpenInference README](https://raw.githubusercontent.com/Arize-ai/openinference/main/README.md) — instrumentation inventory across four languages; OpenLIT and OpenLLMetry span processors.
- [`@arizeai/openinference-genai` README](https://raw.githubusercontent.com/Arize-ai/openinference/main/js/packages/openinference-genai/README.md) — the self-declared lossy, October-2025-stale bridge.
- [Datadog OTel instrumentation](https://docs.datadoghq.com/llm_observability/instrument/otel_instrumentation/) — the dual-dialect ingest statement and tested-framework table.
- [Datadog MCP server](https://docs.datadoghq.com/llm_observability/build_with_ai/mcp_server/) — the `llmobs` toolset and six agent skills.
- [Honeycomb agents](https://docs.honeycomb.io/send-data/use-cases/agents/) — required attributes, the caller-emits-`invoke_agent` rule, the Claude Code OTTL transform.
- [Langfuse native OpenTelemetry](https://langfuse.com/integrations/native/opentelemetry) — OTLP endpoint, ingestion-version header, baggage-propagation recommendation.
- [Langfuse MCP tracing](https://langfuse.com/docs/observability/features/mcp-tracing) — the SEP-414 `_meta` flow end to end, separate versus linked traces.
- [Braintrust OpenTelemetry](https://www.braintrust.dev/docs/integrations/sdk-integrations/opentelemetry/send-traces-and-logs) — OTLP endpoint, `x-bt-parent`, span processor.
- [LangSmith OpenTelemetry ingestion](https://docs.langchain.com/langsmith/trace-with-opentelemetry) — OpenLLMetry basis and the stated OTel-versus-native tradeoff.
- [AAIF `draft-schemacommons-aaif-00`](https://datatracker.ietf.org/doc/draft-schemacommons-aaif/00/) — 25 June 2026, individual draft, no stream, no intended RFC status, expires 2026-12-27; §4.7 telemetry and §4.8 evaluation.
- [CUBE, arXiv 2603.15798](https://arxiv.org/abs/2603.15798) — submitted 2026-03-16, roughly 24 authors; MCP- and Gym-based benchmark wrapper.
- [AG-UI documentation index](https://docs.ag-ui.com/llms.txt) — the zero-match grep across the 1.0 specification and concepts.
- [OWASP Agent Observability Standard](https://aos.owasp.org/spec/instrument/a2a/extend_a2a/) — the cross-protocol attempt, and why it is a security-guardrail spec rather than an interop trace standard.
