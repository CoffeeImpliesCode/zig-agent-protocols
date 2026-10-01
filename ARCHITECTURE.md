# Runtime architecture

How the higher-level layer is built on top of the codec, and why. The codec
(`src/json.zig` through `src/bridge.zig`) is settled and unchanged; this records
the decisions for the runtime that sits above it.

## 1. Target `std.Io`, never a concrete backend

Every runtime entry point takes `io: std.Io` as a parameter. Nothing in the
library names `std.Io.Threaded` except the examples and the tests, and no
library type stores an `Io` that it did not receive.

The reasons, in the order they actually bind:

- **It is an interface on purpose.** `std.Io.zig` states the intent in its own
  module doc: "A cross-platform interface that abstracts all I/O operations
  and concurrency ... This interface allows programmers to write optimal,
  reusable code while participating in these operations." The design rule
  behind it is that *any operation which may block control flow or introduce
  non-determinism goes through the interface*. Taking it as a parameter is what
  makes the code reusable rather than welded to one executor.
- **It is the dependency-injection move, and that is deliberate.** The same rule
  produced the container migration: an allocator is not stored in a struct, it
  is passed to the methods that need it. `Io` follows the same pattern for
  execution. A connection that hard-coded a loop would be a connection that
  cannot be driven by a test loop.
- **It keeps the backends interchangeable.** `std.Io` has `Threaded` (complete),
  `Evented` (experimental), `Uring`/`Kqueue`/`Dispatch` (proof of concept) and
  `failing` (for tests). Code written against the interface runs on all of them.
- **It costs one parameter.** The accepted price is "interface coloring": a
  blocking-looking function still takes `io`, so a purely computational helper
  does not. That is a smaller cost than losing the backend choice.

## 2. No new dependencies

The repository rule is zero dependencies beyond the Zig toolchain
(`AGENTS.md`). The runtime therefore uses `std.http.Client` and
`std.http.Server` for HTTP rather than a third-party HTTP library.

`zio` (github.com/lalinsky/zio) was evaluated as the async runtime, and is a
strong project, but it is a **runtime choice, not a library dependency**: its
README states it is "a full implementation of the standard library's `std.Io`
interface, so any Zig 0.16+ code written against `std.Io` runs on zio
unmodified", and it explicitly advises "prefer the `std.Io` interface,
especially if you are writing a library". Writing against the interface is
therefore the choice that keeps zio available to applications while costing
this library nothing. The same applies to `dusty` (HTTP) and `pg.zig` (async
Postgres) by the same author: they are the frontier of what is being built
*against* `std.Io`, and they prove the interface is wide enough, but adopting
them would invert the dependency and break the house rule.

`std.Io.Evented` is not usable yet. Its own comparison, from the zio FAQ, is
that it "is very far from finished. It's missing essential functionality, if it
even builds", where `Threaded` is the complete implementation. So `Threaded` is
the reference backend for tests and examples, and the interface is the contract.

## 3. Concurrency is structured

`std.Thread.Pool` was removed in 0.16 in favour of `Io.Group`. Every task that
outlives a call belongs to a group. `defer group.cancel(io)` covers early
returns and is a no-op after a successful join. There is no detached work.

A connection owns no group and starts no task. The caller holds the group,
spawns `Conn.pump` on it, and awaits or cancels it; `Conn` holds the reader's
buffers and nothing else about the executor. That is the same choice as taking
`io: std.Io` by parameter rather than storing it: the executor belongs to the
caller.

The reader's lifetime is bounded by two things the caller can both observe.
`Conn.close` marks the connection dead, and `pump` tests that flag rather than
reading forever, so closing a connection ends its reader instead of only
declaring it unusable. The caller must await or cancel the group before releasing
the buffers its tasks borrow.

Blocking socket peers, readers and deadline races use `concurrent`, not `async`.
`Io.Group.async` may run its task inline when `Threaded` reaches its async limit,
which defaults to one less than the CPU count. An inline reader prevents its
caller from sending the request it waits for. This was a real deadlock in a
two-core FreeBSD guest and in the MCP exchange with `.async_limit = .nothing`.
`concurrent` either assigns independent execution or returns
`error.ConcurrencyUnavailable`. The examples propagate that error; the benchmark
reports it without calling it a socket failure or recording a measurement.

Synchronisation uses `Io.Mutex` and `Io.Condition`, not `std.Thread.Mutex` and
`std.Thread.Condition`, for the same reason: they cooperate with the
implementation's cancellation, so a blocked waiter is released when its group is
cancelled instead of hanging.

## 4. The codec allocates nothing, and the one allocator is the consumer's

The encoding contract in `PROTOCOLS.md` section 2 says no decode or encode path
allocates. That contract is unchanged and still holds for every `src/*.zig`
codec module, and for the runtime layer above it: a frame, the scratch a handler
decodes into, the answer it composes, a pending-request slot and every byte of
session state are caller-owned. The wire path from bytes to a decoded message
allocates nothing, and it allocates nothing as a property rather than by
accident:

- Frame assembly and every decode buffer stay caller-owned, so nothing between
  the transport's bytes and a decoded message is composed out of a heap.
- The pending-request table is a caller-supplied array of slots rather than a
  hash map, so a connection has a known upper bound on outstanding requests and
  reports exhaustion instead of growing without limit.

The runtime is a different kind of code and is permitted an allocator where its
state is genuinely dynamic. It takes none: the one structure that would qualify
is the pending table, and that is the caller's array.

Where an allocator does appear, it belongs to `std.http` and to the consumer
who owns the client rather than to any layer here. `std.http.Client` carries an
allocator and spends it on its own connection pool, so whether the HTTP paths
meet a heap at all is the consumer's decision and not a property of this
repository:

