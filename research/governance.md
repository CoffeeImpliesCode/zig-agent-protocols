# Governance of the agent protocol set

Who owns each agent wire protocol, under what licence, through which decision
process, and by what route it arrived there. This document covers the Agentic AI
Foundation, the other Linux Foundation vehicles, FIDO, IETF, W3C, the AAIF
project-proposal census, and the surfaces that have no governor at all. It does
not cover protocol wire values or security posture; those are in the
per-protocol and cross-cutting documents listed in [`README.md`](README.md).
Where adoption appears below, it means institutional adoption — members, seated
boards, filed proposals — not the deployment numbers.

- Research date: **2026-09-29**
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values
  live there
- Evidence: this file

Every claim below carries the primary URL the source sweep traced it to.
`[UNVERIFIED]` marks what the source could not confirm against a primary page.
`NOT ESTABLISHED IN SOURCE` marks a value the source did not carry, so nothing
here is a guess.

## State

### The Agentic AI Foundation

AAIF is a Linux Foundation directed fund. It was formed on **2025-12-09**
alongside Anthropic's donation of MCP
([Anthropic announcement](https://www.anthropic.com/news/donating-the-model-context-protocol-and-establishing-of-the-agentic-ai-foundation),
[LF formation release](https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation)).
The source sweep did not establish the fund's own founding instrument, its
legal form relative to the LF, or a separate incorporation date: NOT ESTABLISHED
IN SOURCE beyond the 2025-12-09 formation release.

Founding projects at formation were **MCP, goose and AGENTS.md**. Co-founders
named in the Anthropic announcement are **Anthropic, Block and OpenAI**, with
declared support from **Google, Microsoft, AWS, Cloudflare and Bloomberg**.

The current hosted-project roster is **exactly six**
([aaif.io/projects](https://aaif.io/projects)):

| # | Hosted project | Maturity / stage | Governance path |
| --- | --- | --- | --- |
| 1 | MCP (Model Context Protocol) | Production standard; AAIF stage label NOT ESTABLISHED IN SOURCE | Donated into AAIF 2025-12-09 |
| 2 | A2A (Agent2Agent) | Growth Stage | LF project 2025-06-23, admitted to AAIF 2026-08-04 |
| 3 | goose | NOT ESTABLISHED IN SOURCE | Hosted since formation |
| 4 | AGENTS.md | NOT ESTABLISHED IN SOURCE | Hosted since formation |
| 5 | agentgateway | Growth | Proposal #11, approved, closed 2026-05-21 |
| 6 | Agent Router (ex-Envoy AI Gateway) | Growth | Proposal #18, approved, closed 2026-09-10 |

The other LF vehicles are **not** AAIF: AGNTCY sits directly under the Linux
Foundation, and the x402 Foundation is a separate LF body. AAIF is one LF
vehicle among several, not the LF's agentic monopoly.

### The board and the working groups

Per the LF member release of 2026-02-24
([aaif.io/news/aaif-welcomes-97-new-members](https://aaif.io/news/aaif-welcomes-97-new-members)):

- **Membership:** 97 new members joined, bringing the total to **146**.
- **Board chair:** **David Nalley (AWS)** was appointed governing board chair.
- **New Gold members** named in the release include **Huawei, JPMorgan Chase,
  American Express, Circle and Workato**.
- Named in the source sweep, from the proposal records: **Nick Cooper (OpenAI)**
  is an AAIF governing board member and an MCP Core Maintainer. Whether the
  board chair is a separate seat from the board membership is not stated in
  source: NOT ESTABLISHED IN SOURCE.

The AAIF runs **eight working groups**; the source names two from the
[aaif.io/about](https://aaif.io/about) summary — **Agentic Commerce** and
**Identity & Trust** — plus a **Governance, Risk & Regulatory Alignment** group
that the source describes as mapping explicitly to the EU AI Act. The remaining
five working-group names and the full board roster: NOT ESTABLISHED IN SOURCE.

### Admission: the public TC → GB vote gate

Projects enter AAIF through a public Technical Committee → Governing Board vote
recorded in the issue tracker at
[github.com/aaif/project-proposals](https://github.com/aaif/project-proposals/issues).
This tracker is the authoritative, dated record of which agent projects are
trying to reach neutral governance and which the foundation accepted. The gate
is a real filter, not a rubber stamp (see [Sharp edges](#sharp-edges)).

### Governance owner and licence, by protocol

| Protocol | Governance owner | Licence | Transition timeline |
| --- | --- | --- | --- |
| **MCP** | AAIF → "Model Context Protocol a Series of LF Projects, LLC" ([governance](https://modelcontextprotocol.io/community/governance)) | Apache-2.0 for code and specs; CC-BY-4.0 for non-spec docs; **no CLA**, copyright stays with contributor | Donated 2025-12-09; technical model deliberately unchanged; IP/trademark moved to LF Projects, LLC, so governance changes now need LF Projects, LLC approval |
| **A2A** | AAIF, Growth Stage | Apache-2.0 (contributed by Google) | Google launch 2025-04-09 → LF project 2025-06-23 → AAIF proposal #37 approved, closed 2026-08-04 → AAIF blog 2026-08-17 → A2A blog 2026-08-27 |
| **ACP** (Zed, JetBrains) | **Interim** — Zed + JetBrains jointly, BDFL ([governance](https://agentclientprotocol.com/community/governance)); AAIF transition in flight | Apache-2.0, **no CLA** | JetBrains joins 2025-10-06; co-BDFL 2026-02-18; files to AAIF 2026-04-01 (proposal #1); still unsigned and not an AAIF project on the research date |
| **Open Responses** | AAIF pending (#41, Impact stage) | Apache-2.0 code, CC-BY-4.0 spec text; DCO sign-off | Public launch January 2026; spec revisions 2026-01-15 and 2026-04-24; filed to AAIF 2026-08-21 |
| **Agent Skills / SKILL.md** | Anthropic-origin; AAIF pending (#47) | Apache-2.0 + CC-BY-4.0 | Product 2025-10-16; published open standard 2025-12-18; filed to AAIF 2026-09-24, `TC Vote` |
| **agentgateway** | AAIF, Growth (#11) | NOT ESTABLISHED IN SOURCE | Approved, closed 2026-05-21; Cisco's project donated by Red Hat (author `linsun`) |
| **Agent Router** | AAIF, Growth (#18) | NOT ESTABLISHED IN SOURCE | Approved, closed 2026-09-10 (ex-Envoy AI Gateway) |
| **AG-UI** | **None.** Own org `ag-ui-protocol`, no `GOVERNANCE.md`, no foundation, no AAIF proposal ([org](https://github.com/orgs/ag-ui-protocol/repositories)) | MIT | Never had a governance process; the de facto owner is CopilotKit |
| **A2UI** | **None.** Google-created, no governance page, no foundation, no AAIF proposal ([a2ui.org](https://a2ui.org/)) | Apache-2.0 | No transition in flight |
| **UCP** | **None stated** ([ucp.dev](https://ucp.dev/)) | NOT ESTABLISHED IN SOURCE | Strong multi-vendor coalition, no TSC, no neutral home |
| **AP2** | **FIDO Alliance** — Agentic Authentication + Payments TWGs ([AP2 site](https://ap2-protocol.org/)) | NOT ESTABLISHED IN SOURCE | Google origin 2025-09-16 → donated to FIDO 2026-04-28 with v0.2; Mastercard Verifiable Intent also to FIDO |
| **x402** | **x402 Foundation**, separate LF body ([release](https://www.linuxfoundation.org/press/linux-foundation-announces-operational-launch-of-x402-foundation-to-standardize-internet-native-payments-for-ai-agents-and-applications)) | NOT ESTABLISHED IN SOURCE | Intent April 2026 → operational launch 2026-07-14 |
| **AGNTCY** | **Linux Foundation directly, not AAIF** ([docs](https://docs.agntcy.org/)) | NOT ESTABLISHED IN SOURCE | Cisco open-sourced 2025-03 → LF welcomed 2025-07-29 |
| **ANS** (Agent Name Service) | **LF intent only** ([release](https://www.linuxfoundation.org/press/linux-foundation-announces-intent-to-launch-agent-name-service-to-establish-trusted-identity-infrastructure-for-ai-agents)) | NOT ESTABLISHED IN SOURCE | Intent announced 2026-06-23; nothing chartered |
| **ANP** | AAIF proposal #46, label `New`, unreviewed, no sponsor | NOT ESTABLISHED IN SOURCE | Community launch April 2025; filed to AAIF 2026-09-24 |
| **Web Bot Auth** | **IETF WG** `webbotauth` ([documents](https://datatracker.ietf.org/group/webbotauth/documents/)) | NOT ESTABLISHED IN SOURCE (IETF default) | Cloudflare-originated; WG document dated 2026-09-01 |
| **agentproto** | **IETF Proposed WG** ([history](https://datatracker.ietf.org/group/agentproto/history/)) | NOT ESTABLISHED IN SOURCE (IETF default) | Created 2026-06-11 in BOF → Proposed 2026-09-09; second BoF request filed 2026-09-04 for IETF 127 |
| **WebMCP** | **W3C Community Group** (Web Machine Learning CG) ([report](https://webmachinelearning.github.io/webmcp/)) | NOT ESTABLISHED IN SOURCE | Draft Community Group Report dated 2026-09-29; not a W3C Standard |
| **Open Agent Auth** (Alibaba) | **None** ([site](https://alibaba.github.io/open-agent-auth/)) | Apache-2.0 | No foundation; named as existing practice in the agentproto BoF request |
| **Docker MCP Gateway / ToolHive** | **Vendor-governed, non-foundation** | ToolHive Apache-2.0; Docker Enterprise Gateway NOT ESTABLISHED IN SOURCE | Neither is a foundation project; the neutral-registry question (#29) is the open one |

### The AAIF project-proposal census

Full census of [github.com/aaif/project-proposals](https://github.com/aaif/project-proposals/issues)
as of 2026-09-29. Issue number, status and dated outcome are the record:

| # | Project | Status | Opened | Outcome / date |
| --- | --- | --- | --- | --- |
| 1 | Agent Client Protocol (ACP) | `TC Approved` + `GB Vote`, agreement **unsigned** | 2026-04-01 | pending |
| 7 | Agent Guard | Declined | — | 2026-05-03 |
| 11 | agentgateway | `Approved`, Growth | — | closed 2026-05-21 |
| 14 | Agent Passport System (APS) — crypto identity/delegation | **Declined** | — | 2026-05-15 |
| 18 | Agent Router (ex-Envoy AI Gateway) | `Approved`, Growth | — | closed 2026-09-10 |
| 19 | Agent Governance Toolkit | Declined | — | 2026-06-29 |
| 20, 25, 27, 33 | Nobulex / ai video screener / workspace.json / unnamed | Declined | — | 2026-05-15 → 05-31 |
| 29 | MCP Gateway Registry | `Under Review` | 2026-05-12 | open 4.5 months |
| 31 | Safe Zone | Declined `Too Early` | — | 2026-09-26 |
| 32 | Ferridis | Declined `Too Early` | — | 2026-09-26 |
| 34 | Durable Agents (ex-Dapr Agents) | Declined, `Sandbox` | — | 2026-09-11 |
| 37 | Agent2Agent (A2A) | `Approved`, Growth, signed | — | closed 2026-08-04 |
| 38 | Agent Governance & Accountability WG | Declined | — | 2026-09-28 |
| 39 | ContextForge | `Postponed` | 2026-08-13 | open |
| 40 | regent-httpsig | **Declined** | — | 2026-09-28 |
| 41 | Open Responses | `TC Approved` + `GB Vote`, Impact, signed pending | 2026-08-21 | pending |
| 42 | TRACE Specification | New | 2026-09-14 | open |
| 43 | RCAN: Robot Communication and Addressing Network | New | 2026-09-15 | open |
| 44 | RelayReady Sandbox | New | 2026-09-20 | open |
| 45 | PACT | New | 2026-09-21 | open |
| 46 | ANP | `New` (unreviewed) | 2026-09-24 | open |
| 47 | Agent Skills | `TC Vote` | 2026-09-24 | pending |
| 48 | Spector: Memory Engine for AI Agents | New | 2026-09-25 | open |
| 49 | Flywheel | New | 2026-09-28 | open |
| 50 | OpenEnv | New | 2026-09-28 | open |

The load-bearing fact: **AAIF intake is a real filter.** The source states that
**13 of 23 closed proposals are `Declined`**, and that three were declined in the
final four days before the research date. There is **no AG-UI, A2UI, or UCP
proposal** in the tracker. A2A waited roughly 14 months at LF before moving into
AAIF; ACP has been in the GB-vote queue for six months. The foundation also
declined two agent-identity/signing proposals — **#14 Agent Passport System**
(cryptographic identity and delegation, closed 2026-05-15) and **#40
regent-httpsig** (a sigstore/HTTPSig-for-agents candidate, closed 2026-09-28) —
which is why the ANS and IETF identity work matters.

### The other LF and standards vehicles

- **AGNTCY** — Linux Foundation directly, not AAIF. Cisco open-sourced it 2025-03
  (with LangChain and Galileo); LF welcomed it 2025-07-29. Formative members:
  Cisco, Dell, Google Cloud, Oracle, Red Hat; 65+ supporting companies. It is
  Cisco-originated and, two years on, has the least adoption of any LF-hosted
  agent project. ([LF release](https://www.linuxfoundation.org/press/linux-foundation-welcomes-the-agntcy-project-to-standardize-open-multi-agent-system-infrastructure-and-break-down-ai-agent-silos))
- **x402 Foundation** — separate LF body, operational launch 2026-07-14, 40
  members. Premier roster is overwhelmingly payments/financial (Stripe, Visa,
  Mastercard, Amex, Shopify, Google, Cloudflare, AWS, Coinbase, and others).
  It is a *payment* standard, not an agent-integration standard.
- **ANS** — LF **intent only** as of 2026-06-23; nothing chartered, no published
  specification. DNS-based agent identity; supports DIDs and Legal Entity
  Identifiers.
- **FIDO Alliance** — now governs AP2 and Mastercard Verifiable Intent. See
  [`commerce.md`](commerce.md) for the mechanism.

### IETF: substrate, not a fork

IETF is layering a transport and dialog substrate beneath the application-layer
protocols, and its charter says so explicitly. See
[the agentproto charter](https://raw.githubusercontent.com/ietf-artarea/charters/main/agentproto/charter.md)
under [What it does](#what-it-does) for the deferral clause.

Two live groups:

- **`agentproto`** — Proposed WG, "Agent Communication Protocols". Created
  2026-06-11 in state BOF; AD Charles Eckel; chairs Leslie Daigle and Orie Steele;
  the `agent2agent@ietf.org` list was renamed to `agentproto@ietf.org` on
  2026-07-24. WG-forming BoF at IETF 126, Vienna, 2026-07-23. State moved BOF →
  Proposed 2026-09-09. A second BoF request
  ([bofreq-steele-agentproto-00](https://datatracker.ietf.org/doc/bofreq-steele-agentproto/))
  dated 2026-09-04 targets IETF 127 with expected attendance 100. Nine named
  proponents span Cloudflare, Cisco, Alibaba, Nokia and Huawei
  ([documents](https://datatracker.ietf.org/group/agentproto/documents/)).
- **`webbotauth`** — active WG, Cloudflare-originated (Thibault Meunier, Sandor
  Major). WG document `draft-ietf-webbotauth-httpsig-protocol-00` dated
  2026-09-01, defining HTTP Message Signatures for automated traffic, the
  `Signature-Agent` header, a JWKS key directory and a well-known URI. It
  superseded a chain of individual drafts.

Individual, non-WG agent Internet-Drafts are also active in the
discovery/identity layer, including `draft-ni-agent-entity-discovery-00`
(Huawei, DNS AED resource record, 2026-07-06) and
`draft-aiendpoint-ai-discovery-01` (`/.well-known/ai`, 2026-07-28). See
[`identity-and-discovery.md`](identity-and-discovery.md).

### W3C: Community-Group level only

W3C activity is real but structurally weak — it is Community-Group level, with
no W3C Recommendation track, no W3C Patent Policy, and no membership
accountability.

- **AI Agent Protocol Community Group** — launched 2025-05-08, proposed by
  **gaowei chang** (ANP's author) with supporters Ruoxi Ran, Song Xu, Gavin Sze,
  Jomy Wu. Use-case and Protocol drafts both 2025-08-19; ANP white paper
  2025-05-23. Biweekly meetings. Effectively an ANP venue
  ([w3.org/community/agentprotocol](https://www.w3.org/community/agentprotocol/)).
- **WebMCP** — Draft Community Group Report dated 2026-09-29, Web Machine
  Learning CG. Editors Brandon Walderman (Microsoft), Khushal Sagar (Google),
  Dominic Farolino (Google). Exposes `document.modelContext.registerTool()`.
  "Not a W3C Standard" ([report](https://webmachinelearning.github.io/webmcp/)).
- `[UNVERIFIED]` — a W3C **Agent Identity Registry Protocol CG** (call for
  participation dated 2026-04-24) and an **AI Agent Memory Interoperability CG**;
  a **Web & AI IG** charter dated 2025-10. These come from secondary sources
  only and were not confirmed against w3.org.

## What it does

Governance bodies differ in *who can decide* and *what they are chartered to
decide*. The following is the decision machinery of each, as described by the
source.

### MCP: PyTorch-style hierarchy with a BDFL top

MCP's governance is a role hierarchy — Contributors → Maintainers → Core
Maintainers → Lead Maintainers — with the upper three tiers together forming the
**MCP Steering Group** ([governance page](https://modelcontextprotocol.io/community/governance)).
Lead Maintainers **David Soria Parra** and **Den Delimarsky** are BDFL and can
veto any Maintainer or Core Maintainer decision. Core Maintainers: Peter
Alexander, Caitie McCaffrey, Kurtis Van Gent, Clare Liguori, Paul Carleton,
Nick Cooper. Emeritus: Justin Spahr-Summers (co-inventor), Basil Hosmer, Che
Liu, Nick Aldridge.

Decision process for grouped work ([working-interest-groups](https://modelcontextprotocol.io/community/working-interest-groups)):
chartered Working and Interest Groups, lazy consensus (5-day minor, 10-day
significant) → formal vote (50% quorum, 2/3 for scope changes) → escalation to a
designated Core Maintainer. WG Leads commit 2–3 h/week and need sponsorship by
two Core Maintainers or one Lead Maintainer. Spec changes run through a SEP
process with a sponsor.

The `2026-07-28` release added the governance machinery the spec had lacked:
a feature lifecycle policy (Active/Deprecated/Removed, ≥12 months before
removal, with an expedited-removal exception), a conformance-suite gate on
Standards Track SEPs, and an SDK tier system.

### A2A: seated company TSC with an inactivity rule

A2A's [GOVERNANCE.md](https://raw.githubusercontent.com/a2aproject/A2A/main/GOVERNANCE.md)
defines an **eight-seat TSC** in a "Startup Phase", one seat each for **Google,
Microsoft, Cisco, AWS, Salesforce, ServiceNow, SAP and IBM**, each org
appointing a member. A "Steady State" composition is to be decided 18 months
after inception. Inactivity is enforced through LFX attendance tracking: **six
weeks** without attendance marks a member inactive, and their sponsor may
replace them. A membership-increase path exists only by majority vote of the
TSC. A2A is markedly *less* open to individuals than MCP, which seats people
rather than companies.

### Open Responses: individual-seat TSC with a vendor-majority ban

Open Responses is the only project in the set whose charter **explicitly bars
any single vendor from holding a majority of core-maintainer seats**. Its
eight-seat TSC is individuals, not companies: Steve Coffey (OpenAI, Lead Core
Maintainer), Ankit Mathur (Databricks), Anthony Liguori (Amazon/AWS), Ben
Burtenshaw (Hugging Face), Devon Rifkin (Ollama), Ji Huang (OpenAI), Matt
Apperson (OpenRouter), Shaun Smith (Hugging Face). Conformance is enforced
through OpenAPI schemas, dated immutable snapshots, a browser compliance
tester, a CLI acceptance suite, and a GitHub Actions PR gate.

### ACP: interim dual-company BDFL

ACP is jointly governed by **Zed and JetBrains**, explicitly "working toward
transitioning to an independent foundation"
([governance page](https://agentclientprotocol.com/community/governance)). Lead
Maintainers (BDFL) are **Ben Brandt (Zed Industries)** and **Sergey Ignatov
(JetBrains)**. Core Maintainers: Agus Zubiaga, Anna Zhdan, Niko Matsakis. The
model is "modeled heavily on MCP's governance". Spec changes run through an
**RFD (Request for Dialog)** process — Draft → Preview → Completed, each gated
by a core-team champion. ACP is the only major protocol here without a completed
neutral-governance story.

### IETF: the deferral clause

The `agentproto` [draft charter](https://raw.githubusercontent.com/ietf-artarea/charters/main/agentproto/charter.md)
states the IETF's position toward MCP and A2A in three clauses. It
"neither replaces application-layer agent communication protocols"; it defines
"extension points through which existing application-layer agent communication
protocols (e.g., MCP and A2A) can make use of it"; and it states that "changes
to those protocols themselves are the responsibility of their respective
maintainers and are, thus, out of scope."

The architecture that follows is IETF supplying the substrate and AAIF
supplying the semantics. `agentproto`'s chartered deliverable is an *Agentic
Dialog Management Protocol* (Standards Track) defining dialog identifiers,
lifecycle semantics and dialog-context propagation across multiple
intermediaries and trust boundaries, plus bindings over HTTP, QUIC, WebTransport,
WebRTC and MOQ, plus a Reference Architecture and a Use Cases & Requirements
document. Explicitly out of scope: agent behaviour and reasoning, hallucination
mitigation beyond user confirmation, and UI design.

One of the group's 13 related drafts binds both application-layer protocols
directly: `draft-jennings-agentproto-mcp-over-moqt-00`, *Model Context Protocol
and Agent Skills over Media over QUIC Transport*. `webbotauth` sits outside
`agentproto` and is not subject to its scope clause; it governs agent identity
and authorization on the web, not MCP/A2A semantics.

### Three governance models, ranked by accountability

The source ranks the three live models by accountability:

1. **A2A** — seated 8-company TSC with an inactivity rule.
2. **Open Responses** — individual-seat TSC with a single-vendor-majority ban.
3. **MCP** — BDFL-inside-a-foundation, where two Lead Maintainers can veto the
   layers below them.

AAIF's own TC → GB vote, with its decline rate, is itself a meaningful filter
layer above all three.

## What changed recently

| Date | Governance event |
| --- | --- |
| 2025-04-09 | Google launches A2A. |
| 2025-06-23 | A2A becomes an LF project (not LF AI & Data). |
| 2025-07-29 | LF welcomes AGNTCY. |
| 2025-08 | IBM's Agent Communication Protocol merges into A2A — the field collapsed rather than forked. |
| 2025-09-16 | Google announces AP2. |
| 2025-12-09 | **AAIF forms**; Anthropic donates MCP. Governance model declared unchanged. |
| 2026-01-26 | MCP Apps announced. |
| 2026-02-18 | Sergey Ignatov (JetBrains) promoted to ACP Lead Maintainer — Zed + JetBrains co-BDFL. |
| 2026-02-24 | AAIF: 97 new members → 146 total; David Nalley (AWS) appointed board chair; Huawei, JPMorgan Chase, Amex, Circle, Workato join as Gold. |
| 2026-03-12 | A2A v1.0 ships. |
| 2026-04-01 | ACP files to join AAIF (proposal #1). |
| 2026-04-28 | Google donates AP2 (with v0.2) and Mastercard Verifiable Intent to FIDO. |
| 2026-05-21 | agentgateway admitted to AAIF (proposal #11, closed). |
| 2026-06-11 | IETF creates `agentproto` group in BOF state. |
| 2026-06-23 | LF announces intent to launch ANS. |
| 2026-07-14 | x402 Foundation operational launch. |
| 2026-07-23 / 07-24 | IETF 126 Vienna BoF forms the WG (07-23); `agentproto@ietf.org` mailing-list rename (07-24). |
| 2026-08-04 | A2A admitted to AAIF (proposal #37, closed). |
| 2026-08-17 / 08-27 | AAIF blog and A2A blog announce A2A's Growth Stage admission. |
| 2026-09-01 | IETF `webbotauth` WG document `draft-ietf-webbotauth-httpsig-protocol-00`. |
| 2026-09-09 | `agentproto` state moves BOF → Proposed. |
| 2026-09-10 | Agent Router admitted to AAIF (proposal #18, closed). |
| 2026-09-24 | AAIF: Agent Skills proposal #47 and ANP proposal #46 filed. |
| 2026-09-26 → 09-28 | AAIF declines Safe Zone, Ferridis, Agent Governance & Accountability WG, and regent-httpsig. |
| 2026-09-29 | WebMCP Draft Community Group Report dated. |

## Evidence of adoption

Governance adoption is measured in members, hosted projects, and a queue of
proposals.

- **146 AAIF members** as of 2026-02-24, up 97 in a single announcement, with
  named Gold members spanning payments (JPMorgan Chase, Amex, Circle) and
  enterprise software (Workato).
- **Exactly six hosted projects** — the roster is small, which is itself the
  signal that intake is selective.
- **A populated proposal queue** running from issue #1 to #50. Two protocols
  are admitted (MCP at formation, A2A 2026-08-04), two more were admitted as
  infrastructure (agentgateway, Agent Router), and three sit in the GB-vote
  stage or awaiting one (ACP, Open Responses, Agent Skills).
- **A2A** reports 150+ supporting organizations and an 8-company TSC, and grew
  from 50+ to 150+ supporters over roughly a year.
- **Cross-regime participation:** Huawei is simultaneously a Gold AAIF member
  (announced 2026-02-24) and the largest IETF `agentproto` proponent; three of
  the group's nine named proponents are Huawei staff. [INFERENCE] — the source
  states the "largest proponent" claim without the count behind it.

## Sharp edges

- **The decline rate is the governance fact, but its arithmetic does not fully
  reconcile in source.** The source states "13 of 23 closed proposals are
  Declined" and elsewhere summarizes the gate as a "~65% decline rate". The
  census table above enumerates **12 distinct declined issue numbers** (7, 14,
  19, 20, 25, 27, 31, 32, 33, 34, 38, 40) against 3 approved (11, 18, 37).
  Neither 13/23 nor 12/15 is 65%, and the source does not say which
  denominator is authoritative: NOT ESTABLISHED IN SOURCE. The direction of
  the finding is not in doubt — intake rejects the large majority of what is
  filed, and the rejection is not topic-selective: it spans agent identity
  (#14, #40), governance tooling (#19, #38), sandboxes (#34, #44) and
  unclassifiable submissions. Note also that #14 Agent Passport System closed
  2026-05-15 and #40 regent-httpsig closed 2026-09-28: the source describes
  these as two agent-identity declines "in the same month", which the dates do
  not support.
- **A BDFL layer survives inside a foundation.** MCP's two Lead Maintainers can
  veto any decision below them — the asymmetry contributors keep contesting, and
  the reason a TSC is repeatedly proposed. A2A answered it with a seated
  company TSC and an attendance rule; Open Responses answered it with a
  vendor-majority ban.
- **The A2A attendance rule depends on a third-party platform.** Inactivity is
  enforced through LFX attendance tracking; whether a platform's attendance
  data is authoritative is a fragile foundation for a governance rule.
- **ACP is the open transition.** The AAIF contribution agreement is unsigned
  (proposal #1) and the governance page still reads "interim", so as of the
  research date ACP is not an AAIF project. The security contact is
  `security@zed.dev`.
- **Commerce governance is split across three bodies** with no cross-body
  memorandum: x402 at the LF (settlement), AP2 + Verifiable Intent at FIDO
  (authorization/intent), and A2A at AAIF (transport). The same agent must
  satisfy FIDO-credential, LF-settlement and AAIF-transport requirements under
  three different IP terms. The source frames this as defensible layering; the
  absence of a memorandum is the edge.
- **Identity is the contested surface.** Five live, uncoordinated agent-identity
  answers: ANS (DNS), IETF `AED` (DNS), ANP `did:wba` (DID), `webbotauth`
  (HTTPSig), and A2A signed Agent Cards.
- **The MCP name-collision hazard is a governance problem, not only a naming
  one.** "ACP" denotes at least four distinct things (Agent Client, Agent
  Communication, a commerce ACP, and the plural IETF "Agent Communication
  Protocols"). Governance ambiguity follows naming ambiguity.

### No protocol-level forks, in any region

The source's finding, for Chinese, EU and general ecosystems: **there are no
protocol-level forks anywhere.** What exists is deployment localization, not
specification divergence.

- **China:** vendors (Alibaba Higress, Tencent, Baidu, DeepSeek, MiniMax, Qwen)
  adopt MCP natively and layer **enterprise gateways** for traffic control,
  audit and data-residency compliance. Alibaba's Higress does OpenAPI →
  remote-MCP translation and MCP server management. Compliance-driven SDK
  forks exist (e.g. forcing `CODEBUDDY_INTERNET_ENVIRONMENT: "internal"`), but
  these are deployment forks, not spec forks, and are not announced as forks.
- **EU:** no EU fork exists. The EU's presence is regulatory pressure flowing
  *into* the neutral homes: AAIF has a dedicated Governance, Risk & Regulatory
  Alignment working group mapping to the EU AI Act, and Huawei is a Gold member
  while being the largest IETF `agentproto` proponent.
- The "East vs. West fork" framing is wrong for 2026. The real fault line is by
  *layer* — protocol (AAIF/IETF) vs. settlement (x402 at LF) vs. intent (FIDO)
  vs. carrier (3GPP/ITU-T) — and it does not map onto geography.

### The ungoverned-surface list

These ship with real adoption and no neutral governance. This is the concrete
open space:

| Surface | Evidence of adoption | Governance gap |
| --- | --- | --- |
| **AG-UI** (largest) | 16k stars, 1,657 contributing organizations, 49 merge-right maintainers, pushed 2026-09-29; LFX Insights tracks it | No `GOVERNANCE.md`, no foundation, no AAIF proposal, no neutral IP home, no CLA |
| **A2UI** | v0.9.1 current, v1.0 candidate; official Lit/Angular/Flutter/Markdown renderers plus community React/Compose | Google-created, no governance page, no foundation; competes with MCP Apps SEP-1865 and AG-UI |
| **UCP** | 13+ named co-developers across retail, lodging and food (Google, Shopify, Etsy, Wayfair, Target, Walmart, Amazon, Microsoft, Meta, Salesforce, Stripe, and others) | Strong commercial coalition, no TSC, no decision rule, no neutral home |
| **MCP Gateway Registry** | Docker MCP Gateway and ToolHive are both in production use | Non-foundation, vendor-governed competitors; the neutral registry (proposal #29) has been `Under Review` for 4.5 months since 2026-05-12 |

AG-UI's LFX Insights profile also flags **38 open critical/high vulnerabilities
and no `SECURITY.md`** — a supply-chain signal about implementations whose
absence of a published security policy is itself the governance gap. The
declarative-UI "declaration war" is otherwise largely settled: OpenAI's Apps
SDK and `mcp-ui` were absorbed into MCP Apps (SEP-1865), which shipped as an
official MCP extension in the `2026-07-28` release, resolving much of the
AG-UI/A2UI competition in MCP's favour.

## Sources

Every claim above traces to one of these primary pages, as captured by the
2026-09-29 source sweep. Where the sweep marked a claim unconfirmed, it is
tagged `[UNVERIFIED]` in the body.

**AAIF**
- [aaif.io/projects](https://aaif.io/projects) — the six hosted projects.
- [aaif.io/about](https://aaif.io/about) — governing board and eight working groups.
- [aaif.io/news/aaif-welcomes-97-new-members](https://aaif.io/news/aaif-welcomes-97-new-members) — 2026-02-24: 146 members, Nalley chair, new Gold list.
- [github.com/aaif/project-proposals](https://github.com/aaif/project-proposals/issues) — the proposal census.
- [aaif.io/blog/a2a-joins-aaif](https://aaif.io/blog/a2a-joins-aaif) — A2A admission.

**Formation**
- [Anthropic donation announcement](https://www.anthropic.com/news/donating-the-model-context-protocol-and-establishing-of-the-agentic-ai-foundation) — 2025-12-09, co-founders and supporters.
- [LF formation release](https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation) — 2025-12-09, founding projects and member tiers.

**MCP**
- [modelcontextprotocol.io/community/governance](https://modelcontextprotocol.io/community/governance) — LF Projects, LLC, roles, licence.
- [modelcontextprotocol.io/community/working-interest-groups](https://modelcontextprotocol.io/community/working-interest-groups) — decision process.

**A2A**
- [A2A GOVERNANCE.md](https://raw.githubusercontent.com/a2aproject/A2A/main/GOVERNANCE.md) — TSC seats and attendance rule.
- [LF A2A launch](https://www.linuxfoundation.org/press/linux-foundation-launches-the-agent2agent-protocol-project-to-enable-secure-intelligent-communication-between-ai-agents) — 2025-06-23.

**ACP**
- [agentclientprotocol.com/community/governance](https://agentclientprotocol.com/community/governance) — interim Zed + JetBrains model.
- [AAIF proposal #1](https://github.com/aaif/project-proposals/issues/1) — filed 2026-04-01, unsigned.

**IETF**
- [agentproto history](https://datatracker.ietf.org/group/agentproto/history/) — BOF → Proposed.
- [agentproto charter](https://raw.githubusercontent.com/ietf-artarea/charters/main/agentproto/charter.md) — the MCP/A2A deferral clause.
- [agentproto documents](https://datatracker.ietf.org/group/agentproto/documents/) — 13 related drafts.
- [bofreq-steele-agentproto-00](https://datatracker.ietf.org/doc/bofreq-steele-agentproto/) — second BoF, IETF 127.
- [webbotauth documents](https://datatracker.ietf.org/group/webbotauth/documents/) — WG document 2026-09-01.

**W3C**
- [w3.org/community/agentprotocol](https://www.w3.org/community/agentprotocol/) — AI Agent Protocol CG.
- [webmachinelearning.github.io/webmcp](https://webmachinelearning.github.io/webmcp/) — Draft CG Report 2026-09-29.

**Other foundations**
- [AGNTCY LF release](https://www.linuxfoundation.org/press/linux-foundation-welcomes-the-agntcy-project-to-standardize-open-multi-agent-system-infrastructure-and-break-down-ai-agent-silos) and [docs.agntcy.org](https://docs.agntcy.org/).
- [x402 Foundation launch](https://www.linuxfoundation.org/press/linux-foundation-announces-operational-launch-of-x402-foundation-to-standardize-internet-native-payments-for-ai-agents-and-applications) — 2026-07-14.
- [ANS intent](https://www.linuxfoundation.org/press/linux-foundation-announces-intent-to-launch-agent-name-service-to-establish-trusted-identity-infrastructure-for-ai-agents) — 2026-06-23.
- [AP2 to FIDO](https://blog.google/products-and-platforms/platforms/google-pay/agent-payments-protocol-fido-alliance/) and [ap2-protocol.org](https://ap2-protocol.org/).

**Ungoverned surfaces**
- [github.com/orgs/ag-ui-protocol](https://github.com/orgs/ag-ui-protocol/repositories) and [LFX Insights AG-UI](https://insights.linuxfoundation.org/project/ag-ui/).
- [a2ui.org](https://a2ui.org/), [ucp.dev](https://ucp.dev/).
- [alibaba.github.io/open-agent-auth](https://alibaba.github.io/open-agent-auth/).
