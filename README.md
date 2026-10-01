# zig-agent-proto

Zig 0.16.0 interface library for the agent wire protocols.

**[`PROTOCOLS.md`](PROTOCOLS.md) is the authority.** It specifies every type name,
tag value and byte layout in `src/`. If the source and `PROTOCOLS.md` disagree,
the source is wrong.

[`research/`](research/README.md) is the dated evidence base behind it:
[`research/sota-2026-09-29.md`](research/sota-2026-09-29.md) is the synthesis, and
the other documents cover each protocol and cross-cutting layer in detail.

Above the codec sits a runtime layer built on Zig 0.16's `std.Io`: newline
framing, a JSON-RPC connection with request/response correlation, a session per
protocol pinned to one revision or wire version, the `mcp-over-acp` binding
carried over an ACP connection, both MCP transports — stdio and Streamable
HTTP — and the A2A `1.0` unary JSON-RPC binding over `std.http`. It targets the
`std.Io` interface rather than a concrete executor, so a consumer picks the
runtime; [`ARCHITECTURE.md`](ARCHITECTURE.md) records why.

Build and test with `zig build`, `zig build test`, `zig build docs`. Five
demonstrations run: `zig build run` decodes real wire bytes with the codec,
`zig build run-runtime` runs a live MCP client and server against each other
over a socket, `zig build run-sessions` runs an ACP session and the
`mcp-over-acp` binding over one more, `zig build run-http` runs the Streamable
HTTP transport over a loopback port, and `zig build run-a2a` discovers an A2A
agent through its card and sends three unary `SendMessage` calls to the
endpoint that card advertises. Together the five are the end-to-end proof that
the codec and the runtime work together on real transport bytes.
`zig build run-bench` runs the bounded benchmarks described below, and
`zig build interop-mcp` and `zig build interop-a2a` build only the two
participants an independent SDK peer starts. `zig build test` runs the unit
tests, the golden vectors decoded from the specifications' own worked examples,
the loopback tests that drive two real connections, the test blocks carried by
the examples, each benchmark module as a root of its own, `testio` and both
interoperability participants — thirteen roots in all, each built as its own
module instance, so nothing is compiled twice.
`zig build fuzz` runs the property and differential harness,
which generates hostile input and checks it against a reference parser. The
house gate is `gate`, from `devenv shell`. Development conventions are in
[`AGENTS.md`](AGENTS.md). [CI](.github/workflows/ci.yml) runs the same
toolchain steps, the property harness, all five demonstrations and one bounded
benchmark smoke, on Linux and on macOS.

## The A2A `1.0` slice

[`PROTOCOLS.md`](PROTOCOLS.md) section 5 is the authority for everything below;
this is a map of where that section lands in `src/`, not a second statement of
it.

The two list responses decode into storage the caller names, which is the rule
every codec here follows. `a2a.decodeListTasksResponse` takes the caller's
`[]Task`, a `ContentArena` for everything a nested task reaches, and a scratch
region. `a2a.decodeListTaskPushNotificationConfigsResponse` takes the caller's
`[]TaskPushNotificationConfig` and a scratch region and no arena, because
nothing under a configuration is a `Part`. A page with more elements than the
caller reserved is `error.BufferTooSmall` rather than a truncated page. All
four members of `ListTasksResponse` are REQUIRED, so a missing one is
`error.MissingField` and `tasks` may be empty but not absent; `""` and `0` are
values a page may carry and neither can stand for "not seen". Neither member of
`ListTaskPushNotificationConfigsResponse` is REQUIRED, so both are presences:
`configs` is null for a page that never mentioned the list and empty for `[]`,
and `next_page_token` is null for a page that never mentioned the token and `""`
for the last page. A repeated member resolves first-wins, `null` included.

`a2a.Rpc` names each method's declared request and response, and the two
factories that resolve them to their Zig payload types are
`a2a.Rpc.RequestType` and `a2a.Rpc.ResponseType`. Both are types, so both are
named as types: they were `requestType` and `responseType`, and the old
spellings are gone rather than kept as aliases, so a consumer that used them
renames its call sites and nothing else. The wire types, the four list codec
signatures and the `a2a_http` API are not affected by that rename.

`src/a2a_http.zig` is the wire binding, written on `std.http` and on the
existing codecs rather than on a second parser:

