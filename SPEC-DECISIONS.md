# Specification decisions

Points where `PROTOCOLS.md` and the deeper value source
`research/normative/*.md` disagree, and how this library resolved them. Each
decision is grounded in a primary artifact, not a preference.

`PROTOCOLS.md` is the stated authority for `src/`. But it also states, in §5.1,
that A2A's `specification/a2a.proto` "is the single normative artifact". Where
the two conflict, the more specific authority for that protocol wins, and the
reasoning is recorded here so it is discoverable rather than buried in a source
comment.

The library's governing rule, from `PROTOCOLS.md` §1: where a value is marked
`NOT ESTABLISHED`, no primary source defined it, and this library does not
invent one; the case is an explicit decode or encode failure instead.

## 1. A2A `DeleteTaskPushNotificationConfig` response type

- **Decision:** the response is `google.protobuf.Empty`.
- **Conflict:** `PROTOCOLS.md` §5.3 line 411 lists `TaskPushNotificationConfig`.
  The proto, at `research/normative/a2a-1.0.0.md` line 644, lists
  `google.protobuf.Empty`.
- **Resolution:** the proto wins under `PROTOCOLS.md`'s own authority clause
  (§5.1). A real 1.0.0 agent returns an empty body; declaring a config payload
  would make a peer wait for a body that never arrives.

## 2. A2A §5.8 extension and binding namespace prefixes

- **Decision:** not modelled. The prefixes
  `https://a2a-protocol.org/extensions/` and `.../bindings/` are **not** exposed
  as constants.
- **Conflict:** `PROTOCOLS.md` §5.8 presents them as a specification table. The
  normative extraction states, verbatim (§9.3 and §9.4), that the specification
  "defines no A2A-owned extension URI namespace and no mandatory prefix" and
  that the only URIs present are illustrative `example.com` values; it lists the
  namespace as `NOT ESTABLISHED IN SOURCE`.
- **Resolution:** the library does not invent values that no primary source
  establishes. `AgentCard.capabilities.extensions[].uri` is a free-form string;
  `activatesExtension` matches on whatever URI a caller supplies. The
  activation semantics that PROTOCOLS.md *does* establish — a required
  extension with no activation is `-32008` — are implemented.

## 3. `jsonrpc.Kind` message classification

- **Decision:** `Kind` has three variants — `request`, `notification`,
  `response` — matching the specification's rule.
- **Conflict:** an earlier revision had four, adding `error_response`.
  `PROTOCOLS.md` §3 line 107 classifies on `id` and `method` presence only: "a
  message with an `id` and no `method` is a response; a message with a `method`
  and no `id` is a notification; a message with both is a request." A message
  carrying `error` rather than `result` is still a response by that rule.
- **Resolution:** the error-versus-result distinction is carried losslessly on
  the `Message` itself (`result` and `rpc_error` are separate optional members
  and exactly one is set on a response), so collapsing the fourth variant loses
  no information while matching the authority.

## 4. MCP Apps and AG-UI scope

- **Decision:** neither is implemented. The `PROTOCOLS.md` §9 exclusion list is
  the scope this library holds itself to.
- **Conflict:** `research/sota-2026-09-29.md` §7, "Scope for this library",
  places both protocols in scope, because "both are Stable or 1.0 and both are
  consumed by the hosts this library's users already run". `PROTOCOLS.md` §9,
  "Not implemented", excludes both: "Specified and stable, but the client
  support matrix is a community-maintained list. Deferred until a host is chosen"
  for MCP Apps, and "Declined for the same reason as A2UI: a vendor-governed 1.0
  with no foundation home. Revisit if it is donated" for AG-UI.
- **Resolution:** `PROTOCOLS.md` is the stated authority for `src/`, so §9
  governs and the **Conditional** list stays unimplemented. The exclusions stand
  on the reasons §9 records: the MCP Apps `ui/*` surface waits for a host,
  because its client support matrix is community-maintained, and AG-UI waits
  for a foundation home it does not have. Each is lifted by the condition §9
  names, a chosen host or a donation. The research document stays the deeper
  value source and the protocol document the authority, as for A2A above.

