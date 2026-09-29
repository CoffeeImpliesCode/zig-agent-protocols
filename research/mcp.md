# Model Context Protocol

The Model Context Protocol in full: the current `2026-07-28` core revision and every
breaking change that separates it from `2025-11-25`, the extensions framework built by
SEP-2133 and the five official extensions under it, the official MCP Registry with its
API, moderation posture and disputed size, the SEP process and the proposed release
cadence, and the sharp edges that make the wire harder than the spec text suggests. This
document does not enumerate the primitive method set of the core protocol, does not
re-derive the vendor support matrix (that lives in
[`platform-support.md`](platform-support.md)), and does not cover MCP Apps as a UI
protocol beyond what the extension itself constrains (see
[`ui-protocols.md`](ui-protocols.md)). Where the source material did not reach a value,
this document says so.

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

`2026-07-28` is the current stable revision of the core protocol. The draft changelog at
[`modelcontextprotocol.io/specification/draft/changelog`](https://modelcontextprotocol.io/specification/draft/changelog)
reads, in full: *"Changes since the most recent release will accumulate here."* — with
zero entries. Nothing has merged into a successor revision as of the research date. The
normative source is the TypeScript schema at `schema/2026-07-28/schema.ts` in
`modelcontextprotocol/specification`. SEP and documentation work happens in
`modelcontextprotocol/modelcontextprotocol`, a separate repository the docs site does not
name.

MCP is now a two-layer system over that core revision, plus a non-normative third layer
of infrastructure.

| Layer | What it is | Normative |
| --- | --- | --- |
| Core protocol | Date-versioned primitive set, revision `2026-07-28`, stateless | Yes |
| Extensions framework | Optional opt-in capabilities under `{vendor}/{name}` identifiers, per SEP-2133 | Yes, per extension |
| Registry and aggregators | Metadata-only server catalogue plus vendor marketplaces | No |

The core revision is stateless. There is no `initialize` handshake, no `Mcp-Session-Id`,
and no SSE resumption. Every request carries its version and its client capabilities in
`_meta`, a version mismatch yields `UnsupportedProtocolVersionError`, servers must
implement `server/discover`, and server-initiated requests were replaced by the MRTR
pattern. The
[versioning page](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
divides implementations into Modern (`2026-07-28`+), Legacy (`2025-11-25`- and earlier)
and Dual-era, and states that dual-era servers MAY serve both eras concurrently.

### Governance and licence

Model Context Protocol is **"a Series of LF Projects, LLC"** — a Linux Foundation
project, with a Python-style maintainer hierarchy.

| Role | Named holders as of 2026-09-29 |
| --- | --- |
| Lead Maintainers (BDFL) | David Soria Parra (`dsp-ant`), Den Delimarsky (`localden`) |
| Core Maintainers | Peter Alexander (`pja-ant`), Caitie McCaffrey (`CaitieM20`), Kurtis Van Gent (`kurtisvg`), Clare Liguori, Paul Carleton (`pcarleton`), Nick Cooper (`nickcoai`) |
| Emeritus | Justin Spahr-Summers, Basil Hosmer, Che Liu, Nick Aldridge |

Core Maintainers meet bi-weekly. There are 42 Final SEPs and 44 open SEP pull requests as
of the research date
([`/seps/index`](https://modelcontextprotocol.io/seps/index); open-PR count from the
[GitHub SEP PR search](https://api.github.com/search/issues?q=repo:modelcontextprotocol/modelcontextprotocol+type:pr+state:open+SEP)).

| Artefact | Licence |
| --- | --- |
| Spec text and schema | Apache 2.0 |
| Prose documentation | CC-BY-4.0 |
| Registry OpenAPI document | MIT |
| Registry implementation | Apache 2.0, with a CLA to the Linux Foundation |
| Extension repositories (for example `ext-apps`) | Apache 2.0 |
| SEP-2133 contributions | Apache 2.0, LF contributor licence grant, trademark and antitrust clauses apply |

The licence split is why the schema and the prose are separately citable. SEP-2133
additionally requires that extensions be contributed under Apache 2.0.

### SDK conformance tiers

SEP-1730 defines three SDK tiers gated on a conformance test suite, at 100 %, 80 % and no
conformance requirement respectively. The test suite became available 2026-01-23 and the
tier assignments were published 2026-02-23. Relegation rules apply when a regression is
found. The tiering explicitly carves out extensions and experimental features: **no tier
requires support for any extension**, so the tiers place no floor under the extension
ecosystem.

## What it does

### The 2025-11-25 revision, in one paragraph

2025-11-25 was the last handshake-based, session-carrying revision, and was primarily an
authorization and elicitation release layered onto an otherwise incremental set of
metadata and schema improvements. Its nine major changes were: OpenID Connect Discovery
1.0 added to authorization server discovery; **icons** as additional metadata on tools,
resources, resource templates and prompts (SEP-973); **incremental scope consent** via
`WWW-Authenticate` (SEP-835); guidance on tool names (SEP-986); a standards-based rework
of `ElicitResult` and `EnumSchema` supporting titled and untitled, single-select and
multi-select enums (SEP-1330); **URL-mode elicitation** (SEP-1036), letting a server hand
the user a URL to complete something out of band and the first real out-of-band
interaction primitive; `tools`/`toolChoice` parameters giving **sampling tool-calling**
(SEP-1577); **OAuth Client ID Metadata Documents** as the recommended client-registration
mechanism (SEP-991); and **experimental tasks** — durable request tracking with polling and
deferred result retrieval (SEP-1686) — which shipped inside the core spec as an
experimental utility. Minor changes covered stderr permitted for all log types on stdio,
an optional `description` on `Implementation` to align with the registry's `server.json`,
HTTP 403 required for an invalid `Origin`, input validation errors returned as
tool-execution errors rather than protocol errors so the model can self-correct (SEP-1303),
server-initiated SSE disconnect for polling (SEP-1699), OAuth protected-resource-metadata
discovery aligned with RFC 9728 making `WWW-Authenticate` optional (SEP-985), default
values for all primitive elicitation types (SEP-1034), and JSON Schema 2020-12 as the
default dialect (SEP-1613). It also carried the governance SEPs 932 (formal governance),
994 (communication practices), 1302 (Working and Interest Groups) and 1730 (SDK tiering).

### The 2026-07-28 revision and every breaking change

No published changelog page for `2026-07-28` was reachable during this research; the
`2026-07-28` changelog, unlike the `2025-11-25` one, is **NOT ESTABLISHED IN SOURCE**.
The table below is reconstructed from the specification's current-state description, the
reversal note attached to `2025-11-25`, and the field-observation section of
[Sharp edges](#sharp-edges) below. It is complete with respect to those sources; it is
not a substitute for the upstream changelog.

| Change | `2025-11-25` | `2026-07-28` |
| --- | --- | --- |
| Session establishment | `initialize` handshake, session id issued | Removed. No handshake |
| Session identifier | `Mcp-Session-Id` | Removed from the spec |
| SSE resumption | Supported | Removed |
| Version declaration | In the `initialize` exchange | Per request, in `_meta["io.modelcontextprotocol/protocolVersion"]` |
| Client capabilities | `initialize` capabilities block | Per request, in `_meta["io.modelcontextprotocol/clientCapabilities"]`, with `clientInfo` in `_meta` too |
| Server discovery | None | `server/discover`; servers MUST implement it and advertise `capabilities.extensions` in its response |
| Version negotiation failure | — | `UnsupportedProtocolVersionError`; the `MCP-Protocol-Version` header carries the version |
| Server-initiated requests (elicitation, sampling) | Delivered over an open session, requiring stateful mode | Replaced by the MRTR pattern |
| MRTR mechanism | — | A result carrying `InputRequiredResult`, `inputRequests` and `inputResponses`, followed by a retry of the original request |
| Tasks | Experimental, in core (SEP-1686) | Pulled back out of core into the `ext-tasks` extension (SEP-2663) |
| Resource subscriptions | Core feature | Replaced by `subscriptions/listen` |
| Optional-feature capability bucket | `experimental` | `extensions` |
| `ping` | Present | Removed |
| `logging/setLevel` | Present, session-scoped | Removed; `logLevel` travels per request in `_meta` |
| `notifications/roots/list_changed` | Present | Removed |
| `notifications/message` precondition | Any session | Servers MUST NOT emit it without `logLevel` in the request's `_meta` |
| Logging on stdio | Restricted to non-stdout | stderr permitted for all log types, carried over from `2025-11-25` |

Consequences worth naming:

- A client that cannot perform MRTR loses server-initiated requests entirely. Elicitation
  and sampling do not degrade; they disappear.
- `UnsupportedProtocolVersionError` is the negotiation failure path. The error code and
  the client/server compatibility matrix are on the versioning page; the compatibility
  matrix and the transport-specific era probes are **NOT ESTABLISHED IN SOURCE** here —
  the page was read, its tables were not transcribed.
- Elicitation and sampling changed their statefulness requirement. On `2025-11-25` and
  earlier they require a stateful session; on `2026-07-28`+ they route through MRTR and do
  not. Amazon Bedrock AgentCore is the only vendor found that documents this fork
  explicitly.
- Extensions that were core features one revision earlier are now opt-in. Tasks is the
  case in point, and the roadmap states that continued work on Tasks toward eventual
  inclusion in core is expected.

The extension and result field names inside the MRTR result beyond `InputRequiredResult`,
`inputRequests` and `inputResponses`, and the request/response shape of `server/discover`
beyond its `capabilities.extensions` field, are **NOT ESTABLISHED IN SOURCE**.

### The extensions framework

An extension is identified by an *extension identifier* of the form
`{vendor-prefix}/{extension-name}`, for example
`io.modelcontextprotocol/oauth-client-credentials`. Identifiers follow the same rules as
`_meta` keys, with a **mandatory prefix**. Official extensions use
`io.modelcontextprotocol`. Third parties are told to use a reversed domain they own,
Java-package style, such as `com.example/my-extension`, to avoid collisions.

The framework itself is **SEP-2133** — Final, Standards Track, created 2025-01-21, PR
#2133, author Peter Alexander. It defines exactly three things: an identifier, a settings
object, and a capability key. Everything else is delegated to the extension. A **breaking
change** is formally defined as removing or renaming a field, changing a field type,
altering the semantics of existing behaviour, or adding a new required field. Breaking
changes must use a new identifier, suffixed `-v2`, although the overview page softens
this to "prefer capability flags or versioning within the extension settings object rather
than creating a new extension identifier". SEP-3392 would replace the rule entirely; see
[What changed recently](#what-changed-recently).

**Versioning is the notable gap.** SEP-2133 says verbatim: *"Extensions SHOULD be versioned,
but exact versioning approach is not specified here."* In practice each extension
repository carries a `specification/` directory with a version-named or
`stable`/`draft` subdirectory — `ext-apps/specification/2026-01-26/apps.mdx`,
`ext-tasks/specification/2026-07-28/`, `ext-auth/specification/{stable,draft}/`. Extension
versioning is therefore a repository convention, not a protocol-level or registry-level
mechanism. [INFERENCE] Extension version negotiation does not exist on the wire at all:
nothing tells a peer which extension version is in play, so the
`protocolVersion: "2026-01-26"` that `ext-apps` carries inside its own `ui/initialize` is
a spec-local convention rather than a framework mechanism.

**Negotiation comes in two incompatible shapes.**

| Era | Where the client declares `extensions` | Where the server declares `capabilities.extensions` |
| --- | --- | --- |
| Modern, `2026-07-28`+ | In `_meta["io.modelcontextprotocol/clientCapabilities"]` on **every request** | In the `server/discover` response |
| Legacy, `2025-11-25`- and earlier | In the `initialize` request and response `capabilities` block | In the `initialize` response |

`extensions` is a map from extension identifier to a per-extension settings object; an
empty object `{}` means supported with no settings. A client request as published looks
like this:

```json
{
  "_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {
      "extensions": {
        "io.modelcontextprotocol/ui": { "mimeTypes": ["text/html;profile=mcp-app"] }
      }
    },
    "io.modelcontextprotocol/clientInfo": {}
  }
}
```

The two paths are not symmetric. Open PR #3364 (sambhav, opened 2026-09-15, still open)
exists specifically to restore the `2025-11-25` `initialize` examples to the
documentation and to state that `extensions` is **absent from the older published
capability schemas**. SDK support must therefore be checked per protocol version.

**Graceful degradation is mandatory on the supporting side.** If one party supports an
extension and the other does not, the supporting side must either fall back to core
behaviour or reject with an appropriate error, and the extension should document its
fallback. The published example: a server offering UI-enhanced tools must still return
meaningful text for non-UI clients, while a server requiring an auth extension may reject
the connection.

**Lifecycle, per SEP-2133.** Five steps.

| Step | Requirement |
| --- | --- |
| Propose | SEP in the main repository, type Extensions Track |
| Implement | At least one reference implementation in an official SDK, required before review |
| Review | Core Maintainers hold final authority |
| Publish | Pull request adding the extension to its repository |
| Adopt | Out of band |

Requirements throughout: RFC 2119 language, and an associated Working Group or Interest
Group. SDK maintainers have full autonomy over their own SDKs; extensions must be off by
default and opt-in; and extension support is explicitly not required for protocol
conformance or for any SDK conformance tier.

**The experimental tier.** Any maintainer may create an `experimental-ext-<name>`
repository while the SEP is still in draft or before submission. It must be tied to a WG
or IG, must mark its experimental status in the README and in published package names,
and remains under Core Maintainer oversight including the power to archive or remove it.
Graduation to official goes through the standard Extensions Track. Two are in incubation:
`experimental-ext-interceptors` (SEP-2624, multi-language reference implementation) and
`experimental-ext-server-card` (SEP-2127).

**There is no extension registry.** No machine-readable registry of extensions, no
discovery endpoint, and no signed extension index exists. What exists instead is the
hand-maintained overview page, a community-maintained pull-request-editable support
matrix whose own text reads "This list is maintained by the community… please submit a
pull request", and the repository naming convention as a de-facto stage signal. The
matrix lists only four extensions and omits Tasks entirely, although Tasks is Final and
shipped in the `2026-07-28` release. Extension-support tracking is already known-stale.

**SEP-2133's own acknowledged gaps**, in its "Not Specified" section: no mechanism for
extensions to advertise how they modify the schema, no rules for inter-extension or
extension-to-core-version dependencies, and no way to group extensions into profiles.

### The five official extensions

Four appear on the support matrix; five have official repositories.

| Extension | Identifier | Repository | Spec status |
| --- | --- | --- | --- |
| MCP Apps | `io.modelcontextprotocol/ui` | `ext-apps` | `2026-01-26` = **Stable**; `draft` in development |
| OAuth Client Credentials | `io.modelcontextprotocol/oauth-client-credentials` | `ext-auth` | `stable` + `draft` directories; from SEP-1046 (Final) |
| Enterprise-Managed Authorization | `io.modelcontextprotocol/enterprise-managed-authorization` | `ext-auth` | `specification/stable/enterprise-managed-authorization.mdx`; from SEP-990 (Final) |
| Tasks | `io.modelcontextprotocol/tasks` | `ext-tasks` | `specification/2026-07-28/` + `draft`; SEP-2663 (Final, Extensions Track) |
| Skills over MCP | `io.modelcontextprotocol/skills` | `ext-skills` | SEP-2640 (Final, Extensions Track) |

#### MCP Apps

Identifier `io.modelcontextprotocol/ui`. The repository calls the object a "View"; the
documentation site calls it an "App". Spec version `2026-01-26`, status Stable.

A **UI Resource** is a normal MCP resource whose `uri` must use the `ui://` scheme and
whose `mimeType` must be `text/html;profile=mcp-app`. Content is returned through
`resources/read` as `text` or `blob`; other MIME types are reserved for future
extensions; the content must be a valid HTML5 document. Resource metadata lives in
`_meta.ui`:

| Field | Effect |
| --- | --- |
| `csp.connectDomains[]` | Maps to CSP `connect-src`. Empty or omitted means no external connections |
| `csp.resourceDomains[]` | Maps to `img-src`, `script-src`, `style-src`, `font-src`, `media-src`. Wildcard subdomains supported |
| `csp.frameDomains[]` | Maps to `frame-src`. Empty or omitted means `frame-src 'none'` |
| `csp.baseUriDomains[]` | Maps to `base-uri`. Empty or omitted means `base-uri 'self'` |
| `permissions.{camera,microphone,geolocation,clipboardWrite}` | Request only; hosts may honour through the iframe `allow` attribute. Apps SHOULD NOT assume permissions are granted |
| `domain` | A dedicated sandbox origin, for stable OAuth callbacks, CORS and API-key allowlists. Host-defined: format and validation are the host's |
| `prefersBorder` | Boolean. An explicit value is recommended because host defaults vary |

The `domain` field's two documented host patterns are unrelated to one another:
`a904794854a047f6.claudemcpcontent.com`, which Anthropic derives by hashing, and
`www-example-com.oaiusercontent.com`, which OpenAI derives from the URL. Omitted, the host
supplies a default, "typically per-conversation".

Tool linkage is `_meta.ui` on a `Tool`: `resourceUri` names the `ui://` resource, and
`visibility` is an array of `"model"` and `"app"` defaulting to `["model","app"]`. An
`"app"`-only tool is hidden from the agent's tool list but remains callable by the app
over the same server connection; the specification presents this as the mechanism for
refresh buttons and form submissions. The flat `_meta["ui/resourceUri"]` key is
**deprecated** and slated for removal before general availability.

The rendering flow has four steps: the host preloads the `ui://` resource before the tool
is called, which enables streaming tool inputs; the host fetches it through
`resources/read`; the host renders it in a sandboxed iframe; and the two sides exchange
bidirectional JSON-RPC over `postMessage`. In that exchange the iframe is the MCP
*client* and the host is an MCP *server* that may proxy the real server. Shared core
methods are `tools/call`, `resources/read`, `notifications/message` and `ping`. The
lifecycle is `ui/initialize` then `ui/notifications/initialized`. The full method surface
is app-to-host requests `ui/open-link`, `ui/message`, `ui/request-display-mode` and
`ui/update-model-context`; host-to-app notifications `ui/notifications/tool-input`,
`ui/notifications/tool-input-partial`, which streams 0..n partial-JSON messages with
unclosed structures auto-closed, `ui/notifications/tool-result` and
`ui/notifications/tool-cancelled`; view-to-host notifications
`ui/notifications/size-changed` and `ui/notifications/host-context-changed`; and the
host-to-view request `ui/resource-teardown`, to which the host should wait for a response
to prevent data loss. A reserved sandbox-proxy pair carries the HTML across the iframe
boundary: `ui/notifications/sandbox-proxy-ready` from the proxy to the host, and
`ui/notifications/sandbox-resource-ready` from the host to the proxy, carrying the raw
HTML, an optional sandbox override, the CSP and the permissions. The protocol version
negotiated in `ui/initialize` is the extension's own `2026-01-26`, distinct from the core
revision.

`McpUiInitializeResult` returns `HostCapabilities` — `openLinks`, `serverTools`,
`serverResources`, `logging`, `sandbox` (carrying `permissions` and `csp`) and
`experimental` — alongside a `HostContext` of `toolInfo`, `theme` (`light` or `dark`),
`styles.variables` holding a standardized set of roughly sixty CSS custom properties,
`styles.css.fonts` for `@font-face` and `@import` injection, `displayMode`,
`availableDisplayModes`, `containerDimensions`, `locale` as BCP 47, `timeZone` as an IANA
name, `userAgent`, `platform` as `web`, `desktop` or `mobile`, `deviceCapabilities`
carrying `touch` and `hover`, and `safeAreaInsets`. Container dimensions fix each axis
independently as `width` or `height`, as `maxWidth` or `maxHeight`, or leave it unbounded.
An app declares its `appCapabilities.availableDisplayModes` from `inline`, `fullscreen` and
`pip`, and the host must not switch to a mode the app did not declare.

The theme variables are the
`--color-background-{primary,secondary,tertiary,inverse,ghost,info,danger,success,warning,disabled}`
family, the full `--color-text-*`, `--color-border-*` and `--color-ring-*` families,
`--font-{sans,mono}`, four `--font-weight-*` values, the `--font-text-*-size` and
`--font-heading-*-size` scales with their line heights, `--border-radius-{xs..full}`,
`--border-width-regular` and `--shadow-{hairline,sm,md,lg}`.

**Security model.** The sandbox is a browser iframe: the app cannot reach the parent DOM,
host cookies or local storage, cannot navigate the parent, and cannot run scripts in the
parent context. All communication is `postMessage`. The host constructs the CSP from the
declared domains, and when `ui.csp` is omitted a mandatory restrictive default applies:

```
default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';
img-src 'self' data:; media-src 'self' data:; connect-src 'none';
```

The host may further restrict but must not allow undeclared domains, and should log CSP
configurations for audit. A **double-iframe sandbox proxy is mandatory for web hosts**:
host and sandbox must have different origins, the sandbox receives `allow-scripts
allow-same-origin`, the host ships the HTML via `sandbox-resource-ready`, the sandbox
enforces the CSP, sets `object-src 'none'` and forwards all non-`ui/notifications/sandbox-*`
messages in both directions, and the host must not send anything to the view before
receiving `initialized`. Host-side mediation is explicit: the host may block any app
message or subject it to further user approval. Cross-server tool calls are always blocked
for `"app"`-only tools.

Two pre-standard lineages were folded in: MCP-UI's `iframe-ready` handshake with
external-URL and remote-DOM content types, and OpenAI's Apps SDK, launched November 2025.
MCP-UI's `@mcp-ui/client` remains a supported alternative host framework, and OpenAI ships
`migrate-oai-app` as a first-class skill.

What ships it: `ext-apps` under Apache 2.0, npm `@modelcontextprotocol/ext-apps` v2 with
subpackages `/react` for hooks, `/app-bridge` for host-side iframe rendering, tool-call
proxying and security policy enforcement, and `/server` for tool and resource
registration. The wire protocol is unchanged between 1.x and 2.x. The repository ships a
`basic-host` reference host, roughly twenty example servers, six starter templates
(React, Vue, Svelte, Preact, Solid and vanilla) and four Agent Skills: `create-mcp-app`,
`migrate-oai-app`, `add-app-to-server` and `convert-web-app`. Generated API documentation
is published at `apps.extensions.modelcontextprotocol.io`.

#### Tasks

Identifier `io.modelcontextprotocol/tasks`, from SEP-2663 (Final, Extensions Track),
shipped with the `2026-07-28` revision. Capability is declared per request. Creating a
task returns a `CreateTaskResult` with `resultType: "task"`, a `taskId`, a `ttlMs` and a
`pollIntervalMs`. Five statuses exist. `tasks/get` reads state, `tasks/update` supplies
mid-flight input, and `tasks/cancel` is cooperative. `notifications/tasks` is gated
behind `subscriptions/listen`, so task notification delivery depends on a subscription
mechanism that itself arrived in the same revision. The rationale for a durable handle
rather than an open session is that the core protocol no longer has one. The five status
values are **NOT ESTABLISHED IN SOURCE**: the overview page names the count, not the
enumeration.

#### Enterprise-Managed Authorization

Identifier `io.modelcontextprotocol/enterprise-managed-authorization`, from SEP-990
(Final). The flow is **ID-JAG**: the identity provider issues an Identity Assertion JWT,
which the client exchanges at the MCP authorization server for an access token. Policy is
centralized, revocation is immediate and centralized, and the extension ships
implementation checklists for clients, servers and authorization servers plus
account-linking guidance. The framing on the roadmap is that "MCP authorization assumes a
person with a browser at consent time", which is increasingly false; agent identity and
delegation via Workload Identity Federation (SEP-1933), ID-JAG and RFC 8693 token
exchange are the coordinated deliverables, alongside IETF OAuth and WIMSE.

#### Skills over MCP

Identifier `io.modelcontextprotocol/skills`, from SEP-2640 (Final, Extensions Track). The
surface is `skills/list` and `skills/get`, with content served through `resources/read`
for `skill://` URIs. A server must hold the `resources` capability and declare the
extension with its `directoryRead` setting. Manifests carry SHA-256 digests, and identity
is the tuple of server identity plus URI. The documentation states plainly that "SDK and
host support is still being implemented".

#### OAuth Client Credentials

Identifier `io.modelcontextprotocol/oauth-client-credentials`, from SEP-1046 (Final),
living in the `ext-auth` repository alongside Enterprise-Managed Authorization. Its
identifier is the one the framework documentation uses as its worked example. The grant
mechanism, the settings object and the negotiation behaviour are **NOT ESTABLISHED IN
SOURCE**: the extension's specification page was not read during this research, and only
its repository layout and originating SEP are recorded here. Host support is thin — two
clients implement the two auth extensions between them.

### The MCP Registry

`modelcontextprotocol/registry`, Go with PostgreSQL, deployed via Pulumi, images at
`ghcr.io/modelcontextprotocol/registry`. It is **still in preview**: all eight registry
documentation pages carry the banner "currently in preview. Breaking changes or data
resets may occur before general availability." The OpenAPI version is `2025-12-01` under
the MIT licence, and the live `server.json` schema is still pinned at
`https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json`, a
2025-12-11 artefact still in service nearly a year later.

**API.** Unauthenticated, read-only REST at `https://registry.modelcontextprotocol.io`.

| Endpoint | Parameters |
| --- | --- |
| `GET /v0.1/servers` | `cursor`, `limit`, `search` (name substring), `updated_since` (RFC 3339), `version` (exact or `latest`), `include_deleted` |
| `GET /v0.1/servers/{serverName}/versions` | — |
| `GET /v0.1/servers/{serverName}/versions/{version}` | — |

Path parameters must be URL-encoded, `io.github.user%2Fserver`. The live instance also
serves `/v0/servers`, `/docs` as FastAPI/Swagger, and `/openapi.yaml`. The response
envelope is:

```json
{
  "servers": [
    {
      "server": {},
      "_meta": {
        "io.modelcontextprotocol.registry/official": {
          "status": "", "statusChangedAt": "", "publishedAt": "", "updatedAt": "", "isLatest": true
        }
      }
    }
  ],
  "metadata": { "count": 0, "nextCursor": "" }
}
```

The registry is deliberately unopinionated metadata: name, description, title, version,
`repository`, `websiteUrl`, `packages[]` covering npm, PyPI, OCI, mcpb, NuGet and Cargo
each with a `transport`, `remotes[]` carrying `streamable-http` entries with `headers[]`
of `name`, `isRequired`, `isSecret` and `description`, and `_meta`.

**Publishing authentication — four methods:** GitHub OAuth for interactive flows, GitHub
OIDC from GitHub Actions, DNS verification and HTTP verification. Namespace enforcement is
the trust model. Publishing `io.github.domdomegg/my-cool-mcp` requires logging in as
`domdomegg` or running in an Action on their repositories; publishing
`me.adamjones/my-cool-mcp` requires proving `adamjones.me` by DNS or HTTP challenge.
Publishers may attach `_meta["io.modelcontextprotocol.registry/publisher-provided"]` custom
metadata, capped at 4 KB.

**Moderation is deliberately minimal**, and says so.

| Removed | Explicitly not removed |
| --- | --- |
| Illegal content | Low-quality or buggy servers |
| Malware, regardless of intent | Servers with security vulnerabilities |
| Spam: duplicate submissions under different names, fixed-response marketing servers, description-stuffed marketing over unrelated implementations | Servers that duplicate others |
| Non-functioning servers | Adult content |

The disclaimer is stronger than the policy: *"The MCP Registry does not make guarantees
about moderation, and consumers should assume minimal-to-no moderation… limited active
moderation capabilities."* Removal is a soft delete: `status` becomes `"deleted"` but the
metadata stays API-accessible, and in extreme cases metadata may be overwritten. Security
scanning is delegated entirely to upstream package registries — npm, PyPI, Docker Hub — and
to downstream aggregators. Spam controls are namespace authentication, character limits
and regex validation, and manual takedown. Rate limiting, AI spam detection and community
reporting are recorded as under consideration.

**Structural constraints.** There is no unpublish capability
([open issue #104](https://github.com/modelcontextprotocol/registry/issues/104)); only
maintainers can remove an entry. Version metadata is immutable in npm fashion, so a bad
release must be superseded rather than withdrawn. The codebase is not designed for
self-hosting and maintainers cannot support forks; enterprises wanting private registries
must run their own. The registry is **not intended to be consumed directly by host
applications** — hosts are told to consume a downstream marketplace implementing the same
OpenAPI spec. Private servers are explicitly out of scope.

**The aggregator contract** is the three read endpoints above, cursor pagination,
`updated_since` filtering, `status` semantics, and an `_meta` injection pattern for
subregistries, under an explicit "no uptime or data durability guarantees" statement.

**Who runs it.** Registry Working Group: Radoslav "Rado" Dimitrov (Stacklok) as lead,
Tadas Antanavicius (PulseMCP), Bob Dickinson (TeamSpark) and Preeti "Pree" Dewani
(Ravenmail). It was seeded in February 2025 by David Soria Parra and Justin Spahr-Summers
asking PulseMCP and Goose to build it. The founding maintainers spanned Anthropic, GitHub,
Block, VS Code, NuGet and Microsoft, and the registry documentation names Anthropic, GitHub,
PulseMCP and Microsoft as the major trusted contributors.

#### Registry size, and the dedup disagreement

The registry publishes no official count, and the read API returns only a page-local
`metadata.count`. Every public figure is therefore third-party, and the two credible ones
disagree on exactly one question: whether version records or distinct servers are being
counted.

| Source | Date | Method | Distinct servers | Records | Other |
| --- | --- | --- | --- | --- | --- |
| [Circadian](https://circadian-agent.com/research/mcp-registry) | 2026-07-25 | Full crawl, published crawler and dataset, collapsed on `_meta."io.modelcontextprotocol.registry/official".isLatest` | **18,387** | 58,230 version records | 18,200 active, 187 deprecated |
| [MCP Registry Tracker (CatchMetrics)](https://mcp-tracker.martinalderson.com/) | 2026-06-22 | Counts records, not distinct servers | — | **40,506** "servers" | 30,564 stdio, 13,412 remote, 348 new in the last day |

Neither figure is verifiable against a primary source, because none exists.
[UNVERIFIED] The registry itself publishes no number, so both are third-party.

The Circadian crawl is the more detailed of the two and carries the composition data.

| Measure | Value |
| --- | --- |
| Distinct namespaces | 11,438 |
| Under `io.github.*` | 72.3 % (13,288) — a GitHub account, not a verified company domain |
| Largest non-GitHub namespace | Smithery, 213 |
| Servers with exactly one published version | 60.7 % (11,157) |
| Remote-only, no installable package | 46 % (8,425), and the fastest-growing segment |
| Remote share of new servers, Q1 2026 | ~25 % |
| Remote share of new servers, April 2026 | 50.8 % |
| Remote share of new servers, July 2026 | 58.9 % |
| Package mix | npm 6,384; PyPI 2,844; OCI 618; mcpb 384; NuGet 86; Cargo 11 |
| Monthly new servers | 456 (September 2025) → 4,523 (July 2026), roughly 167/day |

The Circadian source carries a self-correction notice — a retraction for an earlier
npm-lookup error — and explicitly disclaims authority. Its npm-distribution section
survives the retraction with the caveat that CI and mirrors inflate the measure.

### The SEP process

SEPs are the primary change mechanism, and there are **42 Final**. The status ladder is
Draft (has a sponsor, informal review), proposal (no sponsor), In-Review, Accepted
(awaiting a reference implementation), Final, Rejected, Withdrawn, Superseded and
**Dormant** (no sponsor, auto-closed after six months). Four tracks exist: Standards
Track, **Extensions Track** (SEP-2133's new type — same review process, different
target), Process and Informational.

Numbering is the pull request number in `modelcontextprotocol/modelcontextprotocol`. Since
**SEP-1850** (Final, 2025-11-20) established the pull-request-based workflow, a SEP *is* a
pull request: new proposals open a canonical PR in the main repository with a `0000-`
placeholder filename until a number is assigned. **SEP-2484** (Final) requires conformance
tests for Standards Track SEPs to reach Final. Two live dashboards exist,
`plan.modelcontextprotocol.io/seps` for status and `voting.modelcontextprotocol.io/seps`
for the review queue.

**In-flight proposals** as of 2026-09-29, from the 44 open SEP-labelled pull requests.

| SEP | Title | Status | Note |
| --- | --- | --- | --- |
| SEP-3398 | Release Cycle Updates | Draft, Process, opened 2026-09-28 | Release cadence; see below |
| SEP-3392 | Extension Lifecycle | Draft, opened 2026-09-25 | Maturity ladder |
| SEP-3371 | Consistent SDK extension points | Draft, opened 2026-09-18 | Three public SDK extension points |
| SEP-2127 | MCP Server Cards — HTTP Server Discovery | In-Review, 250 days | Discovery is unsettled |
| SEP-1862 | Tool Resolution | Draft | |
| SEP-2564 | Server-Side Filtering for List Methods | Draft | |
| SEP-2202 | Non-File URI Schemes for Roots | Draft | |
| SEP-1984 | Comprehensive Tool Annotations | Draft | |
| SEP-1913 | Trust and Sensitivity Annotations | Draft | |
| SEP-1932 | DPoP Profile | Draft | |
| SEP-1933 | Workload Identity Federation | Draft | |
| SEP-2448 | MCP server execution telemetry | Draft | |
| SEP-2343 | Elicitation requires authorization for remote servers | Draft | |
| SEP-2778 | Type Constraints | Draft | |
| SEP-2792 | Per-Request User Language Preference | In-Review | `io.modelcontextprotocol/acceptLanguage` plus `contentLanguage`, RFC 4647 |
| SEP-2200 | Clarify tool result content visibility | In-Review | Direct cause of the roadmap's tool-result-shape item |
| SEP-2145 | Standardize `tools/call` failure reporting | In-Review | |
| SEP-2293 | Completions Metadata | In-Review | |
| SEP-2557 | Adapt Tasks for Stateless & Sessionless Protocol | In-Review | |
| SEP-2356 | File input support | In-Review | |
| SEP-1336 | User Agent Guidance | In-Review | |
| SEP-2631 | File Objects and Transfer | Proposal, 45 👍 | The most-upvoted open proposal |
| SEP-2817 | AI Invocation Audit Context in `_meta` | Proposal, 42 comments | |
| SEP-2848 | Asynchronous Approval for Tool Calls | Proposal | `io.modelcontextprotocol/tool-approval`, built on Tasks |
| SEP-2624 | Interceptors | Proposal | Has an `experimental-ext-interceptors` repo |
| SEP-2752 | HTTP Message Signing | Proposal | RFC 9421 |
| SEP-2809 | Attested Tool-Server Admission (ATSA) | Proposal | |
| SEP-2793 | Tool Risk Metadata | Proposal | |
| SEP-2694 | Resumable Task Event Streams | Proposal | |
| SEP-2643 | Structured Authorization Denials | Proposal | |
| SEP-3149 | Require `token_endpoint_auth_methods_supported` in CIMD | Proposal | |
| SEP-3279 | Negotiated Tool Result Variants | Proposal | |
| SEP-3313 | Structured Tool-Failure Classification | Proposal | `io.modelcontextprotocol/toolFailure` |
| SEP-2633 | Standard Client-Side Configuration Format `mcp.json` | Proposal | |
| SEP-2787 | Tool call attestation | Proposal | |
| SEP-2093 | Resource Contents Metadata and Capabilities | **Rejected** | The only rejection on record |
| SEP-1821 | Dynamic tool search | **Dormant** | |
| SEP-1905 | Task result streaming | **Dormant** | |
| SEP-1904 | Filtering for `tasks/list` | **Dormant** | |
| SEP-1921 | Context headers | **Dormant** | |
| SEP-1975 | Conversation event subscriptions | **Dormant** | |
| SEP-2001 | HA patterns | **Dormant** | |
| SEP-1803 | Event subscriptions | **Dormant** | |
| SEP-1404 | Versioning guidelines | **Dormant** | |
| SEP-2598 | Pluggable Transports | Deferred label | |

Seven proposals carry no sponsor and sit in `proposal` indefinitely: SEP-3094 Granular
Citations, SEP-2817, SEP-2624, SEP-2631, SEP-2752, SEP-2809 and SEP-2793.

#### Release cadence

**SEP-3398 (Release Cycle Updates)** — PR #3398, Draft, Process type, author Kurtis Van
Gent, opened **2026-09-28**, sponsored by the Core Maintainers as a group. It formalises
what the Core Maintainers agreed at MCPCon Europe.

| Rule | Value |
| --- | --- |
| Cadence | Every six months, **March and September** |
| Cycle length | Eight months, overlapping |
| Cycle shape | Two months planning, a Core Maintainer review window opening at 6 months and closing at 2.5 months, then stabilization |
| Release managers | Rotating primary/secondary pair |
| Planning starts | 8 months out |
| CM review opens | 6 months out |
| Soft freeze | 2.5 months out — all release-bound SEPs Final *and merged*, including spec text, schema, changelog, reference implementation and conformance tests |
| Next-cycle planning | 2 months out |
| SDK beta | 1.5 months out, Tier 1 required |
| Hard freeze | 1 month out — only critical security or release-blocking correctness/interop defects, by full Core Maintainer vote |
| Release | 0 |
| Sponsorship | A WG or the CM group must sponsor before formal review |
| Voting | Recorded seven-calendar-day vote in the maintainer Discord; affirmative votes from **more than half of all eligible Core Maintainers**; abstentions and absences do not count, and a majority of meeting attendees is explicitly insufficient |
| Change during voting | Returns the proposal |
| Transition | Moves the previously targeted December 2026 release to **March 2027**; the first cycle reuses the planning done in August 2026 |

The SEP's own open questions are the exact target date, its alignment with AgentCon NA
2027, and how to handle emergency votes with fewer than seven days remaining. As of the
research date it is **a draft, three days old and unadopted**, so the March 2027 date is a
proposal, not a commitment. No committed next-release date exists. The date of the
MCPCon Europe at which the cadence was agreed is **NOT ESTABLISHED IN SOURCE**.

### The roadmap

Last updated **2026-08-22**. Five priority areas, each naming its accountable Core
Maintainers, and an explicit statement that review time is scarce and spent inside them
first: SEPs outside the five areas face a longer queue and a higher bar for
justification.

| Priority area | Core Maintainers | Deliverables |
| --- | --- | --- |
| Agentic Messaging Primitives | Caitie McCaffrey, Clare Liguori, Peter Alexander | Server-initiated events via the Triggers & Events WG — channels, subscriptions, webhooks, to avoid expensive client-side polling; a composition review across Tasks, `subscriptions/listen` and progress notifications. The stated risk: three answers to "the server isn't done yet" that share no lifecycle, cancellation model or error surface |
| HTTP-Native Transport Unification | Kurtis Van Gent, Nick Cooper | HTTP over stdio with Streamable HTTP as the single binding and HTTP/2 over stdin/stdout; ETags for caching tool-call results; standardized error handling; capability scoping for tool lists after SEP-2575; secure server configuration |
| Agent Identity and Enterprise-Ready Security | Paul Carleton, Den Delimarsky | DPoP finalization; agent identity and delegation via Workload Identity Federation (SEP-1933), ID-JAG and RFC 8693 token exchange, coordinated with IETF OAuth and WIMSE; human-presence attestation under discussion |
| Improved Primitives | Kurtis Van Gent, Peter Alexander, Den Delimarsky | A `tools/call` redesign, motivated by `content` and `structuredContent` together having "confused server and client authors alike and produced diverging implementations"; progressive discovery; primitive annotations extended or, if not useful, deprecated |
| Improved SDK Developer Experience | Den Delimarsky, David Soria Parra | Generating a candidate Tier 1 SDK and quickstarts from the specification plus a human-reviewed conformance suite; the extension contract, covering which role an extension binds, what SDKs must support natively, how extensions are packaged, and auth as its own area |

The page carries an explicit caveat that it "reflects current thinking rather than firm
commitments", and a 6–12 month horizon, consistent with a March 2027 target.

## What changed recently

The core revision is two months old on the research date. Everything below moved inside
that window, or was announced inside it and has not yet landed.

| Date | Change | Status |
| --- | --- | --- |
| 2025-09-08 | MCP Registry preview announced, with founding maintainers across Anthropic, GitHub, Block/Goose, PulseMCP, VS Code, NuGet and Microsoft, and an explicit warning that data durability is not guaranteed before GA | In force |
| 2025-10-24 | Registry API freeze at v0.1 | In force; v0.x still live on 2026-09-29 |
| 2025-11-20 | SEP-1850 makes the SEP a pull request | Final |
| 2025-11-25 | Last handshake-based, session-carrying core revision | Superseded by `2026-07-28` |
| 2026-01-23 | SDK conformance test suite becomes available | In force |
| 2026-01-26 | MCP Apps spec version `2026-01-26` marked Stable; VS Code announces MCP Apps support | In force |
| 2026-02-23 | SDK tier assignments published | In force |
| 2026-03-03 | Cursor 2.6 ships "MCP Apps and Team Marketplaces for Plugins" | Shipped |
| 2026-07-28 | Core protocol revision `2026-07-28`; stateless, no handshake, MRTR replaces server-initiated requests | Current stable |
| 2026-08-22 | Roadmap last updated; five priority areas with named Core Maintainers | Current |
| 2026-08-31 | Security IG restructured as a routing/triage group (#3331) | Open PR |
| 2026-09-15 | PR #3364 opened to restore the `2025-11-25` `initialize` extension-negotiation examples | Open |
| 2026-09-16 | VS Code MCP documentation page last dated | Current |
| 2026-09-21 | Primitive Grouping IG agreed to become Progressive Disclosure WG (#3376) | Open PR |
| 2026-09-23 | File Uploads WG and Filesystems WG agreed to merge into a Files WG (#3389) | Open PR |
| 2026-09-25 | SEP-3392 Extension Lifecycle opened | Draft |
| 2026-09-28 | SEP-3398 Release Cycle Updates opened | Draft |

**SEP-3392 Extension Lifecycle** (PR #3392, Draft, author `pja-ant`, opened 2026-09-25,
labels `SEP`/`draft`/`extension`) is the in-flight answer to the missing-registry problem.
It proposes a maturity ladder **Experimental → Beta → Stable (as extension) or promoted to
core**, encoded in the repository *name*: `experimental-ext-<name>`, `beta-ext-<name>`,
`ext-<name>`.

| Stage | What changes | Gate |
| --- | --- | --- |
| Experimental | Iterates on Extension Maintainer approval only and may break | Tied to a WG or IG |
| Beta | May still break | Entering Beta requires an Extensions Track SEP |
| Stable as extension | Changes only with a new core protocol revision | Entering Stable requires an Extensions Track SEP |
| Promoted to core | Standards Track SEP with a defined migration; clients keep advertising the extension identifier while they support earlier revisions | Standards Track |

It would replace SEP-2133's "every breaking change needs a new identifier" rule, answer
the open feature-maturity question in SEP-2596, and extend SEP-2484's conformance
requirement to the promotion SEPs. Its proposed *Transition* section classifies `ext-apps`
and `ext-auth` as **Stable**, `ext-skills` and `ext-tasks` as **Beta**, and
`ext-server-card` Beta once SEP-2127 is accepted. The PR states that this classification
"is a proposal for the Core Maintainers". [UNVERIFIED] — not adopted as of the research
date.

**SEP-3371 Consistent SDK extension points** (PR #3371, Draft, author sambhav, opened
2026-09-18, assigned to felixweinberger) defines three public SDK extension points so
extension owners can ship independent packages: registration plus capabilities plus
dependencies; custom RPC methods, with method-name-conflict and handler-replacement
rejection; and middleware. It addresses the roadmap's "extension contract" item directly.

**Group churn in flight.** File Uploads WG plus Filesystems WG merging into one Files WG
(#3389, Den Delimarsky, 2026-09-23), resolving a live collision between SEP-2631's
`files/*` method family and the SEP-2532/SEP-2571 resource-write model; Primitive Grouping
IG becoming Progressive Disclosure WG (#3376, agreed 2026-09-21); the Security IG
restructured as a routing/triage group (#3331, 2026-08-31); and a full community-docs
restructure (#3363, draft). [INFERENCE] Group structure is being consolidated around the
roadmap's five priority areas, and the Files WG merge is the clearest evidence that the
`files/*`-versus-Resources question is genuinely contested.

**Registry drift.** The registry's OpenAPI document is dated `2025-12-01` and the live
`server.json` schema `2025-12-11`, both unchanged through 2026-09, while v0.1 has now been
frozen for eleven months without reaching general availability.

**Vendor-side momentum ahead of the calendar.** Amazon Bedrock AgentCore's documentation
is already written against `2026-07-28` behaviour, so at least one ecosystem implementer
is building against the current release rather than the legacy one.

## Evidence of adoption

### SDK install volume

Measured directly on 2026-09-29 from the npm downloads API and pypistats.

| Package | Registry | Window | Downloads |
| --- | --- | --- | --- |
| `@modelcontextprotocol/sdk` | npm | 2026-09-21 → 2026-09-27 | 64,725,178 |
| `@modelcontextprotocol/sdk` | npm | 2026-08-29 → 2026-09-27 | 202,740,901 |
| `mcp` | PyPI | last day | 8,771,550 |
| `mcp` | PyPI | last week | 54,995,266 |
| `mcp` | PyPI | last month | 219,043,071 |

The TypeScript SDK runs at roughly 9.2M downloads a day. The combined official-SDK
surface is around 97M monthly installs, consistent with the "97M+ monthly SDK installs"
figure circulating in third-party ecosystem trackers. [INFERENCE] These counts include CI
and mirror traffic, so they measure distribution, not distinct users.

Registry-side npm distribution is far more long-tailed. Of npm-declaring servers
resolvable at census time, the median had 413 downloads a month, 79.5 % were under
1,000 a month, and the top 10 took 80.2 % of all 35.3M monthly npm downloads, with
ChromeDevTools (`chrome-devtools-mcp`, 10.2M/month) and Firebase (`firebase-mcp`,
9.6M/month) alone taking 55 %.

### Host support, per vendor documentation

| Host | Transports | Core primitives | Revision tracked | Notes |
| --- | --- | --- | --- | --- |
| Claude, Claude Desktop, Claude Code | Streamable HTTP, legacy HTTP+SSE, stdio, plus `ws` in Claude Code | Tools, Prompts, Resources | **2025-11-25** authorization specs | Resource subscriptions and sampling explicitly unsupported. See below |
| VS Code + GitHub Copilot | stdio, Streamable HTTP | Tools, Prompts, Resources; MCP Apps render inline | 2026-07-28-era | See below |
| Cursor | stdio, SSE, Streamable HTTP | Tools, Prompts, Resources, **Roots**, **Elicitation**, Apps | 2026-07-28-era | Broadest core-primitive list found |
| Zed | stdio, HTTP | **Tools and Prompts only** | **2025-11-25** | Discovery, Sampling, Elicitation unsupported |
| Gemini CLI | stdio, SSE, Streamable HTTP | Tools, Prompts, Resources | 2026-07-28-era | See below |
| JetBrains AI Assistant 2026.2 | STDIO, Streamable HTTP | Not itemised | Not stated | No MCP Apps support documented |
| OpenAI ChatGPT and Codex | Not stated | Plugins, MCP Apps, a bounded Skills subset | 2026-07-28-era | See below |
| Microsoft Foundry | Public and private endpoints | `mcp` tool; MCP tasks in preview | 2026-07-28-era | See below |
| Amazon Bedrock AgentCore | Streamable HTTP only | Hosted servers, `POST /mcp` | **2026-07-28** | The only vendor documenting MRTR |
| Cloudflare | Streamable HTTP for remote, stdio for local | Hosted servers | 2026-07-28-era | Publishes tool-design guidance |

**Claude / Claude Desktop / Claude Code.** One connector infrastructure spans claude.ai,
Claude Desktop, Claude mobile, Cowork and Claude Code. Supports Tools, Prompts and
Resources; text and image tool results; text and binary resources. **Explicitly
unsupported: resource subscriptions and sampling.** The OAuth client follows only the
2025-03-26, 2025-06-18 and 2025-11-25 authorization specifications — Claude has not
moved to the `2026-07-28` revision. Limits: roughly 150,000 characters per tool result and
240 s per tool call on hosted surfaces; 25,000 tokens via `MAX_MCP_OUTPUT_TOKENS` and
`MCP_TOOL_TIMEOUT` in Claude Code. Redirect URI
`https://claude.ai/api/mcp/auth_callback`. Distribution is the reviewed Anthropic
Directory, alongside custom connectors, Claude plugins and local desktop extensions
packaged with MCPB. `code.claude.com/docs/en/mcp` documents a fourth transport, `ws`,
with persistent push, header-only auth and no OAuth; a discovery cache reporting
`cached Nh ago · connects on first use · N tools` behind `MCP_DISCOVERY_CACHE`; reserved
built-in server names (`workspace`, `claude-in-chrome`, `computer-use`, `Claude Preview`,
`Claude Browser`); and project-scope `.mcp.json` approval gated on workspace trust, "a
cloned repository can't approve its own servers".

**VS Code + GitHub Copilot.** A first-class `@mcp` server gallery in the Extensions view,
installable per user or into a workspace. Two config formats coexist: `.vscode/mcp.json`
with a top-level `servers`, and the portable `.mcp.json` with a top-level `mcpServers`.
`code --add-mcp` is the CLI. `chat.mcp.discovery.enabled` reuses configurations from Claude
Desktop, GitHub Copilot CLI, Cursor and Windsurf. The Agent Host is a separate execution
surface that does not read `.vscode/mcp.json`; it reads workspace `.mcp.json` and user
`~/.copilot/mcp-config.json` natively, with VS Code forwarding eligible configurations
and skipping servers needing interactive `${input:…}`. stdio sandboxing on macOS and
Linux via `sandboxEnabled: true` with a `sandbox` object carrying filesystem `allowWrite`
and network `allowedDomains`; when sandboxed, tool calls are **auto-approved** because
they run in a controlled environment. Not available on Windows.
`chat.mcp.autostart` takes `never`, `onlyNew` or `newAndOutdated`. Enterprise
management is through GitHub policies.

**Cursor.** MCP Marketplace with OAuth, community servers via cursor.directory, and team
marketplaces. `mcp.json` at `~/.cursor/mcp.json` and `.cursor/mcp.json`, plus `envFile` for
stdio. Static OAuth with `CLIENT_ID`, `CLIENT_SECRET` and `scopes` for providers without
DCR, on fixed redirect URLs `https://www.cursor.com/agents/mcp/oauth/callback` and
`http://localhost:8787/callback`. The registration extension API is
`vscode.cursor.mcp.registerServer()`. Enterprise MCP Allowlist covering command-pattern
approvals for stdio, URL-pattern for remote and per-tool allowlists, plus per-server
network modes of allow all, allowlist, deny all or no sandbox. The documentation states
that "MCP Apps follow progressive enhancement: if a host cannot render app UI, the same
tool still works through normal MCP responses."

**Zed.** MCP servers install as extensions from the Zed marketplace or as custom
`context_servers`. Remote servers with no `Authorization` header trigger the standard MCP
OAuth flow. Per-tool permission keys are `mcp:<server>:<tool_name>`, for example
`mcp:github:create_issue`. Configured servers are forwarded to External Agents over ACP.
The page still links to the 2025-11-25 spec pages for tools and prompts, which is the lag
indicator.

**Gemini CLI.** `mcpServers` config with `mcp.allowed`/`mcp.excluded` global filters,
per-server `trust`, `includeTools`/`excludeTools` allowlists where exclude wins, `timeout`
defaulting to 600,000 ms, `cwd`, and `authProviderType: 'service_account_impersonation'`
with `targetAudience` and `targetServiceAccount` for Google Cloud IAP. Resources are
discovered automatically and referenceable as `@server://resource/path`. It also
sanitises the environment by default: `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*KEY*`,
`*AUTH*`, `*CREDENTIAL*`, certificates and private keys are redacted from the inherited
base environment before a server process is spawned, and only explicitly configured `env`
entries escape redaction. Automatic OAuth discovery on 401.

**JetBrains.** AI Assistant 2026.2, STDIO and Streamable HTTP, configured under Settings |
Tools | AI Assistant | MCP, with per-server global-versus-project scope and logs under the
IDE `mcp` folder. Since 2025.2 the IDEs also run an integrated MCP Server, exposing IDE
tools to Claude Code, Codex, VS Code and others — the IDE-as-server direction.

**OpenAI.** MCP servers are how a ChatGPT or Codex plugin reaches live data,
authentication and controlled actions, and UI is optional: "The server defines the tools
available to ChatGPT and Codex. It does not need to return custom UI." ChatGPT ships MCP
Apps and a bounded static subset of Skills. An implementing server must declare
`io.modelcontextprotocol/skills` in `capabilities.extensions` — explicitly not the earlier
`experimental` key — implement paginated `skills/list` and `skills/get` with `skill://` URIs
and per-resource `sha256:<64 hex>` digests, and serve every listed URI through
resources/read`.

| Importer limit | Value |
| --- | --- |
| Skills per submission | 5 |
| Catalog pages | 10 |
| Files per skill | 100 |
| `SKILL.md` | 256 KiB |
| Per supporting file | 1 MiB |
| Per skill | 5 MiB |
| Archive per scan | 8 MiB |

Imports are submission-time snapshots, not live. The profile convention is
`_meta["openai/profile"]: true`. The documentation requires accurate `annotations` and
insists authorization be enforced server-side, never relying on the model.

**Microsoft Foundry.** A first-class `mcp` tool across Python, C#, JavaScript, Java and
REST, on both Basic and Standard agent setups. Public and private endpoints; private
requires a dedicated MCP subnet on Azure Container Apps delegated to
`Microsoft.App/environments`. Foundry Toolboxes bundle Web Search, Code Interpreter, File
Search, Azure AI Search, MCP servers, OpenAPI tools and A2A behind a **single
MCP-compatible endpoint** consumable by Foundry Agent Service, Microsoft Agent Framework,
LangGraph and the GitHub Copilot SDK. Seven auth types: `none`, `custom-keys`, `oauth2`
with Foundry-managed connector names for 11 named servers including `foundrygithubmcp`,
`foundryneonmcp` and `foundryvercelmcp`, `user-entra-token`,
`project-managed-identity`, `agentic-identity` for the agent's per-project identity, and
scopes. Toolbox endpoints support long-running operations through MCP tasks, labelled
**preview**. First consent raises a `CONSENT_REQUIRED` error with code **`-32006`** and a
consent URL.

**Amazon Bedrock AgentCore.** MCP servers deploy as ARM64 containers on `0.0.0.0:8000`
with `POST /mcp`, Streamable HTTP required. Stateless is the default
(`stateless_http=True`); stateful (`stateless_http=False`) enables elicitation and
sampling. microVM stickiness is provided by `Mcp-Session-Id`, and container and session
lifecycle is AgentCore Sessions. The version-dependent state requirement is documented
explicitly: for `2025-11-25` and earlier, elicitation and sampling require stateful
sessions because the server delivers those requests over an open session; for
`2026-07-28` and later they use the MRTR pattern and no longer require stateful mode.
JSON-RPC-to-exception error mapping is documented for `-32001` through `-32011` and
`-32603`, the `Accept` header requirement returns 406 otherwise, and OAuth uses RFC 7235
`WWW-Authenticate` with `GetRuntimeProtectedResourceMetadata`.

**Cloudflare.** Remote MCP servers on Workers, remote via Streamable HTTP with OAuth and
local via stdio, plus published tool-design guidance: do not wrap the full API schema,
prefer fewer well-designed tools over many granular ones, deploy several narrowly-scoped
servers instead of one over-privileged one, write detailed parameter descriptions, and run
eval tests after every change.

### Extension support matrix

Community-maintained at
`modelcontextprotocol.io/extensions/client-matrix`.

| Extension | Implementations |
| --- | --- |
| MCP Apps | Claude (web), Claude Desktop, VS Code GitHub Copilot, Microsoft 365 Copilot, Goose, Postman, MCPJam, ChatGPT, Cursor, Archestra.AI, PostHog Code |
| Skills | ChatGPT (partial), fast-agent (partial), MCP Inspector (partial, skill verification), mcpc |
| Enterprise auth | Archestra.AI and mcpc only |
| Tasks | **Absent from the matrix entirely**, despite being Final and shipped |

### Registry consumers and subregistries

Consumers and subregistries named in the sources: Anthropic Directory, Cursor
Marketplace, the VS Code gallery, the GitHub MCP Registry, Smithery, PulseMCP,
cursor.directory, Glimind, and MCP Census. Microsoft runs an Enterprise Registry
subregistry, and Microsoft MCP Server for Enterprise was in public preview with the
endpoint `https://mcp.svc.cloud.microsoft/enterprise` [UNVERIFIED] — cited in the source
prose but not independently confirmed against a documentation page during this research.

Publishers named in the registry census: ChromeDevTools, Firebase, Upstash Context7,
Snyk, Telnyx, Callstack, SAP Fiori, Firecrawl, Vercel, Neon, Morningstar, LSEG,
Pipedream, Azure Databricks, GitHub, Notion, Microsoft, Atlassian, Sentry, Statsig,
Stripe, Figma.

**Operating groups.** 26 or more active Working Groups and Interest Groups had published
2026 meeting calendars: mcp-apps-wg, server-card-wg, server-identity-wg,
progressive-disclosure-wg, files-wg, filesystem-wg, triggers-events-wg, transports-wg,
interceptors-wg, registry-dev, skills-over-mcp-wg, inspector-v2-wg, sdk-wg, and the
auth-wg-tool-scopes, auth-wg-fine-grained-authz, auth-wg-mixup-protection, gateways-ig,
tool-annotations-ig, security-ig and finance groups.

## Sharp edges

### Extensions framework

1. **No extension registry.** Discovery is a hand-maintained docs page plus a
   PR-edited community matrix, and that matrix is already wrong: it omits the Final,
   shipped Tasks extension. There is no way to ask programmatically "what extensions exist
   and at what version".
2. **Versioning is unspecified and unimplemented on the wire.** SEP-2133 explicitly
   declines to specify an approach. Versions live in repository directory names. Nothing
   on the wire tells a peer which extension version is in play.
3. **Two incompatible negotiation flows.** Modern per-request `_meta` versus legacy
   `initialize` `capabilities.extensions`, with `extensions` absent from the older
   published schemas. PR #3364 is still open to document the legacy path. SDK support
   must be checked per protocol version.
4. **SEP-2133 declines three things on purpose**: schema-modification advertisement,
   inter-extension dependencies, and extension profiles. A request needing two
   extensions, or needing an extension to alter the tool schema, has no answer.
5. **SEP-3392 is unadopted and would reverse existing guidance.** Until it lands, the
   breaking-change rule is "new identifier"; after it lands, it is "capability flags or
   versioned settings", with maturity encoded only in a repository *name*.
6. **Extension support is optional for SDK conformance.** The tiering system explicitly
   carves extensions and experimental features out of every tier, so no conformance floor
   exists for any extension. The client matrix is the only coverage signal, and it is
   community-maintained and demonstrably incomplete.
7. **Extension maturity is essentially untracked.** Tasks and Skills are both Final SEPs
   shipped in or alongside `2026-07-28`, yet Skills' own documentation says SDK and host
   support "is still being implemented" and the matrix lists only three partial
   implementations.
8. **Every extension needs a WG or IG.** Unfunded or single-vendor ideas outside an
   existing group have no path to incubation.

### MCP Apps

9. `domain` is host-defined with no spec format, so OAuth callbacks and API-key
   allowlisting are non-portable; the two documented host patterns are unrelated.
10. `visibility: ["app"]` tools are hidden from the model but callable by the app over the
    same connection — a legitimate pattern per the spec, and a policy-bypass shape for
    hosts that do not surface it.
11. The mandatory default CSP still permits `script-src 'unsafe-inline'` and
    `style-src 'unsafe-inline'`.
12. The deprecated flat `_meta["ui/resourceUri"]` key is still in the Stable 2026-01-26
    spec with a "removed before GA" promise that has not been kept.
13. Two predecessors, MCP-UI and the OpenAI Apps SDK, were folded in; MCP-UI remains a
    supported alternative host framework, so "implement the postMessage protocol
    directly" versus "use `@mcp-ui/client`" is an unresolved fork. The `ext-apps` README
    states plainly that there is no *supported* host implementation in the repository
    beyond the `basic-host` example.
14. The specification itself calls out partial passing of colour variables as a clash
    hazard — "unexpected clashes may occur if hosts pass some color variables but not
    others" — and `prefersBorder` exists precisely because host defaults vary.
15. App SDK v2 renamed packages and requires `^2.0.0` peers, though the wire protocol is
    unchanged between 1.x and 2.x: a packaging migration with a compatibility promise and
    no version negotiation to enforce it.

### Registry

16. **The registry is not a trust anchor and does not pretend to be.** "Consumers should
    assume minimal-to-no moderation." It removes illegal content, malware, spam and
    non-functioning servers; it explicitly does **not** remove low-quality, buggy,
    vulnerable, duplicate or adult-content servers. Security scanning is delegated
    entirely to npm, PyPI, Docker Hub and to downstream aggregators.
17. **Soft delete leaves metadata live.** `status: "deleted"` entries stay
    API-accessible, and in extreme cases metadata is overwritten. Aggregation is the
    responsibility of downstream consumers, who must poll status.
18. **Still preview, no GA, no durability guarantee**, and the API-freeze announcement
    dates from 2025-10-24 for v0.1 — with v0.x still live in 2026-09, nearly a year later.
    Breaking changes and data resets remain explicitly possible.
19. **No unpublish.** A publisher cannot retract a server; only maintainers can.
    Immutable, npm-style versions mean a bad release must be superseded, not withdrawn.
20. **Not self-hostable and not supported if forked.** Maintainers cannot support it;
    enterprises wanting private registries must run their own. Hosts are explicitly told
    *not* to consume it directly.
21. **Namespace auth proves control of a GitHub account or a domain — nothing more.**
    72.3 % of the registry sits under `io.github.*`, personal accounts rather than
    verified company domains. A verified domain is a stronger claim than a GitHub
    handle, and the registry treats both as sufficient.
22. **Abandonment is the norm.** 60.7 % of servers have exactly one published version and
    were never updated; only about 36 % were touched in the last 30 days. Version-record
    counts overstate the ecosystem by 3.2×, so any headline quoting "tens of thousands of
    MCP servers" should be checked for dedup.
23. **The registry does not publish its own size**, so every public figure is third-party
    and the two credible ones disagree, 18,387 distinct against 40,506 records, purely on
    the dedup question.
24. **46 % of the registry is remote-only** — hosted endpoints with no installable
    package — and nobody, including the census author, has usage data for that
    fastest-growing half.

### SEP process

25. **Dormancy is a real sink.** Seven SEPs are explicitly Dormant after six months
    without a sponsor, including several that map directly onto live problems: dynamic
    tool search (SEP-1821), task result streaming (SEP-1905), event subscriptions
    (SEP-1803), conversation event subscriptions (SEP-1975), `tasks/list` filtering
    (SEP-1904), context headers for rate limiting (SEP-1921) and HA patterns (SEP-2001).
26. **Sponsor-gated.** Proposals without a sponsor sit in `proposal` indefinitely, among
    them SEP-3094 Granular Citations, SEP-2817 AI Invocation Audit Context with 42
    comments, SEP-2624 Interceptors, SEP-2631 File Objects with 45 👍, SEP-2752 HTTP
    Message Signing, SEP-2809 ATSA and SEP-2793 Tool Risk Metadata. Community enthusiasm
    is not converting into accepted specifications.
27. **The roadmap explicitly rations review.** "Maintainer review time is scarce. We spend
    it here first." SEPs outside the five priority areas face a longer queue and a higher
    bar for justification — an admission that the process is throughput-bound, not
    merit-bound.
28. **SEP-3398 could make it worse before better.** Requiring WG *or* CM-group
    sponsorship adds a gate before queue submission, and the seasonal review window means
    a ready extension SEP can wait up to six months. The SEP's own rationale concedes this
    "may delay process and extension proposals that are ready outside the window". Its
    resolution mechanism, deferring unfinished proposals to a later cycle without moving
    the release date, is a policy choice.
29. **The next release date is uncommitted** and SEP-3398 is still a draft three days old
    on the research date, with the exact date and AgentCon NA 2027 alignment listed as
    open questions.

### Cross-cutting

30. **Host support trails the spec by a release or more.** Claude's connector OAuth follows
    2025-03-26, 2025-06-18 and 2025-11-25 and Claude explicitly does not support resource
    subscriptions or sampling. Zed's MCP documentation still links 2025-11-25 pages and
    supports only Tools and Prompts. Microsoft Foundry's Toolbox long-running-operations
    support for MCP tasks is labelled preview. JetBrains documents no MCP Apps. The
    registry's own `server.json` schema is still pinned at 2025-12-11.
31. **The stateless release created a capability regression at the protocol level** that
    vendors are individually papering over: elicitation and sampling lost their
    open-session delivery, so on `2025-11-25` and earlier they require stateful sessions
    while on `2026-07-28`+ they route through MRTR. AWS documents this fork explicitly;
    others have not published equivalent guidance. Clients that cannot do MRTR lose
    server-initiated requests entirely.
32. **Deprecated and removed core features are still load-bearing in the field.**
    `Mcp-Session-Id` was removed from the spec but AgentCore uses it for microVM
    stickiness. `initialize` was removed but Claude Code still reports skipped servers
    from an `initialize`-shaped world and Zed still probes on that basis. `ping`,
    `logging/setLevel` and `notifications/roots/list_changed` are gone, but `logLevel`
    now travels per request in `_meta` and servers MUST NOT emit `notifications/message`
    without it — a constraint that is easy to miss.
33. **Long-tail quality is delegated to aggregators that mostly do not exist yet.** The
    registry's moderation policy pushes security and quality to "downstream
    subregistries (like the GitHub MCP Registry)" while simultaneously telling host
    applications not to consume the registry directly. The middle layer is still being
    built.
34. **Registry scale figures and ecosystem claims are in tension with the actual shape of
    the data** — a 3.2× overstatement from version-record counting, an 80.2 % npm download
    concentration in the top 10 servers, and a median of 413 monthly downloads per
    npm-declaring server. Any adoption narrative should carry the dedup rule with it.

## Sources

### Specification and governance

- <https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning> — Modern
  versus Legacy versus Dual-era definitions, per-request `_meta` version declaration,
  `UnsupportedProtocolVersionError` (-32022), the `MCP-Protocol-Version` header, extension
  negotiation examples, transport-specific era probes, the client/server compatibility
  matrix, and that dual-era servers MAY serve both eras concurrently.
- <https://modelcontextprotocol.io/specification/draft/changelog> — reads "Changes since
  the most recent release will accumulate here." with no entries; the evidence that
  `2026-07-28` is current.
- <https://modelcontextprotocol.io/specification/2025-11-25/changelog> — the full
  `2025-11-25` change set: OIDC discovery, icons, incremental scope consent, tool-name
  guidance, ElicitResult/EnumSchema, URL-mode elicitation, sampling with tools, CIMD,
  experimental tasks, JSON Schema 2020-12, and SEP-932/994/1302/1730.
- <https://modelcontextprotocol.io/community/governance> — LF Projects LLC status,
  Apache 2.0 and CC-BY-4.0 licensing split, the Maintainer/Core Maintainer/Lead
  Maintainer hierarchy, bi-weekly CM meetings, and the named rosters.
- <https://modelcontextprotocol.io/community/sdk-tiers> — SDK tiering, the 100/80/none
  conformance gates, tests available 2026-01-23, tiering published 2026-02-23,
  relegation rules, and the extension and experimental carve-out.

### Extensions

- <https://modelcontextprotocol.io/extensions/overview> — extension identifiers, the
  `ext-` and `experimental-ext-` repository conventions, the creation lifecycle, RFC 2119
  and WG/IG requirements, both negotiation examples, and graceful degradation.
- <https://modelcontextprotocol.io/seps/2133-extensions> — SEP-2133 in full: the framework
  definition, the official/experimental/unofficial tiers, delegation, the branding-change
  rule, SDK autonomy, Apache 2.0, the LF contributor licence grant, trademark and
  antitrust clauses, and the "Not Specified" gaps.
- <https://modelcontextprotocol.io/extensions/client-matrix> — the official extension
  inventory with identifiers, and per-client support.
- <https://modelcontextprotocol.io/extensions/tasks/overview> — Tasks as
  `io.modelcontextprotocol/tasks`: CreateTaskResult, the five statuses,
  `tasks/get`/`tasks/update`/`tasks/cancel`, `notifications/tasks` behind
  `subscriptions/listen`, the durable-handle rationale, and per-request capability
  declaration.
- <https://modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization> —
  the ID-JAG delegated flow, centralized policy and revocation, the client/server/AS
  checklists, and account-linking guidance.
- <https://modelcontextprotocol.io/extensions/skills/overview> — SEP-2640 Final;
  `skills/list`, `skills/get`, `resources/read` for `skill://` URIs, the mandatory
  `resources` capability plus `directoryRead`, SHA-256 digest manifests, identity as
  server identity plus URI, and the "SDK and host support is still being implemented"
  caveat.
- <https://modelcontextprotocol.io/extensions/apps/overview> — the MCP Apps rationale, the
  four-step mechanism, the postMessage transport, framework-agnostic build, host support
  list, and the AppBridge versus `@mcp-ui/client` routes.
- <https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx> —
  the Stable MCP Apps specification: UIResource, McpUiResourceCsp, UIResourceMeta, the
  mandatory default CSP, the no-loosening rule, McpUiToolMeta and visibility, the
  double-iframe sandbox proxy requirements, the full `ui/*` method inventory,
  HostCapabilities, HostContext, container dimension modes, display modes, the ~60
  standardized theming variables, and the deprecation of the flat
  `_meta["ui/resourceUri"]`.
- <https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/README.md> — spec
  version table, Apache 2.0, the v2 package split and 1.x↔2.x wire compatibility, the four
  shipped Agent Skills, the example catalogue, and the caveat that there is no supported
  host implementation in the repository.
- <https://github.com/modelcontextprotocol/experimental-ext-interceptors> — the live
  experimental extension for SEP-2624, establishing that the `experimental-ext-` tier is
  in use.

### SEP process, roadmap and releases

- <https://modelcontextprotocol.io/seps/index> — 42 Final, the full status legend, and per
  SEP number, title, status, type and created date.
- <https://plan.modelcontextprotocol.io/seps> — the live SEP status board with sponsor,
  status, target release and days in status.
- <https://api.github.com/search/issues?q=repo:modelcontextprotocol/modelcontextprotocol+type:pr+state:open+SEP> —
  the 44 open SEP-labelled pull requests.
- <https://patch-diff.githubusercontent.com/raw/modelcontextprotocol/modelcontextprotocol/pull/3398.diff> —
  the full SEP-3398 text: March/September cadence, eight-month cycles, release-manager
  rotation, milestone offsets, sponsorship, queue, seven-day recorded votes over all
  eligible CMs, soft and hard freeze, SDK beta, transition to March 2027, open questions.
- <https://modelcontextprotocol.io/development/roadmap> — the five priority areas, named
  Core Maintainers per area, server-initiated events, HTTP over stdio, ETags, DPoP,
  WIF/ID-JAG/RFC 8693, tool result shape, progressive discovery, primitive annotations,
  the extension contract, the generated-artifacts experiment, explicit SEP prioritisation
  and the 6–12 month horizon.
- <https://meet.modelcontextprotocol.io/2026> — the 2026 WG/IG meeting calendar, used as
  evidence of active operating groups.

### Registry

- <https://modelcontextprotocol.io/registry/about> — registry purpose, preview status,
  server.json contents, the package-registry relationship, the private-server exclusion,
  aggregator expectations, namespace authentication and the spam-prevention mechanisms.
- <https://modelcontextprotocol.io/registry/moderation-policy> — the permissive policy
  verbatim, the "consumers should assume minimal-to-no moderation" disclaimer, the
  explicit non-removals, soft delete via `status`, and appeals.
- <https://modelcontextprotocol.io/registry/registry-aggregators> — the aggregator
  contract: the three read endpoints, cursor pagination, `updated_since`, status
  semantics, subregistry `_meta` injection, and "no uptime or data durability
  guarantees".
- <https://modelcontextprotocol.io/registry/faq> — Official Registry versus MCP Registry
  API terminology, no unpublish (issue #104), immutable version metadata, the 4 KB
  `publisher-provided` `_meta` cap, and the `Abuse report:` issue convention.
- <https://raw.githubusercontent.com/modelcontextprotocol/registry/main/README.md> — the
  2025-09-08 preview launch, the 2025-10-24 v0.1 API freeze, the Registry WG roster, the
  Go/Postgres/ko/Pulumi architecture, the ghcr image tags, the four publishing auth
  methods, namespace enforcement examples, and the not-self-hostable statement.
- <https://raw.githubusercontent.com/modelcontextprotocol/registry/main/docs/reference/api/openapi.yaml> —
  the normative registry OpenAPI 3.1, id
  `…/draft/2025-12-01/server-registry-openapi`, version 2025-12-01, MIT.
- <https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json> — the
  live server.json schema actually served, including the `Argument` command-injection
  warning and the `Icon` MIME-type enum.
- <https://blog.modelcontextprotocol.io/posts/2025-09-08-mcp-registry-preview/> — the
  preview announcement, the subregistry model, the founding-maintainer roster across
  Anthropic, GitHub, Block, PulseMCP, VS Code, NuGet and Microsoft, and the durability
  caveat.
- <https://registry.modelcontextprotocol.io/v0.1/servers?limit=1> — the live response
  envelope and the `io.modelcontextprotocol.registry/official` `_meta` shape.

### Adoption measurement

- <https://api.npmjs.org/downloads/point/last-week/@modelcontextprotocol/sdk> — 64,725,178
  downloads, 2026-09-21 to 2026-09-27.
- <https://api.npmjs.org/downloads/point/last-month/@modelcontextprotocol/sdk> — 202,740,901
  downloads, 2026-08-29 to 2026-09-27.
- <https://pypistats.org/api/packages/mcp/recent> — the `mcp` PyPI figures.
- <https://circadian-agent.com/research/mcp-registry> — the third-party registry census,
  2026-07-25, with a published crawler and dataset: 58,230 version records to 18,387
  distinct servers, 11,438 namespaces, 72.3 % under `io.github.*`, 60.7 % single-version,
  46 % remote-only, the remote-share inflection, package mix, npm download concentration,
  and the author's own retraction and disclaimers.
- <https://mcp-tracker.martinalderson.com/> — the second independent registry count, dated
  2026-06-22: 40,506 total, 30,564 stdio, 13,412 remote, 348 new in the last day, counting
  records rather than distinct servers.

### Vendor documentation

- <https://claude.com/docs/connectors/building> — the supported feature set, the three
  authorization spec versions Claude follows, DCR and redirect URI requirements, lazy auth
  and Enterprise Managed Auth, the size and timeout limits, the directory versus custom
  connector split, and the explicit statement that resource subscriptions and sampling are
  unsupported.
- <https://code.claude.com/docs/en/mcp> — `claude mcp add` across http, sse and stdio, the
  `ws` WebSocket transport, `CLAUDE_PROJECT_DIR` and `roots/list`, reserved server names,
  project-scope approval gated on workspace trust, the discovery cache and
  `MCP_DISCOVERY_CACHE`, the config-warning matrix, and failure-detail redaction rules.
- <https://code.visualstudio.com/docs/agent-customization/mcp-servers> — VS Code and GitHub
  Copilot: the `@mcp` gallery, `.vscode/mcp.json` versus portable `.mcp.json`, the Agent
  Host split, cross-client discovery, `code --add-mcp`, inline MCP Apps rendering,
  macOS and Linux stdio sandboxing with auto-approval, Workspace Trust inheritance, and
  GitHub-policy enterprise allowlisting. Page date 2026-09-16.
- <https://code.visualstudio.com/blogs/2026/01/26/mcp-apps-support> — the VS Code MCP Apps
  announcement.
- <https://cursor.com/docs/mcp> — three transports, Tools/Prompts/Resources/Roots/
  Elicitation/Apps support, progressive enhancement, static OAuth credentials and fixed
  redirect URLs, `envFile`, the registration extension API, per-server network modes, the
  enterprise MCP Allowlist, and the Cursor Marketplace with team marketplaces.
- <https://cursor.com/changelog/2-6> — Cursor 2.6, 2026-03-03, "MCP Apps and Team
  Marketplaces for Plugins".
- <https://zed.dev/docs/ai/mcp> — Tools and Prompts only with Discovery, Sampling and
  Elicitation unsupported, `tools/list_changed` handling, extension-based install, the
  OAuth flow for unheadered remote servers, `mcp:<server>:<tool>` permission keys, ACP
  forwarding, and the 2025-11-25 spec links that mark the lag.
- <https://www.jetbrains.com/help/ai-assistant/mcp.html> — JetBrains AI Assistant
  2026.2: STDIO and Streamable HTTP, JSON config, per-server scope, MCP logs, and the
  integrated IDE-as-MCP-server plugin available since 2025.2.
- <https://raw.githubusercontent.com/google-gemini/gemini-cli/main/docs/tools/mcp-server.md> —
  Gemini CLI: three transports, `mcp.allowed`/`mcp.excluded`, `includeTools`/`excludeTools`,
  per-server `trust`, `@server://resource/path` references, and the default environment
  redaction of `*TOKEN*`/`*SECRET*`/`*PASSWORD*`/`*KEY*`/`*AUTH*`/`*CREDENTIAL*` before
  spawning servers.
- <https://developers.openai.com/plugins/build/mcp-server> — MCP servers as plugin
  backends, MCP Apps for ChatGPT, the bounded static subset of SEP-2640 Skills with its
  size limits and snapshot semantics, the `_meta["openai/profile"]` convention, and the
  instruction to enforce authorization server-side.
- <https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/model-context-protocol> —
  Microsoft Foundry: the `mcp` tool across Python, C#, JavaScript, Java and REST, public
  versus private endpoints with a dedicated MCP subnet on Azure Container Apps, Toolboxes
  as MCP-compatible endpoints, seven auth types including `agentic-identity`, eleven
  Foundry-managed OAuth connector names, MCP tasks in preview, and the `-32006`
  CONSENT_REQUIRED error.
- <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html> —
  AgentCore Runtime: ARM64 container on 0.0.0.0:8000, `POST /mcp`, the stateless default,
  microVM stickiness via `Mcp-Session-Id`, the version-dependent state requirement, the
  JSON-RPC-to-exception error table, the `Accept` header 406, and the RFC 7235
  `WWW-Authenticate` plus `GetRuntimeProtectedResourceMetadata` OAuth flow.
- <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/mcp-stateful-features.html> —
  the stateful MCP feature demonstration and the `Mcp-Session-Id` session contract.
- <https://developers.cloudflare.com/agents/model-context-protocol/> — remote MCP on
  Cloudflare, Streamable HTTP with OAuth for remote and stdio for local, and the tool-design
  guidance against mirroring full API schemas, on narrowly-scoped servers, with evals.
