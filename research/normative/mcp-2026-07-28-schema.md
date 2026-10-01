# Model Context Protocol `2026-07-28` — capability and notification declarations from `schema.ts`

This document transcribes the `schema/2026-07-28/schema.ts` declarations that
`PROTOCOLS.md` §4.8, §4.10 and §4.11 are built from: the ten `*ResultResponse`
interfaces, the ten result interfaces they name, the two result base interfaces,
the `ServerResult` union, `ContentBlock` and its five members,
`ResourceContents` and its two arms, the element types those reference, both
capability interfaces, and all eight notification shapes with the types they
depend on. §4.10 is the newest and largest section of the contract and the only
one the MCP result codec in `src/mcp.zig` implements against; before this file
existed, none of it could be re-verified offline, because §4.10 was transcribed
from the upstream artifact directly rather than from a document in this
directory. §4.8 and §4.11 were added for the same reason: each named a shape the
artifact declares and no document here declared.

Every declaration below is reproduced exactly as it appears in the artifact,
including its JSDoc comment, and each is labelled with the artifact's line range.
Nothing here is restated or paraphrased: where a declaration carries normative
requirement language, that language is inside the quoted block.

- Retrieval date: 2026-10-01
- Contract: [`../../PROTOCOLS.md`](../../PROTOCOLS.md) §4.8 — capabilities; §4.10
  — the result payloads; §4.11 — the notification payloads
- Evidence: this file, transcribed from the artifacts named under
  *Artifact provenance*

## Artifact provenance

- `https://raw.githubusercontent.com/modelcontextprotocol/specification/main/schema/2026-07-28/schema.ts`
  — the primary normative source for every declaration below. 98,426 bytes,
  3,197 newline-terminated lines, ending with the `ServerResult` union's final arm
  `| InputRequiredResult;` and a terminating newline.
- sha256, recomputed from `main` on **2026-10-01**:
  `742750af0bb8c716e7030c4977c992b55d1adc4407e9e66997db5846baedc2cd`
- `https://raw.githubusercontent.com/modelcontextprotocol/specification/3098fe94caa1b9e0afaaa6d30e040b61d5802471/schema/2026-07-28/schema.json`
  — the **generated** JSON Schema, draft 2020-12, 181,474 bytes, 3,963 lines, no
  `$id`, sha256
  `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`, fetched
  2026-10-01 at the same commit. It is a **cross-check, not a second source of
  truth**: no declaration is quoted from it, and where it is read below the reading
  is of a keyword the TypeScript source cannot express. It is listed because two
  claims that this file previously made are decidable only here — see §9.

The digest equals the one recorded for the transcription of `PROTOCOLS.md` §4.10, so
§4.10 was taken from bytes this URL still serves and the section's provenance is
reproducible: fetching the URL and hashing the result is sufficient to establish that
the artifact before this file was written is the artifact §4.10 was written from.
`main` is a moving branch and a later fetch may not match; re-hash before relying on
any line range below.

### Immutable pin

`main` is a branch, so the line ranges below are only pinned by a digest and a
later fetch may not reproduce them. As of **2026-10-01** the same bytes are
reachable at an immutable ref, and both URLs were fetched and hashed
separately:

| | URL | Bytes | Lines | sha256 |
| --- | --- | --- | --- | --- |
| Moving ref | `https://raw.githubusercontent.com/modelcontextprotocol/specification/main/schema/2026-07-28/schema.ts` | 98,426 | 3,197 | `742750af0bb8c716e7030c4977c992b55d1adc4407e9e66997db5846baedc2cd` |
| Immutable ref | `https://raw.githubusercontent.com/modelcontextprotocol/specification/3098fe94caa1b9e0afaaa6d30e040b61d5802471/schema/2026-07-28/schema.ts` | 98,426 | 3,197 | `742750af0bb8c716e7030c4977c992b55d1adc4407e9e66997db5846baedc2cd` |

The two responses are byte-identical (`cmp` reports no difference), so the
commit-pinned URL is a second address for the *same* artifact, not a different
revision of it. Commit `3098fe94caa1b9e0afaaa6d30e040b61d5802471` is the `main`
head at 2026-10-01T12:55:32Z, subject *"Merge pull request #3408 from
modelcontextprotocol/claude/maintainers-tnorimat-nbarbettini — Add Conformance
maintainers"*, resolved through
`https://api.github.com/repositories/862570523/commits?sha=main&per_page=1`.

The digest above is unchanged from the one this file already recorded, and that
is the point: the historical provenance of `PROTOCOLS.md` §4.10 is **not**
rewritten. §4.10 was transcribed from bytes whose digest is `742750af…2cd`, the
digest recomputed on 2026-10-01 is the same value, and the commit-pinned fetch
of the same date is byte-identical to it. The pin adds a durable address for
the line ranges; it introduces no new claim about when §4.10 was written and
does not license moving any `artifact L…` cite.

Every hash in this section is over the **original HTTP response body** as
written to disk by `curl -o`, never over reader output, a wrapper, or a
normalised copy. A reader that reformats, line-numbers, or wraps the source
cannot be hashed and must not be.

**Provenance conflict, now resolved in the sibling.**
[`mcp-2026-07-28.md`](mcp-2026-07-28.md) lines 6 and 21–22 described this same URL as
*"the 3203-line `schema/2026-07-28/schema.ts`"* and *"primary normative source, 3203
lines"*. The artifact is **3,197** lines, confirmed three ways on 2026-10-01: `wc -l`,
the line number of the file's last line (3197), and the byte count (98,426) with a
trailing newline present — the `3203` figure was wrong by six. The sibling has since
been corrected at both sites and its *Cross-source conflicts and gaps* entry 11 records
the superseded figure rather than deleting it, so this paragraph is kept as the
provenance of the correction and not as a live disagreement. No value either document
transcribes was ever affected: every declaration quoted here sits at or before line
3197, and the `sha256` above is the digest of the 3,197-line artifact.

## Scope: what §4.8, §4.10 and §4.11 take from this artifact

| Contract subsection | Declarations quoted below | Here |
| --- | --- | --- |
| 4.10 preamble | `JSONRPCResultResponse`, `ResultType`, `Result`, `ResultMetaObject`, `MetaObject`, `Cursor`, `RequestId` | §1 |
| 4.10.1 method to result | the ten `*ResultResponse` interfaces, `EmptyResult`, `ServerResult` | §1, §3, §5 |
| 4.10.2 cacheable and paginated | `CacheableResult`, `PaginatedResult`, `PaginatedRequest`, `PaginatedRequestParams` | §2 |
| 4.10.3 payloads | the ten result interfaces, `PromptMessage`, `Role`, `SubscriptionsListenResultMetaObject`, `ToolAnnotations` | §4, §8 |
| 4.10.4 `ContentBlock` | `ContentBlock` and `TextContent`, `ImageContent`, `AudioContent`, `ResourceLink`, `EmbeddedResource`; `Resource`, `BaseMetadata`, `Icons`, `Icon`, `Annotations` | §6, §8 |
| 4.10.5 caller-owned sequences | `Prompt`, `PromptArgument`, `ResourceTemplate`, `ResourceContents`, `TextResourceContents`, `BlobResourceContents` | §7, §8 |
| 4.10.6 open and closed sets | `Result`'s index signature, `ContentBlock`'s declaration, the capability doc sentences, `Role`, `Icon.theme`, `cacheScope`, and the `additionalProperties` census over the generated `schema.json` | §1, §2, §6, §8, §9 |
| 4.10.7 where the source is silent | `ResourceContents` arms, `Annotations.priority`, `completion.values` | §4, §7, §8 |
| 4.8 capabilities | `ClientCapabilities`, `ServerCapabilities` | §9 |
| 4.11 notifications | `NotificationParams`, `Notification`, `JSONRPCNotification`, `NotificationMetaObject`, `RequestMetaObject` (the `progressToken` member), `ProgressToken`, `SubscriptionFilter`, `LoggingLevel`, all eight notification interfaces and the five params interfaces they name, `ClientNotification`, `ServerNotification` | §10 |

Also quoted, though §4.10 names them only by type: `Implementation`, which
`ResultMetaObject` points at, and `ServerCapabilities`, the type of
`DiscoverResult.capabilities`.

`ClientCapabilities` was previously quoted by doc comment only, with its body
left to [`mcp-2026-07-28.md`](mcp-2026-07-28.md) §6. It is now quoted in full at
§9, because §4.8 states a member table for it and a table whose declaration is
in a different document than its own citations is not auditable from one place.
§6 of the sibling remains a true and useful second source: every value in its
`ClientCapabilities` JSON shape and field table agrees with the L711–L786
declaration now quoted here.

## 1. Envelope and base types

### `JSONRPCResultResponse` — artifact L282–L291

```ts
/**
 * A successful (non-error) response to a request.
 *
 * @category JSON-RPC
 */
export interface JSONRPCResultResponse {
  jsonrpc: typeof JSONRPC_VERSION;
  id: RequestId;
  result: Result;
}
```

`jsonrpc: typeof JSONRPC_VERSION` resolves through `export const JSONRPC_VERSION = "2.0";`
at artifact L31–L32, so the field is the literal `"2.0"`.

### `RequestId` — artifact L256–L261

```ts
/**
 * A uniquely identifying ID for a request in JSON-RPC.
 *
 * @category Common Types
 */
export type RequestId = string | number;
```

### `ResultType` — artifact L208–L216

```ts
/**
 * Indicates the type of a {@link Result} object, allowing the client to
 * determine how to parse the response.
 *
 * complete - the request completed successfully and the result contains the final content.
 * input_required - the request requires additional input and the result contains an {@link InputRequiredResult} object with instructions for the client to provide additional input before retrying the original request.
 * @category Common Types
 */
export type ResultType = "complete" | "input_required" | string;
```

The trailing `| string` arm is what makes `resultType` an open carrier with a closed
documented set; §4.10.6 states both halves and is supported by this line and by
nothing else in the file.

### `Result` — artifact L218–L236

```ts
/**
 * Common result fields.
 *
 * @category Common Types
 */
export interface Result {
  _meta?: ResultMetaObject;
  /**
   * Indicates the type of the result, which allows the client to determine
   * how to parse the result object.
   *
   * Servers implementing this protocol version MUST include this field.
   * For backward compatibility, when a client receives a result from a
   * server implementing an earlier protocol version (which does not include
   * `resultType`), the client MUST treat the absent field as `"complete"`.
   */
  resultType: ResultType;
  [key: string]: unknown;
}
```

Two facts §4.10 depends on, both visible here and nowhere else: `resultType` is
**required** on every result (it is `ResultType`, not `ResultType | undefined`), and
`[key: string]: unknown` makes every result object an **open** member set. Because the
index signature is inherited, it reaches all ten results and `InputRequiredResult`.

### `EmptyResult` — artifact L528–L534

```ts
/* Empty result */
/**
 * A result that indicates success but carries no data.
 *
 * @category Common Types
 */
export type EmptyResult = Result;
```

An alias, not an interface: `EmptyResult` has no member of its own and adds nothing
to `Result`. §4.10.1 quotes this declaration word for word.

### `ResultMetaObject` — artifact L136–L158

```ts
/**
 * Extends {@link MetaObject} with additional result-specific fields. All key naming rules from `MetaObject` apply.
 *
 * @see {@link MetaObject} for key naming rules and reserved prefixes.
 * @see [General fields: `_meta`](/specification/2026-07-28/basic/index#meta) for more details.
 * @category Common Types
 */
export interface ResultMetaObject extends MetaObject {
  /**
   * Identifies the server software producing the response. Servers SHOULD
   * include this field on every response unless specifically configured not
   * to do so.
   *
   * The {@link Implementation} schema requires `name` and `version`; other
   * fields are optional.
   *
   * The value is self-reported by the server and is not verified by the
   * protocol. It is intended for display, logging, and debugging. Clients
   * SHOULD NOT use it to change their behavior, and SHOULD NOT rely on it for
   * security decisions.
   */
  "io.modelcontextprotocol/serverInfo"?: Implementation;
}
```

### `MetaObject` — artifact L34–L54

```ts
/**
 * Represents the contents of a `_meta` field, which clients and servers use to attach additional metadata to their interactions.
 *
 * Certain key names are reserved by MCP for protocol-level metadata; implementations MUST NOT make assumptions about values at these keys. Additionally, specific schema definitions may reserve particular names for purpose-specific metadata, as declared in those definitions.
 *
 * Valid keys have two segments:
 *
 * **Prefix:**
 * - Optional — if specified, MUST be a series of _labels_ separated by dots (`.`), followed by a slash (`/`).
 * - Labels MUST start with a letter and end with a letter or digit. Interior characters may be letters, digits, or hyphens (`-`).
 * - Implementations SHOULD use reverse DNS notation (e.g., `com.example/` rather than `example.com/`).
 * - Any prefix where the second label is `modelcontextprotocol` or `mcp` is **reserved** for MCP use. For example: `io.modelcontextprotocol/`, `dev.mcp/`, `org.modelcontextprotocol.api/`, and `com.mcp.tools/` are all reserved. However, `com.example.mcp/` is NOT reserved, as the second label is `example`.
 *
 * **Name:**
 * - Unless empty, MUST start and end with an alphanumeric character (`[a-z0-9A-Z]`).
 * - Interior characters may be alphanumeric, hyphens (`-`), underscores (`_`), or dots (`.`).
 *
 * @see [General fields: `_meta`](/specification/2026-07-28/basic/index#meta) for more details.
 * @category Common Types
 */
export type MetaObject = Record<string, unknown>;
```

