# Agent Instructions and Skills

This document records the state of the four artifacts that carry instructions to
an agent: the Agent Skills `SKILL.md` format at agentskills.io, the Skills over
MCP extension that transports that format, `AGENTS.md` as an always-on project
convention, and `llms.txt` as a site-level documentation map. It covers what each
one specifies, when each changed, who ships it, and where the layer breaks. It
does not cover vendor plugin marketplaces, the Agent Definition Language, or the
A2A agent card beyond the fact that both reference skills; it does not prescribe
anything. Wire values for this layer are in [`../PROTOCOLS.md`](../PROTOCOLS.md).

- Research date: 2026-09-29
- Contract: [`../PROTOCOLS.md`](../PROTOCOLS.md) — the normative wire values live there
- Evidence: this file

## State

Four artifacts, four different governance models, one shared subject.

| Artifact | Kind | Steward | Version | Status on 2026-09-29 |
| --- | --- | --- | --- | --- |
| Agent Skills / `SKILL.md` | format specification | Anthropic (`agentskills/agentskills`) | **none published** | Stable in practice, unversioned in form |
| Skills over MCP (`io.modelcontextprotocol/skills`) | transport extension, SEP-2640 | MCP Skills Over MCP WG, Extensions Track | Extension id is the version; written against base revision `2026-07-28` | **Final, merged 2026-09-13** |
| `AGENTS.md` | convention | Agentic AI Foundation (Linux Foundation) | **none** | Largest install base in the layer, no specification |
| `llms.txt` / `llms-full.txt` | site documentation map | One author | v2, dated 2026-08-10, no version body | Mainstream publishing, undisclosed consumption |

### Agent Skills / SKILL.md

