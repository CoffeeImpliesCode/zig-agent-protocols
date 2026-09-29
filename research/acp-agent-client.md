# Agent Client Protocol (ACP) — editor to coding agent

Evidence about the Zed and JetBrains Agent Client Protocol: its wire version and
the artifact versions that surround it, its interim two-vendor governance, the v1
method set and session lifecycle, the permission and elicitation flows, the client
and agent capability sets, the v2 draft, the ACP Registry, adoption on both sides
of the wire, and the sharp edges. The IBM Agent Communication Protocol, which
shares the acronym and nothing else, is out of scope; it has its own document.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

### Version

The stable wire version is `1`. The specification repository states it verbatim:
"The current stable ACP protocol version is `1`"
([agent-client-protocol README](https://github.com/agentclientprotocol/agent-client-protocol)).

Four different numbers describe the same protocol, and they move independently:

| Number | Value on the research date | What it versions | Source |
| --- | --- | --- | --- |
| Wire `protocolVersion` | `1` | The negotiated wire shape | [README](https://github.com/agentclientprotocol/agent-client-protocol) |
| Rust crate release | `1.9.1` (2026-09-18) | `agent-client-protocol-schema` crate code | [releases](https://github.com/agentclientprotocol/agent-client-protocol/releases) |
| v1 JSON Schema artifact | `schema-v1.23.0` | `schema/v1` schema documents | [releases](https://github.com/agentclientprotocol/agent-client-protocol/releases) |
| v2 JSON Schema artifact | `schema-v2.0.0-alpha.3`, `.4`, `.5` | `schema/v2` draft schema documents | [releases](https://github.com/agentclientprotocol/agent-client-protocol/releases) |

The divergence is deliberate and documented. The repository warns that crate and
schema release versions are **decoupled from wire compatibility**, and that only
the negotiated `protocolVersion` determines the wire shape
([README](https://github.com/agentclientprotocol/agent-client-protocol)). The crate
is a Rust code artifact; the schemas are generated JSON Schema documents; neither
is a protocol version. v1 stayed at wire version `1` through 15 or more stabilized
RFDs without a major bump, which is why the crate and schema counters run far
ahead of the wire counter.

### Location

| Artefact | Location |
| --- | --- |
| Specification and docs | [agentclientprotocol.com](https://agentclientprotocol.com) |
| v1 doc tree | `/protocol/v1/*` |
| v2 doc tree | `/protocol/v2/*` |
| Machine-readable page index | [`llms.txt`](https://agentclientprotocol.com/llms.txt) — v1 and v2 trees, 5 SDKs, about 50 RFDs, 21 announcements |
| Spec and code repository | [github.com/agentclientprotocol/agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol) (Rust) |
| Schema crate | `agent-client-protocol-schema` |
| Schema documents | `schema/v1`, `schema/v2` |

### The repository move

The repository is no longer under `zed-industries`. It lives in the
domain-verified GitHub organisation `agentclientprotocol`, verified for
agentclientprotocol.com, holding 15 repositories: the registry, `codex-acp`,
`claude-agent-acp`, `acp-tck`, a meetings repository, and 5 SDKs
([organisation](https://github.com/agentclientprotocol)).

The move is bracketed by two dated artefacts:

| Date | Evidence | Source |
| --- | --- | --- |
| On or before 2025-10-06 | Zed's JetBrains announcement still discusses the project under the old path | [zed.dev/blog/jetbrains-on-acp](https://zed.dev/blog/jetbrains-on-acp) |
| By 2025-10-13 | CHANGELOG `0.4.7` moves the Rust SDK to `agentclientprotocol/rust-sdk` | [CHANGELOG](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/CHANGELOG.md) |
| 2025-10-24 | CHANGELOG `0.6.0` links a pull request under `agentclientprotocol/agent-client-protocol` | [CHANGELOG](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/CHANGELOG.md) |

The transfer therefore landed between 2025-10-06 and 2025-10-13. The exact date
is **NOT ESTABLISHED IN SOURCE**. `[INFERENCE]` The move was a neutrality step,
taken as JetBrains became a co-developer; no source states that intent directly.

### License and maturity

Apache-2.0 across every repository in the organisation, with **no CLA**;
contributions are accepted under explicit Apache-2.0 assignment wording
([governance](https://agentclientprotocol.com/community/governance)).

The wire protocol is labelled pre-1.0 in maturity practice but is in wide use.
v1 is called stable, 15 or more RFDs were stabilised on top of it without a major
version bump, and the Rust and TypeScript SDKs reached `1.0.0` on 2026-06-25
([updates](https://agentclientprotocol.com/updates)). ACP is not an AAIF project
and is not under the Linux Foundation ([aaif.io/projects](https://aaif.io/projects)).

### Governance

Governance is explicitly interim and explicitly two-company. The governance page
states that ACP is "jointly governed by Zed and JetBrains… while working toward
transitioning to an independent foundation"
([governance](https://agentclientprotocol.com/community/governance)). No foundation
exists, no transition date is published, and no transition process is published.

The authority ladder is shaped like MCP and the Rust Foundation: contributors, then
maintainers, then core maintainers, then **two lead maintainers with BDFL authority
and veto over everything** ([governance](https://agentclientprotocol.com/community/governance)).

| Role | Person | Organisation | Dated change |
| --- | --- | --- | --- |
| Lead maintainer | Ben Brandt | Zed Industries | — |
| Lead maintainer | Sergey Ignatov | JetBrains | Added 2026-02-18 |
| Core maintainer | Anna Zhdan | JetBrains | — |
| Core maintainer | Agus Zubiaga | — | — |
| Core maintainer | Niko Matsakis | — | — |
| Core maintainer | Vadim Briliantov | — | — |

Source: [MAINTAINERS.md](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/MAINTAINERS.md),
last updated 2026-06-01. The 2026-02-18 addition of the second lead makes the
BDFL pair explicitly one per vendor
([updates](https://agentclientprotocol.com/updates)).

Process mechanics:

- Core maintainers meet every two weeks.
- Protocol changes run through an RFD process; the lifecycle stages are Draft,
  Active, Preview and Completed, and Preview is explicitly unstable
  ([rfds/updates](https://agentclientprotocol.com/rfds/updates)).
- Public discussion runs through Zulip
  ([governance](https://agentclientprotocol.com/community/governance)).
- Working and interest groups exist, with a 72-hour core-maintainer vote and a
  facilitator role distinct from maintainer
  ([working-interest-groups](https://agentclientprotocol.com/community/working-interest-groups)).
  The Transports Working Group was formed 2026-04-22 and is co-led by Anna Zhdan
  (JetBrains) and Alex Hancock (Block Goose)
  ([announcement](https://agentclientprotocol.com/announcements/transports-working-group)).

Security disclosure runs through Zed alone, at `security@zed.dev`, even though
JetBrains co-governs the project
([governance](https://agentclientprotocol.com/community/governance)). The scope of
that inbox — whether it covers agent implementations rather than only the
specification repository — is **NOT ESTABLISHED IN SOURCE**.

An AAIF proposal to admit ACP, and any unsigned or signed agreement attached to
such a proposal, are **NOT ESTABLISHED IN SOURCE** for this document. The
AAIF project list is the only ACP-side evidence, and it shows no ACP
([aaif.io/projects](https://aaif.io/projects)). Foundation-level questions are out
of scope here; see [`governance.md`](governance.md).

### Named companies and their standing

| Company | Standing | Evidence |
| --- | --- | --- |
| Google | Launch partner. Approached Zed. Gemini CLI is the reference implementation, in `google-gemini/gemini-cli`. No maintainer seat. | [launch post](https://zed.dev/blog/bring-your-own-agent-to-zed), [MAINTAINERS.md](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/MAINTAINERS.md) |
| GitHub / Microsoft | Implementer, not governor. Copilot CLI ships ACP first-party. No maintainer seat. Microsoft also shipped a competing stack, AgentHQ, in Dec 2025. | [Copilot changelog](https://github.blog/changelog/2026-01-28-acp-support-in-copilot-cli-is-now-in-public-preview/), [JetBrains](https://blog.jetbrains.com/ai/2025/12/agents-protocols-and-why-we-re-not-playing-favorites/) |
| Cognition | Implementer only. Devin CLI in the registry at `3000.11.3`. No maintainer seat. | [registry](https://agentclientprotocol.com/registry) |
| Block / Goose | Alex Hancock co-leads the Transports Working Group. Goose is an AAIF project, not an ACP-governing party. | [WG announcement](https://agentclientprotocol.com/announcements/transports-working-group) |

## What it does

### Roles and shape

A client is an editor, IDE or UI. An agent is a coding-agent process. The stated
model is explicitly borrowed from LSP: "Just as the Language Server Protocol
unbundled language intelligence from monolithic IDEs, our goal with the Agent
Client Protocol is to enable you to switch between multiple agents without
switching your editor"
([introduction](https://agentclientprotocol.com/get-started/introduction)).

### Transport

JSON-RPC 2.0 over UTF-8. **stdio is the only normative transport**: the client
launches the agent as a subprocess, messages are newline-delimited with no embedded
newlines, the agent **MUST NOT** write non-ACP bytes to stdout, and stderr is free
for logs ([transports](https://agentclientprotocol.com/protocol/v1/transports)).
Custom transports are permitted. Streamable HTTP is "In discussion, draft proposal
in progress" ([transports](https://agentclientprotocol.com/protocol/v1/transports)),
and the introduction page warns that "Full support for remote agents is a work in
progress" ([introduction](https://agentclientprotocol.com/get-started/introduction)).
v2 adopts JSON-RPC 2.0 batch semantics
([v2 overview](https://agentclientprotocol.com/rfds/v2/overview)).

### Version negotiation and the extension mechanism

The client sends the highest integer `protocolVersion` it speaks. The agent echoes
it or returns its own highest. The client **SHOULD** disconnect if it cannot speak
the returned version
([initialization](https://agentclientprotocol.com/protocol/v1/initialization)).

All capabilities are optional, and omission means **UNSUPPORTED**. That single rule
is the protocol's non-breaking-extension mechanism: a peer that does not recognise
a capability field degrades rather than fails
([initialization](https://agentclientprotocol.com/protocol/v1/initialization)).

### Method set, v1

Agent-side methods
([v1 overview](https://agentclientprotocol.com/protocol/v1/overview)):

| Method | Note |
| --- | --- |
| `initialize` | First call; carries `protocolVersion` and both capability sets |
| `authenticate` | Optional; follows `initialize` |
| `logout` | Gated on `agentCapabilities.auth.logout` |
| `session/new` | Baseline |
| `session/prompt` | Baseline; stays pending for the whole turn |
| `session/load` | Gated on `agentCapabilities.loadSession` |
| `session/list` | Stabilized 2026-02 to 2026-06 window |
| `session/resume` | — |
| `session/close` | — |
| `session/delete` | Gated on `agentCapabilities.session.delete` |
| `session/set_mode` | Removed in the v2 draft |
| `session/set_config_option` | — |
| `session/cancel` | Notification; baseline |
| `$/cancel_request` | Notification; cancels any outstanding request by ID from either side; stabilized 2026-06-29 |

Client-side methods
([v1 overview](https://agentclientprotocol.com/protocol/v1/overview)):

| Method | Note |
| --- | --- |
| `session/request_permission` | **The only baseline Client method.** The IDE is the policy decision point. |
| `fs/read_text_file` | Gated on `clientCapabilities.fs.readTextFile` |
| `fs/write_text_file` | Gated on `clientCapabilities.fs.writeTextFile` |
| `terminal/create` | Gated on `clientCapabilities.terminal` |
| `terminal/output` | Gated on `clientCapabilities.terminal` |
| `terminal/release` | Gated on `clientCapabilities.terminal` |
| `terminal/wait_for_exit` | Gated on `clientCapabilities.terminal` |
| `terminal/kill` | Gated on `clientCapabilities.terminal` |
| `elicitation/create` | Form or URL mode; stabilized 2026-07-24 |
| `elicitation/complete` | Notification |

Agent to client: the `session/update` notification
([v1 overview](https://agentclientprotocol.com/protocol/v1/overview)).

The baseline agent session methods are `session/new`, `session/prompt`,
`session/cancel` and `session/update`
([initialization](https://agentclientprotocol.com/protocol/v1/initialization)). The
remaining agent methods are optional and gated on capabilities.

### Session lifecycle, v1

```
initialize
  -> authenticate                     (optional)
  -> session/new | session/load
  -> session/prompt                   (stays pending for the whole turn)
       <- session/update              (streamed by the agent)
       -> session/request_permission | fs/* | terminal/* | elicitation/create
  <- prompt response carrying stopReason   (turn ends)
```

`session/cancel`, sent as a notification, interrupts a turn. `$/cancel_request`,
stabilized 2026-06-29, cancels any outstanding request by ID from either side
([updates](https://agentclientprotocol.com/updates),
[v1 overview](https://agentclientprotocol.com/protocol/v1/overview)).

### Permission flow, v1

The agent calls `session/request_permission` with `sessionId`, a `toolCall` of
type `ToolCallUpdate`, and an `options` array. Each option is
`{optionId, name, kind}` with `kind` drawn from `allow_once`, `allow_always`,
`reject_once`, `reject_always`. The client replies with
`{outcome: {outcome: "selected", optionId}}` or `{outcome: {outcome: "cancelled"}}`.
Clients MAY auto-decide by policy
([tool-calls](https://agentclientprotocol.com/protocol/v1/tool-calls)).

### Elicitation flow

Stabilized 2026-07-24
([updates](https://agentclientprotocol.com/updates)). The agent calls
`elicitation/create` in one of two modes
([elicitation](https://agentclientprotocol.com/protocol/v1/elicitation)):

| Mode | Shape | Rules |
| --- | --- | --- |
| `form` | Restricted flat JSON Schema, non-sensitive fields | **MUST NOT** request secrets |
| `url` | Out-of-band OAuth-style flow | Carries an `elicitationId`, completed by the later `elicitation/complete` notification |

The client answers `accept`, `decline` or `cancel`. Sensitive flows **MUST** use
URL mode, and an agent **MUST NOT** fall back to form mode. Agents **MUST** bind
each elicitation to the receiving connection plus verified identity
([elicitation](https://agentclientprotocol.com/protocol/v1/elicitation)).

### Client capabilities

Advertised by the client at `initialize`
([initialization](https://agentclientprotocol.com/protocol/v1/initialization)):

| Capability | Gates |
| --- | --- |
| `fs.readTextFile` | `fs/read_text_file` |
| `fs.writeTextFile` | `fs/write_text_file` |
| `terminal` (top-level boolean) | All five `terminal/*` methods |
| `auth.terminal` | Terminal-mode authentication |
| `elicitation.form` | Form-mode elicitation |
| `elicitation.url` | URL-mode elicitation |
| `session.configOptions.boolean` | `type: "boolean"` config options |

### Agent capabilities

([initialization](https://agentclientprotocol.com/protocol/v1/initialization)):

| Capability | Gates |
| --- | --- |
| `loadSession` | `session/load` |
| `promptCapabilities.image` | Image content in prompt blocks |
| `promptCapabilities.audio` | Audio content in prompt blocks |
| `promptCapabilities.embeddedContext` | Embedded resource content |
| `mcpCapabilities.http` | MCP over HTTP |
| `mcpCapabilities.sse` | MCP over SSE; annotated deprecated by the MCP spec |
| `auth.logout` | `logout` |
| `session.delete` | `session/delete` |
| `session.additionalDirectories` | Additional workspace roots |

Agent-side MCP servers are declared in `session/new`, not in `initialize`
([initialization](https://agentclientprotocol.com/protocol/v1/initialization)).

Terminal authentication is a **separate** field from terminal execution:
`clientCapabilities.auth.terminal` versus `clientCapabilities.terminal`
([authentication](https://agentclientprotocol.com/protocol/v1/authentication)).

### Extensions

`_meta` fields, custom methods prefixed with `_`, and custom capabilities
([v1 overview](https://agentclientprotocol.com/protocol/v1/overview)). v2 adds
`_`-prefixed unknown enum variants
([v2 migration](https://agentclientprotocol.com/protocol/v2/migration)).

Stabilized v1 extensions, with dates
([updates](https://agentclientprotocol.com/updates)):

| Date | Item |
| --- | --- |
| 2025-10-24 | Optional `clientInfo` and `agentInfo`, implementation telemetry at `initialize` |
| 2026-06-05 | `messageId` |
| 2026-06-05 | `usage_update` for context-window and cost reporting |
| 2026-06-24 | `session_config_options`, including `model_config` |
| 2026-07-06 | `type: "boolean"` config options |
| 2026-07-24 | Elicitation |
| 2026-09-17 | Programmatic tool-call `name` |

### The ACP Registry

An RFD by `@ignatov` with `@benbrandt` as champion. Draft 2025-11-28, final
revision 2026-02-04, status **Completed**
([registry RFD](https://agentclientprotocol.com/rfds/acp-agent-registry)). Announced
live in Zed's blog on 2026-01-28
([zed.dev/blog/acp-registry](https://zed.dev/blog/acp-registry)); the ACP updates
page records "ACP Registry is Released" on 2026-03-09
([updates](https://agentclientprotocol.com/updates)). The same launch post
announced that Zed's own Agent Extensions would be deprecated in favour of the
registry ([zed.dev/blog/acp-registry](https://zed.dev/blog/acp-registry)).

Repository: [agentclientprotocol/registry](https://github.com/agentclientprotocol/registry),
Apache-2.0, 409 stars, 103 open issues, 115 open pull requests on the research
date.

Layout: one directory per agent, each holding `agent.json` and an optional
16x16 monochrome SVG icon that uses `currentColor`
([registry RFD](https://agentclientprotocol.com/rfds/acp-agent-registry)).

Manifest schema
([registry RFD](https://agentclientprotocol.com/rfds/acp-agent-registry)):

| Field | Required | Constraint |
| --- | --- | --- |
| `id` | Yes | Must match `^[a-z][a-z0-9-]*$` |
| `name` | Yes | — |
| `version` | Yes | — |
| `description` | Yes | — |
| `distribution` | Yes | One of the three types below |
| `repository` | No | — |
| `authors` | No | — |
| `license` | No | — |
| `icon` | No | 16x16 monochrome SVG, `currentColor` |

Distribution types
([registry RFD](https://agentclientprotocol.com/rfds/acp-agent-registry)):

| Type | Detail |
| --- | --- |
| `binary` | 6 OS and architecture targets. **CI rejects entries that do not cover darwin, linux and windows.** |
| `npx` | npm-distributed |
| `uvx` | PyPI-distributed |

**Auth gate.** An agent must implement at least one auth method, `agent` or
`terminal`. CI performs a real ACP handshake against the entry and checks for a
non-empty `authMethods` array
([registry RFD](https://agentclientprotocol.com/rfds/acp-agent-registry)).

Build aggregates entries into `registry.json`, served at
`https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`. An hourly
cron bumps versions from npm, PyPI and GitHub releases
([registry repository](https://github.com/agentclientprotocol/registry)). JetBrains
additionally serves its own `registry-for-jetbrains.json` plus a preview channel
that is explicitly marked "not verified"
([registry repository](https://github.com/agentclientprotocol/registry)).

The registry is operated by the ACP project itself, that is by the Zed and
JetBrains maintainers. It is curated, not neutral
([registry repository](https://github.com/agentclientprotocol/registry)).

## What changed recently

| Date | Change | Source |
| --- | --- | --- |
| 2025-08-27 | ACP ships in Zed with Gemini CLI as reference implementation. Repository under `zed-industries`. | [launch post](https://zed.dev/blog/bring-your-own-agent-to-zed) |
| 2025-10-02 | Adoption snapshot published. | [progress report](https://zed.dev/blog/acp-progress-report) |
| between 2025-10-06 and 2025-10-13 | Repository and SDKs move to the `agentclientprotocol` org. | [CHANGELOG](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/CHANGELOG.md) |
| 2025-10-06 | JetBrains announced as co-developer, not adopter, across the whole IDE line. Governance becomes joint. | [zed.dev/blog/jetbrains-on-acp](https://zed.dev/blog/jetbrains-on-acp) |
| 2025-10-24 | Optional `clientInfo` and `agentInfo` added. | [updates](https://agentclientprotocol.com/updates) |
| 2025-12-16 | JetBrains states it will support multiple protocols rather than pick one. | [JetBrains blog](https://blog.jetbrains.com/ai/2025/12/agents-protocols-and-why-we-re-not-playing-favorites/) |
| 2026-01-28 | ACP Registry goes live. Zed's Agent Extensions deprecated in favour of it. | [zed.dev/blog/acp-registry](https://zed.dev/blog/acp-registry) |
| 2026-01-28 | GitHub Copilot CLI ACP public preview, `copilot --acp`, stdio and TCP. | [GitHub changelog](https://github.blog/changelog/2026-01-28-acp-support-in-copilot-cli-is-now-in-public-preview/) |
| 2026-02-04 | ACP Registry RFD final revision, status Completed. | [registry RFD](https://agentclientprotocol.com/rfds/acp-agent-registry) |
| 2026-02-18 | Sergey Ignatov of JetBrains becomes co-lead maintainer. | [updates](https://agentclientprotocol.com/updates) |
| 2026-02-04 to 2026-06-05 | Rapid RFD-to-stable cadence: session config options, `session/list`, `session_info_update`, additional workspace roots, `session/delete`, session usage and cost, message IDs, `model_config`. | [updates](https://agentclientprotocol.com/updates) |
| 2026-03-09 | Updates page records "ACP Registry is Released". | [updates](https://agentclientprotocol.com/updates) |
| 2026-04-22 | Transports Working Group formed for HTTP and WebSocket. Still draft. | [WG announcement](https://agentclientprotocol.com/announcements/transports-working-group) |
| 2026-06-01 | Unstable `session/set_model` removed. MAINTAINERS.md last updated. | [rfds/updates](https://agentclientprotocol.com/rfds/updates) |
| 2026-06-25 | Rust and TypeScript SDKs reach `1.0.0`. | [updates](https://agentclientprotocol.com/updates) |
| 2026-06-29 | `$/cancel_request` stabilized. | [updates](https://agentclientprotocol.com/updates) |
| 2026-07-02 | Agent Telemetry Export RFD deleted, because it assumed client-launched subprocesses. | [rfds/updates](https://agentclientprotocol.com/rfds/updates) |
| 2026-07-20 | ACP v2 published as Draft, after 15 or more RFDs landed non-breakingly on v1. Steering and queueing explicitly deferred. | [v2 announcement](https://agentclientprotocol.com/announcements/acp-v2-draft) |
| 2026-07-24 | Elicitation stabilized. | [updates](https://agentclientprotocol.com/updates) |
| 2026-07-27 | Experimental `env_var` auth method removed. | [rfds/updates](https://agentclientprotocol.com/rfds/updates) |
| 2026-09-17 | Programmatic tool-call `name` stabilized. | [updates](https://agentclientprotocol.com/updates) |
| 2026-09-18 | Crate release `1.9.1`. | [releases](https://github.com/agentclientprotocol/agent-client-protocol/releases) |
| 2026-09-23 to 2026-09-24 | Session Compaction and Session Notices RFDs reach Preview, which is unstable. | [rfds/updates](https://agentclientprotocol.com/rfds/updates) |

Apple shipped first-party support in Xcode 27, release note 178294840, "Xcode adds
support for the Agent Client protocol". Agent plug-ins can carry "skills, MCP
servers, and ACP agent configurations", release note 178289210
([Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)).

### The v2 draft

Author Ben Brandt. **Status: Draft**
([v2 announcement](https://agentclientprotocol.com/announcements/acp-v2-draft)).

| Property | Value |
| --- | --- |
| Schema release naming | `v2.0.0-alphaX` |
| Implementation guidance | Gate behind version negotiation **and** feature flags |
| Compatibility guidance | "v1-only peers will remain common for some time"; keep v1 working |
| Stabilization date | **NOT ESTABLISHED IN SOURCE** — none published |

([v2 announcement](https://agentclientprotocol.com/announcements/acp-v2-draft),
[v2 overview RFD](https://agentclientprotocol.com/rfds/v2/overview))

The five themes, as enumerated in the body of the v2 overview RFD
([v2 overview](https://agentclientprotocol.com/rfds/v2/overview)):

1. **Beyond the turn.** `session/prompt` returns the `messageId` of the inserted
   user message instead of `stopReason`. Progress and completion move into
   `session/update` through a new `state_update` carrying `running`, `idle` or
   `requires_action`. `session/update` may fire at any time in a session, not only
   inside a turn.
2. **Uniform upserts.** Messages, tool calls, plans and terminal output all patch
   by stable ID with identical omit, `null`, replace and append semantics.
   The `tool_call` variant is **removed**; the first `tool_call_update` creates
   the call. A new `tool_call_content_chunk` variant is added. Message IDs
   become required.
3. **Diff overhaul.** `oldText` and `newText` are replaced by structured file
   states: add, delete, modify, move, copy and non-text, plus an optional
   renderable `git_patch`.
4. **Flexible permissions.** A required `title`, an optional `description`, and
   an optional extensible `subject` union: `type: "tool_call"` or
   `type: "command"` with a required `command` and an absolute `cwd`. This
   decouples prompt copy from tool-call patch state
   ([permission-requests RFD](https://agentclientprotocol.com/rfds/v2/permission-requests)).
5. **Forward compatibility by default.** `_`-prefixed unknown enum variants
   everywhere, and capability support markers become **objects, not booleans**
   (`{}` means supported).

Note on source disagreement: the documentation index entry for the v2 draft
announcement summarises the same page as "the four big themes", while the body of
that page enumerates five. The five-item list is the one used here
([v2 announcement](https://agentclientprotocol.com/announcements/acp-v2-draft)).

Removals
([v2 migration](https://agentclientprotocol.com/protocol/v2/migration)):

| Removed in v2 | Replacement |
| --- | --- |
| `session/load` | `session/resume` with `replayFrom: {type: "start"}` |
| `session/set_mode`, all `SessionMode*`, `current_mode_update` | Config options |
| **All `fs/*` and `terminal/*` client methods and their capabilities** | None; agents own their own execution |
| `agentCapabilities.auth.logout` | `auth/logout` gated purely on a non-empty `authMethods` |
| Deprecated MCP HTTP and SSE | MCP transports realigned |
| Role-specific `clientInfo` and `agentInfo` | One required, role-agnostic `info` |

Additions
([v2 overview](https://agentclientprotocol.com/rfds/v2/overview)):

| Added in v2 | Detail |
| --- | --- |
| Agent-owned terminal output | Display-only: `terminal_update`, `terminal_output_chunk`, base64 chunks, replay snapshots |
| `session.mcp.stdio` | Explicit |
| `auth/login` and `auth/logout` | Gated purely on a non-empty `authMethods` |
| Required baseline method set | `session/new`, `session/list`, `session/resume`, `session/close`, `session/prompt`, `session/cancel`, `session/update`, required whenever `capabilities.session` is present |

**The contentious change: removal of the client filesystem and terminal surface.**
Brandt's stated rationale is that "this hasn't been widely adopted… even then, IDE
support has been mixed… most stuck to their standard implementations", and that
agents are moving to their own sandboxing
([filesystem/terminal RFD](https://agentclientprotocol.com/rfds/v2/client-filesystem-terminal-capabilities)).
The RFD instructs adapters to **reject**, not silently drop, advertised `fs` and
`terminal` support, and states that v1 and v2 terminal references are ownership-
and lifetime-incompatible
([filesystem/terminal RFD](https://agentclientprotocol.com/rfds/v2/client-filesystem-terminal-capabilities)).

This collides with JetBrains' published position from 2025-10: "your IDE will
mediate access to files, the terminal, and other tools via the ACP protocol — you
decide what runs"
([JetBrains blog](https://blog.jetbrains.com/ai/2025/10/jetbrains-zed-open-interoperability-for-ai-coding-agents-in-your-ide/)).

Unresolved in the draft
([v2 migration](https://agentclientprotocol.com/protocol/v2/migration)):

- The Rust schema provides **no cross-version conversion**, so every SDK must
  build adapters at the runtime boundary.
- `capabilities.session` was made optional for non-session, NES-only agents, even
  though the migration guide concedes "currently there isn't protocol support for
  this".
- Steering and queueing were explicitly deferred on 2026-07-20: "`idle` means
  ready for a new prompt while background updates may continue; steering and
  queueing remain separate concerns".

## Evidence of adoption

### Clients

| Client | Relationship to ACP | Evidence |
| --- | --- | --- |
| Zed | First-party, the originating client | [launch post](https://zed.dev/blog/bring-your-own-agent-to-zed) |
| JetBrains IDEs | First-party and shipped. AI Assistant 2026.2 documents registry install, custom agents via `~/.jetbrains/acp.json`, and states you can connect and use ACP-compatible agents without a JetBrains AI service subscription. WSL unsupported; page built 2026-09-14. | [JetBrains help](https://www.jetbrains.com/help/ai-assistant/acp.html) |
| Xcode 27 | First-party, from Apple | [Xcode release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) |
| Microsoft Intelligent Terminal | A Windows Terminal fork that drives ACP over stdio | [client directory](https://agentclientprotocol.com/get-started/clients) |
| Neovim | Four community plugins: CodeCompanion, agentic.nvim, avante.nvim, hermes.nvim | [client directory](https://agentclientprotocol.com/get-started/clients) |
| Emacs | agent-shell.el | [client directory](https://agentclientprotocol.com/get-started/clients) |
| Qt Creator | Official Qt ACP Client Plugin | [client directory](https://agentclientprotocol.com/get-started/clients) |
| Sublime Text, Pulsar, Obsidian, marimo, DuckDB, Unity (two plugins), a Chrome extension, Anycode | Community | [client directory](https://agentclientprotocol.com/get-started/clients) |
| **VS Code** | **No first-party support.** Only five third-party marketplace extensions; Zed links `microsoft/vscode#265496` as an open request. | [client directory](https://agentclientprotocol.com/get-started/clients) |

The official client directory holds roughly 120 entries spanning desktop, web,
mobile and messaging clients, plus framework adapters including LangChain Deep
Agents, LlamaIndex, Mastra, Koog, AgentOS/Rivet, fast-agent and AgentPool
([client directory](https://agentclientprotocol.com/get-started/clients)).

Xcode appears in the Apple release notes but is **absent** from the official client
directory
([client directory](https://agentclientprotocol.com/get-started/clients)). Which
list is authoritative for listings is **NOT ESTABLISHED IN SOURCE**.

### Agents

First-party implementations
([registry](https://agentclientprotocol.com/registry),
[agent directory](https://agentclientprotocol.com/get-started/agents)):

Gemini CLI, GitHub Copilot CLI, Cursor agent CLI (`2026.09.26`), Cognition Devin
CLI (`3000.11.3`), Block Goose, JetBrains Junie (`3419.16.0`), OpenCode, Cline,
Qwen Code, Kilo, Factory Droid, Mistral Vibe, Kimi CLI, Auggie, Codebuddy
(Tencent), Cortex Code (Snowflake), Poolside, Stakpak, Kiro CLI, OpenHands, Docker
cagent.

Not first-party, and this is the material correction:

| Agent | Actual state |
| --- | --- |
| **Claude Code** | Does not implement ACP. A third-party adapter maintained inside the ACP org: [`agentclientprotocol/claude-agent-acp`](https://github.com/agentclientprotocol/claude-agent-acp), 2,592 stars, registry version `0.84.0`. Upstream request [anthropics/claude-code#6686](https://github.com/anthropics/claude-code/issues/6686) open. |
| **Codex** | Does not implement ACP. A third-party adapter maintained inside the ACP org: [`agentclientprotocol/codex-acp`](https://github.com/agentclientprotocol/codex-acp), 417 stars, version `2.0.0`. Upstream request [openai/codex#2785](https://github.com/openai/codex/issues/2785) open. |

Zed's launch post described the Claude path as "Zed's SDK adapter"
([launch post](https://zed.dev/blog/bring-your-own-agent-to-zed)). The official
agent directory now shows both as adapters
([agent directory](https://agentclientprotocol.com/get-started/agents)).

### The 35-agent protocol probe

The registry's daily CI protocol matrix, run 2026-09-29
([`.protocol-matrix/latest.md`](https://raw.githubusercontent.com/agentclientprotocol/registry/main/.protocol-matrix/latest.md)):

| Measurement | Value |
| --- | --- |
| Agents probed | 35 |
| `initialize` succeeded | 34 of 35; `cortex-code` returned `proc_err` |
| Returned `auth_required` on `session/new` | 22 |
| Support `session/list` | 22 |
| Support `session/resume` | 12 |
| Support `session/set_model` | 17 |
| Support `session/fork` | 9 |
| Support `session/stop` | 0 |

`session/fork`, `session/set_model` and `session/stop` are **not** in the
documented v1 method set. Whether `session/fork` is an unstabilized RFD addition
or an out-of-band extension is **NOT ESTABLISHED IN SOURCE**; the docs index
lists about 50 RFDs
([llms.txt](https://agentclientprotocol.com/llms.txt)), and `session/fork` does
not appear on the stabilized announcements list
([rfds/updates](https://agentclientprotocol.com/rfds/updates)).

## Sharp edges

1. **Governance is still two-company interim.** Two BDFL lead maintainers, one per
   vendor, with veto over all core decisions, and an explicit intent to move to an
   independent foundation with no date and no published process. Security triage
   is Zed-only ([governance](https://agentclientprotocol.com/community/governance)).

2. **Remote and cloud agents are not actually supported.** stdio is the only
   normative transport; HTTP is still "In discussion, draft proposal in progress"
   more than a year after a dedicated working group formed on 2026-04-22. The
   Agent Telemetry Export RFD was **deleted** on 2026-07-02 precisely because it
   assumed client-launched subprocesses
   ([rfds/updates](https://agentclientprotocol.com/rfds/updates)). This is the
   largest gap against what vendors want to ship.

3. **v2 removes the IDE-mediated filesystem and terminal surface**, which is the
   core of JetBrains' stated differentiation, and mandates that adapters *reject*
   rather than translate. There is no migration path offered for IDEs built on that
   surface
   ([filesystem/terminal RFD](https://agentclientprotocol.com/rfds/v2/client-filesystem-terminal-capabilities),
   [JetBrains blog](https://blog.jetbrains.com/ai/2025/10/jetbrains-zed-open-interoperability-for-ai-coding-agents-in-your-ide/)).

4. **Permanent dual implementation.** v1 must be maintained indefinitely, the Rust
   schema provides no cross-version conversion, and the "note that the two
   terminal models are incompatible" warning recurs. Every SDK and every agent
   ships two code paths
   ([v2 migration](https://agentclientprotocol.com/protocol/v2/migration)).

5. **Version confusion is by design.** Wire `protocolVersion: 1`, crate `1.9.1`,
   v1 schema `v1.23.0` and v2 schema `v2.0.0-alpha.5` are four different numbers
   moving on four different cadences. The README warns against inferring wire
   compatibility from artifact versions
   ([README](https://github.com/agentclientprotocol/agent-client-protocol)).

6. **Measurable specification and implementation drift.**
   `session/set_model`, an unstable API removed 2026-06-01, is still answered by
   17 of 35 probed agents. The experimental `env_var` auth method, removed
   2026-07-27, is still advertised by 2 of 35. `session/fork`, whose RFD is not on
   the stabilized announcements list, is already exposed by 9 of 35
   ([rfds/updates](https://agentclientprotocol.com/rfds/updates),
   [protocol matrix](https://raw.githubusercontent.com/agentclientprotocol/registry/main/.protocol-matrix/latest.md)).

7. **Elicitation deliberately diverges from MCP.** ACP states it: "This
   deliberately differs from the MCP 2026-07-28 release candidate, where an empty
   elicitation capability retains the original form-only meaning. ACP requires each
   supported mode to be explicit"
   ([elicitation](https://agentclientprotocol.com/protocol/v1/elicitation)).
   Assumptions carried over from MCP break under ACP.

8. **`terminal` is a name collision.** `clientCapabilities.terminal` means
   execution; `clientCapabilities.auth.terminal` means authentication. The v2 RFD
   needed a dedicated FAQ entry to disambiguate them, and stable v2 keeps only the
   authentication one
   ([authentication](https://agentclientprotocol.com/protocol/v1/authentication),
   [filesystem/terminal RFD](https://agentclientprotocol.com/rfds/v2/client-filesystem-terminal-capabilities)).

9. **The registry is a curated choke point operated by the two governing
   companies.** Its CI really launches agents to verify that an auth method
   exists, which makes it a genuine distribution moat and a governance
   concentration at the same time. JetBrains further forks its own index plus an
   unverified preview channel, and the registry supersedes Zed's own Agent
   Extensions
   ([registry repository](https://github.com/agentclientprotocol/registry),
   [zed.dev/blog/acp-registry](https://zed.dev/blog/acp-registry)).

10. **The moat is distribution, not upstream support.** The two most-used agents,
    Claude Code and Codex, still do not ship ACP and rely on adapters maintained
    inside the ACP org. Microsoft shipped a competing GitHub-centric stack,
    AgentHQ, in Dec 2025. JetBrains has publicly said it will "support multiple
    protocols"
    ([agent directory](https://agentclientprotocol.com/get-started/agents),
    [JetBrains blog](https://blog.jetbrains.com/ai/2025/12/agents-protocols-and-why-we-re-not-playing-favorites/)).

11. **No foundation home.** AAIF exists and hosts MCP, goose, AGENTS.md,
    agentgateway, Agent Router and, since 2026-08-17, A2A, but not ACP
    ([aaif.io/projects](https://aaif.io/projects),
    [A2A joins AAIF](https://aaif.io/blog/a2a-joins-aaif)).

12. **The specification surface is unusually wide and fast-moving.** About 50
    RFDs in 13 months, four lifecycle stages including a `Preview` tier that is
    explicitly unstable, and two features — Session Compaction and Session
    Notices — sitting in Preview on the research date
    ([llms.txt](https://agentclientprotocol.com/llms.txt),
    [rfds/updates](https://agentclientprotocol.com/rfds/updates)).

## Sources

### Specification and code

- [agentclientprotocol.com/get-started/introduction](https://agentclientprotocol.com/get-started/introduction) — role of ACP, stdio versus remote, remote-agent support explicitly incomplete
- [agentclientprotocol.com/llms.txt](https://agentclientprotocol.com/llms.txt) — authoritative page inventory: v1 and v2 doc trees, 5 SDKs, about 50 RFDs, 21 announcements
- [agentclientprotocol.com/updates](https://agentclientprotocol.com/updates) — dated announcement timeline 2025-10-24 to 2026-09-17
- [agentclientprotocol.com/rfds/updates](https://agentclientprotocol.com/rfds/updates) — RFD lifecycle stages and dated removals and previews
- [agentclientprotocol.com/protocol/v1/overview](https://agentclientprotocol.com/protocol/v1/overview) — v1 method set, baseline versus optional, session lifecycle, extensibility rules
- [agentclientprotocol.com/protocol/v1/initialization](https://agentclientprotocol.com/protocol/v1/initialization) — `protocolVersion` negotiation and both capability sets
- [agentclientprotocol.com/protocol/v1/transports](https://agentclientprotocol.com/protocol/v1/transports) — stdio normative, HTTP draft only
- [agentclientprotocol.com/protocol/v1/tool-calls](https://agentclientprotocol.com/protocol/v1/tool-calls) — `session/request_permission` shape, permission option kinds, tool-call fields
- [agentclientprotocol.com/protocol/v1/elicitation](https://agentclientprotocol.com/protocol/v1/elicitation) — form and url modes, explicit divergence from MCP, secret rules
- [agentclientprotocol.com/protocol/v1/authentication](https://agentclientprotocol.com/protocol/v1/authentication) — `authMethods`, agent versus terminal flows, logout
- [agentclientprotocol.com/community/governance](https://agentclientprotocol.com/community/governance) — interim joint Zed and JetBrains governance, BDFL veto, "working toward transitioning to an independent foundation", Apache-2.0 with no CLA, `security@zed.dev`
- [agentclientprotocol.com/community/working-interest-groups](https://agentclientprotocol.com/community/working-interest-groups) — group mechanics, 72-hour core-maintainer vote
- [agentclientprotocol.com/announcements/transports-working-group](https://agentclientprotocol.com/announcements/transports-working-group) — 2026-04-22 working group, Anna Zhdan and Alex Hancock
- [github.com/agentclientprotocol/agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol) — "The current stable ACP protocol version is 1"; the artifact-versus-wire version warning; repository layout
- [MAINTAINERS.md](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/MAINTAINERS.md) — leads, core maintainers, transports working group leads; last updated 2026-06-01
- [CHANGELOG.md](https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/main/CHANGELOG.md) — release history; the neutral org in place by 2025-10-13
- [releases](https://github.com/agentclientprotocol/agent-client-protocol/releases) — `v1.9.1`, `schema-v1.23.0`, `schema-v2.0.0-alpha.5`
- [github.com/agentclientprotocol](https://github.com/agentclientprotocol) — domain-verified organisation, 15 repositories

### v2

- [announcements/acp-v2-draft](https://agentclientprotocol.com/announcements/acp-v2-draft) — draft status, themes, alpha naming, "do not ship by default"
- [rfds/v2/overview](https://agentclientprotocol.com/rfds/v2/overview) — full breaking-change list, capability reorganisation, dated revision history back to 2026-05-06
- [protocol/v2/migration](https://agentclientprotocol.com/protocol/v2/migration) — method and `sessionUpdate` diff tables, adapter rejection rules, no cross-version conversion
- [rfds/v2/client-filesystem-terminal-capabilities](https://agentclientprotocol.com/rfds/v2/client-filesystem-terminal-capabilities) — the contentious removal, stated rationale, incompatibility warning
- [rfds/v2/permission-requests](https://agentclientprotocol.com/rfds/v2/permission-requests) — v2 permission `title` and `subject` union
- [protocol/v2/overview](https://agentclientprotocol.com/protocol/v2/overview) — v2 baseline method set and the `state_update` lifecycle

### Registry

- [rfds/acp-agent-registry](https://agentclientprotocol.com/rfds/acp-agent-registry) — manifest schema, distribution types, icon rules, auth gate
- [github.com/agentclientprotocol/registry](https://github.com/agentclientprotocol/registry) — JetBrains-specific index, unverified preview channel, hourly version cron
- [protocol matrix, 2026-09-29](https://raw.githubusercontent.com/agentclientprotocol/registry/main/.protocol-matrix/latest.md) — 35 agents probed, 34 `initialize` OK, per-method support counts
- [agentclientprotocol.com/registry](https://agentclientprotocol.com/registry) — curated agent list with versions

### Directories

- [get-started/agents](https://agentclientprotocol.com/get-started/agents) — official agent directory; Claude Code and Codex shown as adapters
- [get-started/clients](https://agentclientprotocol.com/get-started/clients) — official client directory; Xcode absent, VS Code third-party only

### Vendor and foundation primary sources

- [zed.dev/blog/bring-your-own-agent-to-zed](https://zed.dev/blog/bring-your-own-agent-to-zed) — 2025-08-27 launch with Gemini CLI, original `zed-industries` repository
- [zed.dev/blog/acp-progress-report](https://zed.dev/blog/acp-progress-report) — 2025-10-02 adoption snapshot
- [zed.dev/blog/jetbrains-on-acp](https://zed.dev/blog/jetbrains-on-acp) — 2025-10-06 JetBrains as co-developer
- [zed.dev/blog/acp-registry](https://zed.dev/blog/acp-registry) — 2026-01-28 registry launch and Agent Extensions deprecation
- [JetBrains, interoperability announcement](https://blog.jetbrains.com/ai/2025/10/jetbrains-zed-open-interoperability-for-ai-coding-agents-in-your-ide/) — "your IDE will mediate access to files, the terminal, and other tools via the ACP protocol"
- [JetBrains, multiple protocols](https://blog.jetbrains.com/ai/2025/12/agents-protocols-and-why-we-re-not-playing-favorites/) — 2025-12-16 stance against AgentHQ
- [JetBrains AI Assistant ACP help](https://www.jetbrains.com/help/ai-assistant/acp.html) — shipped in AI Assistant 2026.2, registry install, `acp.json`, WSL limitation; page built 2026-09-14
- [GitHub changelog, 2026-01-28](https://github.blog/changelog/2026-01-28-acp-support-in-copilot-cli-is-now-in-public-preview/) — Copilot CLI public preview, `copilot --acp` over stdio and TCP
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) — "Xcode adds support for the Agent Client protocol" (178294840); ACP agent configurations in plug-ins (178289210)
- [aaif.io/projects](https://aaif.io/projects) — the AAIF project list; no ACP
- [aaif.io/blog/a2a-joins-aaif](https://aaif.io/blog/a2a-joins-aaif) — 2026-08-17, A2A joins AAIF as Growth Stage