`Record<string, unknown>` is the one open member every closed set in §4.10.6 admits,
and `ResultMetaObject` inherits it without narrowing it: the `serverInfo` key is a
declared, typed member, and every other key is still `unknown`.

### `Cursor` — artifact L167–L172

```ts
/**
 * An opaque token used to represent a cursor for pagination.
 *
 * @category Common Types
 */
export type Cursor = string;
```

## 2. The two result bases

### `CacheableResult` — artifact L1076–L1110

```ts
/**
 * A result that supports a time-to-live (TTL) hint for client-side caching.
 *
 * @internal
 */
export interface CacheableResult extends Result {
  /**
   * A hint from the server indicating how long (in milliseconds) the
   * client MAY cache this response before re-fetching. Semantics are
   * analogous to HTTP Cache-Control max-age.
   *
   * - If 0, The response SHOULD be considered immediately stale,
   *   The client MAY re-fetch every time the result is needed.
   * - If positive, the client SHOULD consider the result fresh for this many
   *   milliseconds after receiving the response.
   *
   * @minimum 0
   */
  ttlMs: number;

  /**
   * Indicates the intended scope of the cached response, analogous to HTTP
   * `Cache-Control: public` vs `Cache-Control: private`.
   *
   * - `"public"`: The response does not contain user-specific data. Any
   *   client or intermediary (e.g., shared gateway, caching proxy) MAY cache
   *   the response and serve it across authorization contexts.
   * - `"private"`: The response MAY be cached and reused only within the
   *   same authorization context. Caches MUST NOT be shared across
   *   authorization contexts (e.g., a different access token requires a
   *   different cache).
   *
   */
  cacheScope: "public" | "private";
}
```

Both members are required — neither is marked optional. `cacheScope` is written inline
as a literal union; the artifact declares **no** `CacheScope` type alias, and `grep` for
`CacheScope` over all 3,197 lines returns no declaration. §4.10.6's row naming
`CacheScope` therefore names `mcp.CacheScope` in `src/mcp.zig`, not a schema type, and
the wire set it closes is the inline union above.

### `PaginatedResult` — artifact L1067–L1074

```ts
/** @internal */
export interface PaginatedResult extends Result {
  /**
   * An opaque token representing the pagination position after the last returned result.
   * If present, there may be more results available.
   */
  nextCursor?: Cursor;
}
```

`nextCursor` is the only member `PaginatedResult` contributes and it is optional.

### `PaginatedRequestParams` and `PaginatedRequest` — artifact L1046–L1065

```ts
/**
 * Common params for paginated requests.
 *
 * @example List request with cursor
 * {@includeCode ./examples/PaginatedRequestParams/list-with-cursor.json}
 *
 * @category Common Types
 */
export interface PaginatedRequestParams extends RequestParams {
  /**
   * An opaque token representing the current pagination position.
   * If provided, the server should return results starting after this cursor.
   */
  cursor?: Cursor;
}

/** @internal */
export interface PaginatedRequest extends JSONRPCRequest {
  params: PaginatedRequestParams;
}
```

Four interfaces extend `PaginatedRequest`, and the artifact names them: artifact
L1121–L1123 `ListResourcesRequest` (`method: "resources/list"`), L1157–L1159
`ListResourceTemplatesRequest` (`method: "resources/templates/list"`), L1566–L1568
`ListPromptsRequest` (`method: "prompts/list"`), L1767–L1769 `ListToolsRequest`
(`method: "tools/list"`). A fifth candidate is excluded: `DiscoverRequest` at
L665–L668 extends `JSONRPCRequest` with `params: RequestParams`.

## 3. The ten `*ResultResponse` interfaces

All ten extend `JSONRPCResultResponse` and each narrows `result` to one or two result
types. Three of the ten name `InputRequiredResult` as the alternative arm; the
artifact does not say which method may use it in prose, but it names the three in the
type system, and they are the three methods §4.10.1 marks as MRTR-capable.

| Response interface | Artifact lines | `result` type, verbatim |
| --- | --- | --- |
| `DiscoverResultResponse` | L699–L709 | `DiscoverResult` |
| `ListResourcesResultResponse` | L1137–L1147 | `ListResourcesResult` |
| `ListResourceTemplatesResultResponse` | L1174–L1184 | `ListResourceTemplatesResult` |
| `ReadResourceResultResponse` | L1233–L1246 | `ReadResourceResult \| InputRequiredResult` |
| `SubscriptionsListenResultResponse` | L1353–L1364 | `SubscriptionsListenResult` |
| `ListPromptsResultResponse` | L1582–L1592 | `ListPromptsResult` |
| `GetPromptResultResponse` | L1642–L1652 | `GetPromptResult \| InputRequiredResult` |
| `ListToolsResultResponse` | L1783–L1793 | `ListToolsResult` |
| `CallToolResultResponse` | L1840–L1850 | `CallToolResult \| InputRequiredResult` |
| `CompleteResultResponse` | L2663–L2673 | `CompleteResult` |

### `DiscoverResultResponse` — artifact L699–L709

```ts
/**
 * A successful response from the server for a {@link DiscoverRequest | server/discover} request.
 *
 * @example Discover result response
 * {@includeCode ./examples/DiscoverResultResponse/discover-result-response.json}
 *
 * @category `server/discover`
 */
export interface DiscoverResultResponse extends JSONRPCResultResponse {
  result: DiscoverResult;
}
```

### `ListResourcesResultResponse` — artifact L1137–L1147

```ts
/**
 * A successful response from the server for a {@link ListResourcesRequest | resources/list} request.
 *
 * @example List resources result response
 * {@includeCode ./examples/ListResourcesResultResponse/list-resources-result-response.json}
 *
 * @category `resources/list`
 */
export interface ListResourcesResultResponse extends JSONRPCResultResponse {
  result: ListResourcesResult;
}
```

### `ListResourceTemplatesResultResponse` — artifact L1174–L1184

```ts
/**
 * A successful response from the server for a {@link ListResourceTemplatesRequest | resources/templates/list} request.
 *
 * @example List resource templates result response
 * {@includeCode ./examples/ListResourceTemplatesResultResponse/list-resource-templates-result-response.json}
 *
 * @category `resources/templates/list`
 */
export interface ListResourceTemplatesResultResponse extends JSONRPCResultResponse {
  result: ListResourceTemplatesResult;
}
```

### `ReadResourceResultResponse` — artifact L1233–L1246

```ts
/**
 * A successful response from the server for a {@link ReadResourceRequest | resources/read} request.
 *
 * @example Read resource result response
 * {@includeCode ./examples/ReadResourceResultResponse/read-resource-result-response.json}
 *
 * @example Read resource result response with TTL
 * {@includeCode ./examples/ReadResourceResultResponse/read-resource-result-response-with-ttl.json}
 *
 * @category `resources/read`
 */
export interface ReadResourceResultResponse extends JSONRPCResultResponse {
  result: ReadResourceResult | InputRequiredResult;
}
```

### `SubscriptionsListenResultResponse` — artifact L1353–L1364

```ts
/**
 * A successful response from the server for a {@link SubscriptionsListenRequest | subscriptions/listen}
 * request, sent when the server tears the subscription down gracefully.
 *
 * @example Subscription closed gracefully response
 * {@includeCode ./examples/SubscriptionsListenResultResponse/listen-closed-response.json}
 *
 * @category `subscriptions/listen`
 */
export interface SubscriptionsListenResultResponse extends JSONRPCResultResponse {
  result: SubscriptionsListenResult;
}
```

### `ListPromptsResultResponse` — artifact L1582–L1592

```ts
/**
 * A successful response from the server for a {@link ListPromptsRequest | prompts/list} request.
 *
 * @example List prompts result response
 * {@includeCode ./examples/ListPromptsResultResponse/list-prompts-result-response.json}
 *
 * @category `prompts/list`
 */
export interface ListPromptsResultResponse extends JSONRPCResultResponse {
  result: ListPromptsResult;
}
```

### `GetPromptResultResponse` — artifact L1642–L1652

```ts
/**
 * A successful response from the server for a {@link GetPromptRequest | prompts/get} request.
 *
 * @example Get prompt result response
 * {@includeCode ./examples/GetPromptResultResponse/get-prompt-result-response.json}
 *
 * @category `prompts/get`
 */
export interface GetPromptResultResponse extends JSONRPCResultResponse {
  result: GetPromptResult | InputRequiredResult;
}
```

### `ListToolsResultResponse` — artifact L1783–L1793

```ts
/**
 * A successful response from the server for a {@link ListToolsRequest | tools/list} request.
 *
 * @example List tools result response
 * {@includeCode ./examples/ListToolsResultResponse/list-tools-result-response.json}
 *
 * @category `tools/list`
 */
export interface ListToolsResultResponse extends JSONRPCResultResponse {
  result: ListToolsResult;
}
```

### `CallToolResultResponse` — artifact L1840–L1850

```ts
/**
 * A successful response from the server for a {@link CallToolRequest | tools/call} request.
 *
 * @example Call tool result response
 * {@includeCode ./examples/CallToolResultResponse/call-tool-result-response.json}
 *
 * @category `tools/call`
 */
export interface CallToolResultResponse extends JSONRPCResultResponse {
  result: CallToolResult | InputRequiredResult;
}
```

### `CompleteResultResponse` — artifact L2663–L2673

```ts
/**
 * A successful response from the server for a {@link CompleteRequest | completion/complete} request.
 *
 * @example Completion result response
 * {@includeCode ./examples/CompleteResultResponse/completion-result-response.json}
 *
 * @category `completion/complete`
 */
export interface CompleteResultResponse extends JSONRPCResultResponse {
  result: CompleteResult;
}
```

## 4. The ten result interfaces

### `DiscoverResult` — artifact L670–L697

```ts
/**
 * The result returned by the server for a {@link DiscoverRequest | server/discover} request.
 *
 * @example Server capabilities discovery
 * {@includeCode ./examples/DiscoverResult/server-capabilities-discovery.json}
 *
 * @category `server/discover`
 */
export interface DiscoverResult extends CacheableResult {
  /**
   * MCP Protocol Versions this server supports. The client should choose a
   * version from this list for use in subsequent requests.
   */
  supportedVersions: string[];
  /**
   * The capabilities of the server.
   */
  capabilities: ServerCapabilities;
  /**
   * Natural-language guidance describing the server and its features.
   *
   * This can be used by clients to improve an LLM's understanding of
   * available tools (e.g., by including it in a system prompt). It should
   * focus on information that helps the model use the server effectively
   * and should not duplicate information already in tool descriptions.
   */
  instructions?: string;
}
```

`extends CacheableResult` and nothing else. `DiscoverResult` does **not** extend
`PaginatedResult` and has no `nextCursor`. That is the fact §4.10.2's
`PaginatedResult` row gets wrong; see *Findings* below.

### `CompleteResult` — artifact L2633–L2661

```ts
/**
 * The result returned by the server for a {@link CompleteRequest | completion/complete} request.
 *
 * @category `completion/complete`
 *
 * @example Single completion value
 * {@includeCode ./examples/CompleteResult/single-completion-value.json}
 *
 * @example Multiple completion values with more available
 * {@includeCode ./examples/CompleteResult/multiple-completion-values-with-more-available.json}
 */
export interface CompleteResult extends Result {
  completion: {
    /**
     * An array of completion values. Must not exceed 100 items.
     *
     * @maxItems 100
     */
    values: string[];
    /**
     * The total number of completion options available. This can exceed the number of values actually sent in the response.
     */
    total?: number;
    /**
     * Indicates whether there are additional completion options beyond those provided in the current response, even if the exact total is unknown.
     */
    hasMore?: boolean;
  };
}
```

`completion` is required and `values` is required within it, so
`{"resultType":"complete"}` is not a `CompleteResult`. `@maxItems 100` on `values` is
the **only** numeric bound on any result array in the artifact, which is what §4.10.7
records.

### `GetPromptResult` — artifact L1626–L1640

```ts
/**
 * The result returned by the server for a {@link GetPromptRequest | prompts/get} request.
 *
 * @example Code review prompt
 * {@includeCode ./examples/GetPromptResult/code-review-prompt.json}
 *
 * @category `prompts/get`
 */
export interface GetPromptResult extends Result {
  /**
   * An optional description for the prompt.
   */
  description?: string;
  messages: PromptMessage[];
}
```

### `ListPromptsResult` — artifact L1570–L1580

```ts
/**
 * The result returned by the server for a {@link ListPromptsRequest | prompts/list} request.
 *
 * @example Prompts list with cursor and TTL
 * {@includeCode ./examples/ListPromptsResult/prompts-list-with-cursor-and-ttl.json}
 *
 * @category `prompts/list`
 */
export interface ListPromptsResult extends PaginatedResult, CacheableResult {
  prompts: Prompt[];
}
```

### `ListResourcesResult` — artifact L1125–L1135

```ts
/**
 * The result returned by the server for a {@link ListResourcesRequest | resources/list} request.
 *
 * @example Resources list with cursor and TTL
 * {@includeCode ./examples/ListResourcesResult/resources-list-with-cursor-and-ttl.json}
 *
 * @category `resources/list`
 */
export interface ListResourcesResult extends PaginatedResult, CacheableResult {
  resources: Resource[];
}
```

### `ListResourceTemplatesResult` — artifact L1161–L1172

