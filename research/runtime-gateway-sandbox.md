# Runtime, gateway and sandbox layers

This document covers the three layers that sit around a wire protocol rather than
inside it: the **gateway** (the proxy that fans an agent out to tools and models),
the **sandbox** (the isolation boundary that runs untrusted code), and the
**runtime** (the service contract that hosts an agent and its loop). It does not
restate the MCP or A2A wire formats, which have their own documents. Every claim
below is dated evidence about what existed on 2026-09-29. Nothing here is
normative; the wire values live in `PROTOCOLS.md`.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

Three tags are load-bearing: `[UNVERIFIED]` marks a single-sourced claim, and
`[INFERENCE]` marks a conclusion drawn from sources rather than stated in one.
`NOT ESTABLISHED IN SOURCE` marks a value that no primary source provided. A
value missing here is not a value to guess: a wrong constant in `src/` is worse
than an absent one.

## State

### Gateway

**No gateway standard exists.** There is no specification, no closed SEP, no
IETF wire protocol, and no mesh contract for the proxy layer. Every gateway is a
bespoke product with its own config schema, policy language and auth scheme.

| Where a standard could live | What is actually there |
| --- | --- |
| MCP specification | Deliberately gateway-*enabling*, not gateway-specifying. No gateway SEP is on the [roadmap last updated 2026-08-22](https://modelcontextprotocol.io/development/roadmap). |
| MCP SEP process | [SEP-1763, "Interceptors for Model Context Protocol"](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1763) — opened 2025-11-04, **closed**, labeled "SEP proposal without a sponsor". |
| IETF | [`draft-agent-gw-02`](https://datatracker.ietf.org/doc/draft-agent-gw/) — individual draft, no working group, no RFC stream, IESG state "I-D Exists". |
| AAIF | Two hosted projects, both products: [agentgateway](https://aaif.io/projects) and [Agent Router](https://aaif.io/projects/agent-router). Exactly six hosted projects in total, and no working group is chartered on gateways. |
| A2A | [`a2aproject/a2a-gateway`](https://github.com/a2aproject/a2a-gateway) is an **empty repository** — 1 star, 0 forks, GitHub renders "This repository is empty". Its only content is a description: "A2A Gateway allowing hooking up A2A Agents to different communications channels." |
| Kubernetes | The [Gateway API](https://gateway-api.sigs.k8s.io/) is real, mature and deliberately protocol-agnostic. Neither AAIF gateway extends it to agent semantics. |
| Registry | The [official MCP Registry](https://modelcontextprotocol.io/registry/about) ships an OpenAPI spec that sub-registries may implement. That standardizes registries, not proxies. |

The absence is the finding. Everything else in this section is a vendor's answer
to a gap nobody has closed.

### Sandbox

**No foundation-governed sandbox protocol exists.** What exists is a converging
API layer that is close to a protocol without being one, plus a set of
isolation substrates from three vendors with incompatible guarantees.

| Project | Shape | Governance |
| --- | --- | --- |
| [`kubernetes-sigs/agent-sandbox`](https://github.com/kubernetes-sigs/agent-sandbox) | `Sandbox` CRD (v1beta1) for isolated, stateful, singleton workloads; stable hostname and network identity; persistent storage; controller-managed lifecycle including pause/resume. Extensions: `SandboxTemplate`, `SandboxClaim`, `SandboxWarmPool`. Components `sandboxd` and `sandbox-router`. Docs at [agent-sandbox.sigs.k8s.io](https://agent-sandbox.sigs.k8s.io/). | Kubernetes SIG Apps. 4.1k stars, 536 forks, 1,051 commits, Apache-2.0. |
| [`opensandbox-group/OpenSandbox`](https://github.com/opensandbox-group/OpenSandbox) | Sandbox lifecycle and execution APIs as public OpenAPI contracts; enhancement proposals in `oseps/`; five SDKs (Python, Java/Kotlin, TypeScript, C#/.NET, Go); `osb` CLI; its own MCP server. Runtimes: Docker, Kubernetes, and a Firecracker microVM "fast-sandbox" via an external FastPath v2 gRPC control plane. | Alibaba-originated. 15.6k stars, 1.4k forks, OpenSSF Best Practices badge, listed in the CNCF landscape. Under no foundation. |
| MCP Tasks | Standard, but about **work handles**, not isolation. | [SEP-2663](https://modelcontextprotocol.io/extensions/tasks/overview); `io.modelcontextprotocol/tasks`. |

The two Kubernetes-facing projects have converged: the OpenSandbox 1.1.0 release
notes state a hard requirement on `agents.x-k8s.io/v1beta1`, which is the
agent-sandbox CRD API group. [INFERENCE] That requirement, plus agent-sandbox
being consumed by OpenSandbox, makes `Sandbox` the de-facto orchestrator API —
but it remains a Kubernetes API, and a non-Kubernetes vendor cannot plug in
without a shim.

### Runtime

**No cross-vendor agent runtime API exists.** Every concrete runtime API is
vendor-specific. What *is* shared is a conceptual decomposition and, in one
case, a published port contract.

| Vendor | Runtime API | Contract published |
| --- | --- | --- |
| AWS | [Bedrock AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/) | Yes — a full [service contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-service-contract.html) with fixed ports for four protocols. The only normative runtime service contract found. |
| OpenAI | [Agents API](https://developers.openai.com/api/docs/guides/agents-api/architecture), in beta | A self-hosted executor contract, but it still requires an OpenAI API key and a codex-family executor. |
| Google | [ADK](https://google.github.io/adk-docs/) → Vertex AI Agent Engine, now branded Gemini Enterprise Agent Platform | No equivalent service contract published. |
| AAIF | No working group chartered on runtime APIs. | — |

AAIF's working groups are Accuracy & Reliability, Agentic Commerce,
Governance/Risk & Regulatory, Identity & Trust, Observability & Traceability,
Security & Privacy, Workflows & Process Integration, and Taxonomy & Landscape.
The two nearest to this layer concern delegation semantics and tracing, not
runtime invocation. [Source: [aaif.io](https://aaif.io/)]

## What it does

### Gateway

**MCP 2026-07-28 is gateway-enabling, not gateway-specifying.** The
[2026-07-28 release](https://blog.modelcontextprotocol.io/posts/2026-07-28)
retired the `initialize`/`initialized` handshake and the `Mcp-Session-Id` header
(SEP-2575, SEP-2567), so every request is self-describing. The stated
consequence: "any request can land on any instance behind a plain round-robin
load balancer without needing shared storage."

The routing change is the gateway-relevant one. [SEP-2243, "HTTP Header
Standardization"](https://modelcontextprotocol.io/seps/2243-http-standardization),
created 2026-02-04, Final, Standards Track, makes `Mcp-Method` and `Mcp-Name`
**required** on Streamable HTTP, so that "your gateway, rate limiter, or WAF can
route and meter on those headers instead of parsing JSON bodies". Servers must
reject a request whose headers and body disagree. The SEP's own rationale is
that "proxies and gateways cannot make routing decisions without deep packet
inspection". An optional `x-mcp-header` schema extension mirrors tool parameters
into `Mcp-Param-{Name}`.

What that does and does not do: it lowers the barrier to a plain L7 load
balancer. It does not standardize tool aggregation, catalog filtering, principal
to backend mapping, or upstream capability caching. Every one of those is
per-implementation.

Three seams in this layer are genuinely standardized; everything else is not.

| Seam | Status |
| --- | --- |
| `Mcp-Method` / `Mcp-Name` header routing and metering | Standardized, Final, shipped 2026-07-28 |
| [Enterprise-Managed Authorization](https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization) (from SEP-990) | Standardized as an extension; the enterprise IdP becomes the authoritative decision-maker via an Identity Assertion JWT Authorization Grant (ID-JAG) |
| [Registry OpenAPI](https://modelcontextprotocol.io/registry/about) for sub-registries | Standardized interop artifact |
| Tool aggregation, catalog filtering, backend mapping, capability caching | Per-vendor |

**The two AAIF projects.** They are complementary in coverage and direct
competitors for the same seat.

*agentgateway* — a Rust data plane with a Go Kubernetes controller, created at
Solo.io around 2025-03, donated to the Linux Foundation at Open Source Summit
Europe 2025-08-25, accepted as an [AAIF project on 2026-06-04](https://aaif.io/blog/agentgateway-joins-aaif-as-an-open-gateway-for-agentic-ai-infrastructure)
as the fourth hosted project. Proposal
[#11, opened 2026-04-09](https://github.com/aaif/project-proposals/issues/11).
Stable release v1.5.0 on 2026-08-27; v1.6.0-alpha.2 on 2026-09-22 is
pre-release. It federates MCP, A2A, LLM inference APIs and plain HTTP/gRPC in
one proxy, deployable standalone or conformant to the Kubernetes Gateway API, with
hot xDS reload. It is A2A-native: it proxies A2A, logs `a2a.method` into access
logs, and rewrites the Agent Card URL so that `/.well-known/agent.json` served
through the proxy points back at the gateway. Its
[spec-compatibility page](https://agentgateway.dev/docs/standalone/latest/documentation/mcp/spec-compatibility.md)
documents automatic protocol-version negotiation and fallback. It publishes no
wire specification; its only external standard claim is Gateway API conformance,
which is about routing, not agents.

*Agent Router* — the renamed Envoy AI Gateway, started October 2024 by
Bloomberg and Tetrate, renamed [2026-09-09](https://theagentrouter.ai/blog/envoy-ai-gateway-is-now-agent-router)
and [joined AAIF on 2026-09-10](https://aaif.io/projects/agent-router), three
weeks before this research date. Proposal
[#18, opened 2026-04-24](https://github.com/aaif/project-proposals/issues/18).
v1.0.0 GA on 2026-06-23; v1.1.0 on 2026-08-21. It is an Envoy Gateway control
plane whose ext-proc filter multiplexes MCP tool servers behind an `MCPRoute`
CRD with per-tool CEL authorization, and routes 16 LLM providers under one
OpenAI-compatible API. **It does not support A2A**; A2A appears only as a
roadmap bullet in proposal #18. The rename left CRDs, the
`aigateway.envoyproxy.io` API group, the `aigw` CLI, images, Helm charts and the
Go module path unchanged.

The competition is structural: two foundation-hosted projects, whose stated job
includes "MCP gateway", three months and three weeks apart respectively, with no
shared spec, no interop test suite and no migration path between them. [INFERENCE]
Buyers must pick one seat.

**The IETF draft is architecture only.** [`draft-agent-gw-02`](https://datatracker.ietf.org/doc/draft-agent-gw/),
"Agent Communication Gateway for Semantic Routing and Working Memory"
(Tsinghua University / Beijing University of Posts and Telecommunications),
-02 dated 2026-07-06, last updated 2026-07-12, expires 2027-01-07. Datatracker
is unambiguous: individual draft, no RFC stream, no intended status, no working
group. It defines a three-tier architecture (Access / Domain / Inter-domain
Agent-GW), semantic routing by intent and capability, working memory, capability
digests as a privacy-preserving aggregation, APA protocol adaptation, and a
knowledge delivery network for inference artifacts such as KV caches. It carries
no wire format, no method names and no negotiation. [INFERENCE] Its existence is
evidence that the layer is being conceptualized, not standardized. A separate
individual draft, `draft-serra-mcp-discovery-uri`, proposes an `mcp://` scheme
and `/.well-known/mcp-server` discovery with JWS-signed manifests; also
individual, also not a gateway contract.

**SEP-1763 is the closed attempt.** Opened 2025-11-04 by `@sambhav` — the same
maintainer who filed Agent Router's AAIF proposal — it proposed a first-class
`Interceptor` resource with request and response phases, severity-graded
validation, mutation and discovery, explicitly to solve the M × N problem. Its
motivation section is the cleanest public statement of why a gateway standard is
wanted. It is closed as "SEP proposal without a sponsor". The narrative that
its ideas were absorbed into an "MCP Interceptors WG" is `[UNVERIFIED]`: no
confirmation was found in any primary source.

**A2A has no gateway.** The empty `a2aproject/a2a-gateway` repository is the
verdict. The [A2A roadmap, last updated 2026-09-15](https://a2a-protocol.org/latest/roadmap/)
covers v1.1 enhancements, bidirectional streaming, an A2A CLI, elicitation and
validation tooling; it has no gateway item, and neither does the repository
README's "What's next". Discovery is filled by
[a2a-registry.org](https://www.a2a-registry.org/) — 360 agents, 87 DNS-verified —
which is third-party and not sanctioned by a2aproject. A2A is explicitly
east-west traffic between agents, and it is the protocol with the least standard
machinery around its network layer.

### Sandbox

**Isolation tiers.** "Sandbox" is not a comparable claim: the vendors below sit
at three different levels of containment with different guarantees.

| Tier | Primitive | Vendors and figures |
| --- | --- | --- |
| V8 isolate | Language runtime sandbox, no filesystem, fetches disabled by default | [Cloudflare Code Mode](https://blog.cloudflare.com/code-mode-mcp/): the whole Cloudflare API (~2,500 endpoints) exposed as two tools, `search()` and `execute()`, ~1,000 tokens of context against 1.17M natively |
| Container | Standard namespaced container | [Daytona](https://www.daytona.io/docs/en/sandboxes/) defaults to a Linux container at under 90 ms; [Docker MCP Gateway](https://github.com/docker/mcp-gateway) runs each catalog server as a container; [Modal](https://modal.com/docs/guide/sandboxes) is container-based with a 5-minute default and 24-hour maximum lifetime |
| Syscall-intercepted container | gVisor | Supported by agent-sandbox and OpenSandbox via RuntimeClass, but **not snapshottable** — OpenSandbox rejects gVisor snapshots with HTTP 409 `SNAPSHOT::UNSUPPORTED_RUNTIME` |
| MicroVM | Firecracker, Kata Containers | [E2B](https://docs.e2b.dev/changelog) on Firecracker with ~150 ms boot and memory-preserving pause/resume; OpenSandbox's fast-sandbox provider via FastPath v2 at ~80 ms startup; [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) on a local microVM; [microsandbox](https://github.com/superradcompany/microsandbox) on libkrun with under 100 ms boot |

Daytona additionally offers Linux VM, Windows VM, macOS on Apple silicon and GPU
(H100/H200/RTX/MI355X) classes, with fork, pause/resume, memory snapshots and
two regions.

**The orchestrators.** agent-sandbox is explicit about its scope limit: "Agent
Sandbox is a sandbox orchestrator. It delegates low-level container isolation to
secure 'Sandbox Runtimes' (like gVisor or Kata Containers) by managing Pods
configured to use these runtimes (via RuntimeClass)." Its contribution is
lifecycle and identity — stable hostname and network identity, pause and resume,
warm pools via `SandboxWarmPool` for constant-time admission.

OpenSandbox is the closest thing to a wire contract. Its
[1.1.0 release, 2026-09-21](https://github.com/opensandbox-group/OpenSandbox/releases/tag/release-1.1.0),
is the first stable unified umbrella release. It adds a Credential Vault so that
secrets never enter the workload, a per-sandbox egress sidecar, a PostgreSQL
snapshot store with CAS semantics, lifecycle hooks with fail-closed watchdogs, a
runtime-init handshake (`POST /init` + `GET /ready`) that moves identity out of
image build time, and an `agents.x-k8s.io/v1beta1` requirement. Enhancement
proposals include OSEP-0010 (OpenTelemetry), OSEP-0011 (secure-access signing
keys), OSEP-0020 (lifecycle hooks), plus pause/resume, resilient SDK transport,
multi-sandbox egress and TLS interception. Some of these are groundwork only, not
enabled by default — the experimental egress fleet profile and credential-bound
TLS interception are explicitly not on.

**Credential injection has no standard.** Every vendor invented its own: E2B
workload identity tokens (access tokens were disabled 2026-08-01, `E2B_API_KEY`
only), the OpenSandbox Credential Vault, Docker secret placeholders, the
AgentCore Identity token vault, `sbx secret set`.

**MCP-in-sandbox is the new capability.** Both OpenSandbox (`opensandbox-mcp`)
and E2B ship an MCP server inside the sandbox; E2B's exposes 200+ Docker MCP
Catalog servers reachable via `sbx.getMcpUrl()` with a bearer token. [INFERENCE]
The agent thereby holds a tool whose effect is to create further isolated
environments, which is a self-amplifying capability that no gateway policy
engine in the surveyed set has a rule for.

### Runtime

**The harness/environment decomposition.** OpenAI and AWS arrived at the same
split independently and use nearly the same vocabulary. OpenAI's framing: "The
key split is the boundary between the harness and compute." AWS titles its
comparison page ["Harness vs. Runtime"](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/harness-vs-runtime.html).
The harness is the control plane — agent loop, model calls, tool routing,
handoffs, approvals, tracing, recovery, run state. The environment is the
execution plane — files, commands, ports, snapshots, mounts.

The OpenAI [Agents API](https://developers.openai.com/api/docs/guides/agents-api/architecture)
is in beta. It splits into three environment types: `none`, `openai_hosted` (the
platform provisions the sandbox) and `self_hosted`. The self-hosted contract is
the most portable thing in the layer: you run
`codex exec-server --remote <session.environment.remote_url> --environment-id <id>`,
which opens an **outbound** WebSocket to
`wss://codex-cloud-environments.chatgpt.com`, executes shell commands, reads and
writes files, and uses local MCP servers at the harness's request. All
connections are outbound and auto-reconnect. The environment key
(`CODEX_API_KEY`) can only authorize connecting environments. Session event
states are `agent.session.environment.pending`, `.connected` and `.failed`.

The [Sandbox Agents surface in the TypeScript and Python Agents SDK](https://developers.openai.com/api/docs/guides/agents/sandboxes)
(`@openai/agents/sandbox`) is a Manifest, Capabilities (Shell, Filesystem,
Skills, Memory, Compaction; Memory requires Shell, and live updates also
require Filesystem), a `SandboxClient` (UnixLocal, Docker, hosted providers),
`SandboxSession` and `RunState`/snapshots. Mounts cover S3, GCS, R2, Azure Blob,
Box and S3 Files, plus local files, directories and Git repositories. Manifest
paths are workspace-relative and may not escape via `..`; mount entries are
ephemeral and are skipped by snapshot and persistence flows. Nine sandbox
providers are documented for the Agents API: Modal, Cloudflare, Vercel, Daytona,
Blaxel, E2B, Runloop, DigitalOcean and OCI. [INFERENCE] That list is the closest
thing to an answer to "what hosts agent sandboxes in production".

**The AgentCore service contract is the only normative one.** The
[AgentCore Runtime service contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-service-contract.html)
fixes four protocols to fixed ports on an ARM64 container bound to `0.0.0.0`,
with SigV4 or OAuth 2.0 on all four.

| Protocol | Port | Paths |
| --- | --- | --- |
| HTTP | 8080 | `/invocations`, `/ws` |
| MCP | 8000 | `/mcp` |
| A2A | 9000 | `/` |
| AG-UI | 8080 | `/invocations` (SSE), `/ws` |

The [MCP protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html)
requires Streamable HTTP and defaults `stateless_http=True`. The platform
**generates** `Mcp-Session-Id` and always returns it to clients; a server must
accept it rather than reject it, because it is the platform's mechanism for
microVM stickiness. Stateful mode is retained for 2025-11-25-and-earlier
elicitation and sampling, and SEP-2567 is restated as a stateless server keeping
state in an application-managed store keyed by explicit state handles. JSON-RPC
errors map to `-32001`, `-32002`, `-32003`, `-32004`, `-32005`, `-32006`,
`-32010`, `-32011` and `-32603`, mostly over HTTP 200 following MCP's
convention. `RetryableConflictException` returns `-32005` over HTTP 200, and MCP
clients do not auto-retry it.

The [A2A protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-a2a-protocol-contract.html)
is JSON-RPC 2.0 over HTTP with `GET /.well-known/agent-card.json` and `GET /ping`
returning `{"status":"Healthy"|"HealthyBusy"}`. While the status is `HealthyBusy`
the runtime session is kept alive, and AWS warns against setting
`time_of_last_update` to the current time on every ping, because a continuously
advancing timestamp prevents the idle session timeout from firing and sessions
persist to `MaxLifetime`, exhausting the session quota. The error map is
`-32051` through `-32055`.

AWS also publishes a feature grid separating what the harness does from what the
Runtime does — for example, choice of agent framework is a harness "No" and a
Runtime "Custom" — and a managed harness powered by Strands Agents that runs
inside Runtime.

**A2A defines no task-persistence API.** The
[A2A 1.0 specification](https://a2a-protocol.org/latest/specification/) offers
Get Task, List Tasks, Cancel Task and Subscribe To Task. It defines no
client-facing task storage or task-retention API. What it mandates instead:

- Push-notification config "MUST persist until task completion or explicit
  deletion" — the only storage `MUST` in the document.
- Task history is **explicitly not reliable**: "not all Messages are guaranteed
  to be persisted in the Task history; for example, transient informational
  messages may not be stored. Messages exchanged prior to task creation may not
  be stored… clients MUST NOT rely on this behavior unless negotiated
  out-of-band." Streaming clients "MAY not receive all status update messages if
  the client is disconnected and then reconnects."
- List Tasks requires cursor pagination: `pageToken`/`nextPageToken`, with
  `nextPageToken` always present and `""` on the last page, `pageSize` 1–100 and
  a default at or below 50, sorting by last update **descending**, a
  `statusTimestampAfter` filter, `includeArtifacts` defaulting to `false` with
  the field **omitted entirely** (not an empty array, not null), and
  "appropriate authorization scoping to ensure clients can only access authorized
  tasks".
- A new `tenant` field on task-scoped operations: "opaque routing identifier.
  Must match the tenant value from the selected AgentInterface in the Agent Card
  when that field is set."

Task storage is therefore an SDK concern.
[a2a-python](https://github.com/a2aproject/a2a-python) ships database extras
(`a2a-sdk[postgresql|mysql|sqlite]`, `[sql]`) and a v0.3-to-1.0 migration guide,
which implies a pluggable task store. `[UNVERIFIED]` The task store source was
not read, so the in-memory default is not confirmed.

**A2A hosting guidance is entirely vendor-side.** The 1.0 specification has no
deployment or runtime section at all. AWS publishes the only normative A2A
hosting contract. Google publishes an ADK-to-Vertex path; Azure AI Foundry
exposes A2A endpoints without a published contract.

## What changed recently

| Date | Layer | Change |
| --- | --- | --- |
| 2025-11-04 | Gateway | [SEP-1763](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1763) "Interceptors for Model Context Protocol" opened. Later closed without a sponsor. |
| 2026-02-04 | Gateway | [SEP-2243](https://modelcontextprotocol.io/seps/2243-http-standardization) created. Final, Standards Track. |
| 2026-03-25 | Gateway | [CNCF announcement](https://www.cncf.io/announcements/2026/03/25/istio-brings-future-ready-service-mesh-to-the-ai-era-with-new-ambient-multicluster-gateway-api-inference-extension-and-more/): Istio adds **experimental** agentgateway support as a data plane component. |
| 2026-04-09 | Gateway | AAIF project proposal [#11](https://github.com/aaif/project-proposals/issues/11) for agentgateway opened. |
| 2026-04-17 | Gateway | [Microsoft AKS](https://blog.aks.azure.com/2026/04/17/appnet-agentgateway) announces Azure Kubernetes AppNet (Public Preview) with agentgateway for per-application token rate limiting keyed on mTLS identity. |
| 2026-04-24 | Gateway | AAIF project proposal [#18](https://github.com/aaif/project-proposals/issues/18) for Agent Router opened. |
| 2026-05-12 | Gateway, Sandbox | [Docker AI Governance](https://www.docker.com/blog/docker-ai-governance-unlock-agent-autonomy-safely/) announced. The MCP Gateway moves behind a sales contact as an invite-only feature. |
| 2026-06-04 | Gateway | agentgateway accepted as the [fourth AAIF project](https://aaif.io/blog/agentgateway-joins-aaif-as-an-open-gateway-for-agentic-ai-infrastructure). Agent Router v0.7.0 released. |
| 2026-06-23 | Gateway | Agent Router v1.0.0 GA with a committed-stable v1beta1 control-plane API. |
| 2026-07-06 / 2026-07-12 | Gateway | `draft-agent-gw-02` issued and last updated. Architecture only. |
| 2026-07-21 | Gateway | agentgateway publishes ["MCP goes stateless — do you still need an MCP-native data plane?"](https://agentgateway.dev/blog/), conceding the threat its own maintainers named. |
| 2026-07-27 | Gateway | agentgateway v1.4.0: full MCP 2026-07-28 support, Cross App Access / ID-JAG, and the fix for GHSA-mvgg-jvj2-4frq. |
| 2026-07-28 | Gateway, Runtime | [MCP 2026-07-28](https://blog.modelcontextprotocol.io/posts/2026-07-28) ships. Stateless core (SEP-2575, SEP-2567), mandatory `Mcp-Method`/`Mcp-Name` (SEP-2243), MRTR (SEP-2322), cache hints (SEP-2549), Tasks promoted to an extension (SEP-2663), DCR deprecated for CIMD, 12-month minimum deprecation window. |
| 2026-08-21 | Gateway | Agent Router v1.1.0, first minor on the stable 1.x API. |
| 2026-08-22 | Gateway | [MCP roadmap](https://modelcontextprotocol.io/development/roadmap) last updated. Five priority areas: Agentic Messaging, HTTP-Native Transport, Agent Identity/Enterprise Security, Improved Primitives, SDK DX. None is a gateway. |
| 2026-08-27 | Gateway | agentgateway v1.5.0. Breaking token-usage semantics; guardrails on tool inputs and outputs; `iss` and `aud` mandatory when configured. |
| 2026-09-09 / 2026-09-10 | Gateway | Envoy AI Gateway renamed Agent Router; [joins AAIF](https://theagentrouter.ai/blog/envoy-ai-gateway-is-now-agent-router). CRDs, images and module path unchanged. |
| 2026-09-15 | Gateway | [A2A roadmap](https://a2a-protocol.org/latest/roadmap/) last updated. No gateway item. |
| 2026-09-21 | Sandbox | [OpenSandbox 1.1.0](https://github.com/opensandbox-group/OpenSandbox/releases/tag/release-1.1.0), the first stable unified release. Adds Credential Vault, egress sidecar, PostgreSQL snapshot store with CAS, and an `agents.x-k8s.io/v1beta1` requirement. |
| 2026-09-22 | Gateway | agentgateway v1.6.0-alpha.2, pre-release. |
| 2026-09-23 | Gateway | [docker/mcp-gateway v0.44.1](https://github.com/docker/mcp-gateway/releases/tag/v0.44.1), labeled Pre-release on GitHub. |
| 2026-09-27 / 2026-09-28 | Gateway | ToolHive v0.51.4 (2026-09-27); IBM ContextForge v1.0.11 (2026-09-28) migrates to `mcp>=2.0.0` but leaves `MCP_CLIENT_CONNECT_MODE` and `MCP_INBOUND_PROTOCOL_MODE` defaulting to `legacy`, with `GATEWAY_MODERN_LISTENERS_ENABLED` false — the 2026-07-28 revision is opt-in. |

## Evidence of adoption

### Gateway

| Project | Verdict | Evidence |
| --- | --- | --- |
| [agentgateway](https://github.com/agentgateway/agentgateway) | Real adoption, foundation-governed. 5.1k stars, 5M+ image pulls, 200+ contributors across 60+ organizations (CoreWeave, Red Hat, Adobe, Salesforce, Microsoft, Amdocs, Apple, Alibaba, AWS, Huawei, Cisco). Experimental Istio data plane component. Named adopters Adobe, Apple, T-Mobile, Expedia, Swissquote, Zalando, DNB. | AAIF proposal [#11](https://github.com/aaif/project-proposals/issues/11) (2026-04-09); [AAIF blog](https://aaif.io/blog/agentgateway-joins-aaif-as-an-open-gateway-for-agentic-ai-infrastructure) (2026-06-04); [CNCF](https://www.cncf.io/announcements/2026/03/25/istio-brings-future-ready-service-mesh-to-the-ai-era-with-new-ambient-multicluster-gateway-api-inference-extension-and-more/) (2026-03-25) |
| [Agent Router](https://github.com/theagentrouter/agent-router) | Real production use, three-week-old foundation home. AAIF project page states "used in production by Bloomberg, Tencent Cloud, and Nutanix"; proposal adds LY Corporation, nrp.ai, Simplifai. Tetrate ships a commercial TARS. 2.2k stars. `AWS has embraced it as the preferred AI gateway system for EKS` is `[UNVERIFIED]` — asserted in proposal #18 with no AWS URL given. | [AAIF project page](https://aaif.io/projects/agent-router); proposal [#18](https://github.com/aaif/project-proposals/issues/18); [release notes](https://theagentrouter.ai/release-notes/) |
| [docker/mcp-gateway](https://github.com/docker/mcp-gateway) | **Split verdict.** The open-source binary is real: 1.6k stars, 1,056 commits, ships with Docker Desktop, `docker mcp` CLI plugin, profiles exportable to OCI registries, consumes `registry.modelcontextprotocol.io` refs. The **enterprise product is an announcement**: Docker's own docs say "MCP Gateway as part of Docker AI Governance is an invite-only feature. Contact Docker Sales." No public GA, no pricing, no independent confirmation of enterprise deployment. | [repo](https://github.com/docker/mcp-gateway); [Docker docs](https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/) |
| [IBM ContextForge](https://github.com/IBM/mcp-context-forge) | Real, substantial, vendor-owned, pre-standard. 4.5k stars, 3,233 commits, Apache-2.0, PyPI and GHCR. Uniquely federates MCP + A2A + REST/gRPC with 40+ plugins. Not donated to a foundation. **No named external production customer disclosed.** | repo README |
| [ToolHive](https://github.com/stacklok/toolhive) | Real and mature; foundation status is aspirational. 2.2k stars, 4,433 commits, Apache-2.0. Gateway + Registry Server + Runtime + Studio, K8s operator, semantic tool search. Stacklok states an **intent to donate**; no donation has occurred. | repo; v0.51.4 (2026-09-27) |
| [Lasso mcp-gateway](https://github.com/lasso-security/mcp-gateway) | Effectively dormant. 391 stars, **40 commits total**, 4 releases (v0.1.2 through v1.2.0), Python. Treat as a historical artifact of the 2025 security-gateway wave. | repo commit and release counts |
| [MCPJungle](https://github.com/mcpjungle/MCPJungle) | Real but small and pre-1.0. 1.3k stars, 275 commits, v0.4.6 (2026-08-02), Go. Self-hosted registry plus gateway for the developer and small-team case. Its [roadmap](https://docs.mcpjungle.com/roadmap) lists OAuth as beta, and GitOps/IaC and fine-grained ACLs as not yet built. | repo; [roadmap](https://docs.mcpjungle.com/roadmap) |
| [AWS AgentCore Gateway](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway.html) | Managed AI gateway converting OpenAPI, Smithy and Lambda into MCP tools, with A2A passthrough, model routing and ingress plus egress auth. It is a product behind a service contract, not a published gateway specification. | AgentCore developer guide |

Correction: **MCPJungle is not Lasso's.** No primary source supports an
acquisition or ownership link. MCPJungle lives under the `mcpjungle` GitHub
organization; Lasso ships a separate product. Search results repeatedly
conflate the two, and ToolHive is Stacklok's, not Docker's.

### Sandbox

| Project | Verdict | Evidence |
| --- | --- | --- |
| [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) | Strongest institutional claim: a Kubernetes SIG project, 4.1k stars, 1,051 commits, Apache-2.0, v1beta1 CRD. | repo; SIG Apps |
| [OpenSandbox](https://github.com/opensandbox-group/OpenSandbox) | Largest by stars (15.6k), OpenSSF Best Practices badge, in the CNCF landscape, Alibaba-originated. Vendor-owned, one stable version old. | repo; 1.1.0 release (2026-09-21) |
| [E2B](https://docs.e2b.dev/changelog) | Firecracker microVMs, ~150 ms boot, fork and memory-preserving pause/resume. Weekly changelog current at 2026-09-28. Recent: V2 endpoints (2026-09-21), E2B Embed self-hosting (2026-09-14), access tokens disabled (2026-08-01), BYO SOCKS5 egress applied on the host after allow/deny lists (2026-08-24), Cursor self-hosted machines on E2B (2026-09-07). | changelog |
| [Daytona](https://www.daytona.io/docs/en/sandboxes/) | Five sandbox classes, container default under 90 ms, Linux/Windows VM, macOS, GPU. Two regions. | docs |
| [Modal](https://modal.com/docs/guide/sandboxes) | `modal.Sandbox.create` with lifecycle events, readiness probes, tunnels and snapshots. 5-minute default lifetime, 24-hour maximum. One of OpenAI's nine documented Agents API providers. | docs |
| [microsandbox](https://github.com/superradcompany/microsandbox) | libkrun microVMs, no daemon, Rust/Python/TS/Go SDKs, under 100 ms boot, disk and full-memory snapshots, branching. Local-first and embeddable — an explicit anti-hosted posture. | repo |
| [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) | `sbx` CLI, local microVM plus Docker-managed cloud. Local CLI and compute are free including commercial use; cloud is pay-as-you-go; the API and SDK are explicitly experimental. No public release page found. `sbx` version: NOT ESTABLISHED IN SOURCE. | docs |

Cloudflare has no separate agent sandbox product. Code Mode execution rides
Dynamic Worker Loader isolates — V8, no filesystem, external fetches disabled by
default. That is a constraint on one feature, not a general sandbox.

### Runtime

| Vendor | Adoption signal |
| --- | --- |
| AWS AgentCore | The only vendor publishing a normative hosting contract. Google Cloud, Microsoft Azure AI Foundry and AWS Bedrock AgentCore are named as platform-level A2A hosts in the [A2A-to-AAIF announcement, 2026-08-17](https://aaif.io/blog/a2a-joins-aaif). |
| Huawei Celia | Endorsed production deployment: HarmonyOS OS-level assistant handing long-running tasks to in-app agents, with UI control. Per AAIF, August 2026. |
| Tencent WeChat | Among the first major applications integrating with Huawei and other Android OEM assistants over A2A, with dual authorization. Per AAIF, August 2026. |
| MCP server hosting | [Netlify](https://vercel.com/docs/mcp/deploy-mcp-servers-to-vercel) (official remote MCP server), [Vercel](https://mcp.vercel.com), [Render](https://mcp.render.com/mcp) (GA per changelog), and Cloudflare at `mcp.cloudflare.com/mcp`. Cloudflare names Sentry, Linear and Figma as SDK adopters, and the 2026-07-28 release testimonials include Microsoft Foundry, Google Cloud and AWS. |
| Sandbox providers | Nine documented for the OpenAI Agents API: Modal, Cloudflare, Vercel, Daytona, Blaxel, E2B, Runloop, DigitalOcean, OCI. |

## Sharp edges

### Gateway

- **Two AAIF gateways, no interop story.** No shared spec, no shared config
  schema, no shared policy language, no conformance suite, no migration path.
  agentgateway uses CEL, ContextForge uses RBAC plus plugins, Docker uses
  profiles plus organization policy groups, Microsoft's uses Entra app roles.
  A buyer picks one seat with no exit.
- **Most gateway projects are written against pre-2026-07-28 MCP.**
  agentgateway's own documentation still describes MCP as "a stateful protocol…
  long-lived sessions" and "Traditional gateways were not designed and built to
  support the session and message awareness that is required". The 2026-07-28
  specification invalidated that premise. [INFERENCE] A re-architecture wave
  follows. The MCP-specific downside is already visible: agentgateway
  [documents](https://agentgateway.dev/docs/standalone/latest/documentation/mcp/spec-compatibility.md)
  that statelessness disables response caching.
- **CVE-2026-58197 / GHSA-qg2g-g9w3-m5h8** (ToolHive, High, CVSS 8.8;
  advisory published 2026-07-28, CVE published 2026-09-18; fixed in CLI ≥ 0.30.1
  and Studio ≥ 0.38.0). Stated root causes: `insecure_allow_all:true` as the
  default, no authentication on the ToolHive API or MCP proxies, and
  `host.docker.internal` resolving to the host. A containerized MCP server
  reaches the ToolHive control plane, other servers' proxies, the Kubernetes API
  on `:6443` and Ollama on `:11434` — "full host compromise without any container
  escape vulnerability". The reporter's framing is the sharpest available
  statement of the layer's problem: an unauthenticated local proxy endpoint
  *inside* the isolation boundary is a bigger hole than the boundary.
- **The ToolHive advisory cluster is the pattern to watch** — ten GHSA
  advisories in roughly three weeks, including one Critical on 2026-09-08:
  sessions not bound to authenticated principals; a legacy HTTP+SSE proxy
  broadcasting JSON-RPC across authenticated sessions; ambiguous JSON members
  bypassing authorization and argument policies; `completion/complete` bypassing
  prompt and resource authorization; any POST to a path ending in `/sse` bypassing
  the authorization middleware; permission profiles mutated in place leaking one
  workload's host volume mounts; API-created workloads running unauthenticated
  because the authorization middleware received a literal nil.
- **GHSA-mvgg-jvj2-4frq** (agentgateway, High, 8.1): stateful MCP sessions could
  cross routes and overwrite the authorization policy. Fixed in v1.4.0
  (2026-07-27). [INFERENCE] Any gateway's maturity should be judged on advisory
  count, not feature list.
- **CEL `request.body` truncation in authorization policies.** agentgateway
  documents this as a security recommendation rather than a bug:
  `request.truncatedBody` is capped at `http.maxBufferSize` (2 MB default), so a
  `contains("attacker-payload")` policy fails **open** on large or compressed
  bodies. [INFERENCE] This class of defect is endemic to body-inspecting gateways
  and is under-discussed industry-wide.
- **Silent breaking changes in usage accounting.** agentgateway v1.5.0
  (2026-08-27) changed LLM token counts to include prompt-cache tokens, altering
  every token-based rate limit, dashboard and CEL expression that used
  `llm.inputTokens`. The escape hatch is
  `AGENTGATEWAY_LEGACY_LLM_USAGE_TOKEN_SEMANTICS=true`, with removal planned after
  1.5. Agent Router v1.1.0 (2026-08-21) restricted the Helm controller security
  context to non-root UID 65532 with no privilege escalation, which breaks custom
  controller images silently.
- **The registry does not cover private servers.** The official MCP Registry
  "does not support private servers", its codebase "is not designed for
  self-hosting", and security scanning is delegated to package registries and
  downstream aggregators. It is a downstream-aggregator-only API that host
  applications are not meant to consume directly, still carrying a preview
  banner on the research date, launched 2025-09-08 with the API frozen in late
  October 2025.

### Sandbox

- **Lateral movement from a containerized MCP server is unsolved at the ecosystem
  level.** MicroVM isolation for the *agent* does not protect the *gateway* the
  MCP server talks to. CVE-2026-58197 is the demonstration.
- **"Sandbox" is not a comparable claim.** Docker runs MCP servers in plain
  containers; gVisor cannot be snapshotted; Modal caps lifetime at 24 hours;
  Cloudflare's isolate is a V8 sandbox for code Mode only. Two products making
  the same claim can sit two tiers apart.
- **Docker Sandboxes routes around its own isolation.** Local stdio MCP servers
  run on the host, outside sandbox isolation; the docs carry a warning that such
  servers "can access host files, host network resources, and credentials", and
  a container started via `--command docker` "uses host Docker isolation, not
  sandbox isolation". The same CLI that promises isolation offers an escape
  from it.
- **SSRF and DNS rebinding on manifest fetch** are documented hazards with a
  `--skip-ssrf-check` escape hatch. "Fetching a manifest from an untrusted URL
  can expose internal services or cloud metadata, and DNS rebinding can redirect
  a hostname after it has been checked."
- **Docker's own dynamic-tool surface is unvalidated.** Docker's documentation
  says of `code-mode`, the agent-composable-tool feature, "Code mode is in early
  development and is not yet reliable for general use. The documentation
  intentionally omits usage examples at this time." Dynamically added servers
  are session-scoped and never persisted, but the security model is identical to
  static configuration while the trust surface is not.
- **No standard for credential injection into sandboxes.** E2B workload
  identity, the OpenSandbox Credential Vault, Docker secret placeholders, the
  AgentCore Identity token vault and `sbx secret set` are five unrelated
  mechanisms. `NOT ESTABLISHED IN SOURCE` — no interop artifact between them.
- **Warm pools are the latency mechanism and only two projects model them as a
  first-class API surface**: agent-sandbox's `SandboxWarmPool` and OpenSandbox's
  sandbox pools.

### Runtime

- **The AgentCore A2A card example still declares `"protocolVersion": "0.3.0"`.**
  A live vendor contract document, published against a 1.0-era service contract,
  pinned two protocol majors behind and behind A2A 1.0 itself.
- **AgentCore diverges from A2A on error delivery.** The A2A specification
  delivers JSON-RPC errors over HTTP 200; AgentCore "returns the real HTTP status
  code (for example, 409 or 404)" and instructs clients to parse the body
  anyway. Documented, and a live interop hazard.
- **OpenAI's `self_hosted` executor is less portable than its framing.** It is
  the only runtime contract with a non-AWS, non-OpenAI-client story, and it
  still requires the OpenAI API key and a codex-family executor. The environment
  key cannot authorize any other API action, but the dependency remains.
- **Harness-inside-sandbox collapses the boundary the split exists to create.**
  OpenAI's own documentation warns that running the harness inside the sandbox
  "puts orchestration and model-directed execution in the same compute
  boundary". AWS runs its Strands-powered harness inside Runtime, which is the
  same arrangement.
- **A2A 1.0 already needed 1.0.1 to settle a content-type preference** —
  released 2026-05-26 with "spec: prefer application/a2a+json in HTTP binding".
  A new major required a patch release to choose between two media types.
- **Task history is advisory, not durable.** Long-running-task claims in the
  wild are ahead of what the specification's storage guarantees support. Push
  notifications are server-to-client and require the client to be reachable.
- **Signed agent cards are a 1.0 addition with no trust story yet.** No
  published trust root or verification tooling was found; the capability is
  described in a single line of the AAIF announcement. `[UNVERIFIED]`
- **No convergence mechanism between MCP and A2A.** A cross-vendor gateway
  (agentgateway, ContextForge) is the only place both are spoken, and neither
  protocol's specification acknowledges the other as normative there.

## Sources

Gateway

- https://aaif.io/projects
- https://aaif.io/projects/agent-router
- https://aaif.io/blog/agentgateway-joins-aaif-as-an-open-gateway-for-agentic-ai-infrastructure
- https://github.com/aaif/project-proposals/issues/11
- https://github.com/aaif/project-proposals/issues/18
- https://agentgateway.dev/docs/standalone/latest/documentation/about/introduction/
- https://agentgateway.dev/docs/standalone/latest/documentation/mcp/spec-compatibility.md
- https://agentgateway.dev/docs/standalone/latest/documentation/agent/a2a.md
- https://agentgateway.dev/blog/
- https://github.com/agentgateway/agentgateway/releases/tag/v1.4.0
- https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0
- https://github.com/agentgateway/agentgateway/blob/main/CHARTER.md
- https://www.cncf.io/announcements/2026/03/25/istio-brings-future-ready-service-mesh-to-the-ai-era-with-new-ambient-multicluster-gateway-api-inference-extension-and-more/
- https://blog.aks.azure.com/2026/04/17/appnet-agentgateway
- https://theagentrouter.ai/release-notes/
- https://theagentrouter.ai/blog/envoy-ai-gateway-is-now-agent-router
- https://github.com/theagentrouter/agent-router/releases/tag/v1.1.0
- https://blog.modelcontextprotocol.io/posts/2026-07-28/
- https://modelcontextprotocol.io/seps/2243-http-standardization
- https://modelcontextprotocol.io/development/roadmap
- https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1763
- https://datatracker.ietf.org/doc/draft-agent-gw/
- https://modelcontextprotocol.io/registry/about
- https://blog.modelcontextprotocol.io/posts/2025-09-08-mcp-registry-preview/
- https://github.com/docker/mcp-gateway
- https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/
- https://github.com/IBM/mcp-context-forge
- https://github.com/stacklok/toolhive
- https://github.com/lasso-security/mcp-gateway
- https://github.com/mcpjungle/MCPJungle
- https://docs.mcpjungle.com/roadmap
- https://github.com/a2aproject/a2a-gateway
- https://a2a-protocol.org/latest/roadmap/
- https://www.a2a-registry.org/

Sandbox

- https://github.com/kubernetes-sigs/agent-sandbox
- https://agent-sandbox.sigs.k8s.io/
- https://github.com/opensandbox-group/OpenSandbox
- https://github.com/opensandbox-group/OpenSandbox/releases/tag/release-1.1.0
- https://docs.e2b.dev/changelog
- https://docs.e2b.dev/mcp-gateway
- https://www.daytona.io/docs/en/sandboxes/
- https://modal.com/docs/guide/sandboxes
- https://github.com/superradcompany/microsandbox
- https://docs.docker.com/ai/sandboxes/
- https://docs.docker.com/ai/sandboxes/mcp-gateway/
- https://docs.docker.com/ai/sandboxes-api/
- https://blog.cloudflare.com/code-mode-mcp/

Runtime

- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/
- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-service-contract.html
- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html
- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-a2a-protocol-contract.html
- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/harness-vs-runtime.html
- https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway.html
- https://developers.openai.com/api/docs/guides/agents-api/architecture
- https://developers.openai.com/api/docs/guides/agents-api/environments/self-hosted
- https://developers.openai.com/api/docs/guides/agents/sandboxes
- https://a2a-protocol.org/latest/specification/
- https://github.com/a2aproject/A2A/releases/tag/v1.0.1
- https://github.com/a2aproject/a2a-python
- https://aaif.io/blog/a2a-joins-aaif
- https://modelcontextprotocol.io/extensions/tasks/overview
