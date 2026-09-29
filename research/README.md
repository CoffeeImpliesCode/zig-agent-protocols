# Research

Evidence base for [`../PROTOCOLS.md`](../PROTOCOLS.md). Everything here is dated
evidence about the current state of agent wire protocols. Nothing here is normative.

- Research date: **2026-09-29**
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the authority for every type
  name, tag value and byte layout in `src/`
- Evidence: this directory

## How the two layers relate

`PROTOCOLS.md` says what a conforming implementation looks like. These documents
say why, and record what the wire actually contains at a point in time. When the
two disagree, `PROTOCOLS.md` wins and the research document is what gets corrected.

A protocol's wire values in `PROTOCOLS.md` are pinned to a specific dated spec
revision. The research document for that protocol records the revision, its
release date, and what changed in it. When the upstream revision moves, the
research document is the place that records the delta; `PROTOCOLS.md` is the
place the pin is updated.

## Documents

### Protocols with a wire contract

| Document | Covers |
| --- | --- |
| [`mcp.md`](mcp.md) | Model Context Protocol, revision `2026-07-28` |
| [`a2a.md`](a2a.md) | Agent2Agent, `1.0.0` and patch `v1.0.1` |
| [`acp-agent-client.md`](acp-agent-client.md) | Agent Client Protocol, v1 stable and v2 draft |
| [`acp-others.md`](acp-others.md) | The other three protocols that share the ACP acronym |
| [`ui-protocols.md`](ui-protocols.md) | AG-UI, A2UI, MCP Apps, WebMCP, NLWeb |
| [`instructions.md`](instructions.md) | Agent Skills, Skills over MCP, AGENTS.md, llms.txt |
| [`commerce.md`](commerce.md) | UCP, AP2, x402, AGNTCY, ANP |

### Cross-cutting layers

| Document | Covers |
| --- | --- |
| [`orchestration-hitl.md`](orchestration-hitl.md) | Orchestration (no protocol exists) and human-in-the-loop across MCP, ACP, A2A, AG-UI |
| [`identity-and-discovery.md`](identity-and-discovery.md) | Agent identity, discovery, IETF and W3C activity |
| [`observability.md`](observability.md) | OpenTelemetry GenAI and MCP conventions, OpenInference, evaluation |
| [`runtime-gateway-sandbox.md`](runtime-gateway-sandbox.md) | Gateways, sandboxes, agent runtimes, A2A hosting |

### Ecosystem and risk

| Document | Covers |
| --- | --- |
| [`platform-support.md`](platform-support.md) | Per-vendor protocol support verified from documentation |
| [`security.md`](security.md) | Attack surface, CVEs, and what the specs do and do not mitigate |
| [`governance.md`](governance.md) | AAIF, the other foundations, the proposal census, standards bodies |
| [`sota-2026-09-29.md`](sota-2026-09-29.md) | The synthesis: layer map, verdicts, recommendations |
| [`sources.md`](sources.md) | Consolidated URL index across every document above |

### Normative extractions

| Document | Covers |
| --- | --- |
| [`normative/`](normative/README.md) | Verbatim wire values transcribed from each protocol's own machine-readable artifact |

Seven files, indexed in [`normative/README.md`](normative/README.md). These are the
value-level source of record: `PROTOCOLS.md` selects from them, and the documents in
this directory summarise rather than enumerate. They exist because an earlier pass
reduced exact lists to counts and lost them.

## Method

Facts come from primary sources: official specification sites, the projects' own
repositories and generated schemas, foundation announcements, and vendor
documentation. Secondary commentary was used to locate sources, never as the sole
basis for a fact.

Two tags appear throughout and are load-bearing:

- `[UNVERIFIED]` — the claim is single-sourced, or the source could not be reached
  or confirmed. Treat as provisional.
- `[INFERENCE]` — a conclusion drawn from the sources rather than stated in one.

Where a value could not be established from any primary source, the documents say
`NOT ESTABLISHED IN SOURCE`. That is a deliberate result, not a gap to be filled by
guessing: a wire value that is wrong here becomes a wrong constant in `src/`.

## Staleness

This is a snapshot. The shortest half-life in the set is MCP, whose current
revision was two months old on the research date and whose client support was
still trailing it. Re-verify anything load-bearing against the upstream spec before
depending on it.
