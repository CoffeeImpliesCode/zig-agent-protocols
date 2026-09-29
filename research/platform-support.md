# Platform support

Which vendors ship which agent wire protocol, at which version, in which maturity
state, and where in their own documentation each claim is made. This document
covers MCP, A2A, AG-UI and ACP support across nine model and hosting vendors
plus the hosting platforms. It does not cover protocol wire layouts, threat
models, or CVEs; those live in [`mcp.md`](mcp.md), [`a2a.md`](a2a.md),
[`security.md`](security.md) and [`governance.md`](governance.md).

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

### The headline: the MCP 2026-07-28 adoption gap

MCP's current protocol version is `2026-07-28`
([versioning](https://modelcontextprotocol.io/docs/2026-07-28/learn/versioning.md)).
That revision removes protocol sessions: the `initialize`/`notifications/initialized`
handshake, `Mcp-Session-Id`, SSE resumability via `Last-Event-ID`, and
server-initiated `sampling/createMessage`, `elicitation/create` and `roots/list`
are all gone, replaced by the mandatory `server/discover` RPC and the Multi
Round-Trip Requests pattern, with `subscriptions/listen` replacing GET plus
`resources/subscribe`
([2026-07-28 changelog](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2026-07-28/changelog.mdx),
[basic index](https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md)).
No client in this survey is documented as implementing it.

Three pieces of evidence carry the gap.

| Evidence | What the document says | Date | URL |
| --- | --- | --- | --- |
| **Netlify** | Its own MCP server runs `2026-07-28` from day one, on the stated grounds that statelessness removes sticky-session infrastructure. Client support as of the post: **Claude.ai and Claude Managed Agents today; Claude Code "coming soon."** Endpoint `https://netlify-mcp.netlify.app/mcp`, install `npx -y add-mcp`. | `last_updated` 2026-09-29 | [netlify.com/blog/mcp-goes-stateless-and-extensible](https://www.netlify.com/blog/mcp-goes-stateless-and-extensible/) |
| **Claude** | The Claude Code MCP reference still documents four transports — `http` (with `streamable-http` as an accepted alias), `sse` explicitly deprecated with automatic fallback from HTTP as of v2.1.265, `ws`, and `stdio` — and still describes `roots/list` returning the launch directory plus `--add-dir` grants. `roots` is deprecated, not removed, in `2026-07-28`, earliest removal on or after 2027-07-28. No Anthropic document states a supported protocol revision. | not dated on the page | [code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp), [deprecated registry](https://modelcontextprotocol.io/specification/2026-07-28/deprecated.md) |
| **Zed** | Zed Industries co-governs ACP with JetBrains and is the editor-side counterparty to the same agent-protocol shift. ACP v2 was published as Draft on 2026-07-20, eight days before MCP `2026-07-28`. No Zed document in this survey states which MCP revision its MCP client targets. | ACP v2 Draft 2026-07-20 | [agentclientprotocol.com/updates](https://agentclientprotocol.com/updates) |

The Zed evidence is an absence. Nothing in the survey establishes that Zed
supports, or does not support, `2026-07-28`. It is recorded because Zed owns
the protocol that competes with MCP for the client slot, and because its own
protocol moved its version line in the same week.

Three further datapoints belong with the gap:

- **AWS mandates a header the revision deleted.** AgentCore Runtime requires
  Streamable HTTP and `stateless_http=True` by default, but the platform
  generates `Mcp-Session-Id` and the server **must accept it** for microVM
  routing, while the same page already documents the `2026-07-28` MRTR pattern
  ([MCP protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html)).
- **Only the serverless platforms committed.** The survey found two platforms
  publicly committing to `2026-07-28`: Netlify, and Cloudflare by making the
  stateless handler the non-deprecated path — its Agents SDK `createMcpHandler`
  is stateless while the older class-based `McpAgent` is documented as
  deprecated
  ([Cloudflare MCP authorization](https://developers.cloudflare.com/agents/model-context-protocol/protocol/authorization/index.md)).
  Vercel, which shipped MCP hosting in 2025-05-07, publishes no `2026-07-28` claim
  ([Vercel changelog](https://vercel.com/changelog/mcp-server-support-on-vercel)).
  [INFERENCE] The pattern is that a stateless redesign unblocks exactly the
  request-driven platforms whose sticky-session infrastructure it removes.
- **Vendor documentation lags the revision in three separate places.** Cursor
  still lists Roots as a supported feature ([cursor.com/docs/mcp](https://cursor.com/docs/mcp));
  the Microsoft Copilot Studio A2A page still points at the pre-1.0
  `/.well-known/agent.json` path
  ([Copilot Studio A2A](https://learn.microsoft.com/en-us/microsoft-copilot-studio/add-agent-agent-to-agent));
  and the Cloudflare authorization page still links to spec revision `2025-06-18`.

### Protocol state, 2026-09-29

| Protocol | Current version | Dated | Governance | License | Maturity |
| --- | --- | --- | --- | --- | --- |
| MCP | `2026-07-28` current; prior `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`; `draft` also served | 2026-07-28 | Linux Foundation, under the **Agentic AI Foundation (AAIF)** formed 2025-12-09; contributed by Anthropic; AAIF founding members Anthropic, Block, OpenAI | not verified in this pass | Production in the core; extensions newer than the core |
| A2A | spec `1.0.0`; GitHub release `v1.0.1` | 2026-03-12 (v1.0 announcement); 2026-05-28 (v1.0.1) | Linux Foundation; TSC representatives from AWS, Cisco, Google, IBM Research, Microsoft, Salesforce, SAP, ServiceNow | Apache-2.0 per the repository description; not read from the LICENSE file | Production-ready "1.0"; v1.1 and bidirectional streaming on the [roadmap](https://a2a-protocol.org/latest/roadmap/), updated 2026-09-15 |
| ACP (Agent Client Protocol) | v1 stable; **v2 in Draft** | v2 Draft 2026-07-20 | Zed Industries and JetBrains jointly; Sergey Ignatov (JetBrains) lead maintainer since 2026-02-18; repository moved from `zed-industries/` to `agentclientprotocol/` | not verified in this survey | v1 stabilising feature by feature via RFDs; Rust and TypeScript SDKs 1.0.0 on 2026-06-25; Registry released 2026-03-09; Transports WG formed 2026-04-22 |
| AG-UI | spec revision `2026-01-26`, referenced by the MCP Apps extension; no independent version line found | 2026-01-26 | independent, ag-ui.com | not verified in this survey | Widest hosting support of any protocol in this set, with one first-party cloud implementation |

**Naming collision.** An unrelated project, `agent-control-protocol/acp`
(WebSocket UI automation, "Version 2.0, Draft, 2026-03-28"), also calls itself
ACP. Any selection step that resolves "ACP" by name rather than by repository is
exposed to it.

### Support matrix

Every row is from the vendor's own documentation. `NOT ESTABLISHED IN SOURCE`
means the page states support but names no protocol revision, which is the common
case: most vendors do not publish a revision pin.

| Vendor | Protocol | Revision | Maturity as documented | Source |
| --- | --- | --- | --- | --- |
| **AWS — Bedrock AgentCore Runtime** | MCP | docs reference `2026-07-28`; also mandates `Mcp-Session-Id` | GA per the dev guide | [runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agents-tools-runtime.html), [MCP contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html) |
| AWS — AgentCore Runtime | A2A | A2A 1.0 lineage; announced 2025-11-11, modified 2026-07-10 | GA; stateless HTTP on port 9000 | [A2A announcement](https://aws.amazon.com/blogs/machine-learning/introducing-agent-to-agent-protocol-support-in-amazon-bedrock-agentcore-runtime/) |
| AWS — AgentCore Runtime | AG-UI | NOT ESTABLISHED IN SOURCE | announced 2026-03-13; SSE or WebSocket, port 8080 | [AG-UI contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-agui-protocol-contract.html) |
| AWS — AgentCore Gateway | MCP (managed endpoint) | NOT ESTABLISHED IN SOURCE | GA; `https://{id}.gateway.bedrock-agentcore.{region}.amazonaws.com/mcp`, authorizers `NONE` and `CUSTOM_JWT` | [gateway quick start](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-quick-start.html) |
| **Microsoft — Foundry Agent Service** | A2A | `a2a` tool targets **A2A 1.0**; `a2a_preview` targets 0.3 | `a2a` **GA**; `a2a_preview` preview; text modality only, no streaming | [agent-to-agent](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/agent-to-agent) (2026-09-11) |
| Microsoft — Foundry Agent Service | MCP | NOT ESTABLISHED IN SOURCE | `MCPTool` GA; **MCP tasks preview** | [model-context-protocol](https://raw.githubusercontent.com/MicrosoftDocs/azure-ai-docs/main/articles/foundry/agents/how-to/tools/model-context-protocol.md) (2026-08-26) |
| Microsoft — Copilot Studio | A2A | NOT ESTABLISHED IN SOURCE | documented 2026-08-26 over custom connector infrastructure | [add-agent-agent-to-agent](https://learn.microsoft.com/en-us/microsoft-copilot-studio/add-agent-agent-to-agent) |
| **Google — ADK** | A2A | A2A 1.0 lineage | **Python, Go, Java marked Supported**; TypeScript/JS carries an Experimental badge | [adk.dev/a2a](https://adk.dev/a2a/) |
| Google — ADK | MCP | NOT ESTABLISHED IN SOURCE | built-in MCP tools, agent-as-MCP-server, MCP client | [adk.dev/mcp](https://adk.dev/mcp) |
| Google — Agent Engine (Gemini Enterprise Agent Platform) | A2A | A2A 1.0 lineage | **Pre-GA Offerings Terms**, limited support, no SLA | [agent-engine/develop/a2a](https://docs.cloud.google.com/agent-builder/agent-engine/develop/a2a) |
| **OpenAI** | MCP | NOT ESTABLISHED IN SOURCE | page marked "last verified 2026-09-15"; remote MCP for plugins and Apps, Codex plugins, Responses API | [developers.openai.com/api/docs/mcp](https://developers.openai.com/api/docs/mcp) |
| OpenAI — Agents SDK | MCP | MCP Python SDK v1 and v2 | MCP client at agent level and shared, plus a hosted MCP server | [openai-agents-python/mcp](https://openai.github.io/openai-agents-python/mcp) |
| OpenAI — Apps SDK | migrating to MCP Apps `2026-01-26` | migration in progress; three features "Not yet implemented" | [migrate-openai-app](https://apps.extensions.modelcontextprotocol.io/api/documents/migrate-openai-app.html) |
| **Anthropic — Claude Code** | MCP | NOT ESTABLISHED IN SOURCE; documented surface is pre-`2026-07-28` | four transports; `sse` deprecated with automatic HTTP fallback as of v2.1.265 | [code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp) |
| Anthropic — Claude API MCP connector | MCP | NOT ESTABLISHED IN SOURCE | **beta**, header `mcp-client-2025-11-20` | [mcp-connector](https://platform.claude.com/docs/en/agents-and-tools/mcp-connector) |
| Anthropic — Managed Agents MCP connector | MCP | NOT ESTABLISHED IN SOURCE | **beta**, header `managed-agents-2026-04-01`; 20-server cap per agent | [managed-agents/mcp-connector](https://platform.claude.com/docs/en/managed-agents/mcp-connector) |
| **GitHub Copilot** | MCP | NOT ESTABLISHED IN SOURCE | VS Code agent mode since 2025-04; JetBrains, Eclipse, Xcode public preview 2025-05-19; **code review agent skills + MCP GA 2026-07-29** | [mcp-and-coding-agent](https://docs.github.com/en/copilot/concepts/agents/coding-agent/mcp-and-coding-agent), [changelog 2026-07-29](https://github.blog/changelog/2026-07-29-copilot-code-review-agent-skills-and-mcp-now-generally-available/) |
| **JetBrains — AI Assistant 2026.2** | ACP | ACP v1 | shipped in 2026.2, build 2026-09-14; usable without an AI subscription; WSL unsupported | [jetbrains.com/help/ai-assistant/acp](https://www.jetbrains.com/help/ai-assistant/acp.html) |
| JetBrains — AI Assistant | MCP | NOT ESTABLISHED IN SOURCE | ships Copilot MCP and an integrated IntelliJ MCP server; **MCP passthrough to ACP agents** | same page |
| **Cursor** | MCP | NOT ESTABLISHED IN SOURCE | Tools, Prompts, Resources, Roots, Elicitation, and the Apps extension; tool approval on by default | [cursor.com/docs/mcp](https://cursor.com/docs/mcp) |
| **Cloudflare** | MCP | `createMcpHandler` is the stateless path aligned to `2026-07-28`; `McpAgent` documented as deprecated | first-party remote MCP hosting since 2025-04-28 | [MCP authorization](https://developers.cloudflare.com/agents/model-context-protocol/protocol/authorization/index.md), [blog 2025-04-28](https://blog.cloudflare.com/remote-model-context-protocol-servers-mcp) |
| **Netlify** | MCP | **`2026-07-28`**, from day one | blog `last_updated` 2026-09-29 | [netlify.com/blog/mcp-goes-stateless-and-extensible](https://www.netlify.com/blog/mcp-goes-stateless-and-extensible/) |
| **Vercel** | MCP | NOT ESTABLISHED IN SOURCE | MCP hosting since 2025-05-07; `@vercel/mcp-adapter` renamed `mcp-handler`; SSE plus stateless HTTP; Vercel's own server at `mcp.vercel.com` is Beta on all plans, **[UNVERIFIED]** | [vercel.com/changelog/mcp-server-support-on-vercel](https://vercel.com/changelog/mcp-server-support-on-vercel) |
| **Render** | MCP | NOT ESTABLISHED IN SOURCE | first-party server at `https://mcp.render.com/mcp`; OAuth and static API-key setups for Claude Code, Claude Desktop, Codex and Cursor | [render.com/docs/mcp-server](https://render.com/docs/mcp-server), [render-oss/render-mcp-server](https://github.com/render-oss/render-mcp-server) |
| **Docker** | MCP | NOT ESTABLISHED IN SOURCE | MCP Catalog (curated and team catalogs, `docker mcp catalog`) and MCP Gateway (servers in isolated containers, profiles, `docker mcp` CLI); the governed productization under Docker AI Governance is **invite-only** | [gateway](https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/), [catalog](https://docs.docker.com/ai/mcp-catalog-and-toolkit/catalog), [docker/mcp-registry](https://github.com/docker/mcp-registry) |

### Verified in documentation versus absence of evidence

This distinction is load-bearing. Most rows in the matrix above are
*positive vendor claims*. The rows below are not.

| Claim | Status | What the survey found |
| --- | --- | --- |
| OpenAI supports A2A | **absence of evidence** | No OpenAI document claims A2A support. OpenAI's own agent guidance describes multi-agent work as handoffs and agents-as-tools, reaching cross-framework A2A through out-of-band SDKs. Reported as absence of evidence, not evidence of absence. |
| Anthropic supports A2A | **absence of evidence** | No A2A surface found in Anthropic documentation. |
| GitHub supports A2A | **absence of evidence** | No GitHub documentation found. A web search surfaced a third-party repository, `shashikanth-gs/a2a-copilot`, wrapping Copilot as an A2A server; that is not a vendor claim. |
| Cursor supports A2A | **absence of evidence** | No A2A surface found. |
| Zed targets MCP `2026-07-28` | **NOT ESTABLISHED IN SOURCE** | No Zed document in the survey names an MCP revision. |
| Vercel specifics for `mcp.vercel.com` | **[UNVERIFIED]** | The documentation host returned HTTP 401 to the surveyor. Only the beta-on-all-plans notice is known, from a search-surfaced result. |
| Render generic MCP hosting mechanics | **[UNVERIFIED]** | The Render MCP server page was read; the general "host your own MCP server on Render" mechanics were not. |
| E2B sandbox access to the Docker catalog | **[UNVERIFIED]** | Single-sourced, not confirmed against a primary document. |
| MCP and ACP repository licences | **NOT ESTABLISHED IN SOURCE** | Neither LICENSE file was read in this pass. A2A's Apache-2.0 claim comes from the repository description only. |
| A Foundry Agent Service overview page dated 2026-06-02 | **NOT ESTABLISHED IN SOURCE** | The date is in the source material; the page URL was not captured and is not cited here. |
| "ngpx" as a hosting target | **no such product** | No product by that name could be verified. What exists, and what every client configuration actually uses, is `npx` — for example `claude mcp add myserver -- npx -y @example/mcp-server`, or `"command": "npx"` in a Cursor `mcp.json`. |

### Claim-verification caveats

1. **Every platform row comes from a vendor documentation page fetched
   directly on 2026-09-29.** No secondary blog is the sole source for any
   version or status in the matrix. Where a search result was the only route
   (Vercel's own server), the row is tagged `[UNVERIFIED]`.
2. **No vendor pins a protocol revision except MCP's own versioning page and
   Netlify's blog.** `NOT ESTABLISHED IN SOURCE` in the revision column is the
   normal case, not a research failure: a client that supports `2026-07-28`
   without documenting it is indistinguishable from one that does not support
   it, on this evidence.
3. **The source material is internally inconsistent on two counts, and neither
   is resolved here.** (a) It states "three named clients" support `2026-07-28`
   while its own Netlify citation names two — Claude.ai and Claude Managed
   Agents — plus Claude Code as "coming soon"; the third is not enumerated.
   (b) The MCP extension client matrix is described as naming 13 clients, of
   which 11 are enumerated in the source; the remainder is not listed.
4. **"GA" and "preview" are the vendor's own word**, taken from the page, not a
   maturity judgement. A vendor may mark a surface GA while that surface
   carries a narrower feature set than the protocol, which is what the
   Microsoft A2A row does: GA on A2A 1.0, text modality only, no streaming.
5. **Deployment reality is an inference, not a vendor claim.** That the large
   clients run `2025-11-25` rather than `2026-07-28` follows from the
   combination of no documented `2026-07-28` support, the retained
   pre-revision surface in the Claude Code reference, and the three
   documentation-lag sites. [INFERENCE]

## What it does

### By vendor

**AWS — Amazon Bedrock AgentCore Runtime.** The broadest first-party
multi-protocol surface found. The dev guide lists five protocol contracts:
HTTP, MCP, A2A, AG-UI, plus Gateway.

- *MCP*: Streamable HTTP required, port 8000, ARM64. Stateless mode
  (`stateless_http=True`) is the default, stated as being for compatibility
  with AWS's session management and load balancing. The platform generates
  `Mcp-Session-Id`; the server must accept it for microVM routing. Sessions run
  up to 8 hours on microVMs and 14 days on Instances.
- *A2A*: stateless HTTP server on port 9000, transparent JSON-RPC proxy,
  authenticated agent card at `/.well-known/agent-card.json`. Inbound OAuth 2.0
  or SigV4; outbound IAM execution role or AgentCore Identity. Announced
  2025-11-11, page modified 2026-07-10.
- *AG-UI*: SSE or WebSocket, port 8080, `RunAgentInput` in and AG-UI events
  out, `RUN_ERROR` mapped, session id carried in a header. Announced
  2026-03-13.
- *Gateway*: managed MCP endpoint; authorizer types `NONE` and `CUSTOM_JWT`
  with an OIDC discovery URL and allowed audience.

**Microsoft.** Two surfaces.

- *Foundry Agent Service*: the `a2a` tool type (`A2ATool`, `A2AToolboxTool`)
  targets A2A 1.0 and is GA; the legacy `a2a_preview` targets 0.3 and remains
  in preview. The endpoint shape is
  `https://{account}.services.ai.azure.com/api/projects/{project}/agents/{agent}/endpoint/protocols/a2a`
  with audience `https://ai.azure.com` and a Foundry Agent Consumer role
  requirement. Foundry-hosted A2A targets support 1.0 (JSON-RPC) and 0.3, text
  modality only, no streaming. Six connection authentication types are
  documented, one of which is `agentic-identity` — the agent's own per-project
  identity, distinct from the project managed identity. Task and context
  retention is 60 days from last write.
- *Foundry MCP*: `MCPTool` with `server_url`, `server_label`, `allowed_tools`
  and `require_approval`. Public and private endpoints; a private endpoint
  needs a subnet delegated to `Microsoft.App/environments`. **Eleven**
  Foundry-managed OAuth connectors are documented; eight are named in the
  source: Azure Databricks Genie, GitHub, Infobip WhatsApp/RCS/SMS, LSEG,
  Morningstar, Neon, Pipedream, Vercel. The first OAuth call returns error code
  `-32006`, `CONSENT_REQUIRED`, with a consent URL. **Foundry Toolboxes** bundle
  web search, code interpreter, file search, Azure AI Search, MCP servers,
  OpenAPI tools and A2A connections behind one MCP-compatible endpoint, consumed
  by Agent Service, Agent Framework, LangGraph and the GitHub Copilot SDK. MCP
  tasks are preview.
- *Copilot Studio*: A2A agent connections over custom connector infrastructure,
  authentication None / API key / OAuth 2.0, automatically pulling name and
  description from the agent card. The page still points at the pre-1.0
  `/.well-known/agent.json` path.

**Google.** Two surfaces, at different maturities.

- *ADK*: A2A both exposed and consumed, with Python, Go and Java marked
  Supported and TypeScript/JavaScript carrying an Experimental badge. ADK also
  ships built-in MCP tools, an agent-as-MCP-server path and an MCP client. ADK
  Python 2.0 is GA with graph workflows.
- *Agent Engine*, the Vertex AI Agent Engine lineage now documented as the
  Gemini Enterprise Agent Platform: a first-party "Use an Agent2Agent agent"
  guide, IAM agent identity, Agent Gateway, bidirectional streaming and Private
  Service Connect — with the dedicated A2A page carrying a **Pre-GA Offerings
  Terms** banner.

**OpenAI.** MCP is the protocol with vendor documentation. Remote MCP for
plugins and Apps, Codex plugins, the Responses API, and the Agents SDK both as
an MCP client (agent-level and shared) and as a hosted MCP server, supporting
MCP Python SDK v1 and v2. For deep-research and company-knowledge servers the
contract is specific: read-only `search` and `fetch`, results returned in both
`structuredContent` and a JSON-encoded `content` array, and a non-empty `url` per
result for citable output. ChatGPT is listed in the MCP extension client matrix
as supporting MCP Apps, with partial support noted for Skills.

The 2026 direction of travel is the migration of the OpenAI Apps SDK into MCP
Apps, published as an official migration guide: flat `_meta["openai/*"]`
becomes nested `_meta.ui.*`; `text/html+skybridge` becomes
`text/html;profile=mcp-app`; the `window.openai` global becomes an explicit
`new App(...)`; and the helpers become `registerAppTool()` and
`registerAppResource()`. Three OpenAI features are marked **"Not yet
implemented"** in MCP — `toolInvocation/invoking`, `toolInvocation/invoked` and
`widgetDescription` — and forcing OpenAI mode with `new OpenAITransport()` is
still pending in ext-apps PR #172.

**Anthropic.** Three surfaces, two of them beta.

- *Claude Code*: four transports. `http` is preferred with `streamable-http` an
  accepted alias; `sse` is explicitly deprecated with automatic fallback from
  HTTP as of v2.1.265; `ws` uses header-only authentication; `stdio` is
  standard. A `"type": "sdk"` in-process server registers only from an Agent SDK
  host or the desktop app and is skipped in config. `CLAUDE_PROJECT_DIR` is
  injected into spawned stdio servers. Reserved built-in server names are
  `workspace`, `claude-in-chrome`, `computer-use`, `Claude Preview` and
  `Claude Browser`.
- *Claude API MCP connector*: beta, header `mcp-client-2025-11-20`. Connects to
  remote MCP servers directly from the Messages API with per-tool allow, deny
  and configuration, without a separate MCP client.
- *Claude Managed Agents MCP connector*: beta, header
  `managed-agents-2026-04-01`. `mcp_servers` are declared on the agent by name
  and URL, with a cap of 20 per agent; every server must have a matching
  `mcp_toolset` and vice versa, and dangling toolsets are rejected. Per-tool
  `default_config` and `configs` carry `enabled` and `permission_policy`.
  Tool output above 100,000 characters is spilled to a file in the sandbox with
  a truncated preview.
- Claude (web) and Claude Desktop are listed as supporting the MCP Apps
  extension.

**GitHub Copilot.** MCP is the only protocol documented. It works in agent mode
in VS Code since 2025-04, with JetBrains, Eclipse and Xcode in public preview
from 2025-05-19, and in Copilot CLI, `copilot-sdk`, the coding agent, the cloud
agent, and code review — where agent skills and MCP went GA on 2026-07-29. The
cloud agent has two documented hard limits: it is tools only, with the
documentation stating the servers "do not currently support resources or
prompts"; and "do not currently support remote MCP servers that leverage
OAuth." It uses available tools autonomously without a per-tool approval step,
which differs from Copilot CLI and IDE sessions. Defaults are the GitHub MCP
server, with a repo-scoped read-only token, and the Playwright MCP server,
confined to Copilot's own environment.

**JetBrains.** ACP is the vendor's chosen editor-to-agent protocol, in AI
Assistant 2026.2, build 2026-09-14. Installation runs through the curated ACP
registry from the AI Chat tool window; custom agents are configured through
`~/.jetbrains/acp.json` with `command`, `args` and `env` per agent. The IDE
auto-downloads agent files and manages a Node.js or Python runtime, reusing an
existing compatible one. ACP agents receive MCP passthrough, so a
user-configured MCP server is reachable from an agent. Usable without a
JetBrains AI subscription; WSL is unsupported. Extended logging is available
through the `llm.agent.extended.logging` registry key.

**Cursor.** MCP only, no A2A surface found. Three transports: stdio for local
servers with manual authentication, and SSE and Streamable HTTP for remote
servers over OAuth. The documented feature matrix is Tools, Prompts, Resources,
Roots, Elicitation and the Apps extension. Static OAuth credentials are
configured through an `auth` object in `mcp.json` for providers that do not
support dynamic client registration. Redirect URLs are fixed at
`https://www.cursor.com/agents/mcp/oauth/callback` and
`http://localhost:8787/callback`. The extension API exposes
`vscode.cursor.mcp.registerServer()`, and tool approval is on by default.

**Hosting platforms.**

- *Cloudflare* has the most complete first-party remote-MCP hosting story.
  Agents SDK `createMcpHandler` is stateless; the class-based `McpAgent` is
  documented as deprecated. Cloudflare One publishes "Secure MCP servers with
  Access", last updated 2026-07-09. Cloudflare also operates an MCP catalog
  subregistry with curated server lists, network isolation and image scanning.
- *Netlify* supports `2026-07-28` from day one, as described above, and also
  runs the Cloudflare MCP catalog as a subregistry.
- *Vercel* has hosted MCP since 2025-05-07, with `@vercel/mcp-adapter` renamed
  to `mcp-handler`, a Next.js template, SSE plus stateless HTTP, and Redis for
  SSE state. Vercel's own server at `mcp.vercel.com` is Beta on all plans
  (`[UNVERIFIED]`). Vercel is also one of the eleven servers with a
  Foundry-managed OAuth connector.
- *Render* hosts a first-party remote MCP server at `https://mcp.render.com/mcp`,
  reachable from Claude Code through the official plugin
  `render@claude-plugins-official`, from Codex through
  `codex mcp add render --url … --oauth-client-id codex`, and from Cursor
  through `/add-plugin render`; a static `Authorization: Bearer <API_KEY>` is
  also accepted. Every tool is scoped to a currently selected workspace that the
  user must set. The server source is open at `render-oss/render-mcp-server`.
- *Docker* ships the MCP Catalog and the MCP Gateway. The gateway runs servers
  in isolated containers with restricted privileges, network and resources,
  with per-server logging and call tracing and profile scoping; it auto-runs
  inside Docker Desktop when the MCP Toolkit is enabled, and there is a
  standalone binary for Docker Engine. The open-source gateway is public; the
  governed productization under Docker AI Governance is invite-only, by
  contact with sales. A separate `docker/mcp-registry` repository provides the
  name, namespace and subregistry layering.

## What changed recently

| Date | Change | Vendor |
| --- | --- | --- |
| 2025-04-28 | Remote MCP server components announced: `workers-oauth-provider`, `McpAgent`, Agents SDK | Cloudflare |
| 2025-04 | MCP in agent mode, VS Code | GitHub |
| 2025-05-07 | First-party MCP hosting on Vercel; `@vercel/mcp-adapter` introduced, later renamed `mcp-handler` | Vercel |
| 2025-05-19 | MCP agent mode in public preview for JetBrains, Eclipse and Xcode | GitHub |
| 2025-11-11 | A2A support announced for AgentCore Runtime: stateless HTTP on port 9000, authenticated agent card | AWS |
| 2025-11-20 | Claude API MCP connector becomes available, header `mcp-client-2025-11-20` | Anthropic |
| 2026-01-26 | AG-UI spec revision, referenced by the MCP Apps extension | AG-UI |
| 2026-03-09 | ACP Registry released | ACP project (Zed, JetBrains) |
| 2026-03-12 | A2A 1.0 announced, "production-ready standard" | A2A project (Linux Foundation) |
| 2026-03-13 | AG-UI protocol contract for AgentCore Runtime announced | AWS |
| 2026-04-01 | Managed Agents MCP connector becomes available, header `managed-agents-2026-04-01` | Anthropic |
| 2026-04-22 | ACP Transports Working Group formed | ACP project |
| 2026-06-25 | ACP Rust and TypeScript SDKs reach 1.0.0 | ACP project |
| 2026-07-20 | ACP v2 published as Draft, after 15+ RFDs stabilised on v1 | ACP project (Zed) |
| 2026-07-28 | MCP `2026-07-28` becomes the current protocol revision: stateless, no sessions, no `initialize` handshake | MCP project |
| 2026-07-29 | Copilot code review agent skills and MCP generally available | GitHub |
| 2026-08-26 | Copilot Studio A2A connection documented; Foundry MCP tool page dated the same day | Microsoft |
| 2026-09-11 | Foundry A2A tool documented as GA on A2A 1.0 | Microsoft |
| 2026-09-14 | AI Assistant 2026.2 build carrying ACP support | JetBrains |
| 2026-09-15 | `developers.openai.com/api/docs/mcp` last-verified stamp | OpenAI |
| 2026-09-29 | Netlify MCP server advertises `2026-07-28` support and names its supported clients | Netlify |

## Evidence of adoption

Dated, countable, and drawn from primary sources.

| Metric | Value | Date | Source |
| --- | --- | --- | --- |
| AAIF formation, with MCP, goose and AGENTS.md as founding contributions | Anthropic, Block, OpenAI as founding members | 2025-12-09 | [Linux Foundation press release](https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation-aaif-anchored-by-new-project-contributions-including-model-context-protocol-mcp-goose-and-agents-md) |
| Gates Foundation joined the AAIF | — | 2026-09-15 | same |
| A2A participating organisations | 150+, up from 50+ in April 2025 | 2026-04-09 | [LF A2A one-year release](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year) |
| A2A GitHub stars | 22,000+ | 2026-04-09 | same |
| A2A TSC companies named | AWS, Cisco, Google, IBM, Microsoft, Salesforce, SAP, ServiceNow | 2026-04-09 | same |
| A2A SDK languages | five production-ready, up from one | 2026-04-09 | same |
| A2A cloud platforms named in the LF release | Google, Microsoft, AWS | 2026-04-09 | same |
| MCP Apps client matrix | described as 13 named clients; 11 enumerated in the source: Claude web, Claude Desktop, VS Code Copilot, Microsoft 365 Copilot, Goose, Postman, MCPJam, ChatGPT, Cursor, Archestra.AI, PostHog Code. ChatGPT is partial on Skills. | undated page | [client-matrix.md](https://modelcontextprotocol.io/extensions/client-matrix.md) |
| Cross-framework A2A interop demonstrated by AWS | a Google ADK host agent orchestrating a Strands monitoring agent and an OpenAI-SDK operations agent, on AWS infrastructure | not dated in the source | AWS A2A announcement |

**Where support actually is.** By protocol, the platform support concentrates in
four places:

- **MCP is universal across every vendor in this survey**, and it is the only
  protocol with a client matrix, a conformance framework and a foundation home.
- **A2A is cloud-platform only.** AWS, Microsoft and Google document it.
  OpenAI, Anthropic, GitHub, Cursor and Zed do not, as absence of evidence.
- **ACP is editor-side only**, with two first-party clients: Zed and JetBrains.
- **AG-UI has one first-party cloud implementation**, AWS AgentCore Runtime.

## Sharp edges

1. **The `2026-07-28` adoption gap is the load-bearing caveat.** One hosting
   platform advertises the current spec; the clients it names are Claude.ai and
   Claude Managed Agents, with Claude Code marked "coming soon"; no document in
   this survey claims `2026-07-28` support for Copilot, Cursor, ChatGPT or Zed.
   A description of "MCP 2026-07-28" that omits the support caveat is wrong for
   most readers.
2. **A2A's GA is uneven and vendor-specific.** Microsoft `a2a` is GA on A2A 1.0
   but text-only and non-streaming. AWS is GA but wraps it in a stateless
   JSON-RPC proxy on port 9000 with platform session headers. Google ADK is
   stable in-SDK while the Vertex Agent Engine A2A page is Pre-GA. A2A 1.0 also
   breaks `SendStreamingMessage` on some paths and renames many types, with a
   v0.5+ mapping table in the spec.
3. **Three of the four largest agent vendors document no A2A support at all.**
   OpenAI, Anthropic and GitHub are all silent. Assuming parity across the big
   four is wrong on three of four.
4. **The `2026-07-28` revision deprecates things clients still ship.** Roots and
   Sampling are deprecated, not removed, with earliest removal on or after
   2027-07-28, yet Cursor's documentation still lists Roots as supported and
   Claude Code still implements `roots/list` and
   `notifications/roots/list_changed`. Elicitation was reworked in `2025-11-25`
   with URL mode and again in `2026-07-28` with MRTR, removing
   `notifications/elicitation/complete` and `elicitationId`.
5. **AWS's MCP contract carries both revisions at once.** The page documents the
   `2026-07-28` MRTR pattern and simultaneously requires the server to accept a
   `Mcp-Session-Id` header that the revision removed.
6. **OpenAI's Apps SDK migration to MCP Apps is incomplete.** Three features
   have no MCP equivalent, and the OpenAI-mode transport is still an open pull
   request. A server that adopts `_meta.ui.*` today gives up OpenAI-specific
   affordances unless the ChatGPT host still honours them.
7. **MCP task support is preview almost everywhere.** Microsoft states it
   explicitly, and the `io.modelcontextprotocol/tasks` extension is new in
   `2026-07-28`. Long-running MCP operations are not a settled surface.
8. **Version pins are rare.** No vendor except MCP's own versioning page and
   Netlify's blog publishes a protocol revision, so a support matrix built from
   vendor documentation alone cannot distinguish a client on `2025-11-25` from
   one on `2026-07-28`.
9. **Vendor documentation lag is observable in three places**, and all three
   are protocol-compatibility defects rather than wording: Cursor's Roots row,
   Copilot Studio's `/.well-known/agent.json` path, and Cloudflare's link to
   spec revision `2025-06-18`.
10. **The acronym ACP is not unique.** `agent-client-protocol` (Zed and
    JetBrains) and `agent-control-protocol` (WebSocket UI automation,
    "Version 2.0, Draft, 2026-03-28") share it. Resolution must be by
    repository, not by name.
11. **Two products in this survey are gated.** Docker's governed MCP
    productization under Docker AI Governance is invite-only, and Vercel's own
    MCP server is Beta on all plans.
12. **Cloud agent and local agent are not the same product.** GitHub's cloud
    agent is tools-only, cannot use OAuth-bearing remote MCP servers, and runs
    tools autonomously; Copilot CLI and IDE sessions are not so constrained.
    Same protocol, different supported surface.

## Sources

Every URL below was fetched on 2026-09-29. Vendor pages are the sole basis for
every row in the support matrix.

**Protocol state and revision history**

- <https://modelcontextprotocol.io/docs/2026-07-28/learn/versioning.md> — "The
  current protocol version is 2026-07-28."
- <https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2026-07-28/changelog.mdx>
  — SEP-2567, SEP-2575, SEP-2322 and the other changes in the current revision.
- <https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md> —
  statelessness; removal of the `initialize` handshake and sessions.
- <https://modelcontextprotocol.io/specification/2026-07-28/deprecated.md> —
  deprecated features registry and earliest removal dates.
- <https://modelcontextprotocol.io/extensions/client-matrix.md> — MCP Apps,
  Client Credentials, Enterprise Auth and Skills support per client.
- <https://modelcontextprotocol.io/extensions/apps/overview.md> — MCP Apps
  extension, `ext-apps` revision 2026-01-26.
- <https://apps.extensions.modelcontextprotocol.io/api/documents/migrate-openai-app.html>
  — OpenAI Apps SDK to MCP Apps SDK migration guide.
- <https://raw.githubusercontent.com/a2aproject/A2A/main/docs/specification.md> —
  A2A v1.0 specification text.
- <https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/>
  — v1.0 announcement, 2026-03-12.
- <https://a2a-protocol.org/latest/roadmap/> — v1.1 and bidirectional streaming,
  updated 2026-09-15.
- <https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year>
  — 150+ organisations, 22,000+ stars, TSC membership, 2026-04-09.
- <https://agentclientprotocol.com/protocol/v1/schema> — ACP v1 schema.
- <https://agentclientprotocol.com/updates> — dated ACP governance and protocol
  announcements, October 2025 to 2026-09-17.
- <https://docs.ag-ui.com/sdk/js/core/types> — AG-UI types referenced by the AWS
  contract.

**AWS**

- <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agents-tools-runtime.html>
- <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html>
- <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-agui-protocol-contract.html>
- <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-quick-start.html>
- <https://aws.amazon.com/blogs/machine-learning/introducing-agent-to-agent-protocol-support-in-amazon-bedrock-agentcore-runtime/>
  — 2025-11-11, modified 2026-07-10.

**Microsoft**

- <https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/agent-to-agent>
  — 2026-09-11.
- <https://raw.githubusercontent.com/MicrosoftDocs/azure-ai-docs/main/articles/foundry/agents/how-to/tools/model-context-protocol.md>
  — 2026-08-26.
- <https://learn.microsoft.com/en-us/microsoft-copilot-studio/add-agent-agent-to-agent>
  — 2026-08-26.

**Google**

- <https://adk.dev/a2a/> — language support badges.
- <https://adk.dev/mcp> — built-in tools, agent-as-server, client.
- <https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale> —
  runtime, IAM agent identity, Agent Gateway, streaming.
- <https://docs.cloud.google.com/agent-builder/agent-engine/develop/a2a> —
  Pre-GA Offerings Terms banner.

**OpenAI**

- <https://developers.openai.com/api/docs/mcp> — last verified 2026-09-15.
- <https://openai.github.io/openai-agents-python/mcp> — client and hosted
  server, MCP Python SDK v1 and v2.

**Anthropic**

- <https://code.claude.com/docs/en/mcp> — transports, reserved names,
  `CLAUDE_PROJECT_DIR`.
- <https://platform.claude.com/docs/en/agents-and-tools/mcp-connector> — beta
  `mcp-client-2025-11-20`.
- <https://platform.claude.com/docs/en/managed-agents/mcp-connector> — beta
  `managed-agents-2026-04-01`.

**GitHub, JetBrains, Cursor**

- <https://docs.github.com/en/copilot/concepts/agents/coding-agent/mcp-and-coding-agent>
- <https://github.blog/changelog/2026-07-29-copilot-code-review-agent-skills-and-mcp-now-generally-available/>
- <https://www.jetbrains.com/help/ai-assistant/acp.html> — AI Assistant 2026.2,
  build 2026-09-14.
- <https://cursor.com/docs/mcp> — transports, feature matrix, OAuth
  configuration, extension API.

**Hosting**

- <https://developers.cloudflare.com/agents/model-context-protocol/protocol/authorization/index.md>
- <https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/secure-mcp-servers/index.md>
  — last updated 2026-07-09.
- <https://blog.cloudflare.com/remote-model-context-protocol-servers-mcp> —
  2025-04-28.
- <https://www.cloudflare.com/developer-platform/products/mcp-catalog/>
- <https://www.netlify.com/blog/mcp-goes-stateless-and-extensible/> — last
  updated 2026-09-29; the primary source for the `2026-07-28` adoption gap.
- <https://vercel.com/changelog/mcp-server-support-on-vercel> — 2025-05-07.
- <https://render.com/docs/mcp-server>
- <https://github.com/render-oss/render-mcp-server>
- <https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/>
- <https://docs.docker.com/ai/mcp-catalog-and-toolkit/catalog>
- <https://github.com/docker/mcp-registry>