- `select` walks the card's interfaces in order and takes the first JSON-RPC
  `1.0` one, skipping a JSON-RPC `2.0` entry, a `0.3` entry or a gRPC entry.
- `discover` GETs `a2a.discovery_path` on the caller's own scheme, host and
  port and decodes the card into caller buffers. The card's body and arena must
  outlive the binding, because `Binding.uri` is the advertised URL itself.
- `Client.sendMessage` POSTs the typed `SendMessageRequest` to the advertised
  path and query exactly as written, with a fresh monotonic id.
- `serve` answers the well-known GET with the encoded card and a POST to the
  target the caller configured, from a typed `SendMessageRequest` to a typed
  `Task`, a `Message` or an explicit JSON-RPC error.

There is deliberately no REST, no gRPC, no server-sent events, no push
notification, no task store, no authentication, no signature verification and
no retry: one `SendMessage` is one request, a redirect is not replayed, and an
exhausted id is an error rather than a reused one.

## Benchmarks

`zig build run-bench` runs one bounded executable and
`zig build run-bench -- [flags]` forwards its flags to it. The driver owns the
whole command line:

| Flag | Range | Default | What one count is |
| --- | --- | --- | --- |
| `--mode codec\|runtime\|all` | — | `all` | what runs: the codec against a fixed corpus of literals, a `Conn` round trip and an HTTP first event between real peers over real sockets, or the codec first and then the runtime |
| `--iterations N` | `1..1000000` | `100` | timed passes per window: one pass over the whole corpus for the codec, one round trip per peer for the runtime |
| `--samples N` | `1..64` | `5` | timed windows the statistics span |

`iterations * samples` counts timed passes times windows and is capped at
`1000000` for `--mode codec` and at `10000` for `--mode runtime` and
`--mode all`, because a runtime pass opens a socket and waits for a peer rather
than touching a buffer. An unknown or repeated flag, a missing or non-decimal
count, a count outside its range and a run over its budget are each refused
before a benchmark starts, with exit status 2. `--help` still checks flag syntax
and count ranges, but skips the work budget because it starts no run. The runtime
workload also carries a 120 second wall budget over the whole measured run: a peer
that never flushes and a peer that never answers are one failure rather than two
slow results.

Reports go to standard output as `key=value` lines, one block per workload, and
the two blocks name their statistics differently because they measure different
things:

- **Codec.** `total_ns` is the sum of the timed windows and nothing else, and
  the unqualified `ns_per_op` is its mean over every operation in them, where
  an operation is one accepted corpus row decoded and encoded — printed as a
  decimal, beside `ops_unit` and `iterations_unit` so the denominator is in the
  report rather than in this file. `sample_ns_min`, `sample_ns_median`,
  `sample_ns_max` and one `sample_ns=` line per window are whole window
  totals, so the codec's median is the median of `samples` window totals and
  not a median over individual documents. The block also names its corpus
  (`corpus_sha256`, `corpus_bytes`, `corpus_accepted`) and its caller storage:
  `codec_storage_bytes`, `scratch_required_bytes`, `scratch_used_bytes`,
  `report_buffer_bytes`, `window_array_bytes` and `harness_fixed_bytes` are the
  sizes of fixed arrays the process holds. They are a footprint, not a peak:
  nothing is allocated in order to have one.
- **Runtime.** The unqualified `conn_ns_per_op` and `http_ns_per_op` are means
  over everything measured in that workload, and are what the neighbouring
  `*_ops_per_second` inverts. `*_median_ns_per_op`, `*_p90_ns_per_op` and
  `*_p99_ns_per_op` are quantiles of the **window averages** — each window's
  nanoseconds divided by that window's operations, sorted — so with
  `--samples 5` a `p99` is the largest of five window averages and can sit
  below `*_max_op_ns`, which is the slowest single operation anywhere in the
  run, beside the fastest single one in `*_min_op_ns`. `*_first_window_ns_per_op`
  and the `*_min_window_ns_per_op`/`*_max_window_ns_per_op` pair are window
  averages too, and each `*_window=<n> ... ns_per_op=` line is one window.
  Median and nearest-rank calculations support the full `u64` range without
  overflow.
- **The HTTP boundary.** It measures time to the first event whose bytes decode
  as a JSON-RPC message, and the peer keeps the body open afterwards, which is
  the flush proof rather than an end-of-reply measurement. The TCP connect is
  outside that boundary and is reported separately as `http_connect_*`.
  `http_ns_per_op` already excludes connection time. Do not subtract
  `http_connect_ns_per_op` from it.

