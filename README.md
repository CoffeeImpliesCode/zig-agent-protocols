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
carried over an ACP connection, and both MCP transports, stdio and Streamable
HTTP. It targets the `std.Io` interface rather than a concrete executor, so a
consumer picks the runtime; [`ARCHITECTURE.md`](ARCHITECTURE.md) records why.

Build and test with `zig build`, `zig build test`, `zig build docs`. `zig build
run` decodes real wire bytes with the codec. `zig build run-runtime` runs a
live MCP client and server against each other over a socket, `zig build
run-sessions` runs an ACP session and the `mcp-over-acp` binding over one more,
and `zig build run-http` runs the Streamable HTTP transport over a loopback
port. Together the four are the end-to-end proof that the codec and the runtime
work together on real transport bytes. `zig build test` runs the unit tests, the
golden vectors decoded from the specifications' own worked examples, and the
loopback tests that drive two real connections. `zig build fuzz` runs the
property and differential harness, which generates hostile input and checks it
against a reference parser. The house gate is `gate`, from `devenv shell`.
Development conventions are in [`AGENTS.md`](AGENTS.md). [CI](.github/workflows/ci.yml)
runs the same toolchain steps, including the property harness and all four
examples, on Linux and on macOS.
