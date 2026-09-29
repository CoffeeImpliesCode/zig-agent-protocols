# Agent identity and discovery

This document records the state of agent identity and agent discovery as of the
research date. It covers the five live identity answers, the eight competing
discovery mechanisms, the IETF and W3C positions, and the individual draft
swarm. It does not define wire values. Those live in the contract. It does not
cover the identity layers inside MCP, A2A, or ACP beyond what the cross-protocol
comparison needs, and it does not cover payment authorization, which
[`commerce.md`](commerce.md) records.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

### No adopted agent-identity standard exists

No agent-identity standard has been adopted by any working group, any
foundation, or any W3C process. Five separate answers are live at once. They do
not share an identifier format, a key distribution method, a revocation model,
or a registry. The only layer of this slice with a real standards body behind it
is Web Bot Auth, and it is scoped to proving a caller is an automated agent
acting for an end user, not to giving that agent a durable identity of record.

Identity and discovery are the weakest and most fragmented layers in the set.
Discovery has eight competing mechanisms, and none of them carries identity.

### The five live uncoordinated identity answers

| # | Answer | Anchor date | Body | Identifier | Status on 2026-09-29 |
| --- | --- | --- | --- | --- | --- |
| 1 | **Web Bot Auth** | WG document `draft-ietf-webbotauth-httpsig-protocol-00`, 2026-09-01 | IETF `webbotauth` WG, state Active | HTTP key at a well-known key directory, proved by RFC 9421 signatures | The only chartered IETF agent working group. In production at Cloudflare, Google and Stytch |
| 2 | **ANS (Agent Name Service)** | Linux Foundation intent announcement, 2026-06-23 | LF intent stage. No foundation project chartered | DNS. QNAME `<agent_id>.<base_domain>`. DIDs and Legal Entity Identifiers supported | Intent stage. No specification published. Nothing chartered |
| 3 | **A2A signed Agent Cards** | A2A v1.0, 2026-03-12 | AAIF, A2A is a Growth Stage project | The Agent Card, when signed | The card is self-asserted unless signed. The signature format is NOT ESTABLISHED IN SOURCE |
| 4 | **IETF AED DNS record type** | `draft-ni-agent-entity-discovery-00`, 2026-07-06 | None. Individual submission, Informational | A new DNS resource record type, AED. QNAME `<agent_id>.<base_domain>` | Individual draft. No shepherd, no working group |
| 5 | **ANP `did:wba`** | ANP 1.2 document set, 2026-09 | None. Single organisation, no foundation | `did:wba`, a W3C-style DID method with `e1_` Ed25519 path binding | Reference implementation only. AAIF proposal #46 opened 2026-09-24, unreviewed |