These are scoped numbers for one build, one target, one machine and one run
size: a baseline for a later candidate measured the same way. They are not a
claim about this library's speed on any other host, and nothing they report is
a claim about MCP or A2A peer behaviour.

The Conn workload owns its task group and cancels or joins it before closing
the listener. Each reader pump closes its own stream. The HTTP workload joins
its local group before the group storage expires.

The peer-hang-up negative control answers at most one request. Once it requests
shutdown, its reader stops answering later requests even if the owner task has
not run yet. Scheduling the owner late cannot turn that fault into a successful
measurement. The regression checks this window without sleeps and verifies
`PeerEnded` and one descriptor release per side over a real connection.

## Interoperability with pinned SDKs

The library keeps its zero-dependency guarantee because the peers that make an
exchange real are development processes outside it.
`zig build interop-mcp` and `zig build interop-a2a` build two participants —
`zig-agent-proto-mcp-interop` and `zig-agent-proto-a2a-interop` — that the
Python supervisors in `test/interop/` start by their installed path. Those two
steps build only; the exchange itself is driven by the `interop-mcp` and
`interop-a2a` scripts from `devenv shell`, which run `mcp_peer.py --role
supervise` and `a2a_peer.py --role zig-interop` against those binaries.

Both SDKs come from `devenv.nix` and from nothing else: `python3Packages.mcp`
at `1.29.0`, the newest revision whose own `LATEST_PROTOCOL_VERSION` is exactly
the `2025-11-25` this repository pins, and `a2a-sdk` `1.2.1` built from the
exact PyPI release, because the nixpkgs revision `devenv.lock` pins carries the
`0.3` line whose methods are `message/send` and `tasks/get` where `1.0` uses
`SendMessage` and `GetTask`. There is no `pip install`, no `uv` and no
imperative system installation anywhere in this repository. The versions,
digests and API facts each peer depends on are recorded in
[`test/interop/sdk-pins.json`](test/interop/sdk-pins.json), which both peers
read and check themselves against before they run, so a drifted environment is
a refused run rather than a claim nobody verified.