- `a2a_http` borrows a `*std.http.Client` rather than constructing one, so the
  allocator, the executor and the connection pool stay the consumer's. Every
  buffer on the A2A path is the caller's too; the client is the only borrowed
  thing in it, and nothing in this repository allocates a card, a frame, a
  `Task` or a `Message` with it.
- `http` builds its server from an `Io.Reader` and `Io.Writer` pair the caller
  composes, so whether an allocator is in play on that path is a fact about
  the caller's writer rather than about this module.

That is two claims rather than one, and the second is the useful half: no
protocol byte in this library is ever composed out of an allocator, and a
consumer that never constructs a `std.http.Client` never meets one.

## 5. A handler is given two regions, not one

`json.Reader` keeps its escape offset per reader rather than per buffer. A
second reader decoding a string with an escape therefore starts at offset zero
again and writes over whatever the first left there. A handler handed one
buffer decodes into it and then composes its answer into it, so the writer's
first bytes land on the method name or the id the handler is about to read. The
result is a wrong answer rather than an error: the comparison simply fails and
the handler takes the branch that names an absent method.

`conn.Handler.call` takes `(ctx, frame, decode_scratch, answer)`. The decode
region holds anything the reader unescaped; the answer region holds the
envelope. A `Request` may borrow the frame or the decode region and the
envelope may borrow either, and all of it dies when the handler returns because
the connection owns both and overwrites them for the next request.

Three consequences, in the order they bind:

- **The regions are caller-supplied and separately sized.** A caller who wanted
  two halves of one buffer could have carved them, and several handlers did,
  but a proportional carve's bound is not one a caller can reason about when
  choosing a size, and a silently halved answer region is the failure this
  change exists to remove. `Conn.init` refuses a zero-length region and a pair
  sharing a byte, before it clears the slot table, so the mistake is reported
  where the caller can see which arrays it passed rather than on the first
  message. `conn.overlaps` is the one definition of that check.
- **A third live region becomes a struct field.** Two decoded values cannot
  share one reader's scratch, so `acp_session`'s permission outcome and
  `sessions_demo`'s carried envelope are caller-owned fields of the session's
  struct rather than sub-ranges of a parameter. The cost is that the owning
  type has to know the size, which is a cost worth paying for a value that has
  to stay readable while an answer is being written next to it.
- **Each transport keeps its own pair.** `http.Server` is built from an
  `Io.Reader`/`Io.Writer` and sits *below* `conn.Conn`, which is the layer above
  framing with its own frame buffer and pending table. It shares a
  `conn.Handler` *value* precisely so one dispatcher serves both transports, and
  that shared value is why a second pair in `Server.Buffers` is cheaper than
  making the HTTP transport depend on the connection it sits under.
- **The A2A server's regions are disjoint for the same reason, and checked
  rather than assumed.** `a2a_http.serve` takes seven caller buffers, each live
  at the same moment as the answer written over the next, and proves them
  pairwise disjoint with `conn.overlaps` before it serves. `payload_out` is
  where the handler's answer is composed and `envelope_out` is where the frame
  carrying it is written; the frame splices the first into the second, so one
  array behind both would write the answer over itself and report it as a
  correct answer.

## 6. The A2A binding posts to the endpoint a card advertised

`src/a2a_http.zig` is the newest layer above the codec, and PROTOCOLS.md
section 5 is the authority for everything in it; what follows records why it is
built this way, not a second statement of what it must do.

- **The interface is chosen in the card's own order.** `select` walks
  `card.supported_interfaces` and takes the first entry whose transport is the JSON-RPC
  token and whose version is `1.0`, skipping a JSON-RPC `2.0` entry, a `0.3`
  entry and a gRPC entry without complaint and without reordering. An entry
  that claims `1.0` and is not an absolute HTTP(S) URL is an error rather than
  a skip, because a malformed claim is a card this client cannot reason about.
- **Nothing about the endpoint is inferred.** The advertised path and query are
  used exactly as written, `/rpc` is never guessed, and a relative advertised
  URL is refused rather than resolved against the discovery origin: a client
  that filled any of those in would be calling a peer on a request it never
  named. The discovery GET is the other half of that rule — the caller's own
  scheme, host and port with `a2a.discovery_path`, and the origin's path, query
  and fragment dropped.
- **The card outlives the binding, because the binding borrows it.** A
  `Binding`'s URI is the advertised URL itself, so `DiscoveryBuffers.body` and
  the `CardArena` have to stay alive and unmodified for as long as the client
  that posts through it; a card body reused under a live client takes the
  endpoint with it.
- **One version, and a peer's refusal is not a caller's failure.** Every
  request carries the selected interface's own `A2A-Version`, and a request
  whose header is absent, empty, patched or otherwise unsupported is answered
  `-32009`; an unknown method is `-32601` and invalid params are `-32602`. The
  codec's `0.3` method aliases are the codec's dispatch table and do not mean a
  `0.3` body is served here.
- **A reply is one of three things.** `Reply.status` and `Outcome` are read
  together: a `result` carrying a `Task`, a `result` carrying a `Message`, or
  an explicit `jsonrpc.Error` kept as an error even when the HTTP status is a
  success. Collapsing the three into one flag is the mistake the type exists to
  prevent.
- **There is no REST, no gRPC, no event stream, no push, no task store, no
  authentication and no signature.** Nor is there a retry: a `SendMessage` is
  one request with a fresh id, a redirect is not replayed, and an id is never
  reused. A peer that needs any of those is a peer this module refuses, which
  is a different answer from the one it would give if it guessed.

## 7. What this buys

A consumer picks the executor, not the library. The same connection code runs
under `std.Io.Threaded` in the test suite, under whatever `init.io` provides in
a server binary, and under zio in an application that wants io_uring with
work-stealing, with no change to this repository.
