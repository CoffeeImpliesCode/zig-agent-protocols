# Instructions and observability: normative wire values

Verbatim transcription of the machine-readable and specification text behind the
instruction-discovery, skill-loading, observability and identity layers of the
agent protocol stack: the Agent Skills `SKILL.md` frontmatter grammar and the
`skills-ref` validator that enforces it, the MCP Skills extension
(`io.modelcontextprotocol/skills`), AGENTS.md, the OpenTelemetry GenAI and MCP
semantic conventions, the MCP trace-context `_meta` reservations,
`draft-ietf-webbotauth-httpsig-protocol-00`, and the A2A signed Agent Card
section. Every enumeration is written out row by row. Nothing is summarised to a
count.

- Research date: 2026-09-29
- Contract: [`../../PROTOCOLS.md`](../../PROTOCOLS.md) — the normative wire values
- Evidence: this file, transcribed from the artifacts named per table

## Artifact provenance

| # | Artifact | URL | What it established |
| - | - | - | - |
| 1 | Agent Skills specification | `https://agentskills.io/specification` | Frontmatter key table, per-field constraints, directory layout, progressive-disclosure token budgets |
| 2 | `skills-ref` reference validator | `https://raw.githubusercontent.com/agentskills/agentskills/main/skills-ref/src/skills_ref/validator.py` | `MAX_SKILL_NAME_LENGTH=64`, `MAX_DESCRIPTION_LENGTH=1024`, `MAX_COMPATIBILITY_LENGTH=500`, `ALLOWED_FIELDS`, NFKC normalisation, directory-name match |
| 3 | `skills-ref` README | `https://raw.githubusercontent.com/agentskills/agentskills/main/skills-ref/README.md` | `validate` / `read-properties` / `to-prompt` CLI, `<available_skills>` XML format |
| 4 | MCP Skills extension source of truth | `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` | Extension identifier, three methods, `Skill` / `SkillResource`, `directoryRead`, 512-entry and 16 MiB limits, `sha256:{hex}` digest |
| 5 | Rendered MCP Skills extension | `https://skills.extensions.modelcontextprotocol.io/specification/stable/skills` | Same, rendered against base revision `2026-07-28` |
| 6 | SEP-2640 Skills Extension | `https://modelcontextprotocol.io/seps/2640-skills-extension` | Result-field required/optional table, worked URI examples |
| 7 | SEP-414 OTel Trace Context Propagation | `https://modelcontextprotocol.io/seps/414-request-meta` | The unprefixed `traceparent` / `tracestate` / `baggage` `_meta` exception |
| 8 | MCP base spec `2026-07-28`, General fields / `_meta` | `https://modelcontextprotocol.io/specification/2026-07-28/basic/index` | `_meta` key-name grammar, reserved-prefix rule, reserved key table, per-request and per-response `io.modelcontextprotocol/*` fields |
| 9 | AGENTS.md project site | `https://agents.md/` | File locations, nested-file guidance, conflict-resolution FAQ, required-fields FAQ |
| 10 | agentsmd/agents.md README | `https://raw.githubusercontent.com/agentsmd/agents.md/main/README.md` | Minimal example. No specification document exists in the repository |
| 11 | AGENTS.md Technical Charter | `https://raw.githubusercontent.com/agentsmd/agents.md/main/Technical_Charter.pdf` | Governance only (adopted 2025-12-08, LF Projects). No format specification |
| 12 | OTel MCP semantic conventions | `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md` | `mcp.client` / `mcp.server` spans, four `mcp.*` metrics, 25-value `mcp.method.name` enum, transport recording, context propagation |
| 13 | OTel GenAI model spans | `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-spans.md` | Inference / embeddings / retrieval / fetch-response / memory / execute-tool span names and the `gen_ai.*` attribute table |
| 14 | OTel GenAI agent spans | `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-agent-spans.md` | Create agent, invoke agent (client and internal), invoke workflow, plan |
| 15 | OTel GenAI metrics | `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-metrics.md` | Instrument types, UCUM units, explicit bucket boundaries |
| 16 | OTel GenAI token metrics | `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-token-metrics.md` | Five `{token}` counters, two `{token}` histograms, `gen_ai.token.modality` enum |
| 17 | OTel GenAI events | `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-events.md` | `gen_ai.client.inference.operation.details`, `gen_ai.evaluation.result` |
| 18 | OTel GenAI README | `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/README.md` | Document status `Development`; dependency versions |
| 19 | `draft-ietf-webbotauth-httpsig-protocol-00` | `https://www.ietf.org/archive/id/draft-ietf-webbotauth-httpsig-protocol-00.txt` | `Signature-Agent` dictionary header, well-known URI, JWKS directory format, `signature-input` / label syntax, keyid thumbprint rules, IANA registrations |
| 20 | Cloudflare Web Bot Auth implementation doc | `https://developers.cloudflare.com/bots/reference/bot-verification/web-bot-auth/` | Deployed form against the older `directory-03` / `architecture-02` drafts; its divergences |
| 21 | A2A 1.0 specification | `https://a2a-protocol.org/latest/specification/` | §4.4 `AgentCard.signatures`, §5.7 field presence, §8.4–8.4.3 Agent Card Signing |

## 1. Agent Skills: `SKILL.md` frontmatter

### 1.1 Frontmatter keys

Source: `https://agentskills.io/specification` — §"`SKILL.md` format" / §Frontmatter
(markdown alternate `https://agentskills.io/specification.md`)

| Field | Required | Constraints (verbatim) |
| - | - | - |
| `name` | Yes | Max 64 characters. Lowercase letters, numbers, and hyphens only. Must not start or end with a hyphen. |
| `description` | Yes | Max 1024 characters. Non-empty. Describes what the skill does and when to use it. |
| `license` | No | License name or reference to a bundled license file. |
| `compatibility` | No | Max 500 characters. Indicates environment requirements (intended product, system packages, network access, etc.). |
| `metadata` | No | Arbitrary key-value mapping for additional metadata (a map from string keys to string values). |
| `allowed-tools` | No | Space-separated string of pre-approved tools the skill may use. (Experimental) |

No other frontmatter key is defined. No length limit is stated for `license`,
`metadata` or `allowed-tools`. No YAML type is stated for `license`; the example
is a bare string, `license: Apache-2.0`.

### 1.2 Per-field normative constraints

Source: `https://agentskills.io/specification` — §"`name` field", §"`description`
field", §"`compatibility` field", §"`metadata` field", §"`allowed-tools` field"

| Field | Constraint (verbatim) |
| - | - |
| `name` | Must be 1-64 characters |
| `name` | May only contain unicode lowercase alphanumeric characters (`a-z`, `0-9`) and hyphens (`-`) |
| `name` | Must not start or end with a hyphen (`-`) |
| `name` | Must not contain consecutive hyphens (`--`) |
| `name` | Must match the parent directory name |
| `description` | Must be 1-1024 characters |
| `description` | Should describe both what the skill does and when to use it |
| `description` | Should include specific keywords that help agents identify relevant tasks |
| `compatibility` | Must be 1-500 characters if provided |
| `metadata` | A map from string keys to string values |
| `allowed-tools` | A space-separated string of tools that are pre-approved to run. Experimental. Support for this field may vary between agent implementations |

The three length bounds named in the contract are therefore: `name` 1–64,
`description` 1–1024, `compatibility` 1–500.

#### CONFLICT — `name` character class

Two statements in the same primary source disagree.

| Source location | Statement |
| - | - |
| `https://agentskills.io/specification` §Frontmatter table, `name` row | "Lowercase letters, numbers, and hyphens only." |
| `https://agentskills.io/specification` §"`name` field" bullet 2 | "May only contain unicode lowercase alphanumeric characters (`a-z`, `0-9`) and hyphens (`-`)" |

The parenthetical `(a-z, 0-9)` contradicts the word "unicode". The validator
resolves this in favour of the broader reading; see 1.3.

### 1.3 Validator-enforced constraints (`skills-ref`)

Source: `https://raw.githubusercontent.com/agentskills/agentskills/main/skills-ref/src/skills_ref/validator.py`

| Validator constant | Value | Source line |
| - | - | - |
| `MAX_SKILL_NAME_LENGTH` | `64` | module-level |
| `MAX_DESCRIPTION_LENGTH` | `1024` | module-level |
| `MAX_COMPATIBILITY_LENGTH` | `500` | module-level |

`ALLOWED_FIELDS` set, the complete membership:

| `ALLOWED_FIELDS` member | Source line |
| - | - |
| `name` | `ALLOWED_FIELDS = {` |
| `description` | (same set) |
| `license` | (same set) |
| `allowed-tools` | (same set) |
| `metadata` | (same set) |
| `compatibility` | (same set) |

Validator behaviour, verbatim conditionals:

| Rule | Verbatim source expression | Failure message |
| - | - | - |
| Name non-empty | `if not name or not isinstance(name, str) or not name.strip():` | `Field 'name' must be a non-empty string` |
| Name NFKC-normalized then trimmed | `name = unicodedata.normalize("NFKC", name.strip())` | — |
| Name length | `if len(name) > MAX_SKILL_NAME_LENGTH:` | `Skill name '{name}' exceeds 64 character limit ({len} chars)` |
| Name lowercase | `if name != name.lower():` | `Skill name '{name}' must be lowercase` |
| No leading/trailing hyphen | `if name.startswith("-") or name.endswith("-"):` | `Skill name cannot start or end with a hyphen` |
| No consecutive hyphens | `if "--" in name:` | `Skill name cannot contain consecutive hyphens` |
| Character class | `if not all(c.isalnum() or c == "-" for c in name):` | `Skill name '{name}' contains invalid characters. Only letters, digits, and hyphens are allowed.` |
| Directory-name match | `dir_name = unicodedata.normalize("NFKC", skill_dir.name)` then `if dir_name != name:` | `Directory name '{skill_dir.name}' must match skill name '{name}'` |
| Unknown top-level key | `extra_fields = set(metadata.keys()) - ALLOWED_FIELDS` | `Unexpected fields in frontmatter: {…}. Only {…} are allowed.` |
| Missing `name` | `if "name" not in metadata:` | `Missing required field in frontmatter: name` |
| Missing `description` | `if "description" not in metadata:` | `Missing required field in frontmatter: description` |
| `description` non-empty | `if not description or not isinstance(description, str) or not description.strip():` | `Field 'description' must be a non-empty string` |
| `compatibility` type | `if not isinstance(compatibility, str):` | `Field 'compatibility' must be a string` |
| Required file | `find_skill_md(skill_dir)` returns `None` | `Missing required file: SKILL.md` |