The A2A participant is a CLI with a required role, and each role refuses flags it
does not take. `zig-agent-proto-a2a-interop --role client --base-url URL
--expect-endpoint TARGET [--report-file PATH]` discovers a card, sends and
checks the endpoint that card advertised;
`--role server --port N --advertise-port M --rpc-target TARGET --requests N
[--report-file PATH]` serves the card and that many requests, printing one line
of readiness before it accepts any. `zig-agent-proto-mcp-interop` takes the
SDK's own stdio pipes and runs the `2025-11-25` sequence itself; `mcp_peer.py
--role serve` is the other end of those pipes.

The evidence a run produces is a capture rather than a self-report. The MCP
participant's standard output carries only wire frames; the A2A server prints
one readiness line there, while its HTTP wire crosses the supervisor's relay.
Reports go to the file `--report-file` names, and the supervisor checks them
against the captured bytes. A capture asked for by name is kept as evidence; a
generated one is removed when the run ends. Every peer starts
its children in their own process groups and reaps them on success, on failure
and on timeout, and the MCP participant closes the connection and exits so the
SDK sees end of file and shuts down on its own. This repository documents how
to run an exchange; whether one succeeded is a fact about that run and the
capture it kept, not a claim made here.

## Working on a node

This repository declares its environment and never installs one. Nothing here
is installed imperatively: no `pip install`, no `uv`, no system or development
package, no root. `devenv.nix` declares the tools, the scratch layout and one
Python interpreter carrying both interoperability SDKs, and `devenv.lock` pins
the nixpkgs revision it evaluates against. `devenv shell` enters that
environment; `.envrc` carries the same choice to direnv users.

Some nodes cannot host Nix natively — `/nix` is not writable and the account
holds no capabilities — and there `nix` and `devenv` are run inside an
Apptainer sandbox on node-local scratch, through wrappers the node's operator
configures outside this checkout. That arrangement is per-node state, not a
property of this repository: nothing here creates it, repairs it or hard-codes
its store paths, and nothing here asserts that a particular node has one. What
the repository owes the environment is the part it controls, and that is
`devenv.nix` together with the pin file.

The interpreter the interoperability peers import is the Nix package built by
`devenv.nix` from the revision `devenv.lock` pins, and the versions and hashes
are recorded in
[`test/interop/sdk-pins.json`](test/interop/sdk-pins.json).

### Scratch layout

One root, and every path derived from it:

| Path | Variable | What is in it | Reclaimable |
| --- | --- | --- | --- |
| `<root>/tmp` | `TMPDIR`, `TMP`, `TEMP` | the peers' default work directory, and every temporary file a build makes | yes, once no run is live |
| `<root>/cache` | `XDG_CACHE_HOME` | tool caches with no more specific home | yes |
| `<root>/xdg-data` | `XDG_DATA_HOME` | the anyzig shim's staged toolchain download at `$XDG_DATA_HOME/anyzig` | yes, once the toolchain is unpacked |
| `<root>/zig-cache` | `ZIG_GLOBAL_CACHE_DIR` | the global manifest and its `p/`, the toolchains the shim downloaded | `p/` is the slow half; removing it makes the shim fetch the pinned toolchain from ziglang.org again |
| `<root>/build-cache` | `ZIG_LOCAL_CACHE_DIR` | the local build cache, which `zig build` rebuilds from the manifest | yes, first |

  `<root>` is the first of the `zig-agent-proto` directories under
  `/home/tmp2`, `/home/tmp`, `/vol/tmp2` and `/vol/tmp` that exists: the
  node-local physical mounts first, the approved NFS ones as a fallback.
  `.envrc` picks it with three facts about each mount -- it is a mount of
  its own, this account can write it, and it has at least 100 GiB free, a
  floor `ZIG_AGENT_PROTO_SCRATCH_MIN_FREE_GIB` can raise -- then creates
  the five directories under a 077 umask and refuses any of them that is a
  symlink or belongs to another account. `devenv.nix` derives the same
  five paths from the caller's `USER` with `builtins.pathExists`, so the
  value belongs to the derivation and devenv's evaluation cache cannot pin
  a stale one. Neither side considers `/tmp` or `/var/tmp`, and an
  inherited value naming either, or a removed path, is replaced rather
  than kept.

Two defaults are worth knowing. `TMPDIR` is where an interoperability
peer puts its work directory, because `test/interop/mcp_peer.py` creates it
there and removes it when the run ends; a run given `--work-dir` writes
there instead, and that capture is evidence rather than a temporary file.
`ZIG_AGENT_PROTO_SDK_PINS` names the pin file both peers read and check
themselves against, so a run cannot quietly test something else.

### Checkpoint cleanup

- **Delete only what this project owns and can rebuild.** That is
  `<root>/build-cache`, `<root>/cache`, the contents of `<root>/tmp` and
  `<root>/xdg-data`, `zig-out/`, `.devenv/` and `codedb.snapshot`. Nothing
  outside `<root>` and the sandbox is touched: not `/tmp`, not `/var/tmp`,
  not another account's directory, not another project's scratch. A
  `zig-agent-proto` directory this checkout did not create is not this
  project's to delete.
- **Keep what re-fetching it would cost.** `<root>/zig-cache/p` holds the
  pinned Zig toolchain the shim unpacked. The Nix store behind a node's
  sandbox is the same kind of thing, and `nix store gc` is the bounded way to
  shrink it rather than a reason to remove it.
- **Clean up what a run left behind.** Each peer starts every child in its
  own process group and reaps the group on success, on failure and on
  timeout, so a leftover socket or directory in `<root>/tmp` belongs to a
  run that was killed outright, and that is safe to remove.
- **Keep only the proof a claim needs.** A capture asked for by name is
  evidence and is kept; the generated ones are temporary files and are not.
  One of the former is enough.

## A report that cannot be delivered is a failure, not a clean run

Every program here that writes a report now propagates a write or flush failure
instead of swallowing it. The command-line tools, the demonstrations and the
SDK interop executables buffered their output and dropped the error from the
final flush, so a run whose reader never received the bytes it printed still
exited 0: the report said the exchange succeeded while the success was the
part that had not happened. A successful report now propagates the failure of
its own final flush, once, and the process exits nonzero with the flush error.

The A2A interop server is the same case one level up. Readiness is a fact it
asserts to its supervisor, so a failed write of the readiness line is a failed
startup: the server now fails to start instead of continuing to accept
connections it could not have said it was ready for.

Best-effort flushing is still correct in exactly two places, and both are
cases where the program was never going to succeed anyway: while it is already
unwinding from the failure being reported, and immediately before an explicit
nonzero refusal exit, where there is no further path on which to deliver
anything. Everywhere else a failed flush is the failure.

`Server.answer(.stream)` reports `.ok` only after the terminating chunk of a
chunked body has been written successfully. It reported it as soon as the
answer had been assembled, which let a body that failed on the wire read as a
successful one. Where sending fails, the cleanup that runs on that path cannot
replace the failure that caused it — a cleanup error is reported without
discarding the send error it followed.

None of this changes what any of these programs promise on the wire: no
protocol layout changed, no buffer was added to any hot path, and no function
gained an error in the set its callers are required to handle.

## The house gate

`gate`, from `devenv shell`, runs the house gate tool over this repository:
`fmt`, `build`, `test`, `ast-check`, `ziglint`, `zlint`, `zbc`, `zwanzig` and
`cross-test`, plus coverage when it is asked for with `gate --cov`. Cross-test
is the only section targeting non-native platforms, and `gate --no-cross`
declares that a run is host-local. The gate cross-checks the selected compiler's
version against `.minimum_zig_version` before any of that, then resolves its real
executable through `zig env`, passes it as `ZIG`, and prepends its directory to
`PATH` for analyzers such as zbc that invoke `zig` by name. This keeps every
section on the checked compiler even when the host scratch policy changes the
cache that the anyzig shim would search. An explicit `ZIG` selects the compiler
to check.
The gate runs `test/gate_analysis_test.py` and `test/gate_zlint_test.py` before
the gate itself, because what it is allowed to waive is decided by code that
has to be checked rather than trusted. The gate tool itself is not part of this
repository and is not modified here.

### The file list is this repository's sources

The gate finds the project's Zig sources with `find`, and its exclusion list is
a value the project sets rather than a default it inherits: setting it replaces
the built-in list, so `devenv.nix` carries the whole of it. That list is the
tool's four defaults plus `/.zig-global-cache/`, which the default
`/zig-global-cache/` does not match and which holds an unpacked Zig toolchain in
this checkout — 1938 `.zig` files of its own. With it, what `zig fmt --check`
and the four analyzers see is exactly the thirty files this repository owns:
`build.zig`, twenty-seven under `src/` and two under `test/`. Nothing is deleted
to get there. The caches stay where they are and the gate stops reading them,
which is the difference between a file list that follows the sources and one
that follows the build state.

### One zbc finding is adjudicated, and the source says so

`zbc` reports `recursive-parse-fn-without-stack-check` on
`json.Reader.skipValue`. That finding is wrong for this parser and it is the
only finding this repository has adjudicated: both container arms call
`enterContainer` before any descent and `leaveContainer` after it, so
`json.max_depth` is checked on every recursive step, and a test covers the
bound. `AGENTS.md` records why a second guard is not the answer.

The adjudication is recorded in the source rather than in the gate: a comment
citing `enterContainer` and `max_depth`, then exactly
`// gate-reviewed-zbc-next-line: recursive-parse-fn-without-stack-check` on the
line immediately above the recursive call it covers.
`tools/gate_zbc.py` is what the gate runs as its `ZBC`. It asks the analyzer for
JSON, reports every finding it is given in the analyzer's own
`severity(rule-id)` form, and adjudicates one of them — and only that one — when
every one of the following holds: the file is `src/json.zig`, the rule is the one
named above, the annotation is on the line immediately above the finding, that
line is a recursive `skipValue` call, and the contiguous comment block above the
annotation names both `enterContainer` and `max_depth`. The annotation covers
the single line it stands above. A second recursive call of the same function is
not covered by it and stays open, because a waiver that grows into a whole
function is a larger claim than the one that was reviewed. A reviewed finding is
never printed as `error(...)`, because that is what the gate counts; it is
printed as `reviewed(...)` and summarised, and `gate` names the standing
adjudication before every run.

