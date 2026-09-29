# zig-agent-proto

Zig 0.16.0 interface library for the agent wire protocols. The public surface is
specified by [PROTOCOLS.md](PROTOCOLS.md), which is the authority for every type
name, tag value, and byte layout in `src/`. The repository uses `jj` with colocated
Git.

## Layout

- `src/root.zig` is the root module. It re-exports every module and declares the
  shared `DecodeError` and `EncodeError` sets.
- `src/json.zig` is the substrate: a borrowing pull parser and a fixed-buffer
  writer. It exists because `std.json` owns heap memory, which the encoding
  contract forbids, so a decoder that touched it would allocate on every call.
- `src/jsonrpc.zig` is the JSON-RPC 2.0 base that MCP and ACP both sit on.
- `src/mcp.zig`, `src/a2a.zig`, `src/acp.zig` are the three wire protocols, and
  `src/bridge.zig` is the `mcp-over-acp` binding.
- Source and tests are flat under `src/`: one file per module, with its unit
  tests as `test` blocks in the same file. There is no `src/tests/` directory.
- `src/testkit.zig` is the property and differential harness, kept out of the
  default `test` run because it generates tens of thousands of documents. It
  asserts the properties that must hold for every byte sequence: no panic, no
  out-of-bounds read, a `DecodeError` rather than a trap, round-trip stability
  through every encoder, `requiredScratchLen` as an upper bound, borrowed values
  that do not alias, and agreement with `std.json.Scanner` on accept-versus-reject.
- `test/` holds the golden vectors: the specifications' own worked examples,
  copied verbatim, plus fixtures whose member names are verbatim from the
  normative schema tables. `test/golden_test.zig` decodes them and pins the
  fields each was selected to pin, and it runs in the default `test` step. It is
  a separate binary from the library tests because a fixture is a file and
  `@embedFile` makes a missing one a build failure rather than a silent skip.
- `src/demo.zig` is the `run` step. It is a separate executable because a static
  library cannot be run, and because a protocol library that has only ever run
  its own tests has never been used against real wire bytes.
- `build.zig` exposes the `zig-agent-proto` module, installs a static library and
  the demonstration, and defines `run`, `test`, `fuzz`, and `docs` steps.
- The library has no dependencies beyond the Zig toolchain and no system library
  dependencies.

## Protocol contracts

- PROTOCOLS.md is the single source of truth. If the source and PROTOCOLS.md
  disagree, the source is wrong. Where PROTOCOLS.md and `research/normative/`
  disagree, PROTOCOLS.md wins and the source records the conflict in a comment.
- Every wire type uses explicitly-sized integers and fixed-length byte arrays.
  A struct is `extern` only when the wire layout genuinely requires a C ABI.
- Decoding is total. It returns a `DecodeError` and never `unreachable`,
  because every byte read off the wire is untrusted input. A `MalformedJson`
  error is a JSON syntax fault; `InvalidUtf8` is reserved for bytes that are
  genuinely not UTF-8. Do not collapse the two.
- Encoding must be the exact inverse of decoding: `decode(encode(x)) == x` and
  `encode(decode(b)) == b` for every accepted input, including a notification,
  which encodes without an `id`. Both directions are tested. `encode` validates
  a message before writing, so it cannot emit bytes its own `decode` rejects.
- Unknown enum tags and unknown method names are errors, not `unreachable`
  arms. An agent speaking a newer protocol version must not crash an older one.
- Do not allocate in a decode or encode path. Use caller-supplied buffers. A
  `Reader` has no allocator field; every escape-unescape target and every
  integer or base64 buffer is caller-owned.

## Contracts the audit pinned down

- `json.Reader` unescapes into the caller's scratch using a **bump offset**:
  two escaped strings decoded from one reader occupy distinct regions and never
  alias, and `skipValue`/`rawValue` consume no scratch. A string with no escape
  borrows the input directly.
- `mcp.lookupMethod(revision, name)` resolves a top-level method and returns
  `error.UnknownMethod` for anything removed at `2026-07-28`, including
  `roots/list`, `sampling/createMessage` and `elicitation/create`.
  `mcp.lookupInputRequest(name)` resolves those three inside `inputRequests`.
- `bridge.isBindingFailure(code, level)` takes an explicit `ErrorLevel`
  (`.inner` / `.outer`), so an inner MCP code — even `-32602`, which the outer
  space also uses — is never read as a binding failure. `bridge.decodeEnvelope`
  takes the outer `jsonrpc.Id` so it can set the request/notification direction.
- `a2a.aliasToCurrent` maps a `0.3` slash-form method name to its `1.0` RPC
  name; `a2a.TaskState.fromTag` / `a2a.Role.fromTag` range-check a numeric tag
  and return `error.UnknownTag` above the declared range.
- Container nesting is bounded by `json.max_depth`. `zbc` reports the recursion
  in `json.Reader.skipValue` as advisory; that finding is wrong, the bound is
  enforced by `enterContainer` and covered by a test, so do not add a second
  guard without removing the first.


## Commands

Run at the repository root:

- `zig build` installs the static library and the demonstration, and makes the
  `zig-agent-proto` module available to consumers. `zig build test` runs the unit
  tests and the golden vectors. `zig build docs` generates documentation.
  `zig build run` executes the demonstration, which prints what each decoder
  produced from real wire bytes; it writes to stdout through one buffered
  writer, so `zig build run > demo.txt` captures the whole report.
- `zig build fuzz` runs the property and differential harness on its own. It
  takes `-Dfuzz-seed=<u64>` and `-Dfuzz-iterations=<usize>`, both in decimal, and
  prints them on every run, so a failure is reproducible from the log. It
  inherits `-Doptimize` and must not be run in ReleaseFast: a bounds violation
  is a trap in Debug and ReleaseSafe and nothing at all in ReleaseFast, and
  catching the former is the reason the step exists.
- `zig fmt --check .` checks formatting. `gate` runs the house gate.
- `jj st` shows working-copy status. Use `jj`, not raw Git commands.

Continuous integration runs the toolchain half of that gate on Linux and on
macOS, in `.github/workflows/ci.yml`. It installs the toolchain named by
`.minimum_zig_version` from `ziglang.org`, checks the tarball against the
sha256 the download index publishes, cross-checks `zig version` against the
pin the way `gate` does, and then runs `zig fmt --check .`, `zig build`,
`zig build test` in Debug and again in ReleaseSafe, `zig ast-check` over the
file set the manifest publishes in `.paths`, `zig build run`, and
`zig build docs`. `zlint` and `zbc` are deliberately not in it: both are
builds of personal checkouts under `~/tools`, outside this repository, so CI
would have to vendor an unpinned third-party build to run them.

This NixOS project declares development dependencies and tools in `devenv.nix`.
Do not install system or development libraries imperatively. Use direnv or
`devenv shell`; run `direnv allow` after changing the environment.

`zig` on this host is the anyzig shim, which resolves the toolchain by reading
`.minimum_zig_version` from `build.zig.zon`. It is deliberately absent from
`devenv.nix` `packages`, because a nixpkgs `zig` would shadow the shim and build
with a version the manifest does not pin. The shim exits 1 with no output when it
cannot resolve a toolchain, so `gate` cross-checks `zig version` against the
manifest pin before running any build step.
