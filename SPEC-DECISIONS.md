# Specification decisions

[PROTOCOLS.md](PROTOCOLS.md) defines the implemented wire contract.
The [normative transcriptions](research/normative/README.md) identify upstream artifacts.
For A2A, the protobuf artifact takes precedence when the contract's summary disagrees.
An unknown value remains an explicit decode or encode error.

## 1. A2A `DeleteTaskPushNotificationConfig` response

The response is `google.protobuf.Empty`.
The protobuf declaration in `research/normative/a2a-1.0.0.md` section 3 takes
precedence over the `TaskPushNotificationConfig` entry in PROTOCOLS section 5.3.

## 2. A2A extension and binding namespaces

The library exposes no `https://a2a-protocol.org/extensions/` or `/bindings/` prefix.
The source defines no A2A-owned namespace or mandatory prefix.
Extension URIs remain free-form strings. A required extension without activation
still produces `-32008`.
See `research/normative/a2a-1.0.0.md` sections 9.3 and 9.4.

## 3. JSON-RPC message classification

`jsonrpc.Kind` has `request`, `notification`, and `response` variants.
Presence of `id` and `method` determines the kind.
A response carries either `result` or `rpc_error`. Error responses need no fourth kind.

## 4. MCP Apps and AG-UI scope

Neither protocol is implemented. PROTOCOLS section 9 defines the exclusions.
MCP Apps requires a selected host. AG-UI remains outside the implemented subset.

## 5. MCP content discriminators and result members

`ContentBlock` is a closed union of text, image, audio, resource link, and embedded resource.
An unknown discriminator returns `UnknownTag`.
The generated schema uses a literal `const` for each arm.

The surrounding result object remains open.
Carried opaque members retain their borrowed JSON bytes and presence.
This does not preserve whitespace, ordering, or escapes in the outer document.
See `research/normative/mcp-2026-07-28-schema.md` sections 8 and 9.

## 6. Previous MCP method registry

At revision `2025-11-25`, `lookupMethod` resolves `roots/list`,
`sampling/createMessage`, and `elicitation/create` as deprecated methods.
They have `present_at_current = false` and are unknown at `2026-07-28`.
Their registry entries use `client_to_server`.
MRTR input-request entries use the separate `server_to_client_mrtr_only` direction.

PROTOCOLS section 4.4 defines method availability.
Section 9 excludes the sampling and roots capability surfaces, not these older method names.

## 7. The bridge's RFD-only ACP capability

`bridge.capability_path` and `bridge.server_declaration` carry the RFD's `acp`
capability and `{"type":"acp"}` declaration.
Neither appears in the pinned released ACP schema artifacts.
The v1 capability is a boolean. The v2 capability is a presence object,
where `{}` means support.

The pinned schema tags are `schema-v1.23.0` and `schema-v2.0.0-alpha.5` at
commit `6d08f412a7a1370d3cc9a124e3be3d6acf92641e`.
The v1 MCP capabilities declare `http`, `sse`, and `_meta`.
The v2 capabilities declare `stdio`, `http`, and `_meta`.
The v2 server union has `http`, `stdio`, and `other` arms.
The RFD declaration matches that `other` arm.
See `research/normative/acp-v1-v2.md` section 10e and decision 11.

## 8. Progress token requiredness

`RequestMetaObject.progressToken` is optional.
It requests out-of-band progress notifications, which the receiver need not provide.
`ProgressNotificationParams.progressToken` is required in a notification payload.
These members have different locations and requiredness.
See `research/normative/mcp-2026-07-28-schema.md` section 10.

## 9. MCP object member sets

A TypeScript declaration without an index signature does not close a JSON object.
The pinned generated JSON Schema contains no `additionalProperties: false`
and no `unevaluatedProperties` keyword.
Its draft 2020-12 semantics permit undeclared properties when the keyword is absent.
The contract therefore records declared members and requiredness without asserting closure.

Literal discriminators and value enums remain closed.
Typed decoders can skip unmodeled members. Represented opaque data and open
carriers must preserve them under PROTOCOLS section 2.
`DiscoverResult.capabilities` retains the entire JSON object as a borrowed lexeme.

Both schema artifacts use commit `3098fe94caa1b9e0afaaa6d30e040b61d5802471`.
The transcription records source hashes and the keyword inventory in section 9.

## 10. Native API contracts

Round trips preserve modeled values and presence, then produce stable normalized encoding.
Consumers that need the original bytes must retain the input.
Decoded values borrow input, scratch, or arena storage.

`lastEncodedLen` and `nextId` observe shared connection state.
The getters require mutable Conn for synchronization.
A length does not identify a caller's buffer unless other encoders are excluded.
An id observation does not reserve an id.

Conn reuses JSON-RPC validation for constructed messages.
Opaque JSON spends the depth of its enclosing containers.
MCP input-required construction validates its source before writing.
ACP v2 initialization checks required info before composing the body.
Writable scratch must not overlap decode input.

`Canceled`, `EncodeBufferTooSmall`, and `ResponseTooLarge` distinguish cancellation,
local output shortage, and inbound response shortage.
Failed operations can dirty caller storage.
Cancellation and overflow do not prove that the peer performed no action.
Reserved ids are never reused.

## 11. ACP SDK snapshot versus released schema artifacts

The pinned `agent-client-protocol` SDK `1.0.0rc2` includes unstable `acp` and
`mcp/message` models that the released schema artifacts do not declare.
The SDK's version files name the same tags as decision 7, but its vendored
schema differs from those tagged artifacts.
The SDK labels the capability unstable.

Its `MessageMcpRequest` carries `connectionId`.
The implemented RFD envelope carries `serverId`.
The library retains the RFD shapes and labels the capability RFD-only.
An SDK advertisement does not establish support in a peer built from a released schema.