That comment is a reviewed waiver, not a claim any tool can check for itself.
The wrapper can see that the record is shaped as described above and refuses
anything else; whether the bound really holds is what the review and the test
that covers it are for. What the wrapper adds is that the waiver is narrow,
attributable to one named line of source, and impossible to extend by editing
a rule list.

Everything else is a refusal, and a refusal fails the run rather than explaining
itself in a warning: analyzer output that is not a JSON array of findings, a
finding missing a field, a severity outside `error` and `warning`, an empty
report, a findings status with no findings in it, an analyzer exit code other
than `0` or `1`, an annotation that maps to no finding, an annotation naming
another rule, an annotation above a line that is not the recursive call, a
marker in a file this review never covered, a second marker in the reviewed
file, and a file list that came out empty because an exclusion matched
everything. Other recursive parse functions remain open errors. An analyzer
that does not answer within 900 seconds is refused. The bounded report prints
open errors before advisory warnings, preserves reviewed diagnoses, and counts
findings it does not show. Truncation cannot turn a fatal error into an advisory.

Raw analyzer access is unchanged: `zbc` on `PATH` is the analyzer, and
`ZBC=zbc zig-gate` runs the gate exactly as the host tool ships. The wrapper is
Python standard library only, it is development tooling like the peers, and the
library keeps its zero-dependency guarantee because no Zig file imports it.
`pytest test/gate_analysis_test.py` and `test/gate_zlint_test.py` pin both
wrappers' decisions against controlled analyzer output; `gate` runs them in one
invocation, with the cache provider off and the fixture root on the approved
scratch volume above.