Notes on the character class: `str.isalnum()` is Unicode-aware, so the validator
accepts any Unicode alphanumeric character that survives the separate
`name == name.lower()` test. `len()` is Python code-point count, not UTF-8 byte
count. NFKC is applied to both `name` and the directory name before comparison,
so the directory-name match is against the NFKC-folded form. The NFKC
normalisation of the name is the first transform applied, before every
subsequent check.

#### GAP — unknown top-level frontmatter keys

The specification does not state that unknown top-level frontmatter keys are
invalid. The validator rejects them outright. No specification text authorises
this. The specification side is `[UNVERIFIED]`.

### 1.4 Directory layout

Source: `https://agentskills.io/specification` — §Directory structure (verbatim block)

```
skill-name/
├── SKILL.md          # Required: metadata + instructions
├── scripts/          # Optional: executable code
├── references/       # Optional: documentation
├── assets/           # Optional: templates, resources
└── ...               # Any additional files or directories
```

| Path | Required | Spec status |
| - | - | - |
| `SKILL.md` | Yes | "A skill is a directory containing, at minimum, a `SKILL.md` file" |
| `scripts/` | No | "Contains executable code that agents can run." Conventions: "The conventions below are recommendations for organizing common types of content." |
| `references/` | No | Named examples given: `REFERENCE.md`, `FORMS.md`, "Domain-specific files (`finance.md`, `legal.md`, etc.)" |
| `assets/` | No | "Contains static resources: Templates …, Images …, Data files …" |
| any other | No | "A skill directory may contain any files and directories beyond the required `SKILL.md`." |

Only `SKILL.md` is required. `scripts/`, `references/` and `assets/` are
explicitly "recommendations".

### 1.5 Token-budget and size guidance

Source: `https://agentskills.io/specification` — §Progressive disclosure,
§Body content, §File references

| Stage | Guidance (verbatim) | Number |
| - | - | - |
| Metadata | "**Metadata** (~100 tokens): The `name` and `description` fields are loaded at startup for all skills" | ~100 tokens |
| Instructions | "**Instructions** (< 5000 tokens recommended): The full `SKILL.md` body is loaded when the skill is activated" | < 5000 tokens |
| Resources | "**Resources** (as needed): Files (e.g. those in `scripts/`, `references/`, or `assets/`) are loaded only when required" | no number |
| File size | "Keep your main `SKILL.md` under 500 lines. Move detailed reference material to separate files." | < 500 lines |
| Reference depth | "Keep file references one level deep from `SKILL.md`. Avoid deeply nested reference chains." | 1 level |
| Reference path form | "use relative paths from the skill root" | — |

The two token budgets the contract names: ~100 tokens at session start
(metadata) and < 5000 on activation (instructions). < 500 lines is a line
budget, not a token budget.

### 1.6 `skills-ref` CLI surface

Source: `https://raw.githubusercontent.com/agentskills/agentskills/main/skills-ref/README.md`

| Command | Output |
| - | - |
| `skills-ref validate path/to/skill` | validation errors to stdout |
| `skills-ref read-properties path/to/skill` | JSON |
| `skills-ref to-prompt path/to/skill-a path/to/skill-b` | `<available_skills>` XML |

Python API: `from skills_ref import validate, read_properties, to_prompt`.

`<available_skills>` XML element order, verbatim:

```xml
<available_skills>
<skill>
<name>
my-skill
</name>
<description>
What this skill does and when to use it
</description>
<location>
/path/to/my-skill/SKILL.md
</location>
</skill>
</available_skills>
```

The README states: "This format is recommended for Anthropic's models, but Skill
Clients may choose to format it differently based on the model being used." Not
normative. The README also states: "This library is intended for demonstration
purposes only. It is not meant to be used in production."

## 2. Skills over MCP (`io.modelcontextprotocol/skills`)

### 2.1 Extension identity

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` — §Extension Identifier, §Protocol Revision

| Field | Value |
| - | - |
| Extension identifier | `io.modelcontextprotocol/skills` |
| Base protocol revision | `2026-07-28` or later |
| SEP | SEP-2640, title "Skills Extension", status `Final`, type `Extensions Track`, created `2026-04-23`, PR `#2640` |
| Reserved `_meta` prefix for this extension | `io.modelcontextprotocol.skills/` |
| Reserved extension label | `io.modelcontextprotocol/skills` |

### 2.2 Method names

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx`

| Method | Verbatim `method` literal | Required when |
| - | - | - |
| Enumerate skills | `"skills/list"` | "A server that declares this extension **MUST** implement" |
| Fetch one skill | `"skills/get"` | "A server that declares this extension **MUST** implement" |
| Read a directory resource | `"resources/directory/read"` | "A server that additionally declares `directoryRead: true` **MUST** implement" |
| Read a file | `"resources/read"` | base protocol, unmodified: "Skill files are read via the standard `resources/read` method. No skill-specific read semantics are defined." |

The extension adds three methods. `resources/read` is the base protocol's and is
not redefined.

### 2.3 Capability-declaration object shape

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` — §Capability Negotiation (verbatim `jsonc`)

```jsonc
// Server capabilities
{
  "capabilities": {
    "resources": {},
    // Other capabilities...
    "extensions": {
      "io.modelcontextprotocol/skills": {
        "directoryRead": true,
      },
    },
  },
}
```

| Setting | Type | Default | Meaning (verbatim) |
| - | - | - | - |
| `directoryRead` | boolean | `false` | "The server implements [`resources/directory/read`](#reading-directories)." |

Constraint, verbatim: "A server declaring this extension therefore **MUST** also
declare the `resources` capability." "An empty object indicates support for the
extension with no optional features."

### 2.4 `Skill` and `SkillResource` field lists

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` — §Skill Entries (verbatim `typescript`)

```typescript
/**
 * A file belonging to a skill, with the digest and size of its content.
 */
interface SkillResource {
  /** Resource URI of the file. */
  uri: string;

  /**
   * SHA-256 digest of the file's raw bytes, formatted as `sha256:{hex}`
   * where {hex} is 64 lowercase hexadecimal characters.
   */
  digest: string;

  /**
   * Length in bytes of the file's raw content (the same bytes that `digest` covers).
   */
  size: number;
}

/**
 * The entry for a single skill.
 */
interface Skill {
  /** Resource URI of the skill's SKILL.md, readable via resources/read. */
  uri: string;

  /**
   * The skill's SKILL.md YAML frontmatter, rendered verbatim as a JSON object.
   * `name` and `description` are always present; every other field the author
   * wrote passes through unchanged.
   */
  frontmatter: {
    name: string;
    description: string;
    [key: string]: unknown;
  };

  /**
   * The skill's files: a complete enumeration of SKILL.md and every supporting
   * file, or the string "dynamic" when the skill's content is generated such
   * that stable digests cannot be published.
   */
  resources: SkillResource[] | "dynamic";
}
```

`SkillResource` fields, three in total: `uri` (string), `digest` (string),
`size` (number). `Skill` fields, three in total: `uri` (string), `frontmatter`
(object, `name` and `description` required, every other key passthrough),
`resources` (`SkillResource[] | "dynamic"`).

Result-field required flags, from SEP-2640 §Enumeration via `skills/list`
(Source: `https://modelcontextprotocol.io/seps/2640-skills-extension`):

| Field | Required | Description (verbatim) |
| - | - | - |
| `skills` | Yes | Array of skill entries. |
| `skills[].frontmatter` | Yes | Verbatim copy of the skill's `SKILL.md` YAML frontmatter, rendered as JSON. |
| `skills[].uri` | Yes | Resource URI of the skill's `SKILL.md`. |
| `skills[].resources` | Yes | The skill's files: an array enumerating them with digests and sizes, or the string `"dynamic"`. |
| `skills[].resources[].uri` | Yes | Resource URI of the file. |
| `skills[].resources[].digest` | Yes | SHA-256 digest of the file. |
| `skills[].resources[].size` | Yes | Length in bytes of the file's raw content. |

### 2.5 Request / result types

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` (verbatim `typescript`)

| Type | Declaration | Required literal fields |
| - | - | - |
| `ListSkillsRequest` | `extends PaginatedRequest` | `method: "skills/list"` |
| `ListSkillsResult` | `extends PaginatedResult, CacheableResult` | `skills: Skill[]`; `resultType` MUST be `"complete"`; `ttlMs` and `cacheScope` are **REQUIRED** |
| `GetSkillRequest` | `extends Request` | `method: "skills/get"`; `params: { uri: string }` |
| `GetSkillResult` | `extends CacheableResult` | `skill: Skill`; `resultType` MUST be `"complete"`; `ttlMs` and `cacheScope` are **REQUIRED** |
| `ReadResourceDirectoryRequest` | `extends PaginatedRequest` | `method: "resources/directory/read"`; `params: { uri: string; cursor?: Cursor }` |
| `ReadResourceDirectoryResult` | `extends PaginatedResult` | `resources: Resource[]`; `resultType` MUST be `"complete"` |

Error code, verbatim: "the server **MUST** return error `-32602` (Invalid
params), the same code `resources/read` uses for unknown resources."
`resources/directory/read` returns `-32602` "If the URI does not exist, or exists
but is not a directory resource".

Every request "**MUST** include the required [request
metadata](https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta)."

### 2.6 `skill://` URI rules

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` — §Resource Mapping, §Nested Skills, §Directory Resources

| Rule | Requirement level | Statement |
| - | - | - |
| Form | — | `skill://<skill-path>/<file-path>` |
| Scheme is privileged | Servers **SHOULD** use the `skill://` URI scheme | "Schemes other than `skill://` … A server **MAY** serve skills under another scheme … No scheme is privileged." |
| `<skill-path>` | — | "a `/`-separated path of one or more segments"; "It **MAY** be a single segment (`git-workflow`) or nested to arbitrary depth (`acme/billing/refunds`)" |
| `<file-path>` | — | "the file's path relative to the skill directory root, using `/` as the separator" |
| Final segment of `<skill-path>` | **MUST** | "MUST equal the skill's `name` as declared in its `SKILL.md` frontmatter" |
| Final segment naming rules | **MUST** | "MUST satisfy the Agent Skills specification's naming rules" |
| First segment | **SHOULD** | "The first segment occupies the URI authority component and **SHOULD** be a valid `reg-name` per [RFC 3986]" |
| Other prefix segments | **SHOULD** | "Any other prefix segments **SHOULD** be valid URI path segments" |
| Authority resolution | **MUST NOT** | "clients **MUST NOT** attempt DNS or network resolution of it" |
| `SKILL.md` always explicit | — | "The resource for the skill's required `SKILL.md` is therefore always addressable as `skill://<skill-path>/SKILL.md`" |
| Skill root | — | "`skill://<skill-path>`, that is, the `SKILL.md` URI with the `/SKILL.md` suffix removed and no trailing slash" |
| Directory resources | — | "a resource whose `mimeType` is `inode/directory` … Directory URIs are written without a trailing slash" |
| Scheme-based skill detection | **MUST NOT** | "A host **MUST NOT** conclude that a resource is a skill merely because its URI carries a particular scheme." |
| Nested skill frontmatter | **MUST NOT** | "A nested `SKILL.md` read this way is ordinary markdown: hosts **MUST NOT** act on its frontmatter." |
| Nested skill activation | MUST | "requires fresh, explicit user consent" |

