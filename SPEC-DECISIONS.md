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
  AudioContent | ResourceLink | EmbeddedResource` with **no `| string` arm, no
  index signature, and no "not a closed set" sentence** — and that sentence
  appears verbatim on `ClientCapabilities` and `ServerCapabilities` and
  nowhere else, so the artifact's own idiom marks an open discriminator
  explicitly. Meanwhile `Result` declares `[key: string]: unknown` and
  `basic/index.md` says a result "MAY follow any JSON object structure", so
  the object is open in its keys whatever the discriminator is.
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
