# Commerce protocols — UCP, Agentic Commerce Protocol, AP2, x402

Verbatim wire values for the four commerce protocols, transcribed from each
project's own machine-readable artifact — generated JSON Schemas, OpenAPI and
OpenRPC documents, and the published specification text. These four protocols
are strictly separate namespaces with no shared wire values and no cross-wiring;
each is its own section below and nothing is merged across them. Where a row
could not be established from a primary source it reads `NOT ESTABLISHED IN
SOURCE`. Where two primary sources disagree, both values appear with a note.

- Research date: 2026-09-29
- Contract: [`../../PROTOCOLS.md`](../../PROTOCOLS.md) — the normative wire values
- Evidence: this file, transcribed from the artifacts named per section

## Artifact provenance

### UCP — Universal Commerce Protocol, release `2026-08-25`

| Artifact | URL | What it established |
| --- | --- | --- |
| Overview | `https://ucp.dev/2026-08-25/specification/overview/` (repo file `docs/specification/overview/index.md`) | Namespace convention, governance table, reserved member `ucp`, date and amount formats, `UCP-Agent` RFC 8941 rule, transport enum, other reverse-DNS strings, OAuth scope strings |
| Reference | `https://ucp.dev/2026-08-25/specification/reference/` (generated from `docs/specification/reference.md`) | `reverse_domain_name` and `version` patterns |
| Schemas | `https://ucp.dev/2026-08-25/schemas/…` (repo `source/schemas/…`) | The `name` and `version` keys of every shipped capability; `ucp.json` profile shape and `status` enum; `service.json` transport enum and per-branch required sets |
| Shopping REST | `https://ucp.dev/2026-08-25/services/shopping/rest.openapi.json` | `info.title` = "UCP Shopping Service", `info.version` = `2026-08-25`, OpenAPI `3.1.0`; the 13 pathed operations plus the webhook; `components.parameters.ucp_agent`; every request and response header |
| Common REST | `https://ucp.dev/2026-08-25/services/common/rest.openapi.json` | The two location operations |
| MCP bindings | `https://ucp.dev/2026-08-25/services/shopping/mcp.openrpc.json`, `…/services/common/mcp.openrpc.json` | The MCP method names per service |
| Extension pages | `https://ucp.dev/2026-08-25/specification/shopping/extensions/…`, `…/common/extensions/…`, `…/payment/extensions/…` | Extension identifiers, `version`, `extends`, `spec` path, `schema` URL |
| Draft-only lodging | `https://raw.githubusercontent.com/Universal-Commerce-Protocol/ucp/main/docs/specification/lodging/booking/index.md`, `…/lodging/extensions/cancellation-policy.md` | `dev.ucp.lodging.booking` and `dev.ucp.lodging.policy.cancellation` — `[UNVERIFIED — single-sourced]`, `main` only |

Negative evidence for `dev.ucp.lodging.*` in release `2026-08-25`, three
independent release-pinned sources, all empty:
`https://ucp.dev/2026-08-25/llms-full.txt` (no `dev.ucp.lodging.`, no `lodging`,
no `Booking`); `https://ucp.dev/2026-08-25/specification/reference/` (generated
with `base_dir='source/schemas/lodging'` — no `lodging` match);
`https://ucp.dev/2026-08-25/specification/lodging/booking/` returns HTTP 404. The
same corpus does contain the checkout page, the identity-linking page, the
location pages, and AP2-mandate/split-payments/buyer-consent content, so the
absence is a real negative for the release.

### Agentic Commerce Protocol — spec `2026-04-17`