```ts
/**
 * The result returned by the server for a {@link ListResourceTemplatesRequest | resources/templates/list} request.
 *
 * @example Resource templates list with cursor and TTL
 * {@includeCode ./examples/ListResourceTemplatesResult/resource-templates-list-with-cursor-and-ttl.json}
 *
 * @category `resources/templates/list`
 */
export interface ListResourceTemplatesResult
  extends PaginatedResult, CacheableResult {
  resourceTemplates: ResourceTemplate[];
}
```

### `ReadResourceResult` — artifact L1221–L1231

```ts
/**
 * The result returned by the server for a {@link ReadResourceRequest | resources/read} request.
 *
 * @example File resource contents
 * {@includeCode ./examples/ReadResourceResult/file-resource-contents.json}
 *
 * @category `resources/read`
 */
export interface ReadResourceResult extends CacheableResult {
  contents: (TextResourceContents | BlobResourceContents)[];
}
```

`extends CacheableResult` and nothing else: cacheable, not paginated. `contents` is
required and is a union of two interfaces with no discriminator.

### `SubscriptionsListenResult` and its `_meta` — artifact L1319–L1351

```ts
/**
 * Extends {@link ResultMetaObject} with the subscription-stream identifier carried by a
 * {@link SubscriptionsListenResult}. All key naming rules from `MetaObject` apply.
 *
 * @see {@link MetaObject} for key naming rules and reserved prefixes.
 * @category `subscriptions/listen`
 */
export interface SubscriptionsListenResultMetaObject extends ResultMetaObject {
  /**
   * Identifies the subscription stream this response closes, so the client can
   * correlate it with the originating subscription — mirroring the same key on
   * the stream's notifications. The value is the JSON-RPC ID of the
   * `subscriptions/listen` request that opened the stream (and equals this
   * response's `id`).
   */
  "io.modelcontextprotocol/subscriptionId": RequestId;
}

/**
 * The response to a {@link SubscriptionsListenRequest | subscriptions/listen}
 * request, signalling that the subscription has ended gracefully (for example,
 * during server shutdown). Because the listen stream is long-lived, this result
 * is sent only when the server tears the subscription down; an abrupt transport
 * close carries no response. The result body is otherwise empty.
 *
 * @example Subscription closed gracefully
 * {@includeCode ./examples/SubscriptionsListenResult/listen-closed.json}
 *
 * @category `subscriptions/listen`
 */
export interface SubscriptionsListenResult extends Result {
  _meta: SubscriptionsListenResultMetaObject;
}
```

`_meta` is the only payload member and it is **required** here and nowhere else: every
other result inherits `Result._meta?`, which is optional. The doc comment is the
artifact's own source for the two claims §4.10.3 makes about this result — that the
value equals the originating request's `id`, and that an abrupt close carries no
response.

### `CallToolResult` — artifact L1795–L1838

```ts
/**
 * The result returned by the server for a {@link CallToolRequest | tools/call} request.
 *
 * @example Result with unstructured text
 * {@includeCode ./examples/CallToolResult/result-with-unstructured-text.json}
 *
 * @example Result with structured content
 * {@includeCode ./examples/CallToolResult/result-with-structured-content.json}
 *
 * @example Invalid tool input error
 * {@includeCode ./examples/CallToolResult/invalid-tool-input-error.json}
 *
 * @category `tools/call`
 */
export interface CallToolResult extends Result {
  /**
   * A list of content objects that represent the unstructured result of the tool call.
   */
  content: ContentBlock[];

  /**
   * An optional JSON value that represents the structured result of the tool call.
   *
   * This can be any JSON value (object, array, string, number, boolean, or null)
   * that conforms to the tool's outputSchema if one is defined.
   */
  structuredContent?: unknown;

  /**
   * Whether the tool call ended in an error.
   *
   * If not set, this is assumed to be false (the call was successful).
   *
   * Any errors that originate from the tool SHOULD be reported inside the result
   * object, with `isError` set to true, _not_ as an MCP protocol-level error
   * response. Otherwise, the LLM would not be able to see that an error occurred
   * and self-correct.
   *
   * However, any errors in _finding_ the tool, an error indicating that the
   * server does not support tool calls, or any other exceptional conditions,
   * should be reported as an MCP error response.
   */
  isError?: boolean;
}
```

`extends Result` alone — `tools/call` results carry neither `ttlMs` nor `cacheScope`.
`content` is required, so a present-but-empty array is the only empty form the artifact
admits. `isError` is the artifact's own source for §4.10.3's note that a tool's failure
belongs in the result and not in a JSON-RPC error, quoted verbatim above.

### `ListToolsResult` — artifact L1771–L1781

```ts
/**
 * The result returned by the server for a {@link ListToolsRequest | tools/list} request.
 *
 * @example Tools list with cursor and TTL
 * {@includeCode ./examples/ListToolsResult/tools-list-with-cursor-and-ttl.json}
 *
 * @category `tools/list`
 */
export interface ListToolsResult extends PaginatedResult, CacheableResult {
  tools: Tool[];
}
```

## 5. `ServerResult` and the MRTR arm

### `ServerResult` — artifact L3184–L3197

```ts
/** @internal */
export type ServerResult =
  | EmptyResult
  | DiscoverResult
  | CompleteResult
  | GetPromptResult
  | ListPromptsResult
  | ListResourceTemplatesResult
  | ListResourcesResult
  | ReadResourceResult
  | SubscriptionsListenResult
  | CallToolResult
  | ListToolsResult
  | InputRequiredResult;
```

Twelve arms, exactly as §4.10.1 lists them and in the same order. `EmptyResult` is the
first arm; `InputRequiredResult` is the last. The file's final line is that last arm,
with a terminating newline, which is what fixes the artifact at 3,197 lines.

### `InputRequiredResult`, `InputRequests`, `InputResponses` — artifact L544–L595

```ts
/**
 * A map of server-initiated requests that the client must fulfill.
 * Keys are server-assigned identifiers; values are the request objects.
 *
 * @example Elicitation and sampling input requests
 * {@includeCode ./examples/InputRequests/elicitation-and-sampling-input-requests.json}
 *
 * @category Multi Round-Trip
 */
export interface InputRequests {
  [key: string]: InputRequest;
}

/**
 * A map of client responses to server-initiated requests.
 * Keys correspond to the keys in the {@link InputRequests} map;
 * values are the client's result for each request.
 *
 * @example Elicitation and sampling input responses
 * {@includeCode ./examples/InputResponses/elicitation-and-sampling-input-responses.json}
 *
 * @category Multi Round-Trip
 */
export interface InputResponses {
  [key: string]: InputResponse;
}

/**
 * An InputRequiredResult sent by the server to indicate that additional input is needed
 * before the request can be completed.
 *
 * At least one of `inputRequests` or `requestState` MUST be present.
 * @example InputRequiredResult with elicitation and sampling input requests and request state
 * {@includeCode ./examples/InputRequiredResult/input-required-result-with-elicitation-and-sampling-and-request-state.json}
 *
 * @example InputRequiredResult with request state only (load shedding)
 * {@includeCode ./examples/InputRequiredResult/input-required-result-with-request-state-only.json}
 *
 * @category Multi Round-Trip
 */
export interface InputRequiredResult extends Result {
  /* Requests issued by the server that must be complete before the
   * client can retry the original request.
   */
  inputRequests?: InputRequests;
  /* Request state to be passed back to the server when the client
   * retries the original request.
   * Note: The client must treat this as an opaque blob; it must not
   * interpret it in any way.
   */
  requestState?: string;
}
```

Both `inputRequests` and `requestState` are optional in the type system, while the doc
comment imposes *"At least one of `inputRequests` or `requestState` MUST be present."*
That is a requirement the artifact states in prose and does not encode in the types, and
§4.10.7 does not list it among the silences.

### `InputRequest` / `InputResponse` — artifact L536–L542

```ts
/** @internal */
export type InputRequest =
  CreateMessageRequest | ListRootsRequest | ElicitRequest;

/** @internal */
export type InputResponse =
  CreateMessageResult | ListRootsResult | ElicitResult;
```

Neither member of either union extends `Result`, and none carries a `resultType`. That
is why an `inputRequests` value cannot be confused with a result envelope.

## 6. `ContentBlock` and its five members

### `ContentBlock` — artifact L2302–L2306

```ts
/**
 * @category Content
 */
export type ContentBlock =
  TextContent | ImageContent | AudioContent | ResourceLink | EmbeddedResource;
```

Five arms, no `| string`, no index signature, and the only content the prompt-message
and tool-call paths accept. Nothing in `ContentBlock`'s own declaration is open.

The artifact declares a **second, different** content union, and it is not a superset
of this one. `SamplingMessageContentBlock` has five arms too, but it drops
`ResourceLink` and `EmbeddedResource` and adds `ToolUseContent` and
`ToolResultContent`; the two sets overlap in three members. Quoted because the
relation is the thing a reader gets wrong by eye:

### `SamplingMessageContentBlock` and `SamplingMessage` — artifact L2230–L2263

```ts
/**
 * Describes a message issued to or received from an LLM API.
 *
 * @example Single content block
 * {@includeCode ./examples/SamplingMessage/single-content-block.json}
 *
 * @example Multiple content blocks
 * {@includeCode ./examples/SamplingMessage/multiple-content-blocks.json}
 *
 * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
 * Remains in the specification for at least twelve months; see the
 * deprecated features registry.
 *
 * @category `sampling/createMessage`
 */
export interface SamplingMessage {
  role: Role;
  content: SamplingMessageContentBlock | SamplingMessageContentBlock[];
  _meta?: MetaObject;
}

/**
 * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
 * Remains in the specification for at least twelve months; see the
 * deprecated features registry.
 *
 * @category `sampling/createMessage`
 */
export type SamplingMessageContentBlock =
  | TextContent
  | ImageContent
  | AudioContent
  | ToolUseContent
  | ToolResultContent;
```

Three things follow that `PROTOCOLS.md` §4.10 does not record. The sampling union
**drops** the two arms that carry a resource — `ResourceLink` and `EmbeddedResource` —
so a sampling message cannot embed a resource where a prompt message can, which is
what `PromptMessage`'s doc comment contrasts when it says *"This is similar to
{@link SamplingMessage}, but also supports the embedding of resources from the MCP
server."* `SamplingMessage.content` is a **union of one block or an array of blocks**,
where `PromptMessage.content` is a single block and `CallToolResult.content` is
always an array — a third shape for the same field name. And the whole sampling path
is **@deprecated** (SEP-2577): the union at L2252, `SamplingMessage` at L2239,
`ToolUseContent` at L2400 (`type: "tool_use"`), `ToolResultContent` at L2439
(`type: "tool_result"`), `CreateMessageResult` at L2204 and `CreateMessageRequest` at
L2157. The two extra members are outside §4.10's scope, so they are named here rather
than quoted in full.

### `TextContent` — artifact L2308–L2330

```ts
/**
 * Text provided to or from an LLM.
 *
 * @example Text content
 * {@includeCode ./examples/TextContent/text-content.json}
 *
 * @category Content
 */
export interface TextContent {
  type: "text";

  /**
   * The text content of the message.
   */
  text: string;

  /**
   * Optional annotations for the client.
   */
  annotations?: Annotations;

  _meta?: MetaObject;
}
```

### `ImageContent` — artifact L2332–L2361

```ts
/**
 * An image provided to or from an LLM.
 *
 * @example `image/png` content with annotations
 * {@includeCode ./examples/ImageContent/image-png-content-with-annotations.json}
 *
 * @category Content
 */
export interface ImageContent {
  type: "image";

  /**
   * The base64-encoded image data.
   *
   * @format byte
   */
  data: string;

  /**
   * The MIME type of the image. Different providers may support different image types.
   */
  mimeType: string;

  /**
   * Optional annotations for the client.
   */
  annotations?: Annotations;

  _meta?: MetaObject;
}
```

### `AudioContent` — artifact L2363–L2392

```ts
/**
 * Audio provided to or from an LLM.
 *
 * @example `audio/wav` content
 * {@includeCode ./examples/AudioContent/audio-wav-content.json}
 *
 * @category Content
 */
export interface AudioContent {
  type: "audio";

  /**
   * The base64-encoded audio data.
   *
   * @format byte
   */
  data: string;

  /**
   * The MIME type of the audio. Different providers may support different audio types.
   */
  mimeType: string;

  /**
   * Optional annotations for the client.
   */
  annotations?: Annotations;

  _meta?: MetaObject;
}
```

### `ResourceLink` — artifact L1709–L1721

```ts
/**
 * A resource that the server is capable of reading, included in a prompt or tool call result.
 *
 * Note: resource links returned by tools are not guaranteed to appear in the results of {@link ListResourcesRequest | resources/list} requests.
 *
 * @example File resource link
 * {@includeCode ./examples/ResourceLink/file-resource-link.json}
 *
 * @category Content
 */
export interface ResourceLink extends Resource {
  type: "resource_link";
}
```

The whole declaration is one inherited set plus the tag: every `Resource` field, plus
`type`. §4.10.4's consequence follows directly — a `Resource` inside `resources/list`
has no `type`, and the same object inside a content block does.

### `EmbeddedResource` — artifact L1723–L1744

```ts
/**
 * The contents of a resource, embedded into a prompt or tool call result.
 *
 * It is up to the client how best to render embedded resources for the benefit
 * of the LLM and/or the user.
 *
 * @example Embedded file resource with annotations
 * {@includeCode ./examples/EmbeddedResource/embedded-file-resource-with-annotations.json}
 *
 * @category Content
 */
export interface EmbeddedResource {
  type: "resource";
  resource: TextResourceContents | BlobResourceContents;

  /**
   * Optional annotations for the client.
   */
  annotations?: Annotations;

  _meta?: MetaObject;
}
```

