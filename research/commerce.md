# Commerce and agent payment protocols

This document records dated evidence about the five protocols that carry an agent
into a transaction — UCP, AP2, x402, AGNTCY and ANP — plus a summary of the
Agentic Commerce Protocol, which is covered in full in
[`acp-others.md`](acp-others.md). It covers state, governance, wire mechanism,
dated change history, adoption and sharp edges for each. It does not cover card
network agentic rails (Visa Intelligent Commerce, Mastercard Agent Pay, PayPal
Agent Ready) except where they decide governance or appear in an adoption roster,
and it does not cover agent identity or discovery standards, which are recorded in
[`identity-and-discovery.md`](identity-and-discovery.md). It is evidence, not
contract: no byte layout is normative here.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

**Premise correction, stated once and load-bearing.** UCP is **not** a Google +
OpenAI initiative. It is Google plus **Shopify**, with a council that also seats
Amazon, Meta, Stripe, Microsoft, Salesforce, Wayfair, Target, Etsy, Expedia,
Booking, Hilton, Adyen, PayPal, Coinbase and Ant International. OpenAI is not a
UCP maintainer; the maintainer roster does not list it. The Google-versus-OpenAI
confusion comes from the Agentic Commerce Protocol, which is OpenAI plus Stripe
plus Meta, documented in the ACP subsection below. OpenAI does co-chair FIDO's
Agentic Authentication Technical Working Group alongside CVS Health and Google,
which is a different body from the one that took AP2.

## State

### UCP — Universal Commerce Protocol