Verbatim example table (SEP-2640 §Examples, identical in the stable spec):

| Skill path | File | Resource URI |
| - | - | - |
| `git-workflow` | `SKILL.md` | `skill://git-workflow/SKILL.md` |
| `pdf-processing` | `references/FORMS.md` | `skill://pdf-processing/references/FORMS.md` |
| `pdf-processing` | `scripts/extract.py` | `skill://pdf-processing/scripts/extract.py` |
| `acme/billing/refunds` | `SKILL.md` | `skill://acme/billing/refunds/SKILL.md` |
| `acme/billing/refunds` | `examples/email.md` | `skill://acme/billing/refunds/examples/email.md` |

Resource metadata for `skill://<skill-path>/SKILL.md`: `mimeType` **SHOULD** be
`text/markdown`; `name` **SHOULD** be set from the `name` frontmatter field;
`description` **SHOULD** be set from the `description` frontmatter field;
`_meta` keys **SHOULD** use the `io.modelcontextprotocol.skills/`
reverse-domain prefix.

Identity rule, verbatim: "The identity of an MCP-served skill is therefore the
pair of the host's identity for the originating server and the skill's `uri`."
… "Hosts **MUST NOT** key any of these on the `uri` alone."

### 2.7 Digest format

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` — §Integrity and Verification

| Item | Value |
| - | - |
| Format string | `sha256:{hex}` |
| `{hex}` | "64 lowercase hexadecimal characters" |
| Input | "SHA-256 hashes of a file's raw bytes" |
| Trust property | "Digests are unsigned and supplied by the same server that supplies the content. … Hosts **MUST NOT** treat a digest match as a security boundary." |

### 2.8 Numeric limits

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` — §Limits (verbatim table)

| Limit | Value | Counted over |
| - | - | - |
| Resources per skill | 512 entries | The entries of the skill's `resources`, `SKILL.md` included |
| Total file size per skill | 16 MiB (16,777,216 bytes) | The sum of `size` over the skill's `resources` |

"Hosts **MUST** support skills up to and including these limits, and **MAY**
support larger ones." / "Servers **SHOULD NOT** serve a skill that exceeds either
limit." No limit is placed on the number of skills a server may serve or a host
must accept.

### 2.9 Reserved-key and result constraints

Source: `https://raw.githubusercontent.com/modelcontextprotocol/ext-skills/main/specification/stable/skills.mdx` — §Reserved (final section), §Frontmatter, §Resources

| Constraint | Level | Statement |
| - | - | - |
| `metadata` key prefix reserved | — | "keys prefixed with `io.modelcontextprotocol/` are reserved for metadata defined by MCP extensions. This extension currently defines no such keys." |
| Unknown reserved-prefix keys | SHOULD | "Implementations **SHOULD** ignore keys under this prefix that they do not recognize." |
| `frontmatter` fidelity | **MUST** | "The `frontmatter` object **MUST** be identical in content to the frontmatter of the `SKILL.md` it describes." |
| `resources` required | **MUST** | "`resources` is **REQUIRED** on every skill entry" |
| `resources` completeness | **MUST** | "it lists every file of the skill, each exactly once, including an entry whose `uri` equals the skill's top-level `uri`" |
| Invalid `resources` value | **MUST NOT** | "An entry with no `resources` at all, or with any value other than an array or `"dynamic"`, is invalid, and hosts **MUST NOT** load it." |
| Digest/size verification on read | **MUST** | "it **MUST** verify the content against that entry's `digest` and `size`." |
| Frontmatter re-verification | **MUST** | "hosts **MUST** parse its YAML frontmatter and compare it field-by-field against the entry's `frontmatter`." |
| Lazy retrieval | **MUST NOT** | "Hosts **MUST NOT** retrieve a skill's files ahead of need" |

## 3. AGENTS.md

### 3.1 File locations

Source: `https://agents.md/` — §"How to use AGENTS.md?" and §FAQ

| Location | Level | Statement |
| - | - | - |
| `AGENTS.md` at the root of the repository | Directive | "Create an AGENTS.md file at the root of the repository." |
| `AGENTS.md` inside each package (monorepo) | Directive | "Large monorepo? Use nested AGENTS.md files for subprojects … Place another AGENTS.md inside each package." |
| Alternative filename `AGENT.md` (singular) | Convention, via symlink | "Rename existing files to AGENTS.md and create symbolic links for backward compatibility: `mv AGENT.md AGENTS.md && ln -s AGENTS.md AGENT.md`" |
| Aider config `read: AGENTS.md` in `.aider.conf.yml` | Per-tool configuration | §FAQ "How do I configure Aider?" |
| Gemini CLI `{ "context": { "fileName": "AGENTS.md" } }` in `.gemini/settings.json` | Per-tool configuration | §FAQ "How do I configure Gemini CLI?" |

No other filename, path, or discovery order is specified by agents.md.

### 3.2 Nesting and merge rules

Source: `https://agents.md/` — §"4. Large monorepo?" and §FAQ "What if
instructions conflict?"

| Rule | Level | Verbatim statement |
| - | - | - |
| Nearest-file selection | Descriptive | "Agents automatically read the nearest file in the directory tree, so the closest one takes precedence and every subproject can ship tailored instructions." |
| Conflict resolution | FAQ answer | "The closest AGENTS.md to the edited file wins; explicit user chat prompts override everything." |
| Loading of nested files | Descriptive | "Agents automatically read the nearest file in the directory tree" |
| Merge vs. replace | NOT ESTABLISHED IN SOURCE | No source states whether parent and child content are concatenated, deduplicated, or whether the child wholly replaces the parent. "the closest one takes precedence" is the only statement. |
| Traversal root | NOT ESTABLISHED IN SOURCE | No source states whether a root `AGENTS.md` is read in addition to a nested one. |

### 3.3 Convention vs. specification

Source: `https://agents.md/`,
`https://raw.githubusercontent.com/agentsmd/agents.md/main/README.md`,
`https://raw.githubusercontent.com/agentsmd/agents.md/main/Technical_Charter.pdf`

| Aspect | Finding |
| - | - |
| Machine-readable schema (JSON Schema, protobuf, `.proto`) | Does not exist. The `https://github.com/agentsmd/agents.md/tree/main` root contains only `README.md`, `Technical_Charter.pdf`, `LICENSE`, `AGENTS.md`, and a Next.js site (`components/`, `pages/`, `public/`, `styles/`, `next.config.ts`, `package.json`). |
| Normative language (RFC 2119 MUST/SHOULD/MAY) | Not used anywhere on `https://agents.md/`. |
| Required fields | "No. AGENTS.md is just standard Markdown. Use any headings you like; the agent simply parses the text you provide." |
| File format | "AGENTS.md is just standard Markdown." |
| Headings / sections | Recommendations only, presented as "Popular choices: Project overview / Build and test commands / Code style guidelines / Testing instructions / Security considerations". Not a required section list. |
| Section separator style in examples | `##` (ATX) in all shipped examples. No statement that other forms are invalid. |
| Governing document | The `Technical_Charter.pdf` (adopted December 8, 2025) is a governance document — TSC structure, voting, IP policy. It contains no format, field, or parsing requirements. |
| Steward | "AGENTS.md is now stewarded by the [Agentic AI Foundation](https://aaif.io) under the Linux Foundation." |

Everything in this section is **convention**, not specification. The only two
behavioural rules stated anywhere — nearest-file precedence and user-prompt
override — appear in the FAQ as prose answers, not as normative clauses.

## 4. OpenTelemetry GenAI and MCP semantic conventions

### 4.1 Document status

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/README.md`

| Document | Status |
| - | - |
| `docs/gen-ai/README.md` — Semantic conventions for generative AI systems | `Development` |
| `docs/gen-ai/gen-ai-spans.md` — Semantic conventions for generative client AI spans | `Development` |
| `docs/gen-ai/gen-ai-agent-spans.md` | `Development` |
| `docs/gen-ai/gen-ai-metrics.md` | `Development` |
| `docs/gen-ai/gen-ai-token-metrics.md` | `Development` |
| `docs/gen-ai/gen-ai-events.md` | `Development` |
| `docs/gen-ai/mcp.md` | `Development` |

Referenced dependency versions: `open-telemetry/semantic-conventions` `v1.44.0`;
`open-telemetry/opentelemetry-specification` `v1.55.0` (metrics advisory) and
`v1.56.0` (span-name guidelines).

### 4.2 `mcp.*` attributes

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md` — §Client / §Server attribute tables, §Metrics

| Key | Value Type | Stability | Requirement level (as stated) | Definition |
| - | - | - | - | - |
| `mcp.method.name` | string | Development | `Required` on mcp.client span, mcp.server span, `mcp.client.operation.duration`, `mcp.server.operation.duration` | "The name of the request or notification method." |
| `mcp.protocol.version` | string | Development | `Recommended` | "The [version](https://modelcontextprotocol.io/specification/versioning) of the Model Context Protocol used." |
| `mcp.session.id` | string | Development | `Recommended` on spans; `Opt-In` on the two operation-duration metrics | "Identifies [MCP session](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#session-management)." |
| `mcp.resource.uri` | string | Development | `Conditionally Required` on spans ("When the client executes a request type that includes a resource URI parameter."); `Opt-In` on metrics | "The value of the resource uri." Scope limited to `resources/read`, `resources/subscribe`, `resources/unsubscribe`, `notifications/resources/updated`. |

The `mcp.*` attribute set is exactly these four. No `mcp.*` attribute is Stable
or Release Candidate.