## 5. MCP `ContentBlock` is a closed union; the result object around it is open

- **Decision:** an unrecognised `type` on a `ContentBlock` is
  `error.UnknownTag`, exactly as an unrecognised tag is on every other closed
  set in this library. A **member the result object does not model** is carried
  as the borrowed lexeme it arrived as, and written back verbatim.
- **Conflict:** no primary source states a decoding policy either way. The
  schema artifact declares `ContentBlock = TextContent | ImageContent |
  AudioContent | ResourceLink | EmbeddedResource` with **no `| string` arm and no
  "not a closed set" sentence** — and that sentence appears verbatim on
  `ClientCapabilities` and `ServerCapabilities` and nowhere else, so the
  artifact's own idiom marks an open discriminator
  explicitly. Meanwhile `Result` declares `[key: string]: unknown` and
  `basic/index.md` says a result "MAY follow any JSON object structure", so
  the object is open in its keys whatever the discriminator is.
  The index signature is not part of that argument, and decision 9 removes it: a
  TypeScript index signature is not a wire rule. What carries the closedness is
  the union's own idiom, confirmed on the wire by the generated `schema.json`, which
  emits `"type": {"const": "text"}` through `{"const": "resource"}` — one `const`
  per arm, so a sixth string is invalid by the schema itself.
- **Resolution:** the two facts are not in tension and the policy follows
  each. The discriminator is closed, so an unknown `type` has no arm to decode
  into and refusing it is the only answer that reports a fault rather than
  inventing one — the same rule `a2a.TaskState.fromTag`, `a2a.Role.fromTag` and
  `acp.PermissionOptionKind` already follow, and the reason
  `root.DecodeError` carries `UnknownTag` at all. The object is open, so a key
  no result type models cannot be dropped: `PROTOCOLS.md` §2 requires
  `encode(decode(b)) == b`, and a typed shape cannot hold a key it does not
  name. That is the rule `bridge.Envelope.meta` and `bridge.OutcomePayload`
  follow, and a typed shape is exactly what re-opened a loss that had been open
  for the life of this repository.
- **Note:** an earlier draft of `PROTOCOLS.md` §4.10 described `ContentBlock`
  as an open union. The artifact does not support that, and the transcription
  follows the artifact.
- **Note, added by decision 9:** this decision's outcome is unchanged and its
  evidence is now stated on the union rather than on member sets. The same
  obsolete "no index signature" clause in `src/mcp.zig` was removed; its comment
  now cites the literal discriminator and generated-schema `const` evidence.

## 6. `roots/list` and `sampling/createMessage` resolve at `2025-11-25`

- **Decision:** `mcp.lookupMethod(.previous, …)` resolves `roots/list`,
  `sampling/createMessage` and `elicitation/create`, each with
  `present_at_current = false` and `deprecated = true`. Before this wave all
  three were refused at every revision, and `AGENTS.md` restated that as
  settled — which is how a defect becomes indistinguishable from a decision.
- **Conflict:** two passages of `PROTOCOLS.md` point opposite ways.
  §4.4 lists all three as "Removed in `2026-07-28`, and therefore decoded as
  `UnknownMethod` **at that revision**", which reads as: they resolve at
  `2025-11-25`. §9 "Not implemented" lists "MCP sampling and roots" as
  excluded outright, which reads as: not at any revision. For
  `elicitation/create` there is no conflict at all — §9 does not name it, §4.9's
  deprecation registry does not list it, and the internal evidence is
  decisive: `mcp.removed_methods` carries `notifications/elicitation/complete`
  as a notification, so the library resolves the sibling beside a request it
  refuses.
- **Resolution:** §4.4 wins, for all three, because it is the method-registry
  authority and it speaks to this exact question, whereas §9 is a scope list
  about *surfaces*. The distinction that makes both true: §9's exclusion is
  about the sampling and roots **capabilities** — `Roots`, the
  `notifications/roots/list_changed` handler, the client sampling capability —
  none of which this library models. The **MRTR input requests** are modelled
  and always were: `mcp.input_requests` has carried all three with
  `.deprecated = true` since before this wave, and `lookupInputRequest` finds
  them independently of `lookupMethod`. So §9 is not contradicted by resolving
  the names; it is obeyed about the surfaces it names.