| Artifact | URL | What it established |
| --- | --- | --- |
| Checkout OpenAPI | `https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/spec/2026-04-17/openapi/openapi.agentic_checkout.yaml` | `openapi: 3.1.0`, `info.version: "2026-04-17"`, `servers: https://merchant.example.com`, `security: bearerAuth`; the five checkout operations; every request and response header; `PaymentData`, `instrument`, `PaymentHandler`; `Error.type` enum |
| Delegate payment OpenAPI | `…/spec/2026-04-17/openapi/openapi.delegate_payment.yaml` | `POST /agentic_commerce/delegate_payment` |
| JSON Schema | `…/spec/2026-04-17/json-schema/schema.agentic_checkout.json` | `$defs.DiscoveryResponse` and every discovery field; `MessageError.code`, `MessageWarning.code`, `severity`, `resolution`, `content_type`; the `InterventionCapabilities` enums |
| RFC | `…/main/rfcs/rfc.agentic_checkout.md` §6 | The `Idempotency-Key` and `Request-Id` rules |
| Payment Handlers RFC | `…/main/rfcs/rfc.payment_handlers.md` (Version: 2026-01-22) §5.2 | The richer `instrument` shape, `PaymentHandler` field notes, credential sub-schema URLs |
| MCP binding OpenRPC | `…/spec/2026-04-17/openrpc/openrpc.agentic_checkout.json` | `openrpc: 1.3.2`, `info.version: "2026-04-17"`, title "ACP Agentic Checkout — MCP Binding"; the five tools and their `payload`/`result` refs |
| MCP binding prose | `…/main/docs/mcp-binding.md` (SEP #135) | Argument shape `{meta, id, payload}`; the `meta` field to header map; the JSON-RPC error code rules |
| Changelog | `…/main/changelog/2026-04-17.md` | Feed API and Cart API paths `[UNVERIFIED]`; removal of `request_not_idempotent` |
| Webhooks doc | `https://www.agenticcommerce.dev/docs/reference/webhooks` | `POST /agentic_checkout/webhooks/order_events`; `Merchant-Signature` HMAC |
| Checkout doc | `https://www.agenticcommerce.dev/docs/reference/checkout` | Header required/optional cross-check |

### AP2 — v0.2

| Artifact | URL | What it established |
| --- | --- | --- |
| Specification | `https://ap2-protocol.org/ap2/specification/` (repo file `docs/ap2/specification.md`) | The five roles and their agentic classification; the two modes; the `cnf` requirement on open mandates; the signature-algorithm and salt requirements |
| Mandate schemas | `…/AP2/main/code/sdk/schemas/ap2/checkout_mandate.json`, `open_checkout_mandate.json`, `payment_mandate.json`, `open_payment_mandate.json` | Every `vct` const, every property, every `required` set, the constraint type names |
| Receipt schemas | `…/code/sdk/schemas/ap2/checkout_receipt.json`, `payment_receipt.json`, `types/receipt_status.json` | Receipt field lists, the `oneOf` branches, the `Success`/`Error` status enum |
| Mandate prose | `…/docs/ap2/checkout_mandate.md`, `…/docs/ap2/payment_mandate.md` | `cnf` and `sd_hash` rules; the observed `{"cnf":{"jwk":{…}}}` shape |
| Agent authorization | `…/docs/ap2/agent_authorization.md` | The OpenID4VP `transaction_data` object; the generic Mandate Receipt; the non-normative Authorization Request example |
| Security | `…/docs/ap2/security_and_privacy_considerations.md` | The `cnf` mitigation; SD-JWT digest salt; decoy digests |
| Flows | `…/docs/ap2/flows.md` | The `direct` flow label; the `unresolved_constraint` fallback |
| Implementation notes | `…/docs/ap2/implementation_considerations.md` | Hash-algorithm consistency between SD-JWT digests and `checkout_hash` |

### x402 — v1

| Artifact | URL | What it established |
| --- | --- | --- |
| Specification | `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md` | `**Protocol Version**: 1`; `x402Version`; `PaymentRequirementsResponse`, `PaymentRequirements`, `PaymentPayload`, `SchemePayload`, `Authorization`, `SettlementResponse`; the EIP-712 types; the facilitator endpoints; Bazaar discovery; error codes; supported networks |
| HTTP-402 doc | `https://docs.x402.org/core-concepts/http-402` | `PAYMENT-REQUIRED`, `PAYMENT-SIGNATURE`, `PAYMENT-RESPONSE` (v2-era; conflicts with the v1 spec) |
| Facilitator doc | `https://docs.x402.org/core-concepts/facilitator`, `…/core-concepts/client-server.md` | Header direction per header; "x402 V2 uses three standardized headers for payment communication" |
| Bazaar doc | `https://docs.x402.org/extensions/bazaar.md` | `EXTENSION-RESPONSES`; the v2 resource-entry shape (conflicts with the v1 spec) |

## UCP

Release `2026-08-25`. Every value below is release-pinned.

### Namespace format

Source: `https://ucp.dev/2026-08-25/specification/overview/` — file `docs/specification/overview/index.md`; `https://raw.githubusercontent.com/Universal-Commerce-Protocol/ucp/main/mkdocs.yml`, file `docs/specification/overview/index.md`

| Element | Verbatim value |
| --- | --- |
| Naming convention (MUST) | `[reverse-domain].{service}.{capability}` |
| Governance table | `dev.ucp.*` → authority `ucp.dev` → "UCP governing body"; `com.{vendor}.*` → `{vendor}.com` → "Vendor organization"; `org.{org}.*` → `{org}.org` → "Organization" |
| `reverse_domain_name` pattern (schema) | `^[a-z](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9_-]*[a-z0-9_])?)+$` |
| `version` pattern | `^\d{4}-\d{2}-\d{2}$` |
| Reserved member name | `ucp` (protocol namespace; "reserved as the **protocol namespace** in every structured UCP object scope") |
| Schema notes | "Date format: Always specified as RFC 3339"; "Amounts format: Minor units (cents)" |

Source: `https://ucp.dev/2026-08-25/specification/reference/` — generated from `docs/specification/reference.md`

### Shipped capability identifiers

Source: each schema below is `https://ucp.dev/2026-08-25/schemas/…`; values taken verbatim from that file's `name` and `version` keys. Repo path `source/schemas/…` in `Universal-Commerce-Protocol/ucp`

| Capability identifier | `name` (schema) | `version` | Schema URL |
| --- | --- | --- | --- |
| `dev.ucp.shopping.checkout` | `dev.ucp.shopping.checkout` | `2026-08-25` | `/schemas/shopping/checkout.json` |
| `dev.ucp.shopping.cart` | `dev.ucp.shopping.cart` | `2026-08-25` | `/schemas/shopping/cart.json` |
| `dev.ucp.shopping.order` | `dev.ucp.shopping.order` | `2026-08-25` | `/schemas/shopping/order.json` |
| `dev.ucp.shopping.catalog.search` | `dev.ucp.shopping.catalog.search` | `2026-08-25` | `/schemas/shopping/catalog_search.json` |
| `dev.ucp.shopping.catalog.lookup` | `dev.ucp.shopping.catalog.lookup` | `2026-08-25` | `/schemas/shopping/catalog_lookup.json` |
| `dev.ucp.shopping.permalink` | `dev.ucp.shopping.permalink` | `2026-08-25` | `/schemas/shopping/permalink.json` |
| `dev.ucp.common.identity_linking` | `dev.ucp.common.identity_linking` | `2026-08-25` | `/schemas/common/identity_linking.json` |
| `dev.ucp.common.location.search` | `dev.ucp.common.location.search` | `2026-08-25` | `/schemas/common/location_search.json` |
| `dev.ucp.common.location.lookup` | `dev.ucp.common.location.lookup` | `2026-08-25` | `/schemas/common/location_lookup.json` |
| `dev.ucp.lodging.*` (any) | NOT ESTABLISHED IN SOURCE for release `2026-08-25` | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE |

Draft-only lodging identifiers, `main` and not the release. `[UNVERIFIED — single-sourced]`.
Source: `https://raw.githubusercontent.com/Universal-Commerce-Protocol/ucp/main/docs/specification/lodging/booking/index.md` and `…/docs/specification/lodging/extensions/cancellation-policy.md`

| Identifier | Kind | `extends` | Schema (draft template) |
| --- | --- | --- | --- |
| `dev.ucp.lodging.booking` | capability | — | NOT ESTABLISHED IN SOURCE (page declares only "**Capability Name:** `dev.ucp.lodging.booking`" and `version: "{{ ucp_version }}"`) |
| `dev.ucp.lodging.policy.cancellation` | extension | `["dev.ucp.lodging.booking"]` | `https://ucp.dev/{{ ucp_version }}/schemas/lodging/policy_cancellation.json` |

### Extension identifiers

Source: `https://ucp.dev/2026-08-25/specification/…` pages, each business-profile example; plus `https://ucp.dev/2026-08-25/specification/overview/`

| Extension identifier | `version` | `extends` | `spec` path | `schema` URL |
| --- | --- | --- | --- | --- |
| `dev.ucp.shopping.fulfillment` | `2026-08-25` | `"dev.ucp.shopping.checkout"` | `/specification/shopping/extensions/fulfillment` | `/schemas/shopping/fulfillment.json` |
| `dev.ucp.shopping.discount` | `2026-08-25` | `["dev.ucp.shopping.checkout","dev.ucp.shopping.cart"]` (multi-parent example) / `"dev.ucp.shopping.checkout"` (profile example) | `/specification/shopping/extensions/discount` | `/schemas/shopping/discount.json` |
| `dev.ucp.shopping.buyer_consent` | `2026-08-25` | `["dev.ucp.shopping.cart","dev.ucp.shopping.checkout"]` | `/specification/shopping/extensions/buyer-consent` | `/schemas/shopping/buyer_consent.json` |
| `dev.ucp.common.loyalty` | `2026-08-25` | `["dev.ucp.shopping.catalog.search","dev.ucp.shopping.catalog.lookup","dev.ucp.shopping.cart","dev.ucp.shopping.checkout"]` | `/specification/common/extensions/loyalty` | `/schemas/common/loyalty.json` |
| `dev.ucp.common.payment.ap2_mandate` | `2026-08-25` | `"dev.ucp.shopping.checkout"` | `/specification/payment/extensions/ap2-mandates` | `/schemas/common/payment_ap2_mandate.json` |
| `dev.ucp.common.payment.authentication` | `2026-08-25` | `"dev.ucp.shopping.checkout"` | `/specification/payment/extensions/authentication` | `/schemas/common/payment_authentication.json` |
| `dev.ucp.common.payment.terms` | `2026-08-25` | `["dev.ucp.shopping.checkout","dev.ucp.shopping.order"]` | `/specification/payment/extensions/terms` | `/schemas/common/payment_terms.json` |
| `dev.ucp.common.payment.split_payments` | `2026-01-23` (only value present on its spec page) | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE | NOT ESTABLISHED IN SOURCE |

Action sub-identifiers under `dev.ucp.common.payment.authentication`. Source: `https://ucp.dev/2026-08-25/specification/payment/extensions/authentication/`

| Action identifier | Verbatim description |
| --- | --- |
| `dev.ucp.common.payment.device_data_collection` | "Run an invisible browser-capable device data collection surface." |
| `dev.ucp.common.payment.three_ds_challenge` | "Present a buyer-facing 3DS challenge surface." |

**CONFLICT (UCP, version):** every other UCP-authored entity in release
`2026-08-25` declares `"version": "2026-08-25"`; the Split Payments page declares
`"version": "2026-01-23"`. Both values are quoted verbatim above; the release
spec states "UCP-authored `dev.ucp.*` capabilities and extensions are versioned in
lockstep with the specification: each declares the date `D` of the UCP release it
ships in."

Other well-known reverse-DNS strings, not capabilities. Source: `https://ucp.dev/2026-08-25/specification/overview/` and `/specification/reference/`

| String | Kind |
| --- | --- |
| `dev.ucp.shopping.policy.return` | policy identifier |
| `dev.ucp.shopping.policy.warranty` | policy identifier |
| `dev.ucp.buyer_ip` | well-known name |
| `dev.ucp.user_agent` | well-known name |
| `dev.ucp.consent.marketing` | consent purpose |
| `dev.ucp.consent.marketing.email` | consent purpose |
| `dev.ucp.consent.marketing.sms` | consent purpose |
| `dev.ucp.consent.analytics` | consent purpose |
| `dev.ucp.consent.preferences` | consent purpose |
| `dev.ucp.consent.sale_or_sharing` | consent purpose |
| `dev.ucp.shopping.order:read` | OAuth scope, form `{capability}:{scope}` |
| `dev.ucp.shopping.order:manage` | OAuth scope |
| `dev.ucp.shopping.checkout:manage` | OAuth scope |

### `/.well-known/ucp` profile shape

Source: `https://ucp.dev/2026-08-25/schemas/ucp.json` (`$id` = that URL) `$defs.business_schema` / `$defs.platform_schema` / `$defs.base` / `$defs.entity`

| Path | Type | Required | Notes (verbatim where quoted) |
| --- | --- | --- | --- |
| `ucp` | object | **Required** | root member; top-level `keys[]` is the canonical JWK Set array (RFC 7517) |
| `ucp.version` | string `^\d{4}-\d{2}-\d{2}$` | **Required** | |
| `ucp.status` | string, enum `success` \| `error`, default `success` | in response branches | |
| `ucp.services` | object keyed by `reverse_domain_name` → array of service objects | **Required** | "The `services` and `payment_handlers` registries **MUST** be present even when empty." |
| `ucp.capabilities` | object keyed by `reverse_domain_name` → array of capability objects | Optional | "optional and **MAY** be omitted" |
| `ucp.payment_handlers` | object keyed by `reverse_domain_name` → array | **Required** | |
| `ucp.map_order` | object of arrays | Optional | `ucp_request: omit` |
| `ucp.request_constraints` | `$ref …/common/types/request_constraints.json` | Optional | `ucp_request: omit` |
| `ucp.supported_versions` | object; keys `version`, values uri | business only, optional | "When omitted, only `version` is supported." |
| `keys` (top level) | array | Optional | JWK Set; kty `EC` (P-256, P-384) and `OKP` (Ed25519) are the two UCP-defined key types |

`ucp.status` enum, written out: `success`, `error`.

Entity object (`$defs.entity`): `required: ["version"]`; optional `spec` (uri),
`schema` (uri), `id` (string), `config` (object, `additionalProperties: true`).
Capability object adds `extends` — `OneOf[string, array]`, "Present for
extensions, absent for root capabilities."

Service object. Source: `https://ucp.dev/2026-08-25/schemas/service.json`

| Condition | Additional required members |
| --- | --- |
| always | `transport` |
| `platform_schema` | `spec`; and `schema` for `rest`, `mcp`, `embedded` (not for `a2a`) |
| `business_schema` | `endpoint` for `rest`, `mcp`, `a2a`; `embedded` in business_schema carries `config` → `/schemas/transports/embedded_config.json` |

### `UCP-Agent` header

Source: `https://ucp.dev/2026-08-25/services/shopping/rest.openapi.json` → `components.parameters.ucp_agent`

| Property | Value |
| --- | --- |
| Header name | `UCP-Agent` |
| `in` | `header` |
| `required` | `true` |
| `schema.type` | `string` |
| Description (verbatim) | "Identifies the UCP agent making the call. All requests MUST include the UCP-Agent header containing the signer's profile URI using RFC 8941 Dictionary syntax. The URL MUST point to /.well-known/ucp. Format: profile=\"https://example.com/.well-known/ucp\"." |

Source: `https://ucp.dev/2026-08-25/specification/overview/` (section "Platform Advertisement on Request")

| Transport | Rule (verbatim) |
| --- | --- |
| HTTP | "**HTTP Transport:** Platforms **MUST** use Dictionary Structured Field syntax ([RFC 8941](https://datatracker.ietf.org/doc/html/rfc8941)) in the UCP-Agent header" |
| HTTP example | `UCP-Agent: profile="https://agent.example/profiles/shopping-agent.json"` |
| MCP | "Platforms **MUST** include a `meta` object containing request metadata" — `arguments.meta["ucp-agent"] = {"profile": "https://agent.example/profiles/shopping-agent.json"}` under `tools/call` / `create_checkout` |
| Related header (optional layer) | `Signature-Agent: sig1="https://platform.example/.well-known/ucp";type=jwks_uri` |

**ABNF: NOT ESTABLISHED IN SOURCE.** No ABNF production exists in the UCP
specification — the only normative form given is "RFC 8941 Dictionary syntax".

**CONFLICT (UCP, `UCP-Agent` URL constraint):** the OpenAPI parameter says the
profile URL "MUST point to /.well-known/ucp"; the overview's own example uses
`https://agent.example/profiles/shopping-agent.json`, and the
identity-linking/location examples use
`https://platform.example/profiles/v2026-01/agent.json`.

### Transport binding identifiers

Source: `https://ucp.dev/2026-08-25/schemas/service.json` (`transport` enum) and `https://ucp.dev/2026-08-25/specification/overview/`

| `transport` value | Artifact per binding | Note (verbatim where quoted) |
| --- | --- | --- |
| `rest` | OpenAPI 3.x (JSON) | |
| `mcp` | OpenRPC (JSON) | |
| `a2a` | Agent Card Specification | "`endpoint` for A2A transport refers to the Agent Card URL for the agent." |
| `embedded` | OpenRPC (JSON) | written "EP(embedded)" in the overview's artifact table |

Enum, verbatim: "**Enum:** `rest`, `mcp`, `a2a`, `embedded`".

### Shopping REST operations

Source: `https://ucp.dev/2026-08-25/services/shopping/rest.openapi.json` (`info.title` = "UCP Shopping Service", `info.version` = `2026-08-25`, OpenAPI `3.1.0`)

| # | Method | Path | `operationId` | Success |
| --- | --- | --- | --- | --- |
| 1 | POST | `/checkout-sessions` | `create_checkout` | 201 |
| 2 | GET | `/checkout-sessions/{id}` | `get_checkout` | 200 |
| 3 | PUT | `/checkout-sessions/{id}` | `update_checkout` | 200 |
| 4 | POST | `/checkout-sessions/{id}/complete` | `complete_checkout` | 200 |
| 5 | POST | `/checkout-sessions/{id}/cancel` | `cancel_checkout` | 200 |
| 6 | POST | `/carts` | `create_cart` | 201 |
| 7 | GET | `/carts/{id}` | `get_cart` | 200 |
| 8 | PUT | `/carts/{id}` | `update_cart` | 200 |
| 9 | POST | `/carts/{id}/cancel` | `cancel_cart` | 200 |
| 10 | POST | `/catalog/search` | `search_catalog` | 200 |
| 11 | POST | `/catalog/lookup` | `lookup_catalog` | 200 |
| 12 | POST | `/catalog/product` | `get_product` | 200 |
| 13 | GET | `/orders/{id}` | `get_order` | 200 |
| 14 | POST | (webhook `orderEvent`, platform-registered URL — no path in this document) | `order_event_webhook` | 200 |

Thirteen operations carry a path; the fourteenth, `order_event_webhook`, has no
path in this document.

### Location operations

Source: `https://ucp.dev/2026-08-25/services/common/rest.openapi.json`

| Method | Path | `operationId` |
| --- | --- | --- |
| POST | `/locations/search` | `search_locations` |
| POST | `/locations/lookup` | `lookup_locations` |

### Shopping MCP method names

Source: `https://ucp.dev/2026-08-25/services/shopping/mcp.openrpc.json` and `…/services/common/mcp.openrpc.json`

| MCP method | Service |
| --- | --- |
| `create_checkout` | `dev.ucp.shopping` |
| `get_checkout` | `dev.ucp.shopping` |
| `update_checkout` | `dev.ucp.shopping` |
| `complete_checkout` | `dev.ucp.shopping` |
| `cancel_checkout` | `dev.ucp.shopping` |
| `create_cart` | `dev.ucp.shopping` |
| `get_cart` | `dev.ucp.shopping` |
| `update_cart` | `dev.ucp.shopping` |
| `cancel_cart` | `dev.ucp.shopping` |
| `search_catalog` | `dev.ucp.shopping` |
| `lookup_catalog` | `dev.ucp.shopping` |
| `get_product` | `dev.ucp.shopping` |
| `get_order` | `dev.ucp.shopping` |
| `search_locations` | `dev.ucp.common` |
| `lookup_locations` | `dev.ucp.common` |

Service registry keys observed in release profiles: `dev.ucp.shopping`,
`dev.ucp.common`. `dev.ucp.lodging` — NOT ESTABLISHED IN SOURCE for this release.

### Header names in the shopping REST binding

Source: `https://ucp.dev/2026-08-25/services/shopping/rest.openapi.json` → `components.parameters` / `components.headers`

| Header | Direction | Required | Type / format | Note |
| --- | --- | --- | --- | --- |
| `UCP-Agent` | request | **true** | `string` | RFC 8941 dictionary, see above |
| `Authorization` | request | Optional | | |
| `X-API-Key` | request | Optional | | |
| `Signature` | request and response | Optional | | "RFC 9421 HTTP Message Signature… Format: `sig1=:<base64-signature>:`" |
| `Signature-Input` | request and response | Optional | | `sig1=("@method" "@authority" "@path" "ucp-agent" "idempotency-key" "content-digest" "content-type");keyid="platform-2026"` |
| `Content-Digest` | request and response | Optional | | `sha-256=:<base64-digest>:` |
| `Idempotency-Key` | request | **true** | `string`, `format: uuid` | |
| `Request-Id` | request | **true** | `string`, `format: uuid` | |
| `User-Agent` | request | | | |
| `Content-Type` | request | | | |
| `Accept` | request | | | |
| `Accept-Language` | request | | | |
| `Accept-Encoding` | request | | | |
| `Webhook-Timestamp` | request, webhook only | **true** | `integer` | |
| `Webhook-Id` | request, webhook only | **true** | `string`, `format: uuid` | |

Response headers only: `Signature`, `Signature-Input`, `Content-Digest`.

## Agentic Commerce Protocol

Spec `2026-04-17`. Distinct from the Agent Client Protocol, which is a different
protocol in a different file.

### Endpoints

Source: `https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/spec/2026-04-17/openapi/openapi.agentic_checkout.yaml` (`openapi: 3.1.0`, `info.version: "2026-04-17"`, `servers: https://merchant.example.com`, `security: bearerAuth`)

| Method | Path | `operationId` | Success |
| --- | --- | --- | --- |
| POST | `/checkout_sessions` | `createCheckoutSession` | 201 |
| POST | `/checkout_sessions/{checkout_session_id}` | `updateCheckoutSession` | 200 |
| GET | `/checkout_sessions/{checkout_session_id}` | `getCheckoutSession` | 200 (404 if absent) |
| POST | `/checkout_sessions/{checkout_session_id}/complete` | `completeCheckoutSession` | 200 |
| POST | `/checkout_sessions/{checkout_session_id}/cancel` | `cancelCheckoutSession` | 200 (405 if already completed/canceled) |

Source: `https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/spec/2026-04-17/openapi/openapi.delegate_payment.yaml`

| Method | Path | `operationId` |
| --- | --- | --- |
| POST | `/agentic_commerce/delegate_payment` | `delegatePayment` |

Feed API, added in this release. Source: `changelog/2026-04-17.md`. No OpenAPI
file was located in `spec/2026-04-17/openapi/`. `[UNVERIFIED]`

| Method | Path |
| --- | --- |
| POST | `/feeds` |
| GET | `/feeds/{id}` |
| GET | `/feeds/{id}/products` |
| PATCH | `/feeds/{id}/products` |

Cart API. Source: `changelog/2026-04-17.md`; `openapi.cart.yaml` referenced as
new, path and method verbatim. No `spec/2026-04-17/openapi/openapi.cart.yaml` was
fetchable. `[UNVERIFIED]`

| Method | Path |
| --- | --- |
| POST | `/carts` |
| GET | `/carts/{id}` |
| PUT | `/carts/{id}` |
| POST | `/carts/{id}/cancel` |

Webhook receiver, hosted by OpenAI. Source: `https://www.agenticcommerce.dev/docs/reference/webhooks`

| Method | Path |
| --- | --- |
| POST | `/agentic_checkout/webhooks/order_events` |

### Request and response headers

Source: `openapi.agentic_checkout.yaml` → `components.parameters` (and the path-level parameter blocks)

| Header | `in` | Required | Schema / example | Description (verbatim where quoted) |
| --- | --- | --- | --- | --- |
| `Authorization` | header | **true** | `string`, ex `Bearer api_key_123` | "Bearer token for API authentication" |
| `Content-Type` | header | **true** | `string`, ex `application/json` | — |
| `API-Version` | header | **true** | `string`, ex `"2026-01-16"` | — |
| `Idempotency-Key` | header | **true** | `string`, `minLength: 1`, `maxLength: 255`, ex `550e8400-e29b-41d4-a716-446655440000` | "Idempotency key. MUST be present on all POST requests. Opaque string, max 255 characters. UUID v4 recommended. Scoped to authenticated identity + endpoint." |
| `Request-Id` | header | false | `string`, ex `request_id_123` | — |
| `Signature` | header | false | `string`, ex `ZXltZX...` | "HMAC signature for webhook verification" |
| `Timestamp` | header | false | `string`, `format: date-time`, ex `"2026-04-17T10:30:00Z"` | "RFC 3339 date-time string for request timing validation" |
| `Accept-Language` | header | false | `string`, ex `en-US` | — |
| `User-Agent` | header | false | `string`, ex `ChatGPT/2.0 (Mac OS X 15.0.1; arm64; build 0)` | — |

Per-operation header sets are explicit: `GET /checkout_sessions/{id}` carries no
`Content-Type` and no `Idempotency-Key`; `POST …/{id}` adds only
`Idempotency-Key`; `POST /checkout_sessions`, `…/complete`, `…/cancel` carry all
of the above.

Response headers. Source: `openapi.agentic_checkout.yaml` → `responses.201/200.headers`

| Header | Required | Type | Description (verbatim) |
| --- | --- | --- | --- |
| `Idempotency-Key` | **true** | | "Echo of the request idempotency key" |
| `Idempotent-Replayed` | Optional | `string`, `enum: ["true"]` | "true when the response is a cached replay of a previous request with the same Idempotency-Key" |
| `Request-Id` | **true** | | "Echo of the request correlation id" |
| `Retry-After` | **true**, on error response `IdempotencyInFlight` only | `integer` | |

Docs cross-check. Source: `https://www.agenticcommerce.dev/docs/reference/checkout`

| Flag | Headers |
| --- | --- |
| Required | `Authorization`, `Content-Type`, `API-Version` (format `YYYY-MM-DD`, e.g. `2026-01-30`) |
| Optional | `Idempotency-Key`, `Request-Id`, `Accept-Language`, `User-Agent`, `Signature`, `Timestamp` |
| Response | `Idempotency-Key`, `Request-Id` |

The docs list the `API-Version` example `2026-01-30` while the OpenAPI example is
`2026-01-16`; the release version is `2026-04-17`.

### Discovery document

Source: `https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/spec/2026-04-17/json-schema/schema.agentic_checkout.json` (`$defs.DiscoveryResponse` etc.) and `changelog/2026-04-17.md`

| Field | Type | Required | Verbatim description / value |
| --- | --- | --- | --- |
| path | — | — | `/.well-known/acp.json` ("served at the origin root per RFC 8615") |
| `protocol` | `DiscoveryProtocol` | **Required** | |
| `api_base_url` | `string` (uri) | **Required** | "Base URL for the ACP REST API. Agents append resource paths to this URL (e.g., {api_base_url}/checkout_sessions)." |
| `transports` | array of string | **Required** | advertises transport bindings; enum `rest`, `mcp`; example `["rest"]` |
| `capabilities` | `DiscoveryCapabilities` | **Required** | |
| `protocol.name` | string | **Required** | const `acp` |
| `protocol.version` | string | **Required** | `"2026-04-17"` |
| `protocol.supported_versions` | array of string | **Required** | `["2025-09-29", "2026-01-30", "2026-04-17"]` (chronological) |
| `protocol.documentation_url` | string | optional | `"https://agenticcommerce.dev"` |
| `capabilities.services` | array of string | **Required** | example `["checkout", "orders", "delegate_payment", "carts"]`; closed enum per API version |
| `capabilities.extensions` | array of `DiscoveryExtension` | optional | `{"name","spec","schema"}` — "does not include session-level details like schema or extends fields" |
| `capabilities.intervention_types` | array of string | optional | example `["3ds"]` |
| `capabilities.supported_currencies` | array | optional | example `["usd","eur"]` |
| `capabilities.supported_locales` | array | optional | example `["en-US"]` |

Response caching: "Responses SHOULD include `Cache-Control: public, max-age=3600`
as a recommended minimum." "No authentication required".

### `Idempotency-Key` and `Request-Id` rules

Source: `https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/rfcs/rfc.agentic_checkout.md` §6

| Rule | Verbatim |
| --- | --- |
| Requirement | "Clients **MUST** include an `Idempotency-Key` header on **every POST** request (create, update, complete, cancel)." |
| Key shape | "The key is an **opaque string**, max **255 characters**; UUID v4 is **RECOMMENDED**." |
| Scoping | "Servers **MUST** scope keys to the **authenticated identity + endpoint path**; the same key on different endpoints is treated independently." |
| Missing key | 400 Bad Request, `{"type":"invalid_request","code":"idempotency_key_required","message":"Idempotency-Key header is required on all POST requests"}` |
| Same key, different body | 422, `code: idempotency_conflict`, "**No** (permanent)" |
| Same key, original in flight | 409, `code: idempotency_in_flight`, "Servers **SHOULD** include a `Retry-After` header (in seconds)." |
| 5xx | "Responses with HTTP **5xx** status codes **MUST NOT** be cached against the idempotency key." / "A retry with the same key after a 5xx **MUST** be processed as a **fresh request**." |
| Retention | "Servers **MUST** retain idempotency key → response mappings for **at least 24 hours**." |
| Replay signalling | `Idempotent-Replayed: "true"` |
| `Request-Id` | `Request-Id: <string>` — "**RECOMMENDED**"; "echo if provided" |

### `Signature` and `Timestamp` HMAC scheme

| Element | Value | Source |
| --- | --- | --- |
| `Signature` value format | `<base64url>` | `rfcs/rfc.agentic_checkout.md` header list |
| `Signature` OpenAPI description | "HMAC signature for webhook verification", example `ZXltZX...` | `openapi.agentic_checkout.yaml` → `parameters.Signature` |
| `Timestamp` value format | `<RFC3339>`, `format: date-time`, example `"2026-04-17T10:30:00Z"` | `openapi.agentic_checkout.yaml` |
| Webhook signature header | `Merchant-Signature` — "Requests MUST be signed with an HMAC signature in the `Merchant-Signature` header." | `https://www.agenticcommerce.dev/docs/reference/webhooks` |
| Webhook signature failure | `401 Unauthorized` - Invalid signature | same |
| Security rule | "**Webhooks:** Verify HMAC (`Merchant-Signature`) on webhook calls (see separate Webhooks RFC/OAS)." | `rfcs/rfc.agentic_checkout.md` |
| HMAC algorithm, key derivation, signed canonical string, encoding of the `Signature` header | NOT ESTABLISHED IN SOURCE | no such construction in `openapi.agentic_checkout.yaml`, `schema.agentic_checkout.json`, `rfcs/rfc.agentic_checkout.md`, or the webhooks doc |

### Error `type` enum

Source: `openapi.agentic_checkout.yaml` + `schema.agentic_checkout.json` + `rfcs/rfc.agentic_checkout.md`

Protocol-level `Error` object — `required: ["type","code","message"]`, optional
`param` ("RFC 9535 JSONPath"), `additionalProperties: false`, plus optional
`supported_versions` (added 2026-04-17).

| `type` | `code` (well-known) | HTTP |
| --- | --- | --- |
| `invalid_request` | `idempotency_key_required` | 400 |
| `invalid_request` | `idempotency_conflict` | 422 |
| `invalid_request` | `idempotency_in_flight` | 409 |
| `invalid_request` | `unsupported_api_version` | not stated `[UNVERIFIED]` |
| `invalid_request` | `missing_api_version` | not stated `[UNVERIFIED]` |
| `processing_error` | implementation-defined | 5XX |
| `service_unavailable` | implementation-defined | 5XX |

`Error.type` enum, authoritative, `openapi.agentic_checkout.yaml`, three values:
`invalid_request`, `processing_error`, `service_unavailable`. The changelog for
2026-04-17 states "Removed `request_not_idempotent` from `Error.type` enum. See
SEP #120."

**CONFLICT (ACP, `data.type`):** `docs/mcp-binding.md` still lists
`request_not_idempotent` in its "ACP Error Types in `data`" table alongside
`invalid_request`, `processing_error`, `service_unavailable`; the 2026-04-17
OpenAPI/JSON-Schema `Error.type` enum omits it and the RFC changelog records its
removal. Both quoted; the schema omits it.

`MessageError.code` enum, in `messages[]` on 2xx, `type: "error"`, `required:
["type","code","content_type","content"]`, twenty-one values:

| # | `code` |
| --- | --- |
| 1 | `missing` |
| 2 | `invalid` |
| 3 | `out_of_stock` |
| 4 | `payment_declined` |
| 5 | `requires_sign_in` |
| 6 | `requires_3ds` |
| 7 | `low_stock` |
| 8 | `quantity_exceeded` |
| 9 | `coupon_invalid` |
| 10 | `coupon_expired` |
| 11 | `minimum_not_met` |
| 12 | `maximum_exceeded` |
| 13 | `region_restricted` |
| 14 | `age_verification_required` |
| 15 | `approval_required` |
| 16 | `unsupported` |
| 17 | `not_found` |
| 18 | `conflict` |
| 19 | `rate_limited` |
| 20 | `expired` |
| 21 | `intervention_required` |

`MessageWarning.code` enum, `type: "warning"`, fourteen values:

| # | `code` |
| --- | --- |
| 1 | `low_stock` |
| 2 | `high_demand` |
| 3 | `shipping_delay` |
| 4 | `price_change` |
| 5 | `expiring_promotion` |
| 6 | `limited_availability` |
| 7 | `discount_code_expired` |
| 8 | `discount_code_invalid` |
| 9 | `discount_code_already_applied` |
| 10 | `discount_code_combination_disallowed` |
| 11 | `discount_code_minimum_not_met` |
| 12 | `discount_code_user_not_logged_in` |
| 13 | `discount_code_user_ineligible` |
| 14 | `discount_code_usage_limit_reached` |

`MessageInfo` (`type: "info"`) has **no** `code` property.

`InterventionCapabilities` enums. Source: `schema.agentic_checkout.json`

| Enum | Values |
| --- | --- |
| `severity` (Messages) | `info`, `low`, `medium`, `high`, `critical` |
| `resolution` | `recoverable`, `requires_buyer_input`, `requires_buyer_review` |
| `content_type` | `plain`, `markdown` (CommonMark 0.31.2, no raw HTML) |
| `InterventionCapabilities.supported` | `3ds`, `biometric`, `address_verification` |
| `InterventionCapabilities.required` | `3ds`, `biometric` |
| `InterventionCapabilities.enforcement` | `always`, `conditional`, `optional` |
| `InterventionCapabilities.display_context` | `native`, `webview`, `modal`, `redirect` |
| `InterventionCapabilities.redirect_context` | `in_app`, `external_browser`, `none` |

### Payment Handlers — `instrument` and `credential`

Source: `openapi.agentic_checkout.yaml` → `components.schemas.PaymentData` (wire shape) and `PaymentHandler`; `rfcs/rfc.payment_handlers.md` (Version: 2026-01-22)

`PaymentData` properties:

| Property | Type |
| --- | --- |
| `handler_id` | `string` |
| `instrument` | `object` |
| `billing_address` | `Address` |
| `purchase_order_number` | `string` |
| `payment_terms` | enum `immediate`, `net_15`, `net_30`, `net_60`, `net_90` |
| `due_date` | `date-time` |
| `approval_required` | `boolean` |

`PaymentData.anyOf`: `required: [handler_id, instrument]` **or** `required:
[purchase_order_number]`.

`instrument` from the OpenAPI, inline. Source: `openapi.agentic_checkout.yaml`

| Member | Type | Required | Description (verbatim) |
| --- | --- | --- | --- |
| `type` | `string` | **true** | "Instrument type (e.g., card, wallet_token)" |
| `credential` | `object` | **true** | |
| `credential.type` | `string` | **true** | "Credential type (e.g., spt, wallet_token)" |
| `credential.token` | `string` | **true** | "Credential token value" |

`required: ["type","credential"]` on `instrument` in the OpenAPI.

`instrument` from `rfcs/rfc.payment_handlers.md` §5.2, richer shape.
**`required: ["id","handler_id","type","credential"]`**

| Member | Type | Required | Constraint / description |
| --- | --- | --- | --- |
| `id` | `string` | **true** | pattern `^[a-zA-Z0-9_-]+$`, `minLength: 1`, `maxLength: 128` |
| `handler_id` | `string` | **true** | pattern `^[a-zA-Z0-9_-]+$` |
| `type` | `string` | **true** | examples `["card","wallet","bnpl","agentic_token"]` |
| `credential` | `object` | **true** | "Credential payload (structure defined by handler's credential schema)" |
| `metadata` | `object` | Optional | |
| `billing_address` | | Optional | |

**CONFLICT (ACP, `instrument` required set):** the OpenAPI `PaymentData.instrument`
requires only `["type","credential"]`; `rfc.payment_handlers.md` §5.2 requires
`["id","handler_id","type","credential"]`. Both quoted.

`PaymentHandler` object — `required:
["id","name","version","spec","requires_delegate_payment","requires_pci_compliance","psp","config_schema","instrument_schemas","config"]`;
optional `display_name`, `config` (object), `display_order` (integer; defined in
the RFC, absent from the OpenAPI properties block).

| Field | Note (verbatim where quoted) |
| --- | --- |
| `name` | "Handler name in reverse-DNS format (e.g., dev.acp.tokenized.card)" |
| `version` | pattern `^\d{4}-\d{2}-\d{2}$` |
| `instrument_schemas` | "URLs to JSON Schemas for payment instruments" |
| `requires_delegate_payment` | "**RECOMMENDED: `true`** for all handlers" |
| `requires_pci_compliance` | "**Default: `false`**" |

Credential sub-schemas named in the RFC:

| URL | Meaning |
| --- | --- |
| `https://acp.dev/schemas/credentials/spt.json` | Shared Payment Token |
| `https://acp.dev/schemas/credentials/agentic_token.json` | |

Handler example: `name: "dev.acp.tokenized.card"`, `psp: "stripe"`, `type:
"direct"`, `instrument_schemas:
["https://acp.dev/schemas/handlers/card/instrument.json"]` whose `credential` is
`oneOf: [spt.json, agentic_token.json]`.

### MCP binding — the five tools

Source: `https://raw.githubusercontent.com/agentic-commerce-protocol/agentic-commerce-protocol/main/spec/2026-04-17/openrpc/openrpc.agentic_checkout.json` (`openrpc: 1.3.2`, `info.version: "2026-04-17"`, title "ACP Agentic Checkout — MCP Binding") and `docs/mcp-binding.md`

| # | MCP tool | REST operation | `payload` $ref | `result` |
| --- | --- | --- | --- | --- |
| 1 | `create_checkout_session` | `POST /checkout_sessions` | `CheckoutSessionCreateRequest` | `CheckoutSession` |
| 2 | `get_checkout_session` | `GET /checkout_sessions/{id}` | *(no payload)* | `CheckoutSession` |
| 3 | `update_checkout_session` | `POST /checkout_sessions/{id}` | `CheckoutSessionUpdateRequest` | `CheckoutSession` |
| 4 | `complete_checkout_session` | `POST /checkout_sessions/{id}/complete` | `CheckoutSessionCompleteRequest` | `CheckoutSessionWithOrder` |
| 5 | `cancel_checkout_session` | `POST /checkout_sessions/{id}/cancel` | `CancelSessionRequest` (optional) | `CheckoutSession` |

Binding rules, verbatim: JSON-RPC 2.0 over MCP Streamable HTTP; "All 5
operations are exposed as MCP **Tools**, not Resources."; argument shape
`{meta, id, payload}`; `meta` `required: ["api_version"]`, `additionalProperties:
true`; `Authorization` is "*(out-of-band)*". Errors: "All ACP errors use JSON-RPC
error code `-32000` (server error) uniformly." with the ACP `Error` in
`error.data`; "`-32602` (Invalid params) … reserved for malformed requests that
fail at the JSON-RPC level". "Servers **MUST NOT** require `payload: null`."
Discovery: "the `transports` array in the discovery document includes `\"mcp\"`".
Scope covers checkout only — "a follow-up SEP will define the MCP binding for the
Delegate Payment API".

`meta` field to header map:

| `meta` field | Header |
| --- | --- |
| `api_version` | `API-Version` |
| `idempotency_key` | `Idempotency-Key` |
| `request_id` | `Request-Id` |
| `user_agent` | `User-Agent` |
| `accept_language` | `Accept-Language` |
| `signature` | `Signature` |
| `timestamp` | `Timestamp` |
| *(out-of-band)* | `Authorization` |

## AP2

Version v0.2. No HTTP surface of its own; the wire is SD-JWT verifiable
credentials.

### Roles

Source: `https://ap2-protocol.org/ap2/specification/` (page title "Agentic Payment Protocol (v0.2)"); repo file `docs/ap2/specification.md`

| Role label | Abbrev | Source name in prose | Agentic classification (verbatim) |
| --- | --- | --- | --- |
| Shopping Agent | SA | "Shopping Agent (SA): The Shopping Agent is the primary agent performing product discovery, building the checkout, and executing the purchase." | "is expected to be agentic" |
| Credential Provider | CP | "…source of Payment Credentials for the purchase." | MAY be agentic or non-agentic |
| Merchant | M | "…responsible for providing and completing the Checkout." | MAY be agentic or non-agentic |
| Merchant Payment Processor | MPP | "…responsible for processing payments for purchases." | MAY be agentic or non-agentic |
| Trusted Surface | TS | "…a UI surface that is trusted to get informed user consent for an Intent before creating a user-signed Mandate." | MUST be non-agentic |

### `vct` claim values

Source: `https://raw.githubusercontent.com/google-agentic-commerce/AP2/main/docs/ap2/checkout_mandate.md`, `…/payment_mandate.md`, and the JSON Schemas `code/sdk/schemas/ap2/{checkout_mandate,payment_mandate,open_checkout_mandate,open_payment_mandate}.json`

| Mandate | `vct` (schema `const` = `default`) | Schema description (verbatim) | Required fields (schema `required`) |
| --- | --- | --- | --- |
| closed Checkout Mandate | `mandate.checkout.1` | "Verifiable Credential Type claim as defined in SD-JWT. MUST be 'mandate.checkout'." | `vct`, `checkout_jwt`, `checkout_hash` |
| open Checkout Mandate | `mandate.checkout.open.1` | same pattern for `'mandate.checkout.open'` | `vct`, `constraints`, `cnf` |
| closed Payment Mandate | `mandate.payment.1` | same pattern for `'mandate.payment'` | `vct`, `transaction_id`, `payee`, `payment_amount`, `payment_instrument` |
| open Payment Mandate | `mandate.payment.open.1` | same pattern for `'mandate.payment.open'` | `vct`, `constraints`, `cnf` |

Mandate Versioning, verbatim: "The `vct` value includes a numeric suffix that
acts as a schema version number … Implementations MUST match the exact `vct`
string, including the version suffix." No other `vct` value is defined in v0.2.

### Checkout Mandate and open Checkout Mandate

Source: `code/sdk/schemas/ap2/checkout_mandate.json`, `open_checkout_mandate.json`

Checkout Mandate properties:

| Property | Type | Note (verbatim where quoted) |
| --- | --- | --- |
| `vct` | `string`, const | see above |
| `checkout_jwt` | `string` | `x-selectively-disclosable-field: true`, "base64url-encoded serialized merchant-signed JWT of the Checkout payload" |
| `checkout_hash` | `string` | "base64url-encoded hash of the checkout_jwt field value" |
| `iat` | `integer`, Unix epoch | |
| `exp` | `integer`, Unix epoch | |

`checkout_hash` algorithm, verbatim: "The algorithm used MUST be the same as the
SD-JWT, as defined by the `_sd_alg` claim in the base payload, or `sha-256` if not
present."

Open Checkout Mandate properties:

| Property | Type | Note (verbatim where quoted) |
| --- | --- | --- |
| `vct` | `string`, const | |
| `constraints` | array of `allowed_merchants` \| `line_items` | `contains: line_items` |
| `cnf` | object | "Confirmation claim defined in RFC 7800 section 3.1. Used for key binding." |
| `iat` | `integer` | |
| `exp` | `integer` | |

Checkout constraint types:

| `type` const | Members |
| --- | --- |
| `checkout.allowed_merchants` | `type` const, `allowed` array of Merchant, `x-selectively-disclosable-array` |
| `checkout.line_items` | `type` const, `items` array (`minItems: 1`) of `line_item_requirements` {`id`, `acceptable_items` (array of `item` {`id`,`title`}, selectively disclosable), `quantity` (`exclusiveMinimum: 0`)} |

### Payment Mandate and open Payment Mandate

Source: `code/sdk/schemas/ap2/payment_mandate.json`, `open_payment_mandate.json`

Payment Mandate properties:

| Property | Type | Note (verbatim where quoted) |
| --- | --- | --- |
| `vct` | `string`, const | |
| `transaction_id` | `string` | "base64url-encoded hash of the checkout_jwt field value … The hash algorithm used MUST be the same as the sd_hash field for this sd-jwt, or sha256 if absent." |
| `payee` | `types/merchant.json` | |
| `pisp` | `types/pisp.json` | |
| `payment_amount` | `types/amount.json` | "integer minor units per ISO 4217, e.g., 27999 = $279.99" |
| `payment_instrument` | `types/payment_instrument.json` | |
| `execution_date` | `string` | "ISO8601 date of execution of payment. When absent indicates immediate execution." |
| `risk_data` | `object` | |
| `iat` | `integer` | |
| `exp` | `integer` | |

Open Payment Mandate properties:

| Property | Type | Note |
| --- | --- | --- |
| `vct` | `string`, const | |
| `constraints` | array | `contains: payment_reference` |
| `cnf` | `object` | |
| `payee` | `types/merchant.json` | |
| `payment_amount` | `types/amount.json` | |
| `payment_instrument` | `types/payment_instrument.json` | |
| `pisp` | `types/pisp.json` | |
| `execution_date` | `string` | |
| `risk_data` | `object` | |
| `iat` | `integer` | |
| `exp` | `integer` | |

Payment constraint types:

| `type` const | Members |
| --- | --- |
| `payment.agent_recurrence` | `frequency` enum `ON_DEMAND`, `DAILY`, `WEEKLY`, `BIWEEKLY`, `MONTHLY`, `QUARTERLY`, `ANNUALLY`; `max_occurrences` integer |
| `payment.allowed_payees` | |
| `payment.allowed_payment_instruments` | |
| `payment.allowed_pisps` | |
| `payment.amount_range` | `currency`, `max` required; `min` optional |
| `payment.budget` | `max` number, `currency` required |
| `payment.reference` | `conditional_transaction_id` required |
| `payment.execution_date` | `not_before`, `not_after` |

### Receipts

Source: `code/sdk/schemas/ap2/checkout_receipt.json`, `payment_receipt.json`, `types/receipt_status.json`

`types/receipt_status.json` enum: `Success`, `Error`.

Checkout Receipt:

| Property | Type | Note (verbatim where quoted) |
| --- | --- | --- |
| `status` | `types/receipt_status.json` | |
| `iss` | `string` | |
| `iat` | `integer` | |
| `reference` | `string` | "The hash of the closed Mandate that this receipt is binding to." |
| `error` | `string` | |
| `error_description` | `string` | |
| `order_id` | `string` | |

`required: ["status","iss","iat","reference"]`; `oneOf`: `status: "Success"` +
`required: ["order_id"]` **or** `status: "Error"` + `required:
["error","error_description"]`.

Payment Receipt:

| Property | Type | Note (verbatim where quoted) |
| --- | --- | --- |
| `status` | `types/receipt_status.json` | |
| `iss` | `string` | |
| `iat` | `integer` | |
| `reference` | `string` | |
| `error` | `string` | |
| `error_description` | `string` | |
| `payment_id` | `string` | |
| `psp_confirmation_id` | `string` | "Present only if status is Success." |
| `network_confirmation_id` | `string` | "Present only if status is Success." |

`required: ["status","iss","iat","reference","payment_id"]`; `oneOf`: `status:
"Success"` + `required: ["psp_confirmation_id","network_confirmation_id"]` **or**
`status: "Error"` + `required: ["error","error_description"]`.

Generic Mandate Receipt. Source: `docs/ap2/agent_authorization.md`

| Property | Status | Note (verbatim where quoted) |
| --- | --- | --- |
| `iss` | **REQUIRED** | "MUST be the Verifier" |
| `result` | **REQUIRED** | "An Enum with value `[\"success\", \"error\"]`" |
| `reference` | **REQUIRED** | base64url hash, "MUST be the same as the `_sd_alg` specified for the SD-JWT, or `sha-256` if not specified" |
| `error` | **OPTIONAL** | "MUST be present when the result is `\"error\"`" |
| `error_description` | **OPTIONAL** | |

**CONFLICT (AP2, receipt `status` vs `result`):**
`checkout_receipt.json`/`payment_receipt.json` use `status` with enum
`["Success","Error"]`; `agent_authorization.md` defines the generic Mandate
Receipt with `result` and enum `["success","error"]`. Both quoted; the schemas use
capitalized values, the prose lowercase.

### `cnf` and `sd_hash` requirements

Source: `docs/ap2/specification.md`, `docs/ap2/agent_authorization.md`, `docs/ap2/security_and_privacy_considerations.md`, plus the two `open_*_mandate.json` schemas

| Item | Verbatim |
| --- | --- |
| Open Mandates (specification.md) | "These MUST include the agent's public key as a `cnf` claim. This is required as it is not yet bound to a particular transaction, and so it needs to be constrained for use by the Agent." |
| Schema | both `open_checkout_mandate.json` and `open_payment_mandate.json`: `required: ["vct","constraints","cnf"]`; `cnf` = "Confirmation claim as defined in RFC 7800 section 3.1. Used for key binding." |
| Agent Authorization framework | "*cnf*: **OPTIONAL**. Contains the confirmation method identifying the Proof-of-Possession key as defined in RFC7800. This claim is **REQUIRED** if the Mandate is still open." |
| Security mitigation | "Open Mandates MUST contain the Agent's key (via a `cnf` claim) so that only the agent could create a Closed Mandate with a valid signature." |
| Key Binding | "Because Open Mandates need to be bound to a particular transaction before use, they **MUST** support cryptographic Key Binding." |
| Observed shape | `{"cnf": {"jwk": {"crv": "P-256", "kty": "EC", "x": "…", "y": "…"}}}` (examples in `checkout_mandate.md`, `payment_mandate.md`, `agent_authorization.md`) |
| Closed→open binding | "Closed Mandates MUST contain the `sd_hash` claim to bind them to the presented open Mandate." |

### OpenID4VP `transaction_data` object type strings

Source: `https://raw.githubusercontent.com/google-agentic-commerce/AP2/main/docs/ap2/agent_authorization.md` (§ "Delegation using OpenID4VP")

| `type` value | Status | Where |
| --- | --- | --- |
| `delegate` | **Normative**: "**type**: **REQUIRED**. MUST be the string value \"*delegate*\"." | prose |
| `payment_card` | **Non-normative example only** | appears solely under the heading "**Decoded `transaction_data` Payloads (Informative)**", "Index 0 — Payment Card (UI Data)"; JSON example |

Mandate delegation object required members, verbatim:

| Member | Status | Description (verbatim) |
| --- | --- | --- |
| `type` | REQUIRED | MUST be the string value "*delegate*" |
| `format` | REQUIRED | "The required VDC format of the returned Mandate"; example value `dc+sd-jwt` |
| `delegate_payload` | REQUIRED | "An array containing the Mandate Content payloads as JSON Objects" |
| `delegate_disclosures` | OPTIONAL | "An array that contains any Selective Disclosures in the `delegate_payload`" |

"When constructing the Authorization Response, the `delegate_payload` MUST be
included as part of the Key Binding."

Example request envelope, non-normative:

| Field | Value |
| --- | --- |
| `protocol` | `"openid4vp-v1-unsigned"` |
| `response_type` | `"vp_token"` |
| `response_mode` | `"dc_api"` |
| `dcql_query` | `vct_values: ["com.emvco.dpc"]` |
| `client_metadata.client_id_scheme` | `"x509_san_dns"` |
| `client_metadata.vp_formats["dc+sd-jwt"]` | `{"sd-jwt_alg_values":["ES256"],"kb-jwt_alg_values":["ES256"]}` |

Normative requirement for a response mode: **NOT ESTABLISHED IN SOURCE** —
`response_mode` appears only inside the block explicitly introduced as "Below is a
**non-normative** example of an OpenID4VP Authorization Request to delegate
Checkout and Payment Mandates".

Digital Credentials API statement, the only normative-adjacent text: "It is
RECOMMENDED to use the Digital Credentials API for delegation with OpenID4VP where
available to provide higher security and the best quality user experience."
Digital Credentials API reference or URL: **NOT ESTABLISHED IN SOURCE** — the
phrase carries no hyperlink. AP2's `## References` normative list contains only:
OpenID4VP, SD-JWT (RFC 9901), Delegate SD-JWT, RFC7800. Informative: OpenID4VCI,
ISO18013-5, ISO18013-7. Corroborating absence: the pattern
`dc_api|Digital Credentials API|response_mode|openid4vp-v1-unsigned` returns no
match in `docs/ap2/specification.md`, `docs/ap2/flows.md`, `docs/overview.md`,
`docs/faq.md`, `docs/index.md`, `docs/glossary.md`.

### The two mode discriminators

Source: `docs/ap2/specification.md` (§ Modes) and `docs/ap2/flows.md`

| Item | Verbatim |
| --- | --- |
| Mode names | "There are two `modes` that AP2 can consider to operate in." → "Human Present (Direct): The User directly sees the closed Checkout and approves it and its payment explicitly." / "Human Not Present (Autonomous): The User sees and approves a set of constraints over what closed Checkout and Payment would meet their intent." |
| Flow labels | `direct` = Human Present; `autonomous` = Human Not Present ("This is the `direct` flow where the User is present to directly approve the closed Payment and Checkout Mandates.") |
| Verifier view | "Verifiers of Mandates *always* receive a closed Payment and Checkout Mandate, regardless of the mode. The difference is only in how the verification of the Mandate is performed." |
| Wire discriminator | The `vct` string: closed = `mandate.checkout.1` / `mandate.payment.1`; open = `mandate.checkout.open.1` / `mandate.payment.open.1`. In the Direct case the closed Mandate is signed by the User ("the signature on the closed Mandates is validated as coming from a User directly"); in the Autonomous case the closed Mandate is agent-signed and carries `sd_hash` binding it to the user-signed open Mandate's `cnf` key. |
| Explicit `mode` field on the wire | **NOT ESTABLISHED IN SOURCE** — no `mode` member appears in any `code/sdk/schemas/ap2/*.json` mandate or receipt schema |
| Mode fallback | "A Human Not Present flow can be turned into a Human Present flow by the Merchant (or Credential Provider) returning an `unresolved_constraint` error and bringing the User back into the loop to approve the closed Mandates." |

### Signature-algorithm requirement

Source: `docs/ap2/specification.md`, `docs/ap2/security_and_privacy_considerations.md`, `docs/ap2/implementation_considerations.md`

| Requirement | Verbatim |
| --- | --- |
| Checkout JWT signing | "The Checkout JWT MUST be signed using a digital signature scheme (e.g., ECDSA) and not a deterministic signature (e.g., Ed25519)." |
| Purpose | "To prevent rainbow table attacks…" |
| Salt requirement | "The `checkout_hash` makes use of the entropy already included in the JWT signature … If a signing algorithm (e.g. deterministic signature scheme such as `Ed25519`) is used that does not include this then a salt of sufficient entropy MUST be present in the Checkout." |
| SD-JWT digests | "Digests in SD-JWTs (for Payment and Checkout Mandates as well as Constraints) MUST include a salt with sufficient entropy to prevent guessing the plaintext. See RFC9901 Section 9.1." |
| Decoy digests | "the Trusted Surface MAY insert decoy digests as described in RFC9901 Section 4.2.5." |
| Hash algorithm consistency | "For consistency, the same hashing algorithm is required for both the SD-JWT digests and `checkout_hash`." |
| Merchant keying | "The Merchant MUST provide a merchant-signed JWT containing the Checkout to the Shopping Agent." |
| Example `alg` values in AP2 artifacts | `ES256` (issuer-signed SD-JWT `typ: "example+sd-jwt"`, key-bound `typ: "kb+sd-jwt"`, checkout JWT `typ: "JWT"`); `client_metadata.vp_formats["dc+sd-jwt"].{sd-jwt_alg_values,kb-jwt_alg_values} = ["ES256"]` |
| Mandated algorithm list | **NOT ESTABLISHED IN SOURCE** — no normative enumeration of allowed `alg` values exists in AP2 v0.2 |

## x402

Protocol Version 1.

### `x402Version`

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md`

The spec's own declaration is `**Protocol Version**: 1`.

| Item | Value |
| --- | --- |
| Declared protocol version | `1` (verbatim: `**Protocol Version**: 1`) |
| Field name | `x402Version` |
| Field type | `number` |
| Permitted value | 1 — "Protocol version identifier (**must be 1**)" |
| Occurrences in the spec, verbatim | `"x402Version": 1` in `PaymentRequirementsResponse`, in `PaymentPayload`, in `GET /supported` `kinds[]`, and in each Bazaar resource entry |

### Request and response header names

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md`

| Direction | Header name | Status |
| --- | --- | --- |
| Server → Client (payment required) | `X-PAYMENT` | **The v1 spec names it exactly once**, inside the sample `error` string: `"error": "X-PAYMENT header is required"`. The v1 spec contains no transport/header section, no `Payment-Required`/`PAYMENT-*` header definition, and no mention of the request or settlement header names. |

The v1-spec request and response header names are otherwise **NOT ESTABLISHED IN
SOURCE**.

Source: conflicting, v2-era docs — `https://docs.x402.org/core-concepts/http-402`, `https://docs.x402.org/core-concepts/facilitator`, `https://docs.x402.org/core-concepts/client-server.md`

| Header | Direction | Description (verbatim) |
| --- | --- | --- |
| `PAYMENT-REQUIRED` | Server → Client | Base64-encoded `PaymentRequired` object |
| `PAYMENT-SIGNATURE` | Client → Server | Base64-encoded `PaymentPayload` object |
| `PAYMENT-RESPONSE` | Server → Client | Base64-encoded `SettlementResponse` object |
| `EXTENSION-RESPONSES` | Server → Client (bazaar extension) | "A base64-encoded JSON object keyed by extension name" (`https://docs.x402.org/extensions/bazaar.md`) |

**CONFLICT (x402, header names):** the v1 spec's only header string is
`X-PAYMENT`; the current docs specify `PAYMENT-REQUIRED` / `PAYMENT-SIGNATURE` /
`PAYMENT-RESPONSE` and state "x402 V2 uses three standardized headers for payment
communication". The v1 spec file itself declares "**Protocol Version**: 1" and
its own `Version History` ends at `v0.2 | 2025-10-3 | Transport-agnostic
redesign`. Both sets are quoted.

### `PaymentRequirementsResponse` and `PaymentRequirements`

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md` §5

`PaymentRequirementsResponse` — "**All fields are required.**"

| Field | Type |
| --- | --- |
| `x402Version` | `number` |
| `error` | `string` |
| `accepts` | `array` |

`PaymentRequirements`, each element of `accepts`:

| Field | Type | Required | Description (verbatim) |
| --- | --- | --- | --- |
| `scheme` | `string` | Required | Payment scheme identifier (e.g., "exact") |
| `network` | `string` | Required | Blockchain network identifier (e.g., "base-sepolia", "ethereum-mainnet") |
| `maxAmountRequired` | `string` | Required | Required payment amount in atomic token units |
| `asset` | `string` | Required | Token contract address |
| `payTo` | `string` | Required | Recipient wallet address for the payment |
| `resource` | `string` | Required | URL of the protected resource |
| `description` | `string` | Required | Human-readable description of the resource |
| `mimeType` | `string` | **Optional** | MIME type of the expected response |
| `outputSchema` | `object` | **Optional** | JSON schema describing the response format |
| `maxTimeoutSeconds` | `number` | Required | Maximum time allowed for payment completion |
| `extra` | `object` | **Optional** | Scheme-specific additional information |

### `PaymentPayload`

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md` §7

`PaymentPayload` — "**All fields are required.**"

| Field | Type |
| --- | --- |
| `x402Version` | `number` |
| `scheme` | `string` |
| `network` | `string` |
| `payload` | `object` |

`payload` (`SchemePayload`) — "**All fields are required.**"

| Field | Type | Description (verbatim) |
| --- | --- | --- |
| `signature` | `string` | "EIP-712 signature for authorization" |
| `authorization` | `object` | "EIP-3009 authorization parameters" |

`authorization` (`Authorization`) — "**All fields are required.**"

| Field | Type | Description (verbatim) |
| --- | --- | --- |
| `from` | `string` | "Payer's wallet address" |
| `to` | `string` | "Recipient's wallet address" |
| `value` | `string` | "Payment amount in atomic units" |
| `validAfter` | `string` | "Unix timestamp when authorization becomes valid" |
| `validBefore` | `string` | "Unix timestamp when authorization expires" |
| `nonce` | `string` | "32-byte random nonce to prevent replay attacks" |

EIP-712 `TransferWithAuthorization` types, verbatim order and names:

| Field | EIP-712 type |
| --- | --- |
| `from` | `address` |
| `to` | `address` |
| `value` | `uint256` |
| `validAfter` | `uint256` |
| `validBefore` | `uint256` |
| `nonce` | `bytes32` |

### `SettlementResponse`

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md` §8

| Field | Type | Required | Description (verbatim) |
| --- | --- | --- | --- |
| `success` | `boolean` | Required | Indicates whether the payment settlement was successful |
| `errorReason` | `string` | **Optional** | Error reason if settlement failed (omitted if successful) |
| `transaction` | `string` | Required | Blockchain transaction hash (empty string if settlement failed) |
| `network` | `string` | Required | Blockchain network identifier |
| `payer` | `string` | Required | Address of the payer's wallet |

### Facilitator endpoint paths

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md` §7, §8

| Method | Path | Request / response (verbatim) |
| --- | --- | --- |
| POST | `/verify` | request `{x402Version, paymentPayload, paymentRequirements}`; success `{"isValid": true, "payer": "0x…"}`; error `{"isValid": false, "invalidReason": "insufficient_funds", "payer": "0x…"}` |
| POST | `/settle` | "Request: Same as `/verify` endpoint"; success `{"success": true, "payer", "transaction", "network"}`; error `{"success": false, "errorReason", "payer", "transaction": "", "network"}` |
| GET | `/supported` | `{"kinds": [{"x402Version": 1, "scheme": "exact", "network": "base-sepolia"}, …]}` |
| GET | `/discovery/resources` | see the Bazaar section below |

Facilitator note, verbatim: "Note that while the core x402 protocol is
transport-agnostic, facilitator APIs are currently standardized as HTTP
endpoints." Docs add a public instance path `[https://x402.org/facilitator]`
`[UNVERIFIED — not in the v1 spec]`.

### Bazaar discovery path and resource-entry fields

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md` §8

| Item | Value |
| --- | --- |
| Path | `GET /discovery/resources` |
| Query parameter `type` | `string`, Optional, "Filter by resource type (e.g., \"http\")", default `-` |
| Query parameter `limit` | `number`, Optional, "Maximum number of results to return (1-100)", default `20` |
| Query parameter `offset` | `number`, Optional, "Number of results to skip for pagination", default `0` |
| Example call | `GET /discovery/resources?type=http&limit=10` |

v1 resource-entry fields, table `8.2 Discovered Resource Fields`:

| Field | Type | Required | Description (verbatim) |
| --- | --- | --- | --- |
| `resource` | `string` | Required | The resource URL or identifier being monetized |
| `type` | `string` | Required | Resource type (currently "http" for HTTP endpoints) |
| `x402Version` | `number` | Required | Protocol version supported by the resource |
| `accepts` | `array` | Required | Array of PaymentRequirements objects specifying payment methods |
| `lastUpdated` | `number` | Required | Unix timestamp of when the resource was last updated |
| `metadata` | `object` | Optional | Additional metadata (category, provider, etc.) |

Envelope fields in the v1 example: `x402Version` (number), `items` (array),
`pagination` (object: `limit`, `offset`, `total`).

**CONFLICT (x402, Bazaar entry shape):**
`https://docs.x402.org/extensions/bazaar.md` (v2) shows the same path `GET
{facilitator_url}/discovery/resources` but with different entry fields —
`accepts[].amount` (instead of `maxAmountRequired`), `lastUpdated` as an ISO-8601
string `"2025-08-09T01:07:04.005Z"`, `x402Version: 2`, and an added
`extensions.bazaar.info` object with `input`/`output`. `type` enum there is
`"http"` **or** `"mcp"`. v2 also adds `search` and `bazaar.status` ∈
`{"success","processing","rejected"}` with `bazaar.rejectedReason`.

### v1 error codes and supported networks

Source: `https://raw.githubusercontent.com/x402-foundation/x402/main/specs/x402-specification-v1.md` §9, §11.1

Error codes, verbatim, fifteen values:

| # | Code |
| --- | --- |
| 1 | `insufficient_funds` |
| 2 | `invalid_exact_evm_payload_authorization_valid_after` |
| 3 | `invalid_exact_evm_payload_authorization_valid_before` |
| 4 | `invalid_exact_evm_payload_authorization_value` |
| 5 | `invalid_exact_evm_payload_signature` |
| 6 | `invalid_exact_evm_payload_recipient_mismatch` |
| 7 | `invalid_network` |
| 8 | `invalid_payload` |
| 9 | `invalid_payment_requirements` |
| 10 | `invalid_scheme` |
| 11 | `unsupported_scheme` |
| 12 | `invalid_x402_version` |
| 13 | `invalid_transaction_state` |
| 14 | `unexpected_verify_error` |
| 15 | `unexpected_settle_error` |

Networks, verbatim:

| Network | Chain ID |
| --- | --- |
| `base-sepolia` | 84532 |
| `base` | 8453 |
| `avalanche-fuji` | 43113 |
| `avalanche` | 43114 |

`GET /supported` example also lists `iotex`. Assets: `USDC` (EIP-3009 compliant
ERC-20 token).