### zlint findings are closed one statement at a time, by hand

zlint reports `suppressed-errors` where a caught error is discarded. Some of
those catches are right: a shutdown that failed on the way out of a teardown
that has already ended the socket anyway, an unlink of a path that is already
gone, a flush of a refusal message on a path about to exit nonzero. Nothing
about them is proved, and this repository does not claim it is. Each was read
by a person, and each is recorded in the source beside the statement it covers,
as exactly

    // gate-reviewed-zlint-next-statement: suppressed-errors

The statement it covers is the next line that is not one of the
`// ziglint-ignore: Z026` and `// zwanzig-disable-next-line: empty-catch-engine`
rows already standing there; those are jumped because they are contiguous and
each names the rule it silences. Nothing else is jumped — a blank line, a
paragraph, a statement, another directive or a second marker ends the cover, so
an annotation cannot grow from one statement into a function or a range. Both
shapes of target are that one statement: an empty `catch {}`, and a
bounded-format `catch unreachable` whose failure cannot happen because the
buffer was sized for this format above it.

That comment is a manual review and is the weakest claim in this section, so
it is stated plainly: the wrapper checks the shape of the record — one of
sixteen reviewed paths, one exact marker, one target line, and exactly one
`warn`-level `suppressed-errors` record on that line — and never the truth of
the comment above it. Refused, and failing the run: a marker in a path the
review never covered, one naming another rule, one whose target line no longer
carries the finding it was written for, one matching two findings, two markers
claiming one finding, a marker an analyzer cannot fence to any statement, an
unreadable report, an unknown level, a record for a file the run did not select,
an empty file list, a duplicate file, and a path outside the checkout. Nothing
else is waived. A rule this wrapper does not adjudicate stays open and is
counted and printed like any other, which is what keeps a review of one caught
error from becoming a waiver of a rule nobody has read.

The analyzers use distinct mechanisms. `zlint` natively honors `SAFETY:`
comments for `unsafe-undefined`. The adapter reviews only exact annotated
`suppressed-errors` statements. `ziglint`'s Z026 and zwanzig's
`empty-catch-engine` use their own named line directives. The source comments
record human-reviewed invariants, not a proof produced by an analyzer.

The gate runs zlint twice and both spellings have to keep working: `$ZLINT -S`,
whose `Found N errors and M warnings` line it counts, and `$ZLINT -S -f json`,
whose records it reduces to a per-rule histogram. The text run prints exactly
one summary line, errors before warnings, and caps what it displays at a
hundred diagnostics without ever capping the counts, so five hundred warnings
cannot hide the one error behind the cap. The JSON run prints every open record
as the analyzer's own NDJSON, uncapped and unaltered, because a cap there would
delete rules from a histogram. A closed finding is named on stderr with the
marker standing behind it and is never printed on stdout as a finding, because
that is what the gate would count. `gate` prints no count of its own, and the
wrapper prints the real one, with every file and line it closed, on every run.