`resource` is a union of the same two arms `ReadResourceResult.contents` uses, with the
same absence of a discriminator.

## 7. `ResourceContents` and its two arms

### `ResourceContents` — artifact L1509–L1527

```ts
/**
 * The contents of a specific resource or sub-resource.
 *
 * @internal
 */
export interface ResourceContents {
  /**
   * The URI of this resource.
   *
   * @format uri
   */
  uri: string;
  /**
   * The MIME type of this resource, if known.
   */
  mimeType?: string;

  _meta?: MetaObject;
}
```

### `TextResourceContents` — artifact L1529–L1540

```ts
/**
 * @example Text file contents
 * {@includeCode ./examples/TextResourceContents/text-file-contents.json}
 *
 * @category Content
 */
export interface TextResourceContents extends ResourceContents {
  /**
   * The text of the item. This must only be set if the item can actually be represented as text (not binary data).
   */
  text: string;
}
```

### `BlobResourceContents` — artifact L1542–L1555

```ts
/**
 * @example Image file contents
 * {@includeCode ./examples/BlobResourceContents/image-file-contents.json}
 *
 * @category Content
 */
export interface BlobResourceContents extends ResourceContents {
  /**
   * A base64-encoded string representing the binary data of the item.
   *
   * @format byte
   */
  blob: string;
}
```

Nothing in the artifact discriminates these two. They differ only by which required
member each adds, so an object carrying both satisfies both arms and an object carrying
neither satisfies neither. That is §4.10.7's first and second bullets, and the artifact
confirms rather than contradicts them.

## 8. Element types the results reference

### `PromptMessage` and `Role` — artifact L1689–L1707

```ts
/**
 * The sender or recipient of messages and data in a conversation.
 *
 * @category Common Types
 */
export type Role = "user" | "assistant";

/**
 * Describes a message returned as part of a prompt.
 *
 * This is similar to {@link SamplingMessage}, but also supports the embedding of
 * resources from the MCP server.
 *
 * @category `prompts/get`
 */
export interface PromptMessage {
  role: Role;
  content: ContentBlock;
}
```

`content` is a single `ContentBlock`, not an array, and neither member is optional.

### `Prompt` and `PromptArgument` — artifact L1654–L1687

```ts
/**
 * A prompt or prompt template that the server offers.
 *
 * @category `prompts/list`
 */
export interface Prompt extends BaseMetadata, Icons {
  /**
   * An optional description of what this prompt provides
   */
  description?: string;

  /**
   * A list of arguments to use for templating the prompt.
   */
  arguments?: PromptArgument[];

  _meta?: MetaObject;
}

/**
 * Describes an argument that a prompt can accept.
 *
 * @category `prompts/list`
 */
export interface PromptArgument extends BaseMetadata {
  /**
   * A human-readable description of the argument.
   */
  description?: string;
  /**
   * Whether this argument must be provided.
   */
  required?: boolean;
}
```

### `Resource` and `ResourceTemplate` — artifact L1433–L1507

```ts
/**
 * A known resource that the server is capable of reading.
 *
 * @example File resource with annotations
 * {@includeCode ./examples/Resource/file-resource-with-annotations.json}
 *
 * @category `resources/list`
 */
export interface Resource extends BaseMetadata, Icons {
  /**
   * The URI of this resource.
   *
   * @format uri
   */
  uri: string;

  /**
   * A description of what this resource represents.
   *
   * This can be used by clients to improve the LLM's understanding of available resources. It can be thought of like a "hint" to the model.
   */
  description?: string;

  /**
   * The MIME type of this resource, if known.
   */
  mimeType?: string;

  /**
   * Optional annotations for the client.
   */
  annotations?: Annotations;

  /**
   * The size of the raw resource content, in bytes (i.e., before base64 encoding or any tokenization), if known.
   *
   * This can be used by Hosts to display file sizes and estimate context window usage.
   */
  size?: number;

  _meta?: MetaObject;
}

/**
 * A template description for resources available on the server.
 *
 * @category `resources/templates/list`
 */
export interface ResourceTemplate extends BaseMetadata, Icons {
  /**
   * A URI template (according to RFC 6570) that can be used to construct resource URIs.
   *
   * @format uri-template
   */
  uriTemplate: string;

  /**
   * A description of what this template is for.
   *
   * This can be used by clients to improve the LLM's understanding of available resources. It can be thought of like a "hint" to the model.
   */
  description?: string;

  /**
   * The MIME type for all resources that match this template. This should only be included if all resources matching this template have the same type.
   */
  mimeType?: string;

  /**
   * Optional annotations for the client.
   */
  annotations?: Annotations;

  _meta?: MetaObject;
}
```

Neither declares `type`. `Resource` declares `size?: number`, which §4.10 does not
enumerate; the row is listed here so the member set is complete.

### `Tool` and `ToolAnnotations` — artifact L1900–L2015

```ts
/**
 * Additional properties describing a {@link Tool} to clients.
 *
 * NOTE: all properties in `ToolAnnotations` are **hints**.
 * They are not guaranteed to provide a faithful description of
 * tool behavior (including descriptive properties like `title`).
 *
 * Clients should never make tool use decisions based on `ToolAnnotations`
 * received from untrusted servers.
 *
 * @category `tools/list`
 */
export interface ToolAnnotations {
  /**
   * A human-readable title for the tool.
   */
  title?: string;

  /**
   * If true, the tool does not modify its environment.
   *
   * Default: false
   */
  readOnlyHint?: boolean;

  /**
   * If true, the tool may perform destructive updates to its environment.
   * If false, the tool performs only additive updates.
   *
   * (This property is meaningful only when `readOnlyHint == false`)
   *
   * Default: true
   */
  destructiveHint?: boolean;

  /**
   * If true, calling the tool repeatedly with the same arguments
   * will have no additional effect on its environment.
   *
   * (This property is meaningful only when `readOnlyHint == false`)
   *
   * Default: false
   */
  idempotentHint?: boolean;

  /**
   * If true, this tool may interact with an "open world" of external
   * entities. If false, the tool's domain of interaction is closed.
   * For example, the world of a web search tool is open, whereas that
   * of a memory tool is not.
   *
   * Default: true
   */
  openWorldHint?: boolean;
}

/**
 * Definition for a tool the client can call.
 *
 * @example With default 2020-12 input schema
 * {@includeCode ./examples/Tool/with-default-2020-12-input-schema.json}
 *
 * @example With explicit draft-07 input schema
 * {@includeCode ./examples/Tool/with-explicit-draft-07-input-schema.json}
 *
 * @example With no parameters
 * {@includeCode ./examples/Tool/with-no-parameters.json}
 *
 * @example With output schema for structured content
 * {@includeCode ./examples/Tool/with-output-schema-for-structured-content.json}
 *
 * @category `tools/list`
 */
export interface Tool extends BaseMetadata, Icons {
  /**
   * A human-readable description of the tool.
   *
   * This can be used by clients to improve the LLM's understanding of available tools. It can be thought of like a "hint" to the model.
   */
  description?: string;

  /**
   * A JSON Schema object defining the expected parameters for the tool.
   *
   * Tool arguments are always JSON objects, so `type: "object"` is required at the root.
   * Beyond that, any JSON Schema 2020-12 keyword may appear alongside `type` — including
   * composition keywords (`oneOf`, `anyOf`, `allOf`, `not`), conditional keywords
   * (`if`/`then`/`else`), reference keywords (`$ref`, `$defs`, `$anchor`), and any other
   * standard validation or annotation keywords.
   *
   * Property schemas may carry an `x-mcp-header` annotation to mirror the
   * argument value into an HTTP header on the Streamable HTTP transport. See
   * the Streamable HTTP transport specification for the validity and
   * extraction rules.
   *
   * Defaults to JSON Schema 2020-12 when no explicit `$schema` is provided.
   */
  inputSchema: { $schema?: string; type: "object"; [key: string]: unknown };

  /**
   * An optional JSON Schema object defining the structure of the tool's output returned in
   * the structuredContent field of a {@link CallToolResult}. This can be any valid JSON Schema 2020-12.
   *
   * Defaults to JSON Schema 2020-12 when no explicit `$schema` is provided.
   */
  outputSchema?: { $schema?: string; [key: string]: unknown };

  /**
   * Optional additional tool information.
   *
   * Display name precedence order is: `title`, `annotations.title`, then `name`.
   */
  annotations?: ToolAnnotations;

  _meta?: MetaObject;
}
```

`ToolAnnotations` has five members and all five are optional. `inputSchema` is
required and its `type` is the literal `"object"`; `outputSchema` is optional and has
no `type` constraint. Both carry `[key: string]: unknown` — the open member set §4.10.4
treats as not library-typed.

### `Annotations` — artifact L2265–L2300

```ts
/**
 * Optional annotations for the client. The client can use annotations to inform how objects are used or displayed
 *
 * @category Common Types
 */
export interface Annotations {
  /**
   * Describes who the intended audience of this object or data is.
   *
   * It can include multiple entries to indicate content useful for multiple audiences (e.g., `["user", "assistant"]`).
   */
  audience?: Role[];

  /**
   * Describes how important this data is for operating the server.
   *
   * A value of 1 means "most important," and indicates that the data is
   * effectively required, while 0 means "least important," and indicates that
   * the data is entirely optional.
   *
   * @TJS-type number
   * @minimum 0
   * @maximum 1
   */
  priority?: number;

  /**
   * The moment the resource was last modified, as an ISO 8601 formatted string.
   *
   * Should be an ISO 8601 formatted string (e.g., "2025-01-12T15:00:58Z").
   *
   * Examples: last activity timestamp in an open file, timestamp when the resource
   * was attached, etc.
   */
  lastModified?: string;
}
```

`priority?: number` with `@minimum 0` / `@maximum 1` and no integer narrowing — the
basis for §4.10.7's fourth bullet.

### `BaseMetadata`, `Icons` and `Icon` — artifact L885–L969

```ts
/**
 * An optionally-sized icon that can be displayed in a user interface.
 *
 * @category Common Types
 */
export interface Icon {
  /**
   * A standard URI pointing to an icon resource. May be an HTTP/HTTPS URL or a
   * `data:` URI with Base64-encoded image data.
   *
   * Consumers SHOULD take steps to ensure URLs serving icons are from the
   * same domain as the client/server or a trusted domain.
   *
   * Consumers SHOULD take appropriate precautions when consuming SVGs as they can contain
   * executable JavaScript.
   *
   * @format uri
   */
  src: string;

  /**
   * Optional MIME type override if the source MIME type is missing or generic.
   * For example: `"image/png"`, `"image/jpeg"`, or `"image/svg+xml"`.
   */
  mimeType?: string;

  /**
   * Optional array of strings that specify sizes at which the icon can be used.
   * Each string should be in WxH format (e.g., `"48x48"`, `"96x96"`) or `"any"` for scalable formats like SVG.
   *
   * If not provided, the client should assume that the icon can be used at any size.
   */
  sizes?: string[];

  /**
   * Optional specifier for the theme this icon is designed for. `"light"` indicates
   * the icon is designed to be used with a light background, and `"dark"` indicates
   * the icon is designed to be used with a dark background.
   *
   * If not provided, the client should assume the icon can be used with any theme.
   */
  theme?: "light" | "dark";
}

/**
 * Base interface to add `icons` property.
 *
 * @internal
 */
export interface Icons {
  /**
   * Optional set of sized icons that the client can display in a user interface.
   *
   * Clients that support rendering icons MUST support at least the following MIME types:
   * - `image/png` - PNG images (safe, universal compatibility)
   * - `image/jpeg` (and `image/jpg`) - JPEG images (safe, universal compatibility)
   *
   * Clients that support rendering icons SHOULD also support:
   * - `image/svg+xml` - SVG images (scalable but requires security precautions)
   * - `image/webp` - WebP images (modern, efficient format)
   */
  icons?: Icon[];
}

/**
 * Base interface for metadata with name (identifier) and title (display name) properties.
 *
 * @internal
 */
export interface BaseMetadata {
  /**
   * Intended for programmatic or logical use, but used as a display name in past specs or fallback (if title isn't present).
   */
  name: string;

  /**
   * Intended for UI and end-user contexts — optimized to be human-readable and easily understood,
   * even by those unfamiliar with domain-specific terminology.
   *
   * If not provided, the name should be used for display (except for {@link Tool},
   * where `annotations.title` should be given precedence over using `name`,
   * if present).
   */
  title?: string;
}
```

`Icon.theme` is `"light" | "dark"` — a closed inline union, like `cacheScope` and with
no named alias in the artifact.

## 9. Capability and implementation declarations §4.8 and §4.10 lean on

Both capability interfaces are quoted in full below. `ServerCapabilities` was
already here for `DiscoverResult.capabilities`; `ClientCapabilities` is added
because §4.8 now carries a member table for each, and a member table with no
declaration behind it is exactly the gap this file exists to close. The section
closes with the one measurement the TypeScript source cannot make on its own —
whether any of these member sets is closed on the wire — and finding 11 records
why that measurement changed a claim this file had already made.

### `ClientCapabilities` — artifact L711–L786