| Property | Value |
| --- | --- |
| Latest release | `2026-08-25`, 25 Aug 2026 ([release notes](https://github.com/Universal-Commerce-Protocol/ucp/releases/tag/v2026-08-25)) |
| Earlier dated releases | `2026-01-11`, `2026-01-23`, `2026-04-08` |
| Unreleased | `ucp.dev/draft/` tracks a draft; `latest/` tracks the released spec |
| Spec site | [ucp.dev](https://ucp.dev/) |
| Repo | [Universal-Commerce-Protocol/ucp](https://github.com/Universal-Commerce-Protocol/ucp) — 3.4k stars, 471 forks, 218 open issues, Apache-2.0, as of 2026-09-29 |
| Sibling repos | `ucp/samples`, `ucp/conformance`, the `ucp-schema` Rust crate, an org with native SDKs |
| Partner portal | Google merchant documentation at `developers.google.com/merchant/ucp`; the Google partner portal is recorded as `ucp.goog` |
| Governance | **No foundation.** A Governance Council — Amit Handa (Google), Ilya Grigorik (Shopify), Twum Djin (Stripe), 2 seats open — over four domain Tech Councils: Shopping, Food, Lodging, Payments ([MAINTAINERS.md](https://raw.githubusercontent.com/Universal-Commerce-Protocol/.github/main/MAINTAINERS.md)) |
| Maturity | Real spec, four dated releases in nine months, breaking-change cadence, published conformance suite |

UCP was not donated to the Linux Foundation, FIDO or AAIF. Continuity risk is
concentrated in Google plus Shopify.

### AP2 — Agent Payments Protocol

| Property | Value |
| --- | --- |
| Version | `v0.2`, spec title "Agentic Payment Protocol (v0.2)" — still pre-1.0 |
| Changelog | `0.1.0` = 2025-09-16, `0.2.0` = 2026-04-28 ("Release of V2") ([CHANGELOG.md](https://raw.githubusercontent.com/google-agentic-commerce/AP2/main/CHANGELOG.md)) |
| Spec site | [ap2-protocol.org](https://ap2-protocol.org/) |
| Repo | [google-agentic-commerce/AP2](https://github.com/google-agentic-commerce/AP2) — 3.2k stars, 504 forks, 166 issues, Apache-2.0, as of 2026-09-29 |
| Governance | **Donated to the FIDO Alliance, 2026-04-28.** Proceeds inside FIDO's Payments Technical Working Group, chaired by members from Mastercard and Visa |
| Code | Python SDK at `code/sdk/python/ap2/` (Pydantic models plus canonical JSON schemas), Go and Android samples, a Vite/React demo web client |
| Maturity | Real spec, real SDK, samples. **No PyPI package is published.** |

Google's stated reason for the donation was to keep the protocol "platform-agnostic
and community-led" ([Google blog, 2026-04-28](https://blog.google/products-and-platforms/platforms/google-pay/agent-payments-protocol-fido-alliance/)). The long-term home is therefore an industry association that also
certifies and runs conformance programs, which is materially different from a
GitHub-governed spec. The date the FIDO Payments TWG itself was chartered is
NOT ESTABLISHED IN SOURCE.

### x402

| Property | Value |
| --- | --- |
| Core spec version | `x402Version: 1` in the [core specification](https://raw.githubusercontent.com/coinbase/x402/main/specs/x402-specification-v1.md) |
| SDK/package line | `v2` — a "Migration Guide: V1 to V2" exists; the Go module is `github.com/x402-foundation/x402/go/v2`; Bazaar resource entries carry `x402Version: 2` |
| Repo | Moved from `github.com/coinbase/x402` to [x402-foundation/x402](https://github.com/x402-foundation/x402) — 6.7k stars, 2.1k forks, 591 issues, Apache-2.0, as of 2026-09-29 |
| Governance | **x402 Foundation, under the Linux Foundation** |
| Foundation timeline | Intent announced 2025-09-23; LF intent to launch April 2026; **operational launch 2026-07-14** with Coinbase's contribution complete, 40 organisations joined |
| Maturity | The only protocol in this set with a measured production signal |

The version split is itself a finding: [INFERENCE] the wire version and the SDK
major have diverged, and the documentation still treats the v1 core types as
current.

### AGNTCY — "Internet of Agents"

| Property | Value |
| --- | --- |
| Governance | **Linux Foundation**, donation announced 2025-07-29. Formative members Cisco, Dell Technologies, Google Cloud, Oracle, Red Hat, plus 75+ companies |
| Org | [github.com/agntcy](https://github.com/agntcy) — 50 repos, 1.1k followers |
| Legal | "AGNTCY is proudly part of the Linux Foundation"; footer on dir.agntcy.org: "(c) 2026, Agntcy, a Series of LF Projects, LLC" |
| TSC | John Cardente (Dell), Kevin Cogan (Red Hat), Luca Muscariello (Cisco), John Parello (Cisco), Anant Patel (Oracle), Todd Segal (Google Cloud), Hema Seshadri (Akamai), Marcelo Yannuzi (Cisco) |
| Health | LFX Insights 83/100, lifecycle "Active", 23 maintainers with merge rights, contributors from 42 organisations, last release 0 days ago, Security & Supply Chain 28/35 ("no open CVEs and full security practices") |
| Standards status | Two IETF drafts, both individual submissions, both Informational, neither adopted |

**AGNTCY is not part of AAIF.** Verified against [aaif.io/projects](https://aaif.io/projects):
AAIF hosts exactly six projects — Model Context Protocol, goose, AGENTS.md,
agentgateway, Agent2Agent (A2A), Agent Router. AGNTCY is absent. AAIF itself was
formed 2025-12-09 and later added A2A, agentgateway and Agent Router. The two
Linux Foundation agent umbrellas are complementary and non-overlapping: AAIF holds
the tool and call protocols, AGNTCY holds the directory, identity and messaging
substrate.

**On the recurring question of whether Cisco wound AGNTCY down: the answer is no.**
Activity is current, not vestigial — `slim`, `dir`, `identity`, `identity-service`,
`oasf` and `coffeeAgntcy` all show a 2026-09-29 update, and the engineering blog
has posts through 2026-08-25. Cisco's Outshift blog was still publishing AGNTCY
architecture content on 2026-06-09. The project is also pruning rather than
abandoning: `acp-sdk`, `workflow-srv`, `workflow-srv-mgr` and `iomapper-agnt` are
all marked **Deprecated** in the Core working-group repository list
([WORKING-GROUPS.md](https://raw.githubusercontent.com/agntcy/governance/main/working-groups/WORKING-GROUPS.md)).
The context that does belong in the record: Cisco announced roughly 4,000 job cuts
in an AI and security restructuring on 2026-05-13, on top of an earlier 7%
workforce cut ([memo](https://blogs.cisco.com/news/our-path-forward); the ~4,000
figure is from contemporaneous trade press `[UNVERIFIED]` against the memo text),
and 13 of 15 working-group leads are Cisco employees. The honest reading is a live
project with a sponsor under cost pressure and an execution structure concentrated
in that sponsor.

### ANP — Agent Network Protocol

| Property | Value |
| --- | --- |
| Version | `1.2` document set: ANP-01 white paper, ANP-02 DID authentication, ANP-03 did:wba, ANP-04 WNS naming, ANP-07 Agent Description, ANP-08 Agent Discovery, ANP-09 messaging overview plus 9 profiles |
| Not released | ANP-06 meta-protocol remains Draft and is "not part of the currently released architecture"; ANP-10 (AP2 adaptation) is Draft / not released, self-described as "not a stable payment interoperability standard" |
| Repo | [agent-network-protocol/AgentNetworkProtocol](https://github.com/agent-network-protocol/AgentNetworkProtocol) — 1,437 stars, 104 forks, 23 open issues, Apache-2.0, primary language HTML |
| Sites | [agent-network-protocol.com](https://www.agent-network-protocol.com/) and a second domain in circulation |
| Governance | **None.** No foundation, no working group, no standards body. Contact is a personal Gmail address plus an aliyun.com address and a QQ number; Discord and WeChat |
| Maturity | Announced and specified, essentially not deployed |

Per-document release dates for the 1.2 set are NOT ESTABLISHED IN SOURCE. The
project's own site still carries 1.1 paths in at least one place
([ANP-05 profile page](https://www.agent-network-protocol.com/specs/1.1/message/direct-e2ee)),
which is version drift across sites.

### Agentic Commerce Protocol (ACP) — summary

Full treatment in [`acp-others.md`](acp-others.md). The facts that bear on the
commerce comparison:

| Property | Value |
| --- | --- |
| Name | `Agentic Commerce Protocol` — the project's own name, used in the GitHub org, the spec title, Stripe's docs and the discovery document's `protocol.name: "acp"` |
| Maintainers | **OpenAI, Stripe, Meta.** Founding Maintainers are OpenAI and Stripe with a 7-seat TSC; three seats filled — OpenAI, Stripe, Meta. Meta signed the corporate CLA 2026-03-19 |
| Governance | [docs/governance.md](https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/docs/governance.md) — **not donated to any foundation**; Linux Foundation and OpenJS are named only as a gated long-term goal |
| Versioning | Date-based, no semver, no 1.0. Latest stable spec `2026-04-17`, README badge **Beta** |
| License | Apache-2.0 **plus a CLA** under a Collaboration and Governance Agreement dated 2025-11-21 — not frictionless Apache-in/Apache-out |
| Repo | 102 commits, ~1.6k stars, 251 forks; last commit 2026-07-18, roughly 10 weeks stale on the research date `[INFERENCE from the commit list]` |
| Implementers | OpenAI (ChatGPT) and Stripe (Agentic Commerce Suite), per the README |

## What it does

### UCP

Capability negotiation, not a fixed API. A **Business** publishes a profile at
`/.well-known/ucp`. A **Platform** advertises its profile per request through the
`UCP-Agent` header: `POST /checkout-sessions` with
`UCP-Agent: profile="https://agent.example/profiles/shopping-agent.json"`.

Negotiation is **server-selects**: intersect by capability name, pick the highest
common date-version, iteratively prune extensions whose parents are absent, and
echo the result in every response ([core concepts](https://raw.githubusercontent.com/Universal-Commerce-Protocol/ucp/main/docs/documentation/core-concepts.md)).

Namespaces are reverse-domain, `[reverse-domain].{service}.{capability}`, for
example `dev.ucp.shopping.checkout`. There is no central registry. A declared
schema URL's host must reverse-match the namespace authority, either
label-aligned prefix or exact; the spec URL itself is documentation and is not
authority-bound. Transports per service are `rest` (OpenAPI 3.1), `mcp`
(OpenRPC), `a2a` (Agent Card) and `embedded` (OpenRPC). The bindings are thin —
method names plus base-schema references only.

Roles are Platform (consumer), Business (capability provider, typically Merchant of
Record), **Credential Provider** (tokenises, keeps the raw PAN off the platform)
and PSP (Stripe, Adyen, PayPal, Braintree, Chase).

| Capability group | Members |
| --- | --- |
| Shipped capabilities | `shopping.checkout`, `shopping.cart`, `shopping.catalog.search`, `shopping.catalog.lookup`, `shopping.order`, `shopping.permalink`, `common.identity_linking` (OAuth 2.0), `common.location.search`, `common.location.lookup`, `lodging.booking` |
| Extensions | `shopping.discount`, `shopping.fulfillment`, `shopping.buyer_consent`, `common.loyalty`, `common.payment.authentication` (3DS2), `common.payment.ap2_mandate`, `common.payment.split_payments`, `common.payment.terms` |

`dev.ucp.common.payment.*` is the payment-handler slot. AP2 is one handler among
others. UCP is therefore not payment-agnostic by itself: it depends on a
credential provider plus a PSP.

### AP2

Five roles: Shopping Agent (SA), Credential Provider (CP), Merchant (M), Merchant
Payment Processor (MPP) and **Trusted Surface** (TS). One entity may hold several.
Trusted Surface MUST be non-agentic; SA is expected to be agentic; M, MPP and CP
may be either. All validation MUST happen in deterministic code
([specification](https://ap2-protocol.org/ap2/specification/)).

The design premise is that an agentic role is a potential attacker, so the
protocol treats the model's output as untrusted input and requires tamper-evident
evidence for it.

Authorization is two-step. *Mandate Delegation*: the user approves Mandate Content
on a Trusted Surface and the signed Mandate is handed to the Agent. *Action
Authorization*: the Verifier challenges, the Agent presents the Mandate, the
Verifier returns a Receipt ([agent authorization](https://ap2-protocol.org/ap2/agent_authorization/)).

Mandates are **SD-JWT verifiable credentials** with a `vct` claim carrying a
numeric schema-version suffix — `mandate.checkout.1`, `mandate.payment.1`,
`mandate.checkout.open.1`. Implementations MUST match the exact `vct` string.

v0.2 renamed the objects from v0.1: **Checkout Mandate**, which proves the Agent
may buy this cart, plus Checkout Receipt; and **Payment Mandate**, which proves the
Agent may pay for this cart, plus Payment Receipt. The Payment Mandate binds to
the Checkout by cryptographic hash of the merchant-signed Checkout JWT. To defeat
rainbow-table attacks the Checkout JWT **MUST use a non-deterministic signature
scheme such as ECDSA, not Ed25519** — an unusual and specific normative
requirement.

There are two modes. *Human Present (Direct)*: the user signs closed mandates on
the Trusted Surface. *Human Not Present (Autonomous)*: the user signs **open**
mandates carrying constraints, the Agent then signs **closed** mandates with its
own Agent key, includes that key as a `cnf` claim, and sets the smallest workable
`exp`. Verifiers always receive closed mandates; the difference is how trust is
established. In Autonomous mode the Agent must present only the disclosures needed
for evaluation and **MUST NOT** present a new open mandate without a prior
rejection receipt, which is the anti-multiple-approval rule.

Delegation uses **OpenID4VP** with `transaction_data` carrying two objects: type
`payment_card` for UI rendering, and type `delegate`, whose `delegate_payload`
array carries `mandate.checkout.1` plus `mandate.payment.1` and which **MUST be
covered by the SD-JWT Key Binding JWT**. `response_mode` is `dc_api` and the
Digital Credentials API is recommended; ISO mDocs (ISO 18013-5) are named as an
alternative and OpenID4VCI for issuance.

Trusted Surface trust has two models. *User Credential*: an external Issuer the
Verifier trusts, where one credential can delegate to many Agents. *Trusted Agent
Provider*: the Agent's provider is trusted, which is simpler but requires the
Verifier to trust every Agent Provider. Blending is allowed.

AP2 is payment-agnostic by design. Google shipped a bridge, **a2a-x402**, with
Coinbase, the Ethereum Foundation and MetaMask, described as "a production-ready
solution for agent-based crypto payments". The AP2 FAQ points at
`google-agentic-commerce/a2a-x402` while the launch blog links `google-a2a/a2a-x402`;
the org has evidently moved and the two documents are inconsistent
`[UNVERIFIED which is current]`.

### x402

x402 revives HTTP **402 Payment Required**. There is no new transport and no new
protocol negotiation. The wire flow is: request; the server returns **402** with
base64 JSON in the `PAYMENT-REQUIRED` header; the client signs and retries with
`PAYMENT-SIGNATURE`; the server verifies locally or POSTs to a facilitator
`/verify`; the work is fulfilled; settlement happens locally or via `/settle`; the
response is **200** with base64 settlement JSON in `PAYMENT-RESPONSE`
([facilitator concepts](https://docs.x402.org/core-concepts/facilitator)).

The spec makes a three-layer split explicit. *Types* are transport- and
scheme-independent: PaymentRequirements, PaymentPayload, SettlementResponse.
*Logic* is scheme plus network: how a payload is formed, verified and settled.
*Representation* is transport: HTTP, MCP, A2A.

The **facilitator** is an optional but recommended third party that verifies and
settles on chain so a resource server needs no chain connectivity. It is
explicitly non-custodial — "does not hold funds or act as a custodian". Three
deployment paths exist: the public x402.org facilitator (dev/testnet only), a
production provider, or self-facilitation inside the resource server. The README
warns: "Do not assume the public x402.org facilitator is the default production
path for mainnet EVM routes."

Schemes are `exact` (fixed price), `upto` (the buyer authorises a cap, the seller
settles actual usage) and batch settlement (on EVM and SVM, escrow plus
off-chain vouchers with batched on-chain redemption for high-volume micropayments).

The EVM `exact` scheme is **EIP-3009** `transferWithAuthorization` — EIP-712 typed
data with `from`, `to`, `value`, `validAfter`, `validBefore`, `nonce` — which
gives gasless payment with no prior approval. Facilitator verification checks
signature validity, balance, amount greater than or equal to required, time
window, parameter match and transaction simulation. The SVM `exact` scheme is SPL
`TransferChecked` with a strict instruction layout: the facilitator fee payer must
not appear in any account list nor be the transfer authority or source, the
compute-unit price is bounded, the destination ATA must match the
`payTo`/asset PDA, and the amount must exactly equal `maxAmountRequired`.

Networks covered are EVM, SVM (Solana), AVM (Aptos), Casper, Stellar, TVM, Hedera,
Keeta, XRPL, NEAR, Concordium and Cardano. Client and server packages exist for
fetch, axios, express, fastify, hono, next, paywall, extensions and mcp.

Extensions are composable and do not change business logic:

| Extension | Function |
| --- | --- |
| Bazaar | Discovery |
| builder-code | ERC-8021 Schema 2 on-chain attribution |
| payment-identifier | Idempotency |
| SIWX | CAIP-122 sign-in to re-access without repaying |
| Signed offers and receipts | Crypto proof of interaction on the 402 and the 200 |
| EIP-2612 gas sponsoring | Pays gas for approval |
| ERC-20 approval gas sponsoring | Pays gas for approval |
| lifecycle hooks | — |

Bazaar discovery is `GET {facilitator}/discovery/resources`, returning
x402-compatible services with type `http` or type `mcp`; MCP tools carry
`toolName`, `inputSchema` and transport `streamable-http` or `sse`. The
facilitator signals cataloguing results through a base64 `EXTENSION-RESPONSES`
header carrying `bazaar.status` of `success`, `processing` or `rejected`. Because
the marketplace-item spec is part of the x402 scheme, any facilitator can
implement its own discovery layer ([Bazaar docs](https://docs.x402.org/extensions/bazaar)).

### AGNTCY

Four components ship as working code with public services and IETF drafts; two
further items are announced rather than standardised.

| Component | Language, stars | Function |
| --- | --- | --- |
| OASF, Open Agentic Schema Framework | Elixir, 334 | The record data model. Skill taxonomy at `schema.oasf.outshift.com/skill_categories`. Records model MCP server definitions, prompt-based agents and evaluation metrics as modular extensions. Repos `agntcy/oasf`, `agntcy/oasf-sdk` |
| ADS, Agent Directory Service | Go, 190 (`agntcy/dir`); spec 59 (`agntcy/dir-spec`) | Distributed directory. Records stored **as OCI artifacts in container registries**, content-addressed by CID, located via a **DHT** mapping skill taxonomy to CID to peer directory servers. gRPC and protobuf at `buf.build/agntcy/dir` |
| SLIM, Secure Low-Latency Interactive Messaging | Rust, 220; spec 52 | gRPC over HTTP/2 and HTTP/3, publish-subscribe, secure messaging, group communication. Positioned as the transport layer for A2A and MCP |
| Identity | Go, 103 (`agntcy/identity`); TypeScript, 67 (`agntcy/identity-service`); `agntcy/identity-spec` | Onboard, create and verify identities for agents, MCP servers and multi-agent systems. TSV-driven authorisation model (2026-08-25); OIDC gateway in `dirctl` (2026-08-10) |
| CoffeeAgntcy | Python, 112 | End-to-end reference multi-agent application |

ADS has a **public production network at `ads.outshift.io`** and a running
federation testbed with a documented federation-partner call. Its IETF draft is
[draft-mp-agntcy-ads-02](https://datatracker.ietf.org/doc/draft-mp-agntcy-ads/)
(2026-07-06, Informational, authors Muscariello and Polic of Cisco); the draft
itself notes "This note is to be removed before publishing as an RFC". SLIM's
draft is [draft-mpsb-agntcy-slim](https://datatracker.ietf.org/doc/draft-mpsb-agntcy-slim)
(v00 October 2025, v02 current, Informational).

The observability and eval working group ships Observe-SDK, Telemetry-Hub and
OpenTelemetry over SLIM (2026-04-02).

What is announced but not standardised: there is **no IETF working group** — both
drafts are individual submissions with no responsible AD, no telechat date and no
RFC stream. There is **no consensus on record format** — ADS uses OCI plus DHT,
SLIM is a bespoke gRPC transport, OASF is a record schema, A2A uses Agent Cards
and MCP uses `server.json`: four formats. "Internet of Agents" is a slogan, not
an implemented network; no demonstrated cross-vendor agent internet running on
AGNTCY components exists.

### ANP

ANP positions itself as "the HTTP of the Agentic Web era" — a suite for identity,
naming, discovery, negotiation, secure messaging and application collaboration
that explicitly reuses HTTP, CAs, DNS, CDNs and TLS rather than building a new
stack.

**ANP-02 DID Authentication** specifies method-independent HTTP/JSON
authentication, deliberately separated from DID-method validation. It supports both
`did:wba` and **native `did:web`** (Appendix B). That separation is the most
architecturally distinctive decision in this slice. **ANP-03 did:wba** is a
W3C-style DID method with `e1_` Ed25519 path binding as the default, a `k1_`
compatibility extension (Appendix A), stable subject paths, and "verified DID
transitions" — key rotation as a first-class protocol operation. **ANP-04 WNS**
(WBA Name Space) gives human-readable handles such as `alice.example.com` mapped
to `did:wba` with **bidirectional** verification. **ANP-07 and ANP-08** are agent
description documents plus both active `.well-known` discovery and passive
registration with "search agents".

**ANP-09** defines nine messaging profiles:

| Profile | Identifier | Note |
| --- | --- | --- |
| P1 | `anp.core.binding.v1` | Core binding |
| P2 | `anp.identity.discovery.v1` | Identity discovery |
| P3 | `anp.direct.base.v1` | Direct base |
| P4 | `anp.group.base.v2` | Group base |
| P5 | `anp.direct.e2ee.v2` | Independent per-device cryptographic endpoints, per-device-pair direct sessions |
| P6 | `anp.group.e2ee.v2` | **Candidate**, stable code point pending a registered MLS ExtensionType; multiple MLS leaves |
| P7 | `anp.attachment.v1` | Attachment |
| P8 | `anp.federation.relay.v1` | Federation relay |
| P9 | mentions | Mention semantics |

Implementations **MUST NOT** reinterpret E2EE v1 state as v2 or silently
downgrade. The profile set already carries a migration hazard at version 1.

**ANP-06**, the meta-protocol, remains a draft: `MetaProtocolInterface` with
`anp.get_capabilities` and `anp.negotiate` to select interface, profile, security
profile and schema. This is the semantic-negotiation layer that UCP does with
reverse-DNS namespaces and x402 does with extensions — three incompatible answers
to the same question. **ANP-10** is an AP2 adaptation draft that delegates payment
to AP2 rather than re-specifying it.

### Agentic Commerce Protocol (ACP)

Full treatment in [`acp-others.md`](acp-others.md). The wire shape, for
comparison against the five above: HTTPS plus JSON plus HTTP verbs, **not**
JSON-RPC. Four surfaces — Checkout (`POST`/`GET /checkout_sessions`, `/complete`,
`/cancel`; plus stateless `POST /carts`, `GET|PUT /carts/{id}`, `/cancel`), Feed
(agent-hosted, merchant-pushed), Delegate Payment
(`POST /agentic_commerce/delegate_payment`, Agent to PSP, returning a scoped
`vt_…` token carrying `allowance` with `max_amount`, `merchant_id`, `expires_at`,
plus `risk_signals`) and Delegate Authentication (3DS2 Create → Authenticate →
Retrieve). Discovery is unauthenticated `GET /.well-known/acp.json`
([reference](https://agenticcommerce.dev/docs/reference/checkout)). An additive
[MCP binding](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/docs/mcp-binding.md)
(SEP #135) maps the five checkout operations to MCP tools over Streamable HTTP.

## What changed recently

### UCP

| Date | Release | What changed |
| --- | --- | --- |
| 2026-01-11 | `2026-01-11` | Dated release, per the release list |
| 2026-01-23 | `2026-01-23` | Dated release, per the release list |
| 2026-04-08 | `2026-04-08` | Dated release, per the release list |
| 2026-08-25 | `2026-08-25` | Largest release to date (below) |

`2026-08-25` is the largest release and carried an explicitly labelled
breaking-change set, with these additions and renames:

- **Actions primitive** — out-of-band authorization and form-fill requests on Cart,
  Checkout and Catalog; 3DS2 delivered through Actions.
- **`$requestConstraints`** — response-carried JSON-Schema validation with path
  targeting and `anyOf`, replacing static instrument schemas.
- **PAN versus Network Token** split into distinct credential types.
- **Split payments**, and **payment schedules** (deposits, installments, deferred).
- **Loyalty extension**; **delegated IdPs**.
- **Buyer consent** restructured into a reverse-DNS-keyed dynamic map.
- **Web Bot Auth interop (PR #483)**.
- **Canonical profile keys** — `signing_keys[]` removed; `keys[]` (a JWK Set) is
  now the only signing-key field.
- **Repo restructured** into domain verticals (`shopping/`, `payment/`,
  `common/`) with primitives under `common/types/`; payment extensions migrated
  from `dev.ucp.shopping.*` to `dev.ucp.common.payment.*`.
- **Location Search/Lookup and deterministic operating hours**; fractional
  quantities; sale-basis pricing; grocery readiness.

The release contract is now date-versioning plus independent capability
versioning, but 2026-04-08 to 2026-08-25 carried a large breaking set: an
integrator absorbs schema-level breaks roughly annually. In 2026 UCP expanded
beyond retail, with Food and Lodging verticals in progress and waitlists on the
Google side.

### AP2

**2026-04-28 produced two simultaneous events**: AP2 was donated to the FIDO
Alliance, and `v0.2` shipped. v0.2's headline addition is **Human Not Present
(autonomous) payments** — an agent executing a purchase with no user present on
the basis of pre-authorized instructions, Google's example being securing
limited-run tickets the moment they go on sale.

v0.2 renamed objects: **Cart Mandate became Checkout Mandate**. Any code or
prose written against v0.1 terminology is stale. The v0.1 "Intent" framing
(Intent Mandate, Cart Mandate) as described in the 2025-09-16 launch blog is
superseded by the Checkout/Payment Mandate split, which is a stable migration
from "Intent" to "Mandate" only in the sense that the old names should be
abandoned.

**Verifiable Intent**, co-developed by Mastercard and Google, was donated to FIDO
alongside AP2 on 2026-04-28: a tamper-proof log of user-authorized agent actions
for accountability.

### x402

| Date | Event |
| --- | --- |
| 2025-09-23 | Cloudflare and Coinbase announce intent to create the Foundation (Matthew Prince: "Coinbase deserves immense credit for starting the work") |
| 2026-02-12 | Coinbase Developer Platform's **SQL API** accepts x402 payments, for autonomous-agent on-chain data |
| 2026-03-11 | CDP x402 Facilitator adds **Polygon**; chain support spans Base, Solana, Polygon |
| April 2026 | The Linux Foundation announces intent to launch the x402 Foundation |
| 2026-06-15 | Coinbase plus **AWS CloudFront/WAF** integration so publishers and API providers can accept agents as customers via x402 `[UNVERIFIED full text — the Coinbase URL returned HTTP 403 on direct fetch and the fact rests on the search index of the primary URL]` |
| 2026-07-14 | **Operational launch of the x402 Foundation** — the most consequential governance event in this slice |

Premier members at launch: Adyen, AWS, American Express, Circle, Cloudflare,
Coinbase, Fiserv, **Google**, Mastercard, Monad Foundation, MoonPay, Ripple,
Shopify, Solana Foundation, Stellar Development Foundation, Stripe, Visa. General
members: Aleo, Fireblocks, Galaxia Moneytree, Hecto Financial, Injective, KakaoPay,
Kite AI, LayerZero Labs, Merit Systems, NEAR Foundation, Orthogonal, Polygon Labs,
Quant Network, SKALE, t54 labs, utexo, World Liberty Financial, zerohash.
Associate members: BSV Association, Cardano Foundation, Casper, Japanese Contents
Blockchain Initiative, OMA3. The 2026-07-14 launch announcement is carried on
[x402.org](https://x402.org/); the press-release URL recorded during research was
truncated and is not reproduced here.

Also added during 2026: the `upto` and batch-settlement schemes; the Bazaar
discovery extension; `settlement_pending` non-terminal settlement semantics; a
Solana SettlementCache; expanded network coverage. Contracts were audited by
Cantina three times, in February, March and May 2026.

Note that **Google is a premier member of the x402 Foundation** while authoring
UCP and having donated AP2 to FIDO. [INFERENCE] Google's position is hedged
across the payment-protocol landscape rather than committed to one.

### AGNTCY

Component repositories show 2026-09-29 updates across `slim`, `dir`, `identity`,
`identity-service`, `oasf` and `coffeeAgntcy`; the engineering blog has posts
through 2026-08-25; `OASF` skill categories are served live. Dated technical
changes in the window: TSV-driven authorisation in Identity (2026-08-25),
OpenTelemetry over SLIM (2026-04-02), browser WebSocket cross-transport support in
SLIM (2026-08-11), an OIDC gateway in `dirctl` (2026-08-10), and
[draft-mp-agntcy-ads-02](https://datatracker.ietf.org/doc/draft-mp-agntcy-ads/)
(2026-07-06). The donation to the Linux Foundation is dated 2025-07-29.

### ANP

ANP consolidated to a **1.2** document set in 2026. ANP-02 was renumbered — it was
previously tied to `did:all`, whose historical documents retain that identity.
Messaging split into an overview plus 9 profiles with a mixed-version profile
catalog. Native `did:web` integration (Appendix B) was added and `e1_` became the
default binding. A vNext workspace was created as the starting point for 1.3.
The project presented to the W3C WebAgents Community Group and recorded a
"community first meeting" milestone.

The Milestones list is honest and mostly incomplete: the meta-protocol is not
stabilised; "Complete the registered MLS ExtensionType release gate for stable P6
v2" is not done; "Continue aligning SDK implementations and examples with the 1.2
specification set and validating actual interoperability" is not done; "Continue
standardization work" is not done.

### ACP

| Date | Release | What changed |
| --- | --- | --- |
| 2025-09-29 | Initial | Launch alongside Instant Checkout in ChatGPT |
| 2025-12-12 | `2025-12-12` | Fulfillment |
| 2026-01-16 | `2026-01-16` | Capability negotiation |
| 2026-01-30 | `2026-01-30` | Payment handlers, extensions, discount — **breaking** |
| 2026-04-17 | `2026-04-17` | Latest stable: cart, feed, orders, delegate authentication, discovery, MCP |

The 2026-01-30 **Payment Handlers framework** was the breaking change: it
replaced `payment_provider.supported_payment_methods` with
`capabilities.payment.handlers[]` carrying id, name, version, spec URL,
delegation requirements, PCI information and PSP identity, and moved payment data
to `{handler_id, instrument:{type, credential:{type:"spt", token}}}`. An
**Extensions framework** followed, its first member being the Discount extension.

Governance change: Meta joined as a lead maintainer and took TSC seat 3, signing
the corporate CLA on 2026-03-19; Stripe's documentation now describes ACP as
"created by Stripe, OpenAI, and Meta". The CLA signatory list was last updated
2026-06-03.

## Evidence of adoption

### UCP

The strongest evidence is a production deployment, not a logo wall.
[developers.google.com/merchant/ucp](https://developers.google.com/merchant/ucp)
is a live merchant integration guide for **AI Mode in Google Search and Gemini**,
with native checkout as the default and embedded checkout available to approved
merchants, Merchant Center feeds as the discovery substrate, a waitlist, and an
explicit statement that "you remain the Merchant of Record". Native SDKs and a
conformance suite are published.

Spec documentation also ships partner logos, split into two tiers. **Co-developed**:
Google, Shopify, Stripe, Amazon, Meta, Microsoft, Salesforce, Etsy, Target,
Walmart, Wayfair, DoorDash, Square/Block, Toast, Uber Eats; for lodging, Amadeus,
Booking.com, Hilton, Trip.com, Expedia, Marriott. **Endorsed**: Adyen, Affirm, Amex,
Ant International, Best Buy, Block, Carrefour, Checkout.com, and others. These are
site logos, not a signed commitment list.

Adoption honesty: the ecosystem is overwhelmingly shopping and overwhelmingly
Google-surface. Lodging and Food are waitlists, not general availability. The
number of independently deployed non-Google implementations, and the number of
implementations that have passed the conformance suite, are NOT ESTABLISHED IN
SOURCE.

### AP2

**Launch breadth, 2025-09-16**: "more than 60 organizations", with named
endorsements from Adyen, American Express, Ant International, Coinbase, Etsy,
Forter, Intuit, JCB, Mastercard, Mysten Labs, PayPal, Revolut, Salesforce,
ServiceNow, UnionPay International and Worldpay, plus Accenture, Adobe,
Airwallex, BHN, BVNK, Checkout.com, Confluent, Dell, Deloitte, DLocal, Ebanx,
Eigen Labs, Gr4vy, Gravitee, Global Fashion Group, 1Password, Fiuu, JusPay, KCP,
Lightspark, ManusAI, Mesh, Nexi, Okta, Payoneer, PwC and Shopee
([launch post](https://cloud.google.com/blog/products/ai-machine-learning/announcing-agents-to-payments-ap2-protocol)).

**FIDO board-level institutional backing, 2026-04-28**: 1Password, American
Express, Dashlane, Egis, Google, LastPass, Mastercard, OneSpan, PayPal, Prove
Identity, Thales and Visa all issued supporting statements, and Visa and
Mastercard **chair** the Payments TWG
([FIDO announcement](https://fidoalliance.org/fido-alliance-to-develop-standards-for-trusted-ai-agent-interactions/)).

**Real but pre-production**: the [FAQ](https://ap2-protocol.org/faq) is explicit
that the samples **mock actual payment service providers**, and that "we are
working on an SDK and a MCP server right now, in collaboration with payment
service providers. Check back soon." No named PSP is shipping AP2 mandates in
production as of this research date. `a2a-x402` is the one shipped production
artifact connecting AP2 to crypto rails.

### x402

This is the only protocol in the set with a measured production signal. The
[x402.org](https://x402.org/) counters, site last updated 2026-08-25, report
**75.41M transactions, $24.24M volume, 94.06K buyers, 22K sellers in the last 30
days**. The Foundation reports 40 organisations at operational launch on
2026-07-14, including Visa, Mastercard, American Express, Stripe, Adyen and
Fiserv.

Named production integrations: the Coinbase CDP SQL API, Coinbase plus AWS
CloudFront/WAF, and — on the x402.org site — Alchemy, Nansen, QuickNode, Messari,
Vercel and World. Ecosystem directories exist outside the Foundation —
x402scan.com, Agentic.Market, pay.sh, app.ampersend.ai/discover, x402-list.com —
which is a sign of organic rather than centrally gated growth. The number of
production facilitators, and any breakdown of the transaction counts by network,
are NOT ESTABLISHED IN SOURCE.

### AGNTCY

- **Cisco's own AI Catalog** is built on ADS plus OASF and is the product the ADS
  documentation points users to. Real, and captive.
- **Outshift/ServiceNow, 2026-06-09** ([writeup](https://outshift.cisco.com/blog/ai-ml/service-now-outshift-multi-agent-enterprise)):
  a federated-agent-discovery plus distributed-workflow architecture combining
  governance with ADS federation. ServiceNow is a genuinely independent adopter
  and an A2A launch partner.
- **SoftServe** deployed a multi-agent video intelligence system powered by SLIM.
- **Orium** and **DataWell** are cited as extending the Internet of Agents in
  2026.
- [LFX Insights](https://insights.linuxfoundation.org/project/agntcy) records 42
  contributing organisations and 23 merge-right maintainers — a multi-vendor
  contributor base that most agent-protocol repositories do not have.
- **Éric Vyncke (Cisco) is the Responsible Area Director for the proposed IETF
  DAWN working group**, and the AGNTCY team is staffing that discovery WG.

### ANP

1,437 stars and 104 forks is real attention for a specification repository with no
foundation behind it. Implementations exist, but all from the same community:
**AgentConnect**, the reference SDK, and **AWiki** — `awiki-cli-rs2` (Rust),
`awiki-me` (Flutter), `awiki-open-server` — all under the AgentConnect and
`agent-network-protocol` organisations.

There is **zero evidence of independent third-party deployments**: no named
enterprise adopter, no foundation membership, no standards-body presence beyond a
Community Group presentation. The "global first open agent network" posts in the
Chinese-language blog series are promotional, not deployment evidence.

### ACP

Launch 2025-09-29 with Instant Checkout in ChatGPT, US, for Etsy sellers and
"coming soon" 1M+ Shopify merchants. The hard adoption signal is the
[corporate CLA signatory list](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/legal/cla/SIGNATORIES.md),
updated 2026-06-03, all under the 2025-11-21 agreement:

| Organization | Signed | Issue |
| --- | --- | --- |
| Stripe, Inc. | 2025-11-21 | — |
| OpenAI LLC | 2025-11-21 | — |
| Adyen N.V. | 2026-01-28 | #87 |
| Wix.com Ltd. | 2026-02-19 | #155 |
| commercetools Inc. | 2026-02-19 | #145 |
| OpenCommerce Network Inc. | 2026-02-26 | #163 |
| Affirm Inc. | 2026-03-09 | #172 |
| Meta Platforms, Inc. | 2026-03-19 | #185 |
| Agentic Commerce Inc. (Catalog) | 2026-03-30 | #206 |
| PayPal, Inc. | 2026-04-16 | #210 |

Non-Stripe PSPs and fintechs are Adyen, Affirm and PayPal. Whether Adyen or Affirm
have shipped production ACP endpoints is `[UNVERIFIED]`; a CLA signature is not
shipping. Production ACP is concentrated on the ChatGPT/Stripe path: the spec site
concedes "Discovery tooling is in progress" and "Each AI platform manages
onboarding", so there is no ACP-wide merchant registry and reach-out is an email
address.

The strongest single signal against ACP's momentum is
[Shopify's ChatGPT channel documentation](https://help.shopify.com/en/manual/online-sales-channels/agentic-storefronts/chatgpt):
Shopify now describes the ChatGPT channel as a discovery *referrer* — "ChatGPT
users complete their purchase on your online store checkout in a ChatGPT in-app
browser… ChatGPT is a product discovery channel… therefore there's no option to
activate or deactivate a ChatGPT direct checkout setting" — and reserves **direct
checkout** for Google AI Mode/Gemini, Microsoft Copilot and Meta. Shopify was ACP's
launch partner and is now a UCP co-developer.

The Domain Working Groups defined in governance (Travel, Fitness & Wellness,
Grocery Delivery, Donations) have **no announced rosters** `[UNVERIFIED]`, and
are most likely unfilled.

## Sharp edges

### UCP

- **Authority binding is provenance, not trust, and the spec says so explicitly.**
  A valid binding proves only that the name is controlled by the party owning the
  domain. Every trust decision is pushed to negotiation time.
- **No Public Suffix List consultation.** The derivation algorithm treats a public
  suffix — `github.io`, `co.uk`, S3 buckets — as an ordinary authority, so
  co-tenants under such a suffix satisfy the same prefix rule. The spec's
  mitigation is prose only: "declare entities only under a registrable domain you
  exclusively control". That is a live footgun for anyone hosting schemas on
  object storage.
- **Binding is not fetch-safety.** The hostname check and the resolved-address
  SSRF check are independent and both required; it is easy to implement one and
  miss the other.
- **Platform conflict of interest is structural.** Google is simultaneously the
  spec's largest steward, the platform UCP primarily serves (AI Mode, Gemini), and
  a merchant via its own payments stack. Merchant of Record staying with the
  merchant mitigates but does not remove this.
- **`ucp.dev` is not a foundation domain.** UCP was donated nowhere; continuity
  risk is concentrated in Google plus Shopify.
- **Autonomous checkout is gated.** Checkout "has to be finalized manually by the
  user through a trusted UI unless the AP2 Mandates extension is supported"
  ([checkout capability spec](https://ucp.dev/latest/specification/shopping/checkout)),
  so UCP's autonomous path depends on AP2 adoption.

### AP2

- **Still 0.x with a mid-flight object-model rename.** Mandate version suffixing
  via `vct` is well designed, but a breaking vocabulary change one release in is
  a maturity signal.
- **Agent-to-agent mandate delegation is explicitly out of scope** — "outside the
  scope of the current specification". AP2 does not yet do what its abbreviation
  implies for agent-swarm payment chains.
- **Automatic mandate retrieval is out of scope.** A method to retrieve the
  Checkout Mandate keyed by the Payment Mandate's `transaction_id` "would provide
  substantial utility" but is undefined, so dispute evidence in practice requires
  out-of-band retention by all parties.
- **Direct mode often collapses to ordinary e-commerce.** The spec concedes "this
  can often be replaced with a traditional e-commerce journey". The differentiator
  is Autonomous mode, which is precisely the newest and least-deployed part.
- **The constraint expression language is unspecified.** The guarantee is
  "verifiable intent, not inferred action", but the spec concedes the agent
  "needs to determine the applicable Mandates and Disclosures ad-hoc… an explicit
  query language in the commerce protocol can help practical interoperability."
- **Ed25519 is prohibited** for the Checkout JWT. Many toolchains default to
  Ed25519; this is a non-obvious interop trap.
- **The FIDO membership model.** FIDO Alliance members include PayPal and American
  Express. A protocol stewarded by a body whose membership skews toward the
  parties that will adjudicate the resulting disputes is a structural
  consideration, not an accusation.
- **The org moved and the docs did not**, at least for `a2a-x402` `[UNVERIFIED
  which is current]`.

### x402

- **The facilitator is the trust chokepoint.** It holds no funds, and the protocol
  is designed trust-minimising — "all payment schemes must not allow for the
  facilitator or resource server to move funds, other than in accordance with
  client intentions" — but verification and settlement pass through it. The README
  hedges toward self-facilitation for production, so the "one line of code" pitch
  and the "you must run your own chain layer" reality are both true.
- **A documented Solana race.** Duplicate `/settle` submissions before confirmation
  return success to both callers, because Solana RPC reports duplicates as
  success — "a malicious client could exploit this to access multiple resources
  while only paying once". The built-in in-memory SettlementCache (120s TTL,
  roughly twice the blockhash lifetime) mitigates it and is enabled by default in
  the TypeScript and Python helpers, but **merchants settling directly must
  implement this themselves**. That is an unmitigated-by-default money bug in the
  merchant path.
- **`settlement_pending` versus platform deadlines.** The default
  `confirmationTimeoutMs` is 180,000 ms (3 minutes, the viem default) and 120s in
  Python. Behind a serverless or gateway deadline this yields a 5xx *with no
  transaction hash* instead of a reconcilable `settlement_pending` — an
  operational footgun that is documented but easy to miss.
- **Bazaar is immature by its own admission**: "in early development… we're
  currently more like 'Yahoo search'". Discovery is a facilitator-operated
  catalogue, so the index is only as good as the facilitators that run it.
- **Crypto-first economics.** 75M transactions against $24.24M volume is roughly
  $0.32 average: micropayment economics, not commerce. Card rails are a
  Foundation roadmap item, not a shipped scheme.
- **Version-number ambiguity** between `x402Version: 1` in the core spec and
  `x402Version: 2` in Bazaar resource entries.
- **No identity story.** x402 pays; it does not say who the agent is or who
  authorised it. That is AP2's job, or a Web Bot Auth or DID layer's job, bridged
  today only by `a2a-x402`.

### AGNTCY

- **Concentration risk, stated explicitly.** 13 of 15 working-group leads are
  Cisco; the TSC is 8 people from 5 companies but Cisco holds 3 seats and all
  execution; and Cisco cut roughly 4,000 jobs on 2026-05-13. Linux Foundation
  hosting gives legal and trademark neutrality, not operational independence
  `[INFERENCE]`.
- **IETF strategy is "file drafts and hope".** Both drafts are Informational
  individual submissions authored entirely by Cisco employees, with no AD
  assigned. That is the weakest possible IETF posture.
- **Star counts are an order of magnitude below UCP (3.4k), AP2 (3.2k) and x402
  (6.7k).** The most-staffed project in this slice has the least visible
  adoption.
- **It does not compose cleanly with the winners.** AGNTCY assumes OASF records,
  so a platform running A2A or MCP must translate. The SLIM `a2a-*` adapters at
  1-2 stars each show how early that integration is.
- **Bus factor and responsiveness.** LFX reports a median maintainer first response
  of **20 days** — healthy, not fast.
- **ADS is drifting toward Cisco's AI Catalog data model.** The draft has an
  entire "AI Catalog Interoperability" section and an "AI Finder Service", which
  risks the open directory becoming a feed for a Cisco product.
- **No identity interop.** AGNTCY Identity does not bridge to `did:web`, to Web
  Bot Auth, or to FIDO's agentic work. It is a closed-ish scheme.
- **Four record formats, no consensus**: OCI plus DHT for ADS, bespoke gRPC for
  SLIM, OASF as a schema, Agent Cards for A2A, `server.json` for MCP.

### ANP

- **Single-organization by any honest measure.** Personal email contacts, a WeChat
  ID, one GitHub organisation, one reference-implementation family, no
  foundation, no IPR policy.
- **The repository is the protocol.** No released spec versioning process, no
  errata process, no reference-implementation conformance suite, no independent
  test vectors. Git history *is* the standards process.
- **Document sprawl and frozen legacy paths.** The README openly documents that
  `examples/`, `vnext/` and `chinese/` paths "retain -vnext for path
  compatibility" and that "earlier scattered paths remain frozen copies". A
  protocol that cannot delete its own files is hard to maintain.
- **The P6 gate is a real dependency on an external standard**: stable group
  E2EE is blocked on a registered MLS ExtensionType. Which MLS working group or
  registry owns that gate is `[UNVERIFIED]` — the README asserts the gate and the
  registration status was not checked.
- **No interop with A2A or MCP in practice.** The repository's own comparison
  posts frame ANP as against MCP, not with it. In a world where MCP and A2A won,
  ANP is a parallel stack, not a layer.
- **Nine messaging profiles is a lot of surface for zero deployed deployments.**
  Every profile is a compatibility liability with no implementations to validate
  against.
- **Naming collision.** "ACP" is used by OpenAI plus Stripe for the commerce
  protocol, by `agntcy/acp-sdk` (deprecated, Agent Connect Protocol) and by
  several payment vendors. See [`acp-others.md`](acp-others.md) for the
  disambiguation.

### ACP

Summarised here; the full list is in [`acp-others.md`](acp-others.md). The four
that bear on the commerce comparison:

- **Docs lag the repo.** `agenticcommerce.dev/docs/changelog` stops at
  2026-01-30 and never mentions 2026-04-17, the Carts API, the Feed API,
  `/.well-known/acp.json` or the MCP binding, while the repository README still
  says "maintained by OpenAI and Stripe" against a `MAINTAINERS.md` and Stripe
  docs that say three. Anyone implementing from the spec site builds two releases
  behind.
- **Founding Maintainer veto.** OpenAI and Stripe hold a block-only veto over SEPs
  for an "open standard"; it is bounded by four principles, but it is a real
  concentration.
- **Feed direction inversion is a structural liability.** Merchants push
  catalogues into every agent, so there is no portable, merchant-owned
  catalogue-of-record across agents — the opposite of UCP's pull model.
- **Momentum is not uniform.** Last stable spec 2026-04-17 (5 months), last commit
  2026-07-18 (about 10 weeks), and Shopify demoting ChatGPT to a referrer, while
  the same vendors (Stripe, Meta, PayPal) ship or back UCP as well.

## Comparison and verdict

| Protocol | Steward, dated | Latest dated spec | Repo, 2026-09-29 | Non-founder named production deployer | Measured production signal | Tier |
| --- | --- | --- | --- | --- | --- | --- |
| **x402** | x402 Foundation under the Linux Foundation, operational 2026-07-14, 40 organisations | `x402Version: 1` core spec; SDK line v2 | 6.7k stars, 2.1k forks, Apache-2.0 | AWS, Cloudflare, Alchemy, Nansen, QuickNode, Messari, Vercel, World | **75.41M transactions, $24.24M, 94.06K buyers, 22K sellers in 30 days** (site 2026-08-25) | 1 |
| **UCP** | Private Governance Council — Google, Shopify, Stripe, 2 seats open; no foundation | `2026-08-25` | 3.4k stars, 471 forks, Apache-2.0 | Google, live in AI Mode and Gemini; partner logos are not commitments | Production deployment on Google surfaces, with a waitlist | 1 |
| **AP2** | FIDO Alliance Payments TWG, donation and v0.2 both 2026-04-28, chaired by Mastercard and Visa | `0.2.0`, 2026-04-28 | 3.2k stars, 504 forks, Apache-2.0 | 60+ launch partners; samples mock all PSPs | **None**: no named PSP ships AP2 mandates in production | 2 |
| **AGNTCY** | Linux Foundation, donation 2025-07-29; **not** AAIF | No dated spec release; two Informational IETF drafts, 2026-07-06 latest | Org 1.1k followers, 50 repos; components 334/220/190/112/103/67 | Cisco AI Catalog; ServiceNow (2026-06-09); SoftServe | LFX health 83/100, 42 contributing organisations, "Active" | 2 |
| **ACP** | OpenAI, Stripe, Meta; 7-seat TSC, 3 filled; no foundation | `2026-04-17`, Beta | ~1.6k stars, 251 forks, Apache-2.0 plus CLA | ChatGPT/Stripe production; Adyen, Wix, commercetools, Affirm, PayPal signed the CLA `[UNVERIFIED shipped]` | Instant Checkout in ChatGPT, live since 2025-09-29, one vendor path | 2 |
| **ANP** | **None** — personal email contacts, no working group | `1.2` document set, undated; ANP-06 and ANP-10 draft | 1,437 stars, 104 forks, Apache-2.0 | None; AgentConnect and AWiki only, same community | **None** | 3 |

### Four-tier verdict

**Tier 1 — real and shipping.** Two protocols, and they are shipping different
things. **x402** is the narrowest in scope and the only one with a working
governance body, a production marketplace story and a measurable transaction
count; its weakness is that it says nothing about who the agent is or who
authorised it. **UCP** is real, in production on Google AI Mode and Gemini, with a
published conformance suite and four dated releases in 2026 — but it is gated
behind a single vendor's surfaces and is governed privately, so nobody outside
Google and Shopify can direct it. Also at this tier by the stated criterion, but
recorded in the identity document rather than here: Web Bot Auth, which UCP has
already adopted via PR #483.

**Tier 2 — real code, real governance, thin adoption.** Three protocols.
**AP2** has genuinely well-specified cryptography, a real SDK, 60+ launch partners
and 12 FIDO board endorsements, but is v0.2, renamed its core objects one release
in, mocks every PSP in its samples, and has no named PSP in production.
**AGNTCY** has four shipped components, a 42-organisation contributor base, two
Informational IETF drafts and a genuinely independent adopter in ServiceNow, but
13 of 15 working-group leads are Cisco and its star counts are an order of
magnitude below the Tier 1 projects. **ACP** ships to real users through
ChatGPT, but on a single vendor path, and the strongest available signal —
Shopify reducing its ChatGPT channel to a referrer — cuts against it. Included
here rather than in Tier 1 because the criterion for Tier 1 is a named
non-founder implementer with a production deployment, and for ACP that is
`[UNVERIFIED]`: the non-founder names are CLA signatories.

**Tier 3 — specified, governance thin or absent, deployment near zero.** **ANP**
only. It has the best-designed DID and agent-identity stack in the set on paper —
method-independent authentication separated from DID-method validation, bidirectional
WNS handles, `e1_` Ed25519 binding, nine messaging profiles, and an AP2 adaptation
that correctly delegates payment rather than re-specifying it — and it is
essentially undeployed, under no foundation, by any honest measure one
organisation. Its own milestone list concedes that interoperability validation is
not done.

**Tier 4 — announced, not yet real.** The items that would be cited as adoption
if they shipped: UCP's Food and Lodging verticals, which are waitlists; AGNTCY's
SLIM-to-A2A transport adapters for node, Java and .NET, at 1-2 stars each; the
x402 Bazaar catalogue, described by its own maintainers as "more like Yahoo
search"; and ACP's Travel, Fitness & Wellness, Grocery Delivery and Donations
Domain Working Groups, whose rosters are not announced `[UNVERIFIED]`. FIDO's
separate Agentic Authentication TWG, formed April 2026, is adjacent to this slice
and is recorded in the governance document.

Two cross-cutting patterns close the evidence:

1. **Payments is the only layer with a governance winner, and it took an
   operating-system vendor to force it.** x402 reached the Linux Foundation with
   Visa, Mastercard and American Express at the table only after Coinbase shipped
   it and Cloudflare co-founded the Foundation. AP2 reached FIDO with Mastercard
   and Visa chairing. UCP went nowhere and remains a private Google-plus-Shopify
   instrument. The observed order is code first, foundation second, always with a
   payment network as anchor tenant.
2. **Vendors are shipping both sides.** Stripe co-sponsors ACP and sits on the
   UCP co-developer wall; Meta holds ACP TSC seat 3 and is a UCP co-developer;
   PayPal's Agent Ready product advertises both an ACP integration for ChatGPT
   and a UCP integration for Google AI Mode/Gemini. No statement from OpenAI,
   Stripe, Google or Shopify that UCP and ACP converge was found `[UNVERIFIED —
   searched, none found]`, and ACP's own governance document anticipates the
   opposite: "Can TSC members or contributors also participate in other competing
   or complementary protocols? A: Yes. There are no restrictions against working
   with other protocols." The two protocols split on discovery direction — ACP
   pushes merchant catalogues into an agent-hosted feed, UCP pulls from
   merchant-hosted `/.well-known/ucp` — on trust model, and on payment rails.
   Merchant of record is **not** the differentiator: both keep it with the
   merchant. Agent-to-agent commerce is first-class in neither.

## Sources

### UCP

- [ucp.dev/specification/overview](https://ucp.dev/specification/overview/) — namespace authority binding algorithm, capability and service definitions
- [ucp-spec core concepts](https://raw.githubusercontent.com/Universal-Commerce-Protocol/ucp/main/docs/documentation/core-concepts.md) — roles, `/.well-known/ucp`, `UCP-Agent`, capability intersection
- [UCP v2026-08-25 release](https://github.com/Universal-Commerce-Protocol/ucp/releases/tag/v2026-08-25) — full change and breaking-change list
- [UCP MAINTAINERS.md](https://raw.githubusercontent.com/Universal-Commerce-Protocol/.github/main/MAINTAINERS.md) — council and tech-council roster
- [Google merchant UCP guide](https://developers.google.com/merchant/ucp) — deployment path, AI Mode and Gemini, Merchant of Record
- [UCP checkout capability spec](https://ucp.dev/latest/specification/shopping/checkout) — the trusted-UI requirement and the AP2 Mandates exception
- [ucp.dev](https://ucp.dev/) — specification site

### AP2

- [ap2-protocol.org specification](https://ap2-protocol.org/ap2/specification/) — roles, mandates, modes, dispute evidence
- [AP2 agent authorization](https://ap2-protocol.org/ap2/agent_authorization/) — Mandate Delegation and Action Authorization, OpenID4VP with SD-JWT Key Binding, User Credential versus Trusted Agent Provider
- [AP2 payment mandate](https://ap2-protocol.org/ap2/payment_mandate) and [checkout mandate](https://ap2-protocol.org/ap2/checkout_mandate) — mandate structures and receipts
- [AP2 flows](https://ap2-protocol.org/ap2/flows/) — Human Present and Human Not Present worked examples
- [AP2 FAQ](https://ap2-protocol.org/faq) — UCP versus AP2, `a2a-x402`, mocked PSPs, SDK status, FIDO continuation
- [AP2 CHANGELOG.md](https://raw.githubusercontent.com/google-agentic-commerce/AP2/main/CHANGELOG.md) — 0.1.0 2025-09-16, 0.2.0 2026-04-28
- [Google Cloud launch post, 2025-09-16](https://cloud.google.com/blog/products/ai-machine-learning/announcing-agents-to-payments-ap2-protocol) — 60+ partners, v0.1 Intent/Cart/Payment framing, `a2a-x402`
- [Google blog, 2026-04-28](https://blog.google/products-and-platforms/platforms/google-pay/agent-payments-protocol-fido-alliance/) — donation, v0.2, Verifiable Intent
- [FIDO Alliance announcement](https://fidoalliance.org/fido-alliance-to-develop-standards-for-trusted-ai-agent-interactions/) — TWG formation, chairs, board endorsements
- [google-agentic-commerce/AP2](https://github.com/google-agentic-commerce/AP2) — repository layout, SDK, sample scenarios, PyPI status
- [ap2-protocol.org](https://ap2-protocol.org/) — project home

### x402

- [x402 core specification v1](https://raw.githubusercontent.com/coinbase/x402/main/specs/x402-specification-v1.md) — core types, EIP-3009, SVM constraints, facilitator endpoints
- [x402-foundation/x402](https://github.com/x402-foundation/x402) — repository, schemes, chain packages, audit PDFs, production path guidance
- [x402.org](https://x402.org/) — 30-day volume counters, member logos, FAQ, Foundation launch announcement
- [x402 facilitator concepts](https://docs.x402.org/core-concepts/facilitator) — header names, `settlement_pending`, the Solana duplicate-settlement race
- [x402 Bazaar extension](https://docs.x402.org/extensions/bazaar) — discovery endpoint, MCP tool shape, `EXTENSION-RESPONSES`
- [x402 docs index](https://docs.x402.org/llms.txt)
- [Coinbase, x402 Facilitator adds Polygon, 2026-03-11](https://www.coinbase.com/en-es/developer-platform/discover/launches/x402facilitator-polygon)
- [Coinbase and AWS CloudFront/WAF, 2026-06-15](https://www.coinbase.com/blog/coinbase-and-aws-let-publishers-accept-agents-as-customers-via-x402) — `[UNVERIFIED full text; HTTP 403 on direct fetch]`
- [Cloudflare press release, 2025-09-23](https://www.cloudflare.com/en-gb/press/press-releases/2025/cloudflare-and-coinbase-will-launch-x402-foundation/)

### AGNTCY

- [github.com/agntcy](https://github.com/agntcy) — organisation, TSC, component repositories
- [AGNTCY WORKING-GROUPS.md](https://raw.githubusercontent.com/agntcy/governance/main/working-groups/WORKING-GROUPS.md) — working-group leads and the Deprecated list
- [AGNTCY OPERATING_MODEL.md](https://raw.githubusercontent.com/agntcy/governance/main/OPERATING_MODEL.md) — charter, TSC responsibilities
- [Cisco Outshift on the Linux Foundation donation](https://outshift.cisco.com/blog/agntcy-donated-to-linux-foundation)
- [LFX Insights project page](https://insights.linuxfoundation.org/project/agntcy) — health metrics
- [ADS overview](https://dir.agntcy.org/latest/dir/dir-overview) — DHT plus OCI architecture, `ads.outshift.io`
- [draft-mp-agntcy-ads](https://datatracker.ietf.org/doc/draft-mp-agntcy-ads/) — Informational, no AD
- [draft-mpsb-agntcy-slim](https://datatracker.ietf.org/doc/draft-mpsb-agntcy-slim) — SLIM draft
- [aaif.io/projects](https://aaif.io/projects) — establishes that AGNTCY is absent from AAIF
- [Linux Foundation AAIF formation, 2025-12-09](https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation)
- [Outshift/ServiceNow, 2026-06-09](https://outshift.cisco.com/blog/ai-ml/service-now-outshift-multi-agent-enterprise) — the independent adopter
- [AGNTCY engineering blog feed](https://blogs.agntcy.org/feed.xml) — engineering cadence through 2026-08-25
- [Cisco "Our Path Forward" memo](https://blogs.cisco.com/news/our-path-forward) — 2026-05-13 restructuring; the ~4,000 figure is `[UNVERIFIED]` against the memo text
- The Linux Foundation AGNTCY welcome press release is dated 2025-07-29; the URL recorded during research was truncated and is not reproduced here

### ANP

- [AgentNetworkProtocol repository](https://github.com/agent-network-protocol/AgentNetworkProtocol) — specification index, statuses, profiles, milestones, contacts
- [ANP 1.2 stack overview](https://agent-network-protocol.com/en/about)
- [ANP second domain](https://www.agent-network-protocol.com/)
- [Original ANP repository](https://github.com/agent-network-protocol/anp)
- [ANP direct E2EE profile page](https://www.agent-network-protocol.com/specs/1.1/message/direct-e2ee) — 1.1 path, showing version drift across sites

### ACP

- [agentic-commerce-protocol repository](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol)
- [MAINTAINERS.md](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/MAINTAINERS.md)
- [docs/governance.md](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/docs/governance.md) — TSC, SEP process, Founding Maintainer veto
- [docs/mcp-binding.md](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/docs/mcp-binding.md) — SEP #135
- [changelog/2026-04-17.md](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/changelog/2026-04-17.md)
- [add-meta-tsc-member.md](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/changelog/unreleased/add-meta-tsc-member.md)
- [legal/cla/SIGNATORIES.md](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/legal/cla/SIGNATORIES.md) — updated 2026-06-03
- [agenticcommerce.dev/docs](https://agenticcommerce.dev/docs) and [llms.txt](https://agenticcommerce.dev/llms.txt)
- [ACP checkout reference](https://agenticcommerce.dev/docs/reference/checkout)
- [OpenAI checkout spec](https://developers.openai.com/commerce/specs/checkout) and [payment spec](https://developers.openai.com/commerce/specs/payment)
- [OpenAI key concepts](https://developers.openai.com/commerce/guides/key-concepts) — the merchant-of-record statement
- [Stripe ACP docs](https://docs.stripe.com/agentic-commerce/acp)
- [Stripe launch post, 2025-09-29](https://stripe.com/blog/developing-an-open-standard-for-agentic-commerce) and [press release](https://stripe.com/newsroom/news/stripe-openai-instant-checkout)
- [Shopify ChatGPT channel help doc](https://help.shopify.com/en/manual/online-sales-channels/agentic-storefronts/chatgpt) — ChatGPT as a referrer, direct checkout elsewhere
- [PayPal Agent Ready](https://developer.paypal.com/agent-ready/overview) — ships both ACP and UCP integrations
- [Visa Trusted Agent Protocol](https://developer.visa.com/capabilities/trusted-agent-protocol/overview) and [Visa Intelligent Commerce](https://www.visa.com/en-us/solutions/intelligent-commerce) — orthogonal credential rails
- Full ACP treatment: [`acp-others.md`](acp-others.md)
