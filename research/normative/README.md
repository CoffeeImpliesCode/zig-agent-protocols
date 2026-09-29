# Normative extractions

Verbatim wire values transcribed from each protocol's own machine-readable
artifact: JSON Schema, `.proto` files, and generated method registries.

- Research date: **2026-09-29**
- Contract: [`../../PROTOCOLS.md`](../../PROTOCOLS.md) — the authority for every type
  name, tag value and byte layout in `src/`
- Evidence: this directory

## What belongs here versus the narrative documents

The documents one level up answer *what the protocol is, who runs it, and whether to
depend on it*. They summarise. This directory answers *what bytes go on the wire*,
and it does not summarise: a list of 31 event types is written as 31 rows, because an
earlier pass of this same research reduced such lists to counts and lost them.

`PROTOCOLS.md` is derived from this directory. Where the two disagree, `PROTOCOLS.md`
wins and the fix belongs in the source code, but the evidence for the correct value is
here.

## Documents

| File | Artifact transcribed | What it preserves |
| --- | --- | --- |
| [`mcp-2026-07-28.md`](mcp-2026-07-28.md) | `schema/2026-07-28/schema.ts` and the generated `schema.json`, cross-checked | Method inventory, `_meta` keys, error codes, headers, the result envelope, capability placement per revision, extension identifiers, the deprecated registry, MRTR |
| [`a2a-1.0.0.md`](a2a-1.0.0.md) | `specification/a2a.proto` at tag `v1.0.0` | Enum numbers, protobuf field numbers for all messages, the gRPC service, the JSON-RPC and HTTP bindings including every tenant variant, the error mapping table, the AgentCard and signature shapes |
| [`acp-v1-v2.md`](acp-v1-v2.md) | `schema/v1/meta.json`, `schema/v1/schema.json`, `schema/v2/meta.json`, `schema/v2/schema.json` | The method registries verbatim, the complete `sessionUpdate` variant sets for both versions, both capability trees, the permission and elicitation shapes, the transport framing rules, the `mcp/message` envelope |
| [`ui-protocols.md`](ui-protocols.md) | AG-UI 1.0 JSON Schema, the A2UI v1.0 candidate schemas, the MCP Apps `2026-01-26` specification | All 31 AG-UI event type strings, both transport framings, the A2UI envelope and catalog indirection, the MCP Apps CSP and `ui/*` surface |
| [`commerce.md`](commerce.md) | UCP `2026-08-25` schemas, the Agentic Commerce Protocol `2026-04-17` OpenAPI and JSON Schema, the AP2 v0.2 specification, the x402 v1 specification | Capability identifiers, endpoint paths, header names, error enums, mandate `vct` strings, payment header names and facilitator endpoints |
| [`instructions-observability.md`](instructions-observability.md) | The Agent Skills specification and `skills-ref` validator, the MCP Skills extension, the OpenTelemetry GenAI and MCP semantic conventions, `draft-ietf-webbotauth-httpsig-protocol`, the A2A signed-card section | Frontmatter keys and their exact constraints, the skill URI and digest rules, every `gen_ai.*` and `mcp.*` attribute name with stability, the Web Bot Auth header set |

## Reading order for an implementer

1. [`../../PROTOCOLS.md`](../../PROTOCOLS.md) for the contract you are coding against.
2. The file in this directory for the protocol you are implementing, as the
   authoritative value source.
3. The narrative document one level up for why the value is what it is, and for the
   defects and sharp edges that shape the design.

## Method

Values are copied from the primary artifact, not from prose describing it, and not from
a search result. Where a row could not be established from any primary source it reads
`NOT ESTABLISHED IN SOURCE` rather than carrying a plausible guess. A guessed constant
in this library is a wire-compatibility bug that a conformance suite will not catch.

Where two primary sources disagree, both values appear with a note. That is a finding,
not a defect in the transcription.

The schemas move. MCP's current revision was two months old on the research date and its
client support was still trailing it. Re-verify against upstream before depending on
any value here.
