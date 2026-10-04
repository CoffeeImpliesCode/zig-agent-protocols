# zig-agent-protocols

Zig 0.16.0 interface library for the agent wire protocols. The public surface is
specified by [PROTOCOLS.md](PROTOCOLS.md), which is the authority for every type
name, tag value, and byte layout in `src/`. The repository uses `jj` with colocated
Git.

## Layout

- `src/root.zig` is the root module. It re-exports the library modules and
  declares the shared `DecodeError` and `EncodeError` sets. Four modules are
  reached as named imports rather than through it: `testkit.zig`, which the
  `fuzz` step compiles as its own root; `testio.zig`, the shared test executor
  the build adds to the library module as `testio`; and `bench_codec.zig` and
  `bench_runtime.zig`, which the `run-bench` driver reaches the same way. The
  ten executable roots under `src/` are programs rather than library surface.
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
  in it is revision rules: which methods exist at the pinned revision, which
  way each travels, and where capabilities travel. How a result is
  classified is deliberately **not** here — it reads facts out of a document
  rather than out of a connection, so `classifyResult`, `checkResult` and
  `inputRequired` live in `mcp.zig` beside the decoders they sit under. The
  split is the tree's own rule: document facts are codec, connection and
  pinned-session facts are session.
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
- `src/a2a_http.zig` is the A2A `1.0` unary JSON-RPC binding, the newest layer
  above the codec and the only one written straight onto `std.http` rather than
  through `http.zig`, whose gates are MCP's. PROTOCOLS.md section 5 is its
  authority and its own module comment records why each rule is there, so this
  entry is a pointer rather than a second statement of the contract. It borrows
  a `*std.http.Client` instead of constructing one, so the allocator, the
  executor and the connection pool are the consumer's, and every buffer on the
  path is a caller buffer. No REST, no gRPC, no server-sent events, no push, no
  task store, no authentication, no signature and no retry is implemented, and
  a redirect is not replayed.
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
- `src/a2a_demo.zig` is the `run-a2a` step: discovery through
  `a2a.discovery_path`, a card whose advertised endpoint is neither a default
  nor `/rpc`, and three unary `SendMessage` calls answered with a `Task`, a
  `Message` and a JSON-RPC error, so the three answers are read as three
  different things.
- `src/bench_codec.zig` and `src/bench_runtime.zig` are the two benchmark
  modules, each with the frozen entry point `run(io, out, iterations,
  samples)`. The first measures a fixed literal corpus in caller buffers; the
  second measures a `Conn` round trip and an HTTP first valid event between
  real peers over real sockets. Their caller buffers are fixed and do not grow
  with the counts. The supplied executor may allocate for tasks and I/O;
  fixed benchmark storage is not a claim about whole-process heap traffic.
  `src/bench.zig` is the driver: it
  owns the command line and the work budget, and it reaches both modules as
  named imports, so the driver and the test binary share one module instance
  each instead of compiling a second copy of a benchmark.
- `src/mcp_interop.zig`, `src/mcp_current_interop.zig`, `src/a2a_interop.zig`
  and `src/acp_interop.zig` are four interoperability participants, not library
  modules. Supervisors in `test/interop/` start them against independent SDKs.
  No library module imports a participant or an SDK. `test/interop/sdk-pins.json`
  records the versions, digests and API facts that each peer checks before a run.
  The two MCP participants cover separate revisions without a compatibility shim.
  The ACP participant uses wire 1 by default. Wire 2 requires explicit selection
  and the pinned SDK's experimental runtime.
- `build.zig` exposes the `zig-agent-protocols` module and installs a static library,
  five examples, the benchmark driver and four interoperability participants.
  It defines `run`, `run-runtime`, `run-sessions`, `run-http`, `run-a2a`,
  `run-bench`, `interop-mcp`, `interop-mcp-current`, `interop-a2a`, `interop-acp`,
  `test`, `test-artifacts`, `fuzz` and `docs`. Each `interop-*` build step
  installs a participant without starting an SDK. The matching `devenv` script
  drives the exchange. `run-bench` forwards `-- …` to the driver, which owns
  its flags and bounds.
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
- Encoding preserves modeled wire values and represented presence, not the
  original JSON spelling. `PROTOCOLS.md` section 2 defines normalization,
  first-wins duplicates, stable re-encoding and carried opaque JSON. A
  notification still encodes without `id`. Encoders validate their modeled
  shape; publish any unchecked text or alias preconditions on the owning API.