The Linux Foundation [announced intent to launch ANS on 2026-06-23](https://www.linuxfoundation.org/press/linux-foundation-announces-intent-to-launch-agent-name-service-to-establish-trusted-identity-infrastructure-for-ai-agents),
naming Cloudflare, Salesforce, Cisco, Infoblox, GoDaddy, Hashgraph Online, and an
OWASP co-author. The release states DNS-based agent identity, verification and
discovery at internet scale. It is an intent statement. The release names
`github.com/agentnameservice` as the future home of the technical repos, and
links no specification.

ANS and the IETF AED draft arrived at the same idea from opposite directions.
ANS extends DNS with a naming convention. The AED draft
([`draft-ni-agent-entity-discovery-00`](https://datatracker.ietf.org/doc/draft-ni-agent-entity-discovery/),
Huawei, 2026-07-06, Informational) proposes a new record type. The AED draft
gives the reason: a client cannot tell multiple agents served from one domain
name apart, which creates impersonation and lateral-movement risk. Two
independent efforts, no coordination, the same QNAME shape.

### Discovery has eight mechanisms and none of them carries identity

| Mechanism | Where it lives | What it identifies | Governance | Verifies identity? | Scale reality |
| --- | --- | --- | --- | --- | --- |
| **MCP Registry** ([7.3k stars](https://github.com/modelcontextprotocol/registry)) | Hosted API at `registry.modelcontextprotocol.io` | MCP servers, that is tools. Not agents | AAIF, because MCP is an AAIF project | No. Metadata registry. Auth is separate, OAuth 2.1 plus RFC 9728 Protected Resource Metadata | Preview 2025-09-08. API freeze at v0.1 since 2025-10-24. Still pre-GA |
| **A2A Agent Card** | Fetched per agent over HTTP | Agents. Capabilities, skills, endpoints | AAIF | No. Self-asserted | Widely implemented. Fetched at `/.well-known/agent-card.json` |
| **UCP profile** | `/.well-known/ucp` plus a `UCP-Agent` header | Commerce capabilities of a merchant | Private group, Google and Shopify | Provenance only. Reverse-DNS authority binding, which the specification calls not-trust | Live on Google AI Mode and Gemini |
| **AGNTCY ADS** | Federated directory nodes at `ads.outshift.io`, DHT plus OCI | Agents, by skill taxonomy in OASF | Linux Foundation, directly | No built-in identity. Identity is a separate AGNTCY project | Cisco AI Catalog and ServiceNow. A federation testbed |
| **x402 Bazaar** | Facilitator `/discovery/resources` | Paid endpoints and MCP tools | x402 Foundation, Linux Foundation | No | The project describes its own maturity as a "Yahoo search" stage |
| **ANP-08** | The agent's own origin, plus search agents | Agents. Description documents | None. Single organisation | Yes, through `did:wba` and `did:web` in ANP-02 and ANP-03 | Reference implementation only |
| **IETF DAWN** | Not yet specified. Protocol due December 2027 | AI resources. Type, reachability, protocol | IETF, chartering | Explicitly out of scope | Nothing before 2027 |
| **W3C AI Agent Protocol CG "Search Agent"** | Conceptual | Agents | W3C Community Group, no formal review | Not applicable | A requirements document with visible TODOs |

Three separate efforts reached for the same authentication substrate
independently. MCP's OAuth profile, UCP's Web Bot Auth interop, and the AGNTCY
Identity project all chose OAuth 2.1 with an external authorization server. The
DID group chose `did:web`. MCP is the only one of these shipping today.

MCP is the most consequential of the eight. Remote MCP servers must be OAuth 2.1
resource servers implementing
[RFC 9728 Protected Resource Metadata](https://modelcontextprotocol.io/specification),
with PKCE and S256. A client refuses a server whose metadata does not show PKCE
support. The 2025-11-25 revision made
[OAuth Client ID Metadata Documents](https://modelcontextprotocol.io/specification)
the recommended client-registration mechanism, a static HTTPS-hosted document,
and kept Dynamic Client Registration only for backward compatibility. It demoted
`WWW-Authenticate` to an optional discovery path.

### The DID and HTTP-signature fault line

The fragmentation is not random. It follows one fault line.

| Side | Members | Requires |
| --- | --- | --- |
| **HTTP Message Signatures plus DNS** | Web Bot Auth, DNSid, ARIA's anchoring layer, and the AED draft's direction | An HTTP key, a key directory, and DNS |
| **DIDs and verifiable credentials** | ANP `did:wba` and `did:web`, ARIA's credential layer | A new identifier type, a verifiable credential stack, and a registry |

The HTTP-signature side requires no new identifier type, no credential stack and
no new registry. It uses DNS and
[RFC 9421 HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421). The
DID side is better specified on paper and needs more infrastructure.

Three independent projects have already layered the two sides. ANP Appendix B
supports native `did:web` alongside `did:wba`. The UCP profile carries a
`keys[]` JWK Set that the specification describes as reusable as a Web Bot Auth
key source, and UCP PR #483 added Web Bot Auth interop. ARIA anchors credentials
in DNS. `[INFERENCE]` The layering approach is the one already in use, because
each instance of it was a separate project's local decision rather than a
coordinated plan.

`did:web` itself is a W3C Community Group report
([`w3c-ccg.github.io/did-method-web`](https://w3c-ccg.github.io/did-method-web)),
not a W3C Recommendation. It is widely used and formally unratified. No
agent-specific DID method has been adopted anywhere.

Three IETF drafts pull the DID camp toward DNS.
[`draft-kavian-aep-did-web-identity-method-00`](https://www.ietf.org/archive/id/draft-kavian-aep-did-web-identity-method-00.html)
(2026-06-28, intended Standards Track) proposes `did:web` as the identity method
for an Agent Enrollment Protocol.
[`draft-ranjbar-dane-did-01`](https://datatracker.ietf.org/doc/html/draft-ranjbar-dane-did-01)
(2026-08-01, intended Standards Track, Whisper Security via viaGraph) proposes
DANE-style TLSA publication for DIDs. The source for the latter is its title and
abstract only `[UNVERIFIED]`.

## What it does

### Web Bot Auth, the only chartered agent working group

The [`webbotauth` working group](https://datatracker.ietf.org/wg/webbotauth/about/)
is in state Active. Its charter, `charter-ietf-webbotauth-01`, is approved. The
area is Web and Internet Transport. The chairs are David Schinazi and Rifaat
Shekh-Yusef. The responsible AD is Mike Bishop. The expected liaisons are
AIPREF, HTTPBIS, OAUTH, TLS, and WIMSE.

AI agents are explicitly in scope. The in-scope list includes AI agents
retrieving or interacting with content on behalf of end users. The out-of-scope
list is equally explicit. It excludes authenticating access to content not
intended for human consumption, including HTTP APIs and **agent-to-agent
interfaces**. It also excludes authenticating the end user of a participating
client or agent, defining a vocabulary for bot intents, and tracking or assigning
reputation.

That last exclusion is the load-bearing one for this document. The group that
looks like the agent-identity answer is scoped away from agent-to-agent identity
by its own charter.

Three milestones are met. The Standards Track authentication specification
reached the IESG on 2026-04-30. The Standards Track bot-info mechanism reached
the IESG on 2026-04-30. The BCP operational specification milestone was 2026-08-31.

The current working-group document is
[`draft-ietf-webbotauth-httpsig-protocol-00`](https://datatracker.ietf.org/doc/draft-ietf-webbotauth-httpsig-protocol),
dated 2026-09-01, titled "HTTP Message Signatures for automated traffic". Its
authors are Thibault Meunier of Cloudflare and Sandor Major of Google. It builds
on RFC 9421. A companion draft, `draft-meunier-webbotauth-registry`, defines a
registry and a Signature Agent card for Web Bot Auth, with Cloudflare, Amazon
and Google as authors.

The mechanism is small. The agent holds an HTTP key. It publishes a key
directory at a well-known URL, carrying a JWKS and a `Signature-Agent` header. It
signs requests with `Signature-Input` and `Signature` headers. The origin fetches
the key directory to verify. This is cryptographic agent identity on the
existing HTTP stack, with no DID, no verifiable credential, and no new registry.

### IETF agentproto, a proposed working group that defers to MCP and A2A

The second IETF agent group is
[`agentproto`](https://datatracker.ietf.org/group/agentproto/documents/), titled
"Agent Communication Protocols". It is in state Proposed, not Active.

Its history is short. The group was created 2026-06-11 in BOF state. Charles
Eckel is the responsible AD. Leslie Daigle and Orie Steele are the chairs. The
`agent2agent@ietf.org` mailing list was renamed to `agentproto@ietf.org` on
2026-07-24. The working-group-forming BoF was held at IETF 126 in Vienna on
2026-07-23. The state changed from BOF to Proposed on 2026-09-09. A second BoF
request, [`bofreq-steele-agentproto-00`](https://datatracker.ietf.org/doc/bofreq-steele-agentproto/),
was dated 2026-09-04 for IETF 127, with expected attendance of 100.

The nine named proponents are Leslie Daigle, Orie Steele, Cullen Jennings
(Cloudflare), Jonathan Rosenberg (Cisco), Suresh Krishnan (Cisco), Dapeng Liu
(Alibaba), Zaheduzzaman Sarker (Nokia), and Lionel Morand, Arashmid Akhavain and
Hesham Moussa (Huawei).

The
[charter](https://raw.githubusercontent.com/ietf-artarea/charters/main/agentproto/charter.md)
is deferential in writing. It states that the work neither replaces
application-layer agent communication protocols, and that it defines extension
points through which existing application-layer agent communication protocols,
MCP and A2A among them, can make use of it. It states that changes to those
protocols themselves are the responsibility of their respective maintainers and
are out of scope.

The deliverable is an "Agentic Dialog Management Protocol" on the Standards
Track, defining dialog identifiers, lifecycle semantics, and dialog-context
propagation across intermediaries and trust boundaries, plus bindings over HTTP,
QUIC, WebTransport, WebRTC and MOQ, plus a Reference Architecture and a Use Cases
and Requirements document. Agent behaviour, hallucination mitigation beyond user
confirmation, and UI design are out of scope.

Thirteen related drafts are attached to the group. Two of them concern identity:
`draft-bu-agentproto-security-principal-binding-07` and
`draft-okutomi-session-bound-agent-identity-06`, the latter a verifier-side
acceptance profile for channel-bound agent identity. One binds MCP to a
transport, `draft-jennings-agentproto-mcp-over-moqt-00`, titled "Model Context
Protocol and Agent Skills over Media over QUIC Transport". Both remain
individual drafts.

`[INFERENCE]` IETF is supplying transport and dialog substrate while AAIF keeps
protocol semantics. The charter's out-of-scope clause is explicit rather than
implied, so the two bodies are not competing at the layer they have claimed.

### IETF DAWN, the discovery group that chartered itself out of identity

[`charter-ietf-dawn-00-07`](https://datatracker.ietf.org/doc/charter-ietf-dawn/)
was last updated 2026-09-11. Its state is Start Chartering, under Internal
Steering Group and IAB review. The working group state is Proposed. The
responsible AD is Éric Vyncke of Cisco. There is no telechat date. It has two
BLOCK positions, and has enough positions to pass once they are resolved.

DAWN stands for Discovery of Agents With Names. The problem statement is
[`draft-akhavain-moussa-dawn-problem-statement-05`](https://datatracker.ietf.org/doc/draft-akhavain-moussa-dawn-problem-statement/).

The scope is how a client discovers public properties of AI resources: type,
reachability, communication protocol, and services. The diameters are immediate
proximity, such as discovering all agents in one shop, within an organisation,
and between cooperating parties over the public internet. The charter states that
the working group will consider DNS and mDNS as mechanisms on which to build a
discovery protocol.

Identity is excluded by name. Out of scope for the initial phase are capability
exchange beyond minimum public discovery information, all communication beyond
the initial discovery process, internet-wide AI resource indexing and search,
**identity management of AI agents, tools and skills**, and trust management and
trust evaluation methods beyond secure content exchange between DAWN parties.

Milestones: terminology, optional, June 2027. Protocol specification, December
2027. Architecture, January 2028.

The Cloud Security Alliance's
[landscape note of 2026-09-02](https://labs.cloudsecurityalliance.org/research/csa-research-note-ietf-agent-identity-standards-20260902-csa/)
assesses WIMSE, not DAWN, as the working group most likely to produce an adopted
agent-identity standard. WIMSE has adopted nothing.

### W3C Community Groups

W3C is present at Community Group level only. Community Group Reports carry no
W3C formal review and no patent commitment.

| Group | Started | Produced |
| --- | --- | --- |
| **AI Agent Protocol CG** | 2025-05-08, proposed by gaowei chang | "AI Agent Protocol Use Cases and Requirements", Draft Community Group Report, 2026-07-17 |
| **WebAgents CG** | "Autonomous Agents on the Web" | An Interoperability Report surveying the agent protocol landscape |
| **Agent Identity Registry Protocol CG** | Call for participation 2026-04-24. Inaugural meeting 2026-09-08 | Nothing. The inaugural agenda was a third-party protocol presentation |

The **AI Agent Protocol CG** meets bi-weekly. Its one deliverable,
[`Use Cases and Requirements`](https://w3c-cg.github.io/ai-agent-protocol/use_case.html),
dated 2026-07-17, defines three concepts, Personal Agent, Service Agent and
Search Agent, three worked scenarios (flight rebooking, hotel booking, and
agent-to-agent meeting scheduling), and eight requirement categories: identity
authentication, discovery, description, interaction, transactions, privacy, and
identity interoperability.

That document is visibly incomplete. It carries the text "Introduction — TODO:
This section needs further development and refinement", "Existing Work — TODO",
and "Features and Benefits — TODO". The "Agent Actions" and "Focal Use Cases"
sections are empty.

The group was proposed by the author of ANP, with supporters Ruoxi Ran, Song
XU, Gavin Sze and Jomy Wu. It is effectively an ANP venue.

The **WebAgents CG**
([`report-interoperability.html`](https://w3c-cg.github.io/webagents/TaskForces/Interoperability/Reports/report-interoperability.html))
published an Interoperability Report that surveys agent protocols and flags
unclear alignments and overlaps. The ANP team has presented to it. A survey is
not an identity mechanism.

The **Agent Identity Registry Protocol CG** holds its
[inaugural meeting on 2026-09-08](https://raw.githubusercontent.com/w3c-cg/agent-identity/main/meetings/2026/2026-09-08-minutes.md).
Seven people attended. Five were from a single organisation, TrustLayer
Foundation A.C. The others were MolTrust/CryptoKRI, one attendee from Keele
University, and Paola Di Maio of the AI KR CG. The inaugural agenda was a
presentation of the ARIA Protocol, which the chair framed as background rather
than as a proposal, and on the same terms as any other. The next meeting was set
for 2026-09-22.

The WebMCP Draft Community Group Report, dated 2026-09-29, is a fourth
Community Group output. It concerns browser tool registration, not agent
identity. See [`ui-protocols.md`](ui-protocols.md).

The W3C AI KR CG and the DIF Trusted AI Agents WG are named as further venues.
The source did not examine them `[UNVERIFIED]`.

### The individual draft swarm

The Cloud Security Alliance counted at least eight distinct agent-identity
architectures in IETF circulation as of September 2026, from at least six
organisations, none adopted by any working group. The source table enumerates
ten.

| Draft | Date | Intended status | Origin | Core idea |
| --- | --- | --- | --- | --- |
| [`draft-ihsanullah-dnsid-01`](https://datatracker.ietf.org/doc/draft-ihsanullah-dnsid/) | 2026-06-29 | Standards Track | Identity Digital | DNS TXT records as a durable ownership anchor |
| [`draft-ni-wimse-ai-agent-identity-02`](https://datatracker.ietf.org/doc/draft-ni-wimse-ai-agent-identity) | 2026-02-28 | Submitted to WIMSE, not adopted | WIMSE contributors | Dual-identity credentials binding an agent WIMSE ID to its owner's identity, with three issuance models |
| [`draft-kavian-aep-did-web-identity-method-00`](https://www.ietf.org/archive/id/draft-kavian-aep-did-web-identity-method-00.html) | 2026-06-28 | Standards Track | Individual | `did:web` as the identity method for an Agent Enrollment Protocol |
| [`draft-ranjbar-dane-did-01`](https://datatracker.ietf.org/doc/html/draft-ranjbar-dane-did-01) | 2026-08-01 | Standards Track | Whisper Security via viaGraph | DANE and TLSA publication for DIDs `[UNVERIFIED]` beyond title and abstract |
| [`draft-ni-agent-entity-discovery-00`](https://datatracker.ietf.org/doc/draft-ni-agent-entity-discovery/) | 2026-07-06 | Informational | Huawei | A new DNS record type, AED, re-anchoring trust at the agent rather than the domain |
| [`draft-aiendpoint-ai-discovery-01`](https://datatracker.ietf.org/doc/draft-aiendpoint-ai-discovery/) | 2026-07-28 | Standards Track intent | Individual, sole author Y. Choi | `/.well-known/ai` returning a token-efficient JSON capability document |
| [`draft-klrc-aiagent-auth-00`](https://www.ietf.org/archive/id/draft-klrc-aiagent-auth-00.html) | 2026 | Informational | Individual | WIMSE IDs with SPIFFE trust domains and OAuth 2.0 token exchange, separating the agent client-id from the delegated subject, with OpenID Shared Signals for revocation |
| `draft-sharif-agent-identity-framework-01` | 2026 | Not established in source | Individual | An agent identity framework for autonomous agents |

#### DNSid, the most technically serious of the swarm

[`draft-ihsanullah-dnsid-01`](https://datatracker.ietf.org/doc/draft-ihsanullah-dnsid/),
dated 2026-06-29, is titled "DNS-Anchored Durable Identity for AI Agents". Its
author is at Identity Digital, an ICANN domain registry, so the DNS expertise is
operator experience rather than crypto startup experience. Its intended status is
Standards Track.

The gap it names is durable ownership. OAuth 2.1, OIDC, SPIFFE/SPIRE, SCIM, NGAC
and MCP collectively address runtime authentication, authorization, lifecycle
management and tool interaction, and none of them by itself provides a durable,
governance-backed ownership anchor that persists across platforms, trust domains
and agent lifecycles. The draft also names the temporal problem directly: which
accountable entity owned this agent at a specific past time. That question is
unanswerable once a domain transfers or a credential expires.

The mechanism uses no new record types. The agent is assigned an FQDN, bound to
an accountable entity identified by a DNS domain under that entity's control.
Structured pointers go into ordinary DNS TXT records, pointing at the agent's
keys, lifecycle log and status. The draft states there are no new DNS record
types, opcodes or response codes, and no resolver, server or protocol changes.
HTTP service interfaces are defined: KU for the operational key, EK for the
entity key, SU for status. The tags include GI for a Governance Identifier, LR
for a Log Reference, FL for Policy Flags, and KA for a Key Age Maximum. Record
integrity is entity-signed, the log interface is an abstract append-only
interface, and keys rotate through a defined procedure with two-key separation.

The draft states that it sits beneath existing identity, authorization and
interaction standards without competing with them. Appendix A maps the
relationships to adjacent standards, and Appendix C sketches a migration path to
a dedicated record type.

Its sharp edges are structural. It is a single-author individual submission with
no responsible AD, no working group and no shepherd. It expires 2026-12-31. Its
own security section leaves post-quantum and log-durability concerns open, and
calls out TXT-string ambiguity and negative caching.

#### The five competing AIPs

The clearest evidence of non-convergence is a name. Five independent parties use
the acronym AIP, or the name Agent Identity Protocol, for unrelated designs.

| Draft | Date | Origin | Core idea |
| --- | --- | --- | --- |
| `draft-aip-agent-identity-protocol-00` | 2026-03-16 | Cao and Arango Gutierrez, individuals | A two-layer AIP. A registry-issued identifier plus a keypair. The agent signs every message |
| [`draft-singla-agent-identity-protocol-03`](https://datatracker.ietf.org/doc/draft-singla-agent-identity-protocol) | 2026-06-09 | Individual | An `aip_scope` value, with per-issuer uniqueness of the JWT ID across delegation chains |
| [`draft-fane-opena2a-aip-00`](https://www.ietf.org/archive/id/draft-fane-opena2a-aip-00.html) | 2026-07-06 | Individual | The OpenA2A Agent Identity Protocol |
| [`draft-prakash-aip-01` | 2026-08-19 | Individual | Verifiable delegation across MCP and A2A |
| ARIA Protocol | Presented 2026-09-08 | TrustLayer Foundation A.C. | Four trust levels over W3C VC 2.0, a Bitstring Status List, a post-quantum composite signature and DNS anchoring |

The source states the count two ways. The draft-swarm section says five drafts
from five individuals use the name AIP, and the table it accompanies enumerates
four AIP-named drafts. The synthesis section names those same four drafts plus
ARIA as five independent parties. The five-party reading is the one the
enumeration supports. The five-drafts reading is not reconciled in the source.

`[INFERENCE]` Five parties, one acronym, no shared wire format, is a naming
collision rather than a standards effort. The collision is a live hazard for
anyone searching the datatracker for "agent identity protocol".

## What changed recently

| Date | Event |
| --- | --- |
| 2025-05-08 | W3C AI Agent Protocol Community Group launched |
| 2025-10-24 | MCP Registry API frozen at v0.1. Still pre-GA on the research date |
| 2025-11-25 | MCP revision made OAuth Client ID Metadata Documents the recommended client-registration mechanism |
| 2026-03-12 | A2A v1.0 shipped, listing signed agent cards among its features |
| 2026-04-30 | Web Bot Auth Standards Track authentication specification and bot-info mechanism both reached the IESG |
| 2026-05-15 | AAIF proposal #14, the Agent Passport System, a cryptographic identity and delegation proposal, was declined |
| 2026-06-23 | Linux Foundation announced intent to launch ANS |
| 2026-06-29 | DNSid draft, Identity Digital, Standards Track intent |
| 2026-07-23 | The `agentproto` working-group-forming BoF, at IETF 126 in Vienna |
| 2026-07-24 | The `agent2agent@ietf.org` list renamed to `agentproto@ietf.org` |
| 2026-08-31 | Web Bot Auth BCP operational specification milestone |
| 2026-09-01 | `draft-ietf-webbotauth-httpsig-protocol-00`, the working group's current document |
| 2026-09-08 | W3C Agent Identity Registry Protocol CG inaugural meeting. Seven attendees |
| 2026-09-09 | `agentproto` state changed from BOF to Proposed |
| 2026-09-11 | DAWN charter updated to 00-07. Two BLOCK positions. No telechat date |
| 2026-09-24 | AAIF proposal #46, ANP, opened. Label `New`, unreviewed by staff or the TC |
| 2026-09-28 | AAIF proposal #40, `regent-httpsig`, a signature scheme for agents, was declined and closed |

The two AAIF declines are the same kind of event one month apart. The Agent
Passport System, a cryptographic identity and delegation proposal, was declined
on 2026-05-15. `regent-httpsig`, an HTTPSig-for-agents candidate, was declined
and closed on 2026-09-28, one day before this research date. AAIF intake is a
real filter rather than a rubber stamp. 13 of 23 closed proposals are declined.

The full proposal census is in [`governance.md`](governance.md).

## Evidence of adoption

| Answer | Adoption evidence | Date |
| --- | --- | --- |
| Web Bot Auth | Cloudflare ships a production Web Bot Auth flow with bot registration and a verified-bot list. The CSA landscape note records production deployments at Cloudflare, Google and Stytch | 2026-09-02 |
| Web Bot Auth | UCP PR #483 added Web Bot Auth interop for automated agentic auth negotiation. The UCP profile carries a `keys[]` JWK Set usable as a Web Bot Auth key source | 2026-08-25 UCP release |
| A2A Agent Card | 150 or more supporting organisations and 22,000 or more GitHub stars. Fetched at `/.well-known/agent-card.json` as part of the AAIF-hosted A2A specification | 2026-04-09 |
| MCP Registry | 7.3k GitHub stars. A live hosted API. A Registry working group with named leads | 2025-10-24 API freeze |
| ANS | No specification and no implementation. Intent stage only | 2026-06-23 |
| IETF AED | No working group, no shepherd, no implementation | 2026-07-06 |
| ANP `did:wba` | 1,437 GitHub stars and 104 forks. Two commercial deployments named in the AAIF proposal, one of them internal use. The proposal itself states its five third-party integrations should not be read as evidence of conformance or production deployment | 2026-09-24 |

Two gaps in the adoption evidence are worth recording as gaps.

Microsoft and Okta general-availability dates for agent identity are cited by
the CSA landscape note. The dates themselves are
NOT ESTABLISHED IN SOURCE for this document.

A `sigstore-a2a`-style project exists for keyless signing of A2A agent identity
and Agent Cards through Fulcio and Rekor. It has no standards body, no adoption
numbers, and community-grade governance. It is not evidence of adoption, only
evidence of interest. The source tags the adjacent MCP Registry authentication
mechanics it describes as coming from a secondary security analysis
`[UNVERIFIED]`.

## Sharp edges

### The one chartered group is scoped away from agent-to-agent identity

The `webbotauth` charter excludes authenticating agent-to-agent interfaces. It
excludes authenticating the end user of a participating client or agent. What it
standardizes is that a caller is an automated agent acting for a user it can
name. A2A agent-to-agent traffic and any A2A-to-A2A call fall outside it.

So the strongest identity mechanism in the ecosystem does not cover the traffic
that MCP and A2A actually generate. `[INFERENCE]` This is the single largest gap
between what is standardized and what is shipped.

### Discovery is over-supplied and under-specified at the same time

Eight mechanisms compete. None carries identity. Three of them, MCP Registry,
x402 Bazaar and the third-party A2A registry cluster, index tools rather than
agents. One of them, x402 Bazaar, describes its own maturity as a "Yahoo search"
stage. The IETF's own answer, DAWN, has a protocol milestone of December 2027 and
excludes identity by name.

The third-party registry cluster is largely not a standards effort.
`agent-dns.dev`, `agent-json.org`, `a2a-registry.org` and the `agents.json`
aggregation format carry no governance. A2A's own `/.well-known/agent-card.json`
is real and is part of the AAIF-hosted A2A specification. The separate registries
are not.

### The MCP Registry does not sign its own metadata

The MCP Registry standardises discoverability. The `server.json` metadata a
registry serves can change without any signature. Tool poisoning and the "rug
pull" attack are therefore unresolved at the metadata layer `[UNVERIFIED]`. The
source cites a secondary security analysis for this, and flags that the
`io.github.username/*` and `com.example.*/*` namespace forms need confirmation
against the registry's own authentication documentation.

### The individual drafts have no path to adoption

Every draft in the swarm is an individual submission. DNSid, the most
technically serious, expires 2026-12-31 with no AD and no shepherd. The WIMSE
agent-identity draft was not adopted. WIMSE, cited as the likeliest source of an
adopted agent-identity standard, has adopted nothing.

A fifth answer would be a working group. A sixth would be a
[Foundation-chartered project](https://github.com/aaif/project-proposals/issues).
The two most recent attempts at the latter, in May and September 2026, were both
declined.

### The acronym collision is a live supply-chain hazard

Five parties use AIP. Four unrelated protocols use ACP, which
[`acp-others.md`](acp-others.md) records. `[INFERENCE]` A package or draft
selected by name alone can land on a dead project, which is the same hazard the
ACP collision already produces.

### Open questions

- Whether A2A's signed Agent Card shares a wire format with Web Bot Auth, or is
  independent of it. NOT ESTABLISHED IN SOURCE.
- The signature format, algorithm, and key distribution method for A2A signed
  Agent Cards. The source names the feature but not the mechanism.
  NOT ESTABLISHED IN SOURCE.
- The intended status of `draft-sharif-agent-identity-framework-01`.
  NOT ESTABLISHED IN SOURCE.
- Whether the `webbotauth` BCP operational specification milestone of 2026-08-31
  was met on time. The charter lists the date as a milestone. The source does not
  record the outcome.
- Microsoft and Okta general-availability dates for agent identity.
  NOT ESTABLISHED IN SOURCE.
- Whether the 3GPP SA1 study TR 22.870 and the CT3 study item FS_6G_AIP_CT will
  adopt a web-native agent protocol or write a separate one. The source marks
  this `[UNVERIFIED]`, drawn from a secondary technical blog and an ETSI
  workshop deck rather than from 3GPP's portal.
- Whether the ITU-T SG13 work-programme item on networking for AI-agent
  collaboration is real. The source could not load the primary page and marks it
  `[UNVERIFIED]`.

## Sources

- <https://datatracker.ietf.org/wg/webbotauth/about/> — group state, charter, agents in scope, milestones
- <https://datatracker.ietf.org/doc/draft-ietf-webbotauth-httpsig-protocol> — working-group document 00, 2026-09-01
- <https://datatracker.ietf.org/group/webbotauth/documents/> — document list
- <https://developers.cloudflare.com/bots/reference/bot-verification/web-bot-auth> — production Web Bot Auth
- <https://datatracker.ietf.org/doc/charter-ietf-dawn/> — DAWN charter 00-07, out-of-scope list, two BLOCK positions
- <https://datatracker.ietf.org/doc/draft-akhavain-moussa-dawn-problem-statement/> — DAWN problem statement 05
- <https://datatracker.ietf.org/group/agentproto/documents/> — 13 related drafts
- <https://datatracker.ietf.org/group/agentproto/history/> — group state history
- <https://raw.githubusercontent.com/ietf-artarea/charters/main/agentproto/charter.md> — the MCP and A2A out-of-scope clause
- <https://datatracker.ietf.org/doc/bofreq-steele-agentproto/> — second BoF request, nine proponents
- <https://datatracker.ietf.org/doc/draft-ihsanullah-dnsid/> — DNSid full text, tags, security sections
- <https://datatracker.ietf.org/doc/draft-ni-wimse-ai-agent-identity> — WIMSE applicability, not adopted
- <https://www.ietf.org/archive/id/draft-klrc-aiagent-auth-00.html> — token-exchange agent authorization
- <https://www.ietf.org/archive/id/draft-kavian-aep-did-web-identity-method-00.html> — `did:web` for an Agent Enrollment Protocol
- <https://datatracker.ietf.org/doc/html/draft-ranjbar-dane-did-01> — DANE for DIDs
- <https://datatracker.ietf.org/doc/draft-ni-agent-entity-discovery/> — the AED record type
- <https://datatracker.ietf.org/doc/draft-aiendpoint-ai-discovery/> — `/.well-known/ai`
- <https://datatracker.ietf.org/doc/draft-singla-agent-identity-protocol> — one of the AIP drafts
- <https://www.ietf.org/archive/id/draft-fane-opena2a-aip-00.html> — another AIP draft
- <https://labs.cloudsecurityalliance.org/research/csa-research-note-ietf-agent-identity-standards-20260902-csa/> — landscape note, 2026-09-02
- <https://w3c-cg.github.io/ai-agent-protocol/use_case.html> — Community Group Report, 2026-07-17, with TODO markers
- <https://w3c-cg.github.io/webagents/TaskForces/Interoperability/Reports/report-interoperability.html> — WebAgents interoperability survey
- <https://raw.githubusercontent.com/w3c-cg/agent-identity/main/meetings/2026/2026-09-08-minutes.md> — inaugural meeting minutes
- <https://www.w3.org/community/agent-identity> — Community Group page
- <https://w3c-ccg.github.io/did-method-web> — `did:web`, a Community Group report
- <https://www.linuxfoundation.org/press/linux-foundation-announces-intent-to-launch-agent-name-service-to-establish-trusted-identity-infrastructure-for-ai-agents> — ANS intent, 2026-06-23
- <https://github.com/agent-network-protocol/AgentNetworkProtocol> — ANP spec index, profiles, `did:wba`
- <https://github.com/modelcontextprotocol/registry> — MCP Registry preview and API freeze
- <https://github.com/aaif/project-proposals/issues> — the two declined identity proposals
- <https://aaif.io/projects> — AAIF project list
- <https://dir.agntcy.org/latest/dir/dir-overview> — AGNTCY Agent Directory Service
- <https://docs.x402.org/extensions/bazaar> — x402 Bazaar discovery