The specification lives at [agentskills.io/specification](https://agentskills.io/specification).
**No version number is published anywhere on the site or in the repo.** There is
no versioned release, no changelog, no semantic-versioning scheme and no
stability statement. The former spec path
`anthropics/skills/spec/agent-skills-spec.md` is now a stub whose entire content
is "The spec is now located at https://agentskills.io/specification"
([stub](https://github.com/anthropics/skills/blob/main/spec/agent-skills-spec.md)).
Versioning is implicit and git-based only.

Governance sits in
[`agentskills/agentskills`](https://github.com/agentskills/agentskills) (25.8k
stars). Per
[CONTRIBUTING.md](https://github.com/agentskills/agentskills/blob/main/CONTRIBUTING.md),
proposals go to Discussions, bugs to Issues, the bar for spec additions is
explicitly high ("it is much easier to add things to a specification than to
remove them"), the `skills-ref` reference library is not accepting code
contributions, skill submissions and major architectural changes are refused for
now, logo and client-listing requests are reviewed by the Anthropic team and
require a *shipping* implementation rather than a beta, and AI-assist disclosure
in pull requests is mandatory. There is no technical steering committee and no
charter. Licensing is Apache-2.0 for code and spec, CC-BY-4.0 for documentation.

This is the highest-maturity artifact in the layer: a real specification, a
reference validator (`skills-ref validate <dir>`), and a multi-vendor client
list. Its two structural weaknesses are that it is unversioned, and that its
normative naming and progressive-disclosure rules are enforced by convention
rather than by conformance tests.

### Skills over MCP (`io.modelcontextprotocol/skills`)

[SEP-2640](https://modelcontextprotocol.io/seps/2640-skills-extension) is
**Final**. It was created 2026-04-23 and the pull request merged 2026-09-13
([PR #2640](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640)).
It sits on the Extensions Track and is written against base protocol revision
`2026-07-28` or later.

The [Skills Over MCP working group charter](https://modelcontextprotocol.io/community/working-groups/skills-over-mcp)
records the group's formation as an Interest Group on 2026-02-01 and its
conversion to a Working Group on 2026-04-16, on the grounds that it was already
doing binding work. Leads are Ola Hungerford (Nordström), Peter Alexander
(Anthropic) and Sambhav Kothari (Bloomberg). The authority table is:
additive spec changes need WG consensus plus Core Maintainer approval; breaking
changes need wider review; scope expansion needs Core Maintainer approval. The
group meets weekly on Tuesdays for 60 minutes at 9:00 PT.

Specification and decision records live in
[`modelcontextprotocol/ext-skills`](https://github.com/modelcontextprotocol/ext-skills);
conformance scenarios were merged into
[`modelcontextprotocol/conformance`](https://github.com/modelcontextprotocol/conformance/pull/330)
on 2026-09-11. MCP is an AAIF project, so this extension inherits that
stewardship.

### AGENTS.md

`AGENTS.md` was released by OpenAI with Codex in **August 2025** and
**donated to the Agentic AI Foundation (AAIF)** under the Linux Foundation on
**2025-12-09**. AAIF was co-founded the same day by OpenAI, Anthropic and Block,
with support from Google, Microsoft, AWS, Bloomberg and Cloudflare, and is a
directed fund ([announcement](https://openai.com/index/agentic-ai-foundation/)).

**There is no specification.** The
[`agentsmd/agents.md`](https://github.com/agentsmd/agents.md) repository (24.7k
stars, 1.9k forks, 38 commits, MIT) contains a README, a LICENSE, an
`AGENTS.md`, a `Technical_Charter.pdf` and the Next.js site source. There is no
spec document, no RFC process, no versioning scheme and no conformance language.
The [site FAQ](https://agents.md/) states: "Are there required fields? No.
AGENTS.md is just standard Markdown. Use any headings you like; the agent simply
parses the text you provide."

The [Technical Charter](https://github.com/agentsmd/agents.md/blob/main/Technical_Charter.pdf),
adopted 2025-12-08, governs the *project*: Contributors, Maintainers, Core
Maintainers and a Lead Core Maintainer, TSC voting with a quorum, a 75%
supermajority to remove the Lead Core Maintainer, MIT inbound contributions with
DCO sign-off, CC-BY-4.0 documentation and a two-thirds amendment rule. It defines
the mission as "develop a simple, open format for guiding AI agents" and does
not define the format. A third-party assessment states the consequence plainly:
"It has no version number, no RFC-2119 conformance language and no separate
specification document, and calling it a 'spec at version *n*' would be inventing
something that does not exist"
([agents.md.org.ai](https://agents.md.org.ai/)).

### llms.txt

`llms.txt` is authored by Jeremy Howard (Answer.AI / fast.ai), published
**2024-09-03** and last modified **2026-08-10**. The site self-describes as "A
proposal" and states "The llms.txt specification is open for community input".
There is no standards body, no charter, no RFC process and no versioning body.
The [canonical repository](https://github.com/AnswerDotAI/llms-txt) hosts what
the project itself calls an "informal overview" for version control and
discussion, sourced from a Quarto notebook (`nbs/index.qmd`). The author is the
sole publisher of versions. The pages read carry no explicit license statement
(`NOT ESTABLISHED IN SOURCE`).

Version 2 is current. A third-party standards register describes the artifact as
"still a convention, not a ratified standard"
([specification.website](https://specification.website/spec/agent-readiness/llms-txt/)).

### The version number nobody has

| Artifact | Version string | Source of the string |
| --- | --- | --- |
| Agent Skills / `SKILL.md` | none | not published |
| `AGENTS.md` | none | not published |
| `llms.txt` | "v2", dated 2026-08-10 | the author's changelog, no version body |
| `.well-known/agent-skills/index.json` | `$schema: .../discovery/0.2.0/schema.json` | [PR #254](https://github.com/agentskills/agentskills/pull/254), still open |
| Skills over MCP | `io.modelcontextprotocol/skills` plus base revision `2026-07-28` | [SEP-2640](https://modelcontextprotocol.io/seps/2640-skills-extension) |

The discovery schema for a file that is not in any specification carries a
version, and the core `SKILL.md` format does not. The MCP extension is the only
artifact in the layer with a version a client can actually negotiate against.

## What it does

### Agent Skills / SKILL.md

The unit is a directory containing a `SKILL.md` at its root. `SKILL.md` is
required; `scripts/`, `references/`, `assets/` and arbitrary other files and
directories are optional. It is a filesystem format with no wire encoding:
`SKILL.md` is YAML frontmatter plus a free-form Markdown body.

Frontmatter fields, exactly as the specification states them
([spec](https://agentskills.io/specification)):

| Field | Required | Constraints |
| --- | --- | --- |
| `name` | yes | 1–64 chars; `[a-z0-9-]` only; no leading or trailing hyphen; no `--`; must match the parent directory name |
| `description` | yes | 1–1024 chars; must state what the skill does *and* when to use it |
| `license` | no | license name or a bundled-license reference |
| `compatibility` | no | ≤500 chars; environment requirements |
| `metadata` | no | flat `string` → `string` map |
| `allowed-tools` | no | space-separated pre-approved tools; **Experimental** |

Progressive disclosure is the core design principle, in three tiers: about 100
tokens of `name` plus `description` are read at session start; the full
`SKILL.md` body is read on activation and is recommended to stay under 5000
tokens; `scripts/`, `references/` and `assets/` are read only on demand.
Guidance is to keep `SKILL.md` under 500 lines and to keep reference files one
level deep.

**Discovery locations are not in the specification**, which deliberately
declines to say where skills live. The
[client-implementation guide](https://agentskills.io/client-implementation/adding-skills-support)
establishes `<project>/.<client>/skills/`, `<project>/.agents/skills/`,
`~/.<client>/skills/` and `~/.agents/skills/`. It calls `.agents/skills/` "a
widely-adopted convention for cross-client skill sharing" and describes it as
de facto rather than mandatory. The collision rule is that project-level
overrides user-level. The trust rule is a recommendation: gate project-level
skill loading on a folder-trust check, because a freshly cloned open-source
project is untrusted input.

Invocation is model-driven by description matching, or explicit as `/name` or
`$name`.

Vendor extensions live outside the specification, and each vendor documents
which fields are standard and which are theirs: VS Code adds `argument-hint`,
`user-invocable`, `disable-model-invocation` and `context: fork`
([VS Code](https://code.visualstudio.com/docs/agent-customization/agent-skills));
OpenAI adds a sibling `agents/openai.yaml` carrying
`policy.allow_implicit_invocation` and `dependencies.tools[].type: mcp`
([Codex](https://learn.chatgpt.com/docs/build-skills)); Claude Code adds
`!`-command dynamic context injection, `@`-file references and a name-collision
precedence table
([Claude Code](https://code.claude.com/docs/en/skills)).

### Skills over MCP

The extension is a transport binding and nothing else. The specification states
"This extension defines only the transport binding" and "Future revisions of
the Agent Skills specification apply automatically". The
[rationale document](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/rationale.md)
is blunter: "Redefining any of this in an MCP SEP would create a second source of
truth and a drift risk. This SEP is a transport binding; the payload format is
someone else's concern."

It is built entirely on the existing Resources primitive. No new core
primitive was added; the rationale records that the original "new primitive"
approach in SEP-2076 was rejected because it flattens skills to name-addressed
blobs and loses the directory model.

**Capability negotiation.** The server declares the extension in
`capabilities.extensions` during `server/discover`:

```json
{ "io.modelcontextprotocol/skills": { "directoryRead": true } }
```

`directoryRead` is the one optional setting, a boolean defaulting to `false`.
Declaring the extension **MUST** also declare the base `resources` capability.
Clients **MUST NOT** call `skills/list` or `skills/get` before observing the
declaration. To a client that does not support the extension, `skill://`
resources are ordinary resources.

**Methods.**

| Method | Required | Behaviour |
| --- | --- | --- |
| `skills/list` | yes | Paginated and cacheable. May legitimately return an empty or partial result; hosts **MUST NOT** treat that as proof of absence. |
| `skills/get` | yes | Retrieval by URI, returning the same entry shape. Lets a host obtain a manifest for a skill that appeared in no listing. |
| `resources/directory/read` | no, behind `directoryRead: true` | The `ls` analogue. Returns metadata-only direct children, uses `mimeType: "inode/directory"` for subdirectories, is cursor-paginated, and returns `-32602` on a non-directory. |

**File retrieval** is the base `resources/read`, not a new verb. The URI is
`skill://<skill-path>/SKILL.md`, where `<skill-path>` is `/`-separated, its
final segment **MUST** equal the skill's `name`, preceding segments are a
server-chosen organisational prefix, and the first segment occupies the RFC 3986
authority position but carries no semantics — clients **MUST NOT** DNS-resolve
it. `skill://` is conventional, not privileged; a server may equally use
`github://owner/repo/skills/refunds/SKILL.md`.

**The `Skill` entry shape** is `{ uri, frontmatter, resources }`:

| Field | Type | Requirement |
| --- | --- | --- |
| `uri` | URI | the skill's canonical URI |
| `frontmatter` | object | verbatim and unfiltered, exactly as in the file |
| `resources` | `SkillResource[]` or `"dynamic"` | when an array, it **MUST** be complete: every file of the skill, each once, including `SKILL.md` itself |

`SkillResource` is `{ uri, digest, size }` where `digest` is
`"sha256:<64 hex>"`. An entry with no `resources`, or with anything other than
an array or `"dynamic"`, is invalid and hosts **MUST NOT** load it.

**Limits** are fixed so that every conforming host can rely on them without
fetching anything: 512 resources per skill and 16 MiB total per skill. Both are
checkable from the entry alone.

**Caching.** On base revision `2026-07-28` or later, `skills/list` and
`skills/get` extend both `PaginatedResult` and `CacheableResult`; `ttlMs` and
`cacheScope` are required fields per
[SEP-2549](https://modelcontextprotocol.io/seps/2549-TTL-for-list-results).

**Verification.** Digest and size must both match the held entry on every read;
a size mismatch alone is a verification failure. The frontmatter is parsed and
compared field by field against the entry, and any discrepancy blocks the load.
A host is "acting on a skill" from the moment `SKILL.md` enters context until it
leaves; during that window, reading a file not in the manifest is a verification
failure equivalent to a digest mismatch. Hosts **MUST NOT** pre-fetch files on
connection, on listing, or on approval.

**Identity** is the pair (host-assigned server label, skill URI). Hosts **MUST**
keep both halves in the registry, in approvals and in the cache. `name` is a
label, not an identifier: hosts **MUST NOT** assume uniqueness and **MUST**
disambiguate rather than silently drop or prefer.

**Nesting is allowed.** A nested skill's files are ordinary supporting files of
the enclosing skill, so they appear in both manifests. Reading a nested
`SKILL.md` that way is ordinary Markdown and hosts **MUST NOT** act on its
frontmatter; *activating* it requires fresh explicit user consent. Publication
stays flat.

**Out of scope by construction:** the user-interaction model (hosts decide), any
authentication beyond the base protocol's OAuth, and any lifecycle or
streaming semantics — skills are static content.

**Reservations:** the `skills/` method prefix, the `resources/directory/read`
method name, the `io.modelcontextprotocol/skills` label, the
`io.modelcontextprotocol.skills/` `_meta` prefix, and `io.modelcontextprotocol/`
keys inside frontmatter `metadata`.

### The decision log

The [decision log](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/decisions.md)
is the ADR-lite record of accepted design. It is the most direct evidence of
which properties of the extension are load-bearing.

| Date | Decision | Reason recorded |
| --- | --- | --- |
| 2026-02-01 | Group formed as an Interest Group | — |
| 2026-02-14 | MCP-served skills are the *instructor* format (static Markdown). The *helper* model — skills that execute local code — is out of scope. | Helper skills already have repos and npx for distribution, are harder to security-vet, and would likely fail registry security review. |
| 2026-02-21 | `agentskills/agentskills` Discussions designated the cross-project channel. | Respects the upstream governance model rather than fragmenting discussion. |
| 2026-03-16 | `_meta` is reserved for MCP-transport-specific concerns only. | The recorded razor: "does this metadata also apply to non-MCP skills? If so, it should go in frontmatter." |
| 2026-04-16 | URI conventions fixed: prefix allowed, final segment equals the name, `SKILL.md` explicit, no nesting. | No-nesting was reversed on 2026-07-16. |
| 2026-04-16 | Interest Group converted to Working Group. | Already doing binding work. |
| 2026-04-19 | The filesystem is a host-side implementation detail. A skill must work on hosts with no filesystem; hosts may materialise to disk, and relative-path resolution must be identical either way. | Archives permitted as a server-side packaging optimisation. |
| 2026-06-02 | The per-entry `digest` is reinstated. | — |
| 2026-06-05 | **Decoupled from the upstream `.well-known` proposal** and the schema defined independently. | Peter Alexander reported that the upstream discovery spec "has implementations in the wild but no governance momentum into the agentskills.io spec itself". |
| 2026-06-09 | `resources/directory/read` added as a dedicated verb. | Overloading `resources/read` was rejected (varying result schema); a `uri` parameter on `resources/list` was rejected (overloaded semantics). |
| 2026-06-24 | Core-maintainer vote **deferred**, with four structural concerns. | Archive unpacking risk (decompression bombs, path traversal, link escapes, normalisation collisions, non-regular entries); `skill://index.json` as a proprietary out-of-spec format; conflating skills-over-MCP with general distribution; script-execution risk. |
| 2026-07-16 | **The decisive v1 scope-down.** Archives removed and deferred to an appendix; `skill://index.json` replaced by `skills/list`; the single digest replaced by a per-file `resources` manifest; `skills/get` added; `resources/directory/read` demoted to optional behind one flag; skill URI schemes made non-privileged; name-collision handling made normative; nesting allowed with fresh-consent gating. | The lead maintainer's instruction: "break it into something small, land it, and layer complexity afterward." The per-file manifest closed a gap where a benign skill could be approved and then rotate a supporting file such as `references/GUIDE.md`. Name-collision handling was added after a security finding that same-name skills are a live impersonation surface. |
| 2026-09-08 (merged 2026-09-10) | Three divergences between the stable spec page and the SEP corrected. | `ListSkillsResult` must extend `CacheableResult` (it was silently dropping `ttlMs` and `cacheScope`); `GetSkillResult extends CacheableResult`, resolving a question SEP-2640 left open; the `resources`-capability dependency reworded as a consequence of the base Resources spec so a base-conformant server is not made non-conformant. The `2026-07-28` baseline was made explicit. |
| 2026-09-11 | Conformance scenarios merged. | — |
| 2026-09-13 | SEP-2640 marked Final. | — |

### AGENTS.md

The file sits at the repository root and is plain Markdown. No required fields,
no frontmatter, no schema. Nesting is supported and encouraged: "Place another
AGENTS.md inside each package. Agents automatically read the nearest file in
the directory tree, so the closest one takes precedence." The site cites
OpenAI's main repository as containing 88 `AGENTS.md` files
([agents.md](https://agents.md/)). Explicit user chat prompts override
everything.

There is no conformance layer. The content is context, not enforced
configuration; [Claude Code's documentation](https://code.claude.com/docs/en/memory)
states that it "treats them as context, not enforced configuration" and that a
`PreToolUse` hook is needed to block an action. Commands listed in the file are
attempted: "The agent will attempt to execute relevant programmatic checks and
fix failures before finishing the task."

Migration from the losing `AGENT.md` spelling is a symlink:
`mv AGENT.md AGENTS.md && ln -s AGENTS.md AGENT.md`. Aider is configured with
`read: AGENTS.md` in `.aider.conf.yml`; Gemini CLI with
`{"context": {"fileName": "AGENTS.md"}}` in `.gemini/settings.json`.

Claude Code reads `AGENTS.md` natively, "on their own or alongside CLAUDE.md"
([memory docs](https://code.claude.com/docs/en/memory)). The remainder of the
adopter list on agents.md is a first-party claim list rather than per-vendor
documentation.

The singular `AGENT.md` was the competing format that lost: Geoffrey Huntley of
Sourcegraph and Amp, **July 2025**, published as a full IETF-style RFC document
with MUST/SHOULD/MAY, RFC 2119 normative references, an IANA Considerations
section stating that no IANA actions are required, and a change-proposal path
([agentmd/agent.md](https://github.com/agentmd/agent.md)). It added REQUIRED
root placement, a SHOULD list of six sections, hierarchical multi-file support
with `~/.config/AGENT.md`, merging semantics ("more specific files taking
precedence over general ones") and `@`-mentions for file inclusion. Amp owned
the `agent.md` domain and conceded: "we're willing to compromise". Its own
migration table prescribes `ln -s AGENTS.md AGENT.md` for Gemini CLI, OpenAI
Codex and OpenCode — the reverse direction of the AGENTS.md FAQ. Amp shipped
native `AGENT.md` support on 2025-05-07 and multi-file support on 2025-07-07.
The `agent.md` domain now redirects to AGENTS.md. The two repositories are
distinct: `agentmd/agent.md` and `agentsmd/agents.md`.

### llms.txt

`/llms.txt` may sit at the site root or at any subpath. A file covers the URLs
under its path and, since v2, the most specific file applies. Section order is:
an optional byte-order mark; an H1, which is the only required section; a
blockquote summary; zero or more non-heading Markdown blocks; and zero or more
H2-delimited "file lists" of Markdown links, each `- [name](url): optional
notes` ([llmstxt.org](https://llmstxt.org/)).

`## Optional` is a convention for secondary links. v2 explicitly stripped its
mechanical meaning: v1's `llms_txt2ctx` context-expansion tool and the special
handling of that section were both removed.

v2's substantive addition is discovery through standard link relations, which
the [changelog](https://llmstxt.org/changes.html) identifies as the commonest
adoption request. `rel="alternate"; type="text/markdown"` points at a page's
Markdown version; `rel="describedby"` points at the covering `llms.txt`. Both
forms are defined, emitted as an HTML `<link>` or as an HTTP `Link:` header:

```
Link: </docs/page.html.md>; rel="alternate"; type="text/markdown", </docs/llms.txt>; rel="describedby"
```

The header form reaches non-HTML resources and can be set in CDN configuration.
v2 also allows both `page.html.md` (v1) and `page.md` (what publishing tools
actually emit), and defines subpath scoping so a site that controls only a path
can participate.

The specification states explicitly that `llms.txt` is not an alternative to
`/.well-known/` (RFC 8615), because well-known URIs exist only at the origin
root and many authors control only a path, and that it is not a sitemap
substitute. `robots.txt` serves a different purpose: it controls access, while
`llms.txt` is consulted on demand for inference.

`llms-full.txt` is **not** in the specification. It is a vendor convention
generated by Mintlify, GitBook and others; third-party registers list it as an
adjacent `status: optional` entry
([specification.website](https://specification.website/spec/agent-readiness/llms-full-txt/)).
llmstxt.org does not define it.

### Convergence: one format, two carriers

The convergence between Skills over MCP and agentskills.io is structural rather
than rhetorical, and it is deliberate.

1. **The format was not redefined.** SEP-2640 delegates the payload format
   entirely to agentskills.io, and future revisions of the Agent Skills
   specification apply automatically. A `SKILL.md` on disk at
   `.agents/skills/<name>/` and a `SKILL.md` served as
   `skill://<server>/<name>/SKILL.md` are the same artifact under the same
   frontmatter rules.
2. **One resolution codepath is a stated design goal.** The 2026-04-19 decision
   makes the filesystem a host-side detail and requires identical relative-path
   resolution whether the skill came from disk or from `resources/read`, so a
   `references/guide.md` reference means the same thing either way.
3. **The cross-project governance channel is upstream's.** The 2026-02-21
   decision designates Discussions in `agentskills/agentskills` as the primary
   channel, explicitly to respect that project's governance model. Jonathan
   Hefner authored the upstream `.well-known` proposal and participates as an
   MCP core maintainer in the working group.
4. **Convergence is visible at the HTTP edge.** One Mintlify `Link:` header
   advertises `rel="llms-txt"`, `rel="llms-full-txt"`, `rel="api-catalog"`,
   `rel="mcp-server-card"`, `rel="agent-card"` and `rel="agent-skills"`
   simultaneously ([Mintlify llms.txt](https://www.mintlify.com/docs/ai/llmstxt),
   [Mintlify SKILL.md](https://www.mintlify.com/docs/ai/skillmd)). Four
   conventions, one origin, one header.
5. **The layering is complementary, and vendors describe it as such.** Red Hat's
   [2026-07-27 framing](https://developers.redhat.com/articles/2026/07/27/standardize-project-context-agentsmd-and-agent-skills)
   puts `AGENTS.md` as always-on project context shipped with every prompt and
   `SKILL.md` as on-demand procedure. The MCP extension adds a third axis,
   distribution and integrity for remote content. llmstxt.org frames its own
   purpose as being "mainly useful for *inference*". Claude Code's documentation
   makes the same cut, routing multi-step procedures out of `CLAUDE.md` into
   skills; VS Code tabulates skills against custom instructions as different
   purposes, different scope and different portability.
6. **Where they genuinely compete is discovery and distribution.** Both
   `AGENTS.md` and `SKILL.md` are files someone must install or clone. Three
   attempts address that: vendor plugin and marketplace systems, which Red Hat
   states are not standardized; the unmerged upstream
   `/.well-known/agent-skills/index.json` proposal, which the working group
   deliberately decoupled from; and Skills over MCP, which has a Final
   specification and a governance body. MCP settled the standards question on
   this specific point on 2026-09-13. `[INFERENCE]` The competition is over who
   standardises distribution, not over what the instructions look like.

What is not converged: discovery over HTTP, plugin packaging, and client
implementation. `[INFERENCE]`

## What changed recently

### Agent Skills / SKILL.md

| Date | Change | Source |
| --- | --- | --- |
| 2025-10-16 | Skills launched across Claude.ai, Claude Code, the Agent SDK and the Developer Platform, with a `/v1/skills` API endpoint. Partners named at launch: Box, Canva, Notion, Rakuten. | [claude.com/blog/skills](https://claude.com/blog/skills) |
| 2025-10-16 | Anthropic engineering post published (modified 2026-04-15) records the progressive-disclosure rationale and explicit security guidance on untrusted skills. | [Anthropic](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) |
| 2025-12-18 | Published as an open standard and cross-platform port at agentskills.io. | update notes on both Anthropic pages |
| 2026-01-13 | Spring AI generic Agent Skills support. | [clients page](https://agentskills.io/clients) |
| 2026-02-21 | The MCP working group designates agentskills Discussions as the cross-project channel. | [decision log](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/decisions.md) |
| 2026-03-16 | `.well-known/agent-skills/index.json` discovery specification proposed upstream in PR #254. **Still open on 2026-09-29.** | [PR #254](https://github.com/agentskills/agentskills/pull/254) |
| 2026-09-23 | Anthropic shipped a "Claude Marketplace". | [claude.com/blog/skills](https://claude.com/blog/skills) |

During 2026 the vendor distribution layers proliferated and remain
unstandardised: Claude Code plugins and marketplaces (`plugin.json`,
`marketplace.json`), OpenAI plugins bundling skills together with registered
MCP server connections, VS Code agent-plugins, Gemini CLI extensions and Cursor
plugin directories each use a different mechanism.

### Skills over MCP

The dated arc is the decision log above: Interest Group 2026-02-01, instructor
format 2026-02-14, Working Group 2026-04-16, the `.well-known` decoupling
2026-06-05, the core-maintainer deferral 2026-06-24, the v1 scope-down
2026-07-16, spec/SEP divergence fixes 2026-09-08 merged 2026-09-10, conformance
scenarios 2026-09-11, Final 2026-09-13.

One vendor document has not caught up. OpenAI's
[MCP server plugin documentation](https://developers.openai.com/plugins/build/mcp-server)
still calls SEP-2640 "a draft … not yet part of the stable MCP specification"
and demands `capabilities.extensions` while rejecting the earlier `experimental`
declaration, which is inconsistent with the Final status merged 2026-09-13.
`[UNVERIFIED]` whether the page was corrected after it was read.

### AGENTS.md

| Date | Change |
| --- | --- |
| 2025-08 | Released with Codex as a Markdown file alongside `README.md`. |
| 2025-12-08 | Technical Charter adopted; it governs the project, not a format version. |
| 2025-12-09 | Donated to AAIF; AAIF co-founded by OpenAI, Anthropic and Block. |
| 2026 | Native `AGENTS.md` reading added across the ecosystem, Claude Code among them. |
| 2026 | A third-party frontmatter profile proposed at agents.md.org.ai. |

The native-reading change made the older workaround advice stale: Red Hat's
2026-07-27 article still describes the symlink and `@AGENTS.md` import as
necessary, while Claude Code's current documentation describes reading
`AGENTS.md` directly. `[INFERENCE]` from comparing the two dated sources.

The third-party profile is explicitly additive, optional and non-normative: the
site insists "Nothing here amends AGENTS.md, and if the wording below ever
disagrees with agents.md, agents.md is right." It defines MDXLD keys `$id`,
`$type: TechArticle` and `$context: https://schema.org.ai`. Its existence is
evidence of demand for a metadata layer the standard has no room for.

### llms.txt

| Date | Change |
| --- | --- |
| 2024-09-03 | v1 published. |
| 2026-05 | Google Search's AI optimization guide lists llms.txt among tactics you do **not** need, grouped with content chunking, AI-specific rewriting and special schema. `[UNVERIFIED]` single-sourced through Search Engine Journal, 2026-05-20. |
| 2026-05-05 | Chrome Lighthouse's llms.txt audit page last updated. Lighthouse 13.3 ships an **Agentic Browsing** category, on by default, that includes the audit. |
| 2026-08-10 | v2. The changelog states "the community has taken to the proposal far more than I expected" and identifies the biggest gap as discoverability, since v1 required the agent to guess `/llms.txt`. v2 added link relations, blessed both `.md` and `.html.md` URL forms, defined subpath scoping, and replaced the `llms_txt2ctx` tooling description with a direct statement that agents view or search the file and then follow links. |

Integrations listed on llmstxt.org at the research date: Mintlify, GitBook,
Yoast SEO, AIOSEO, Wix, plus the `vitepress-plugin-llms`,
`docusaurus-plugin-llms`, Drupal LLM Support recipe, `llms-txt-php` and VS Code
PagePilot libraries, and an MCP server (`server-llm-txt` in
`mcp-get/community-servers`) for fetching and searching llms.txt files.

### The unmerged discovery proposal

`/.well-known/agent-skills/index.json` deserves its own record because a major
docs platform serves it in production while the pull request that defines it is
still open.

PR #254, "Add spec for `.well-known` URI", by jonathanhefner, opened
**2026-03-16**, still **Open** on 2026-09-29, with companion issue #255. It is
distilled from Cloudflare's `agent-skills-discovery-rfc`
(`[UNVERIFIED]`: the Cloudflare repository was not fetched directly; provenance
is per the pull request description). The proposed shape is

```json
{
  "$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json",
  "skills": [
    { "name": "...", "type": "skill-md", "description": "...",
      "url": "...", "digest": "sha256:..." }
  ]
}
```

where `type` is `skill-md` for a single `SKILL.md` or `archive` for a `.tar.gz`
or `.zip` bundle, and URLs may be relative, path-absolute or fully qualified so
that a CDN can host the artifacts. The proposal also covers `$schema` versioning,
URL resolution, digest verification, archive safety (path traversal, symlinks,
decompression bombs), HTTP requirements and client steps.

The `digest` field is the contested part. Peter Alexander argues it is a
footgun requiring a build process to keep digests in sync with static files,
with little value given HTTP caching and same-trust-domain assumptions. Jonathan
Hefner argues it covers cross-domain integrity (index on one host, artifacts on a
CDN), single-GET staleness detection across a whole catalog, and detecting a
torn read when interdependent skills must update in lockstep.

Mintlify ships the index "following the agent-skills 0.2.0 discovery spec" with
`$schema`, `name`, `type` (always `skill-md`), `description` truncated to 1024
characters to match the `SKILL.md` limit, `url` and `digest`, plus
`GET /.well-known/agent-skills/{name}/SKILL.md`. It keeps a legacy
`/.well-known/skills/index.json` with `{name, description, files}` and
`/.well-known/skills/{name}/skill.md`, and restricts skills to authenticated
user groups through a `groups: ["admin"]` frontmatter field, hidden from public
discovery and exposed as MCP resources only to matching authenticated end
users. `[UNVERIFIED]`: `schemas.agentskills.io` was unreachable from the
research environment, so whether the schema JSON is live is
`NOT ESTABLISHED IN SOURCE`; Mintlify's documentation is the evidence. The page
`agentskills.io/well-known-uri` returns 404, consistent with PR #254 being
unmerged.

The working group's 2026-06-05 decision decoupled the MCP extension from this
proposal and defined its own schema. The two will not auto-converge.

## Evidence of adoption

### Agent Skills / SKILL.md

The [client showcase](https://agentskills.io/clients) lists roughly 40 named
implementers, each linking its own documentation: Claude, Claude Code, ChatGPT
and Codex, Cursor, VS Code, GitHub Copilot, Copilot CLI, the Copilot cloud agent,
Gemini CLI, Amp, Factory, goose (Block), opencode, OpenHands, Junie
(JetBrains), Letta, Databricks Genie Code, Snowflake Cortex Code, Pulumi Neo,
Spring AI, Roo Code, TRAE (ByteDance), Mistral AI Vibe, OpenClaw, Hermes Agent
(Nous Research), ZeroClaw, Autohand, Firebender, Mux (Coder), Emdash, Qodo,
Laravel Boost, Piebald, Kiro (AWS), Workshop, nanobot, fast-agent, Tabnine,
Superconductor, Vita, Ona, Command Code, Deep Code, mcpkit, MCPJam, Agentman,
Google AI Edge Gallery, bub and VT Code. CONTRIBUTING.md gates listing on a
*working* implementation rather than a beta, which makes the list stronger
evidence than an ordinary logo wall.

Repositories: `agentskills/agentskills` (25.8k stars, 2k forks),
`anthropics/skills` (61.2k stars, 6k forks) and `openai/skills`. The
`anthropics/skills` repository's `spec/` directory is now only the redirect stub.

### Skills over MCP: the client support gap

This is the weakest part of the story. The
[official client support matrix](https://modelcontextprotocol.io/extensions/client-matrix)
is community-maintained by pull request.

| Client | Skills support on 2026-09-29 |
| --- | --- |
| mcpc (Apify MCP CLI) | **Full** — the only full-support entry |
| ChatGPT | Partial — imports skills at plugin submission, a static snapshot |
| fast-agent | Partial — first client to interoperate end to end with `hf-mcp-server` |
| MCP Inspector | Partial — SEP-2640 since 2.6.0, 2026-09-09, including CLI skill verification |
| MCPJam Inspector | Partial |
| goose | Planned (issue #12068) |
| Claude web, Claude Desktop, VS Code GitHub Copilot, Microsoft 365 Copilot, Cursor, Postman, Archestra.AI, PostHog Code | blank |

Server and SDK side, from the
[implementations table](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/implementations.md):

| Component | Status |
| --- | --- |
| Go SDK | in progress (#1238) |
| TypeScript SDK | in progress (#2818) |
| Python SDK | in progress (#3485) |
| C# SDK | in progress (#1864) |
| `hf-mcp-server` (Hugging Face) | v1 — `skills/list`, `skills/get`, `directoryRead`, HTTP transports only |
| `github-stars-contrib-mcp-server` | v1 |
| Tachyon (Java) | v1 |
| `github-mcp-server` (GitHub's own) | prototype on a demo branch, not for merge |

**No Claude client is listed as implementing the extension**, although Anthropic
co-leads the working group. `[INFERENCE]` from the matrix. The count is one
full-support client, four SDKs still in progress, and no Claude client.

Adoption evidence outside MCP: OpenAI documents importing skills from an MCP
server implementing `io.modelcontextprotocol/skills`, with strict limits of 5
skills and 10 pages, 256 KiB per `SKILL.md` and 5 MiB total, and a required
complete `resources` list with digests. Mintlify ships the unmerged upstream
`/.well-known/agent-skills/index.json` and an A2A `/.well-known/agent-card.json`
whose `skills` array points at the same skills. `[INFERENCE]` The ecosystem is
routing around the unmerged well-known proposal.

### AGENTS.md

The site claims "over 60,000 open-source projects", evidenced by a GitHub code
search for `path:AGENTS.md NOT is:fork NOT is:archived`, and OpenAI's
announcement repeats it as "more than 60,000 open-source projects and agent
frameworks". This is a self-reported, search-derived figure, not a measured one.

Named adopters on agents.md: OpenAI Codex, Google Jules, Factory, Aider, goose
(Block), opencode, Zed, Warp, VS Code, Devin (Cognition), UiPath Autopilot and
Coded Agents, JetBrains Junie, Amp, Cursor, Roo Code, Gemini CLI, Kilo Code,
Phoenix, Semgrep, the GitHub Copilot coding agent, Ona, Windsurf (Cognition) and
Augment Code. Named repositories with an `AGENTS.md` at the root: `openai/codex`
(632 contributors), `apache/airflow` (4,668 contributors),
`temporalio/sdk-java` (155) and `PlutoLang/Pluto`.

Organisationally, AAIF places `AGENTS.md` alongside MCP, goose, agentgateway,
A2A and Agent Router on its
[project roster](https://aaif.io/projects). Its
[working-group taxonomy](https://aaif.io/) — Accuracy, Agentic Commerce,
Governance, Identity and Trust, Observability, Security and Privacy, Workflows,
Taxonomy — has no group that owns the instructions or skills layer.

### llms.txt

Publishing is mainstream and verifiable. The AI labs publish their own files
at `developers.openai.com/llms.txt`, `docs.anthropic.com/llms.txt` and
`ai.google.dev/gemini-api/docs/llms.txt`, linked from llmstxt.org. Chrome
Lighthouse audits for it in Google-authored code. Docs platforms generate it by
default. llmstxt.org's own claim is "thousands of sites", unsourced by
measurement.

Mintlify's implementation is the strongest single piece of evidence: files
generated at the root and mirrored at `/.well-known/llms.txt`; a 100,000
character cap that splits into recursive `/_llms/*.md` index files;
`.md`-suffixed page links; OpenAPI and AsyncAPI links; an `Optional` section
for external absolute-URL navigation entries; a custom "Agent Instructions"
block; an `X-Llms-Txt: /llms.txt` header plus a multi-relation `Link:` header
advertising llms.txt, llms-full.txt, an API catalog, an MCP server card, an A2A
agent card and an agent-skills index; and auth-aware visibility, where fully
authenticated sites require auth for both files while partially authenticated
sites stay public but exclude restricted pages. FastHTML/nbdev publishes both
`llms.txt` and `.md` page variants as the reference implementation of v2's link
relations.

Consumption is not established. No model vendor discloses whether its crawlers
read llms.txt; a third-party register states "Publishing is mainstream,
consumption is undisclosed, and that asymmetry is the honest case for shipping
it", updated 2026-08-21. Google's Search AI optimization guide lists it among
tactics you do not need; John Mueller compared it to the keywords meta tag and
noted that no AI services used it and that bots did not request the file, and
called building separate Markdown pages for bots "a stupid idea"; Gary Illyes
and Amir Taboul confirmed at Search Central Live APAC that Google is not
pursuing it. Google's own properties once auto-deployed llms.txt through their
CMS and removed it within hours when noticed — an internal platform artefact, not
a Search decision. All of the Google Search positions are `[UNVERIFIED]`,
sourced through Search Engine Journal rather than Google directly.

Where the artifact is load-bearing is software documentation: llmstxt.org says
"llms.txt files are used most heavily for software documentation, where coding
agents follow them to find API references and tutorials". A verified negative
from the research date: `https://agents.md/llms.txt` returns 404, so the
AGENTS.md site publishes no llms.txt.

## Sharp edges

### Discovery locations diverge between clients

The specification deliberately does not say where skills live, and the
implementations do not agree. The divergence is current, not historical.

| Implementation | Project-level locations | User-level locations | Documented scanning behaviour |
| --- | --- | --- | --- |
| Codex | `.agents/skills` | `USER` and `ADMIN` scopes, `/etc/codex/skills` for admin | Scans `.agents/skills` from the current working directory upwards to the repository root; does **not** merge same-named skills, so both appear in selectors. Also applies a 2% and 8000-character budget to the skill catalog. ([docs](https://learn.chatgpt.com/docs/build-skills)) |
| VS Code / Copilot | `.github/skills/`, `.claude/skills/`, `.agents/skills/` | `~/.copilot`, `~/.claude`, `~/.agents` | Reads all three project locations. ([docs](https://code.visualstudio.com/docs/agent-customization/agent-skills)) |
| Claude Code | `.claude/skills/` in enterprise, personal, project, nested and plugin scopes | personal `.claude/skills` | Documents `.claude/skills/` locations, with a note that some implementations also scan `.agents/skills/` for compatibility; it does not treat `.agents/skills/` as a primary path. ([docs](https://code.claude.com/docs/en/skills)) |

`.agents/skills/` is the closest thing to a cross-client convention, and the
client guide calls it de facto rather than mandatory. `[INFERENCE]` A skill
placed in `.agents/skills/` reaches Codex and VS Code reliably and Claude Code
only through the compatibility path, so cross-client portability is aspirational
rather than guaranteed.

Failure modes are silent in at least one implementation: VS Code documents that
a `name` containing slashes, colons or dots, or a namespaced prefix such as
`myorg/skillname`, makes the skill silently fail to load, and that a skill whose
name collides with a bundled skill is replaced without a prompt. Codex, by
contrast, shows both same-named skills in its selectors. Neither behaviour is
specified.

Validation leniency is a portability hazard by design: the client guide tells
implementers to warn and load anyway when the name does not match the directory,
which deviates from a MUST in the specification. A skill authored for a lenient
client can be technically invalid against the spec.

### Prompt injection is the format's core risk

Every mechanism in this layer puts unreviewed bytes into model context. The
layers differ in whether they acknowledge it.

**Agent Skills from disk.** Anthropic's own launch post warns that malicious
skills can exfiltrate data. The repository's README and CONTRIBUTING do not
mandate provenance or signing. The
[`.well-known` proposal](https://github.com/agentskills/agentskills/pull/254)
explicitly adds a "Prompt injection" bullet to its security section, which
indicates the upstream specification does not yet treat the problem as its own.
The client guide only recommends a folder-trust gate for project-level skills;
no vendor mandates one. `allowed-tools` is Experimental and vendor support
varies.

**`AGENTS.md`.** The file is unreviewed prose from an untrusted repository,
injected into the model's context every session. There is no trust gate, no
security section and no escalation path, in either the standard or any of the
vendor documentation read.

**`llms.txt`.** A published file is attacker-writable content on the same
origin as the documentation, and the format has no integrity mechanism of any
kind — no digest, no signature, no versioning.

**Skills over MCP** is the only layer in this set with a full, prescriptive
Security Considerations section, and it answers by assigning the burden to the
host. The obligations it places on an implementing host are:

- Treat MCP-served content as untrusted model input, and as *higher-risk than
  remote tool invocation*.
- Tag origin at the point the content enters context, and never present it as
  indistinguishable from a local filesystem skill.
- Do not allow implicit host-side code execution, covering both declarative
  fields the host parses and body instructions that direct the model to run
  code.
- Enforce origin-scoped resource reads: a skill from server A must not cause a
  `resources/read` against server B. The specification names this an explicit
  confused-deputy vector.
- Ignore `allowed-tools` for MCP-origin skills without explicit user opt-in.
  `[UNVERIFIED]` the clause is truncated in the source material at "without
  explicit use…", so the precise condition is `NOT ESTABLISHED IN SOURCE`; the
  obligation to ignore the field is not in doubt.
- Verify digest and size against the held entry on every read, compare
  frontmatter field by field, refuse to load on any discrepancy, and treat an
  unlisted-file read during the activation window as a verification failure.
- Not pre-fetch files on connection, on listing, or on approval.
- Keep both halves of the identity pair in registry, approvals and cache, and
  disambiguate same-name skills rather than preferring one. The 2026-07-16
  decision records that same-name skills are a live impersonation surface.
- Require fresh explicit user consent to activate a nested skill.

The asymmetry is the finding: the newest and least-deployed layer has the best
threat model, and the most widely used artifact, `AGENTS.md`, has none.

### Skills over MCP

- **The adoption gap between specification maturity and client support is
  severe.** The specification went Final on 2026-09-13; sixteen days later the
  official matrix has one full-support client, all four official SDKs in
  progress, GitHub's own server as a prototype on a demo branch, and no Claude
  client at all.
- **The extension is deliberately lossy relative to the format it carries.**
  The 2026-02-14 decision makes MCP-served skills the instructor format only,
  so a skill served over MCP cannot ship executable helpers.
- **Archives were removed and bulk retrieval has no replacement.** Per-file
  reads mean an N-file skill costs N round trips. The 512-resource and 16 MiB
  limits are the only bulk story. The appendix records that reintroducing
  archives must start from the Core Maintainers' security objections rather
  than rediscover them.
- **`"dynamic"` skills are a dead end by construction.** They have no content
  integrity and cannot be content-bound; hosts **MAY** decline them and server
  authors **SHOULD** expect some to. OpenAI's importer requires a complete
  `resources` list with digests, so dynamic skills are unusable there.
- **`resources/directory/read` can disagree with the held manifest by design.**
  A live directory read may list files the manifest lacks. Hosts **MUST NOT**
  treat that as extending the manifest and **MUST** present the situation as
  "changed, needs re-approval" rather than a read error. No shared version token
  exists to make the two comparable.
- **Partial and empty listings are legal**, so a host that assumes exhaustive
  enumeration will silently miss skills on gateway or generative servers.
- **The upstream `.well-known` decoupling is a live divergence risk.** The
  working group traded alignment for unblocking, accepting divergence from a
  format that already has a production consumer in Mintlify. If the upstream
  proposal revives, re-convergence is owed.
- **Distribution is explicitly out of scope.** The charter places plugin and
  bundle packaging and registry schema in other groups' hands, so the
  "install a skill" story remains fragmented.

### AGENTS.md

- **A foundation-governed artifact with no specification.** AAIF provides
  neutral stewardship, but there is no normative document for the Technical
  Steering Committee to approve or reject, no way to detect a vendor shipping a
  broken `AGENTS.md` reader, and no compatibility story. The Charter's mission
  of "a simple, open format" is unbacked by a format definition.
- **Plain Markdown puts the semantics in each implementation, and they
  diverge.** Unresolved questions include whether a root file is merged with or
  overridden by a nested one, whether content is truncated, and whether listed
  commands are auto-executed. Claude Code *concatenates* discovered files rather
  than overriding, orders them root to current working directory, and strips
  `<!-- -->` HTML comments before injection. No standard mentions any of this.
- **Token bloat is unmanaged.** Red Hat's guidance to keep under roughly 150
  lines, or 30–50 for small repositories, is vendor advice rather than
  specification, because no size budget exists anywhere. The contrast with
  Agent Skills' explicit three-tier budget of about 100 and under 5000 tokens
  is instructive.
- **No machine-readable metadata.** The `agents.md.org.ai` profile and
  Mintlify's "custom agent instructions" block are both third-party inventions
  filling the same gap. A separate third-party repository
  publishes a SPECIFICATION.md and CHANGELOG.md for `AGENTS.md`; it is not the
  standard, and its existence is evidence of the spec vacuum rather than of a
  format.
- **The name fight cost a year.** `AGENT.md` against `AGENTS.md` consumed 2025
  and still leaves symlink farms. The migration advice produced symlinks, and
  filesystem parsers can double-inject symlinked ancestor scopes
  (`[UNVERIFIED]`, secondary source).

### llms.txt

- **Publishing is mainstream; consumption is undisclosed.** No model vendor
  states whether its crawlers read the file, and one large vendor advises
  against it.
- **Google is internally contradictory, which is itself the finding.** Search
  says skip it; Chrome Lighthouse audits for it. The audit is Not Applicable on
  a 404 — Lighthouse only flags server errors retrieving the file — so
  providing llms.txt is explicitly optional. The categories are separate:
  Search visibility versus agentic-browser readiness.
- **Governance is one person.** No standards body, no charter, no RFC process,
  no version body, and the author is the sole publisher of versions.
- **The v2 `Optional` section lost its mechanics.** The `llms_txt2ctx`
  context-expansion tool was removed, so a consumer that relied on the section
  having defined meaning has to re-read the file itself.
- **Not superseded by MCP, because it does a different job.** MCP serves
  structured data and tools; llms.txt curates which human-authored pages matter
  and points at them. The meeting point is HTTP: one Mintlify `Link:` header
  advertises both, plus an A2A agent card and an agent-skills index.

### Cross-cutting

- **Governance asymmetry.** llms.txt has one author and no body. `AGENTS.md` has
  a Linux Foundation foundation and a Technical Charter but no format spec.
  Agent Skills has a real specification, no version, Anthropic-team merge
  authority and no TSC. Skills over MCP has the only properly governed process
  in the set — charter, decision log, conformance suite — attached to a
  transport almost nobody has implemented. The most used artifact has the least
  specified one; the best-specified artifacts are least used over their intended
  channel.
- **Extension-field sprawl with no registry.** `context: fork`,
  `argument-hint`, `user-invocable`, `disable-model-invocation`,
  `agents/openai.yaml`, `groups`, `!`-injection and `@`-references are all
  documented per vendor and silently ignored elsewhere. The MCP extension's
  2026-03-16 `_meta` decision is the right shape of answer — MCP-specific
  concerns in `_meta`, everything else in frontmatter — but nothing enforces it
  for vendor extensions, and the core specification has no extension or
  versioning mechanism at all.
- **Nobody discloses consumption.** No vendor says whether its crawler reads
  llms.txt; no vendor publishes which skills its users have or which trigger;
  the `AGENTS.md` figure is a code search, not a usage measurement. This layer's
  adoption evidence is structurally weaker than the protocol layer's.
- **Naming churn is current state, not history.** `AGENT.md` against
  `AGENTS.md`, `AGENTS.md` against `CLAUDE.md` against `GEMINI.md`,
  `.claude/skills/` against `.agents/skills/` against `.github/skills/`,
  `skill://` against arbitrary schemes, and `/.well-known/skills/` against
  `/.well-known/agent-skills/` are all live.

## Sources

### Agent Skills

- [agentskills.io/specification](https://agentskills.io/specification) — the
 format specification: frontmatter table, directory layout, progressive
 disclosure, validation
- [agentskills.io/home](https://agentskills.io/home) — overview and progressive
 disclosure
- [agentskills.io/clients](https://agentskills.io/clients) — the client showcase,
 roughly 40 implementers with per-vendor documentation links
- [agentskills.io/client-implementation/adding-skills-support](https://agentskills.io/client-implementation/adding-skills-support)
 — discovery directories, the `.agents/skills/` convention, collision
 precedence, trust gating, lenient validation
- [github.com/agentskills/agentskills](https://github.com/agentskills/agentskills)
 — the specification repository, 25.8k stars
- [CONTRIBUTING.md](https://github.com/agentskills/agentskills/blob/main/CONTRIBUTING.md)
 — governance, the bar for specification additions, no `skills-ref` code
 contributions, Anthropic reviews listings, mandatory AI disclosure
- [anthropics/skills README](https://github.com/anthropics/skills/blob/main/README.md)
 — example skills, the specification stub redirect, plugin marketplace install
- [anthropics/skills specification stub](https://github.com/anthropics/skills/blob/main/spec/agent-skills-spec.md)
 — "The spec is now located at https://agentskills.io/specification"
- [Anthropic engineering post](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
 — origin post, published 2025-10-16, modified 2026-04-15, security section
- [claude.com/blog/skills](https://claude.com/blog/skills) — launch 2025-10-16,
 the 2025-12-18 update, launch partners, `/v1/skills`
- [code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills) —
 Claude Code skill locations, name-collision table, account sync, security
 handling
- [code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory) —
 Claude Code reads `AGENTS.md` natively, `CLAUDE.md` scope table, `.claude/rules/`
- [code.visualstudio.com/docs/agent-customization/agent-skills](https://code.visualstudio.com/docs/agent-customization/agent-skills)
 — VS Code and Copilot skill directories, extension frontmatter
- [learn.chatgpt.com/docs/build-skills](https://learn.chatgpt.com/docs/build-skills)
 — Codex skill scopes, catalog budget, `agents/openai.yaml`, plugins
- [github.com/agentskills/agentskills/pull/254](https://github.com/agentskills/agentskills/pull/254)
 — the `.well-known/agent-skills/index.json` proposal, open since 2026-03-16, the
 digest debate

### Skills over MCP

- [skills.extensions.modelcontextprotocol.io/specification/stable/skills](https://skills.extensions.modelcontextprotocol.io/specification/stable/skills)
 — the stable extension specification, `skill://` rules, limits, Security
 Considerations
- [modelcontextprotocol.io/extensions/skills/overview](https://modelcontextprotocol.io/extensions/skills/overview)
 — official overview, message flow, capability negotiation
- [modelcontextprotocol.io/seps/2640-skills-extension](https://modelcontextprotocol.io/seps/2640-skills-extension)
 — SEP-2640, Final
- [github.com/modelcontextprotocol/modelcontextprotocol/pull/2640](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640)
 — the pull request, merged 2026-09-13
- [modelcontextprotocol.io/community/working-groups/skills-over-mcp](https://modelcontextprotocol.io/community/working-groups/skills-over-mcp)
 — working group charter, leads, authority table, changelog
- [ext-skills decisions.md](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/decisions.md)
 — the full decision log, 2026-02-14 to 2026-09-08
- [ext-skills rationale.md](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/rationale.md)
 — design rationale, including the transport-binding argument
- [ext-skills implementations.md](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/implementations.md)
 — the SDK, server and host status table
- [modelcontextprotocol.io/extensions/client-matrix](https://modelcontextprotocol.io/extensions/client-matrix)
 — the official client support matrix
- [developers.openai.com/plugins/build/mcp-server](https://developers.openai.com/plugins/build/mcp-server)
 — OpenAI's MCP skill import, its limits and digest requirements; still calls
 SEP-2640 a draft
- [github.com/modelcontextprotocol/conformance/pull/330](https://github.com/modelcontextprotocol/conformance/pull/330)
 — conformance scenarios, merged 2026-09-11
- [modelcontextprotocol.io/seps/2549-TTL-for-list-results](https://modelcontextprotocol.io/seps/2549-TTL-for-list-results)
 — `CacheableResult`, `ttlMs` and `cacheScope`
- [github.com/aaif-goose/goose/issues/12068](https://github.com/aaif-goose/goose/issues/12068)
 — planned goose support
- [github.com/huggingface/hf-mcp-server](https://github.com/huggingface/hf-mcp-server)
 — the one notable v1 server
- [github.com/apify/mcpc](https://github.com/apify/mcpc) — mcpc, the only
 full-support client

### AGENTS.md

- [agents.md](https://agents.md/) — the format home, the 60,000-plus claim, the
 adopter list, the FAQ on required fields, nesting and migration
- [github.com/agentsmd/agents.md](https://github.com/agentsmd/agents.md) — the
 repository, MIT, 24.7k stars, file tree with no specification document
- [Technical_Charter.pdf](https://github.com/agentsmd/agents.md/blob/main/Technical_Charter.pdf)
 — the governance charter adopted 2025-12-08
- [openai.com/index/agentic-ai-foundation](https://openai.com/index/agentic-ai-foundation/)
 — AAIF co-founding, the AGENTS.md donation, 2025-12-09
- [aaif.io/projects](https://aaif.io/projects) — the AAIF project roster
- [aaif.io](https://aaif.io/) — the AAIF working-group taxonomy
- [agents.md.org.ai](https://agents.md.org.ai/) — third-party critique: no
 version, no RFC 2119, no specification document
- [github.com/agentmd/agent.md](https://github.com/agentmd/agent.md) — the
 losing `AGENT.md` format, July 2025
- [github.com/TechSpokes/agency-specifications-files-agents-md](https://github.com/TechSpokes/agency-specifications-files-agents-md)
 — a third-party "AGENTS.md specification" with a changelog, evidence of the
 spec vacuum

### llms.txt

- [llmstxt.org](https://llmstxt.org/) — the specification, v2, published
 2024-09-03, modified 2026-08-10
- [llmstxt.org/changes.html](https://llmstxt.org/changes.html) — the v2
 changelog and rationale
- [github.com/AnswerDotAI/llms-txt](https://github.com/AnswerDotAI/llms-txt) —
 the canonical source, `nbs/index.qmd`
- [developer.chrome.com llms.txt audit](https://developer.chrome.com/docs/lighthouse/agentic-browsing/llms-txt)
 — the Lighthouse audit, "emerging convention", Not Applicable on 404, last
 updated 2026-05-05
- [www.mintlify.com/docs/ai/llmstxt](https://www.mintlify.com/docs/ai/llmstxt) —
 llms.txt and llms-full.txt generation, the `/_llms/` split, the `Link:` and
 `X-Llms-Txt:` headers
- [www.mintlify.com/docs/ai/skillmd](https://www.mintlify.com/docs/ai/skillmd) —
 `/.well-known/agent-skills/index.json`, the legacy path, the A2A agent card,
 the `groups` frontmatter field
- [specification.website llms.txt entry](https://specification.website/spec/agent-readiness/llms-txt/)
 — "not a ratified standard", consumption undisclosed
- [Search Engine Journal on Google's llms.txt guidance](https://www.searchenginejournal.com/googles-llms-txt-guidance-depends-on-which-product-you-ask/575431/)
 — secondary sourcing of the split guidance, the Mueller quotes and Lighthouse
 13.3
- [developers.redhat.com, 2026-07-27](https://developers.redhat.com/articles/2026/07/27/standardize-project-context-agentsmd-and-agent-skills)
 — the AGENTS.md/SKILL.md split, token budgets, `.agents/skills/`, and the
 admission that packaging is not standardised

### Not verified during research

- `schemas.agentskills.io/discovery/0.2.0/schema.json` was unreachable, so the
  live availability of the discovery schema is `NOT ESTABLISHED IN SOURCE`.
- The Google Search AI optimization guide and Cloudflare's
  `agent-skills-discovery-rfc` were not fetched directly; both are cited through
  sources that quote or link them.
- Whether OpenAI's MCP plugin documentation still describes SEP-2640 as a draft
  after the research date is `NOT ESTABLISHED IN SOURCE`.
- The full 681-line SEP-2640 text and the 955-line stable extension
  specification were not read end to end. Claims about the SEP's deferred-
  features appendix rest on the decision log and the rationale document, not on
  the appendix text.