Raw analyzer access is unchanged: `zlint` on `PATH` is the analyzer, and
`ZLINT=zlint zig-gate` runs the gate exactly as the host tool ships. The wrapper
is Python standard library only, like `tools/gate_zbc.py` and the peers.

### Narrow source waivers

Source waivers name one rule on one line, with a preceding invariant or teardown
rationale. `zwanzig-disable-next-line: RULE` requires the colon; omitting it
suppresses every rule on the next line. `ziglint-ignore: ZNNN` is also specific
to the named rule. Neither tool is disabled globally.

The third is the gate's own, described above:
`// gate-reviewed-zlint-next-statement: suppressed-errors`. It names a rule
rather than a line, so it stands above the statement instead of on it, and it
jumps only the `Z026` and `empty-catch-engine` rows already there. A blank line
or a paragraph of prose between a marker and its statement is what keeps it
from being a range waiver, and the proof above it is a human's claim in every
case, not a tool's.

The installed `zwanzig` miscounts a bare `//` row when parsing suppressions.
Comment paragraphs before a waiver therefore use ordinary blank lines, not
empty `//` rows. This preserves the exact diagnostic line without changing
runtime behavior or modifying the host analyzer.


### Cross coverage separates compilation from execution

`cross-test.profile.sh` requires execution on twenty Linux targets, including
32-bit, big-endian and little-endian architectures. It sets
`CROSS_REQUIRE_RUNNERS=1`, so a missing QEMU user-mode emulator or Wine fails
this gate profile rather than silently reducing its coverage, and
`CROSS_BUILD_STEP=test`, so every row runs the complete `test` step including
the live transport tests rather than a codec-only subset. `--targets` selects
rows already in a profile; it cannot add targets. The declared environment
supplies the user-mode emulators and Wine; nothing here is installed
imperatively.

