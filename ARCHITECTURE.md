# Runtime architecture

[PROTOCOLS.md](PROTOCOLS.md) defines the wire contract.
Attached API documentation defines buffer lifetimes, validation, and failure residue.

## Execution and dependencies

Runtime operations use caller-supplied `std.Io` capabilities.
`Conn.init` stores the capability for locks and condition waits.
Stdio adapters retain theirs. Pure codecs need no executor.
No library layer constructs a backend. Tests and examples select `std.Io.Threaded`.

A backend must support the selected transport's streaming I/O, synchronization,
cancellation, and independent concurrent tasks. Interface compatibility alone does
not establish transport support.

The library has no external dependencies. HTTP uses `std.http.Client` and
`std.http.Server`. The A2A client borrows a standard HTTP client, including its
allocator and connection pool. That client and its backend remain caller-owned.

## Structured concurrency

A connection starts no tasks and owns no task group.
The caller runs `Conn.pump` in its own `Io.Group`.
Readers, writers, buffers, callbacks, and the backend must outlive those tasks.
Keep each object at a stable address while tasks retain its pointers.

Use `Io.Group.concurrent` for blocking peers and reader pumps.
`async` can run inline when a backend reaches its async limit.
An inline reader can prevent the caller from sending the request it awaits.
`concurrent` either starts independent execution or returns `ConcurrencyUnavailable`.

Teardown order:

1. Close Conn to mark it dead.
2. Shut down the transport to wake blocked reads.
3. Join or cancel every reader and writer.
4. Close each descriptor once.
5. Release borrowed storage and the backend.

`Io.Mutex` and `Io.Condition` cooperate with backend cancellation.
A canceled response wait releases its pending slot and leaves Conn usable.
The peer may already have executed the request. Conn does not replay it.

## Caller storage

Codecs allocate no memory. Input strings, escape scratch, arena elements, frame
buffers, pending slots, and session state use caller-owned storage.
The pending table bounds outstanding calls and reports exhaustion instead of growing.
A borrowed `std.http.Client` can allocate for its own pool.

`conn.Handler.call` receives `(ctx, frame, decode_scratch, answer)`.
Decoded strings can borrow frame or scratch for the callback's duration.
The returned envelope remains valid through the synchronous write after the callback.
The next decode or buffer reuse invalidates those bytes.
Handlers run inline on the pump. A handler must not wait for another call on that connection.

Decode scratch and answer storage must be separate regions.
`Conn.init` rejects empty or overlapping configuration regions before clearing slots.
A handler that retains a third decoded value needs independent storage for it.
Each HTTP transport retains its own decode and answer regions.
`a2a_http.serve` checks all seven supplied buffers for pairwise overlap.

An encoder can dirty backing storage before failure. Discard failed output.
Other alias and stable-address requirements remain caller preconditions.
Assertions diagnose specified misuse in debug and safe modes, not fast or small modes.

## A2A binding

`select` walks the card's interfaces in order and selects the first JSON-RPC `1.0` entry.
It skips other transports and versions. A matching entry needs an absolute HTTP(S) URL.
Discovery uses the caller's scheme, host, and port with `a2a.discovery_path`.
Requests use the advertised path and query without substituting a default endpoint.

`Binding.uri` borrows the decoded card's storage.
Keep the card body, scratch, and arena unchanged while the binding remains in use.
Each request carries the selected `A2A-Version` and a fresh monotonic id.
A reply is a Task result, a Message result, or an explicit JSON-RPC error.
HTTP success does not convert a protocol error into a result.
The transport has no automatic retry or redirect replay.

## Resource boundaries

| Boundary | Retained resources | Cleanup |
| --- | --- | --- |
| Decoder | Input, scratch, arena borrows | Keep alive and unchanged. Returned values own no cleanup. Failure can consume scratch or arena capacity. |
| Encoder | Source values and caller output | Keep sources valid and separate from writable output. Discard failed encoding. |
| Conn | Reader/writer pointers, configuration regions, callback context, Io | Follow the teardown order above. Per-call buffers remain separate. |
| Session | Borrowed Conn and negotiated state | Conn outlives the session. Session mutation requires caller synchronization. |
| HTTP exchange | Live request and caller buffers | Close once after successful construction, before backend teardown. |
| A2A binding | URI borrowed from card storage | Retain backing storage until the binding is unused. |

`lastEncodedLen` and `nextId` are synchronized connection-wide snapshots.
Exclude other encoders before using a length to slice your output.
An id snapshot does not reserve that id.
`EncodeBufferTooSmall` means local output shortage.
`ResponseTooLarge` means an inbound answer exceeded result storage.
Neither response overflow nor cancellation authorizes replay.
