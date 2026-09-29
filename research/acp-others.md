# The other three protocols that share the ACP acronym

This document covers the three protocols named `ACP` that are not the Agent Client
Protocol: the IBM/BeeAI **Agent Communication Protocol**, the OpenAI/Stripe/Meta
**Agentic Commerce Protocol**, and the **Agent Control Protocol**. It records why
each exists, what happened to it, and who uses it. It does not cover the Agent
Client Protocol itself, which is documented separately in
[`acp-agent-client.md`](acp-agent-client.md), and it defines no wire values.

The acronym is **four-way ambiguous**. Four unrelated protocols have shipped under
it, none interoperate, and all four use a different wire format:

1. Agent **Client** Protocol — editor ↔ coding agent, JSON-RPC 2.0 over stdio.
2. Agent **Communication** Protocol — IBM/BeeAI, agent ↔ agent, REST over HTTP.
3. **Agentic** Commerce Protocol — buyer ↔ agent ↔ merchant, REST over HTTPS.
4. Agent **Control** Protocol — agent → application UI commands, WebSocket.

A fifth, the Agent Context Protocol ([`github.com/agx-dev/acp`](https://github.com/agx-dev/acp),
1 star), takes the same acronym for an agent-memory proposal. It appears in
[State](#state) and in the closing table and is not covered further here. None of
the four appear in the
[Agentic AI Foundation project list](https://aaif.io/projects).

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

### Agent Communication Protocol — IBM / BeeAI

| Property | Value |
| --- | --- |
| Expansion | Agent Communication Protocol |
| Originator | IBM Research, March 2025, to power the BeeAI Platform |
| Donated to | Linux Foundation, with BeeAI, later in March 2025 (exact day NOT ESTABLISHED IN SOURCE) |
| Merged into | A2A, 2025-08-25 |
| Repository | [`i-am-bee/acp`](https://github.com/i-am-bee/acp) — **archived by the owner 2025-08-27**, read-only, labelled "Public archive"; final commit `e5265ca` (2025-08-25) |
| Licence | Apache-2.0 |
| Repository size | ~1,016 stars, 126 forks, 0 open issues |
| Spec site | [`agentcommunicationprotocol.dev`](https://agentcommunicationprotocol.dev/introduction/welcome) — still live, still serving the complete REST specification, carrying only a red banner: "ACP is now part of A2A under the Linux Foundation!" No deprecation notice, no redirect. Last protocol-relevant content on the site is undated |
| SDK | `acp-sdk` still published on PyPI and npm |
| Governance | None. Not an AAIF project |

The repository banner is the unambiguous ground truth: the
[repository itself](https://github.com/i-am-bee/acp) states "This repository was
archived by the owner on Aug 27, 2025. It is now read-only."

ACP is not an AAIF project, one hop indirectly. It merged into
[A2A](https://github.com/a2aproject/A2A), and A2A was accepted into AAIF as a
Growth Stage project on 2026-08-17; AAIF's own
[announcement](https://aaif.io/blog/a2a-joins-aaif) states "In August 2025, IBM's
Agent Communication Protocol merged into A2A." ACP itself never joined: it had
already been absorbed when [AAIF was formed on 2025-12-09](https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation)
with MCP, goose and AGENTS.md. The LF-hosted BeeAI project is separate from ACP
and did not absorb it.

The full AAIF project list — MCP, goose, AGENTS.md, agentgateway, Agent2Agent,
Agent Router — [contains no ACP](https://aaif.io/projects).

### Agentic Commerce Protocol — OpenAI, Stripe, Meta

| Property | Value |
| --- | --- |
| Expansion | Agentic Commerce Protocol |
| `ACP` is the project's own name | Yes — GitHub org [`agentic-commerce-protocol`](https://github.com/agentic-commerce-protocol), spec title, [Stripe's doc heading](https://docs.stripe.com/agentic-commerce/acp), and the discovery document's `protocol.name: "acp"` |
| Spec site | [`agenticcommerce.dev`](https://www.agenticcommerce.dev/docs) |
| Repository | [`agentic-commerce-protocol/agentic-commerce-protocol`](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol) — 102 commits, ~1.6k stars, 251 forks |
| Licence | Apache-2.0 **plus a CLA** under a "Collaboration and Governance Agreement" dated 2025-11-21. Third-party contributions require CLA execution |
| Status badge | **Beta** |
| Versioning | Date-based. No semver, no 1.0 |
| Latest stable spec | **2026-04-17** |
| Last repository commit | **2026-07-18** (SEP #281) |
| Governance | Founding Maintainers OpenAI and Stripe; 7-seat TSC, 3 seats filled; **not donated to any foundation** |

**Governance.** The Founding Maintainers are OpenAI and Stripe
([`docs/governance.md`](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/docs/governance.md)).
The TSC has 7 seats; three are filled — OpenAI (`aravindrao-openai`), Stripe
(`prasad-stripe`) and Meta (`lhwa`), per
[`MAINTAINERS.md`](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/MAINTAINERS.md).
Meta's seat came via
[`changelog/unreleased/add-meta-tsc-member.md`](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/changelog/unreleased/add-meta-tsc-member.md),
and Meta signed the corporate CLA on **2026-03-19** (issue #185).
[Stripe's documentation](https://docs.stripe.com/agentic-commerce/acp) now describes
ACP as "created by Stripe, OpenAI, and Meta". The governance FAQ names Linux
Foundation and OpenJS only as a gated long-term goal. Founding Maintainers hold a
veto over SEPs, bounded to block-only.

**Version history.**

| Release date | Content |
| --- | --- |
| 2025-09-29 | Initial release |
| 2025-12-12 | Fulfillment |
| 2026-01-16 | Capability negotiation |
| 2026-01-30 | Payment Handlers, Extensions, Discount — breaking |
| 2026-04-17 | Cart, Feed, orders, delegate authentication, discovery, MCP — latest stable |

No commits in roughly the 10 weeks between 2026-07-18 and the research date
[INFERENCE from the commit list].

### Agent Control Protocol

| Property | Value |
| --- | --- |
| Expansion | Agent Control Protocol |
| Repository | [`agent-control-protocol/acp`](https://github.com/agent-control-protocol/acp) |
| Status | Draft, spec badge v2.0 |
| Transport | WebSocket |
| Scale | ~7 stars |
| Governance | None published. Not under a foundation or a standards body |
| First commit date | NOT ESTABLISHED IN SOURCE |

The repository README carries an unusual embedded HTML comment,
`<!-- curadoria: ... confirmed-useful="2026-09-02" -->`, which is not a normal
governance signal.

**Conflicting attribution, recorded rather than resolved.** The ACP research
opened the repository above and describes a manifest plus `set_field`, `click` and
`navigate` commands over WebSocket, 8 actions, 15 field types, a 41-test
conformance suite and the `@acprotocol/server` reference server, with the only
production implementation being a single vendor's product. The commerce research
instead attributes the name to "academic / enterprise (not one project)",
admission control and risk scoring over agent execution traces, citing arXiv only
and marked `[UNVERIFIED]` because the paper was never opened. The identity of the
vendor shipping the only production Agent Control Protocol implementation is
NOT ESTABLISHED IN SOURCE.

### Agent Context Protocol — recorded, not documented further

[`agx-dev/acp`](https://github.com/agx-dev/acp): 1 star, Rust, a four-layer
memory model, methods `acp.memory.store`, `acp.memory.recall` and
`acp.version.snapshot`, and a reference implementation that self-exposes as an MCP
server. Its own roadmap leaves the "reference implementation" box unchecked
although the implementation is in the tree.

## What it does

### Agent Communication Protocol — REST, explicitly not JSON-RPC

The specification is an OpenAPI document (`docs/spec/openapi.yaml` in the
[archived repository](https://github.com/i-am-bee/acp)).

| Element | Shape |
| --- | --- |
| Discovery | `GET /agents` |
| Invocation | `POST /runs` |
| Responses | Synchronous, SSE streaming, and an **Await** pause/resume primitive for interactive long-running flows |
| Agent Manifest | name, description, metadata, status — discovery without exposing internals |
| Run | The unit of invocation |
| Message | role plus ordered parts |
| MessagePart | MIME-typed, so any format works without protocol changes |
| Sessions | Statefulness |

The design goals were async-first, streaming, and discovery both online and
offline via metadata baked into the distribution package. It served agent ↔ agent,
agent ↔ application, and agent ↔ human. A2A's design — agent cards, opaque
agents, HTTP plus JSON — is the surviving descendant.

### Agentic Commerce Protocol — HTTPS, JSON, HTTP verbs

Not JSON-RPC. HTTPS plus JSON plus HTTP verbs. Roles: Buyer (human), Agent
(client), Merchant/Seller (the REST server), and PSP/Vault (which serves Delegate
Payment).

**Full REST surface.**

| Surface | Methods | Notes |
| --- | --- | --- |
| Checkout | `POST /checkout_sessions` (201), `GET /checkout_sessions/{id}`, `POST /checkout_sessions/{id}`, `POST /checkout_sessions/{id}/complete`, `POST /checkout_sessions/{id}/cancel` | The five operations that the MCP binding maps to tools |
| Cart (2026-04-17) | `POST /carts`, `GET /carts/{id}`, `PUT /carts/{id}` (full line-item replacement), `POST /carts/{id}/cancel` | Single-seller, no status lifecycle, no payment data, estimated totals; cart → checkout via `cart_id` is deferred |
| Feed | `POST /feeds`, `GET /feeds/{id}`, `GET /feeds/{id}/products`, `PATCH /feeds/{id}/products` | Hosted by the **Agent**, pushed into by merchants — the reverse of UCP. File ingestion via `metadata.json` (`FeedMetadata`) and `products.jsonl` |
| Delegate Payment | `POST /agentic_commerce/delegate_payment` | **OpenAI → PSP**, not to the merchant. Returns vault token `vt_…` |
| Delegate Authentication | 3DS2 Create → Authenticate → Retrieve | Objects `PaymentMethod`, `BrowserInfo`, `AuthenticationResult` (cryptograms, ECI); webhooks for fingerprint, challenge and RReq |

**Delegate Payment request and errors.** The request carries `payment_method`
(`card`, `card_number_type: network_token|fpan`, optional `cryptogram` /
`eci_value`), an `allowance` (`reason: one_time`, `max_amount`, `currency`,
`checkout_session_id`, `merchant_id`, `expires_at`), and `risk_signals[]`. A 201
returns the vault token. Error codes: `invalid_request`, `invalid_card`,
`idempotency_conflict` (409), `rate_limit_exceeded` (429), `processing_error`
(500), `service_unavailable` (503).

**Discovery.** Unauthenticated `GET /.well-known/acp.json` (RFC 8615), with a
recommended `Cache-Control: public, max-age=3600`. The document returns
`DiscoveryProtocol` (name `acp`, current version, `supported_versions` history,
documentation URL), `transports: ["rest","mcp"]`, `api_base_url`, and
`DiscoveryCapabilities` (`services` including `"carts"`, `extensions`,
`intervention_types`, currencies, locales). Enums are closed per API version;
merchant- and session-specific data stays inline on the create request.

**Negotiation.** Inline: the agent sends `capabilities` in
`CheckoutSessionCreateRequest` and the seller returns the **intersection**, so
incompatibility surfaces before payment authorization. The 2026-01-30 **Payment
Handlers framework** (breaking) replaced
`payment_provider.supported_payment_methods` with `capabilities.payment.handlers[]`,
each carrying id, name, version, spec URL, delegation requirements, PCI
information and PSP identity, and moved payment data to
`{handler_id, instrument:{type, credential:{type:"spt", token}}}`. A parallel
**Extensions framework** carries optional features; the first is the **Discount
extension** (`discounts.codes[]`, per-line allocations, rejected codes returned as
`messages[]`).

**Auth and security.** A bearer key in `Authorization`. Required headers:
`Authorization`, `Content-Type: application/json`, `API-Version: YYYY-MM-DD`.
Optional: `Idempotency-Key`, `Request-Id`, `Accept-Language`, `User-Agent`,
`Signature`, `Timestamp`. Sellers "authenticate every request, verify signatures,
enforce idempotency, validate inputs, and support safe retries", and push order
webhooks (`order.created`, `order.updated`). Delegated tokens are single-use,
capped by `max_amount`, bound to a merchant and a checkout session, and expiring.
Version-mismatch errors may carry `supported_versions[]` for programmatic
renegotiation.

**Merchant of record.** Unambiguous and stated identically by
[Stripe](https://docs.stripe.com/agentic-commerce/acp),
[OpenAI](https://developers.openai.com/commerce/guides/key-concepts) and the
[spec site](https://www.agenticcommerce.dev/docs): the **merchant** is merchant of
record, never the agent. "OpenAI is not the merchant of record in the Agentic
Commerce Protocol." Settlement, refunds, chargebacks, tax and compliance stay with
the merchant and its PSP. Agent-to-agent commerce is not in ACP; it is
agent ↔ merchant.

**MCP binding.** ACP does not ride MCP — REST is primary and required. The binding
([`docs/mcp-binding.md`](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/docs/mcp-binding.md),
SEP #135) is additive: same schemas, same semantics, JSON-RPC 2.0 over MCP
Streamable HTTP at a single endpoint (for example `/mcp`), five tools
(`create_checkout_session`, `get_checkout_session`,
`update_checkout_session`, `complete_checkout_session`,
`cancel_checkout_session`), and `{meta, id, payload}` arguments. The spec site
frames ACP as declaring "a common set of interfaces (**think MCP**)" — parallel in
spirit, not built on. The Delegate Payment MCP binding is deferred to a follow-up
SEP.

**Reference implementations.** OpenAI (ChatGPT) and Stripe (Agentic Commerce
Suite), per the repository README.

### Agent Control Protocol — commands into an application UI

Manifest plus a command/result loop over WebSocket, with `set_field`, `click` and
`navigate` commands, 8 actions in total, 15 field types, a 41-test conformance
suite, and a reference server published as `@acprotocol/server`.

## What changed recently

### Agent Communication Protocol

| Date | Event |
| --- | --- |
| 2025-03 | Launched by IBM Research; donated to the Linux Foundation with BeeAI later the same month |
| 2025-08-25 | Merge into A2A announced in [i-am-bee discussion #5](https://github.com/orgs/i-am-bee/discussions/5) by geneknit: development winding down, Blair to the A2A TSC, BeeAI `A2AServer` / `A2AAgent` migration path announced |
| 2025-08-25 | Final commit `e5265ca` |
| 2025-08-27 | Repository archived by the owner, read-only |
| 2025-08-29 | [Linux Foundation for AI & Data merger post](https://lfaidata.foundation/communityblog/2025/08/29/acp-joins-forces-with-a2a-under-the-linux-foundations-lf-ai-data/), co-authored by Kate Blair (IBM) and Todd Segal (Google) |
| 2025-12-09 | AAIF formed; ACP absent, having already merged |
| 2026-08-17 | A2A accepted into AAIF as a Growth Stage project; AAIF restates the ACP merger |
| Undated | `agentcommunicationprotocol.dev` still serves the full specification behind a single banner |

The LF post contains a copy-edit error — "bringing ACP features into ACP" —
which appears verbatim on both the LF blog and the GitHub discussion.

### Agentic Commerce Protocol

| Date | Event |
| --- | --- |
| 2025-09-29 | Launch, with Instant Checkout in ChatGPT |
| 2025-11-21 | Collaboration and Governance Agreement signed; Stripe and OpenAI sign the CLA |
| 2026-01-16 | Capability negotiation release |
| 2026-01-28 | Adyen N.V. signs the CLA (#87) |
| 2026-01-30 | Payment Handlers, Extensions and Discount release — breaking |
| 2026-02-19 | Wix.com Ltd. (#155) and commercetools Inc. (#145) sign the CLA |
| 2026-02-26 | OpenCommerce Network Inc. signs the CLA (#163) |
| 2026-03-09 | Affirm Inc. signs the CLA (#172) |
| 2026-03-19 | **Meta Platforms, Inc. signs the CLA (#185)** and takes TSC seat 3 |
| 2026-03-30 | Agentic Commerce Inc. (Catalog) signs the CLA (#206) |
| 2026-04-16 | **PayPal, Inc. signs the CLA (#210)** |
| 2026-04-17 | Latest stable spec: cart, feed, orders, delegate authentication, discovery, MCP |
| 2026-04-28 | Google donates AP2 to the FIDO Alliance — the competing trust layer reaches a neutral foundation; ACP does not |
| 2026-06-03 | [CLA signatory list](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/legal/cla/SIGNATORIES.md) last updated |
| 2026-07-18 | Last repository commit (SEP #281) |

**Unreleased SEPs pending as of the research date:** #197 suggested pricing
(`suggested_price` on `Item` with `PriceSource` provenance — `feed_id`, `channel`,
`feed_update_id`, `updated_at`, plus a seller-controlled verification window),
#200 fulfillment details on complete, #232 order schema post-checkout alignment,
#260 feed update ID, #281 optional product URL on checkout items, plus the
`intervention_required` error code and error-envelope fixes.

**Deferred:** cart → checkout conversion, promotions, the Delegate Payment MCP
binding, and dedicated auth/authz error types.

### Agent Control Protocol

No dated release record was recoverable. The only date attached to the repository
is the `2026-09-02` value inside its non-standard README annotation. The first
commit date is NOT ESTABLISHED IN SOURCE.

## Evidence of adoption

### Agent Communication Protocol — historical, and ecosystem-bound

At the time of the merger, the reference implementations were the BeeAI Platform
and the BeeAI Framework, both LF-hosted. A DeepLearning.AI short course, "ACP:
Agent Communication Protocol", taught it, and IBM Research published a project
page and blog. The DeepLearning.AI A2A course is now co-built with IBM Research
and teaches A2A. There was no large organisation coalition, no third-party IDE or
cloud support, and no sustained independent implementations.

**Migration adapters.** No ACP → A2A wire-compatibility layer was ever shipped.
IBM shipped adapter shims instead, per
[discussion #5](https://github.com/orgs/i-am-bee/discussions/5) and the
[LF post](https://lfaidata.foundation/communityblog/2025/08/29/acp-joins-forces-with-a2a-under-the-linux-foundations-lf-ai-data/):

| Adapter | Direction | Purpose |
| --- | --- | --- |
| `A2AServer` | BeeAI agent → A2A | Expose a BeeAI agent as an A2A agent |
| `A2AAgent` | A2A → BeeAI | Consume an external A2A agent inside BeeAI |
| Migration guide | — | Documented path; the BeeAI Platform was told to "now use A2A" |

Anything still speaking ACP REST is talking to an archived specification.

### Agentic Commerce Protocol

Launched 2025-09-29 with Instant Checkout in ChatGPT in the US, first for Etsy
sellers and then "coming soon" for 1M+ Shopify merchants. The
[launch press release](https://stripe.com/newsroom/news/stripe-openai-instant-checkout)
names Glossier, Vuori, Spanx and SKIMS.

The hard adoption roster is the
[CLA signatory list](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/blob/main/legal/cla/SIGNATORIES.md)
(last updated 2026-06-03), all under the 2025-11-21 Collaboration and Governance
Agreement:

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

Non-Stripe PSPs and fintechs among the signatories: Adyen, Affirm, PayPal. Whether
Adyen and Affirm have shipped production endpoints is
[UNVERIFIED — a CLA signature is not shipping].

**Concentration.** Production ACP is concentrated on the ChatGPT/Stripe path. The
spec site concedes "Discovery tooling is in progress" and "Each AI platform
manages onboarding"; there is no ACP-wide merchant registry. The Domain Working
Groups named in governance — Travel, Fitness & Wellness, Grocery Delivery,
Donations — have no announced rosters [UNVERIFIED].

**The Shopify counter-signal.** Shopify was ACP's launch partner and is now a
[UCP co-developer](https://ucp.dev/). Its
[ChatGPT channel documentation](https://help.shopify.com/en/manual/online-sales-channels/agentic-storefronts/chatgpt)
now calls that channel a discovery *referrer*: "ChatGPT users complete their
purchase on your online store checkout in a ChatGPT in-app browser… ChatGPT is a
product discovery channel… therefore there's no option to activate or deactivate a
ChatGPT direct checkout setting." It contrasts this with Google AI Mode/Gemini,
Microsoft Copilot and Meta, which do get direct checkout.

**Vendors shipping both.** Stripe co-sponsors ACP and appears on the
[UCP co-developer wall](https://ucp.dev/) alongside Google, Shopify, Etsy, Wayfair,
Target, Walmart, Amazon, Microsoft, Meta and Salesforce. Meta holds ACP TSC seat 3
and is a UCP co-developer. PayPal's
["Agent Ready" for Braintree](https://developer.paypal.com/agent-ready/overview)
advertises both an ACP integration (ChatGPT, delegated tokens via Braintree) and a
UCP integration (Google AI Mode/Gemini via Google Wallet/Google Pay), "to build
once and accept agent-initiated checkouts across multiple AI ecosystems."

No statement from OpenAI, Stripe, Google or Shopify that ACP and UCP converge was
found. ACP's own governance doc anticipates the opposite: "Can TSC members or
contributors also participate in other competing or complementary protocols? A:
Yes. There are no restrictions against working with other protocols."
[UNVERIFIED — searched; no direct vendor convergence statement located.]

### Agent Control Protocol

One reference server, ~7 stars, and a single vendor's product as the only
production implementation [UNVERIFIED]. The identity of that vendor is
NOT ESTABLISHED IN SOURCE.

## Sharp edges

### Agent Communication Protocol

1. **The spec site is live and indexed.** `agentcommunicationprotocol.dev` serves
   the full protocol behind one banner. Search engines and retrieval-augmented
   models keep presenting a dead protocol as current. The repository is correctly
   archived; the documentation is not marked deprecated.
2. **"Merged" is routinely misreported as "still available, contributed to by
   IBM."** The archive flag is the only unambiguous ground truth, and the live
   documentation site actively works against the correct reading.
3. **IBM's own explainer content is stale.** IBM think-topic pages ("What is
   ACP?", "What Are AI Agent Protocols?") still present ACP as a live open standard
   under the Linux Foundation. [UNVERIFIED — partially verified via search
   results; the pages themselves were not fetched.]
4. **No A2A feature trace from ACP is publicly attributable.** The merger post
   said "the first issues aimed at bringing ACP features into A2A are already in
   the A2A GitHub" and a commenter asked for a roadmap; no such roadmap was
   published. A2A v1.0 (March 2026) and v2-style features are not documented as
   ACP-derived. [UNVERIFIED] — the provenance of any A2A feature is not traceable
   from public sources.
5. **No wire compatibility layer.** A peer implementing against the live
   documentation site would build against a dead spec with no migration path
   other than the two BeeAI shims.

### Agentic Commerce Protocol

1. **The documentation site lags the repository.** The
   [site changelog](https://www.agenticcommerce.dev/docs/changelog) stops at
   2026-01-30 and never mentions 2026-04-17, the Carts API, the Feed API,
   `/.well-known/acp.json` or the MCP binding. The repository README still says
   "maintained by OpenAI and Stripe" while `MAINTAINERS.md`, `governance.md` and
   Stripe's documentation say three. Anyone implementing from the spec site builds
   two releases behind.
2. **The MCP binding collapses error semantics.** All ACP errors map to JSON-RPC
   `-32000`; the spec itself calls this "a known tradeoff". Auth failures surface
   as `data.type: "invalid_request"` because dedicated auth error types do not
   exist.
3. **PCI scope creep through MCP proxies.** The spec's own note: a proxy that
   inspects or logs `complete_checkout_session` payloads "may be in PCI scope even
   if they do not store card data."
4. **Docs and binding disagree on MCP support.**
   [OpenAI's checkout spec](https://developers.openai.com/commerce/specs/checkout)
   still says "In the future, the Agentic Checkout Spec will support MCP servers"
   while the repository has shipped the binding. The OpenAI production surface is
   REST-only in the documentation read on the research date.
5. **No agent registry and no discovery tooling.** Reach-out is an email address,
   `acp@stripe.com`.
6. **Carts are half-built.** No lifecycle, no `cart_id` hand-off, estimated
   totals.
7. **The feed direction inversion is a structural liability.** Merchants push
   catalogs into every agent; there is no portable, merchant-owned catalog of
   record across agents in ACP.
8. **Founding Maintainer veto.** OpenAI and Stripe hold a block-only veto over
   SEPs, bounded by four stated principles — a concentration risk for a project
   describing itself as an open standard.
9. **CLA plus Apache-2.0 makes forking non-trivial.**
10. **Motion has slowed.** Latest stable spec 2026-04-17, last commit 2026-07-18,
    Beta badge, no 1.0, no foundation. The competing trust layer, AP2, reached a
    neutral foundation (FIDO) on 2026-04-28.
11. **Adjacent naming noise, excluded deliberately.** IETF individual draft
    [`draft-benzing-accp-00`](https://datatracker.ietf.org/doc/draft-benzing-accp/00)
    is "Agent Context Compression Protocol (**ACCP**)", a different acronym and a
    compression proposal. arXiv 2602.15055 (2026-02-11) proposes a unified ACP for
    federated A2A orchestration — an academic preprint, not a protocol body.

### Agent Control Protocol

1. **The name is a supply-chain hazard.** An attacker or a confused integrator who
   reaches for "ACP" can land on a WebSocket UI-automation protocol with no
   foundation, no standards body and no independent implementation, and treat it
   as interchangeable with the editor protocol of the same name. Its method and
   type names are not a subset of anything else named ACP.
2. **Scale is hobby-scale.** ~7 stars, one reference server, a 41-test conformance
   suite, and a single production implementation of unknown vendor identity.
3. **No dated release record.** The first commit date is NOT ESTABLISHED IN
   SOURCE; the only date in the repository is an annotation value inside a
   non-standard HTML comment.
4. **The name was already taken twice** when it was adopted.

### The four ACPs at a glance

| # | Expansion | Steward | Layer | Wire | Status on 2026-09-29 |
| --- | --- | --- | --- | --- | --- |
| 1 | Agent **Client** Protocol | Zed + JetBrains | Editor ↔ coding agent | JSON-RPC 2.0 over stdio | Active; v1 stable, v2 draft; no foundation |
| 2 | Agent **Communication** Protocol | IBM / BeeAI → A2A | Agent ↔ agent | REST over HTTP | **Dead**; merged 2025-08-25, archived 2025-08-27, spec site still live |
| 3 | **Agentic** Commerce Protocol | OpenAI + Stripe + Meta | Buyer ↔ agent ↔ merchant | REST over HTTPS, optional MCP binding | Active; **Beta**, last stable spec 2026-04-17, last commit 2026-07-18, not donated |
| 4 | Agent **Control** Protocol | `agent-control-protocol` | Agent → application UI commands | WebSocket | Hobby-scale draft, ~7 stars, no governance |
| 5 | Agent **Context** Protocol | `agx-dev` | Agent memory | MCP-exposed methods | Hobby scale, 1 star |

**Any 2026 document that uses bare `ACP` is ambiguous.** The four differ in wire
format, in layer, in steward, and in liveness, and none interoperate: #1 is
JSON-RPC over stdio between an editor and a coding agent, #2 was REST between
agents, #3 is REST between an agent and a merchant, and #4 is a WebSocket command
loop into an application UI. The disambiguating signals available to a reader are
the expansion and the spec host — `agentclientprotocol.com` for #1,
`agentcommunicationprotocol.dev` for #2, `agenticcommerce.dev` for #3, and a
GitHub repository with no spec site for #4. No primary source read on the research
date disambiguates the acronym for a reader, and search results for "ACP" in
agentic contexts return the four subjects mixed. IBM's ACP went to the Linux
Foundation and was superseded by A2A, so three of the four remain nominally live.

## Sources

### Agent Communication Protocol

- <https://github.com/i-am-bee/acp> — archive notice, "Public archive" label, README merge banner
- <https://github.com/orgs/i-am-bee/discussions/5> — pinned 2025-08-25 merge announcement (geneknit), `A2AServer` / `A2AAgent`
- <https://lfaidata.foundation/communityblog/2025/08/29/acp-joins-forces-with-a2a-under-the-linux-foundations-lf-ai-data/> — LF AI & Data merger post, 2025-08-29
- <https://agentcommunicationprotocol.dev/introduction/welcome> — still-live spec site with only a merge banner
- <https://raw.githubusercontent.com/i-am-bee/acp/main/docs/about/mcp-and-a2a.mdx> — ACP's own post-merge advantage list
- <https://raw.githubusercontent.com/i-am-bee/acp/main/docs/about/whats-next.mdx> — future-direction page surviving in an archived repo
- <https://aaif.io/projects> — the six AAIF projects; no ACP
- <https://aaif.io/blog/a2a-joins-aaif> — 2026-08-17 A2A joins AAIF; explicit "IBM's ACP merged into A2A"
- <https://a2a-protocol.org/latest/blog/2026/08/27/a-new-chapter-for-a2a-joining-the-agentic-ai-foundation/> — 150+ organisations; BeeAI among framework adopters
- <https://github.com/a2aproject/A2A> — A2A Apache-2.0, 26k stars, HTTP+JSON-RPC, Agent Cards
- <https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation> — AAIF formed 2025-12-09
- <https://www.ibm.com/think/topics/agent-communication-protocol> — IBM explainer, stale [UNVERIFIED]

### Agentic Commerce Protocol

- <https://github.com/agentic-commerce-protocol/agentic-commerce-protocol> — repo, licence, stars, Status: Beta
- <https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/MAINTAINERS.md> — OpenAI, Stripe, Meta
- <https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/docs/governance.md> — TSC, DWGs, SEP process, Founding Maintainer veto
- <https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/docs/mcp-binding.md> — SEP #135 binding
- <https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/changelog/2026-04-17.md> — latest stable release notes
- <https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/changelog/unreleased/add-meta-tsc-member.md> — Meta's TSC seat
- <https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/legal/cla/SIGNATORIES.md> — signatory roster
- <https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/LICENSE> — Apache 2.0
- <https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/commits/main> — last commit 2026-07-18
- <https://github.com/agentic-commerce-protocol/agentic-commerce-protocol/tree/main/changelog/unreleased> — pending SEPs
- <https://www.agenticcommerce.dev/docs> — spec site intro
- <https://www.agenticcommerce.dev/llms.txt> — machine-readable ACP summary
- <https://www.agenticcommerce.dev/docs/changelog> — stale site changelog, stops 2026-01-30
- <https://www.agenticcommerce.dev/docs/reference/checkout> — full REST reference
- <https://developers.openai.com/commerce/guides/key-concepts> — merchant-of-record statement
- <https://developers.openai.com/commerce/specs/checkout> — OpenAI checkout spec, headers, webhooks
- <https://developers.openai.com/commerce/specs/payment> — Delegate Payment, Allowance, RiskSignal
- <https://docs.stripe.com/agentic-commerce/acp> — "created by Stripe, OpenAI, and Meta"
- <https://stripe.com/blog/developing-an-open-standard-for-agentic-commerce> — launch post, 2025-09-29
- <https://stripe.com/newsroom/news/stripe-openai-instant-checkout> — launch press release
- <https://help.shopify.com/en/manual/online-sales-channels/agentic-storefronts/chatgpt> — Shopify's discovery-referrer position
- <https://ucp.dev/> — UCP co-developer wall
- <https://ucp.dev/documentation/ucp-and-ap2/> — UCP ↔ AP2 flow
- <https://ap2-protocol.org/> — AP2 mandates and credentials
- <https://blog.google/products-and-platforms/platforms/google-pay/agent-payments-protocol-fido-alliance/> — AP2 to FIDO, 2026-04-28
- <https://developer.paypal.com/agent-ready/overview> — both ACP and UCP in one product

### Agent Control Protocol and adjacent names

- <https://github.com/agent-control-protocol/acp> — draft v2.0, manifest, WebSocket, 8 actions, 15 field types, 41-test conformance, `@acprotocol/server`
- <https://github.com/agx-dev/acp> — Agent Context Protocol, 1 star
- <https://datatracker.ietf.org/doc/draft-benzing-accp/00> — IETF ACCP, different acronym, excluded
- <https://arxiv.org/abs/2602.15055> — academic unified-ACP proposal, not a protocol body
