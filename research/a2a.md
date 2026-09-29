# Agent2Agent (A2A) — agent to agent

Evidence about the Agent2Agent protocol: the released specification revision and the
divergence between the release tag and the documentation site, its move from the Linux
Foundation to the Agentic AI Foundation, the three-layer architecture, the eleven
operations and their three standard bindings, the Task lifecycle and data model, the
Agent Card and signed cards, the extension and custom-binding governance, the
authentication model and in-task authorization, the published version of every
official SDK, dated adoption evidence, and the sharp edges including the
specification's internal contradictions. The Agent Payments Protocol, which A2A is
frequently cited alongside, is out of scope; it has its own document.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

### The spec site and the repo disagree about the current release

The documentation site labels **1.0.0** as the "Latest Released Version"
([specification](https://a2a-protocol.org/latest/specification/)). The repository has
shipped **v1.0.1 since 2026-05-26** (GitHub published the tag 2026-05-28), and there
is no pinned 1.0.1 page: `https://a2a-protocol.org/v1.0.1/specification/` 302-redirects
to `/latest/`. `/latest/` therefore tracks the repository `main` branch, not the
released tag, and carries unreleased post-1.0.1 edits. Anything cited from `/latest/`
must be attributed to `main`, not to v1.0.1.

| Revision | Date | Status on 2026-09-29 | Source |
| --- | --- | --- | --- |
| `1.0.0` | tagged 2026-03-12, published 2026-03-12T16:34:41Z | Labeled "latest" by the site; has a pinned page | [releases](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15), [v1.0.0 spec](https://a2a-protocol.org/v1.0.0/specification/) |
| `v1.0.1` | changelog 2026-05-26, published 2026-05-28 | Shipped; **no pinned page**; reachable only through `/latest/` or the tag | [releases](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15) |
| `0.3.0` | 2025-07-30 | Pre-1.0, pinned page exists | [v0.3.0 spec](https://a2a-protocol.org/v0.3.0/specification/) |
| `0.2.6` | 2025-07-17 | Pre-1.0 | [releases](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15) |
| `0.1.0` | — | Pre-1.0; date NOT ESTABLISHED IN SOURCE | — |

v1.0.1 contains three spec-only fixes and no other content changes: "prefer
`application/a2a+json` in HTTP binding" (#1753), "recent transcoding-related error
changes" (#1627), and "TaskStatus values in the specification" (#1801)
([releases](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15)).

The v1.0.0 announcement calls 1.0 "the first stable, production-ready version"
([v1.0 launch post](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/)).
Conformance tooling exists but is young, and the extension namespace is empty.

### Normative source

Section 1.4 of the specification declares `specification/a2a.proto` the single
authoritative normative definition of all data objects and request/response messages
([specification](https://a2a-protocol.org/latest/specification/)). Two consequences for
any reimplementation:

- `specification/json/a2a.json` is generated at build time, is not committed, and is
  explicitly non-normative. A pinned JSON schema is NOT ESTABLISHED IN SOURCE as a
  published artifact.
- SDK bindings and JSON schemas MUST be regenerated from the proto.
- JSON serialization follows ProtoJSON per ADR-001: camelCase field names, ProtoJSON
  enum spellings, `google.protobuf.Timestamp` as ISO-8601 UTC.

### Governance

A2A ran under the Linux Foundation from June 2025, contributed by Google
([Google Cloud, 2025-08-01](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade);
[AAIF, 2026-08-17](https://aaif.io/blog/a2a-joins-aaif)). Since **2026-08-17** it is
hosted by the **Agentic AI Foundation**, a neutral foundation under the Linux
Foundation, as a **Growth Stage** project
([AAIF announcement](https://aaif.io/blog/a2a-joins-aaif);
[A2A-side announcement, 2026-08-27](https://a2a-protocol.org/latest/blog/2026/08/27/a-new-chapter-for-a2a-joining-the-agentic-ai-foundation/)),
alongside MCP, goose, AGENTS.md, and agentgateway
([AAIF about](https://aaif.io/about)). IBM's Agent Communication Protocol merged into
A2A in August 2025, per the [AAIF post](https://aaif.io/blog/a2a-joins-aaif).

The A2A Technical Steering Committee has 8 company seats, read from `GOVERNANCE.md` on
`main` on 2026-09-29 ([GOVERNANCE.md](https://raw.githubusercontent.com/a2aproject/A2A/main/GOVERNANCE.md)):

| Seat | Representative |
| --- | --- |
| Google | Todd Segal |
| Microsoft | Darrel Miller |
| Cisco | Luca Muscariello |
| AWS | Abhimanyu Siwach |
| Salesforce | Stephen Petschulat |
| ServiceNow | Sugandh Rakha |
| SAP | Sivakumar N. |
| IBM | Stefano Maestri |

Quorum is 50%, with a majority of those present. The TSC decides the "steady state"
composition 18 months after inception. `GOVERNANCE.md` has not been rewritten for AAIF
as of 2026-09-29, so whether the 8-seat A2A TSC survives the transition unchanged is
`[UNVERIFIED]`.

### Repository

[github.com/a2aproject/A2A](https://github.com/a2aproject/A2A), Apache-2.0, 25,963
stars, 2,637 forks, 265 open issues, last push 2026-09-25.

## What it does

### Three layers

The specification's §1.3 defines three layers
([specification](https://a2a-protocol.org/latest/specification/)):

| Layer | Content |
| --- | --- |
| L1 | Canonical data model as Protocol Buffers messages (`specification/a2a.proto`) |
| L2 | Eleven binding-independent abstract operations |
| L3 | Protocol bindings mapping L2 onto wire encodings |

The stated purpose of the layering is that "new protocol bindings can be added without
changing the fundamental data model."

### Operations and bindings

All eleven operations, with the mapping from specification §5.3
([specification](https://a2a-protocol.org/latest/specification/)). Method names are
PascalCase; the 0.3 slash form (`message/send`) is gone. The gRPC service is
`A2AService`.

| Functionality | JSON-RPC | gRPC | REST |
| --- | --- | --- | --- |
| Send message | `SendMessage` | `SendMessage` | `POST /message:send` |
| Send streaming message | `SendStreamingMessage` | `SendStreamingMessage` (server stream) | `POST /message:stream` |
| Get task | `GetTask` | `GetTask` | `GET /tasks/{id}` |
| List tasks | `ListTasks` | `ListTasks` | `GET /tasks` |
| Cancel task | `CancelTask` | `CancelTask` | `POST /tasks/{id}:cancel` |
| Subscribe to task | `SubscribeToTask` | `SubscribeToTask` (server stream) | `POST /tasks/{id}:subscribe` |
| Create push config | `CreateTaskPushNotificationConfig` | `CreateTaskPushNotificationConfig` | `POST /tasks/{id}/pushNotificationConfigs` |
| Get push config | `GetTaskPushNotificationConfig` | `GetTaskPushNotificationConfig` | `GET /tasks/{id}/pushNotificationConfigs/{configId}` |
| List push configs | `ListTaskPushNotificationConfigs` | `ListTaskPushNotificationConfigs` | `GET /tasks/{id}/pushNotificationConfigs` |
| Delete push config | `DeleteTaskPushNotificationConfig` | `DeleteTaskPushNotificationConfig` | `DELETE /tasks/{id}/pushNotificationConfigs/{configId}` |
| Get extended Agent Card | `GetExtendedAgentCard` | `GetExtendedAgentCard` | `GET /extendedAgentCard` |

There is no JSON-RPC `agent/getAuthenticatedExtendedCard` and no
`tasks/pushNotificationConfig/*` in 1.0. A fourth path exists for custom bindings
(§5.8, §12) but has no fixed method names.

The error model moved to `google.rpc.Status` / `google.rpc.ErrorInfo`, with `reason`
plus a `domain` of `a2a-protocol.org`, replacing RFC 9457 problem details. Nine A2A
error codes occupy the JSON-RPC `-32001`..`-32009` range. Two names appear explicitly
in the material read: `ExtensionSupportRequiredError` (`-32008`) and
`VersionNotSupportedError` (`-32009`, with `FAILED_PRECONDITION` and HTTP 400).
`UnsupportedOperationError` is used in the specification text without a code in the
material read. The full nine-entry name-to-code table is NOT ESTABLISHED IN SOURCE.

### Bindings are peers, and none is mandatory

The three bindings are specified in §9 (JSON-RPC over HTTP), §10 (gRPC/protobuf), and
§11 (HTTP+JSON/REST), plus the governed custom-binding path in §12
([specification](https://a2a-protocol.org/latest/specification/)). **The specification
designates no mandatory binding.** There is no "MUST implement JSON-RPC" clause.

- §5.1 requires functional equivalence across whatever a given agent declares:
  identical functionality, consistent behaviour, the same error mapping, and equivalent
  authentication.
- §5.2: agents MUST declare all supported protocols; clients MAY choose any declared
  one and SHOULD implement fallback.
- §8.3.2 selection rule: parse `supportedInterfaces`, select the first supported entry,
  prefer earlier entries, use that entry's `url`, and set `tenant` on every request to
  exactly the value declared on the selected entry.

Each `supportedInterfaces[]` entry carries its own `url`, `protocolBinding`,
`protocolVersion`, and optional `tenant`. The `/v1` path prefix was removed from REST
paths (#1269); the version may instead live in the operator's base URL, for example
`https://host/a2a/v1`.

Push notification webhooks are always plain HTTP carrying the JSON payload of the HTTP
binding, regardless of the agent's own binding: "regardless of the protocol binding
being used by the agent, WebHook calls use plain HTTP and the JSON payloads as defined
in the HTTP protocol binding" (§3.5.1).

### Version negotiation

`protocolVersion` moved off the Agent Card onto each `AgentInterface`, which is a
breaking change. It is negotiated with the `A2A-Version` service parameter, a
comma-free `Major.Minor` value transmittable as an HTTP header or as a query parameter
(`?A2A-Version=1.0`). Clients MUST send it on every request. **An empty value is
interpreted as 0.3**, an explicit back-compat rule for 0.3 clients. An unsupported
version returns `VersionNotSupportedError`. Patch versions MUST NOT be used in
requests, responses, or Agent Cards.

### Task lifecycle

States: `TASK_STATE_UNSPECIFIED`, `SUBMITTED`, `WORKING`, `COMPLETED`, `FAILED`,
`CANCELED`, `INPUT_REQUIRED`, `REJECTED`, `AUTH_REQUIRED`. Terminal states are
`COMPLETED`, `FAILED`, `CANCELED`, `REJECTED`; interrupted states are
`INPUT_REQUIRED` and `AUTH_REQUIRED`.

Clients MUST reject a message whose `contextId` disagrees with the referenced task's
`contextId`. `taskId` is server-generated; client-supplied task IDs for new tasks are
not supported. "Canceled" uses the American spelling, standardized in v1.0 (#1283).

`ListTasks` is new in 1.0, with filtering by `contextId`, `status`,
`statusTimestampAfter`, and `includeArtifacts`, and cursor pagination: `pageSize` 1–100
(default at most 50), `pageToken` and `nextPageToken` always present, plus `totalSize`.

### Data model

From the specification
([specification](https://a2a-protocol.org/latest/specification/)):

| Type | Fields |
| --- | --- |
| `Task` | `id`, `contextId`, `status`, `artifacts[]`, `history[]`, `metadata` |
| `TaskStatus` | `state`, `message`, `timestamp` |
| `Message` | `messageId`, `contextId`, `taskId`, `role`, `parts[]`, `metadata`, `extensions[]`, `referenceTaskIds[]` |
| `Part` | oneof over `text \| raw(bytes) \| url \| data`, plus `metadata`, `filename`, `mediaType` |
| `Artifact` | `artifactId`, `name`, `description`, `parts[]`, `metadata`, `extensions[]` |
| `StreamResponse` | oneof over `task \| message \| statusUpdate \| artifactUpdate` |
| `TaskStatusUpdateEvent` | `taskId`, `contextId`, `status`, `metadata` |
| `TaskArtifactUpdateEvent` | `taskId`, `contextId`, `artifact`, `append`, `lastChunk`, `metadata` |

`Role` is now `ROLE_USER` / `ROLE_AGENT`, previously `"user"` / `"agent"`. `Part` is a
single unified message: the `kind` discriminator, the separate `TextPart` / `FilePart` /
`DataPart` types, and the nested `file` object are all removed, and `mimeType` becomes
`mediaType`. `final` is removed from `TaskStatusUpdateEvent`; stream closure is the
terminal signal. Enums moved to SCREAMING_SNAKE_CASE with type prefixes.

IDs were simplified from compound resource names to plain literals (#1389), with parent
and resource IDs split into separate fields. `TaskPushNotificationConfig` and
`PushNotificationConfig` were merged and flattened (#1500).

### Agent Card

Served at `GET https://{domain}/.well-known/agent-card.json`. The path changed from
`agent.json` in 0.3.0 (#841)
([specification](https://a2a-protocol.org/latest/specification/)). Caching guidance:
`Cache-Control`, an `ETag` derived from `version` or a content hash, optional
`Last-Modified`; clients SHOULD use conditional requests per RFC 9111.

| Status | Fields |
| --- | --- |
| Required | `name`, `description`, `supportedInterfaces[]`, `version`, `capabilities`, `defaultInputModes[]`, `defaultOutputModes[]`, `skills[]` |
| Optional | `provider`, `documentationUrl`, `securitySchemes` (map), `securityRequirements` (array), `signatures` (JWS), `iconUrl` |
| Removed vs 0.3 | top-level `url`, `protocolVersion`, `preferredTransport`, `additionalInterfaces`, `supportsAuthenticatedExtendedCard` |

`AgentCapabilities` carries `streaming`, `pushNotifications`, `extensions[]`, and
`extendedAgentCard`. The 0.3 field `supportsAuthenticatedExtendedCard` became
`AgentCapabilities.extendedAgentCard`; the proto field number 13 was removed and
`AgentCapabilities` field 5 added.

Signed Agent Cards are new in 1.0: JWS (RFC 7515) over an RFC 8785 JCS canonicalization,
with the `signatures` field excluded from the signed payload, `jku` for JWKS retrieval,
and protobuf field-presence rules governing what gets canonicalized
([whats-new-v1](https://a2a-protocol.org/latest/whats-new-v1/)).

### Extensions and custom bindings

Declaration is `AgentCard.capabilities.extensions[]` of
`AgentExtension{uri, description, required, params}`. Activation is the
`A2A-Extensions` service parameter, a comma-separated URI list. Unsupported requests are
ignored; the response SHOULD echo `A2A-Extensions` with what was activated
([extensions](https://a2a-protocol.org/latest/topics/extensions/)).

- Extension URIs SHOULD carry a version (`.../v1`). A breaking change MUST use a new
  URI, and the agent MUST NOT silently fall back to another version.
- Extension points: `Message.extensions[]`, `Artifact.extensions[]`, and the
  `metadata` map keyed by extension URI for strongly typed payloads.
- `required: true` makes the agent return `ExtensionSupportRequiredError` (`-32008`)
  when the client did not declare support.
- Extensions MAY add data, profile semantics, new RPC methods ("extended skills"), or
  new task states. Extensions MAY NOT change core data-structure definitions or add
  enum values.

Governance is two-tier
([extension and binding governance](https://a2a-protocol.org/latest/topics/extension-and-binding-governance/)),
with custom bindings governed alongside
([custom protocol bindings](https://a2a-protocol.org/latest/topics/custom-protocol-bindings/)):

| Artefact | Official namespace | Repository name | Graduation requires |
| --- | --- | --- | --- |
| Extension | `https://a2a-protocol.org/extensions/` | `ext-{name}` | Maintainer sponsor, production-quality reference implementation, TSC vote at 50% quorum |
| Experimental extension | same prefix | `experimental-ext-{name}` | — |
| Custom binding | `https://a2a-protocol.org/bindings/` | `cpb-{name}` | same |
| Experimental binding | same prefix | `experimental-cpb-{name}` | — |

**The official extension and binding namespaces are empty as of 2026-09-29.** The only
two artefacts in the `a2aproject` organisation are experimental
([org repository list](https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated)):

| Repository | Purpose | Created | Stars |
| --- | --- | --- | --- |
| `experimental-ext-oid4vp-auth` | OID4VP In-Task Authorization Extension for A2A | 2026-05-14 | 5 |
| `experimental-cpb-slimrpc` | SLIMRPC custom protocol binding for A2A | 2026-05-14 | 9 |

The documentation's "List of Example Extensions" points at sample extensions in
`a2a-samples` (secure-passport, timestamp, traceability, agp), not at the official
namespace ([extensions](https://a2a-protocol.org/latest/topics/extensions/)). Third
party extensions named in the Google Developers Blog of 2025-09-09: Twilio
latency-aware agent selection, Identity Machines IronBook zero-trust handshake, and
Ethereum ERC-8004, the last marked proposed
([Google Developers Blog](https://developers.googleblog.com/en/a2a-extensions-empowering-custom-agent-functionality/)).

### Authentication

`SecurityScheme` is a discriminated union mirroring the OpenAPI 3.2 Security Scheme
Object ([specification](https://a2a-protocol.org/latest/specification/)):

| Variant | Carries |
| --- | --- |
| `apiKeySecurityScheme` | location `query \| header \| cookie` |
| `httpAuthSecurityScheme` | RFC 7235 `scheme` plus a `bearerFormat` hint |
| `oauth2SecurityScheme` | `oauth2MetadataUrl` per RFC 8414 |
| `openIdConnectSecurityScheme` | `openIdConnectUrl` |
| `mtlsSecurityScheme` | — |

`OAuthFlows` is a `oneof` over `authorizationCode` (carrying `pkceRequired`),
`clientCredentials`, `implicit` (deprecated), `password` (deprecated), and `deviceCode`
(RFC 8628). Skill-level `securityRequirements[]` is allowed. Discovery is out of band:
the client reads `securitySchemes`, obtains credentials out of band, and sends them in
headers or metadata. TLS is mandatory in production. `GetExtendedAgentCard` MUST be
authenticated, and clients SHOULD replace their cached public card with the extended
one for the session.

OAuth was modernized per BCP in 1.0: the implicit and password flows were removed,
device-code was added, and `pkceRequired` was added
([whats-new-v1](https://a2a-protocol.org/latest/whats-new-v1/)).

### In-task authorization

An agent transitions the task to `TASK_STATE_AUTH_REQUIRED` with a status message
explaining the need, and receives credentials **out of band** over HTTPS by default.
Section 7.6.4 explicitly leaves the scope, representation, validity, and revocation of
the resulting authorization **undefined by the protocol**. Agents MUST NOT treat the
state transition alone as authorization, and a credential obtained in that state MUST
NOT be assumed to authorize later messages. Chains of `AUTH_REQUIRED` across agents are
allowed. If in-band exchange is negotiated, credentials SHOULD be bound to the
originating agent and encrypted for it
([specification](https://a2a-protocol.org/latest/specification/)).

### A2A and MCP

The official position, in Appendix B of the specification and in the dedicated topic
page, is complementary: MCP standardizes how an agent uses tools, APIs, and data
sources, which is vertical integration inside one agentic system, while A2A standardizes
how independent opaque agents communicate and delegate as peers, which is horizontal
integration across organizational boundaries. "MCP is commonly used for tool and context
integration at the individual agent level. A2A focuses on communication and coordination
between agents" ([a2a-and-mcp](https://a2a-protocol.org/latest/topics/a2a-and-mcp/);
[specification Appendix B](https://a2a-protocol.org/latest/specification/)). The v1.0
announcement carries a section titled "Complementary to MCP, not a replacement"
([v1.0 launch post](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/)).

An A2A server may also expose stateless skills as MCP resources, but this is presented
as a side capability, not as the protocol's purpose
([a2a-and-mcp](https://a2a-protocol.org/latest/topics/a2a-and-mcp/)). At AAIF the two
are sibling projects in one stack, A2A for agent-to-agent and MCP for agent-to-tool
([AAIF about](https://aaif.io/about)).

## What changed recently

| Date | Change | Source |
| --- | --- | --- |
| 2025-04 | A2A launched by Google with 50+ partners | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| 2025-05-07 | Microsoft announces A2A support in Azure AI Foundry and Copilot Studio, with a Semantic Kernel sample | [Microsoft](https://www.microsoft.com/en-us/microsoft-cloud/blog/2025/05/07/empowering-multi-agent-apps-with-the-open-agent2agent-a2a-protocol/) |
| 2025-06 | Google donates A2A to the Linux Foundation | [AAIF](https://aaif.io/blog/a2a-joins-aaif), [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| 2025-07-30 | v0.3.0: well-known path `agent.json` → `agent-card.json` (#841); mTLS, OAuth2 metadata URL, per-skill security (#901); `agent/getAuthenticatedExtendedCard` (#929); AgentCard `signatures` (#917); `Transport` enum (#909) | [v0.3.0 spec](https://a2a-protocol.org/v0.3.0/specification/), [releases](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15) |
| 2025-08 | IBM's Agent Communication Protocol merges into A2A | [AAIF](https://aaif.io/blog/a2a-joins-aaif) |
| 2025-08-01 | Google Cloud ships v0.3 support across ADK, Agent Engine, Cloud Run, GKE, Agentspace, Vertex AI evaluation, AI Agent Marketplace | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| 2025-09-09 | Google Developers Blog walks the extension mechanism and names real-world extensions | [Google Developers Blog](https://developers.googleblog.com/en/a2a-extensions-empowering-custom-agent-functionality/) |
| 2025-11-19 | AWS Marketplace adds A2A server support for Amazon Bedrock AgentCore Runtime | [AWS](https://aws.amazon.com/about-aws/whats-new/2025/11/marketplace-a2a-server-bedrock-agentcore-runtime/) |
| 2026-03-12 | **v1.0.0.** Large breaking rewrite, detailed below | [v1.0 launch post](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/), [whats-new-v1](https://a2a-protocol.org/latest/whats-new-v1/) |
| 2026-04-09 | Linux Foundation one-year press release: 150+ organizations, 22k+ stars, five production-ready SDK languages | [Linux Foundation](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year) |
| 2026-05-14 | `experimental-ext-oid4vp-auth` and `experimental-cpb-slimrpc` created | [org repository list](https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated) |
| 2026-05-26 | **v1.0.1**, three spec-only fixes | [releases](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15) |
| 2026-06-25 | Three v1.1 epics opened by @Tehsmash, all labelled `v1.1-candidate`: Coherent Task History (#1991, 11 child issues), Bidirectional streaming (#1995), Multi-turn interaction gaps (#1992) | [#1991](https://github.com/a2aproject/A2A/issues/1991) |
| 2026-08-17 | A2A joins AAIF as a hosted project | [AAIF](https://aaif.io/blog/a2a-joins-aaif) |
| 2026-08-27 | A2A's own blog confirms Growth Stage | [A2A blog](https://a2a-protocol.org/latest/blog/2026/08/27/a-new-chapter-for-a2a-joining-the-agentic-ai-foundation/) |
| 2026-09-15 | Roadmap last updated: v1.1 enhancements, BiDi streaming, A2A CLI, elicitation and multi-turn workflows, an interoperability specification, registry consolidation, expanded tooling, security best practices, six-language SDK claim | [roadmap](https://a2a-protocol.org/latest/roadmap/) |

### The v1.0.0 breaking set

From [whats-new-v1](https://a2a-protocol.org/latest/whats-new-v1/) and the
[v1.0.0 spec](https://a2a-protocol.org/v1.0.0/specification/):

| Change | Detail |
| --- | --- |
| Layered architecture | Abstract protocol separated from transport mappings (L1/L2/L3) |
| Method names | All operations renamed to PascalCase; the `category/action` form is gone |
| Part model | `TextPart` / `FilePart` / `DataPart` collapsed into one `Part`; the `kind` discriminator replaced by ProtoJSON member-name discrimination in both `Part` and stream events; `mimeType` → `mediaType`; new `raw` (base64 bytes) and top-level `url`; `filename` on all part types |
| Enums | SCREAMING_SNAKE_CASE with type prefixes (`TASK_STATE_*`, `ROLE_*`) |
| `ListTasks` | New, with filtering and cursor pagination |
| Multi-tenancy | `tenant` on every request message and on `AgentInterface` |
| Agent Card | `protocolVersion` moved to `AgentInterface`; `preferredTransport` plus `additionalInterfaces` merged into `supportedInterfaces[]`; `supportsAuthenticatedExtendedCard` → `capabilities.extendedAgentCard` |
| Signed cards | JWS over RFC 8785 JCS canonicalization |
| OAuth | Implicit and password flows removed, device-code added, `pkceRequired` added |
| Errors | `google.rpc.Status` / `google.rpc.ErrorInfo` with `domain: "a2a-protocol.org"`, replacing RFC 9457 problem details; nine codes `-32001`..`-32009` |
| IDs | Compound resource names to plain literals (#1389) |
| URLs | `/v1` removed from HTTP paths (#1269) |
| Service parameters | `A2A-Version` and `A2A-Extensions` added, both with IANA registration templates; `application/a2a+json` media-type template |
| Execution mode | `SendMessageConfiguration.returnImmediately` added |
| Stream events | `final` removed from `TaskStatusUpdateEvent` |
| Push config | `TaskPushNotificationConfig` and `PushNotificationConfig` merged and flattened (#1500) |
| Minor | "canceled" American spelling (#1283); LF prefix on the protobuf package (#1474); `state_transition_history` capability removed as unimplemented (#1396); duplicate ID removed from the create-push-config request (#1487); `ListTaskPushNotificationConfigs` pluralized (#1486) |

Push notification webhook authentication was reworked after v1.0.0 and is visible only
on `/latest/`. The pinned v1.0.0 page shows `Authorization: Bearer
server-generated-jwt` together with `X-A2A-Notification-Token: ...`;
[`/latest/`](https://a2a-protocol.org/latest/specification/) replaces this with
`TaskPushNotificationConfig.authentication` of type
`AuthenticationInfo{scheme, credentials}` and `Authorization: {scheme} {credentials}`.
`X-A2A-Notification-Token` does not appear anywhere in the current specification text
([v1.0.0 spec](https://a2a-protocol.org/v1.0.0/specification/)).

## Evidence of adoption

### Organization counts

| Claim | Figure | Date | Source |
| --- | --- | --- | --- |
| Linux Foundation press release | "more than 150 organizations supporting the standard", up from "more than 50" since April 2025; names AWS, Cisco, Google, IBM, Microsoft, Salesforce, SAP, ServiceNow | 2026-04-09 | [Linux Foundation](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year) |
| AAIF announcement | "over 150 organizations" | 2026-08-17 | [AAIF](https://aaif.io/blog/a2a-joins-aaif) |
| A2A partners page | 174 entries, each linking an announcement or blog post | 2026-09-29 | [partners](https://a2a-protocol.org/latest/partners/) |
| GitHub repository | 25,963 stars | 2026-09-29 | [repository](https://github.com/a2aproject/A2A) |

The counts are self-reported and the partners list is unfiltered. A secondary Chinese
technology blog claimed "250+ members"; that number refers to AAIF membership, not A2A
partners, and it is `[UNVERIFIED]` here because no primary URL for it was captured.

### Platform support

| Vendor | Support | Date | Source |
| --- | --- | --- | --- |
| Google Cloud | A2A native in ADK, plus Agent Engine, Cloud Run, GKE, Agentspace (now Gemini Enterprise), Vertex GenAI Evaluation Service for A2A agents, and an AI Agent Marketplace for partner-sold A2A agents | 2025-08-01 | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| Microsoft | A2A integrated into Azure AI Foundry and Copilot Studio | committed 2025-05; restated 2026-04-09 and 2026-08-17 | [Microsoft](https://www.microsoft.com/en-us/microsoft-cloud/blog/2025/05/07/empowering-multi-agent-apps-with-the-open-agent2agent-a2a-protocol/), [Linux Foundation](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year), [AAIF](https://aaif.io/blog/a2a-joins-aaif) |
| AWS | Bedrock AgentCore Runtime can host and operate A2A servers, distributed through AWS Marketplace | 2025-11-19; restated 2026-08-17 | [AWS](https://aws.amazon.com/about-aws/whats-new/2025/11/marketplace-a2a-server-bedrock-agentcore-runtime/), [AAIF](https://aaif.io/blog/a2a-joins-aaif) |

### Named deployments

| Organisation | Deployment | Date | Source |
| --- | --- | --- | --- |
| Huawei | Standardised A2A between Celia, its OS-level assistant, and in-app agents on the HarmonyOS developer platform, covering long-running task handoff, UI control, and contextual recommendations | 2026-08-17 | [AAIF](https://aaif.io/blog/a2a-joins-aaif) |
| Tencent WeChat | Among the first major apps integrating with Huawei and other Android OEM assistants over A2A, for messages and for voice and video calls with dual authorization | 2026-08-17 | [AAIF](https://aaif.io/blog/a2a-joins-aaif) |
| Tyson Foods, Gordon Food Service | Shared product data and leads for the food supply chain | 2025-08-01 | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| Adobe | Making distributed agents interoperable with the Google Cloud ecosystem | 2025-08-01 | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| S&P Global Market Intelligence | Adopted A2A as its inter-agent protocol | 2025-08-01 | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| ServiceNow | AI Agent Fabric | 2025-08-01 | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) |
| Twilio | Latency-aware agent selection extension, actually shipped | 2025-08-01; extension described 2025-09-09 | [Google Cloud](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade), [Google Developers Blog](https://developers.googleblog.com/en/a2a-extensions-empowering-custom-agent-functionality/) |

The Linux Foundation release names supply chain, financial services, insurance, and IT
operations as the adopting verticals, and Google Cloud plus PayPal extend A2A into
agentic commerce through the Agent Payments Protocol for discovery, pricing, and
fulfilment ([Linux Foundation](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year)).

### Framework integrations

The community hub lists A2A-specific SDKs and integrations for LangGraph, CrewAI,
Pydantic AI, AG2, IBM BeeAI, Agno, Strands, Microsoft Agent Framework, Semantic Kernel,
LlamaIndex, MindsDB, LiteLLM, the Solace agent mesh, UiPath, and Auto Agent Protocol
([community](https://a2a-protocol.org/latest/community/)). The site lists six official
SDK repositories ([sdk](https://a2a-protocol.org/latest/sdk/)).

### Published SDK versions

Every value below is the version resolved by the package index on 2026-09-29, not the
version the protocol document names.

| Language | Package | Published version | Date | Bindings | 0.3 compat | Source |
| --- | --- | --- | --- | --- | --- | --- |
| Python | `a2a-sdk` (PyPI) | `1.1.5` | — | all three, client and server | yes, spec 1.0 + 0.3 | [PyPI metadata](https://pypi.org/pypi/a2a-sdk/json) |
| JavaScript | `@a2a-js/sdk` (npm) | `1.3.0` | — | grpc client and server, express, database, `a2a-db` CLI | yes, `compat/v0_3/*` subpath exports | [npm metadata](https://registry.npmjs.org/@a2a-js/sdk/latest) |
| Java | `org.a2aproject.sdk` | `1.3.0.Final` | — | Quarkus reference implementations for all three | yes, `compat-0.3` module, plus a `tck` module | [a2a-java](https://github.com/a2aproject/a2a-java) |
| Go | `github.com/a2aproject/a2a-go` | `0.3.15` (module proxy `@latest`) | 2026-04-15 | NOT ESTABLISHED IN SOURCE | tags `v1.0.0-alpha`, `v1.0.0-alpha.2`, `v1.0.0-alpha.3` exist but are not resolved as latest | [Go module proxy](https://proxy.golang.org/github.com/a2aproject/a2a-go/@v/list) |
| .NET | `A2A` (NuGet) | `1.0.0-preview2` — still a prerelease | 2026-04-09 | JSON-RPC and HTTP+JSON/REST only, **no gRPC** | separate `A2A.V0_3` package | [NuGet](https://www.nuget.org/packages/A2A), [a2a-dotnet](https://github.com/a2aproject/a2a-dotnet) |
| Rust | `a2a-lf`, from `a2a-rs` | version NOT ESTABLISHED IN SOURCE; repository has 86 stars and 234 commits | — | uniquely ships a SLIMRPC binding; workspace crates `a2a`, `a2a-client`, `a2a-server`, `a2a-pb`, `a2a-grpc`, `a2a-slimrpc`, `a2acli` | — | [a2a-rs](https://github.com/a2aproject/a2a-rs) |

### Conformance and tooling

| Tool | Scope | Source |
| --- | --- | --- |
| `a2a-tck` | Python 3.11+, tests all three transports, organises tests by RFC 2119 level with MUST as hard failure, SHOULD as expected failure, MAY as skipped; drives transport selection from the agent card's `supportedInterfaces`; generates systems under test for `a2a-python`, `a2a-java`, `a2a-jakarta` | [TCK README](https://raw.githubusercontent.com/a2aproject/a2a-tck/main/README.md) |
| `a2a-inspector` | Web UI | [org repository list](https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated) |
| `a2a-cli` | Rust `a2acli`; Windows via `winget-pkgs`, macOS via a Homebrew tap | [org repository list](https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated) |
| `a2a-itk` | Interoperability kit, present in five SDK repositories | [org repository list](https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated) |

## Sharp edges

1. **`AgentCard.security` does not exist.** Section 3.1.11 and section 13.3 both issue a
   MUST to authenticate "using one of the schemes declared in the public
   `AgentCard.securitySchemes` and `AgentCard.security` fields", but the Agent Card
   table in section 4.4.1 defines `securitySchemes` and `securityRequirements` and has
   no `security` field. Two normative requirements point at a field that is not defined
   ([specification](https://a2a-protocol.org/latest/specification/)).

2. **The `SendMessage` default blocking semantics were inverted and the migration
   document does not say so.** 0.3.0 had `MessageSendConfiguration.blocking` — "If
   true, the client will wait for the task to complete. The server may reject this if
   the task is long-running" — with non-blocking as the default
   ([v0.3.0 spec](https://a2a-protocol.org/v0.3.0/specification/)). 1.0 replaced it with
   `returnImmediately`, whose default is blocking: the operation MUST wait until the
   task reaches a terminal or interrupted state before returning. The What's New page
   lists this only as a new "Execution Mode Control" capability, not as a breaking
   behaviour change ([whats-new-v1](https://a2a-protocol.org/latest/whats-new-v1/)). A
   non-blocking 0.3 client that relied on the old default will now block, and
   long-running tasks on a blocking `SendMessage` have no specified server-side escape.

3. **The official extension and binding namespaces are empty.** Zero `ext-*` or `cpb-*`
   repositories exist. The only artefacts are `experimental-ext-oid4vp-auth` and
   `experimental-cpb-slimrpc`, both created 2026-05-14, both with single-digit stars,
   neither referenced from the documentation's extension list
   ([org repository list](https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated);
   [extensions](https://a2a-protocol.org/latest/topics/extensions/)). The
   `https://a2a-protocol.org/extensions/` and `/bindings/` prefixes are declared
   canonical and carry nothing. Anyone building on registered extensions today depends
   on sample or vendor extensions outside the governed namespace.

4. **`/latest/` carries unreleased specification changes and there is no pinned 1.0.1
   page.** `a2a-protocol.org/v1.0.1/specification/` redirects to `/latest/`, which
   tracks `main`. The two differ in the push notification authentication model: v1.0.0
   uses `Authorization: Bearer server-generated-jwt` plus
   `X-A2A-Notification-Token`, while `/latest/` uses
   `AuthenticationInfo{scheme, credentials}`
   ([v1.0.0 spec](https://a2a-protocol.org/v1.0.0/specification/);
   [`/latest/`](https://a2a-protocol.org/latest/specification/)). A reader of
   `/latest/` is reading unreleased text and cannot tell which parts are 1.0.1. The v1.0.1
   webhook auth model may be a breaking change shipped in a patch release: this is
   `[INFERENCE]` from the diff, because the release notes do not flag it.

5. **Content-Type is inconsistent across bindings and within the specification.**
   Section 9.1 mandates `application/json` for JSON-RPC. Section 11.1 says
   `application/a2a+json` SHOULD be used for the REST binding, and section 4.3.3 shows
   webhooks sending `Content-Type: application/a2a+json`. v1.0.1's first fix was
   literally "prefer `application/a2a+json` in HTTP binding", which establishes that
   v1.0.0 was ambiguous ([releases](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15)).
   Separately, the version-error example in section 6.4 of the current specification
   still returns `application/problem+json` per RFC 9457, which the What's New page
   says v1.0 replaced with `google.rpc.Status` JSON
   ([whats-new-v1](https://a2a-protocol.org/latest/whats-new-v1/)).

6. **Removing `final` from `TaskStatusUpdateEvent` removes the explicit end-of-stream
   signal.** Termination is now purely the binding's stream closure mechanism. For SSE
   on JSON-RPC and REST a client cannot distinguish a completed stream from a dropped
   connection without heuristics, and the specification elsewhere acknowledges that
   "clients using streaming to retrieve task updates MAY not receive all status update
   messages if the client is disconnected and then reconnects"
   ([specification](https://a2a-protocol.org/latest/specification/)). v1.1 epic #1991
   tracks the family of history and replay gaps, including #1635 on data loss during
   SSE reconnection and #1811 proposing a `TaskMessageUpdateEvent`
   ([#1991](https://github.com/a2aproject/A2A/issues/1991)).

7. **`SubscribeToTask` refuses terminal-state tasks.** It returns
   `UnsupportedOperationError` for COMPLETED, FAILED, CANCELED, and REJECTED
   (§3.1.6), so a client that loses a stream after completion cannot resubscribe to
   confirm the final state and must fall back to polling `GetTask`. This is specified
   behaviour, and it is in tension with the multi-stream resilience goals of §3.5.2
   ([specification](https://a2a-protocol.org/latest/specification/)).

8. **The IANA registrations are unverified and one contact address is a placeholder.**
   Section 14 supplies registration templates for `application/a2a+json`, the
   `A2A-Version` and `A2A-Extensions` headers, and the `agent-card.json` well-known URI.
   The media-type template lists the contact as "A2A Protocol Working Group,
   <a2a-protocol@example.org>" with change controller "A2A Protocol Working Group", a
   placeholder domain rather than a real address. Whether any of these are actually
   registered with IANA is `[UNVERIFIED]`; no IANA record was found. The header
   templates also cite "Section 3.2.5 of the A2A Protocol Specification" where service
   parameters are §3.2.6 and §3.2.5 is Metadata
   ([specification](https://a2a-protocol.org/latest/specification/)).

9. **The specification still contains 0.3-era residue.** Section 9.3's JSON-RPC "Base
   Request Structure" shows `"method": "category/action"`, contradicting §9.1's PascalCase
   mandate. Section 12.4 cross-references error handling as "Section 3.2.2" when it is
   §3.3.2. Appendix A's deprecation timeline still plans legacy-name removal for
   ">= 0.5.0", a version that will never now exist that 1.0 shipped, so the deprecation
   contract for every renamed object in the 1.0 breaking set is undefined. The
   extensions topic page still shows a 0.3-shaped Agent Card example with a top-level
   `url` and no `supportedInterfaces`, and posts to `/agents/eightball` with
   `SendMessage` ([specification](https://a2a-protocol.org/latest/specification/);
   [extensions](https://a2a-protocol.org/latest/topics/extensions/)).

10. **SDK maturity is uneven and the "production-ready" framing overstates it.** The Go
    module proxy resolves `@latest` to `0.3.15` from 2026-04-15, so `go get` returns a
    pre-1.0 SDK, and .NET is still `1.0.0-preview2`. The .NET SDK documents only
    JSON-RPC and HTTP+JSON/REST, with no gRPC, while the Linux Foundation release called
    five languages "production-ready" on 2026-04-09. The Rust SDK is the newest and
    smallest. See the SDK table above for every resolved version.

11. **`tenant` is opaque and under-specified.** The protocol "does not define its format
    or semantics" and leaves routing to the server, yet requires clients to set it on
    every request and to match it exactly to the selected `AgentInterface`. Multi-tenant
    deployments get a routing hint with no isolation guarantee from the protocol, and
    §13.1 pushes authorization scoping entirely onto implementations
    ([specification](https://a2a-protocol.org/latest/specification/)). Cross-tenant
    leakage is a deployment-level risk the specification does not address.

12. **A gateway was announced but does not exist.**
    `a2aproject/a2a-gateway`, described as "A2A Gateway allowing hooking up A2A Agents
    to different communications channels", is an empty repository with 0 files and 1
    star ([a2a-gateway](https://github.com/a2aproject/a2a-gateway)). Agent discovery
    has no official registry or federation mechanism; the roadmap lists "consolidation
    of efforts for registry" as a 3–6 month item, and a third-party `a2a-registry`
    exists outside the project ([roadmap](https://a2a-protocol.org/latest/roadmap/)).

13. **Streaming and push are optional and the specification forbids a clean fallback.**
    `GetExtendedAgentCard` errors with `UnsupportedOperationError` unless declared, as
    do streaming and push. Clients get no discovery mechanism for another agent's
    capabilities beyond the Agent Card. Combined with the 1.0 field reshuffle
    (`preferredTransport` to `supportedInterfaces[]`,
    `supportsAuthenticatedExtendedCard` to `capabilities.extendedAgentCard`), a 0.3
    client reading a 1.0 Agent Card finds no endpoint and no version it understands. The
    backward compatibility is one-directional: a 1.0 server can serve a 0.3 client via
    `A2A-Version`, not the reverse ([specification](https://a2a-protocol.org/latest/specification/)).

14. **In-task authorization semantics are deliberately undefined.** Section 7.6.4 states
    that the protocol does not define "the scope, representation, validity, or
    revocation semantics" of the authorization, and that a credential obtained in
    `AUTH_REQUIRED` MUST NOT be assumed to authorize subsequent messages. The
    `experimental-ext-oid4vp-auth` extension is the community answer and it is
    experimental. Delegated-authorization security rests on out-of-band discipline with
    no protocol-level enforcement ([specification](https://a2a-protocol.org/latest/specification/)).

15. **The roadmap is 3–6 months out and the v1.1 milestone is at 0%.** Milestone v1.1 is
    due 2026-10-22 with all three epics open and no completed items
    ([milestone 4](https://github.com/a2aproject/A2A/milestone/4)). The 0.3 to 1.0
    migration was aggressive across enums, the Part model, stream events, the error
    model, the Agent Card shape, IDs, and URL prefixes, and the ecosystem has had
    roughly 18 months of SDK compat shims. The 1.1 changes — bidirectional streaming,
    multi-turn state rules, task history — are additive but touch the same areas
    ([roadmap](https://a2a-protocol.org/latest/roadmap/)).

## Sources

Every URL below was fetched and read; none is cited from a search-result snippet.

### Specification and topics

- [https://a2a-protocol.org/latest/specification/](https://a2a-protocol.org/latest/specification/) — full specification: operation set, data model, all three bindings, error taxonomy, authentication, IANA templates, Appendix B on MCP
- [https://a2a-protocol.org/v1.0.0/specification/](https://a2a-protocol.org/v1.0.0/specification/) — pinned v1.0.0, used to diff the push notification authentication model
- [https://a2a-protocol.org/v0.3.0/specification/](https://a2a-protocol.org/v0.3.0/specification/) — pinned v0.3.0, confirms the `blocking` default and `MessageSendConfiguration`
- [https://a2a-protocol.org/latest/whats-new-v1/](https://a2a-protocol.org/latest/whats-new-v1/) — official 0.3 to 1.0 change list and migration phases
- [https://a2a-protocol.org/latest/roadmap/](https://a2a-protocol.org/latest/roadmap/) — post-1.0 direction, last updated 2026-09-15
- [https://a2a-protocol.org/latest/topics/extensions/](https://a2a-protocol.org/latest/topics/extensions/) — extension mechanism, activation, required extensions, limitations
- [https://a2a-protocol.org/latest/topics/extension-and-binding-governance/](https://a2a-protocol.org/latest/topics/extension-and-binding-governance/) — two-tier extension and binding governance
- [https://a2a-protocol.org/latest/topics/custom-protocol-bindings/](https://a2a-protocol.org/latest/topics/custom-protocol-bindings/) — custom binding requirements
- [https://a2a-protocol.org/latest/topics/a2a-and-mcp/](https://a2a-protocol.org/latest/topics/a2a-and-mcp/) — official A2A and MCP relationship
- [https://a2a-protocol.org/latest/partners/](https://a2a-protocol.org/latest/partners/) — partner list, 174 entries on 2026-09-29
- [https://a2a-protocol.org/latest/community/](https://a2a-protocol.org/latest/community/) — framework integrations, community SDKs, tooling
- [https://a2a-protocol.org/latest/sdk/](https://a2a-protocol.org/latest/sdk/) — six official SDK repositories
- [https://a2a-protocol.org/latest/blog/2026/08/27/a-new-chapter-for-a2a-joining-the-agentic-ai-foundation/](https://a2a-protocol.org/latest/blog/2026/08/27/a-new-chapter-for-a2a-joining-the-agentic-ai-foundation/) — Growth Stage, adoption, cloud support
- [https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/) — v1.0 announcement, enterprise features, MCP position

### Foundations

- [https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year) — the 150+ claim, dated 2026-04-09
- [https://aaif.io/blog/a2a-joins-aaif](https://aaif.io/blog/a2a-joins-aaif) — 2026-08-17 AAIF announcement, named production deployments, stack layering
- [https://aaif.io/about](https://aaif.io/about) — AAIF identity, board, working groups

### Repositories and registries

- [https://github.com/a2aproject/A2A](https://github.com/a2aproject/A2A) — repository state, license, star count
- [https://raw.githubusercontent.com/a2aproject/A2A/main/GOVERNANCE.md](https://raw.githubusercontent.com/a2aproject/A2A/main/GOVERNANCE.md) — TSC seats, voting, quorum
- [https://api.github.com/repos/a2aproject/A2A/releases?per_page=15](https://api.github.com/repos/a2aproject/A2A/releases?per_page=15) — v1.0.0, v1.0.1, v0.3.0, v0.2.x release notes and dates
- [https://github.com/a2aproject/A2A/milestone/4](https://github.com/a2aproject/A2A/milestone/4) — v1.1 milestone, 0% complete, due 2026-10-22
- [https://github.com/a2aproject/A2A/issues/1991](https://github.com/a2aproject/A2A/issues/1991) — v1.1 epic on task history, 11 child issues
- [https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated](https://api.github.com/orgs/a2aproject/repos?per_page=100&sort=updated) — full organisation repository list; establishes that only two experimental extension and binding repositories exist
- [https://github.com/a2aproject/a2a-gateway](https://github.com/a2aproject/a2a-gateway) — empty gateway repository
- [https://raw.githubusercontent.com/a2aproject/a2a-tck/main/README.md](https://raw.githubusercontent.com/a2aproject/a2a-tck/main/README.md) — TCK scope, transports, RFC 2119 levels

### Package registries

- [https://pypi.org/pypi/a2a-sdk/json](https://pypi.org/pypi/a2a-sdk/json) — Python SDK 1.1.5, transport matrix, compat mode
- [https://registry.npmjs.org/@a2a-js/sdk/latest](https://registry.npmjs.org/@a2a-js/sdk/latest) — JavaScript SDK 1.3.0, `compat/v0_3` export map
- [https://github.com/a2aproject/a2a-java](https://github.com/a2aproject/a2a-java) — Java SDK 1.3.0.Final, Quarkus, `compat-0.3`, TCK module
- [https://github.com/a2aproject/a2a-rs](https://github.com/a2aproject/a2a-rs) — Rust workspace, SLIMRPC, `a2acli`
- [https://github.com/a2aproject/a2a-dotnet](https://github.com/a2aproject/a2a-dotnet) — .NET SDK, `A2A.V0_3` compat package, no gRPC
- [https://www.nuget.org/packages/A2A](https://www.nuget.org/packages/A2A) — .NET 1.0.0-preview2, 2026-04-09
- [https://proxy.golang.org/github.com/a2aproject/a2a-go/@v/list](https://proxy.golang.org/github.com/a2aproject/a2a-go/@v/list) — Go 0.3.15 as latest, `v1.0.0-alpha` tags present

### Vendor

- [https://www.microsoft.com/en-us/microsoft-cloud/blog/2025/05/07/empowering-multi-agent-apps-with-the-open-agent2agent-a2a-protocol/](https://www.microsoft.com/en-us/microsoft-cloud/blog/2025/05/07/empowering-multi-agent-apps-with-the-open-agent2agent-a2a-protocol/) — Azure AI Foundry and Copilot Studio commitment, 2025-05-07
- [https://aws.amazon.com/about-aws/whats-new/2025/11/marketplace-a2a-server-bedrock-agentcore-runtime/](https://aws.amazon.com/about-aws/whats-new/2025/11/marketplace-a2a-server-bedrock-agentcore-runtime/) — Bedrock AgentCore Runtime A2A support, 2025-11-19
- [https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade](https://cloud.google.com/blog/products/ai-machine-learning/agent2agent-protocol-is-getting-an-upgrade) — v0.3 tooling, named adopters, Linux Foundation donation date, 2025-08-01
- [https://developers.googleblog.com/en/a2a-extensions-empowering-custom-agent-functionality/](https://developers.googleblog.com/en/a2a-extensions-empowering-custom-agent-functionality/) — extension walkthrough and real-world extensions, 2025-09-09

### Unverified items carried forward

1. Whether `application/a2a+json`, the `A2A-Version` and `A2A-Extensions` headers, and
   the `agent-card.json` well-known URI are actually registered with IANA. No IANA
   record was found.
2. Whether the 8-seat A2A TSC composition survives the AAIF transition unchanged.
   `GOVERNANCE.md` on `main` was not rewritten for AAIF as of 2026-09-29.
3. Whether the push notification authentication rework shipped in v1.0.1 constitutes a
   breaking change in a patch release. The release notes do not flag it.
4. The secondary "250+ members" figure, which refers to AAIF membership rather than A2A
   partners. No primary URL for it was captured.
