# zig-agent-proto

Zig 0.16.0 interface library for the agent wire protocols.

**[`PROTOCOLS.md`](PROTOCOLS.md) is the authority.** It specifies every type name,
tag value and byte layout in `src/`. If the source and `PROTOCOLS.md` disagree,
the source is wrong.

[`research/`](research/README.md) is the dated evidence base behind it:
[`research/sota-2026-09-29.md`](research/sota-2026-09-29.md) is the synthesis, and
the other documents cover each protocol and cross-cutting layer in detail.

Build and test with `zig build`, `zig build test`, `zig build docs`. `zig build
test` runs the unit tests and the golden vectors decoded from the
specifications' own worked examples. `zig build fuzz` runs the property and
differential harness, which generates hostile input and checks it against a
reference parser. The house gate is `gate`, from `devenv shell`. Development
conventions are in [`AGENTS.md`](AGENTS.md). [CI](.github/workflows/ci.yml) runs
the same toolchain steps, including the property harness, on Linux and on macOS.
