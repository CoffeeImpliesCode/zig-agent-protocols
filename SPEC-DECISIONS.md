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