- Unknown enum tags and unknown method names are errors, not `unreachable`
  arms. An agent speaking a newer protocol version must not crash an older one.
- Do not allocate in a decode or encode path. Use caller-supplied buffers. A
  `Reader` has no allocator field; every escape-unescape target and every
  integer or base64 buffer is caller-owned.

## Runtime contracts

These are the rules the layer above the codec is bound by. They are not
style; each one has a failure that is hard to see from the code alone.

- **Runtime execution comes from caller-supplied `std.Io` capabilities.**
  Entry points take `io` directly or use a capability received at construction.
  `Conn` stores the `Io` passed to `init` for its locks and condition waits;
  readers/writers and HTTP requests also carry their backend. None constructs
  an executor. Keep backend state alive until all borrowed operations finish.
  Only examples and tests name `std.Io.Threaded`; selecting an interface is
  not certification that every backend implements the needed operations.
  `http.Server.init` takes `Io.Reader`/`Io.Writer`, not a redundant `Io`, since
  those interfaces supply every wait it performs. See `ARCHITECTURE.md`.
  Three `a2a_http` entry points cross-check their executor rather than making an
  exception to the rule: `discover`, `Client.init` and `Client.sendMessage` take
  the `io` *and* a borrowed `*std.http.Client`, and debug-assert that the two
  name the same one — userdata and vtable. Two executors in one call is a call
  whose socket wait has no thread to run on, and the assertion is where that is
  caught rather than on a socket that hangs.
- **Blocking peers and readers use `Io.Group.concurrent`, not `async`.**
  `async` may execute inline when the executor reaches its async limit, so a
  reader can prevent its caller from sending the request it waits for.
  `concurrent` assigns independent execution or returns
  `error.ConcurrencyUnavailable`; propagate that refusal and unwind the group.
- **Both ends of a test share one group.** The caller owns all tasks and joins
  or cancels them before releasing their buffers and transport state.
- **A transport must `shutdown` before `close`.** Closing a file descriptor
  does not interrupt a `read` already blocked on it, so the reader sits on an
  open file description and the group never finishes.
- **The owner closes a duplex stream only after all readers and writers join.**
  A reader that returns must not close the descriptor its caller can still
  write. Teardown marks the connection dead and shuts down the stream, then
  joins or cancels every task that uses it, then closes it once. Ownership is
  recorded before fallible connection initialization so a refused open still
  shuts down and releases its accepted descriptor.
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
- **The two A2A list responses decode into storage the caller names.**
  `decodeListTasksResponse` takes a caller `[]Task` and a `ContentArena`, and
  reads every nested task through one `json.Reader`, so two tasks in one page
  cannot be handed the same escape region; the arena is reset once at the
  public boundary, because one decode serves one document. All four members are
  REQUIRED, so `""` and `0` are values a page may carry and neither can stand
  for "not seen", and a page larger than the caller's array is `BufferTooSmall`
  rather than a page that lost its last task.
  `decodeListTaskPushNotificationConfigsResponse` takes a caller
  `[]TaskPushNotificationConfig` and no arena — nothing under a configuration
  is a `Part` — and marks both members optional, so `null` and `[]` are two
  documents for `configs` and `null` and `""` are two for `nextPageToken`. A
  `""` default would read as "no further pages" for a response that never said
  so.
- **An A2A interface is chosen in the card's order, and the advertised URL is
  used as written.** `a2a_http.select` takes the first JSON-RPC `1.0` interface
  and skips a `2.0` entry, a `0.3` entry or a gRPC one; an entry that claims
  `1.0` and is not an absolute HTTP(S) URL is an error rather than a skip.
  `Binding.uri` borrows the card body, so `DiscoveryBuffers.body` and the
  `CardArena` have to outlive the binding and the client, and `serve`'s seven
  buffers are proven pairwise disjoint with `conn.overlaps` because
  `payload_out` and `envelope_out` are both live when the frame splices the
  answer into itself.
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
  it and swallowed trailing bytes instead of refusing a second value. The
  property harness asserts the whole-document rule over generated input;
  see `src/testkit.zig`'s `tail_rule`.
- **Represented open data must survive encoding.** Carried raw JSON stays a
  borrowed lexeme, not a closed projection that loses keys. This is the contract
  of `bridge.Envelope.meta` and `bridge.OutcomePayload`. Typed decoders may skip
  unmodeled members where their API states that policy; section 2 of
  PROTOCOLS.md does not promise source-document replay.

## Toolchain traps

Four traps in the pinned Zig `0.16.0`:

- **`std.http.Client.connectUnix` does not compile.** It names a
  `std.posix.SocketError` that this `std` no longer defines. A loopback that
  wants a Unix socket uses `Io.net.UnixAddress` instead, and a real client uses
  `connectTcp`.
- **`std.Io.Uring` does not compile unchanged.** Its `dirOpenDir` and
  `dirRealPathFile` implementations return `ReadOnlyFileSystem`, which their
  declared error sets exclude. A real consumer compile fails in `Uring.zig`
  at lines 2732 and 3157. The kernel accepts `io_uring_setup` on this host,
  but that does not establish a working Zig backend. Its socket vtable also
  returns `NetworkDown`; do not substitute another `Threaded` configuration
  and call it a second backend.
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

- `zig build` installs the static library, the five examples, the benchmark
  driver and the four interoperability participants, and makes the
  `zig-agent-protocols` module available to consumers.
  `zig build test` registers fifteen roots: the library unit tests, the golden
  vectors, the loopback tests, the test blocks the four socket-driven examples
  carry, the benchmark driver, each benchmark module as a root of its own,
  `testio`, and all four interoperability participants. Each is a separate module
  instance, so a benchmark or a participant is never compiled twice for the
  test that covers it. `zig build docs` generates documentation.
  `zig build test-artifacts` installs those same fifteen binaries and their
  generated manifest without running them. `cross-test.bsd.profile.sh` drives
  that export inside full-system guests for twenty-two registered BSD rows:
  six FreeBSD, nine NetBSD and seven OpenBSD, through
  `devenv --profile bsd-cross shell`. The manifest is the same registry
  `test` uses, so a guest must run all fifteen roots and report its executed
  test count. Binaries stay on a read-only payload CD, fixtures use
  writable guest scratch, disks are opened as snapshots so a cached image is
  never written, and the receipt reader refuses a missing, repeated or
  zero-test root, a failed exit, skipped tests and an incomplete transcript.
  `zig build run`
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
  one event stream. `zig build run-a2a` discovers an agent through
  `a2a.discovery_path`, reads its card, and sends three unary `SendMessage`
  calls to the endpoint that card advertised, printing the selected endpoint and
  version, the typed task, the typed message and the JSON-RPC error. All three
  are examples rather than tests: they are the proof that the newest layers work
  on real transport bytes, and CI runs all three.
- `zig build run-bench` runs the benchmark driver, and every flag belongs to the
  driver, so `zig build run-bench -- --mode all --iterations 20 --samples 5`
  reaches it verbatim: `--mode codec|runtime|all`, `--iterations N` in
  `1..1000000` and `--samples N` in `1..64`, defaulting to `100` and `5`. The
  product `iterations * samples` is capped at `1000000` for `codec` and `10000`
  for `runtime` and `all`, and the runtime workload carries a 120 second wall
  budget over the measured run. Every refusal happens before a benchmark
  starts, with exit status 2, and `--help` does not swallow a typo standing
  beside it.
- The counts mean different things in the two modules, and a report is read
  against the unit lines it prints. One codec iteration is one pass over the
  whole corpus, so one operation is one accepted row decoded and encoded; one
  runtime iteration is one round trip per peer, each of which opens a socket and
  exchanges frames over it. The unqualified `*_ns_per_op` is a mean over every
  operation measured, and is what `*_ops_per_second` inverts.
  `*_median_ns_per_op`, `*_p90_ns_per_op` and `*_p99_ns_per_op` are quantiles
  of the **window averages**, so with `--samples 5` a `p99` is the largest of
  five window averages and can sit below `*_max_op_ns`, which is the slowest
  single operation anywhere in the run; the codec's `sample_ns_*` figures are
  whole window totals instead. The HTTP boundary is time to the first event
  whose bytes decode, with the TCP connect outside it and reported separately
  as `http_connect_*`, which makes the connect mean the number to subtract
  rather than to add. The storage figures a codec report prints —
  `codec_storage_bytes`, `scratch_used_bytes`, `window_array_bytes`,
  `harness_fixed_bytes` — are the sizes of fixed arrays the process holds and
  are not a peak: nothing is allocated in order to have one. A number from here
  is a baseline for a later candidate measured the same way, not a claim about
  another host or about peer behaviour.