```ts
/**
 * Capabilities a client may support. Known capabilities are defined here, in this schema, but this is not a closed set: any client can define its own, additional capabilities.
 *
 * @category `server/discover`
 */
export interface ClientCapabilities {
  /**
   * Experimental, non-standard capabilities that the client supports.
   */
  experimental?: { [key: string]: JSONObject };
  /**
   * Present if the client supports listing roots.
   *
   * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
   * Remains in the specification for at least twelve months; see the
   * deprecated features registry.
   *
   * @example Roots — minimum baseline support
   * {@includeCode ./examples/ClientCapabilities/roots-minimum-baseline-support.json}
   */
  // eslint-disable-next-line @typescript-eslint/no-empty-object-type
  roots?: {};
  /**
   * Present if the client supports sampling from an LLM.
   *
   * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
   * Remains in the specification for at least twelve months; see the
   * deprecated features registry.
   *
   * @example Sampling — minimum baseline support
   * {@includeCode ./examples/ClientCapabilities/sampling-minimum-baseline-support.json}
   *
   * @example Sampling — tool use support
   * {@includeCode ./examples/ClientCapabilities/sampling-tool-use-support.json}
   *
   * @example Sampling — context inclusion support (deprecated)
   * {@includeCode ./examples/ClientCapabilities/sampling-context-inclusion-support-deprecated.json}
   */
  sampling?: {
    /**
     * Whether the client supports context inclusion via `includeContext` parameter.
     * If not declared, servers SHOULD only use `includeContext: "none"` (or omit it).
     */
    context?: JSONObject;
    /**
     * Whether the client supports tool use via `tools` and `toolChoice` parameters.
     */
    tools?: JSONObject;
  };
  /**
   * Present if the client supports elicitation from the server.
   *
   * @example Elicitation — form and URL mode support
   * {@includeCode ./examples/ClientCapabilities/elicitation-form-and-url-mode-support.json}
   *
   * @example Elicitation — form mode only (implicit)
   * {@includeCode ./examples/ClientCapabilities/elicitation-form-only-implicit.json}
   */
  elicitation?: {
    form?: JSONObject;
    url?: JSONObject;
  };

  /**
   * Optional MCP extensions that the client supports. Keys are extension identifiers
   * (e.g., "io.modelcontextprotocol/oauth-client-credentials"), and values are
   * per-extension settings objects. An empty object indicates support with no settings.
   *
   * Keys MUST follow the {@link MetaObject | `_meta` key naming rules}, with a
   * mandatory prefix.
   *
   * @example Extensions — MCP Apps (UI) extension with MIME type support
   * {@includeCode ./examples/ClientCapabilities/extensions-ui-mime-types.json}
   */
  extensions?: { [key: string]: JSONObject };
}
```

Two shapes in it are not plain objects and are easy to mistranscribe. `roots?: {}`
is the **empty** object type — any JSON object satisfies it, which is why the
artifact carries an `eslint-disable-next-line
@typescript-eslint/no-empty-object-type` comment on that line (L731) and
declares no member for it. And `elicitation.form` and `elicitation.url` carry
**no JSDoc at all** (L769–L772), unlike `sampling.context` and `sampling.tools`;
the only prose about them is in `client/elicitation.md`, which
[`mcp-2026-07-28.md`](mcp-2026-07-28.md) §6 quotes. `ClientCapabilities`
declares no required member: all five of its members are optional.

### `ServerCapabilities` — artifact L788–L883

```ts
/**
 * Capabilities that a server may support. Known capabilities are defined here, in this schema, but this is not a closed set: any server can define its own, additional capabilities.
 *
 * @category `server/discover`
 */
export interface ServerCapabilities {
  /**
   * Experimental, non-standard capabilities that the server supports.
   */
  experimental?: { [key: string]: JSONObject };
  /**
   * Present if the server supports sending log messages to the client.
   *
   * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
   * Remains in the specification for at least twelve months; see the
   * deprecated features registry.
   *
   * @example Logging — minimum baseline support
   * {@includeCode ./examples/ServerCapabilities/logging-minimum-baseline-support.json}
   */
  logging?: JSONObject;
  /**
   * Present if the server supports argument autocompletion suggestions.
   *
   * @example Completions — minimum baseline support
   * {@includeCode ./examples/ServerCapabilities/completions-minimum-baseline-support.json}
   */
  completions?: JSONObject;
  /**
   * Present if the server offers any prompt templates.
   *
   * @example Prompts — minimum baseline support
   * {@includeCode ./examples/ServerCapabilities/prompts-minimum-baseline-support.json}
   *
   * @example Prompts — list changed notifications
   * {@includeCode ./examples/ServerCapabilities/prompts-list-changed-notifications.json}
   */
  prompts?: {
    /**
     * Whether this server supports notifications for changes to the prompt list.
     */
    listChanged?: boolean;
  };
  /**
   * Present if the server offers any resources to read.
   *
   * @example Resources — minimum baseline support
   * {@includeCode ./examples/ServerCapabilities/resources-minimum-baseline-support.json}
   *
   * @example Resources — subscription to individual resource updates (only)
   * {@includeCode ./examples/ServerCapabilities/resources-subscription-to-individual-resource-updates-only.json}
   *
   * @example Resources — list changed notifications (only)
   * {@includeCode ./examples/ServerCapabilities/resources-list-changed-notifications-only.json}
   *
   * @example Resources — all notifications
   * {@includeCode ./examples/ServerCapabilities/resources-all-notifications.json}
   */
  resources?: {
    /**
     * Whether this server supports subscribing to resource updates.
     */
    subscribe?: boolean;
    /**
     * Whether this server supports notifications for changes to the resource list.
     */
    listChanged?: boolean;
  };
  /**
   * Present if the server offers any tools to call.
   *
   * @example Tools — minimum baseline support
   * {@includeCode ./examples/ServerCapabilities/tools-minimum-baseline-support.json}
   *
   * @example Tools — list changed notifications
   * {@includeCode ./examples/ServerCapabilities/tools-list-changed-notifications.json}
   */
  tools?: {
    /**
     * Whether this server supports notifications for changes to the tool list.
     */
    listChanged?: boolean;
  };
  /**
   * Optional MCP extensions that the server supports. Keys are extension identifiers
   * (e.g., "io.modelcontextprotocol/tasks"), and values are per-extension settings
   * objects. An empty object indicates support with no settings.
   *
   * Keys MUST follow the {@link MetaObject | `_meta` key naming rules}, with a
   * mandatory prefix.
   *
   * @example Extensions — Tasks extension support
   * {@includeCode ./examples/ServerCapabilities/extensions-tasks.json}
   */
  extensions?: { [key: string]: JSONObject };
}
```

### `Implementation` — artifact L971–L997

```ts
/**
 * Describes the MCP implementation.
 *
 * @category `server/discover`
 */
export interface Implementation extends BaseMetadata, Icons {
  /**
   * The version of this implementation.
   */
  version: string;

  /**
   * An optional human-readable description of what this implementation does.
   *
   * This can be used by clients or servers to provide context about their purpose
   * and capabilities. For example, a server might describe the types of resources
   * or tools it provides, while a client might describe its intended use case.
   */
  description?: string;

  /**
   * An optional URL of the website for this implementation.
   *
   * @format uri
   */
  websiteUrl?: string;
}
```

### The two "not a closed set" sentences

A search of all 3,197 lines for that phrase returns exactly two hits, and both are
doc comments on capability objects:

- artifact L712, `ClientCapabilities`: *"Capabilities a client may support. Known
  capabilities are defined here, in this schema, but this is not a closed set: any
  client can define its own, additional capabilities."*
- artifact L789, `ServerCapabilities`: *"Capabilities that a server may support. Known
  capabilities are defined here, in this schema, but this is not a closed set: any
  server can define its own, additional capabilities."*

That is the whole of the artifact's guidance about **open** sets, and it is about
member sets, not about values. It is also the only place the artifact says anything
about openness at all — no interface is ever marked open by an index signature alone,
and the one place a **value** set is meant to be open, `ResultType`, says so with a
`\| string` arm instead. The census below turns that idiom into a measurement.

### The generated JSON Schema, and the `additionalProperties` census

`schema.ts` is the normative source, but it is TypeScript, and a TypeScript index
signature is a compile-time construct: it constrains what a *writer* may put in an
object literal, not what a peer may put on the wire. The construct that closes a
member set on the wire is `additionalProperties: false`, and this protocol never uses
it. Both artifacts, fetched 2026-10-01 at the commit pinned above:

| Artifact | sha256 | `additionalProperties` | `unevaluatedProperties` | `…: false` |
| --- | --- | --- | --- | --- |
| `schema/2026-07-28/schema.ts` — 3,197 lines, 98,426 bytes | `742750af…2cd` | **0** | **0** | **0** |
| `schema/2026-07-28/schema.json` — 3,963 lines, 181,474 bytes | `ef70b61f…0203` | **20** | **0** | **0** |

The `main` ref serves the same bytes for the JSON Schema as for the TypeScript:
fetched separately from the commit-pinned URL and compared, `cmp` reports no
difference — 181,474 bytes, 3,963 lines, `ef70b61f…0203` from both. Both digests
are over the raw HTTP response body, never over reader output.

Not one of the twenty is `false`. Fifteen are typed maps —
`JSONObject` → `{"$ref": "#/$defs/JSONValue"}`, `ClientCapabilities` and
`ServerCapabilities` `.experimental` and `.extensions`, `InputRequests`,
`InputResponses`, `CallToolRequestParams.arguments`,
`CompleteRequestParams.context…arguments`, `GetPromptRequestParams.arguments`,
`ElicitRequestFormParams.requestedSchema…properties`, `ElicitResult.content`,
`Tool.inputSchema`, `Tool.outputSchema`, `ToolUseContent.input` — and five are the
bare `{}` that admits any value, on `Result` and on the `params` of `Request`,
`Notification`, `JSONRPCRequest` and `JSONRPCNotification`.

Two things follow, and together they are why the word *closed* is withdrawn wherever
this file applied it to a **member set**:

- **No object type in the schema is closed.** Every nested object read — `elicitation`,
  `sampling`, `prompts`, `resources`, `tools`, the six notification params
  interfaces, `SubscriptionFilter`, `TextContent`, `Tool`, `Prompt`, `Resource`,
  `ResourceContents` — carries **no** `additionalProperties` keyword at all, and under
  draft 2020-12 an absent keyword permits undeclared properties. The generated schema
  therefore positively **allows** a key the type does not name. The limiting case is
  `ClientCapabilities.roots`: `"properties": {}` with no `additionalProperties`, so
  any JSON object satisfies it, exactly as `roots?: {}` does in the TypeScript.
- **A value set is a different question, and it is closed where the artifact says so.**
  `ContentBlock`'s five arms emit `"type": {"const": "text"}` … `{"const": "resource"}`,
  and `LoggingLevel` emits an `enum` of eight literals, so those are closed at the
  wire level. The requiredness of §10's `progressToken` pair is visible here too:
  `RequestMetaObject.required` is
  `["io.modelcontextprotocol/clientCapabilities","io.modelcontextprotocol/protocolVersion"]`
  — `progressToken` is **not** in it — while `ProgressNotificationParams.required` is
  `["progress","progressToken"]`. That is the wire-level form of the opt-in argument
  quoted at §10.

## 10. Notification declarations

`PROTOCOLS.md` §4.11 needs these. Before this section the eight notification
shapes were reachable only through [`mcp-2026-07-28.md`](mcp-2026-07-28.md) §1b,
which tabulates them in one line each, so the requiredness of every member, the
inherited `_meta`, and the two dependent types they share were all unverified
against a declaration anywhere in this directory.

### The notification base chain — artifact L191–L206, L273–L280

```ts
/**
 * Common params for any notification.
 *
 * @category Common Types
 */
export interface NotificationParams {
  _meta?: NotificationMetaObject;
}

/** @internal */
export interface Notification {
  method: string;
  // Allow unofficial extensions of `Notification.params` without impacting `NotificationParams`.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  params?: { [key: string]: any };
}
```

```ts
/**
 * A notification which does not expect a response.
 *
 * @category JSON-RPC
 */
export interface JSONRPCNotification extends Notification {
  jsonrpc: typeof JSONRPC_VERSION;
}
```

`NotificationParams` has exactly **one** member and it is **optional**
 (`_meta?: NotificationMetaObject`, L197), which is the inherited `_meta` every
one of the eight shapes below gets for free. `Notification` is the open layer:
its `params?: { [key: string]: any }` (L205) exists so unofficial extensions do
not have to touch `NotificationParams`, and each of the eight narrows `params`
again in its own declaration — five to a named params interface, three to
`NotificationParams` directly.

`JSONRPCNotification` contributes `jsonrpc: typeof JSONRPC_VERSION` and
**no `id`**, which is the whole of the difference from `JSONRPCRequest` and the
reason a notification never correlates with a response.

### `NotificationMetaObject` — artifact L113–L134

```ts
/**
 * Extends {@link MetaObject} with additional notification-specific fields. All key naming rules from `MetaObject` apply.
 *
 * @see {@link MetaObject} for key naming rules and reserved prefixes.
 * @see [General fields: `_meta`](/specification/2026-07-28/basic/index#meta) for more details.
 * @category Common Types
 */
export interface NotificationMetaObject extends MetaObject {
  /**
   * Identifies the subscription stream a notification was delivered on. The
   * server MUST include this key on every notification delivered via a
   * {@link SubscriptionsListenRequest | subscriptions/listen} stream, so the
   * client can correlate the notification with the originating subscription.
   * The key is absent on notifications not delivered via a subscription
   * stream (e.g. progress notifications for an in-flight request), which is
   * why it is optional here.
   *
   * The value is the JSON-RPC ID of the `subscriptions/listen` request that
   * opened the stream.
   */
  "io.modelcontextprotocol/subscriptionId"?: RequestId;
}
```

