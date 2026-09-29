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

`std.Thread.Pool` was removed in 0.16 in favour of `Io.Group`. The runtime
follows that: every task that outlives a call is spawned on a `Group`, and
`errdefer group.cancel(io)` guarantees it is cancelled on an early return
rather than leaked. There is no detached background work.

A connection owns one group. Its reader task is spawned there when the
connection starts and the group is awaited or cancelled when it closes, so the
reader's lifetime is the connection's lifetime and there is no way to close a
connection while a task is still touching its buffers.

Synchronisation uses `Io.Mutex` and `Io.Condition`, not `std.Thread.Mutex` and
`std.Thread.Condition`, for the same reason: they cooperate with the
implementation's cancellation, so a blocked waiter is released when its group is
cancelled instead of hanging.

## 4. The codec stays allocation-free; the runtime may not be

The encoding contract in `PROTOCOLS.md` section 2 says no decode or encode path
allocates. That contract is unchanged and still holds for every `src/*.zig`
codec module.

The runtime is a different kind of code and is allowed an allocator, because a
connection has genuinely dynamic state (a pending-request table whose size
depends on concurrency). Where it can avoid allocating it does:

- Frame assembly and every decode buffer stay caller-owned, so the wire path
  from bytes to a decoded message still allocates nothing.
- The pending-request table is the one structure that grows with concurrency,
  and it is a caller-supplied array of slots rather than a hash map, so a
  connection has a known upper bound on outstanding requests and reports
  exhaustion instead of growing without limit.

## 5. What this buys

A consumer picks the executor, not the library. The same connection code runs
under `std.Io.Threaded` in the test suite, under whatever `init.io` provides in
a server binary, and under zio in an application that wants io_uring with
work-stealing, with no change to this repository.