`cross-test.full.profile.sh` unsets the matrix, so it audits all 53 Tier 1/2
targets in the pinned
[Zig 0.16.0 support table](https://ziglang.org/download/0.16.0/release-notes.html#Support-Table)
against the pinned Zig 0.16.0 toolchain. It records compilation,
execution and executed test counts separately in `cross-test-summary.json`, and
`CROSS_REQUIRE_RUNNERS=0` lets a row whose runner is absent be recorded as
`build_only` with `runtime_unavailable` rather than dropped. A `build_only` row
is never a test pass. Known runtime failures remain failures, so this audit
correctly exits nonzero on the evidence below rather than reporting a green
matrix.

The last complete audit on this host compiled all 53 targets and reported:
twenty Linux rows `pass` at 736 executed tests each, both Windows rows
executed and failed, and 31 rows `build_only`. The optional
`devenv --profile cross-audit shell` adds Wasmtime so the `wasm32-wasi` row
executes as well; it cannot pass, for the reasons the next paragraph records.

Windows under Wine executes the suite and fails it. `x86_64-windows` reaches
the failures as real errors from the pinned `std`: AF_UNIX listening returns
`error.AddressFamilyUnsupported` from `netListenUnixWindows`, and the AFD bind
returns `error.Unexpected NTSTATUS=0xc00000cb (BAD_DEVICE_TYPE)`.
`x86-windows` is worse than a failure: every one of its thirteen roots exits
with code 1 and prints no result at all, which the summary records as
`no_test_results` rather than as zero tests. WASI under Wasmtime 48.0.1 runs
and fails on socket and concurrency: `584 pass, 33 fail` in the library root
alone, plus failing `http`, `a2a`, `loopback`, `runtime` and `bench-runtime`
roots, where the expected `error.ConcurrencyUnavailable` arrives as
`error.SocketFailed`. None of these is repaired by disabling tests, by
shrinking the roots, or by changing the library's `std.Io` contract.

`cross-test.bsd.profile.sh` is the third profile: the same thirteen test roots
run inside full-system guests instead of under a user-mode emulator, for the
eighteen BSD rows it registers today — three FreeBSD (`x86_64`, `aarch64`,
`riscv64`), nine NetBSD (`x86_64`, `aarch64`, `aarch64_be`, `arm`, `armeb`,
`powerpc`, `x86`, `mips`, `mipsel`) and six OpenBSD (`x86_64`, `x86`, `aarch64`,
`riscv64`, `powerpc`, `powerpc64`). It exports the binaries through
`zig build test-artifacts`, and its manifest is the build's single suite
registry, so a guest runs exactly the roots `zig build test` runs and a green
guest row reports the same 736 executed tests. A row is not runnable unless
its driver registers it: the OpenBSD `armv7` and `loongson64` sets and the
Loongson PMON firmware are pinned in `devenv.nix` for boot work that has not
produced a registered row, and they are not claimed as coverage.

```sh
devenv --profile bsd-cross shell
cross-test --profile cross-test.bsd.profile.sh --output "$TMPDIR/bsd-cross"
```

Guest execution is network-isolated and uses disposable disk writes; prepared
base images stay in the caller-designated guest cache and are opened as
snapshots, so a cached image is never written by a test run. The payload CD
stays read-only. Tests run from writable guest scratch, since
`std.testing.tmpDir` creates `.zig-cache` relative to the working directory.
The receipt reader refuses a missing or repeated root, a failed exit, skipped
tests, a zero-test root and an incomplete transcript before it reports executed
passage, so a green guest row is thirteen complete receipts and not a partial
log.

Completed guest evidence on this host is narrower than the matrix, and the
difference is the point. `x86_64-freebsd` and `aarch64-freebsd` each pass all
thirteen roots for 736 executed tests. `riscv64-freebsd` boots and runs all
thirteen, and fails: the library root completes 425 of 617 tests and then
segfaults inside `conn.test.a call cancelled while it waits gives its slot
back`, the threaded test; `loopback`, `runtime`, `http`, `bench-runtime` and
`a2a` segfault the same way, while `golden` (16), `sessions` (5), `bench` (21),
`bench-codec` (5), `testio` (9), `a2a-interop` (23) and `mcp-interop` (4) pass.
No FreeBSD RISC-V target passes. The NetBSD and OpenBSD cohorts were still
running when this section was written, so nothing is claimed for them here
beyond what their own summaries record.

The optional runner prerequisites are development host dependencies declared
in `devenv.nix`, never library dependencies. The library itself still has no
dependency beyond the Zig toolchain and no system library dependency; see
`AGENTS.md`. The `bsd-cross` profile supplies full-system QEMU with its
firmware, `xorriso`, `cdrtools`, `mtools`, `e2fsprogs`, `xz`, a guest Python
carrying [`anita` 2.18](https://www.gson.org/netbsd/anita/download/anita-2.18.tar.gz)
and `pexpect`, U-Boot for `armv7l` and `riscv64`, and every guest image pinned
by the release checksum its publisher publishes: FreeBSD 15.1 amd64, arm64 and
riscv64 images, NetBSD 11.0 sets and images, OpenBSD 7.8 install media. The
Loongson PMON firmware is the public
[`20210112` release](https://github.com/loongson-community/pmon/releases/tag/20210112)
asset, pinned for a genuine Loongson boot investigation rather than a proven
port pass. NetBSD images are assembled with a pinned `makefs` because the
guest filesystem needs real device nodes from an `MAKEDEV`-style `mtree` and
an explicit FFS byte order, which OpenBSD's older `makefs` supports in
neither; that host binary is Debian's
[`makefs 20190105-3`](https://packages.debian.org/bookworm/amd64/makefs/download),
repackaged from the `.deb` with `autoPatchelfHook` and glibc and declared
`meta.platforms = [ "x86_64-linux" ]`. The optional `bsd-cross` host is
therefore an x86_64 Linux host today: that bound is stated, not waived, and no
macOS or other-host support is claimed for it.

### What a green gate is not a claim about

A green `gate` is a statement about this checkout, on this host, with the
analyzers installed here, at the moment it ran. It is not a statement about
CI: `zlint` and `zbc` are builds of checkouts under `~/tools` that
`.github/workflows/ci.yml` deliberately does not vendor, so CI runs the
toolchain steps, the property harness, the demonstrations and one bounded
benchmark smoke, and the analyzer verdicts are not part of it. It is not a
security proof either: these are pattern detectors and escape analysis over
source text, not a proof that no input can do anything wrong. And a section
that reports `zbc: OK` has adjudicated one finding rather than found none,
which is why `gate` prints which one before it runs.

A green zlint section is the same kind of statement in a different place: it
has closed the findings a person reviewed and has proved none of them. Those
`suppressed-errors` catches are silent by review, not by analysis, and the
wrapper cannot tell the two apart — it checks that the record is shaped the way
the review says it is and refuses everything else.