`MetaObject = Record<string, unknown>` (L54, quoted in §1), so a notification's
`_meta` is **open**. The one named key is optional in the type and required by
the doc comment **conditionally**: *"The server MUST include this key on every
notification delivered via a `subscriptions/listen` stream"* and *"The key is
absent on notifications not delivered via a subscription stream (e.g. progress
notifications for an in-flight request), which is why it is optional here."*
The requirement is therefore established and scoped, not a silence.

### `ProgressToken`, and the two places it appears — artifact L160–L165, L63–L67, L1009–L1013

```ts
/**
 * A progress token, used to associate progress notifications with the original request.
 *
 * @category Common Types
 */
export type ProgressToken = string | number;
```

```ts
export interface RequestMetaObject extends MetaObject {
  /**
   * If specified, the caller is requesting out-of-band progress notifications for this request (as represented by {@link ProgressNotification | notifications/progress}). The value of this parameter is an opaque token that will be attached to any subsequent notifications. The receiver is not obligated to provide these notifications.
   */
  progressToken?: ProgressToken;
```

```ts
export interface ProgressNotificationParams extends NotificationParams {
  /**
   * The progress token which was given in the initial request, used to associate this notification with the request that is proceeding.
   */
  progressToken: ProgressToken;
```

**These two are not in tension, and the difference is the whole point.**
`RequestMetaObject.progressToken` (L67) is `progressToken?:` — **optional**, an
opt-in: *"If specified, the caller is requesting out-of-band progress
notifications… The receiver is not obligated to provide these notifications."*
`ProgressNotificationParams.progressToken` (L1013) is `progressToken:` —
**required**, and it is a payload member of the notification, not a `_meta` key
at all. A sender that opted in must echo the token it was given; a receiver that
sends the notification at all must have received the opt-in, which is what makes
the required member well formed. The first is a `RequestMetaObject` key, the
second is a `ProgressNotificationParams` member; §4.11 states both.

### `CancelledNotification` — artifact L612–L651

```ts
/**
 * Parameters for a `notifications/cancelled` notification.
 *
 * @example User-requested cancellation
 * {@includeCode ./examples/CancelledNotificationParams/user-requested-cancellation.json}
 *
 * @category `notifications/cancelled`
 */
export interface CancelledNotificationParams extends NotificationParams {
  /**
   * The ID of the request to cancel.
   *
   * This MUST correspond to the ID of a request the client previously issued.
   */
  requestId: RequestId;

  /**
   * An optional string describing the reason for the cancellation. This MAY be logged or presented to the user.
   */
  reason?: string;
}

/**
 * This notification is sent by the client to indicate that it is cancelling a request it previously issued.
 *
 * On stdio, the server also sends this notification, solely to terminate a {@link SubscriptionsListenRequest | subscriptions/listen} stream: it references the ID of the `subscriptions/listen` request that opened the stream. Servers MUST NOT use this notification to cancel any other request.
 *
 * The request SHOULD still be in-flight, but due to communication latency, it is always possible that this notification MAY arrive after the request has already finished.
 *
 * This notification indicates that the result will be unused, so any associated processing SHOULD cease.
 *
 * @example User-requested cancellation
 * {@includeCode ./examples/CancelledNotification/user-requested-cancellation.json}
 *
 * @category `notifications/cancelled`
 */
export interface CancelledNotification extends JSONRPCNotification {
  method: "notifications/cancelled";
  params: CancelledNotificationParams;
}
```

The only one of the eight with a **requiredness requirement in prose**: `requestId`
is required by the type and *"This MUST correspond to the ID of a request the
client previously issued"* (L624). `params` itself is required here — one of
five.

### `ProgressNotification` — artifact L1001–L1043

```ts
/**
 * Parameters for a {@link ProgressNotification | notifications/progress} notification.
 *
 * @example Progress message
 * {@includeCode ./examples/ProgressNotificationParams/progress-message.json}
 *
 * @category `notifications/progress`
 */
export interface ProgressNotificationParams extends NotificationParams {
  /**
   * The progress token which was given in the initial request, used to associate this notification with the request that is proceeding.
   */
  progressToken: ProgressToken;
  /**
   * The progress thus far. This should increase every time progress is made, even if the total is unknown.
   *
   * @TJS-type number
   */
  progress: number;
  /**
   * Total number of items to process (or total progress required), if known.
   *
   * @TJS-type number
   */
  total?: number;
  /**
   * An optional message describing the current progress.
   */
  message?: string;
}

/**
 * An out-of-band notification used to inform the receiver of a progress update for a long-running request.
 *
 * @example Progress message
 * {@includeCode ./examples/ProgressNotification/progress-message.json}
 *
 * @category `notifications/progress`
 */
export interface ProgressNotification extends JSONRPCNotification {
  method: "notifications/progress";
  params: ProgressNotificationParams;
}
```

`progress: number` is required and unbounded — *"This should increase every time
progress is made, even if the total is unknown"* — while `total?` is optional, so
`progress` alone is a well-formed params object. Both carry `@TJS-type number`,
which is a typebox generation hint and not a constraint: neither is narrowed to
an integer and neither carries `@minimum`.

### `SubscriptionFilter` — artifact L1261–L1288

```ts
/**
 * The set of notification types a client may opt in to on a
 * {@link SubscriptionsListenRequest | subscriptions/listen} request.
 *
 * Each notification type is **opt-in**; the server **MUST NOT** send
 * notification types the client has not explicitly requested here.
 *
 * @category `subscriptions/listen`
 */
export interface SubscriptionFilter {
  /**
   * If true, receive {@link ToolListChangedNotification | notifications/tools/list_changed}.
   */
  toolsListChanged?: boolean;
  /**
   * If true, receive {@link PromptListChangedNotification | notifications/prompts/list_changed}.
   */
  promptsListChanged?: boolean;
  /**
   * If true, receive {@link ResourceListChangedNotification | notifications/resources/list_changed}.
   */
  resourcesListChanged?: boolean;
  /**
   * Subscribe to {@link ResourceUpdatedNotification | notifications/resources/updated} for these resource URIs.
   * Replaces the former `resources/subscribe` RPC.
   */
  resourceSubscriptions?: string[];
}
```

Four members, all optional. It is the type of
`SubscriptionsListenRequestParams.notifications`, which is **required** (L1301),
and of `SubscriptionsAcknowledgedNotificationParams.notifications`, also
**required** (L1378) — so an empty filter `{}` is well formed and means "nothing
opted in", while a request without the member is not.

### The three `list_changed` notifications — artifact L1248–L1259, L1745–L1756, L1887–L1898

```ts
/**
 * An optional notification from the server to the client, informing it that the list of resources it can read from has changed. This is only delivered on a {@link SubscriptionsListenRequest | subscriptions/listen} stream when the client requested it via the `resourcesListChanged` filter field.
 *
 * @example Resources list changed
 * {@includeCode ./examples/ResourceListChangedNotification/resources-list-changed.json}
 *
 * @category `notifications/resources/list_changed`
 */
export interface ResourceListChangedNotification extends JSONRPCNotification {
  method: "notifications/resources/list_changed";
  params?: NotificationParams;
}
```

```ts
/**
 * An optional notification from the server to the client, informing it that the list of prompts it offers has changed. This is only delivered on a {@link SubscriptionsListenRequest | subscriptions/listen} stream when the client requested it via the `promptsListChanged` filter field.
 *
 * @example Prompts list changed
 * {@includeCode ./examples/PromptListChangedNotification/prompts-list-changed.json}
 *
 * @category `notifications/prompts/list_changed`
 */
export interface PromptListChangedNotification extends JSONRPCNotification {
  method: "notifications/prompts/list_changed";
  params?: NotificationParams;
}
```

```ts
/**
 * An optional notification from the server to the client, informing it that the list of tools it offers has changed. This is only delivered on a {@link SubscriptionsListenRequest | subscriptions/listen} stream when the client requested it via the `toolsListChanged` filter field.
 *
 * @example Tools list changed
 * {@includeCode ./examples/ToolListChangedNotification/tools-list-changed.json}
 *
 * @category `notifications/tools/list_changed`
 */
export interface ToolListChangedNotification extends JSONRPCNotification {
  method: "notifications/tools/list_changed";
  params?: NotificationParams;
}
```

These three are the **only** ones whose `params` is optional
 (`params?: NotificationParams`, L1258, L1755, L1897), and the only ones that
declare no params interface of their own. Each carries nothing but the inherited
optional `_meta`, so the notification's whole payload is its method string. All
three name their `SubscriptionFilter` member in the doc comment, which is the
one place a filter is linked to the notification it gates.

### `SubscriptionsAcknowledgedNotification` — artifact L1366–L1401

```ts
/**
 * Parameters for a {@link SubscriptionsAcknowledgedNotification | notifications/subscriptions/acknowledged} notification.
 *
 * @category `notifications/subscriptions/acknowledged`
 */
export interface SubscriptionsAcknowledgedNotificationParams extends NotificationParams {
  /**
   * The subset of requested notification types the server agreed to honor.
   * Only includes notification types the server actually supports; if the
   * client requested an unsupported type (e.g., `promptsListChanged` when
   * the server has no prompts), it is omitted from this set.
   */
  notifications: SubscriptionFilter;
}

/**
 * Sent by the server to acknowledge that a
 * {@link SubscriptionsListenRequest | subscriptions/listen} subscription has been
 * established and to report which notification types it agreed to honor.
 *
 * This notification MUST be the first message the server sends carrying the
 * subscription's ID in `io.modelcontextprotocol/subscriptionId`. The server MUST
 * NOT send any notification on the subscription before acknowledging it. On
 * stdio, where every subscription shares one channel, this ordering is defined
 * per subscription ID and not per channel: messages belonging to other
 * subscriptions MAY be interleaved before it.
 *
 * @example Listen acknowledged
 * {@includeCode ./examples/SubscriptionsAcknowledgedNotification/listen-acknowledged.json}
 *
 * @category `notifications/subscriptions/acknowledged`
 */
export interface SubscriptionsAcknowledgedNotification extends JSONRPCNotification {
  method: "notifications/subscriptions/acknowledged";
  params: SubscriptionsAcknowledgedNotificationParams;
}
```

The only notification whose doc comment carries an **ordering MUST**: it MUST be
the first message carrying that subscription's
`io.modelcontextprotocol/subscriptionId`, and no notification on the
subscription may precede it — scoped per subscription ID, not per channel, so
interleaving from other subscriptions is allowed.

### `ResourceUpdatedNotification` — artifact L1403–L1431

```ts
/**
 * Parameters for a `notifications/resources/updated` notification.
 *
 * @example File resource updated
 * {@includeCode ./examples/ResourceUpdatedNotificationParams/file-resource-updated.json}
 *
 * @category `notifications/resources/updated`
 */
export interface ResourceUpdatedNotificationParams extends NotificationParams {
  /**
   * The URI of the resource that has been updated. This might be a sub-resource of the one that the client actually subscribed to.
   *
   * @format uri
   */
  uri: string;
}

/**
 * A notification from the server to the client, informing it that a resource has changed and may need to be read again. This is only sent for resources the client opted in to via the `resourceSubscriptions` field of a {@link SubscriptionsListenRequest | subscriptions/listen} request.
 *
 * @example File resource updated notification
 * {@includeCode ./examples/ResourceUpdatedNotification/file-resource-updated-notification.json}
 *
 * @category `notifications/resources/updated`
 */
export interface ResourceUpdatedNotification extends JSONRPCNotification {
  method: "notifications/resources/updated";
  params: ResourceUpdatedNotificationParams;
}
```

`uri` is required and carries `@format uri`. That is a JSDoc format hint and the
artifact declares no pattern or format constraint on it in the type system, so a
decoder validates nothing beyond "a string is present" — the same limit 4.10
records for other `@format`-hinted strings.

### `LoggingMessageNotification` and `LoggingLevel` — artifact L2019–L2083

```ts
/**
 * Parameters for a `notifications/message` notification.
 *
 * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
 * Remains in the specification for at least twelve months; see the
 * deprecated features registry.
 *
 * @example Log database connection failed
 * {@includeCode ./examples/LoggingMessageNotificationParams/log-database-connection-failed.json}
 *
 * @category `notifications/message`
 */
export interface LoggingMessageNotificationParams extends NotificationParams {
  /**
   * The severity of this log message.
   */
  level: LoggingLevel;
  /**
   * An optional name of the logger issuing this message.
   */
  logger?: string;
  /**
   * The data to be logged, such as a string message or an object. Any JSON serializable type is allowed here.
   */
  data: unknown;
}

/**
 * JSONRPCNotification of a log message passed from server to client. The client opts in by setting `"io.modelcontextprotocol/logLevel"` in a request's `_meta`.
 *
 * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
 * Remains in the specification for at least twelve months; see the
 * deprecated features registry.
 *
 * @example Log database connection failed
 * {@includeCode ./examples/LoggingMessageNotification/log-database-connection-failed.json}
 *
 * @category `notifications/message`
 */
export interface LoggingMessageNotification extends JSONRPCNotification {
  method: "notifications/message";
  params: LoggingMessageNotificationParams;
}

/**
 * The severity of a log message.
 *
 * These map to syslog message severities, as specified in RFC-5424:
 * https://datatracker.ietf.org/doc/html/rfc5424#section-6.2.1
 *
 * @deprecated Deprecated as of protocol version 2026-07-28 (SEP-2577).
 * Remains in the specification for at least twelve months; see the
 * deprecated features registry.
 *
 * @category Common Types
 */
export type LoggingLevel =
  | "debug"
  | "info"
  | "notice"
  | "warning"
  | "error"
  | "critical"
  | "alert"
  | "emergency";
```

