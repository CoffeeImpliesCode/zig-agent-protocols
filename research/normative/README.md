# Normative transcriptions

These documents preserve wire values from upstream schemas, protobuf declarations,
and method registries. Each document identifies its artifact and revision.
[PROTOCOLS.md](../../PROTOCOLS.md) selects the implemented subset.
[SPEC-DECISIONS.md](../../SPEC-DECISIONS.md) records conflicts and resolution rules.

| File | Source and content |
| --- | --- |
| [MCP core](mcp-2026-07-28.md) | Revision `2026-07-28` methods, metadata, headers, errors, MRTR, and capability placement. |
| [MCP schema](mcp-2026-07-28-schema.md) | Result, content, capability, and notification declarations from `schema.ts` and generated JSON Schema. |
| [A2A](a2a-1.0.0.md) | Tag `v1.0.0` protobuf field numbers, enums, RPCs, bindings, errors, cards, and signatures. |
| [ACP](acp-v1-v2.md) | Stable v1 and draft v2 method registries, capabilities, updates, permissions, framing, and the MCP-over-ACP RFD. |
| [UI protocols](ui-protocols.md) | AG-UI, A2UI, and MCP Apps source values for surfaces outside the implemented subset. |
| [Commerce](commerce.md) | UCP, Agentic Commerce Protocol, AP2, and x402 source values for excluded surfaces. |
| [Instructions and observability](instructions-observability.md) | Agent Skills, MCP Skills, OpenTelemetry, Web Bot Auth, and A2A signed-card source values. |

`NOT ESTABLISHED IN SOURCE` marks a value the cited artifact does not define.
Conflicting primary sources retain both values with an explanation.
