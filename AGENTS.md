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
- `test/loopback_test.zig` drives two real connections over a Unix socket: a
  client and a server exchanging frames through a live `Io`. It is separate
  from the unit tests because it needs its own loop, and because a codec that
  has only ever been tested against slices has never been driven by a
  transport. Two defects that no slice-driven test could find live here, and
  both are recorded in the file.
- `src/demo.zig` is the `run` step: it decodes real wire bytes with the codec
  and prints what came out.
- `src/framing.zig`, `src/conn.zig` and `src/stdio.zig` are the runtime layer
  that sits above the codec. `framing` assembles newline-delimited frames in a
  caller-owned buffer, `conn` is the JSON-RPC connection, and `stdio` wires the
  process's own streams to one. `ARCHITECTURE.md` records why this layer targets
  the `std.Io` interface rather than a concrete backend.
- `src/mcp_session.zig` is the protocol layer above the connection. Everything
  in it is revision rules: which methods exist, where capabilities travel, and
  how a result is classified.
- `src/acp_session.zig` is the ACP protocol layer above the connection. A
  session is pinned to one wire version for its whole life, because the two
  versions' method registries, capability spellings and permission shapes are
  related by no conversion the specification provides. It also makes the
  approval rule structural rather than a comment: `PermissionAnswer` has no arm
  that means consent, and `PermissionDecision` carries a third arm, `unreadable`,
  so an outcome this library cannot read never becomes `grants = true`.
- `src/bridge_session.zig` carries stateless MCP `2026-07-28` requests over an
  ACP connection with the one method `mcp/message`. Reading the inner outcome is
  a separate step from the call, because an inner MCP error arrives inside a
  successful outer response, and a client that checks only whether the outer
  call failed reports a tool failure as a transport failure and retries it.
- `src/http.zig` is the MCP Streamable HTTP transport, `2026-07-28`, the second
  of the two. It is built on `std.http` and adds no dependency. It mints no
  session identifier and keeps no state between requests, because
  `Mcp-Session-Id` and `Last-Event-ID` were removed at that revision.
- `src/runtime_demo.zig` is the `run-runtime` step: a real MCP client and a
  real server talking to each other over a socket, with the same `conn.Conn` a
  server binary would use.
- `src/sessions_demo.zig` is the `run-sessions` step: an ACP session and the
  `mcp-over-acp` binding over one real connection, which is where the two
  protocol layers are shown composing on transport bytes rather than only
  against each other.
- `src/http_demo.zig` is the `run-http` step: the Streamable HTTP transport over
  a real loopback socket, answering one POST with a single JSON body and one
  with an event stream.
- `build.zig` exposes the `zig-agent-proto` module, installs a static library
  and the four examples, and defines `run`, `run-runtime`, `run-sessions`,
  `run-http`, `test`, `fuzz`, and `docs` steps.
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

## Runtime contracts

These are the rules the layer above the codec is bound by. They are not
style; each one has a failure that is hard to see from the code alone.

- **Every runtime entry point takes `io: std.Io`.** No library type stores an
  `Io` it did not receive, and only the examples and tests name
  `std.Io.Threaded`. This is what keeps the executor a consumer's choice; see
  `ARCHITECTURE.md`.
- **`Io.Group.async` does not run its task until `await` or `cancel`.** A
  reader parked on a group nobody joins simply never starts, and the call
  waiting for its answer waits forever. Join the group.
- **Both ends of a test share one group.** Awaiting the client's group alone
  deadlocks: the client blocks on an answer only the peer's task can produce.
- **A transport must `shutdown` before `close`.** Closing a file descriptor
  does not interrupt a `read` already blocked on it, so the reader sits on an
  open file description and the group never finishes.
- **Read with `readVec`, never `readSliceShort`, to mean "read what is
  available".** `readSliceShort` means *fill this buffer completely* and blocks
  waiting for the remaining kilobytes of a frame that already fully arrived.
- **A connection's reader and writer must outlive `open`.** `conn.Conn` holds
  raw pointers to both `Io.Reader` and `Io.Writer`, so they are fields of the
  owning struct. A local in a constructor dangles the moment it returns, and
  the fault lands on the first read rather than at the call.
- **Handlers run inline on the reader task.** A handler that calls back on the
  same connection deadlocks, because the reader that would deliver that
  answer is the task now waiting for it.
- **A response is matched only by id, and a peer error is not a result.**
  `Response.error_code` is set when the peer answered with `error`; reading only
  `body` reports a failure as a success.
- **Request ids are monotonic and never reused.** A retry is a new call, which
  the multi-round-trip rule requires and which `Conn.nextId` reports.
- **The pending table belongs to the connection.** `Conn.init` clears every
  slot, so a caller's array declared `undefined` is a table of free slots and
  not a table of whatever the stack held. ReleaseSafe does not zero a frame, so
  an uncleared `used` flag answers the first call with `error.TooManyPending`
  before a single byte reaches the wire, and Debug hides it.