`data: unknown` is required and unconstrained — *"Any JSON serializable type is
allowed here"* — so it is **not** a string and not an object; a decoder that
narrowed it to either would refuse a legal notification. `level` is required and
is the same eight-member closed union the artifact types for
`RequestMetaObject["io.modelcontextprotocol/logLevel"]` (L110). Three
declarations in this block carry `@deprecated` — both interfaces and the union —
all SEP-2577.

### The two notification unions — artifact L3165–L3166, L3173–L3182

```ts
/** @internal */
export type ClientNotification = CancelledNotification;
```

```ts
/** @internal */
export type ServerNotification =
  | CancelledNotification
  | ProgressNotification
  | LoggingMessageNotification
  | ResourceUpdatedNotification
  | ResourceListChangedNotification
  | ToolListChangedNotification
  | PromptListChangedNotification
  | SubscriptionsAcknowledgedNotification;
```

`ServerNotification` has exactly **eight** arms and `ClientNotification`
exactly **one**. `CancelledNotification` is in **both**, which is why 4.11 gives
it a direction of its own and §4.4 lists it under "both".

### Counts, mechanically

Counted over the 3,197-line artifact, not read off the prose above:

| Set | Count | How counted |
| --- | --- | --- |
| Interfaces extending `JSONRPCNotification` | **8** | `^export interface \w+Notification extends JSONRPCNotification \{` |
| Notifications declaring their own params interface | **5** — `Cancelled`, `Progress`, `ResourceUpdated`, `SubscriptionsAcknowledged`, `LoggingMessage` | `params: <Name>NotificationParams;` |
| Notifications with required `params` | **5** — the same five | `^  params: \w+NotificationParams;$` |
| Notifications with optional `params` | **3** — the three `list_changed` | `^  params\?: NotificationParams;$` |
| Distinct notification method strings | **8** | one `method: "notifications/…"` literal per interface |
| `SubscriptionFilter` members | **4**, all optional | L1274, L1278, L1282, L1287 |
| `LoggingLevel` literals | **8**, closed | L2076–L2083 |
| `ProgressToken` arms | **2** — `string \| number` | L165 |
| `NotificationParams` members | **1** — `_meta?` | L197 |

The eight method strings, each declared exactly once: `notifications/cancelled`
(L649), `notifications/progress` (L1041), `notifications/resources/list_changed`
(L1257), `notifications/subscriptions/acknowledged` (L1399),
`notifications/resources/updated` (L1429),
`notifications/prompts/list_changed` (L1754),
`notifications/tools/list_changed` (L1896) and `notifications/message` (L2059).

### Open and closed, for the notification side

| Set | Status | Evidence |
| --- | --- | --- |
| Members of any notification params interface | **Declared members only** — closing is **NOT ESTABLISHED** | The six interfaces — `NotificationParams` plus the five named ones — declare exactly the members quoted above and no index signature. That fixes the *declared* set. It does not close the set: `schema.ts` contains no `additionalProperties` and no `unevaluatedProperties`, and in the generated `schema.json` none of the six carries `additionalProperties` at all, so undeclared keys are permitted. `_meta`, which each inherits, is separately open by type |
| A notification's `_meta` | **Open** | `NotificationMetaObject extends MetaObject`, and `MetaObject = Record<string, unknown>` (L54) |
| `params` on the `Notification` base interface | **Open** — `{ [key: string]: any }` | L205. Narrowed by each of the eight; the base form is what an unofficial extension uses |
| `LoggingLevel` | **Closed** — 8 literals | L2075–L2083. No `\| string` arm |
| `data` on `LoggingMessageNotificationParams` | **Open** — `unknown` | L2043, *"Any JSON serializable type is allowed here"* |
| `ProgressToken` | **Closed** — `string \| number` | L165 |

Unlike `Result`, no notification params object carries an index signature, so none of
them *invites* an undeclared key the way `Result` does — but the census above shows
that none of them is closed either, and the two facts are not the same fact. What the
source fixes for a notification params object is its declared member set and the
requiredness of each member; what a peer may send beyond that is not addressed by any
primary source, so it is recorded as a silence at `PROTOCOLS.md` §4.11.5 rather than
asserted here.

## 11. What the artifact fixes, as counts and sets

These are read off the `extends` clauses and the declarations above, not inferred.

| Set | Members | Evidence |
| --- | --- | --- |
| `*ResultResponse` interfaces | **10** | §3 |
| Results that may answer with `InputRequiredResult` | **3** — `ReadResourceResultResponse`, `GetPromptResultResponse`, `CallToolResultResponse` | §3 |
| `ServerResult` arms | **12** | artifact L3184–L3197 |
| Results extending `CacheableResult` | **6** — `DiscoverResult`, `ListToolsResult`, `ListPromptsResult`, `ListResourcesResult`, `ListResourceTemplatesResult`, `ReadResourceResult` | artifact L678, L1779, L1578, L1133, L1169, L1229 |
| Results extending `PaginatedResult` | **4** — `ListToolsResult`, `ListPromptsResult`, `ListResourcesResult`, `ListResourceTemplatesResult` | artifact L1779, L1578, L1133, L1169 |
| Results extending both | **4** — the same four | as above |
| Results that are cacheable but not paginated | **2** — `DiscoverResult`, `ReadResourceResult` | artifact L678, L1229 |
| Results extending `Result` alone | **5** — `CompleteResult`, `GetPromptResult`, `CallToolResult`, `SubscriptionsListenResult`, `InputRequiredResult` | artifact L2644, L1634, L1809, L1349, L584 |
| Requests extending `PaginatedRequest` | **4** — `ListToolsRequest`, `ListPromptsRequest`, `ListResourcesRequest`, `ListResourceTemplatesRequest` | artifact L1767, L1566, L1121, L1157 |
| `ContentBlock` arms | **5** | artifact L2305–L2306 |
| `SamplingMessageContentBlock` arms | **5**, a *different* five — drops `ResourceLink` and `EmbeddedResource`, adds `ToolUseContent` and `ToolResultContent`; shared members with `ContentBlock`: **3** | artifact L2258–L2263 |
| `ResourceContents` arms | **2**, undiscriminated | artifact L1535, L1548 |
| `ServerResult` arms that have a method | **11** of 12; `EmptyResult` has none | §3, artifact L534 |
| Result arrays carrying a numeric bound | **1** — `CompleteResult.completion.values`, `@maxItems 100` | artifact L2649 |
| `ServerNotification` arms | **8** | artifact L3173–L3182, §10 |
| `ClientNotification` arms | **1** — `CancelledNotification` | artifact L3165–L3166, §10 |
| Notifications in both unions | **1** — `CancelledNotification` | artifact L3166, L3175 |
| Notifications with required `params` | **5** | §10 |
| Notifications with optional `params` | **3** — the three `list_changed` | §10 |
| Notifications declaring their own params interface | **5** | §10 |
| `SubscriptionFilter` members | **4**, all optional | artifact L1270–L1288 |
| `LoggingLevel` literals | **8**, closed | artifact L2075–L2083 |
| Capability members that name a notification method or carry its payload | **0** | §9, §10. `ServerCapabilities.prompts.listChanged`, `.resources.subscribe`, `.resources.listChanged` and `.tools.listChanged` are `boolean` members that state whether a notification is emitted; they are not the payload, and the `notifications/*` string occurs in no capability interface |

`nextCursor` appears in exactly one declaration in the whole artifact,
`PaginatedResult` at L1073. Any result that is not one of the four above inherits no
`nextCursor` member.

## Findings for `PROTOCOLS.md` §4.8, §4.10 and §4.11

Read off the artifact. Each carries a status. `PROTOCOLS.md` and `src/mcp.zig` are
being revised against this list, so the statuses are the record of what was checked
and what happened to it; nothing here is deleted when it is fixed. Items 1–8 concern
§4.10; items 9 and 10 are the two contract **gaps** found while building §4.8 and
§4.11 — a shape §4.8 promised but did not carry, and payloads §4.4 named but
`PROTOCOLS.md` never stated. Those two are gaps rather than disagreements: nothing
in the artifact or the sibling was wrong, so there was no conflict to resolve and
no prior value to overturn.

**Two classes of reference in this section, with different durability.** Every
`artifact L…` cite is pinned by the sha256 above and is immutable as long as that
digest holds. Every quotation of `PROTOCOLS.md`, of the sibling document, and of
`src/mcp.zig` is a reading of a file under concurrent edit, and carries the date it
was read, not a guarantee: the items below were verified against those files rather
than against a description of a change to them, but a later editor can move the text
out from under a quotation here. Where a quotation and the artifact disagree, the
artifact wins and the quotation is the stale side — so re-read the quoted file before
relying on any of these statuses.

1. **APPLIED. §4.10.2's `PaginatedResult` row over-counted by one and miscounted which
   result.** The row read *"The same six minus `ReadResourceResult`, which is cacheable
   but **not** paginated"*, naming five paginated results and including
   `DiscoverResult`. `DiscoverResult extends CacheableResult` (L678) and does not extend
   `PaginatedResult`, so the artifact's paginated set is the **four** list results. The
   same subsection contradicted itself a paragraph later, where §4.10 said *"the four
   list results are the only ones that do"* carry `nextCursor`, and
   [`mcp-2026-07-28.md`](mcp-2026-07-28.md) §5 already recorded `DiscoverResult` as
   `CacheableResult` only. §4.10.2 now reads **4** with the four named, the
   `CacheableResult` row is marked **6**, a new paragraph names `DiscoverResult` and
   `ReadResourceResult` as the two cacheable-not-paginated, and the §4.10 preamble
   records that §4.10 contradicted itself inside 4.10.2.

   The preamble now goes further, and this record was corrected to match rather than to
   anticipate: *"The error was that one cell and nothing else: 4.10.3's `DiscoverResult`
   table, 4.10.5's sequence row for that result, and this subsection's own closing
   paragraph were already right, so an auditor has three agreeing places to check the
   corrected cell against rather than one."* All three were verified against the file
   before this sentence was written: 4.10.3's `DiscoverResult` table lists
   `supportedVersions`, `capabilities`, `instructions`, `ttlMs` and `cacheScope` and no
   `nextCursor`; 4.10.5's row is `| DiscoverResult | supportedVersions | string |`,
   with no page column; and the closing paragraph states that the four list methods are
   paginated on both sides and that `nextCursor` is declared exactly once in the
   artifact. An earlier draft of this item asserted the three agreed and found the
   preamble silent on it — true of the artifact, false of the authority. A record that
   certifies a fix the document does not contain is worse than no record, so the item
   was rewritten against the text rather than against what the text ought to say.

2. **APPLIED. §4.10.6's `CacheScope` row named a type the artifact does not declare.**
   The artifact writes `cacheScope: "public" | "private";` inline (L1109) and the string
   `CacheScope` occurs zero times in all 3,197 lines; the name belongs to
   `mcp.CacheScope` in `src/mcp.zig`. The row's *claim* — that the set is closed — was
   correct and the inline union supports it. The row is now named *"`Role`,
   `Icon.theme`, the `cacheScope` literal union"* and states that the artifact declares
   no alias.

3. **APPLIED. §4.10.2 said both bases are marked `/** @internal */`.** Only
   `PaginatedResult` is (L1067, standalone form). `CacheableResult` carries `@internal`
   as a JSDoc tag inside its doc block at L1079. The consequence the row drew —
   neither base has a wire discriminator — was and is unaffected; it is now one clause
   in §4.10.2's opening sentence distinguishing the two forms.

4. **APPLIED, WITH THIS TEXT CORRECTED. §4.10's cross-reference to the sibling document
   named sections that do not transcribe these declarations.** §4.10 said the artifact
   is transcribed value-by-value in [`mcp-2026-07-28.md`](mcp-2026-07-28.md) *"§5, §8
   and §10"*. What each actually carries: **§5** the envelope types — `ResultType`,
   `Result`, `EmptyResult`, `CacheableResult`, `PaginatedResult`,
   `PaginatedRequestParams` and `Cursor` — plus the six-result `extends` table;
   **§10** the MRTR arm (`InputRequiredResult`, `InputRequests`, `InputResponses`);
   **§8**, which is *Media types and URI schemes*, only the five `ContentBlock`
   discriminator literals and `Role` in prose rather than as declarations.

   This item originally claimed that `Role`, `Tool`, `PromptMessage`,
   `ServerResult`, `ToolAnnotations`, `ResourceContents`, the ten `*ResultResponse`
   interfaces and the five `ContentBlock` members appear **nowhere** in that document.
   That was one clause too strong and is withdrawn: `Role` does appear, in §8 prose at
   line 613 (`Role = "user" | "assistant"`), and `Tool` appears at lines 245, 318 and
   457. Neither is a declaration, and `PromptMessage`, `ServerResult`,
   `ToolAnnotations`, `ResourceContents`, the ten `*ResultResponse` interfaces and the
   five `ContentBlock` members genuinely appear nowhere. The accurate claim is the one
   §4.10 now makes: outside §5, §8 and §10 there is no *declaration* of any of them.
   §4.10 was the only transcription of the MCP result payloads, which is why this file
   was needed — that part stands.