- `zig build interop-mcp`, `interop-mcp-current`, `interop-a2a` and `interop-acp`
  build and install participants. They do not start SDKs.
  From `devenv shell`, the matching scripts run the supervisors in `test/interop/`.
  `interop-mcp` covers MCP `2025-11-25`. `interop-mcp-current` covers MCP
  `2026-07-28`. `interop-a2a` drives both unary A2A JSON-RPC directions.
  `interop-acp` covers ACP wire 1. `interop-acp --protocol-version 2` selects
  experimental wire 2 without a fallback. Each supervisor accepts `--work-dir`
  for captured evidence and `--deadline` for the whole run.
  The interpreters are isolated where package versions conflict.
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
- `cross-test` runs a profile outside the house gate. Three exist, and each
  states its own bounds rather than inheriting one:
  `cross-test --profile cross-test.profile.sh` requires execution on the
  twenty Linux targets (`CROSS_REQUIRE_RUNNERS=1`, `CROSS_BUILD_STEP=test`, so
  an unavailable runner or a reduced root set is a failure);
  `cross-test --profile cross-test.full.profile.sh` unsets the matrix and
  audits all 53 Tier 1/2 targets of the pinned Zig 0.16.0 support table with
  `CROSS_REQUIRE_RUNNERS=0`, recording compilation, execution and executed
  test counts separately so a `build_only` row cannot be read as a pass;
  `cross-test --profile cross-test.bsd.profile.sh --output "$TMPDIR/bsd-cross"`
  runs all fifteen registered roots in full-system guests and needs
  `devenv --profile bsd-cross shell` first. `--targets` selects rows already in
  a profile and never adds one, so an unregistered port is not runnable by
  naming it. Known runtime failures stay failures: on this host the full audit
  compiles all 53 targets and still reports both Windows rows failed and 31
  rows `build_only`, and under Wasmtime the `wasm32-wasi` row fails on socket
  and concurrency operations. Those are recorded facts, not defects to be
  hidden by skipping tests. `README.md` carries the per-platform results.
- `jj st` shows working-copy status. Use `jj`, not raw Git commands.

Continuous integration runs the toolchain half of that gate on Linux and on
macOS, in `.github/workflows/ci.yml`. It installs the toolchain named by
`.minimum_zig_version` from `ziglang.org`, checks the tarball against the
sha256 the download index publishes, cross-checks `zig version` against the
pin the way `gate` does, and then runs `zig fmt --check .`, `zig build`,
`zig build test` in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, `zig ast-check`
over every Zig file under `build.zig`, `src` and `test`, and `zig build fuzz`
with seeds `0`, `1` and `18446744073709551615` at 20 000 iterations each in Debug,
all five
demonstrations (`run`, `run-runtime`, `run-sessions`, `run-http`, `run-a2a`),
one bounded benchmark smoke — `zig build run-bench -- --mode all --iterations 4
--samples 3`, which proves the driver runs and asserts no threshold — and
`zig build docs`. The four interoperability participants are installed by
`zig build` and nothing in CI drives them: their SDK peers are declarative
devenv development state that CI does not evaluate, so what CI proves about
them is that they compile and that their own test blocks pass.
`zlint` and `zbc` are deliberately not in it: both are builds
of personal checkouts under `~/tools`, outside this repository, so CI would
have to vendor an unpinned third-party build to run them.

This NixOS project declares development dependencies and tools in `devenv.nix`.
Do not install system or development libraries imperatively. Use `devenv shell`,
or let direnv read `.envrc`. That environment provides `gate`, the SDK
interpreters and four `interop-*` scripts. It pins every SDK against
`test/interop/sdk-pins.json`, so a peer refuses an environment that does not
match. Nothing in this repository repairs, extends or depends on host-wide
state around it.

Two optional profiles add more, still as declared Nix development state and
still never as a library dependency: `cross-audit` adds Wasmtime so the
`wasm32-wasi` row executes, and `bsd-cross` adds full-system QEMU with its
firmware, the ISO and archive tools, `anita` 2.18 with `pexpect` for the guest
console, U-Boot for `armv7l` and `riscv64`, the Loongson PMON
`20210112` firmware, `e2fsprogs`, and every guest image pinned by the
checksum its publisher publishes. Its `makefs` is Debian's `20190105-3`
repackaged with `autoPatchelfHook` and glibc, because the NetBSD guest image
needs `MAKEDEV`-style device nodes and an explicit FFS byte order that
OpenBSD's older `makefs` cannot write; it declares
`meta.platforms = [ "x86_64-linux" ]`, so `bsd-cross` is an x86_64 Linux host
configuration today. That is a stated bound, not a waiver, and no other host
platform is claimed for it.

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
