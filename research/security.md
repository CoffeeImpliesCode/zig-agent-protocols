# Security posture of the agent wire protocols

This document records what MCP, A2A and ACP actually say about security, what each
specification has fixed and when, what no specification currently addresses, and what
the vulnerability record shows. It covers the protocol-level threat models, the
published CVE inventory, the registries that function as the supply-chain surface, and
the platform-level identity work that currently carries most of the real controls. It
does not cover general networking security, host hardening, or the vendor-by-vendor
protocol support matrix.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

All claims below trace to the sources in [Sources](#sources). Claims that rest on a
single source, on a source that could not be reached, or on an absence of evidence
carry `[UNVERIFIED]`. Conclusions drawn across sources carry `[INFERENCE]`. Where a
value does not exist in any consulted source, the cell reads
`NOT ESTABLISHED IN SOURCE`.

## State

### Where security lives in each project

Security is not handled in one place in any of the three protocols, and the places are
not of equal force.

| Protocol | Normative | Spec-adjacent | Non-normative | Formal security body |
| --- | --- | --- | --- | --- |
| MCP | [Authorization Security Considerations](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations.md) — a page of MUSTs | Per-SEP requirements, e.g. the [SEP-1024](https://modelcontextprotocol.io/seps/1024-mcp-client-security-requirements-for-local-server-.md) consent-dialog MUST | [Security Best Practices](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices.md) — confused deputy, token passthrough, SSRF, state handle hijacking, local server compromise; nearly every control is a SHOULD | [MCP Security Interest Group](https://modelcontextprotocol.io/community/interest-groups/security.md), chartered 2026-06-13 |
| A2A 1.0 | §7 Auth, §13 Security Considerations of the [specification](https://raw.githubusercontent.com/a2aproject/A2A/main/docs/specification.md) | — | — | None found |
| ACP v1 | — | — | — | None found; the trust model is implicit in the local-process architecture |

The [Basic](https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md)
specification states that clients and servers "MAY negotiate their own custom
authentication and authorization strategies."

### The MCP Security Interest Group

The MCP project is the only one of the three with a chartered security body. The
[charter](https://modelcontextprotocol.io/community/interest-groups/security.md) dates
from 2026-06-13; facilitators are Den Delimarsky and Paul Carleton, both Anthropic;
office hours run every two weeks with a `#security-ig` Discord channel. Named in-scope
items: threat modeling, server identity / attestation / admission, supply chain and
provenance, runtime drift and post-admission change, auditability, transport-adjacent
security, and vulnerability-disclosure routing. OAuth mechanics are assigned to a
separate Authorization interest group; TLS to the Transports working group.

Its live agenda is the maintainers' own scorecard of what is unfinished.

| Agenda item | Status in the source |
| --- | --- |
| SEP-2809 Attested Tool-Server Admission (ATSA) | Draft |
| SDK vulnerability disclosure | In progress |
| Runtime drift: `list_changed` semantics after approval | Open |
| Supply-chain integrity: protocol, registry, or companion standard | Open |
| Tool identity across servers | Open |
| Capability declarations: hints or contracts | Open |

A signature mechanism and a rug-pull answer are both named as unfinished work by the
maintainers themselves.

### Attack taxonomy

The [OWASP MCP Top 10](https://owasp.org/projects/mcp-top-10) (2025, beta; project
lead Vandana Verma Sehgal; CC BY-NC-SA 4.0) enumerates MCP01 Token Mismanagement &
Secret Exposure, MCP02 Privilege Escalation via Scope Creep, MCP03 Tool Poisoning,
MCP04 Software Supply Chain Attacks & Dependency Tampering, MCP05 Command Injection &
Execution, MCP06 Prompt Injection via Contextual Payloads, MCP07 Insufficient
Authentication & Authorization, MCP08 Lack of Audit and Telemetry, MCP09 Shadow MCP
Servers, and MCP10 Context Injection & Over-Sharing.

The [OWASP MCP Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html)
adds rug pull, tool shadowing and cross-origin escalation, exfiltration via legitimate
channels, message tampering and replay, and sandbox escape.

Named in MCP's own [Security Best Practices](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices.md)
page: confused deputy (with a full attack sequence diagram), token passthrough
(forbidden outright), SSRF during OAuth metadata discovery, state handle hijacking
(the 2026-07-28 successor to session hijacking), and local MCP server compromise.

The term "line jumping" appears in secondary commentary about this attack class. No
primary source using it was found. Flagged `[UNVERIFIED-ABSENT]`.

### CVE inventory

The following were read from NVD and the GitHub Advisory Database, except where the
row says otherwise.

| ID | Component | Published | Severity | Weakness | Failure | Fixed in |
| --- | --- | --- | --- | --- | --- | --- |
| [CVE-2026-25536](https://github.com/advisories/GHSA-345p-7cg4-v4c7) / [GHSA-345p-7cg4-v4c7](https://github.com/advisories/GHSA-345p-7cg4-v4c7) | `@modelcontextprotocol/sdk` (npm) | 2026-02-04, updated 2026-02-09 | High, CVSS 7.1, EPSS 0.358% | NOT ESTABLISHED IN SOURCE | Silent cross-client data leakage: transport reuse causes JSON-RPC id collisions to misroute responses; server reuse overwrites `Protocol._transport` so progress, sampling and elicitation go to the wrong client. Affected ≥1.10.0 ≤1.25.3 | 1.26.0 |
| [CVE-2026-47751](https://github.com/advisories/GHSA-8q5r-mmjf-575q) / [GHSA-8q5r-mmjf-575q](https://github.com/advisories/GHSA-8q5r-mmjf-575q) | `anthropics/claude-code-action` | 2026-05-20, updated 2026-09-01 | Moderate, CVSS v4 5.3, EPSS 0.766% | CWE-78, CWE-200 | Arbitrary code execution on the GitHub Actions runner and secret exfiltration: attacker-controlled PR head checkout + `.mcp.json` read from the working directory + `enableAllProjectMcpServers`. `<1.0.74` | 1.0.74 |
| [CVE-2026-44429](https://nvd.nist.gov/vuln/detail/CVE-2026-44429) | MCP Registry | 2026-05-14, modified 2026-06-17 | Medium 5.4 | CWE-79, CWE-116 | Stored XSS in the catalogue UI via `server.websiteUrl`: server-side validation admitted quote characters; the client-side `escapeHtml` helper used the `textContent`→`innerHTML` round trip, which encodes only `& < > U+00A0` inside text nodes, not `"` or `'`. CSP is `script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com` | 1.7.7 |
| [CVE-2026-35568](https://nvd.nist.gov/vuln/detail/CVE-2026-35568) / [GHSA-8jxr-pr72-r468](https://github.com/advisories/GHSA-8jxr-pr72-r468) | MCP Java SDK | 2026-04-07, modified 2026-07-24 | Medium 5.7 | CWE-346, origin validation | DNS rebinding: a browser reaches a private java-sdk MCP server and makes tool calls as a locally connected agent. `<1.0.0` | 1.0.0 |
| CVE-2026-27735 | mcp-server-git | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Path traversal in `git_add` staging files outside the repository | 2026.1.14 |
| CVE-2026-27826 | mcp-atlassian | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Unauthenticated access before 0.17.0 | 0.17.0 |
| CVE-2026-40576 | excel-mcp-server | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE |
| CVE-2026-44969 | dbt-mcp | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | 1.17.1 |
| CVE-2026-44427 | MCP Registry | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Open redirect. Listing only, not fetched. `[UNVERIFIED]` | NOT ESTABLISHED IN SOURCE |
| CVE-2026-61459 | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Listing only, not fetched. `[UNVERIFIED]` | NOT ESTABLISHED IN SOURCE |
| CVE-2026-30856 | WeKnora | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Tool-name collision via the `mcp_{server}_{tool}` convention plus indirect prompt injection, redirecting tool execution | NOT ESTABLISHED IN SOURCE |
| CVE-2026-25723 | Claude Code | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Piped-`sed` command injection bypassing file-write restrictions | NOT ESTABLISHED IN SOURCE |
| CVE-2026-35603 | Claude Code | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Pre-2.1.75 on Windows loads `C:\ProgramData\ClaudeCode\managed-settings.js` | 2.1.75 |
| CVE-2026-31862 | Cloud CLI | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | `execAsync` with string commands | NOT ESTABLISHED IN SOURCE |
| CVE-2026-39861 | Claude Code | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Sandbox escape via symlink following | NOT ESTABLISHED IN SOURCE |
| CVE-2026-25725 | Claude Code | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | Sandbox escape via persistent `settings.json` injection | NOT ESTABLISHED IN SOURCE |
| GHSA-qxfv-fcpc-w36x | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | `rg` command injection bypassing the approval prompt | NOT ESTABLISHED IN SOURCE |

The rows from CVE-2026-30856 downward were located through search listings rather than
individual advisory fetches. `[UNVERIFIED]` for detail beyond the one-line description.
The inventory covers 2025–2026 only; any pre-2025 advisory for these packages is
`NOT ESTABLISHED IN SOURCE`.

### Bug versus structural flaw

The distinction is not cosmetic. A bug in one server, SDK or harness is fixed by a
patch release; a structural flaw is fixed only by a specification change, and the
security consequences are the same for every implementation that follows the spec.

**Bugs — patchable, no protocol change required.** CVE-2026-25536 (TypeScript SDK
instance reuse, with the design consequence noted below), CVE-2026-35568 (Java SDK DNS
rebinding), CVE-2026-44429 and CVE-2026-44427 (Registry application), CVE-2026-27735
(mcp-server-git path traversal), CVE-2026-27826 (mcp-atlassian unauthenticated access),
CVE-2026-30856 (WeKnora tool-name collision), CVE-2026-47751 (claude-code-action
config trust), and CVE-2026-25723 / -35603 / -31862 / -39861 / -25725 (Claude Code and
Cloud CLI).

**The one bug that is really a design consequence.** CVE-2026-25536 is filed above as
a bug, and the advisory is explicit that the conditions are "most common in stateless
deployments". The SDK's stateless mode made instance reuse the path of least
resistance, and because the SDK's default client generates JSON-RPC ids from an
incrementing counter starting at 0, two clients colliding on an id is the default case
rather than an edge case. The failure mode is silent cross-client data leakage in the
most common deployment pattern, and it requires no attacker — only concurrency. The
1.26.0 fix makes the server throw rather than misroute, converting a silent
confidentiality breach into a loud availability error. `[INFERENCE]` The general
lesson: statelessness removes protocol-level session confusion but shifts the burden
onto implementers, and the ecosystem's first response to that burden was a
silent-confidentiality bug in the reference SDK.

**Structural flaws — no patch available.** These are enumerated with reasoning under
[Sharp edges](#sharp-edges).

## What it does

### What the MCP specification now mitigates natively

The single most consequential change is statelessness.
[`basic/index.md`](https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md)
states: "MCP is a stateless protocol: all the information needed to process a request is
contained in the request itself… Servers **MUST NOT** rely on prior requests over the
same connection to establish context." Sessions, `Mcp-Session-Id`, the `initialize`
handshake, SSE resumability and `Last-Event-ID`, `ping`, `logging/setLevel`, and
`notifications/roots/list_changed` are all gone. That removes the
confused-deputy-by-session-mixup class at the protocol level.

| Risk | Status | Mechanism and where it is written |
| --- | --- | --- |
| Token leakage to third-party resource servers, audience confusion | Mitigated, normative | RFC 8707: clients MUST send `resource` in authorization and token requests. Servers MUST validate that tokens were issued for them (RFC 8707 §2, OAuth 2.1 §5.2). Token passthrough MUST NOT. Clients MUST reject tokens not issued for them. |
| Authorization-server mix-up | Mitigated, normative, conditional | RFC 9207. Servers SHOULD include `iss`; clients MUST compare a present `iss` to the recorded issuer with no case folding, default-port elision, trailing-slash or percent-encoding normalization; MUST reject when the AS advertises support and omits it; MUST NOT act on `error`, `error_description` or `error_uri` on mismatch. The spec notes a future revision is expected to move SHOULD to MUST. |
| Confused deputy | Partial | The Security Best Practices page carries the attack walkthrough, a per-client-consent sequence diagram and specific MUSTs (exact `redirect_uri` match, `__Host-` cookies, `frame-ancestors` CSP, `state` set only *after* consent) — but that page is a tutorial, not normative. The normative hook in Authorization Security Considerations is one sentence. DCR's deprecation narrows the precondition without removing it; DCR remains available for backward compatibility until earliest removal on or after 2027-07-28. |
| OAuth metadata-discovery SSRF, client side | Guidance only, all SHOULD | Enforce HTTPS; block `10/8`, `172.16/12`, `192.168/16`, `127/8`, `::1`, `169.254/16`, `fc00::/7`, `fe80::/10` per RFC 9728 §7.7; validate redirect targets hop by hop; use egress proxies (Smokescreen cited); explicit TOCTOU and DNS-pinning warning; a note not to hand-roll IP validation, citing octal, hex and IPv4-mapped-IPv6 tricks. |
| CIMD-fetch SSRF against the authorization server | Guidance only, SHOULD | The AS takes a URL from an unknown client and fetches it. The spec requires ASes to *consider* SSRF. Localhost redirect-URI impersonation is explicitly not solvable by CIMD. |
| Cross-request state confusion, session hijacking | Structurally removed; a new risk added | The new risk is state handle hijacking. Servers implementing authorization MUST verify all inbound requests, MUST NOT treat possession of a state handle as authentication, SHOULD use secure non-deterministic handles, and SHOULD key stored state as `<user_id>:<handle>` with the user ID derived from the verified token rather than supplied by the client. |
| Silent local command execution via one-click install | Mitigated, client-behaviour MUST | [SEP-1024](https://modelcontextprotocol.io/seps/1024-mcp-client-security-requirements-for-local-server-.md) (Final 2025-07-22): untruncated command and all arguments shown, affirmative approval, a cancel option, and no install on denial. The SEP itself lists residual risks: user override, obfuscation, implementation gaps. |
| OAuth scope over-request | Narrowed | Incremental scope consent via `WWW-Authenticate` `scope` (SEP-835) plus a documented scope-minimization strategy in the [authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/index.md). |

### A2A's security model

§7 of the [A2A 1.0 specification](https://raw.githubusercontent.com/a2aproject/A2A/main/docs/specification.md)
is one page. Production **MUST** use HTTPS/TLS with TLS 1.3 or later recommended; clients
**SHOULD** validate the server certificate; the client learns required schemes from
`AgentCard.securitySchemes` and obtains credentials out-of-band; the server **MUST**
authenticate every request. There is no A2A-specific OAuth profile. `[INFERENCE]` From
the absence of RFC 8707 resource indicators and RFC 9207 `iss` validation in §7 and
§4.5, an A2A client has no normative defence against audience confusion or
authorization-server mix-up — the two failure modes MCP closes normatively.

**Signed Agent Cards (§8.4)** are the strongest identity primitive in any of these
protocols. Agent Cards **MAY** be signed with JWS (RFC 7515). Canonicalization **MUST**
use JCS (RFC 8785) respecting protobuf field-presence semantics: unset optionals
excluded, explicitly-set defaults included, the `signatures` field excluded.
`AgentCardSignature` is `{protected, signature, header}`; the protected header **MUST**
include `alg` and `kid`, and `typ` **SHOULD** be `JOSE`. Clients **SHOULD** verify at
least one signature; public keys **SHOULD** come over HTTPS; clients **MAY** keep a
trusted key store; expired or revoked keys **MUST NOT** be used; multiple signatures
**MAY** support rotation.

The gaps are explicit in the same document. Signing is MAY and verification is SHOULD,
so an unsigned card is fully conformant. There is no trust root, no registry, no
revocation list, and no key-distribution mechanism in the specification.
§7.6.4: "The A2A protocol does not define the scope, representation, validity, or
revocation semantics of the authorization decision or credential obtained in response
to `TASK_STATE_AUTH_REQUIRED`… Agents **MUST NOT** treat the
`TASK_STATE_AUTH_REQUIRED` state transition, by itself, as authorization." §7.6.3
permits in-band credential exchange across a chain of agents if negotiated, and only
recommends binding credentials to the originating agent and encrypting them. §13.2
webhook SSRF protection is SHOULD-level. §13.1: "Authorization boundaries are defined by
each agent's authorization model, not prescribed by the protocol." `[INFERENCE]` A
signature is an identity claim, not a behavioural one; it says nothing about whether
the named agent stays inside its declared scope or leaks data downstream.

Multi-tenancy is a [v1.0 headline feature](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/),
and §13.1's scoping MUSTs — check authorization before any query that could leak the
existence of out-of-scope resources, scope `List Tasks` to the caller even without a
`contextId` — are the direct mitigation. No conformance test covering them was found in
the A2A TCK.

### ACP's security model

There is no wire-level security model, because there is no wire. ACP v1 is JSON-RPC
over stdio between an editor and an agent the editor spawns as a local subprocess
declared by `command`, `args` and `env` in the [v1 schema](https://agentclientprotocol.com/protocol/v1/schema).
The trust boundary is the process boundary, and the security properties are therefore a
property of the host's process management — which is also why
[JetBrains auto-downloads agent files and manages a bundled Node.js or Python
runtime](https://www.jetbrains.com/help/ai-assistant/acp.html).

There is a real authentication model at the protocol level: `authMethods` advertised in
`initialize`, `authenticate` with a `methodId`, `auth_required` gating `new_session`,
`logout` stabilized 2026-05-21, and `AuthMethodAgent` versus `AuthMethodTerminal`
variants. It carries no OAuth profile, no token binding, no audience checking, and no
message signing.

The [Transports Working Group](https://agentclientprotocol.com/updates) was formed
2026-04-22, co-led by Anna Zhdan (JetBrains) and Alex Hancock (Block/Goose), with a
Draft RFD to standardize remote transports over WebSockets and HTTP. When that lands,
ACP acquires a network-facing security surface that does not exist today. No threat
model for it has been published.

### Conformance does not close the gap

The [conformance framework](https://raw.githubusercontent.com/modelcontextprotocol/conformance/main/README.md)
is real: frozen per-revision requirement sets (`--requirements 2026-07-28`), `tier-check`
gating SDK Tier 1, per-check baselining, a GitHub Action, and a `wire-schema-valid`
check. Its own README states the requirement sets "deliberately cover no
authorization-server scenarios, because the specification puts authorization server
implementation beyond its own scope", and SEP-1730, quoted in the README, says
extensions such as Tasks and MCP Apps "are not required for any tier". Conformance
verifies protocol shape, not security posture.

## What changed recently

| Date | Change | Source |
| --- | --- | --- |
| 2025-04-06 | Invariant Labs disclosed tool-poisoning attacks: hidden malicious instructions embedded in tool descriptions, injected at MCP registration | [Invariant Labs](https://invariantlabs.ai/blog/toxic-flow-analysis) |
| 2025-05-20 | NSA announced Cybersecurity Information Sheet U/OO/6030316-26, PP-26-1834, May 2026 Ver. 1.0, "Model Context Protocol (MCP): Security Design Considerations for AI-Driven Automation" | See [Sharp edges](#evidence-caveat-the-asserted-dpop-sep) and the caveat below |
| 2025-05-26 | Invariant Labs demonstrated GitHub MCP exploited: a malicious issue coerces an agent into pulling private-repository data into context and exfiltrating it in an autonomously-created public PR | [Invariant Labs](https://invariantlabs.ai/blog/mcp-github-vulnerability) |
| 2025-07-22 | SEP-1024 (MCP Client Security Requirements for Local Server Installation) reached Final status | [SEP-1024](https://modelcontextprotocol.io/seps/1024-mcp-client-security-requirements-for-local-server-.md) |
| 2025-07-29 | Invariant Labs released toxic flow analysis and `mcp-scan`, scoring an agent's tool-flow graph for lethal-trifecta paths | [Invariant Labs](https://invariantlabs.ai/blog/toxic-flow-analysis) |
| 2026-01-24 | *Breaking the Protocol* published; first rigorous security analysis of the MCP architecture by name | [arXiv 2601.17549](https://arxiv.org/abs/2601.17549) |
| 2026-02-04 | CVE-2026-25536 published; the ecosystem's first high-severity data-leak bug in the reference SDK, in the stateless pattern the spec had just introduced | [GHSA-345p-7cg4-v4c7](https://github.com/advisories/GHSA-345p-7cg4-v4c7) |
| 2026-05-14 | CVE-2026-44429, the stored-XSS poisoning path into the public MCP Registry catalogue, published | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-44429) |
| 2026-05-21 | ACP `logout` stabilized | [ACP updates](https://agentclientprotocol.com/updates) |
| 2026-06-13 | MCP Security Interest Group chartered | [Charter](https://modelcontextprotocol.io/community/interest-groups/security.md) |
| 2026-07-28 | MCP current revision: stateless, MRTR, caching directives, opt-in `listChanged`, DCR deprecated. State handle hijacking replaces session hijacking in the risk list | [changelog](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2026-07-28/changelog.mdx) |
| 2026-07-28 | Microsoft publishes the only first-party vendor threat page found: "1. Rug-Pull Attack (Agent / MCP Server)", updated 2026-08-01 | [Microsoft Zero Trust catalog](https://learn.microsoft.com/en-us/security/zero-trust/catalog-ai-attack-techniques/rug-pull-attack) |
| 2026-09-15 | *Breaking the Protocol* and the other MCP security literature remain the newest independent analysis; SEP-2809 ATSA is still Draft at the research date | [SEP index](https://modelcontextprotocol.io/seps/index.md) |

The 2026-07-28 revision is the pivot point for the whole record. It removed
`Mcp-Session-Id`, the `initialize` handshake, server-initiated `sampling/createMessage`,
`elicitation/create` and `roots/list`; introduced the Multi Round-Trip Requests pattern
and a mandatory `server/discover`; partitioned error codes with `-32020` to `-32022`
spec-reserved; and made `ttlMs` and `cacheScope` required on list results. The
[deprecated features registry](https://modelcontextprotocol.io/specification/2026-07-28/deprecated.md)
lists Roots, Sampling, Logging and DCR as deprecated with earliest removal on or after
2027-07-28; nothing is Removed yet.

## Evidence of adoption

### Independent research

**Invariant Labs**, Snyk's research division, with Luca Beurer-Kellner, Marco Milanta
and Marc Fischer, has produced the three most-cited primary demonstrations:

- 2025-04-06: tool poisoning via hidden instructions in tool descriptions at
  registration time.
- 2025-05-26: the GitHub MCP exfiltration chain, demonstrated with Claude 4 Opus and
  Claude Desktop against an "Always Allow" confirmation policy. Their assessment is
  that "this is not a flaw in the GitHub MCP server code itself, but rather a
  fundamental architectural issue that must be addressed at the agent system
  level… GitHub alone cannot resolve this vulnerability through server-side patches."
  They also report that state-of-the-art aligned models and off-the-shelf
  prompt-injection detectors failed to catch it.
- 2025-07-29: toxic flow analysis and `mcp-scan`, modelling the agent's tool-flow graph
  and scoring potential toxic flows, citing Simon Willison's "the lethal trifecta"
  (2025-06-16) — untrusted instructions, sensitive data, and a way to exfiltrate. TFA
  is a product framework, not peer-reviewed.

**arXiv [2601.17549](https://arxiv.org/abs/2601.17549)**, "Breaking the Protocol:
Security Analysis of the Model Context Protocol Specification and Prompt Injection
Vulnerabilities in Tool-Integrated LLM Agents", Narek Maloyan and Dmitry Namiot,
2026-01-24. Three protocol-level findings: absence of capability attestation, so
servers may claim arbitrary permissions; bidirectional sampling without origin
authentication, so server-side prompt injection; and implicit trust propagation in
multi-server configurations. `MCPBench` covers 847 attack scenarios across five MCP
server implementations and finds 23–41% higher attack success than equivalent non-MCP
integrations. Attack success drops from 52.8% to 12.4% with their `MCPSec` extension
(capability attestation plus message authentication) at +8.3 ms median latency. The
paper's conclusion is that "MCP's security weaknesses are architectural rather than
implementation-specific, requiring protocol-level remediation." The numbers are the
authors' own and the paper was unreviewed at the time of reading. `[UNVERIFIED]`

Titled but not read in full: [arXiv 2508.12538](https://arxiv.org/abs/2508.12538)
Systematic Analysis of MCP Security;
[arXiv 2508.14925](https://arxiv.org/abs/2508.14925), MCPTox, a tool-poisoning
benchmark on real-world servers;
[arXiv 2603.22489](https://arxiv.org/abs/2603.22489), MCP threat modelling with tool
poisoning; [arXiv 2606.27027](https://arxiv.org/abs/2606.27027), ShareLock, multi-tool
threshold poisoning.

**Government.** The NSA Cybersecurity Information Sheet "Model Context Protocol (MCP):
Security Design Considerations for AI-Driven Automation", document U/OO/6030316-26,
PP-26-1834, May 2026 Ver. 1.0, was announced 2026-05-20. The PDF is hosted at nsa.gov
and mirrored at media.defense.gov; both returned HTTP 403 to the researcher. Existence,
title, document number, version and date are confirmed from the NSA press-release index
and the PDF header string. Secondary summaries report 23 discrete security issues across
inversion of control and trust boundaries, arbitrary code execution (CWE-77, CWE-78,
CWE-94, CWE-95), serialization and context sharing, and agent misuse with autonomous
overreach. The substance is `[UNVERIFIED]`; a first-party state publication is exactly
the kind of source that should be read directly.

### Client-side controls, none of them required by any specification

| Control | Detail | Source |
| --- | --- | --- |
| Workspace trust gate | Since v2.1.196 a cloned repository cannot approve its own `.mcp.json` servers — a direct client-side mitigation of the CVE-2026-47751 class | [Claude Code MCP](https://code.claude.com/docs/en/mcp) |
| Secrets referenced, never embedded | `mcp_servers` declared on the agent by name and URL with no tokens; credentials supplied per session by `vault_ids`; MCP toolset defaults to `always_ask`; output over 100,000 characters spilled to a sandbox file with a truncated preview | [Claude Managed Agents MCP connector](https://platform.claude.com/docs/en/managed-agents/mcp-connector) |
| Conditional tool registration | Unauthorized tools are never registered, so the model never sees them, as distinct from a denial the LLM reads | [Cloudflare MCP authorization](https://developers.cloudflare.com/agents/model-context-protocol/protocol/authorization/index.md) |
| Per-tool approval and allowlists | `require_approval` and `allowed_tools`; `agentic-identity` as a connection auth type distinct from managed identity and user tokens | [Foundry MCP tool](https://raw.githubusercontent.com/MicrosoftDocs/azure-ai-docs/main/articles/foundry/agents/how-to/tools/model-context-protocol.md) |
| Allowlist, network modes, description-change detection | MCP allowlist of command and URL patterns with per-server tool allowlists; four network modes including an explicit "No sandbox" opt-out; local detection of tool description changes | [Cursor MCP](https://cursor.com/docs/mcp) |
| No autonomous approval in the cloud agent | "Copilot will use available tools autonomously, and will not ask for approval before use" — a materially different risk from the CLI and IDE surfaces on the same protocol | [GitHub Copilot MCP](https://docs.github.com/en/copilot/concepts/agents/coding-agent/mcp-and-coding-agent) |
| Local description-change detection | Present in Claude Code and MCP Manager; not required by the spec | [Claude Code MCP](https://code.claude.com/docs/en/mcp) |

Microsoft states in its own Foundry documentation that it "doesn't test or verify"
third-party MCP servers, and its own best-practice guidance says to treat remote tool
descriptions, annotations and results as untrusted input that can carry indirect prompt
injection. That is a vendor confirming the research consensus in vendor documentation.

### Platform-level identity work

The controls that actually bind an agent to a principal currently live in vendor
identity systems, not in any of the three specifications.

| Platform | Mechanism | Source |
| --- | --- | --- |
| AWS | AgentCore Identity: distinct identities per agent, integrating Okta, Microsoft Entra ID and Cognito; inbound OAuth 2.0 or SigV4; outbound IAM execution role or managed OAuth for Slack, Zoom and GitHub; per-session microVM isolation with memory sanitization on teardown; Gateway authorizers `NONE` or `CUSTOM_JWT` with OIDC discovery URL and allowed audience | [AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agents-tools-runtime.html), [Gateway quick start](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-quick-start.html) |
| Microsoft | `agentic-identity` as a distinct A2A connection auth type, the agent's own per-project identity, alongside `project-managed-identity` and `user-entra-token`; `Foundry Agent Consumer` RBAC; Microsoft Agent 365 for agent inventory and governance; Purview sensitivity labels; Sentinel; Prompt Shields; a private-subnet requirement for private MCP endpoints | [Foundry A2A tool](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/agent-to-agent) |
| Google | IAM agent identity for Agent Engine, Agent Gateway, a Private Service Connect interface, bidirectional streaming | [Gemini Enterprise Agent Platform](https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale) |
| Anthropic | Managed Agents vaults: credentials referenced per session by ID, never present in the reusable agent definition, with `always_ask` as the default MCP tool permission policy | [Managed Agents MCP connector](https://platform.claude.com/docs/en/managed-agents/mcp-connector) |
| Google (payments) | AP2, the Agent Payments Protocol, at 60+ organizations per the Linux Foundation release; UCP compatibility via an "AP2 mandates extension" capturing "strong cryptographic evidence of the user's consent to purchase" | [Linux Foundation, 2026-04-09](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year) — `[UNVERIFIED]`, single-sourced to that release |

The AP2 line matters because it is the one area where a cryptographic consent artifact
is being designed as a first-class protocol object rather than an optional card
signature, addressing agent authorization for irreversible real-world actions.

### The registries are the supply-chain surface

The official [MCP Registry moderation policy](https://modelcontextprotocol.io/registry/moderation-policy.md)
disclaims the trust role explicitly. The registry "does not make guarantees about
moderation, and consumers should assume minimal-to-no moderation", and under "What We
Don't Remove" it lists "Servers with security vulnerabilities."

| Property | Value | Source |
| --- | --- | --- |
| Moderation stance | "Quite permissive"; servers with security vulnerabilities are kept | [moderation policy](https://modelcontextprotocol.io/registry/moderation-policy.md) |
| Removal semantics | `status: "deleted"`, but metadata remains accessible via the API | [moderation policy](https://modelcontextprotocol.io/registry/moderation-policy.md) |
| Unpublishing | Not possible; issue #104 open | [registry FAQ](https://modelcontextprotocol.io/registry/faq.md) |
| Status | Preview; no uptime or durability guarantees | [registry aggregators](https://modelcontextprotocol.io/registry/registry-aggregators.md) |
| Read API | Unauthenticated, read-only REST | [registry aggregators](https://modelcontextprotocol.io/registry/registry-aggregators.md) |
| Publish token | `POST /v0/auth/github-at` with any GitHub account, or `POST /v0/auth/none` on a deployment with anonymous auth | [CVE-2026-44429 analysis](https://nvd.nist.gov/vuln/detail/CVE-2026-44429) |
| Subregistry `_meta` | Subregistries may inject arbitrary namespaces such as `com.example.subregistry/custom` carrying user ratings and security scan results; the official registry does not validate them | [registry aggregators](https://modelcontextprotocol.io/registry/registry-aggregators.md) |
| `_meta` size limit | 4 KB | [registry FAQ](https://modelcontextprotocol.io/registry/faq.md) |

Curation and image scanning therefore happen in the subregistry layer, not in the
official registry: the [Docker MCP Catalog](https://docs.docker.com/ai/mcp-catalog-and-toolkit/catalog)
and [Docker MCP Registry](https://github.com/docker/mcp-registry), the
[Cloudflare MCP catalog](https://www.cloudflare.com/developer-platform/products/mcp-catalog/),
GitHub's registry, and Netlify running the Cloudflare catalog as a subregistry. The
[Docker MCP Gateway](https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/)
is the clearest isolation control: servers run in isolated containers with restricted
privileges, network and resources, with per-server logging and call tracing.

## Sharp edges

### Structurally unmitigated, with the reasoning for each

1. **No message-level integrity, no replay protection.** Neither MCP nor A2A signs a
   single message. TLS ends at the first proxy, so a compromised proxy, gateway or
   host can rewrite a JSON-RPC body and nothing in the protocol detects it. The
   reasoning that the gap persists: the closest work is `draft-sharif-mcps-secure-mcp`
   ("Secure MCP — Message Signing and Tool Integrity"), an individual IETF draft that
   the specification does not reference. Message signing was not on the Security IG
   agenda at the research date, which suggests the maintainers regard the loss as
   acceptable or out of scope.
2. **No tool-definition pinning or post-approval change semantics.** Rug pull is a
   named attack with a named OWASP category and zero protocol-level answer; the Security
   IG carries it as Open. The 2026-07-28 revision can widen the window rather than
   narrow it: `ttlMs` and `cacheScope` let a client cache a tool list for an hour, and
   `listChanged` notifications are opt-in per type through `subscriptions/listen`, so a
   client that does not subscribe will not learn that tools changed. Caching is a cost
   control; the exposure window follows from it. The same revision's deprecations of
   Roots, Sampling and Logging force large client changes on a dated schedule, which
   gives an attacker a predictable maintenance window.
3. **No capability attestation.** Servers may claim arbitrary permissions and clients
   have no way to verify them. This is finding (1) of
   [arXiv 2601.17549](https://arxiv.org/abs/2601.17549) and the subject of SEP-2809
   Attested Tool-Server Admission, which is Draft. The same paper measures attack
   success falling from 52.8% to 12.4% with attestation plus message authentication,
   so the mitigation is quantified in the literature and absent from the wire format.
4. **No cross-server isolation.** Every connected server's tool descriptions share one
   LLM context, so a malicious server can influence an agent's behaviour toward
   trusted servers. Tool shadowing has no protocol-level defence; OWASP's guidance is to
   treat each server as an untrusted independent security domain and enforce isolation
   in a gateway. The reasoning that the gap persists is structural rather than
   editorial: a single flat tool namespace is what makes multi-server agents usable, so
   isolation has to live above the protocol.
5. **No sender-constrained tokens.** DPoP and RFC 9449 are absent from the
   authorization spec's Standards Compliance list, there is no DPoP SEP among the 42
   Final [SEPs](https://modelcontextprotocol.io/seps/index.md), and no DPoP extension
   exists in `ext-auth` (only OAuth Client Credentials and Enterprise-Managed
   Authorization). The [client matrix](https://modelcontextprotocol.io/extensions/client-matrix.md)
   footnote separates auth-extension support from core authorization features and says
   nothing about DPoP. The consequence is that access tokens remain replayable bearer
   tokens, so a leaked token is a full-privilege credential — which is why the
   Anthropic vault design and Cloudflare's `context.http.authInfo` matter as much as
   anything in the specification.
6. **Authorization is optional, and the specification permits replacing it.** §B5 of
   the authorization spec concedes that `iss` validation "depends on that recorded value
   being authentic; it provides no protection if the expected issuer was obtained from
   an unvalidated source", and that clients and servers MAY negotiate their own
   authentication and authorization strategies. `[INFERENCE]` Optional-by-default
   authorization over a protocol whose security properties are the entire reason it
   exists is the deepest unresolved tension in the specification.
7. **A2A: agent identity is optional and in-task authorization is undefined by design.**
   §7.6.4 is a maintainer-acknowledged hole. With no mandated audience binding and no
   `iss` validation, an A2A deployment must supply both out of band.
8. **ACP: no threat model for the remote transports that are about to exist.** The
   Transports working group's Draft RFD would give ACP a network-facing surface with no
   published analysis of it.

### Evidence caveat: the asserted DPoP SEP

Several secondary blogs and one search summary assert an "SEP-1932 DPoP Profile for
MCP" and "MCP TypeScript SDK 2.1.0" DPoP support. **Neither could be verified from any
primary source.** There is no trace of either in the authorization specification, its
Standards Compliance list, the 42-SEP index, or the extension repositories, and RFC 9449
does not appear in the compliance list. These claims are `[UNVERIFIED]` and the working
assessment is that they are wrong. Any wire-level DPoP value in `src/` would rest on a
source that does not exist.

The term "line jumping" is a second such case: no primary source uses it for this
attack class. `[UNVERIFIED-ABSENT]`.

### Deliberate policy and design choices that are not flaws

These shape risk without being defects:

- The registry's permissive moderation stance and its explicit "minimal-to-no
  moderation" disclaimer. The project has chosen a discoverability model over a
  curation model and has said so.
- The MANDATORY-versus-SHOULD split inside Security Best Practices, where the
  confused-deputy and SSRF mitigations are guidance rather than requirements.
- Conformance suites that verify protocol shape and exclude authorization-server
  behaviour, on the stated grounds that authorization server implementation is beyond
  the specification's scope.
- The community-maintained accuracy of the extension client matrix.
- The fact that most MCP servers in production are unauthenticated local stdio
  processes, for which the protocol's entire authorization framework does not apply. The
  authorization specification's advice is to not follow it in that case and take
  credentials from the environment instead.

### Two present-day sharp edges outside the protocols

The ACP name collision: an unrelated project `agent-control-protocol/acp` — a WebSocket
UI-automation protocol, itself at "Version 2.0, Draft, 2026-03-28" — also calls itself
ACP. Anyone installing "ACP" by name is exposed to a typosquat.

The client capability default: ACP agents are handed `fs` and `terminal` capabilities by
the client, and in JetBrains AI Assistant `default_mcp_settings.use_custom_mcp`
defaults to `true`, so user-configured MCP servers are exposed to third-party ACP agents
by default. `use_idea_mcp` defaults to `false`.

### Two closing observations

**The security-relevant convergence is at the client, not the server.** Nearly every
serious 2026 CVE in this space is a client or harness bug: Claude Code Action trusting a
repository's `.mcp.json`, the TypeScript SDK misrouting responses across clients, the
Java SDK's missing origin check, Cursor's default-exposing `use_custom_mcp` into ACP
agents. The servers are where researchers went looking for the novel attacks; the
breaches are landing where the trust decisions are made.

**The mitigations are arriving as client policy faster than as protocol requirement.**
GitHub's cloud agent using MCP tools autonomously with no approval; Claude Code's
workspace-trust gate on `.mcp.json` approvals; Anthropic's `always_ask` default plus
vaults; Cursor's allowlists and four network modes including an explicit no-sandbox
opt-out; Microsoft's `require_approval` and `allowed_tools`; Cloudflare's conditional
tool registration. Every one of these is a real control, and none of them is required by
the MCP specification or tested by the conformance framework. A deployment's actual
posture is roughly the union of what its weakest client enforces, and the
`MAY negotiate their own authentication` clause makes that union entirely the
deployer's problem.

### Open questions the sources do not answer

- How many of the 42 Final SEPs touch security, and which of the six open Security IG
  items will become specification changes. `NOT ESTABLISHED IN SOURCE`.
- Whether the A2A TCK covers the §13.1 multi-tenancy scoping MUSTs. No such test was
  found; whether one exists is `NOT ESTABLISHED IN SOURCE`.
- The number of MCP servers in the public registry, and what share carry a subregistry
  security-scan result. `NOT ESTABLISHED IN SOURCE`.
- Whether any deployment has applied message signing from
  `draft-sharif-mcps-secure-mcp` in production. `NOT ESTABLISHED IN SOURCE`.
- Any CVE against A2A or ACP implementations. None was found; absence of evidence is
  reported as such.

## Sources

Protocol specifications and project pages:

- MCP specification, revision 2026-07-28 —
  [basic](https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md),
  [authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/index.md),
  [authorization security considerations](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations.md),
  [deprecated features](https://modelcontextprotocol.io/specification/2026-07-28/deprecated.md)
- MCP [changelog 2026-07-28](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2026-07-28/changelog.mdx),
  [changelog 2025-11-25](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2025-11-25/changelog.mdx),
  [versioning](https://modelcontextprotocol.io/docs/2026-07-28/learn/versioning.md),
  [Security Best Practices](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices.md)
- MCP [SEP index](https://modelcontextprotocol.io/seps/index.md),
  [SEP-1024](https://modelcontextprotocol.io/seps/1024-mcp-client-security-requirements-for-local-server-.md),
  [Security Interest Group charter](https://modelcontextprotocol.io/community/interest-groups/security.md)
- MCP registry [moderation policy](https://modelcontextprotocol.io/registry/moderation-policy.md),
  [FAQ](https://modelcontextprotocol.io/registry/faq.md),
  [aggregators and subregistries](https://modelcontextprotocol.io/registry/registry-aggregators.md)
- MCP [extensions overview](https://modelcontextprotocol.io/extensions/overview.md),
  [extension client matrix](https://modelcontextprotocol.io/extensions/client-matrix.md),
  [conformance framework README](https://raw.githubusercontent.com/modelcontextprotocol/conformance/main/README.md)
- A2A 1.0 [specification](https://raw.githubusercontent.com/a2aproject/A2A/main/docs/specification.md),
  [v1.0 release, 2026-03-12](https://a2a-protocol.org/latest/blog/2026/03/12/a2a-protocol-ships-v10-production-ready-standard-for-agent-to-agent-communication/),
  [roadmap](https://a2a-protocol.org/latest/roadmap/)
- ACP [v1 schema](https://agentclientprotocol.com/protocol/v1/schema),
  [updates feed](https://agentclientprotocol.com/updates)

Threat taxonomies and research:

- [OWASP MCP Top 10](https://owasp.org/projects/mcp-top-10) (2025, beta)
- [OWASP MCP Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html)
- Maloyan and Namiot, [arXiv 2601.17549](https://arxiv.org/abs/2601.17549), 2026-01-24;
  [HTML full text](https://arxiv.org/html/2601.17549)
- Invariant Labs, [GitHub MCP exploited, 2025-05-26](https://invariantlabs.ai/blog/mcp-github-vulnerability);
  [toxic flow analysis, 2025-07-29](https://invariantlabs.ai/blog/toxic-flow-analysis)
- Listed, not read: [arXiv 2508.12538](https://arxiv.org/abs/2508.12538),
  [arXiv 2508.14925](https://arxiv.org/abs/2508.14925),
  [arXiv 2603.22489](https://arxiv.org/abs/2603.22489),
  [arXiv 2606.27027](https://arxiv.org/abs/2606.27027); Cloud Security Alliance research
  note "MCP Security Crisis", 2026-05-04; Palo Alto Networks Unit 42 guide, 2025-10-09;
  Legit Security finding on GitLab Duo
- NSA/AISC Cybersecurity Information Sheet U/OO/6030316-26, PP-26-1834, May 2026
  Ver. 1.0, announced 2026-05-20. Hosted at nsa.gov and mirrored at
  media.defense.gov; both returned HTTP 403. Not linked: the resource could not be
  retrieved. Existence, title, document number, version and date are confirmed; the
  substance is `[UNVERIFIED]`.

Vulnerability records:

- [GHSA-345p-7cg4-v4c7 / CVE-2026-25536](https://github.com/advisories/GHSA-345p-7cg4-v4c7)
- [GHSA-8q5r-mmjf-575q / CVE-2026-47751](https://github.com/advisories/GHSA-8q5r-mmjf-575q)
- [CVE-2026-44429](https://nvd.nist.gov/vuln/detail/CVE-2026-44429)
- [CVE-2026-35568](https://nvd.nist.gov/vuln/detail/CVE-2026-35568),
  [GHSA-8jxr-pr72-r468](https://github.com/advisories/GHSA-8jxr-pr72-r468)
- CVE-2026-27735, CVE-2026-27826, CVE-2026-40576, CVE-2026-44969, CVE-2026-44427,
  CVE-2026-61459, CVE-2026-30856, CVE-2026-25723, CVE-2026-35603, CVE-2026-31862,
  CVE-2026-39861, CVE-2026-25725 and GHSA-qxfv-fcpc-w36x: located through NVD and search
  listings. Detail beyond the one-line description is `[UNVERIFIED]`.

Vendor documentation and foundation announcements:

- [Linux Foundation, AAIF formation, 2025-12-09](https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation-aaif-anchored-by-new-project-contributions-including-model-context-protocol-mcp-goose-and-agents-md);
  [A2A one-year release, 2026-04-09](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year)
- AWS: [AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agents-tools-runtime.html),
  [MCP protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html),
  [A2A support, 2025-11-11](https://aws.amazon.com/blogs/machine-learning/introducing-agent-to-agent-protocol-support-in-amazon-bedrock-agentcore-runtime/),
  [Gateway quick start](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-quick-start.html)
- Microsoft: [Zero Trust catalog, rug-pull attack, 2026-07-28](https://learn.microsoft.com/en-us/security/zero-trust/catalog-ai-attack-techniques/rug-pull-attack),
  [Foundry A2A tool](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/agent-to-agent),
  [Foundry MCP tool](https://raw.githubusercontent.com/MicrosoftDocs/azure-ai-docs/main/articles/foundry/agents/how-to/tools/model-context-protocol.md)
- Google: [Gemini Enterprise Agent Platform](https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale)
- Anthropic: [Claude Code MCP](https://code.claude.com/docs/en/mcp),
  [Managed Agents MCP connector](https://platform.claude.com/docs/en/managed-agents/mcp-connector),
  [Claude API MCP connector](https://platform.claude.com/docs/en/agents-and-tools/mcp-connector)
- GitHub: [Copilot MCP](https://docs.github.com/en/copilot/concepts/agents/coding-agent/mcp-and-coding-agent)
- Cursor [MCP docs](https://cursor.com/docs/mcp)
- JetBrains [AI Assistant ACP docs](https://www.jetbrains.com/help/ai-assistant/acp.html)
- Cloudflare: [MCP authorization](https://developers.cloudflare.com/agents/model-context-protocol/protocol/authorization/index.md),
  [Secure MCP servers with Access, 2026-07-09](https://developers.cloudflare.com/cloudflare-one/access-controls/ai-controls/secure-mcp-servers/index.md),
  [MCP catalog](https://www.cloudflare.com/developer-platform/products/mcp-catalog/)
- Docker: [MCP Gateway](https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/),
  [MCP Catalog](https://docs.docker.com/ai/mcp-catalog-and-toolkit/catalog),
  [mcp-registry repository](https://github.com/docker/mcp-registry)
- Netlify, [MCP goes stateless and extensible, 2026-09-29](https://www.netlify.com/blog/mcp-goes-stateless-and-extensible/)