5. **WITHDRAWN, corrected in place above.** An earlier draft of this item claimed the
   artifact's second content union, `SamplingMessageContentBlock`, has *six* arms and is
   `ContentBlock` plus `ToolUseContent` and `ToolResultContent`. Both halves were wrong.
   It has five arms and it is a **different** five: it drops `ResourceLink` and
   `EmbeddedResource` and adds `ToolUseContent` and `ToolResultContent`, so the two
   sets share three members. The union and `SamplingMessage` are now quoted verbatim at
   §6 rather than characterised. §4.10 says nothing about either union and needs no
   change: `ContentBlock`'s five arms are correct as stated, and nothing in §4.10's ten
   methods reaches the sampling path, which is **@deprecated** (SEP-2577) at L2252,
   L2239, L2400, L2439, L2204 and L2157.

6. **APPLIED, RELOCATED — and it was a gap between the code and the contract, not only
   inside the contract.** `InputRequiredResult` types both `inputRequests?` and
   `requestState?` as optional, while its own doc comment at artifact L575 says
   *"At least one of `inputRequests` or `requestState` MUST be present."* The
   requirement is in the artifact in prose, so it was **established**, not a silence —
   and it therefore could not sit in §4.10.7, whose every row is introduced as
   `NOT ESTABLISHED`. Two things followed. §4.10.7 omitted it while presenting its list
   as the silences. And the library was already enforcing it: `src/mcp.zig:1596-1599`
   returns `error.MissingField` when both are absent, documented at `src/mcp.zig:1505-1506`
   as *"At least one of `input_requests` or `request_state` MUST be present; a result
   with neither is `error.MissingField`."* So the code held a MUST the contract did not
   state. The requirement now sits at the end of §4.10.3, stated as established.

7. **APPLIED. §4.10.2 asserted that a request and its result are never both paginated.**
   *"So a request and its result are not both paginated"* is false, and it contradicted
   the clause immediately before it. The four list requests extend `PaginatedRequest`
   (L1121, L1157, L1566, L1767) and their four list results extend `PaginatedResult`
   (L1133, L1169, L1578, L1779) — both sides paginated, for the same four methods. The
   other six methods are paginated on neither side: `DiscoverRequest`/`DiscoverResult`,
   `CompleteRequest`/`CompleteResult`, `GetPromptRequest`/`GetPromptResult`,
   `ReadResourceRequest`/`ReadResourceResult`,
   `SubscriptionsListenRequest`/`SubscriptionsListenResult` and
   `CallToolRequest`/`CallToolResult`. **No pair in the artifact has exactly one
   paginated side**, so the accurate rule is *paginated together or not at all*, and
   that is what §4.10.2 now says.

8. **APPLIED. §4.10.6's closed-set row claimed no interface on its list declares an
   index signature, and that list includes `Tool`.** `Tool.inputSchema` is
   `{ $schema?: string; type: "object"; [key: string]: unknown }` (L1997) and
   `Tool.outputSchema` is `{ $schema?: string; [key: string]: unknown }` (L2005). Both
   are open. The claim is true only of the *interfaces*; it was contradicted by §4.10.4,
   which calls both "open JSON Schema objects", and by §4.10.5, which excludes them
   from library-typed sequences. §4.10.6 now separates the two open members inside
   `Tool` from the declared member set of the interface, which is the distinction
   §4.10.4 was already making. The half of that fix which called the interface-level
   member set "closed" was itself wrong, and item 11 withdraws it.

9. **APPLIED — a contract gap, not a disagreement. §4.8 named a shape it did not
   carry, and §4.10 pointed at it.** §4.10.3's `DiscoverResult` row read
   `| capabilities | ServerCapabilities | **Yes** | The 4.8 shape |`, and §4.8
   carried no member table for anything. The note was a pointer to a shape that
   did not exist in the document it pointed into, so `ServerCapabilities` — whose
   full declaration has been in this file at §9 since it was written — was
   reachable only by reading the evidence document before the contract, which
   inverts the authority relationship `PROTOCOLS.md` states for itself.

   §4.8 now carries **4.8.1 `ClientCapabilities`** and **4.8.2
   `ServerCapabilities`** member tables with nested types, per-member
   optionality and deprecation status, plus **4.8.3** on open sets, and the
   §4.10.3 cell now points at 4.8.2. `ClientCapabilities` is quoted here in full
   at §9 for the first time — it was previously doc-comment only, with its body
   left to the sibling's §6 — so both tables have a declaration behind them in
   the same document the contract cites.

   Counts, read off the declarations rather than the tables:
   `ClientCapabilities` has **5** members and `ServerCapabilities` **7**, and
   **neither declares a single required member**. The two interfaces are the only
   place the artifact says a member set is open, and it says so in prose: *"this is
   not a closed set"*. Neither declares an index signature, so unlike `Result` they
   do not advertise openness by type either — which is a difference in how the
   source *expresses* openness, not a difference in whether undeclared keys are
   permitted. Item 11 measures that.

10. **APPLIED — a second contract gap of the same kind. The eight notification
    shapes were listed as method names and nowhere as payloads.** §4.4 named all
    eight and gave three of them a one-clause note; no section of
    `PROTOCOLS.md` stated a notification's members, their requiredness, or the
    `_meta` every one of them inherits. The only transcription was the sibling's
    §1b, one line each, which lists payload **members** and states **no
    requiredness** — so the five-required/three-optional `params` split, the
    optional `_meta` on all eight, and the two dependent types
    `SubscriptionFilter` and `LoggingLevel` were established nowhere.

    §10 of this file now carries every notification declaration with its line
    range, and `PROTOCOLS.md` §4.11 carries the extracted shapes: **4.11.1** the
    base and the inherited `_meta`, **4.11.2** the `progressToken` distinction,
    **4.11.3** the eight shapes with requiredness, **4.11.4** `SubscriptionFilter`,
    and **4.11.5** the silences.

    The `progressToken` item is the one that could have been mishandled, so it is
    recorded as what it is: `RequestMetaObject.progressToken?` (L67) is a request
    `_meta` key and an opt-in, while `ProgressNotificationParams.progressToken`
    (L1013) is a **required payload member of the notification** and not a
    `_meta` key at all. Opposite markers on two different members of two
    different types, both correct; nothing was moved and no fixture was
    relocated. See decision 8 in [`SPEC-DECISIONS.md`](../../SPEC-DECISIONS.md).

    One thing the extraction had to get right rather than assume: unlike
    `Result`, **none** of the six notification params interfaces declares an
    index signature — `NotificationParams` and the five named ones. That was
    recorded at the time as making a notification's top level closed and only
    `_meta` open. **Item 11 withdraws that reading**; what survives is that none
    of the six *invites* an undeclared key, and that no source forbids one either.

11. **CLAIM WITHDRAWN, and corrected in place above. "Nested objects are closed
    because the interface declares no index signature" was an inference, not a
    transcription.** *Closed* was asserted of three member sets — the capability
    nested objects `sampling`, `elicitation`, `prompts`, `resources`, `tools`; the
    members of the thirteen result element interfaces; and the six notification
    params interfaces — and in every case the evidence offered was the absence of a
    `[key: string]` index signature. A fourth place made the same move in the other
    direction, reading the two capability interfaces' *openness* out of their
    likewise-missing signature rather than out of the prose that states it.
    Such an absence is a fact about a TypeScript declaration. It is not a JSON Schema
    `additionalProperties: false`, it is not a wire rule, and nothing in this
    repository had checked whether the protocol writes one.

    **It does not.** The census in §9 measures it over both artifacts: the string
    `additionalProperties` occurs **zero** times in the 3,197-line `schema.ts`, and
    **twenty** times in the generated `schema.json`, **none of them `false`** — five
    bare `{}`, fifteen typed maps. `unevaluatedProperties` occurs zero times in
    either. Every nested object the claim covered — `elicitation`, `sampling`,
    `prompts`, `resources`, `tools`, the six notification params interfaces,
    `SubscriptionFilter`, `TextContent`, `Tool`, `Prompt`, `Resource`,
    `ResourceContents` — carries **no** `additionalProperties` keyword at all, and
    under draft 2020-12 an absent keyword permits undeclared properties. So the
    generated schema does not merely fail to close those sets; it **permits** a key
    the type does not name.

    What the artifact does fix, and what survives untouched, is the **declared**
    member set and each member's requiredness — 5 members and 7, all optional;
    4 `SubscriptionFilter` members, all optional; 1 optional `_meta` on each
    notification params interface. And the **value** sets stay closed exactly where
    a literal union says so, because `schema.json` emits `"type": {"const": "text"}`
    through `{"const": "resource"}` for the five `ContentBlock` arms and an `enum` of
    eight literals for `LoggingLevel`. Closed *value* sets and declared *member*
    sets are two different questions, and the error was answering the second with the
    evidence for neither.

    **Applied where.** `PROTOCOLS.md` §4.8.3 and §4.10.6 now say *declared* member
    set and mark closing `NOT ESTABLISHED`, with a new bullet in §4.10.7 and a new
    §4.11.5 bullet for what a receiver does with an undeclared key. Decision 9 in
    [`SPEC-DECISIONS.md`](../../SPEC-DECISIONS.md) records it, including the one code
    comment that repeats the inference.

    **No code consequence today, and that is checked rather than assumed.**
    `src/mcp.zig` has no typed capability decoder: `DiscoverResult.capabilities` is
    `[]const u8`, the whole object carried as the lexeme it arrived as
    (`src/mcp.zig` L3752–L3763), so there is no nested member set to reject. The
    correction therefore changes no behaviour; what it changes is a claim the
    contract was making about a protocol it does not fully specify.

### A note on how items 5 and 4 happened

Both were the same failure: a verbatim block was available and not consulted. Item 5
described a union I had read through an elision and never quoted. Item 4 asserted an
absence — "appears nowhere in that document" — from a grep over the wrong pattern
class, having searched for *declarations* and reported it as *mentions*. A digest
cannot catch either: it certifies that the bytes were fetched, not that they were read.
The check that does catch them is quoting the thing and asserting the count
mechanically, which is what §10 and §11 are for.

## Cross-source conflicts and gaps

- **Line count, resolved.** [`mcp-2026-07-28.md`](mcp-2026-07-28.md) lines 6 and 21–22
  recorded 3,203 lines for this URL where the artifact is 3,197. Both sites now read
  3,197 and the sibling's conflicts entry 11 carries the superseded figure. See
  *Artifact provenance*.
- **Overlap, not disagreement.** `ResultType`, `Result`, `EmptyResult`,
  `CacheableResult`, `PaginatedResult`, `PaginatedRequestParams`, `InputRequiredResult`,
  `InputRequests` and `InputResponses` are transcribed in this file **and** in
  [`mcp-2026-07-28.md`](mcp-2026-07-28.md) §5 and §10. Every declaration agrees. The
  duplication is deliberate: §4.10 needs the envelope, the bases and the MRTR arm in one
  place, and this file is the one §4.10's citation resolves to.
- **Capabilities and notifications, now overlapping in three places — and they
  agree.** `ClientCapabilities`, `ServerCapabilities` and all eight notification
  shapes are described in this file (§9, §10), in
  [`mcp-2026-07-28.md`](mcp-2026-07-28.md) §6 and §1b, and in
  [`../../PROTOCOLS.md`](../../PROTOCOLS.md) §4.8 and §4.11. Every value checked
  across all three agrees; the sibling's member lists match the declarations here,
  and it states no requiredness where §10 does. The three-way overlap is
  deliberate — the sibling is the at-a-glance shape, this file is the pinned
  declaration, and the contract is the authority for `src/`.
- **Immutable pin added, provenance not rewritten.** The `main` ref is a moving
  branch and the historical digest recorded for §4.10's transcription is
  `742750af…2cd`. A commit-pinned URL for the same file is now cited alongside
  it, and a 2026-10-01 fetch of that commit returned bytes **identical** to the
  `main` fetch — same length, same line count, same digest. The historical record
  is therefore unchanged and the pin is additive: it gives the `artifact L…`
  ranges a durable address without asserting anything new about when §4.10 was
  transcribed. See *Artifact provenance* → *Immutable pin*. Both digests are over
  the raw HTTP response body, not over reader output.
- **A second artifact, admitted for one question and only that one.** The generated
  `schema/2026-07-28/schema.json` is cited here for the `additionalProperties` census
  at §9 and for nothing else — no declaration in this file is quoted from it, and it
  is not a second source of truth. It is admissible on that one point precisely
  because the TypeScript source is silent there: an index signature is a compile-time
  construct, and the wire-level construct that closes a member set appears nowhere in
  the source. Finding 11 is what the census produced, and it withdrew a claim this
  file had made in three places.
- **Not re-derived here, notifications included.** The `subscriptions/listen`
  opt-in MUSTs and the elicitation rules §4.8.3 and §4.11.4 restate are prose in
  other specification pages. §10 quotes what `schema.ts` itself states — including
  the JSDoc MUSTs on `CancelledNotificationParams.requestId`, on
  `NotificationMetaObject.subscriptionId` and on
  `SubscriptionsAcknowledgedNotification` — and leaves the rest to the sibling.
- **Not re-derived here.** The requirement language §4.10 attributes to
  `basic/index.md`, `server/tools.md`, `server/resources.md`, `server/prompts.md` and
  `server/utilities/caching.md` is prose and lives in those documents, not in
  `schema.ts`. This file quotes only what `schema.ts` itself states; where the
  artifact's own JSDoc makes the same claim, the quotation stands in for the prose.
  In particular the "six cacheable operations" set is fixed by the six `extends
  CacheableResult` clauses above, not by re-reading the caching page.