- **Consequence for the table.** The new rows carry `.client_to_server`, and
  they are a table of their own rather than a reuse of `input_requests`. That
  row's direction is `server_to_client_mrtr_only` and the session gate refuses
  anything that is not `client_to_server`, so handing it the carried row would
  resolve the name and then refuse it in **both** directions — a
  `2025-11-25` server would decline to answer `roots/list` as well as a client
  being unable to send it.
- **Tests.** Two tests pinned the old behaviour as an expectation and were
  deleted rather than inverted, which is this repository's rule for a test that
  encodes the behaviour being removed.

## 7. The bridge `acp` capability and `{"type":"acp"}` are RFD-only, and stay labelled

- **Decision:** the library carries the `acp` capability path and the
  `{"type":"acp"}` server declaration as constants — `bridge.capability_path`
  and `bridge.server_declaration` — and `PROTOCOLS.md` §6.5.1 and §7.1–7.2 state
  in the contract that **neither appears in any released ACP schema**. The
  shapes are encoded per version: v1 a `boolean`, v2 a presence object.
- **Conflict:** `PROTOCOLS.md` §6 previously described ACP capabilities from the
  released schemas only, so the binding's own capability had no entry — while
  `src/bridge.zig` had exported both constants with a doc comment saying the key
  "is in no published schema in either version". The code knew a fact the
  contract did not state, which is the §6 shape of the decision 5 defect.
  Meanwhile the mcp-over-acp RFD specifies both values and the released schemas
  declare neither, so a contract that listed `acp` beside `mcpCapabilities.http`
  as an ordinary capability would have **invented** a published one.
- **Evidence.** Verified directly against the published artifacts, not from a
  transcription: the literal `"acp"` occurs **zero** times in
  `schema/v1/schema.json` and **zero** times in `schema/v2/schema.json`; v1
  `McpCapabilities` has exactly `http`, `sse`, `_meta`; v2 `McpCapabilities` has
  exactly `stdio`, `http`, `_meta`; the v2 `McpServer` union has exactly the
  branches `http`, `stdio` and an `other` catch-all, with no `acp` branch, so the
  RFD declaration currently validates by falling through to `other`; and neither
  `meta.json` lists any `mcp/*` method. Full transcription at
  [`research/normative/acp-v1-v2.md`](research/normative/acp-v1-v2.md) §10e.
- **Resolution:** both values are stated, as §5 does for `ContentBlock` — the
  RFD's and the released schemas' positions are recorded side by side and
  neither is presented as the other's correction. The constants stay because the
  binding is RFD-specified and `bridge.zig` implements the RFD; what changes is
  that the contract now says out loud what the source comment already said, so a
  reader of `PROTOCOLS.md` alone learns the capability is not in a released
  schema. §6.5.1 also records the cross-revision shape change — v1 `boolean`
  where omission means `false`, v2 presence object where `{}` means supported —
  because reading `{}` as `false` at v2 would invert the advertisement.

## 8. `progressToken` is optional in a request `_meta` and required in a notification payload

- **Decision:** `PROTOCOLS.md` §4.11.2 states both, in one table, and neither is
  altered to match the other. §4.3 continues to list `progressToken` as a bare
  `_meta` key — which is true of the *request* declaration only.
- **Conflict:** none in the artifact, and none in the library before this wave.
  Read quickly, the two declarations look like a contradiction: artifact L67
  writes `progressToken?: ProgressToken` and artifact L1013 writes
  `progressToken: ProgressToken`. An earlier note treated that as a defect
  needing a fixture relocated or one declaration corrected.