### 4.3 `jsonrpc.*` attributes used by MCP spans

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md` (attribute rows; the registry page lives in the base `semantic-conventions` repository, not this one)

| Key | Value Type | Stability | Requirement level | Definition |
| - | - | - | - | - |
| `jsonrpc.request.id` | string | Development | `Conditionally Required` "When the client executes a request." (spans only; not on the duration metrics) | "A string representation of the `id` property of the request and its corresponding response." |
| `jsonrpc.protocol.version` | string | Development | `Recommended` "When it's not `2.0`." | "Protocol version, as specified in the `jsonrpc` property of the request and its corresponding response." |

### 4.4 `gen_ai.*` attributes

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-spans.md` (§Inference attribute table),
`gen-ai-agent-spans.md` (§Create agent span, §Invoke agent client span),
`gen-ai-metrics.md` (§`gen_ai.execute_tool.duration`,
§`gen_ai.invoke_workflow.duration`), `gen-ai-token-metrics.md`

**Every `gen_ai.*` attribute below is `Development`. None is Stable or Release
Candidate.**

| Key | Value Type | First-seen in | Example values (verbatim) |
| - | - | - | - |
| `gen_ai.operation.name` | string | gen-ai-spans.md | `chat`; `generate_content`; `text_completion` |
| `gen_ai.provider.name` | string | gen-ai-spans.md | `openai`; `gcp.gen_ai`; `gcp.vertex_ai` |
| `gen_ai.conversation.id` | string | gen-ai-spans.md | `conv_5j66UpCpwteGg4YSxUnt7lPY` |
| `gen_ai.conversation.compacted` | boolean | gen-ai-spans.md | `true` |
| `gen_ai.output.type` | string | gen-ai-spans.md | `text`; `json`; `image` |
| `gen_ai.prompt.name` | string | gen-ai-spans.md | `analyze-code` |
| `gen_ai.prompt.version` | string | gen-ai-spans.md | `1.0.0`; `2025-05-01`; `prod`; `v2` |
| `gen_ai.prompt.variable` | string | gen-ai-spans.md | `Alice`; `French` |
| `gen_ai.request.choice.count` | int | gen-ai-spans.md | `3` |
| `gen_ai.request.frequency_penalty` | double | gen-ai-spans.md | `0.1` |
| `gen_ai.request.max_tokens` | int | gen-ai-spans.md | `100` |
| `gen_ai.request.model` | string | gen-ai-spans.md | `gpt-4` |
| `gen_ai.request.presence_penalty` | double | gen-ai-spans.md | `0.1` |
| `gen_ai.request.previous_response.id` | string | gen-ai-spans.md | `resp_0123456789aBCdef`; `interaction-123` |
| `gen_ai.request.reasoning.level` | string | gen-ai-spans.md | `low`; `medium`; `high` |
| `gen_ai.request.seed` | int | gen-ai-spans.md | `100` |
| `gen_ai.request.stop_sequences` | string[] | gen-ai-spans.md | `["forest", "lived"]` |
| `gen_ai.request.stream` | boolean | gen-ai-spans.md | (no example) |
| `gen_ai.request.temperature` | double | gen-ai-spans.md | `0.0` |
| `gen_ai.request.top_k` | int | gen-ai-spans.md | `40` |
| `gen_ai.request.top_p` | double | gen-ai-spans.md | `1.0` |
| `gen_ai.response.finish_reasons` | string[] | gen-ai-spans.md | `["stop"]`; `["stop", "length"]`; `["stop", "length", "error"]` |
| `gen_ai.response.id` | string | gen-ai-spans.md | `chatcmpl-123` |
| `gen_ai.response.model` | string | gen-ai-spans.md | `gpt-4-0613` |
| `gen_ai.response.time_to_first_chunk` | double | gen-ai-spans.md | `0.5`; `1.2` |
| `gen_ai.input.messages` | any | gen-ai-spans.md | JSON object per `/model/gen-ai/gen-ai-input-messages.json` |
| `gen_ai.output.messages` | any | gen-ai-spans.md | JSON object per `/model/gen-ai/gen-ai-output-messages.json` |
| `gen_ai.system_instructions` | any | gen-ai-spans.md | JSON object per `/model/gen-ai/gen-ai-system-instructions.json` |
| `gen_ai.tool.definitions` | any | gen-ai-spans.md | JSON object |
| `gen_ai.tool.name` | string | mcp.md, gen-ai-metrics.md | `Flights` |
| `gen_ai.tool.type` | string | gen-ai-metrics.md | `function`; `extension`; `datastore` |
| `gen_ai.tool.call.arguments` | any | mcp.md | JSON object per `/model/gen-ai/gen-ai-tool-call-arguments.json` |
| `gen_ai.tool.call.result` | any | mcp.md | JSON object per `/model/gen-ai/gen-ai-tool-call-result.json` |
| `gen_ai.agent.id` | string | gen-ai-agent-spans.md | `asst_5j66UpCpwteGg4YSxUnt7lPY`; `arn:aws:bedrock:us-east-1:123:agent/42`; `urn:agent:projects-123:projects:123:locations:us-east1:aiplatform:reasoningEngines:456` |
| `gen_ai.agent.name` | string | gen-ai-agent-spans.md | `Math Tutor`; `Fiction Writer` |
| `gen_ai.agent.description` | string | gen-ai-agent-spans.md | `Helps with math problems`; `Generates fiction stories` |
| `gen_ai.agent.version` | string | gen-ai-agent-spans.md | `1.0.0`; `2025-05-01` |
| `gen_ai.workflow.name` | string | gen-ai-metrics.md | `multi_agent_rag`; `customer_support_pipeline` |
| `gen_ai.data_source.id` | string | gen-ai-agent-spans.md | `H7STPQYOND` |
| `gen_ai.token.modality` | string | gen-ai-token-metrics.md | `text`; `image`; `audio` |
| `gen_ai.usage.input_tokens` | int | gen-ai-spans.md | `100` |
| `gen_ai.usage.output_tokens` | int | gen-ai-spans.md | `180` |
| `gen_ai.usage.cache_read.input_tokens` | int | gen-ai-spans.md | `50` |
| `gen_ai.usage.cache_write.input_tokens` | int | gen-ai-spans.md | `25` |
| `gen_ai.usage.reasoning.output_tokens` | int | gen-ai-spans.md | `50` |
| `gen_ai.usage.audio.input_tokens` | int | gen-ai-spans.md | `120` |
| `gen_ai.usage.audio.output_tokens` | int | gen-ai-spans.md | `240` |
| `gen_ai.usage.audio.cache_read.input_tokens` | int | gen-ai-spans.md | `60` |
| `gen_ai.usage.text.input_tokens` | int | gen-ai-spans.md | `100` |
| `gen_ai.usage.text.output_tokens` | int | gen-ai-spans.md | `180` |
| `gen_ai.usage.text.cache_read.input_tokens` | int | gen-ai-spans.md | `40` |
| `gen_ai.usage.image.input_tokens` | int | gen-ai-spans.md | `258` |
| `gen_ai.usage.image.output_tokens` | int | gen-ai-spans.md | `1290` |
| `gen_ai.usage.image.cache_read.input_tokens` | int | gen-ai-spans.md | `128` |

Fifty-four attribute rows are enumerated above. The source's own summary text
states "all 57 listed in 4.4"; the fetched table carries 54 rows and no three
missing names are named in the source, so the count is left as the rows
actually present. The four the contract names explicitly:
`gen_ai.request.model` (string, example `gpt-4`), `gen_ai.response.model`
(string, example `gpt-4-0613`), `gen_ai.usage.input_tokens` (int, example
`100`), `gen_ai.operation.name` (string, examples `chat`,
`generate_content`, `text_completion`).

`gen_ai.usage.*` containment rules, verbatim: each modality/counter "SHOULD be
included in" its parent aggregate. Worked example: 100 text tokens (40 cached) +
200 image tokens gives `gen_ai.usage.input_tokens`: 300,
`gen_ai.usage.cache_read.input_tokens`: 40,
`gen_ai.usage.text.input_tokens`: 100,
`gen_ai.usage.text.cache_read.input_tokens`: 40,
`gen_ai.usage.image.input_tokens`: 200.

`gen_ai.request.top_k` constraint, verbatim: "OpenAI's `top_logprobs` … **MUST
NOT** be reported as `gen_ai.request.top_k`."

### 4.5 Non-`gen_ai`, non-`mcp` attributes referenced

Source: attribute rows in `mcp.md`, `gen-ai-spans.md`, `gen-ai-metrics.md` (the
links point at `open-telemetry/semantic-conventions` `v1.44.0`)

| Key | Value Type | Stability | Requirement level as used |
| - | - | - | - |
| `error.type` | string | **Stable** | `Conditionally Required` "If and only if the operation fails." |
| `rpc.response.status_code` | string | **Release Candidate** | `Conditionally Required` "If response contains an error code." |
| `network.protocol.name` | string | **Stable** | `Recommended` "When applicable." |
| `network.protocol.version` | string | **Stable** | `Recommended` "When applicable." |
| `network.transport` | string | **Stable** | `Recommended` |
| `server.address` | string | **Stable** | `Recommended` "If applicable." |
| `server.port` | int | **Stable** | `Recommended` "When `server.address` is set." |
| `client.address` | string | **Stable** | `Recommended` "If applicable." (mcp.server span only) |
| `client.port` | int | **Stable** | `Recommended` "When `client.address` is set." (mcp.server span only) |

`network.transport` enum, all **Stable**: `pipe`, `quic`, `tcp`, `udp`, `unix`.
`error.type` well-known value, **Stable**: `_OTHER`. Transport mapping rule,
verbatim: "This attribute SHOULD be set to `tcp` or `quic` if the transport
protocol is HTTP. It SHOULD be set to `pipe` if the transport is stdio."