- **A handler is handed its decode scratch and its answer buffer as two
  arguments, and they must be two regions.** The escape offset `json.Reader`
  keeps is per reader, not per buffer, so a second reader decoding a string with
  an escape starts at offset 0 again and writes over what the first left there:
  a value the handler borrowed is compared with bytes the handler itself
  produced, and the answer is wrong rather than an error. Never carve one
  buffer into two by a bare index, however the arithmetic looks.
- **A handler that needs a third live region needs a caller-owned struct field,
  not a sub-range.** `escape offset` again: two decoded values cannot share one
  reader's scratch, so `acp_session`'s permission outcome and
  `sessions_demo`'s carried envelope are fields of the owning struct, sized by
  the caller. A fixed array field needs `&` to become a slice; a bare field does
  not coerce.
- **`Conn.init` is fallible, and it refuses before it clears the slot table.** A
  region with no room is `error.UnusableBuffer` and a pair sharing a byte is
  `error.OverlappingBuffers`, both raised before any slot is written, so a
  refused `init` leaves the caller's pending array as it was handed over.
  `conn.overlaps` is the one definition of the predicate — the HTTP transport
  asserts through it rather than defining a second, because a peer cannot
  cause an overlap and so it is not a wire error. Every `Conn.init` call site
  needs `try`, and a call that fails must still hang the transport up: no pump
  was started, so nothing else releases the accepted stream.
- **A failed write kills the connection.** `call`, `notify` and `dispatch` all
  mark the connection dead on `error.Transport`, because a task blocked in
  `call` would otherwise wait on a writer that provably cannot write. An
  `error.Framing` does not: the transport is healthy and stays usable, because
  those same bytes fail the same way however often they are sent and the fault
  is the caller's message. Making one path fatal and another recoverable is the
  bug, not the rule.
- **Every path out of `call` gives its pending slot back.** The table is
  caller-supplied and fixed, so one leaked slot is one fewer request for the
  life of the connection, and sixteen leaked slots make a healthy connection
  answer `error.TooManyPending` forever. Cancellation is the path that does it,
  which is why every mutex acquisition in `conn.zig` is `lockUncancelable`: a
  lock that can fail is a slot that can be dropped.
- **A response nobody can correlate is surfaced, not dropped.** `Conn` reports
  every response that matches no pending slot to an `OrphanHandler` rather than
  discarding it, because a frame the application cannot see is a frame it
  cannot log, cannot account for, and cannot tell apart from a peer that went
  quiet. That covers three cases: an error response whose `id` is `null`, which
  JSON-RPC 2.0 requires where the request's id could not be determined and which
  is the one shape `jsonrpc.decode` admits on an error and refuses everywhere
  else; a response carrying a string id, which no slot ever claims; and the id
  of a call that already returned. One hook rather than a hook per case: two
  hooks for one event is drift, and the wider one subsumes the narrower.
- **`Conn.close` ends the reader, and the caller owns the group.** `pump` tests
  the closed flag rather than reading forever, so a connection that declares
  itself dead stops dispatching. The group is the caller's, spawned on it and
  awaited or cancelled there; `Conn` holds no executor and starts no task.

## Contracts the audit pinned down

- `json.Reader` unescapes into the caller's scratch using a **bump offset**:
  two escaped strings decoded from one reader occupy distinct regions and never
  alias, and `skipValue`/`rawValue` consume no scratch. A string with no escape
  borrows the input directly.
- `mcp.lookupMethod(revision, name)` resolves a top-level method and returns
  `error.UnknownMethod` for anything removed at `2026-07-28` **at that
  revision** — `roots/list`, `sampling/createMessage` and
  `elicitation/create` resolve at `2025-11-25`, where all three were live, and
  `previous_top_level_requests` is the table that says so.
  `mcp.lookupInputRequest(name)` resolves those three inside `inputRequests` at
  every revision. The two tables carry different directions on purpose:
  `input_requests` is a `server_to_client_mrtr_only` value carried in an
  answer, and `previous_top_level_requests` is an ordinary `client_to_server`
  request, so reusing one row for the other resolves the name and then refuses
  it in both directions.
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
- **A repeated JSON member resolves first-wins everywhere.** `json.memberText`
  and `jsonrpc.decode` both take the first, because a later member must not be
  able to make a failed comparison pass. `http` is the deliberate exception and
  refuses a repeated MCP-defined header outright, since two values for a header
  checked against the body leaves the check ambiguous. Three copies of this
  rule disagreeing is drift, not a decision; `json.memberText`'s doc says no
  layer may keep a private copy of that walk, and the ACP session layer once
  did.