- **Resolution:** they are different members of different types and both
  requirednesses are correct. `RequestMetaObject.progressToken` is a request
  `_meta` key and an **opt-in** — *"If specified, the caller is requesting
  out-of-band progress notifications… The receiver is not obligated to provide
  these notifications."* `ProgressNotificationParams.progressToken` is a
  **payload member of the notification**, not a `_meta` key at all, and it is
  required precisely because a well-formed `notifications/progress` can only
  exist for a request that carried the token. Nothing is moved and no fixture is
  relocated; the two rows are tabulated together so the apparent contradiction
  cannot be re-derived. Declarations quoted at
  [`research/normative/mcp-2026-07-28-schema.md`](research/normative/mcp-2026-07-28-schema.md)
  §10.

## 9. No MCP object member set is closed; "declared" replaces "closed"

- **Decision:** the contract states each object's **declared** member set and each
  member's requiredness, and marks *closing* `NOT ESTABLISHED`. The word *closed*
  is now used only for a **value** set a literal union fixes, which is what the
  artifact actually says. `PROTOCOLS.md` §4.8.3, §4.10.6, §4.10.7 and §4.11.5 were
  revised; no `src/` behaviour changes, and the Consequence bullet below says why that
  is a measurement and not an assumption.
- **Conflict:** `PROTOCOLS.md` §4.8.3, §4.10.6 and the extract's §10 each stated
  that a member set is **Closed**, and gave the same evidence each time — the
  interface declares no `[key: string]` index signature. The same inference appeared
  in §4.10.6's list of thirteen result element interfaces and in the extract's
  finding 8. Nothing in the source says any of them is closed; the absence of an
  index signature was read as a normative JSON rule it does not express.
- **Evidence, measured over both artifacts at commit
  `3098fe94caa1b9e0afaaa6d30e040b61d5802471`, fetched 2026-10-01.** In
  `schema/2026-07-28/schema.ts` — 3,197 lines, 98,426 bytes, sha256
  `742750af0bb8c716e7030c4977c992b55d1adc4407e9e66997db5846baedc2cd` — the strings
  `additionalProperties` and `unevaluatedProperties` occur **zero** times each. In
  the generated `schema/2026-07-28/schema.json` — 3,963 lines, 181,474 bytes, sha256
  `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`, declared
  draft 2020-12 — `additionalProperties` occurs **20** times and **none** is `false`
  (five bare `{}`, fifteen typed maps), and `unevaluatedProperties` occurs zero
  times. `elicitation`, `sampling`, `prompts`, `resources`, `tools`, the six
  notification params interfaces, `SubscriptionFilter`, `TextContent`, `Tool`,
  `Prompt`, `Resource` and `ResourceContents` carry **no** `additionalProperties`
  at all, and under draft 2020-12 an absent keyword permits undeclared properties.
  A TypeScript index signature constrains an object literal at compile time; it is
  not `additionalProperties: false`, and the protocol writes that keyword nowhere.
  Census and method: the extract's §9; record: its finding 11.
- **Resolution:** a **value** set and a **member** set are two questions, and the
  artifact answers them by different means. Values: a literal union with no `| string`
  arm, corroborated on the wire by `schema.json` — `"type": {"const": "text"}`
  through `{"const": "resource"}` for the five `ContentBlock` arms, an `enum` of
  eight literals for `LoggingLevel`, `{"type": "boolean"}` for `listChanged` and
  `subscribe`. Those stay closed, and decision 5's `UnknownTag` is unaffected
  because it rested on the union, not on a member set. Members: the declaration
  fixes the names and the requiredness and nothing more. There is no clause to
  reject an undeclared key against and none to forbid one, so the contract states
  the silence instead of resolving it — a decoder may model exactly the declared
  members, and if it accepts more than that, §2 requires it to write them back.
- **Consequence.** `src/mcp.zig` has no typed capability decoder. The field
  `DiscoverResult.capabilities` is `[]const u8` — the whole object carried as the
  lexeme it arrived as, L3752–L3763 — so there is no nested member set to accept or
  reject and the correction moves no behaviour. The `ContentBlock` comment now
  cites the union's literal discriminator values and generated-schema `const`
  constraints, not the unrelated absence of an index signature.
