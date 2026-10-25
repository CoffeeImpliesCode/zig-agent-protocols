# zig-agent-protocols

Experimental Zig codecs and transports for JSON-RPC, MCP, ACP, and A2A.
Requires Zig 0.17.0. The library has no package or system-library dependencies.

## Scope

- JSON parsing and JSON-RPC 2.0 envelopes.
- MCP revisions `2025-11-25` and `2026-07-28`, with stdio and Streamable HTTP transports.
- ACP stable wire version 1 and explicitly selected draft wire version 2.
- The RFD `mcp-over-acp` binding.
- A2A `1.0` discovery and unary JSON-RPC `SendMessage` over HTTP.

The A2A transport does not implement REST, gRPC, streaming, push notifications,
a task store, authentication, signatures, or automatic retries.

[PROTOCOLS.md](PROTOCOLS.md) defines the wire contract.
[SPEC-DECISIONS.md](SPEC-DECISIONS.md) records specification conflicts.
[ARCHITECTURE.md](ARCHITECTURE.md) describes runtime ownership and concurrency.

## Build and test

```sh
zig build
zig build test
zig build test -Doptimize=safe
zig build fuzz
zig build docs
```

`test` runs fifteen roots, including golden fixtures, live loopback tests,
examples, benchmarks, and interoperability participants.
`fuzz` runs the property and differential harness. Use `-Dfuzz-seed=N` and
`-Dfuzz-iterations=N` to select its input.
`docs` installs API documentation under `zig-out/docs`.
`test-artifacts` installs all test binaries and a manifest without running them.

Run the examples:

```sh
zig build run
zig build run-runtime
zig build run-sessions
zig build run-http
zig build run-a2a
zig build run-bench -- --mode all --iterations 10 --samples 2
```

The benchmarks accept `--mode codec|runtime|all`, `--iterations 1..1000000`,
and `--samples 1..64`. Their default is `all`, 100 iterations, and five samples.
The total work limit is 1,000,000 iterations times samples for codec mode,
and 10,000 for runtime or all mode. Reports use `key=value` lines.
Runtime measurements separate connection setup from round trips and first events.

## Use as a package

Add the dependency to your project's `build.zig.zon`:

```sh
zig fetch --save=zig_agent_protocols git+https://github.com/CoffeeImpliesCode/zig-agent-protocols
```

Register the module in `build.zig`:

```zig
const dependency = b.dependency("zig_agent_protocols", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig-agent-protocols", dependency.module("zig-agent-protocols"));
```

Decode and answer a request with caller-owned storage:

```zig
const proto = @import("zig-agent-protocols");

const input = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}";
var scratch: [128]u8 = undefined;
const request = try proto.jsonrpc.decodeRequest(input, &scratch);
var output: [256]u8 = undefined;
const response = try proto.conn.respond(request, "{\"tools\":[]}", &output);
```

Codecs allocate no memory. Decoded values borrow input, scratch, or arena storage.
Keep these regions separate, alive, and unchanged while borrowed values remain in use.
Failed decoding can dirty scratch. Failed encoding can dirty output.
Round trips preserve modeled values and presence, not whitespace, ordering, or escape spelling.
Opaque carried JSON retains its bytes.

Runtime operations use caller-supplied `std.Io` capabilities.
Keep the backend, readers, writers, connection, and callback contexts at stable addresses.
Run a blocking pump with `Io.Group.concurrent`.
Close the connection and shut down its transport, join or cancel tasks, then close the stream.
A successful HTTP exchange constructor requires one matching close.
The static archive exports no C ABI.

## SDK interoperability

The build steps `interop-mcp`, `interop-mcp-current`, `interop-a2a`, and
`interop-acp` install participants. They do not start SDK peers.

The optional site environment, `devenv shell`, supplies Python interpreters and
the pinned SDKs from `test/interop/sdk-pins.json`. Run its matching `interop-*` script.
`interop-acp --protocol-version 2` selects the draft SDK runtime.
Use `--work-dir` to retain captured traffic and reports. `--deadline` bounds a run.

Native builds and tests do not require Nix or devenv.
The optional site environment requires Nix, devenv, anyzig, and a writable scratch
mount configured in `.envrc` and `devenv.nix`. Direnv requires at least 100 GiB free.
Use `.envrc` only on a host with that scratch layout.
Cross-test profiles require QEMU or Wine. The BSD profile also needs full-system
guest images and substantial disk space.
The optional `gate` command requires separately installed `zig-gate` and analyzers.

## Layout

- `src/`: codecs, framing, transports, sessions, examples, and benchmarks.
- `test/`: golden fixtures, loopback tests, and independent SDK peers.
- `tools/`: development checks and guest-runner utilities.
- `research/normative/`: source transcriptions used by the wire contract and fixtures.

## License

MIT, see [LICENSE](LICENSE). Third-party components keep their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