- **A JSON document is exactly one value.** Every decoder checks `reader.atEnd()`
  after its member loop — never inside an arm that captures a lexeme around a
  validation call, and never before the loop closes. Ten decoders once skipped
  it and swallowed the tail, and for three of them with a matching encoder that
  was a silent `encode(decode(b)) != b`. The property harness asserts it over
  generated input; see `src/testkit.zig`'s `tail_rule`.
- **A decoder that accepts a member has to be able to write it back.** A member
  the shape does not model is carried as the borrowed lexeme it arrived as,
  never decoded into a type that cannot hold every key a peer may send — that is
  what `bridge.Envelope.meta` and `bridge.OutcomePayload` do, and a typed shape
  is exactly what re-opened the loss.

## Toolchain traps

Three facts about the pinned Zig `0.16.0`. Each one names neither its cause
nor its file, so the next reader pays for it twice unless it is written down.

- **`std.http.Client.connectUnix` does not compile.** It names a
  `std.posix.SocketError` that this `std` no longer defines. A loopback that
  wants a Unix socket uses `Io.net.UnixAddress` instead, and a real client uses
  `connectTcp`.
- **A line is streamed, never taken.** `std.Io.Reader.takeDelimiter` bounds the
  result by the reader's own buffer rather than the caller's, so an event
  stream line longer than the transfer buffer fails there. `http.readEvent`
  reads a line itself and copies it into the caller's buffer, which is what
  makes the caller's buffer the bound. An SSE line is one message long, and a
  message is bounded by the caller's buffer.
- **`BodyWriter.flush` does nothing in the `chunked` state.** It flushes for
  `end`, `none`, `content_length` and `chunk_len`, and `chunked` is the state a
  `transfer-encoding: chunked` body stays in for its whole life. An event stream
  that relies on it delivers nothing until something ends the body, and a
  stream that never ends never ends it. `http.Stream.send` flushes the body
  writer and the protocol output itself.

## Commands

Run at the repository root:

- `zig build` installs the static library and the four examples, and makes the
  `zig-agent-proto` module available to consumers.
  `zig build test` runs the unit tests, the golden vectors and the loopback
  tests. `zig build docs` generates documentation. `zig build run`
  executes the codec demonstration, which prints what each decoder produced
  from real wire bytes; it writes to stdout through one buffered writer, so
  `zig build run > demo.txt` captures the whole report. `zig build run-runtime`
  runs a live MCP client and server against each other over a socket and
  prints the exchange, which is the end-to-end proof that the codec and the
  runtime work together on real transport bytes.
- `zig build run-sessions` runs an ACP client and agent over a socket, then
  carries two MCP requests over that same connection and prints the carried
  result and the carried error. `zig build run-http` runs a Streamable HTTP
  client and server over a loopback port and prints one single-JSON reply and
  one event stream. Both are examples rather than tests: they are the proof
  that the newest layers work on real transport bytes, and CI runs both.
- `zig build fuzz` runs the property and differential harness on its own. It
  takes `-Dfuzz-seed=<u64>` and `-Dfuzz-iterations=<usize>`, both in decimal, and
  prints them on every run, so a failure is reproducible from the log. It
  inherits `-Doptimize` and must not be run in ReleaseFast: a bounds violation
  is a trap in Debug and ReleaseSafe and nothing at all in ReleaseFast, and
  catching the former is the reason the step exists.

  That step is also the only one that writes an options file, and Zig writes one
  through `renameat2(RENAME_EXCHANGE)`. A checkout on a filesystem that rejects
  that call with `EINVAL` — an NFS export, for one — takes the build runner down
  with a panic instead of reporting a build error, so run the step as
  `zig build fuzz --cache-dir <directory on a local filesystem>`. No other step
  writes one, so the rest of the gate is unaffected.
- `zig fmt --check .` checks formatting. `gate` runs the house gate.
- `jj st` shows working-copy status. Use `jj`, not raw Git commands.

Continuous integration runs the toolchain half of that gate on Linux and on
macOS, in `.github/workflows/ci.yml`. It installs the toolchain named by
`.minimum_zig_version` from `ziglang.org`, checks the tarball against the
sha256 the download index publishes, cross-checks `zig version` against the
pin the way `gate` does, and then runs `zig fmt --check .`, `zig build`,
`zig build test` in Debug and again in ReleaseSafe, `zig build fuzz`,
`zig ast-check` over the file set the manifest publishes in `.paths`,
`zig build run`, `zig build run-runtime`, `zig build run-sessions`,
`zig build run-http`, and `zig build docs`. `zlint` and `zbc` are deliberately not in it: both are
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

It also stages a download inside its appdata directory, which is
`$XDG_DATA_HOME/anyzig`, and `$HOME` here is an NFS export. The staged archive
does not survive the round trip and extraction aborts with `illegal file type
'unknown'`. `devenv.nix` therefore sets `XDG_DATA_HOME` alongside
`ZIG_GLOBAL_CACHE_DIR`, both under the node-local `/home/tmp` scratch.