### 4.6 `mcp.method.name` enum values

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md` — §Client (first enum block) / §Server / §Metrics; all four blocks are identical. Twenty-five values, all `Development`.

| Value | Description (verbatim) | Stability |
| - | - | - |
| `completion/complete` | Request to complete a prompt. | Development |
| `elicitation/create` | Request from the server to elicit additional information from the user via the client | Development |
| `initialize` | Request to initialize the MCP client. | Development |
| `logging/setLevel` | Request to set the logging level. | Development |
| `notifications/cancelled` | Notification cancelling a previously-issued request. | Development |
| `notifications/initialized` | Notification indicating that the MCP client has been initialized. | Development |
| `notifications/message` | Notification indicating that a message has been received. | Development |
| `notifications/progress` | Notification indicating the progress for a long-running operation. | Development |
| `notifications/prompts/list_changed` | Notification indicating that the list of prompts has changed. | Development |
| `notifications/resources/list_changed` | Notification indicating that the list of resources has changed. | Development |
| `notifications/resources/updated` | Notification indicating that a resource has been updated. | Development |
| `notifications/roots/list_changed` | Notification indicating that the list of roots has changed. | Development |
| `notifications/tools/list_changed` | Notification indicating that the list of tools has changed. | Development |
| `ping` | Request to check that the other party is still alive. | Development |
| `prompts/get` | Request to get a prompt. | Development |
| `prompts/list` | Request to list prompts available on server. | Development |
| `resources/list` | Request to list resources available on server. | Development |
| `resources/read` | Request to read a resource. | Development |
| `resources/subscribe` | Request to subscribe to a resource. | Development |
| `resources/templates/list` | Request to list resource templates available on server. | Development |
| `resources/unsubscribe` | Request to unsubscribe from resource updates. | Development |
| `roots/list` | Request to list roots available on server. | Development |
| `sampling/createMessage` | Request to create a sampling message. | Development |
| `tools/call` | Request to call a tool. | Development |
| `tools/list` | Request to list tools available on server. | Development |

Enum-fallback rule, verbatim: "If one of them applies, then the respective value
**MUST** be used; otherwise, a custom value **MAY** be used."

#### GAP — extension methods absent from the enum

`skills/list`, `skills/get` and `resources/directory/read` — the three methods
defined by `io.modelcontextprotocol/skills` — do **not** appear in any of the
four `mcp.method.name` enum blocks in `mcp.md`. `server/discover`,
`prompts/list` extensions and `tasks/*` methods are also absent. There is no
statement in the source explaining the omission. The fallback rule above
governs these: a custom value **MAY** be used.

### 4.7 `gen_ai.operation.name` enum values

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-metrics.md` (the fullest of the six
copies). All values `Development`.

| Value | Description (verbatim) |
| - | - |
| `chat` | Chat completion operation such as OpenAI Chat API |
| `create_agent` | Create GenAI agent |
| `create_memory` | Create new memory records |
| `create_memory_store` | Create or initialize a memory store |
| `delete_memory` | Delete memory records |
| `delete_memory_store` | Delete or deprovision a memory store |
| `embeddings` | Embeddings operation such as OpenAI Create embeddings API |
| `execute_tool` | Execute a tool |
| `fetch_response` | Fetch a previously generated model response by its identifier, without performing inference, such as OpenAI Get a model response |
| `generate_content` | Multimodal content generation operation such as Gemini Generate Content |
| `invoke_agent` | Invoke GenAI agent |
| `invoke_workflow` | Invoke GenAI workflow |
| `plan` | Agent planning or task decomposition phase |
| `retrieval` | Retrieval operation such as OpenAI Search Vector Store API |
| `search_memory` | Search/query memories from a memory store |
| `text_completion` | Text completions operation such as OpenAI Completions API (Legacy) |
| `update_memory` | Update existing memory records |
| `upsert_memory` | Create or update memory records without the caller choosing which |

Eighteen rows are enumerated above. The source block is headed as holding
nineteen values; `[INFERENCE]` one value is not reproduced by the fetched text,
and no substitute is invented here.

`gen_ai.operation.name` carries a footnote on the `fetch_response` value:
"Instrumentations **SHOULD NOT** report token usage (as attributes or metrics)
for this operation."

#### INCONSISTENT ENUM — `gen_ai.operation.name` across files

The `mcp.md` copy of this enum has 15 values; `gen-ai-metrics.md`,
`gen-ai-token-metrics.md` and `gen-ai-agent-spans.md` have 19. The
`gen-ai-spans.md` copy also has 15. The three values present in the
metrics/agent documents but absent from `mcp.md` and `gen-ai-spans.md` are
`text_completion`, `update_memory` and `upsert_memory`.

| Value | in `mcp.md` | in `gen-ai-spans.md` | in `gen-ai-metrics.md` / `-agent-spans.md` / `-token-metrics.md` |
| - | - | - | - |
| `text_completion` | absent | present | present |
| `update_memory` | absent | present | present |
| `upsert_memory` | absent | present | present |
| `generate_content` | present | present | present |
| All other 15 values | present | present | present |

### 4.8 `gen_ai.provider.name` enum values

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-metrics.md`. Sixteen values, all `Development`.

| Value | Description / note (verbatim) |
| - | - |
| `anthropic` | Anthropic |
| `aws.bedrock` | AWS Bedrock |
| `azure.ai.inference` | Azure AI Inference |
| `azure.ai.openai` | Azure OpenAI |
| `cohere` | Cohere |
| `deepseek` | DeepSeek |
| `gcp.gemini` | Gemini — "Used when accessing the 'generativelanguage.googleapis.com' endpoint. Also known as the AI Studio API." |
| `gcp.gen_ai` | Any Google generative AI endpoint — "May be used when specific backend is unknown." |
| `gcp.vertex_ai` | Vertex AI — "Used when accessing the 'aiplatform.googleapis.com' endpoint." |
| `groq` | Groq |
| `ibm.watsonx.ai` | IBM Watsonx AI |
| `mistral_ai` | Mistral AI |
| `moonshot_ai` | Moonshot AI |
| `openai` | OpenAI |
| `perplexity` | Perplexity |
| `x_ai` | xAI |

### 4.9 `gen_ai.token.modality` enum values

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-token-metrics.md`. Four values, all `Development`.

| Value | Description (verbatim) | Stability |
| - | - | - |
| `audio` | Audio tokens. | Development |
| `image` | Image tokens. | Development |
| `text` | Text tokens. | Development |
| `unknown` | The modality is not known. | Development |

Rule, verbatim: "When the provider does not break usage down by modality and
the modality cannot be reliably determined, instrumentations **SHOULD** report
the tokens under the `unknown` modality."

### 4.10 Span names

Source: per row. All spans carry **Status: Development** and **Requirement
level: Recommended**.

| Span | Source file | Span name (verbatim) | Span kind (verbatim) |
| - | - | - | - |
| mcp client | `mcp.md` §Client | "**SHOULD** follow the format `{mcp.method.name} {target}` where target SHOULD match `{gen_ai.tool.name}` or `{gen_ai.prompt.name}` when applicable. If there is no low-cardinality `target` available, the Span name SHOULD be `{mcp.method.name}`." | `CLIENT` |
| mcp server | `mcp.md` §Server | identical to the client format | `SERVER` |
| GenAI inference | `gen-ai-spans.md` §Inference | "`{gen_ai.operation.name} {gen_ai.request.model}`" | "`CLIENT` and MAY be set to `INTERNAL` on spans representing call to models running in the same process" |
| GenAI embeddings | `gen-ai-spans.md` | "`{gen_ai.operation.name} {gen_ai.request.model}`" | `CLIENT` |
| GenAI retrieval | `gen-ai-spans.md` | "`{gen_ai.operation.name} {gen_ai.data_source.id}`" | `CLIENT` |
| GenAI fetch response | `gen-ai-spans.md` | "`{gen_ai.operation.name}`. The response identifier is high cardinality, so it is not included in the span name." | — |
| GenAI memory | `gen-ai-spans.md` | "`{gen_ai.operation.name}`" | — |
| GenAI execute tool | `gen-ai-spans.md` | "`execute_tool {gen_ai.tool.name}`" | `INTERNAL` |
| GenAI create agent | `gen-ai-agent-spans.md` | "`create_agent {gen_ai.agent.name}`" | `CLIENT` |
| GenAI invoke agent (client) | `gen-ai-agent-spans.md` | "`invoke_agent {gen_ai.agent.name}` if `gen_ai.agent.name` is readily available. When `gen_ai.agent.name` is not available, it SHOULD be `invoke_agent`." | `CLIENT` |
| GenAI invoke agent (internal) | `gen-ai-agent-spans.md` | identical to the client form | `INTERNAL` |
| GenAI invoke workflow | `gen-ai-agent-spans.md` | "`invoke_workflow {gen_ai.workflow.name}`" | `INTERNAL` |
| GenAI plan | `gen-ai-agent-spans.md` | "`plan {gen_ai.agent.name}` if `gen_ai.agent.name` is readily available. When `gen_ai.agent.name` is not available, it SHOULD be `plan`." | `INTERNAL` |

Cardinality rule, verbatim (`mcp.md`): "Instrumentation MAY allow users to opt
into including `{mcp.resource.uri}` as `target` in the span name when it is
available but SHOULD NOT include it by default to avoid high cardinality span
names."

### 4.11 `mcp.*` metric names and instrument types

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md` — §Metrics. All **Histogram**, unit `s` (UCUM), all **Development**, all **Requirement level: Recommended**.

| Name | Instrument Type | Unit (UCUM) | Description (verbatim) | ExplicitBucketBoundaries |
| - | - | - | - | - |
| `mcp.client.operation.duration` | Histogram | `s` | The duration of the MCP request or notification as observed on the sender from the time it was sent until the response or ack is received. | `[ 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60, 120, 300 ]` |
| `mcp.server.operation.duration` | Histogram | `s` | MCP request or notification duration as observed on the receiver from the time it was received until the result or ack is sent. | `[ 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60, 120, 300 ]` |
| `mcp.client.session.duration` | Histogram | `s` | The duration of the MCP session as observed on the MCP client. | `[ 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60, 120, 300 ]` |
| `mcp.server.session.duration` | Histogram | `s` | The duration of the MCP session as observed on the MCP server. | `[ 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60, 120, 300 ]` |

Exactly four `mcp.*` metrics, all Histogram.

### 4.12 `gen_ai.*` metric names and instrument types

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-metrics.md`
and `gen-ai-token-metrics.md`. All **Development**, all **Requirement level:
Recommended**.

| Name | Instrument Type | Unit (UCUM) | ExplicitBucketBoundaries |
| - | - | - | - |
| `gen_ai.client.operation.duration` | Histogram | `s` | `[0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12, 10.24, 20.48, 40.96, 81.92]` |
| `gen_ai.client.operation.time_to_first_chunk` | Histogram | `s` | `[0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12, 10.24, 20.48, 40.96, 81.92]` |
| `gen_ai.client.operation.time_per_output_chunk` | Histogram | `s` | `[0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12, 10.24, 20.48, 40.96, 81.92]` |
| `gen_ai.server.request.duration` | Histogram | `s` | `[0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12, 10.24, 20.48, 40.96, 81.92]` |
| `gen_ai.server.time_per_output_token` | Histogram | `s` | `[0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1.0, 2.5]` |
| `gen_ai.server.time_to_first_token` | Histogram | `s` | `[0.001, 0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]` |
| `gen_ai.invoke_workflow.duration` | Histogram | `s` | `[1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600, 7200]` |
| `gen_ai.invoke_agent.duration` | Histogram | `s` | `[0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 12.8, 25.6, 51.2, 102.4, 204.8, 409.6]` |
| `gen_ai.invoke_agent.inference_calls` | Histogram | `{inference_call}` | `[1, 2, 4, 8, 16, 32, 64, 128]` |
| `gen_ai.invoke_agent.tool_calls` | Histogram | `{tool_call}` | `[1, 2, 4, 8, 16, 32, 64, 128]` |
| `gen_ai.execute_tool.duration` | Histogram | `s` | `[0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12, 10.24, 20.48, 40.96, 81.92]` |
| `gen_ai.client.inference.usage.input_tokens` | Counter | `{token}` | NOT ESTABLISHED IN SOURCE (counters take no ExplicitBucketBoundaries) |
| `gen_ai.client.inference.usage.output_tokens` | Counter | `{token}` | NOT ESTABLISHED IN SOURCE |
| `gen_ai.client.inference.usage.cache_read.input_tokens` | Counter | `{token}` | NOT ESTABLISHED IN SOURCE |
| `gen_ai.client.inference.usage.cache_write.input_tokens` | Counter | `{token}` | NOT ESTABLISHED IN SOURCE |
| `gen_ai.client.inference.usage.reasoning.output_tokens` | Counter | `{token}` | NOT ESTABLISHED IN SOURCE |
| `gen_ai.client.inference.operation.input_tokens` | Histogram | `{token}` | NOT ESTABLISHED IN SOURCE |
| `gen_ai.client.inference.operation.output_tokens` | Histogram | `{token}` | NOT ESTABLISHED IN SOURCE |

Eighteen rows: nine `s`-unit Histograms, two call-count Histograms, five
`{token}` Counters, two `{token}` Histograms. The source's prose describes this
set as "10 client/server/workflow/agent/tool metrics" plus "5 `{token}` counters
and 2 `{token}` histograms"; the fetched table carries 18 rows, and every one
of them is written out above.

Histogram-advice rule for the token histograms, verbatim: "The
`gen_ai.client.inference.operation.input_tokens` and
`gen_ai.client.inference.operation.output_tokens` histograms are deliberately not
broken down by modality: percentiles across modalities do not add up."

Billing rule, verbatim: "When systems report both used tokens and billable
tokens, instrumentation **MUST** report billable tokens."

### 4.13 Event names

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-events.md`

| Event name | Status | Requirement level | Note (verbatim) |
| - | - | - | - |
| `gen_ai.client.inference.operation.details` | Development | Opt-In | "The event name **MUST** be `gen_ai.client.inference.operation.details`." |
| `gen_ai.evaluation.result` | Development | NOT ESTABLISHED IN SOURCE | Declared in the table of contents; the attribute table for it was not in the fetched page range. |

### 4.14 Stability summary

| Namespace | Stable | Release Candidate | Development |
| - | - | - | - |
| `mcp.*` | 0 | 0 | 4 (`mcp.method.name`, `mcp.protocol.version`, `mcp.session.id`, `mcp.resource.uri`) |
| `gen_ai.*` | 0 | 0 | all 54 listed in 4.4, plus the 3 enums |
| `jsonrpc.*` | 0 | 0 | 2 |
| Referenced core attributes | 9 (`error.type`, `network.protocol.name`, `network.protocol.version`, `network.transport`, `server.address`, `server.port`, `client.address`, `client.port`, and all 5 `network.transport` enum values) | 1 (`rpc.response.status_code`) | 0 |

**No `gen_ai.*` or `mcp.*` attribute, metric, span, or event in this
repository is Stable or Release Candidate.** Every document in
`docs/gen-ai/**` carries **Status: Development**.

## 5. OpenTelemetry trace context in MCP `_meta`

### 5.1 Reserved `_meta` key names

Source: `https://modelcontextprotocol.io/specification/2026-07-28/basic/index` — §General fields → `_meta` → §Reserved keys (verbatim table)

| Key | Description (verbatim) | Defined in |
| - | - | - |
| `progressToken` | Opts the request into progress notifications | Progress |
| `io.modelcontextprotocol/protocolVersion` | Protocol version for a request | Per-request protocol fields |
| `io.modelcontextprotocol/clientInfo` | Client name and version | Per-request protocol fields |
| `io.modelcontextprotocol/clientCapabilities` | Client capabilities relevant to a request | Per-request protocol fields |
| `io.modelcontextprotocol/logLevel` | Minimum log level the server should emit for a request | Logging |
| `io.modelcontextprotocol/subscriptionId` | Correlates a notification with its originating subscription | Subscriptions |
| `traceparent`, `tracestate`, `baggage` | OpenTelemetry trace context propagation | OpenTelemetry trace context |

Per-response protocol fields, same page:

| Key | Type | Required | Description (verbatim) |
| - | - | - | - |
| `io.modelcontextprotocol/serverInfo` | `Implementation` | No | Server name and version |

### 5.2 Mapping of the OTel keys to W3C header names

Source: `https://modelcontextprotocol.io/specification/2026-07-28/basic/index` — §OpenTelemetry trace context (verbatim)

"As an exception to the prefix requirement above, the keys `traceparent`,
`tracestate`, and `baggage` are reserved for [OpenTelemetry](https://opentelemetry.io/)
trace context propagation. When present, their values **MUST** follow [W3C Trace
Context](https://www.w3.org/TR/trace-context/) and [W3C
Baggage](https://www.w3.org/TR/baggage/) formats respectively."

| MCP `_meta` key | Must follow | W3C header name of the same name |
| - | - | - |
| `traceparent` | W3C Trace Context | `traceparent` |
| `tracestate` | W3C Trace Context | `tracestate` |
| `baggage` | W3C Baggage | `baggage` |

The mapping is identity — the `_meta` key name equals the W3C header name. No
prefix, transformation, or renaming occurs. The mapping is one-to-one with no
additional OTel keys.

### 5.3 Carrier location and grammar

Source: `https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/mcp.md` — §Context propagation (verbatim)

"Instrumentations SHOULD propagate context using the configured [OpenTelemetry
propagators](https://opentelemetry.io/docs/specs/otel/trace/api/#propagators) by
injecting it into the MCP request
[`params._meta`](https://modelcontextprotocol.io/specification/2025-11-25/basic#_meta)
property bag when creating a request or notification. The receiver extracts the
context from `params._meta` and uses it as the remote parent."

"Although the MCP convention expects keys in `params._meta` to be DNS-prefixed,
the context propagation keys SHOULD be written unprefixed. SEP-414 defines this
explicit handling for the W3C Trace Context and Baggage keys (`traceparent`,
`tracestate`, and `baggage`)."

The carrier is `params._meta` (per-request), **not** the HTTP header and **not**
the top-level `_meta` on the message envelope. Verbatim example from `mcp.md`:

```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "get-weather",
    "_meta": {
      "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      "tracestate": "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE"
    }
  },
  "id": 1,
}
```

The second example in the same section adds `"baggage": "userId=alice,serverNode=DF%2028,isProduction=false"`.

Parent-span rule, verbatim (`mcp.md`): "MCP server instrumentation SHOULD, by
default, use context extracted from MCP `params._meta` as a parent for MCP server
span and SHOULD link current ambient context, if it's present."

### 5.4 `_meta` key-name grammar (for validation)

Source: `https://modelcontextprotocol.io/specification/2026-07-28/basic/index` — §`_meta` → §Key name format

| Segment | Rule (verbatim) |
| - | - |
| Structure | "valid `_meta` key names have two segments: an optional **prefix**, and a **name**." |
| Prefix | "MUST be a series of labels separated by dots (`.`), followed by a slash (`/`)." |
| Prefix labels | "Labels MUST start with a letter and end with a letter or digit; interior characters can be letters, digits, or hyphens (`-`)." |
| Prefix notation | "Implementations SHOULD use reverse DNS notation (e.g., `com.example/` rather than `example.com/`)." |
| Reserved prefixes | "Any prefix where the second label is `modelcontextprotocol` or `mcp` is **reserved** for MCP use." Reserved examples: `io.modelcontextprotocol/`, `dev.mcp/`, `org.modelcontextprotocol.api/`, `com.mcp.tools/`. Not reserved: `com.example.mcp/` (second label is `example`). |
| Name | "Unless empty, MUST begin and end with an alphanumeric character (`[a-z0-9A-Z]`)." |
| Name interior | "MAY contain hyphens (`-`), underscores (`_`), dots (`.`), and alphanumerics in between." |

The OTel keys `traceparent`, `tracestate` and `baggage` are all lowercase
alphanumerics, so they satisfy the `name` grammar with an empty prefix.

### 5.5 Related SEP status

| SEP | Title | Status | Type | Relevance |
| - | - | - | - | - |
| SEP-414 | Document OpenTelemetry Trace Context Propagation Conventions | Final | Standards Track | "This specification documents an exception to the DNS prefixing convention for keys in `_meta`." Rationale names the anti-pattern it prevents: "namespacing traceparent like `io.modelcontextprotocol.traceparent`, which will break traces and log correlation." |
| SEP-2028 | (forwarding `_meta` values to HTTP headers) | referenced as `PR #2028` | — | "builds on this SEP for forwarding `_meta` values to HTTP headers" |
| SEP-1788 | reserved keys in `_meta` | referenced as `issue #1788` | — | "should be updated with `traceparent`, `tracestate`, and `baggage` when this SEP is implemented" — now reflected in the 2026-07-28 spec table in 5.1 |

## 6. Web Bot Auth

Primary source: `draft-ietf-webbotauth-httpsig-protocol-00` (T. Meunier,
Cloudflare; S. Major, Google; 1 September 2026; Expires 5 March 2027; Standards
Track). Text:
`https://www.ietf.org/archive/id/draft-ietf-webbotauth-httpsig-protocol-00.txt`.
Datatracker:
`https://datatracker.ietf.org/doc/draft-ietf-webbotauth-httpsig-protocol/`.

### 6.1 `Signature-Agent` header

Source: draft `-00` §5.2.1 (verbatim)

| Property | Value |
| - | - |
| Header field name | `Signature-Agent` |
| Structured-field type | "a Dictionary Structured Header as defined in Section 3.2 of [STRUCTURED-HEADERS]" |
| Member value type | "MUST be String Items that contain a [URI], whose scheme MUST be https" |
| Malformed handling | "If dictionary values are not valid URI-references, the entire header field MAY be ignored." |
| `type` parameter | "Each member carries a type parameter, a Token Item as defined in Section 3.3.4 of [STRUCTURED-HEADERS], naming the discovery mechanism that resolves the value to key material." |
| Default `type` | "When type is absent, its value is `directory`." |
| Unsupported `type` | "A verifier that does not support a type value MUST ignore that member, and MUST NOT infer the mechanism from the URI path, media type, or response body." |
| Presence | "A signed request MUST carry the Signature-Agent header" |
| Signing obligation | "Its member keyed to the signature label MUST be signed as a component as defined in Section 2.1 of [HTTP-MESSAGE-SIGNATURES]." |
| Legacy form | "Earlier versions of this protocol defined Signature-Agent as a bare String … A verifier MAY accept that form and treat it as a dictionary with a single member whose key is the label of the signature covering it. Signers MUST send the dictionary form." |
| Wire discrimination | "a String Item begins with a double quote `"` while a Dictionary member key does not" |

`type` values, §5.5 (verbatim):

| `type` | Value semantics (verbatim) |
| - | - |
| `directory` | "The member value MUST be the ASCII serialization of an origin as defined in Section 6.2 of [ORIGIN], and a verifier MUST ignore a member carrying anything else (an empty path / MAY be accepted though). Resolve the HTTP Message Signatures Directory at the well-known URI registered in Section 8.1, at that origin. This is the default when no type parameter is present." |
| `jwks_uri` | "Resolve the member value as a direct JWK Set URI." |
| `cimd` | "Resolve the member value as a Client ID Metadata Document [CIMD] URI. The document then provides key material through `jwks` or `jwks_uri`." |

Verbatim examples, §5.5:

```
Signature-Agent: sig1="https://signature-agent.test"
Signature-Agent: sig1="https://signature-agent.test/jwks.json";type=jwks_uri
Signature-Agent: sig1="https://signature-agent.test/card";type=cimd
```

### 6.2 JWKS discovery well-known path

Source: draft `-00` §8.1 (verbatim IANA table)

| URI Suffix | Change Controller | Reference | Status | Related information |
| - | - | - | - | - |
| `http-message-signatures-directory` | IETF | this document | permanent | None |

Source: draft `-00` §5.5.1 (verbatim request line)

```
GET /.well-known/http-message-signatures-directory HTTP/1.1
```

| Item | Value |
| - | - |
| Full path | `/.well-known/http-message-signatures-directory` |
| Registry entry (URI Suffix) | `http-message-signatures-directory` |
| Registry | "Well-Known URIs" |
| Status | `permanent` |
| Scheme | `https` — "The directory MUST be served over HTTPS." |
| Media type | `application/http-message-signatures-directory+json` — "A directory served at the well-known URI registered in Section 8.1 MUST be served with media type application/http-message-signatures-directory+json." |

### 6.3 `signature-input` and signature-label syntax

Source: draft `-00` §5.2, §5.2.1, §5.2.5

Covered components — requirement levels:

| Component / parameter | Level (verbatim) |
| - | - |
| `@authority` (§2.2.3 of HTTP-MESSAGE-SIGNATURES) | "Agents **MUST** include at least one of the following components" |
| `@target-uri` (§2.2.2) | same MUST-at-least-one set |
| `created` (§2.3) | "Agents **MUST** include the following @signature-params" |
| `expires` (§2.3) | MUST |
| `keyid` | MUST — "MUST be a base64url JWK SHA-256 Thumbprint as defined in Section 3.2 of [JWK-THUMBPRINT] for RSA and EC, and in Appendix A.3 of [JWK-OKP] for ed25519." |
| `tag` | MUST — "MUST be `web-bot-auth`" |
| `@method` (§2.2.1) | "Agents that want to narrow the scope of their signature **SHOULD** also cover" |
| `@path` (§2.2.6) | SHOULD |
| `@target-uri` (§2.2.2) | SHOULD (narrowing form) |
| `@query-param` (§2.2.8) | SHOULD |
| `Content-Digest` | "No component covers the body. An Agent that needs one MUST send and cover Content-Digest [DIGEST-FIELDS]. This document does not require it." |
| expiry bound | "It is RECOMMENDED that expiry be no more than 24 hours." |

Minimum signed component list, verbatim (§5.2.1):

```
("@authority" "signature-agent";key="sig1")
```

Verbatim full request example (§5.2.5):

```
GET /path/to/resource HTTP/1.1
Host: origin.example.com
Signature: sig=abc==
Signature-Input: sig=("@authority" "signature-agent";key="sig");\
                 created=1700000000;\
                 expires=1700011111;\
                 keyid="ba3e64==";\
                 tag="web-bot-auth"
Signature-Agent: sig="https://signer.example.com"
```

Header count, verbatim: "A signed request carries three headers / 1.
Signature … 2. Signature-Input … 3. Signature-Agent".

Label rules, source draft `-00` §5.2.2 (verbatim):

| Rule | Statement |
| - | - |
| Multiple signatures | "A request MAY contain more than one Web Bot Auth signature. Each signature is identified by its HTTP Message Signatures label." |
| Per-label member | "Each signer MUST provide a Signature-Agent member for its label." |
| Attribution bound | "A verifier MUST NOT attribute a signature to a member that signature does not cover." |
| Chained coverage | "A signer that covers `"signature";key=X` MUST also cover `"signature-input";key=X`, and MUST cover every component identifier listed in `"signature-input";key=X`." |
| Refusal case | "A signer that cannot cover one of those components … MUST NOT cover the inner signature member." |
| Independent validation | "Verifiers MUST validate each signature independently against its own covered components and its own key." |
| Intermediary relabeling | "An intermediary MUST NOT alter the key of a Signature-Agent member that is covered by a signature it is not able to recompute. Relabeling the Signature dictionary member remains permitted." (§6.6.1) |

Replay protection, verbatim (§5.2.3): "Replay protection, including use of the
nonce signature parameter, is described in Section 7.2.2 of
[HTTP-MESSAGE-SIGNATURES]. This document defines no additional nonce
requirements."

### 6.4 Key-directory document shape

Source: draft `-00` §5.5.1 (verbatim example)

| Item | Value |
| - | - |
| Body format | "All three types resolve to a JSON Web Key Set (JWKS) as defined in Section 5 of [JWK]." |
| Top-level member | exactly one: `keys` (array) |
| `alg` restriction | "The alg parameter is restricted to algorithms registered in the HTTP Signature Algorithms section of [HTTP-MESSAGE-SIGNATURES-IANA]." |
| Transport | "The directory MUST be served over HTTPS." |
| Media type at well-known URI | `application/http-message-signatures-directory+json` (MUST) |
| Validation | "A verifier SHOULD validate the directory format and reject malformed entries." |
| `kid` at well-known URI | "when a JWK set is served at the well-known URI registered in Section 8.1, JWK MAY carry a kid. In this case, it MUST be set to the thumbprint defined in Section 5.2, so a verifier selects a key by matching keyid against kid." |
| `kid` at `jwks_uri` / `cimd` | "kid is an operator-chosen label. A verifier that cannot match keyid against kid there computes thumbprints instead." |

Verbatim example response:

```
GET /.well-known/http-message-signatures-directory HTTP/1.1
Host: example.com
Accept: application/http-message-signatures-directory+json

HTTP/1.1 200 OK
Content-Type: application/http-message-signatures-directory+json
Cache-Control: max-age=86400
{
  "keys": [{
    "kty": "OKP",
    "crv": "Ed25519",
    "kid": "NFcWBst6DXG-N35nHdzMrioWntdzNZghQSkjHNMMSjw",
    "x": "JrQLj5P_89iXES9-vFgrIy29clF9CC_oPPsw3c5D0bs",
    "use": "sig",
    "nbf": 1712793600,
    "exp": 1715385600
  }]
}
```

| JWK member | Type | Present in example | Meaning |
| - | - | - | - |
| `keys` | array | Yes | The only top-level member. |
| `kty` | string | Yes | `"OKP"` |
| `crv` | string | Yes | `"Ed25519"` |
| `kid` | string | Yes | JWK thumbprint (MUST equal the thumbprint when served at the well-known URI) |
| `x` | string | Yes | base64url public key |
| `use` | string | Yes | `"sig"` |
| `nbf` | integer | Yes | not-before, Unix seconds (`1712793600` = 2024-04-11) |
| `exp` | integer | Yes | expiry, Unix seconds (`1715385600` = 2024-05-11) |

Verbatim signed-directory-response proof parameters, Appendix B.1: "tag MUST be
http-message-signatures-directory". The verifier "MUST validate it using the key
provided by the directory and MUST validate the Content-Digest field against the
response body" and "MUST reject a directory response signature whose created is
in the future".

Verbatim §E.2.3 body, the exact minimal field set:

```
{"keys":[{"kty":"OKP","crv":"Ed25519","kid":"poqkLGiymh_W0uP6PZFw-dvez3QJT5SolqXBCW38r0U","x":"JrQLj5P_89iXES9-vFgrIy29clF9CC_oPPsw3c5D0bs","use":"sig"}]}
```

Key-rotation procedure, §5.5.2 (verbatim): "1. Add the new key to the directory
before its intended use date / 2. Continue to include the old key until its
expiration date / 3. Remove expired keys from the directory." … "It is not a
revocation mechanism, and this document does not define any."

IANA registration, draft `-00` §8.2.1 (verbatim):

| Field | Value |
| - | - |
| Type name | `application` |
| Subtype name | `http-message-signatures-directory` |
| Required parameters | `N/A` |
| Optional parameters | `N/A` |
| Encoding considerations | `"binary"` |
| Security considerations | `see Section 6` |
| Interoperability considerations | `N/A` |
| Published specification | `this specification` |
| Fragment identifier considerations | `N/A` |

#### CONFLICT — Cloudflare's deployed form vs. draft-00

Cloudflare's documentation states it implements
`draft-meunier-http-message-signatures-directory-03` plus
`draft-meunier-web-bot-auth-architecture-02`, not
`draft-ietf-webbotauth-httpsig-protocol-00`.

Source: `https://developers.cloudflare.com/bots/reference/bot-verification/web-bot-auth/` (last
updated Jul 1, 2026)

| Item | draft `-00` (IETF) | Cloudflare docs |
| - | - | - |
| `Signature-Agent` form | "Signers MUST send the dictionary form" (§5.2.1) | "the header value is a structured string such as `"https://signature-agent.test"`" |
| Cloudflare failure mode | n/a | "The message uses the dictionary form from later drafts, such as `sig2="https://signature-agent.test"`. → **verification fails**" |
| Directory response `Signature-Input` params | Appendix B: tag `http-message-signatures-directory` | `tag` = `http-message-signatures-directory`; `keyid`; `created`; `expires`; `@authority` with the `req` component parameter |
| Request `Signature-Input` `tag` | MUST be `web-bot-auth` | MUST be `web-bot-auth` |
| `alg` | restricted to IANA HTTP Signature Algorithms registry | "Cloudflare supports Ed25519 key algorithm." Example uses `alg="ed25519"` |
| Request `keyid` | MUST be base64url JWK SHA-256 thumbprint | same (RFC 8037 Appendix A.3) |
| `nonce` | "This document defines no additional nonce requirements." | "there is currently no `nonce` validation, nor does Cloudflare guard against replay attacks using a database of seen `nonces`" |
| Directory key members | full JWK incl. `nbf`/`exp`/`use` shown | "Cloudflare will ignore all other key types and key parameters except those containing `kty`, `crv`, and `x`" |
| Unsupported parameters | not stated | "Cloudflare will fail to verify a message if they are included: `sf` (for HTTP header fields) / `bs` (for HTTP header fields) / `key` (for HTTP header fields) / `req` (for HTTP header fields or derived components) / `name` (for `@query-param` support)" |

## 7. A2A signed Agent Card

Source: `https://a2a-protocol.org/latest/specification/` — Latest Released
Version `1.0.0` (canonical `https://a2a-protocol.org/v1.0.0/specification`).
Normative source of all data objects is `spec/a2a.proto`; `spec/a2a.json` is
explicitly "a non-normative build artifact".

### 7.1 `signatures` field shape

Source: §4.4 AgentCard field table (verbatim row)

| Field | Type | Required | Description (verbatim) |
| - | - | - | - |
| `signatures` | array of `AgentCardSignature` | No | JSON Web Signatures computed for this `AgentCard`. |

Source: §4.4.7 AgentCardSignature (prose): "AgentCardSignature represents a JWS
signature of an AgentCard. This follows the JSON format of an RFC 7515 JSON Web
Signature (JWS)."

| Field | Type | Required | Description (verbatim) |
| - | - | - | - |
| `protected` | `string` | Yes | Required. The protected JWS header for the signature. This is always a base64url-encoded JSON object. |
| `signature` | `string` | Yes | Required. The computed signature, base64url-encoded. |
| `header` | `object` | No | The unprotected JWS header values. |

Wire shape (§8.4.2, verbatim):

- **`protected`** (required, string): Base64url-encoded JSON object containing
  the JWS Protected Header
- **`signature`** (required, string): Base64url-encoded signature value
- **`header`** (optional, object): JWS Unprotected Header as a JSON object
  (**not** base64url-encoded)

Verbatim sample (§8.5):

```json
"signatures": [
  {
    "protected": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpPU0UiLCJraWQiOiJrZXktMSIsImprdSI6Imh0dHBzOi8vZXhhbXBsZS5jb20vYWdlbnQvandrcy5qc29uIn0",
    "signature": "QFdkNLNszlGj3z3u0YQGt_T9LixY3qtdQpZmsTdDHDe3fXV9y9-B3m2-XgCpzuhiLt8E0tV6HXoZKHv4GtHgKQ"
  }
]
```

### 7.2 JWS protected-header requirements

Source: §8.4.2 — §JWS Protected Header Parameters (verbatim)

"The protected header **MUST** include:

- `alg`: Algorithm used for signing (e.g., "ES256", "RS256")
- `typ`: **SHOULD** be set to "JOSE" for JWS
- `kid`: Key ID for identifying the signing key

The protected header **MAY** include:

- `jku`: URL to JSON Web Key Set (JWKS) containing the public key"

| Parameter | Level as written | Container | Description |
| - | - | - | - |
| `alg` | MUST (listed under "MUST include") | protected | "Algorithm used for signing (e.g., "ES256", "RS256")" |
| `typ` | Listed under "MUST include" but the bullet text itself says **SHOULD** | protected | "**SHOULD** be set to "JOSE" for JWS" |
| `kid` | MUST (listed under "MUST include") | protected | "Key ID for identifying the signing key" |
| `jku` | MAY | protected | "URL to JSON Web Key Set (JWKS) containing the public key" |

#### AMBIGUITY — `typ` requirement level

`typ` appears in the list introduced by "The protected header **MUST** include:",
but its own description assigns **SHOULD**. No source resolves which governs.
Do not treat `typ` as an unambiguous MUST.

Verbatim decoded example (§8.4.2):

```
{"alg":"ES256","typ":"JOSE","kid":"key-1","jku":"https://example.com/agent/jwks.json"}
```

Verbatim signing input construction (§8.4.2, step 3):

`ASCII(BASE64URL(UTF8(JWS Protected Header)) || '.' || BASE64URL(JWS Payload))`

### 7.3 Canonicalization RFC and rules

Source: §8.4.1 — §Canonicalization Requirements (verbatim)

**RFC: RFC 8785, JSON Canonicalization Scheme (JCS).** "Before signing, the
Agent Card content **MUST** be canonicalized using the JSON Canonicalization
Scheme (JCS) as defined in RFC 8785."

| # | Rule | Level (verbatim) |
| - | - | - |
| 1a | **Field presence**: "the JSON representation **MUST** respect Protocol Buffer field presence semantics as defined in Section 5.7" | MUST |
| 1b | "**Optional fields not explicitly set**: Fields marked with the `optional` keyword that were not explicitly set **MUST** be omitted from the JSON object" | MUST |
| 1c | "**Optional fields explicitly set to defaults**: Fields marked with `optional` that were explicitly set to a value (even if that value matches a default) **MUST** be included in the JSON object" | MUST |
| 1d | "**Required fields**: Fields marked with `REQUIRED` **MUST** always be present, even if the field value matches the default." | MUST |
| 1e | "**Default values**: Fields with default values **MUST** be omitted unless the field is marked as `REQUIRED` or has the `optional` keyword." | MUST |
| 2a | "Predictable ordering of object properties (lexicographic by key)" | MUST |
| 2b | "Consistent representation of numbers, strings, and other primitive values" | MUST |
| 2c | "Removal of insignificant whitespace" | MUST |
| 3 | "**Signature Field Exclusion**: The `signatures` field itself **MUST** be excluded from the content being signed to avoid circular dependencies." | MUST |

Verbatim worked example — input fragment:

```json
{
  "name": "Example Agent",
  "description": "",
  "capabilities": {
    "streaming": false,
    "pushNotifications": false,
    "extensions": []
  },
  "skills": []
}
```

Verbatim canonical output:

```
{"capabilities":{"pushNotifications":false,"streaming":false},"description":"","name":"Example Agent","skills":[]}
```

Verbatim inclusion decisions: `name` REQUIRED → **include**; `description: ""`
REQUIRED → **include**; `streaming: false` optional, present in JSON → **include**;
`pushNotifications: false` optional, present in JSON → **include**;
`extensions: []` "repeated field (not REQUIRED) with empty array → **omit**";
`skills: []` REQUIRED → **include**.

### 7.4 Requirement level per step

Signing (producer side). Source: §8.4 — §8.4.3. Levels as written.

| Step | Level (verbatim) | Statement |
| - | - | - |
| Sign the Agent Card at all | **MAY** | "Agent Cards **MAY** be digitally signed using JSON Web Signature (JWS) as defined in RFC 7515 to ensure authenticity and integrity." |
| 1. Prepare the payload — remove properties with default values; exclude `signatures`; canonicalize per RFC 8785 | MUST (via §8.4.1 rules 1–3) | "Remove properties with default values from the Agent Card / Exclude the `signatures` field / Canonicalize the resulting JSON using RFC 8785 to produce the canonical payload" |
| 2. Create the protected header — construct with `alg`, `typ`, `kid` (+ optional `jku`); serialize to JSON; base64url-encode | MUST (`alg`, `kid`); `typ` ambiguous per 7.2; `jku` MAY | "Construct a JSON object with the required header parameters (`alg`, `typ`, `kid`) and any optional parameters (`jku`)" |
| 3. Compute the signature over `ASCII(BASE64URL(UTF8(JWS Protected Header)) \|\| '.' \|\| BASE64URL(JWS Payload))`; base64url-encode | MUST (implied by the JWS requirement in step 1 of the enclosing MAY) | "Sign the JWS Signing Input using the algorithm specified in the `alg` header parameter and the private key" |
| 4. Assemble the `AgentCardSignature` — set `protected`, set `signature`, optionally set `header` | `protected` and `signature` MUST (declared Required); `header` MAY | "Optionally set `header` to a JSON object containing any unprotected header parameters." |
| Multiple signatures for key rotation | **MAY** | "Multiple signatures **MAY** be present to support key rotation" |

Verification (consumer side). Source: §8.4.3 — §Signature Verification
(verbatim) "Clients verifying Agent Card signatures **MUST**:"

| Step | Level | Statement (verbatim) |
| - | - | - |
| 1 | MUST | "Extract the signature from the `signatures` array" |
| 2 | MUST | "Retrieve the public key using the `kid` and `jku` (or from a trusted key store)" |
| 3 | MUST | "Remove properties with default values from the received Agent Card" |
| 4 | MUST | "Exclude the `signatures` field" |
| 5 | MUST | "Canonicalize the resulting JSON using RFC 8785" |
| 6 | MUST | "Verify the signature against the canonicalized payload" |

Source: §8.4.3 — §Security Considerations (verbatim)

| Statement | Level |
| - | - |
| "Clients **SHOULD** verify at least one signature before trusting an Agent Card" | SHOULD |
| "Public keys **SHOULD** be retrieved over secure channels (HTTPS)" | SHOULD |
| "Clients **MAY** maintain a trusted key store for known agent providers" | MAY |
| "Expired or revoked keys **MUST NOT** be used for verification" | MUST NOT |

Discovery-path statement (§7, Discovery):

| Statement | Level |
| - | - |
| "Agent Cards **MAY** be signed using JSON Web Signatures (JWS) as specified in the AgentCardSignature object (Section 4.4.7)" | MAY |
| "Clients **SHOULD** verify signatures when present to ensure the Agent Card has not been tampered with" | SHOULD |
| "Implementations **SHOULD** support HTTPS to ensure authenticity and integrity of the Agent Card" | SHOULD |

### 7.5 Cross-references

| Anchor referenced in prose | Target |
| - | - |
| RFC 7515 | JSON Web Signature (JWS) — the container format for `AgentCardSignature` |
| RFC 8785 | JSON Canonicalization Scheme (JCS) — the canonicalization algorithm |
| `spec/a2a.proto` | "the single authoritative normative definition of all protocol data objects and request/response messages" |
| `spec/a2a.json` | "a non-normative build artifact" |
| Section 5.7 | Field presence and optionality |
| Section 4.4.7 | `AgentCardSignature` (the field table is at §4.4; the prose cites §4.4.7) |

`alg` values named in the spec: `"ES256"`, `"RS256"`. No algorithm allow-list is
defined. The upstream extraction was cut off mid-word at this point, on the
sentence "no prohibition on symmetric algorith…"; the remainder of that sentence
is NOT ESTABLISHED IN SOURCE here.
