#!/usr/bin/env python3
"""MCP 2025-11-25 interoperability peer, driven against the Zig participant.

Two roles, both in this one file because they are two ends of the same wire:

``--role serve``
    The peer itself: a genuine ``mcp`` SDK server (the pinned 1.29.0 release)
    speaking MCP over this process's own stdin and stdout. It serves three
    tools and nothing else. It is started as a child process, so its stdout is
    the protocol stream and cannot carry a log line; its observations go to a
    side-channel file the supervisor names.

``--role supervise``
    Starts that peer and the Zig client as two children, relays bytes between
    them verbatim, records the raw wire, asserts what the exchange has to
    prove, and kills and reaps everything on any path out.

What the exchange proves, and how each claim is checked:

* the revision is negotiated, not assumed: the peer answers ``initialize`` with
  ``2025-11-25`` because that is the SDK's own latest revision, and the Zig
  client asks for it;
* ``notifications/initialized`` really travels, and really after the answer to
  ``initialize`` arrived and before every request that depends on it. The
  frames for those three moments sit in two different captures, and an index
  into one of them orders nothing; the claim is made from the relay's own
  order instead, which is the sequence number of the write that carried a
  frame and the byte offset inside that write. One read of a pipe routinely
  carries both ``notifications/initialized`` and the request that depends on
  it, so the write sequence alone calls them equal; a pipe is a FIFO byte
  stream, so the byte offset is what orders them. Both halves are recorded
  and kept in ``summary.json``;
* ``tools/list`` and ``tools/call`` are answered;
* a JSON-RPC peer error and a successful tool failure are two different things.
  The peer error is produced by the SDK itself, from a ``tools/call`` whose
  params omit the required ``name``: the SDK's session validates the inbound
  request and answers with ``error.code = -32602`` and no ``result`` member.
  The tool failure is a tool that ran and returned ``isError: true`` inside a
  ``result``. Both are asserted by shape, not by message text;
* a cancellation reaches the independent SDK: the Zig client cancels an
  in-flight ``tools/call`` for a slow tool, and the SDK's own session
  interrupts the handler and answers with a peer error for that id. The peer
  records that its tool started, was interrupted and never finished, which is
  the SDK's cancellation machinery acting rather than the wire merely carrying
  a frame. The cancellation is also checked to cross after the request it
  names, because an SDK drops a cancellation for an id that is not in flight
  and a run that sent one too early would prove nothing;

* what the Zig client's own decoder read is compared with those same bytes at
  the end: the revision, the tool list, the text the echo tool answered with
  and both error codes. The report is never the evidence for a claim, only
  something the wire can be asked to agree with.
* the peer sees end of file and exits, and is reaped. Nothing is left running.

No mocks, no fakes, no synthetic responses: the peer is the upstream SDK and
the wire is the bytes that crossed the pipes. Versions, hashes and the API
facts this file depends on are recorded in ``sdk-pins.json``, which both roles
read and check themselves against, so a run against an environment that does
not match the pins fails instead of quietly testing something else.

Where a run writes: the wire, the reports and the logs all go into one work
directory. Named with ``--work-dir``, it is kept, because a capture somebody
asked for is evidence. Otherwise it is created inside the environment's
``TMPDIR`` and removed when the run ends, on success and on failure alike, so
a run leaves nothing behind and reports which of the two it did instead of
printing a path that no longer exists. ``TMPDIR`` is the only thing that
decides where a generated directory may be created, and a system temporary
directory is refused either way.


Nothing here makes any claim about what the SDK does internally: the capture
is bytes, the assertions are shapes, and the only ordering claimed is the
relay's own.
"""

from __future__ import annotations

import argparse
import json
import os
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Iterable, NamedTuple

HERE = Path(__file__).resolve().parent
DEFAULT_PINS = HERE / "sdk-pins.json"

# The tool names both ends agree on. The Zig client sends these literals; they
# are repeated here rather than negotiated, which is what a client and a server
# do: the names are the interface, and an interop run that agreed on them at
# runtime would be testing the agreement instead of the protocol.
TOOL_ECHO = "echo"
TOOL_FAIL = "fail"
TOOL_SLOW = "slow"

# The 2025-11-25 revision this exchange is pinned to. Sent by the client, and
# asserted against the answer, so neither side gets it right by accident.
REVISION = "2025-11-25"

# A fixed marker, not a path or a hostname: the capture is kept as evidence, so
# it must not carry anything about the machine that produced it.
MARKER = "zig-agent-proto-interop"

# Two codes the checks below compare against, both pinned in sdk-pins.json
# against the mcp 1.29.0 source with line numbers:
# `sdks.mcp.api.peer_error_from_bad_params` records that the SDK's own session
# answers an inbound request whose params fail validation with
# `ErrorData(code=INVALID_PARAMS)`, and `sdks.mcp.api.cancellation` records
# that `RequestResponder.cancel` answers the cancelled id with
# `ErrorData(code=0)`. Asserting them is what tells this run apart from a peer
# that answered with some other error for an unrelated reason.
INVALID_PARAMS = -32602
REQUEST_CANCELLED = 0


class InteropFailure(Exception):
    """A check failed. The message is the finding; the traceback is not."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InteropFailure(message)


# --- pins -----------------------------------------------------------------------


def load_pins(path: Path) -> dict[str, Any]:
    try:
        pins = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise InteropFailure(f"pin file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise InteropFailure(f"pin file is not JSON: {path}: {exc}") from exc
    require(
        pins.get("schema") == "zig-agent-proto/interop-sdk-pins/1",
        f"pin file schema is {pins.get('schema')!r}, not the one this peer was written against",
    )
    return pins


def installed_version(distribution: str) -> str:
    from importlib.metadata import PackageNotFoundError, version

    try:
        return version(distribution)
    except PackageNotFoundError as exc:
        raise InteropFailure(
            f"{distribution} is not importable by {sys.executable}. The interop peers are "
            f"development tooling and are not on the system interpreter: run them through the "
            f"pinned environment (`devenv shell`, then `interop-python`, or `interop-mcp`)."
        ) from exc


def check_pins(pins: dict[str, Any], distribution: str) -> dict[str, Any]:
    """Refuse to test against an environment the pins do not describe."""
    sdks = pins.get("sdks", {})
    require(distribution in sdks, f"the pin file records no {distribution!r}")
    want = sdks[distribution].get("version")
    require(isinstance(want, str) and want != "", f"the pin file records no version for {distribution!r}")
    have = installed_version(distribution)
    require(
        have == want,
        f"{distribution} {have} is installed, the pin is {want}. Refusing to run: an "
        f"interop result only means something for the release it was taken against.",
    )
    return sdks[distribution]


# --- where a run may write ------------------------------------------------------

# The two system-wide temporary directories. A work directory never lands in
# either: they are shared with every other process on the host, so a capture
# left there outlives the run that made it and nobody can say whose it is.
# Which scratch is approved is the environment's decision, and it says so in
# TMPDIR; nothing here carries a path of its own.
SYSTEM_TEMPORARIES = ("/tmp", "/var/tmp")


def within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def is_system_temporary(path: Path) -> bool:
    """Whether a path is, or resolves into, a system temporary directory.

    Through realpath, because a symlink into ``/tmp`` is that same shared
    directory under a different name, and refusing only the literal spelling
    would be a check that passes for the wrong reason.
    """
    resolved = Path(os.path.realpath(path))
    return any(within(resolved, Path(root)) for root in SYSTEM_TEMPORARIES)


def scratch_root() -> Path:
    """The only directory a generated work directory may be created in."""
    raw = os.environ.get("TMPDIR")
    require(
        raw is not None and raw.strip() != "",
        "TMPDIR is not set. This peer keeps a run's work on the scratch the environment "
        "provides and never falls back to a system temporary directory: export "
        "TMPDIR=<scratch>, or pass --work-dir <dir> to name the place yourself.",
    )
    require(Path(raw).is_absolute(), f"TMPDIR={raw!r} is not an absolute path")
    root = Path(raw)
    require(
        not is_system_temporary(root),
        f"TMPDIR={raw!r} is a system temporary directory, which is shared with every process "
        f"on the host. Point TMPDIR at this machine's own scratch instead.",
    )
    root.mkdir(parents=True, exist_ok=True)
    require(os.access(root, os.W_OK | os.X_OK), f"TMPDIR={raw!r} is not writable")
    return root


class WorkDir:
    """Where one run's evidence goes, and who takes it away afterwards.

    Generated or named, the only difference is who may keep it: a generated
    directory is removed when the run ends, on every path out, and the run
    says which of the two happened rather than printing a path that is no
    longer there.
    """

    def __init__(self, requested: str | None, prefix: str) -> None:
        if requested is None:
            self.path = Path(tempfile.mkdtemp(prefix=prefix, dir=os.fspath(scratch_root())))
            self.temporary = True
            return
        named = Path(requested)
        require(named.is_absolute(), f"--work-dir {requested!r} is not an absolute path")
        require(
            not is_system_temporary(named),
            f"--work-dir {requested!r} is a system temporary directory, which is shared with "
            f"every process on the host. If you want the capture kept, name a directory on "
            f"this machine's own storage.",
        )
        require(not named.exists() or named.is_dir(),
                f"--work-dir {named} exists and is not a directory")
        self.path = named
        self.temporary = False
        self.path.mkdir(parents=True, exist_ok=True)

    def __truediv__(self, name: str) -> Path:
        return self.path / name

    def notice(self) -> str:
        if self.temporary:
            return (f"  temporary work removed: {self.path}\n"
                    f"  pass --work-dir <dir> to keep the wire capture and the reports")
        return f"  capture and reports: {self.path}"

    def discard(self) -> None:
        shutil.rmtree(self.path)


def remove_temporary(work: WorkDir) -> None:
    """Take a generated work directory away, or say where it still is."""
    if not work.temporary:
        return
    try:
        work.discard()
    except OSError as exc:  # pragma: no cover - the filesystem refused
        print(f"  the temporary work directory could not be removed and is still at "
              f"{work.path}: {exc}", file=sys.stderr)


class BoundedLog:
    """One child's stderr: bounded on disk, and bounded in what a failure quotes.

    The same cap a wire capture gets, and for the same reason: an unbounded log
    beside a failing run is the artifact nobody opens. The last lines are kept
    in memory as well, because a generated work directory is removed on the way
    out and the message still has to carry the evidence.
    """

    def __init__(self, path: Path, limit: int, keep: int = 20) -> None:
        self.path = path
        self._handle = path.open("wb")
        self._limit = limit
        self._written = 0
        self._lines: deque[str] = deque(maxlen=keep)
        self._carry = b""
        self.truncated = False

    def write(self, data: bytes) -> None:
        if self._written >= self._limit:
            self.truncated = True
            return
        room = self._limit - self._written
        if len(data) > room:
            self._handle.write(data[:room])
            self._written = self._limit
            self.truncated = True
        else:
            self._handle.write(data)
            self._written += len(data)
        self._remember(data)

    def _remember(self, data: bytes) -> None:
        # Whole lines only: a partial line is a line nobody ever read, and a
        # message quoting half of one is worse than quoting nothing.
        self._carry += data
        *complete, self._carry = self._carry.split(b"\n")
        for line in complete:
            self._lines.append(line.decode("utf-8", "replace").rstrip())

    def tail(self, width: int = 600) -> str:
        lines = [*self._lines]
        if self._carry:
            lines.append(self._carry.decode("utf-8", "replace"))
        text = "\n".join(lines)
        if len(text) > width:
            text = "..." + text[-width:]
        return text

    def close(self) -> int:
        self._handle.close()
        return self._written


def pump(source: Any, log: BoundedLog) -> threading.Thread:
    """Drain a child's stderr into a bounded log, on a thread of its own.

    A pipe rather than a file, because a file cannot be bounded while it is
    being written: the cap has to sit between the two ends, or a chatty SDK
    fills the disk before anybody reads what it said.
    """
    assert source is not None

    def drain() -> None:
        descriptor = source.fileno()
        while True:
            try:
                data = os.read(descriptor, 65536)
            except OSError:  # pragma: no cover - the pipe was closed under us
                return
            if not data:
                return
            log.write(data)

    thread = threading.Thread(target=drain, name="stderr-drain", daemon=True)
    thread.start()
    return thread


def stderr_note(log: BoundedLog, work: WorkDir, label: str) -> str:
    """Where a child's stderr ended up, in words that stay true afterwards."""
    if work.temporary:
        where = (f"the temporary work directory {work.path} is removed on the way out, so "
                 f"this is all {label} said")
    else:
        where = f"{label} wrote its stderr to {log.path}"
    tail = log.tail()
    if not tail:
        return f"{where}, and it wrote nothing"
    return f"{where}:\n" + "\n".join(f"    {line}" for line in tail.splitlines())


def require_bounded_size(path: Path, limit: int) -> None:
    """One produced file, held to the same bound as a capture."""
    if not path.exists():
        return
    size = path.stat().st_size
    require(
        size <= limit,
        f"{path.name} is {size} bytes, over this run's {limit}-byte bound. Raise "
        f"limits.capture_bytes_per_direction in the pin file, or the record is not evidence "
        f"of a complete run.",
    )


# --- the peer -------------------------------------------------------------------


class SideChannel:
    """The peer's own record of what it did, on a path the wire does not touch.

    One fresh file per run, one JSON object per line, flushed per line: the Zig
    client waits on a file this writes while it is blocked in a call, so a
    buffered line is a line nobody ever sees.
    """

    def __init__(self, path: Path | None) -> None:
        self._handle = None
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)
            self._handle = path.open("w", encoding="utf-8")

    def event(self, name: str, **fields: Any) -> None:
        if self._handle is None:
            return
        record = {"event": name, "monotonic": round(time.monotonic(), 6), **fields}
        self._handle.write(json.dumps(record, sort_keys=True) + "\n")
        self._handle.flush()

    def close(self) -> None:
        if self._handle is not None:
            self._handle.close()
            self._handle = None

    @staticmethod
    def read(path: Path) -> list[dict[str, Any]]:
        if not path.exists():
            return []
        events = []
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                events.append(json.loads(line))
        return events


def run_serve(args: argparse.Namespace) -> int:
    """The genuine SDK server, over this process's stdio."""
    pins = load_pins(args.pins)
    record = check_pins(pins, "mcp")

    import anyio
    import mcp.types as types
    from mcp.server.lowlevel import Server
    from mcp.server.stdio import stdio_server
    from mcp.shared.exceptions import McpError

    side = SideChannel(args.report)
    side.event(
        "peer_start",
        mcp=record["version"],
        latest_protocol_version=types.LATEST_PROTOCOL_VERSION,
        python=sys.version.split()[0],
    )

    # The file the Zig client waits on. It is written the moment the slow tool
    # is entered and never removed, so the client cannot cancel a request the
    # peer has not started, which is the race a sleep would leave open.
    marker = args.slow_entered_file

    def entered() -> None:
        if marker is not None:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(
                json.dumps({"event": "slow_entered", "monotonic": round(time.monotonic(), 6)}) + "\n",
                encoding="utf-8",
            )
        side.event("slow_entered")

    def text_schema() -> dict[str, Any]:
        # A fresh dict per tool: one schema shared between three models is a
        # latent alias, and a schema is four lines.
        return {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
            "additionalProperties": False,
        }

    server = Server(
        f"{MARKER}-peer",
        version=record["version"],
        instructions=(
            "Interoperability peer for zig-agent-proto. Every tool name, argument and "
            "result is fixed so a capture can be compared against a later run."
        ),
    )

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        side.event("list_tools")
        return [
            types.Tool(
                name=TOOL_ECHO,
                description="Return the text it was given, in a successful result.",
                inputSchema=text_schema(),
            ),
            types.Tool(
                name=TOOL_FAIL,
                description="Run and fail on purpose: a successful call whose result is an error.",
                inputSchema={"type": "object", "properties": {}, "additionalProperties": False},
            ),
            types.Tool(
                name=TOOL_SLOW,
                description="Take long enough to be cancelled while it runs.",
                inputSchema={
                    "type": "object",
                    "properties": {"seconds": {"type": "number"}},
                    "additionalProperties": False,
                },
            ),
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> Any:
        side.event("call_tool", tool=name)
        if name == TOOL_ECHO:
            # A plain content list: the SDK wraps it in a CallToolResult with
            # isError absent, which is what a successful tool call looks like.
            return [types.TextContent(type="text", text=str(arguments.get("text", "")))]
        if name == TOOL_FAIL:
            # A tool that ran and failed. The specification carries this inside
            # the result, and it is a different thing from a JSON-RPC error.
            return types.CallToolResult(
                content=[types.TextContent(type="text", text="deliberate tool failure")],
                isError=True,
            )
        if name == TOOL_SLOW:
            seconds = float(arguments.get("seconds", args.slow_seconds))
            entered()
            try:
                await anyio.sleep(seconds)
            except anyio.get_cancelled_exc_class():
                # The SDK's `RequestResponder.cancel` cancels the scope this
                # sleep runs in, so landing here is the SDK acting on the
                # notification rather than the wire merely carrying it.
                side.event("slow_cancelled")
                raise
            # Reached only when nothing cancelled the handler. The absence of
            # `slow_completed` in the side channel is the negative evidence.
            side.event("slow_completed")
            return [types.TextContent(type="text", text="slow tool finished")]

        # A tool this peer does not have. The SDK's `call_tool` wrapper turns
        # any exception into an isError result, which is the specification's
        # rule for a tool failure and is deliberately not a JSON-RPC error.
        raise McpError(types.ErrorData(code=types.INVALID_PARAMS, message=f"no tool named {name}"))

    async def main() -> None:
        async with stdio_server() as (read_stream, write_stream):
            side.event("serve_begin")
            await server.run(read_stream, write_stream, server.create_initialization_options())
        side.event("serve_end")

    try:
        anyio.run(main)
    except KeyboardInterrupt:  # pragma: no cover - a signal, not a scenario
        side.event("interrupted")
    finally:
        side.event("peer_exit")
        side.close()
    return 0


# --- the supervisor -------------------------------------------------------------


class Capture:
    """The raw wire, one file per direction, byte for byte.

    Nothing is reformatted on the way in: what the supervisor writes is what
    crossed the pipe, which is the only claim worth making about a capture. The
    bound is a cap on evidence, and reaching it fails the run rather than
    quietly recording a prefix and calling it a pass.
    """

    def __init__(self, path: Path, limit: int) -> None:
        self._handle = path.open("wb")
        self._limit = limit
        self._written = 0
        self.truncated = False

    def write(self, data: bytes) -> None:
        if self._written >= self._limit:
            self.truncated = True
            return
        room = self._limit - self._written
        if len(data) > room:
            self._handle.write(data[:room])
            self._written = self._limit
            self.truncated = True
            return
        self._handle.write(data)
        self._written += len(data)

    @property
    def written(self) -> int:
        """How many bytes this capture holds, which is where a frame's byte
        offset is counted from."""
        return self._written

    def close(self) -> int:
        self._handle.close()
        return self._written


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def close_fd(stream: Any) -> None:
    if stream is None:
        return
    try:
        stream.close()
    except OSError:  # pragma: no cover - already closed
        pass


def terminate(process: subprocess.Popen[bytes], grace: float) -> int | None:
    """Kill a child's whole process group, then reap it. Never leaves an orphan."""
    if process.poll() is not None:
        return process.returncode
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):  # pragma: no cover - already gone
        process.kill()
    try:
        return process.wait(timeout=grace)
    except subprocess.TimeoutExpired:  # pragma: no cover - SIGKILL is not refusable
        return None


class Stamp(NamedTuple):
    """One relay write: which direction, which of its bytes, and when.

    `start` and `stop` are offsets into that direction's capture, `order` is
    this relay's write sequence and `at` is the clock when the write was made.
    """

    direction: str
    start: int
    stop: int
    order: int
    at: float


class Chronology:
    """When each byte of each direction crossed the relay.

    Two indices into two captures are not comparable: the fourth frame from
    the client and the second from the server say nothing about which came
    first, and a check that pretends otherwise passes for a reason unrelated
    to the exchange. What does compare is the order this relay wrote the two
    in, because it wrote them one at a time to the same pipe — bytes handed
    over earlier were in the pipe before the later write began, so the reader
    at the far end had them first. Every "after" claim below is made from that,
    and from nothing else.

    One read carries whatever frames had arrived by the time it ran, so the
    write's sequence number alone does not order two frames it carried
    together: it calls them equal, and a claim made from it would fail a
    correct run for the wrong reason. The byte offset inside the write is what
    orders them, because a pipe is a FIFO byte stream and the lower offset was
    in the pipe first. `position` is the pair, and it is what every "after"
    claim is made from.
    """

    def __init__(self, stamps: list[Stamp]) -> None:
        self._stamps = stamps

    def at(self, frame: "Frame") -> Stamp:
        """The write that put a frame's first byte on its way."""
        for stamp in self._stamps:
            if stamp.direction == frame.direction and stamp.start <= frame.offset < stamp.stop:
                return stamp
        raise InteropFailure(
            f"the {frame.direction} frame at byte {frame.offset} belongs to no relay write, so "
            f"nothing in this run can say when it crossed"
        )

    def position(self, frame: "Frame") -> tuple[int, int]:
        """Where a frame sits in the relay's own order: its write, then its byte.

        The sequence number of the write that carried this frame's first byte,
        and the frame's offset inside that write. The number orders two frames
        the relay wrote in different reads; the offset orders two frames that
        one read carried together, which the number alone calls equal. The two
        frames are then compared as a pair, and never one index against an
        index into a different capture.
        """
        stamp = self.at(frame)
        return stamp.order, frame.offset - stamp.start

    def require_after(self, earlier: "Frame", later: "Frame", claim: str) -> None:
        """Whether `later` reached the relay after `earlier` did."""
        first = self.at(earlier)
        second = self.at(later)
        first_write, first_byte = self.position(earlier)
        second_write, second_byte = self.position(later)
        require(
            (first_write, first_byte) < (second_write, second_byte),
            f"{claim}: {describe(earlier)} was written by the relay at {first.at:.6f} as write "
            f"{first_write} byte {first_byte}, and {describe(later)} at {second.at:.6f} as write "
            f"{second_write} byte {second_byte}, so the second crossed "
            f"{second.at - first.at:+.6f}s relative to the first and is the wrong way round in "
            f"the relay's own order. Two indices into two different captures cannot order these; "
            f"this is the relay's write sequence and, where one read carried both, the byte "
            f"offset inside it, because a pipe is a FIFO byte stream.",
        )

    def gap(self, earlier: "Frame", later: "Frame") -> float:
        """How many seconds the relay took between two frames, for a finding."""
        return self.at(later).at - self.at(earlier).at


class Relay:
    """Byte for byte between the two children, with the capture as a tee.

    Each direction is read from one child's stdout and written to the other's
    stdin, unmodified, so what each peer sees is the other's bytes exactly. A
    closed pipe on one side closes the far side's stdin, which is how end of
    file reaches the peer: the peer is never told to stop, it is only left
    without input, which is the thing under test.
    """

    def __init__(self, peer: subprocess.Popen[bytes], zig: subprocess.Popen[bytes],
                 client_to_server: Capture, server_to_client: Capture,
                 deadline: float, budget: float, stamps: list[Stamp]) -> None:
        self._peer = peer
        self._zig = zig
        self._captures = {"c2s": client_to_server, "s2c": server_to_client}
        # The instant the exchange must be finished by, and the number of
        # seconds it was given: one to compare against the clock, one to say
        # in the failure.
        self._deadline = deadline
        self._budget = budget
        self._selector = selectors.DefaultSelector()
        self._open: set[str] = set()
        self.failure: str | None = None
        # One stamp per write, appended as the write happens and shared with
        # the checks below. This is the run's only ordering evidence: an index
        # into one capture says nothing about where a frame sits in the other.
        # One read carries whatever frames had arrived when it ran, so a write's
        # `order` alone does not order two frames inside it — `Chronology.position`
        # pairs it with the frame's byte offset in the write, and that pair is
        # what every "after" claim is made from.
        self.stamps = stamps
        self._order = 0

    def run(self) -> None:
        assert self._peer.stdout is not None and self._zig.stdout is not None
        assert self._peer.stdin is not None and self._zig.stdin is not None
        self._selector.register(self._peer.stdout, selectors.EVENT_READ, ("s2c", self._zig.stdin))
        self._selector.register(self._zig.stdout, selectors.EVENT_READ, ("c2s", self._peer.stdin))
        self._open = {"c2s", "s2c"}

        while self._open and self.failure is None:
            remaining = self._deadline - time.monotonic()
            if remaining <= 0:
                self.failure = f"the exchange did not finish within {self._budget}s"
                break
            for key, _ in self._selector.select(timeout=min(remaining, 0.5)):
                direction, downstream = key.data
                # The descriptor again: the selector watches the file object's
                # descriptor and the bytes come off that same one, so nothing
                # is read through a buffer that would hold bytes back.
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    self._selector.unregister(key.fileobj)
                    self._open.discard(direction)
                    close_fd(downstream)
                    continue
                start = self._captures[direction].written
                self._captures[direction].write(data)
                try:
                    # The descriptor, not the file object: the pipe is written
                    # here and nowhere else, so nothing can be sitting in a
                    # buffer this code does not know about.
                    write_all(downstream.fileno(), data)
                except (BrokenPipeError, OSError) as exc:
                    self.failure = f"writing the {direction} direction failed: {exc}"
                    break
                # Stamped after the write, because that is the claim the stamp
                # can carry: these bytes were on their way to the far side
                # before the next write began. A stamp taken before the write
                # would record an order this process had not committed to.
                self._order += 1
                self.stamps.append(
                    Stamp(direction, start, start + len(data), self._order, time.monotonic()))

    def finish(self) -> None:
        self._selector.close()
        for process in (self._peer, self._zig):
            close_fd(process.stdin)
            close_fd(process.stdout)
        if self.failure is not None:
            raise InteropFailure(self.failure)


def wait_for(process: subprocess.Popen[bytes], deadline: float) -> int:
    try:
        return process.wait(timeout=max(deadline - time.monotonic(), 0.1))
    except subprocess.TimeoutExpired:
        code = terminate(process, 5.0)
        raise InteropFailure(
            f"a child did not exit within the deadline; killed and reaped, exit {code}"
        ) from None


def require_zig_binary(args: argparse.Namespace) -> Path:
    zig_binary = Path(args.zig_binary)
    require(
        zig_binary.exists(),
        f"the Zig participant is not at {zig_binary}. It is an executable target and build.zig "
        f"belongs to the integration owner, so build it first:\n"
        f"  zig build interop-mcp\n"
        f"which installs zig-out/bin/{zig_binary.name}, or point --zig-binary at an existing one.",
    )
    return zig_binary


def run_supervise(args: argparse.Namespace) -> int:
    pins = load_pins(args.pins)
    record = check_pins(pins, "mcp")
    zig_binary = require_zig_binary(args)
    work = WorkDir(args.work_dir, args.work_dir_prefix)
    try:
        return supervise_run(args, pins, record, zig_binary, work)
    finally:
        # Every path out, a failed check included: a generated work directory
        # belongs to this run and to nobody else.
        remove_temporary(work)


def supervise_run(args: argparse.Namespace, pins: dict[str, Any], record: dict[str, Any],
                   zig_binary: Path, work: WorkDir) -> int:
    peer_report = work / "peer-events.jsonl"
    slow_marker = work / "slow-tool-entered.json"
    zig_report = work / "zig-report.json"

    # A named evidence directory may be reused. The marker certifies this run,
    # not a previous slow call whose captures the new run is about to replace.
    slow_marker.unlink(missing_ok=True)

    limit = int(pins.get("limits", {}).get("capture_bytes_per_direction", 262144))
    client_to_server = Capture(work / "wire-client-to-server.log", limit)
    server_to_client = Capture(work / "wire-server-to-client.log", limit)
    peer_log = BoundedLog(work / "peer-stderr.log", limit)
    zig_log = BoundedLog(work / "zig-stderr.log", limit)

    # The flag is a number of seconds, as the pin file's
    # limits.deadline_seconds_default says, while the relay and the waits want
    # an instant on the same clock. Converted once, here.
    deadline = time.monotonic() + args.deadline

    peer: subprocess.Popen[bytes] | None = None
    zig: subprocess.Popen[bytes] | None = None
    drains: list[threading.Thread] = []
    # Filled by the relay as it writes, and read by the checks: what crossed,
    # in which direction, and in what order.
    stamps: list[Stamp] = []
    started = time.monotonic()
    try:
        peer = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--role", "serve",
             "--pins", str(args.pins), "--report", str(peer_report),
             "--slow-entered-file", str(slow_marker), "--slow-seconds", str(args.slow_seconds)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        drains.append(pump(peer.stderr, peer_log))
        zig = subprocess.Popen(
            [str(zig_binary), "--slow-entered-file", str(slow_marker),
             "--report-file", str(zig_report)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        drains.append(pump(zig.stderr, zig_log))
        require(peer.stdin is not None and peer.stdout is not None, "the peer's pipes were not created")
        require(zig.stdin is not None and zig.stdout is not None, "the Zig client's pipes were not created")

        relay = Relay(peer, zig, client_to_server, server_to_client, deadline, args.deadline, stamps)
        relay.run()
        relay.finish()

        peer_code = wait_for(peer, deadline)
        zig_code = wait_for(zig, deadline)
    finally:
        for process in (peer, zig):
            if process is not None and process.poll() is None:
                terminate(process, 5.0)
        for drain in drains:
            # End of file arrives when the child the pipe belongs to is gone.
            # The join is bounded so a pipe that somehow outlives its child
            # cannot hold the run open, and the log is capped either way.
            drain.join(timeout=2.0)
        c2s_bytes = client_to_server.close()
        s2c_bytes = server_to_client.close()
        peer_log.close()
        zig_log.close()

    elapsed = round(time.monotonic() - started, 3)
    require(peer_code == 0,
            f"the peer exited with {peer_code}; {stderr_note(peer_log, work, 'the peer')}")
    require(zig_code == 0,
            f"the Zig client exited with {zig_code}; "
            f"{stderr_note(zig_log, work, 'the Zig client')}")
    require(
        not client_to_server.truncated and not server_to_client.truncated,
        f"the capture hit its {limit}-byte bound; raise limits.capture_bytes_per_direction in "
        f"the pin file or the evidence is incomplete",
    )
    require(
        not peer_log.truncated and not zig_log.truncated,
        f"a child's stderr hit the {limit}-byte bound, so what it said is only a prefix. "
        f"Raise limits.capture_bytes_per_direction in the pin file; an incomplete record of a "
        f"run is not a passing one.",
    )
    for produced in (peer_report, zig_report):
        require_bounded_size(produced, limit)

    c2s = parse_frames((work / "wire-client-to-server.log").read_bytes(), "client to server", "c2s")
    s2c = parse_frames((work / "wire-server-to-client.log").read_bytes(), "server to client", "s2c")
    chronology = Chronology(stamps)
    findings = check_exchange(c2s, s2c, chronology, SideChannel.read(peer_report), zig_report)

    # Every frame with the write that carried it and the byte it starts at
    # inside that write, because one read routinely carries several frames and
    # a row carrying only the write number cannot show the order this run
    # checked. One row per frame, which the capture bound caps.
    timeline: list[dict[str, Any]] = []
    for frame in [*c2s, *s2c]:
        write, byte_in_write = chronology.position(frame)
        timeline.append({
            "frame": describe(frame),
            "direction": frame.direction,
            "byte": frame.offset,
            "order": write,
            "byte_in_write": byte_in_write,
            "ms_after_first_write": round((chronology.at(frame).at - stamps[0].at) * 1000, 3),
        })

    summary = {
        "sdk": {"distribution": "mcp", "version": record["version"], "protocol": REVISION,
                "source": record["nix"]["src"]},
        "zig_participant": str(zig_binary),
        "work_dir": str(work.path),
        "work_dir_kept": not work.temporary,
        "elapsed_seconds": elapsed,
        "bytes": {"client_to_server": c2s_bytes, "server_to_client": s2c_bytes},
        "frames": {"client_to_server": len(c2s), "server_to_client": len(s2c)},
        "peer_events": SideChannel.read(peer_report),
        # The timeline computed above, which is the same ordering evidence the
        # checks above were made from.
        "relay_writes": timeline,
        "findings": findings,
        "capture": {
            "client_to_server": str(work / "wire-client-to-server.log"),
            "server_to_client": str(work / "wire-server-to-client.log"),
        },
    }
    (work / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print(f"mcp interop: mcp {record['version']}, revision {REVISION}, {elapsed}s")
    print(f"  wire: {len(c2s)} client frames, {len(s2c)} server frames, "
          f"{c2s_bytes} + {s2c_bytes} bytes captured")
    for finding in findings:
        print(f"  - {finding}")
    print(work.notice())
    return 0


# --- the checks -----------------------------------------------------------------


class Frame(NamedTuple):
    """One JSON-RPC frame, where it sat in its capture, and which way it went."""

    direction: str
    offset: int
    end: int
    body: dict[str, Any]


def refuse_constant(name: str) -> Any:
    """`NaN`, `Infinity` and `-Infinity` are refused rather than parsed."""
    raise InteropFailure(f"the wire carried {name}, which JSON does not have")


def parse_frames(raw: bytes, label: str, direction: str) -> list[Frame]:
    """Every line of a capture is one JSON-RPC frame, and nothing else is allowed.

    The framing is checked as bytes, not taken on trust from the parse. NDJSON
    separates frames with newlines and permits none inside one, so a frame
    carrying a raw newline in its params — a newline spliced into the params of
    `initialize` is exactly how this exchange failed the first time it ran —
    arrives here as two lines that are not JSON values. A capture that is not a
    whole number of delimited lines is refused for the same reason rather than
    read as the frames it happens to contain.

    There is no separate scan for raw control bytes, and adding one would be a
    mistake rather than belt and braces. Tab and carriage return are JSON
    whitespace (RFC 8259 section 2), so a peer that separates tokens with a
    tab or terminates its frames with CRLF has written a frame this function
    is here to accept, and a scan that refused them would refuse a correct
    peer. Every other byte below 0x20 is already refused by the strict parse
    below: it rejects a control character inside a string, and outside one it
    can only read a byte that is not the start of a value as an error. The
    check for a whole number of delimited lines is the one that proves the
    capture is whole frames rather than a prefix of the exchange, and it stays.
    """
    require(raw != b"", f"the {label} capture is empty: nothing crossed this way at all")
    lines = raw.split(b"\n")
    require(
        lines[-1] == b"",
        f"the {label} capture does not end with a delimiter: its last {len(lines[-1])} bytes are a "
        f"frame nothing closed, so the capture is a prefix of the exchange rather than the exchange",
    )
    frames: list[Frame] = []
    offset = 0
    for number, line in enumerate(lines[:-1], start=1):
        if not line:
            offset += 1
            continue
        try:
            body = json.loads(line.decode("utf-8"), parse_constant=refuse_constant)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise InteropFailure(
                f"{label} line {number} is not one JSON value, so the stream carried bytes that "
                f"are not frames: {exc}. A frame whose params carry a raw newline is split across "
                f"lines exactly like this, and NDJSON permits no newline inside a frame: {line[:200]!r}"
            ) from exc
        require(isinstance(body, dict), f"{label} line {number} is not a JSON-RPC object")
        frames.append(Frame(direction, offset, offset + len(line), body))
        offset += len(line) + 1
    return frames


def describe(frame: Frame) -> str:
    """What to call a frame in a message: its direction, its method and where
    it sat, because none of those identifies a frame on its own."""
    way = "to server" if frame.direction == "c2s" else "to client"
    method = frame.body.get("method") or "answer"
    return f"{way} {method} at byte {frame.offset}"


def requests_of(frames: list[Frame], method: str) -> list[Frame]:
    return [frame for frame in frames
            if frame.body.get("method") == method and "id" in frame.body]


def answer_for(server_frames: list[Frame], request_id: Any) -> Frame:
    for frame in server_frames:
        if "method" not in frame.body and frame.body.get("id") == request_id:
            return frame
    raise InteropFailure(f"the peer never answered request id {request_id!r}")


def call_frame(client_frames: list[Frame], tool: str) -> Frame:
    """The `tools/call` that named a tool, found by its own params rather than
    by its position: every call in this exchange is the same method."""
    for frame in requests_of(client_frames, "tools/call"):
        if frame.body.get("params", {}).get("name") == tool:
            return frame
    raise InteropFailure(f"the client never called the {tool!r} tool")


def check_exchange(client_frames: list[Frame], server_frames: list[Frame],
                   chronology: Chronology, peer_events: list[dict[str, Any]],
                   zig_report: Path) -> list[str]:
    """What the wire has to say, read from the wire.

    Every claim below comes from the captures or from the peer's own side
    channel. The Zig client's report is checked against both at the end, never
    used as the evidence for any of them: a participant's report says what it
    believes happened, and a run that believed the right thing for the wrong
    reason has proved nothing.
    """
    findings: list[str] = []
    # One answer per request. A peer that answered an id twice would let every
    # lookup below read the first of them and pass on a wire that carried a
    # duplicate.
    answered = [frame.body.get("id") for frame in server_frames if "method" not in frame.body]
    require(len(set(answered)) == len(answered),
            f"the peer answered an id more than once: {answered}")

    # 1. The revision is negotiated, and it is the one this exchange is pinned to.
    initialize = requests_of(client_frames, "initialize")
    require(len(initialize) == 1, f"expected exactly one initialize, saw {len(initialize)}")
    handshake = initialize[0]
    answer = answer_for(server_frames, handshake.body["id"])
    require("result" in answer.body, f"initialize was refused: {json.dumps(answer.body)[:200]}")
    negotiated = answer.body["result"].get("protocolVersion")
    require(negotiated == REVISION, f"the peer negotiated {negotiated!r}, the pin is {REVISION!r}")
    require(bool(answer.body["result"].get("serverInfo")),
            "the initialize result carried no serverInfo")
    require("tools" in answer.body["result"].get("capabilities", {}),
            "the peer advertised no tools capability")
    require(handshake.body.get("params", {}).get("protocolVersion") == REVISION,
            f"the client asked for {handshake.body.get('params', {}).get('protocolVersion')!r}, "
            f"not the revision this run is pinned to")
    findings.append(f"initialize negotiated {negotiated} with tools advertised")

    # 2. notifications/initialized travels, after the answer to initialize and
    #    before everything that depends on it.
    #
    #    These three frames sit in two captures, and an index into one of them
    #    says nothing about the other: comparing two such indices passes or
    #    fails for a reason that has nothing to do with the exchange. Every
    #    ordering claim here is the relay's own write order instead.
    initialized = [frame for frame in client_frames
                   if frame.body.get("method") == "notifications/initialized"]
    require(len(initialized) == 1, f"expected one notifications/initialized, saw {len(initialized)}")
    ready = initialized[0]
    chronology.require_after(handshake, answer, "the peer's answer to initialize")
    chronology.require_after(answer, ready,
                             "notifications/initialized went out before the initialize answer arrived")
    dependent = requests_of(client_frames, "tools/list") + requests_of(client_frames, "tools/call")
    require(dependent, "the client asked for nothing that depends on the handshake")
    for frame in dependent:
        chronology.require_after(ready, frame, f"a dependent request went out too early: {frame.body['method']}")
    findings.append(
        f"the peer's initialize answer crossed the relay "
        f"{chronology.gap(handshake, answer) * 1000:.0f}ms after the request, and "
        f"notifications/initialized and all {len(dependent)} dependent requests crossed after that"
    )

    # 3. Request ids are monotonic and never reused.
    ids = [frame.body["id"] for frame in client_frames if "method" in frame.body and "id" in frame.body]
    require(all(isinstance(value, int) and not isinstance(value, bool) for value in ids),
            f"the client's request ids are not all integers: {ids}")
    require(ids == sorted(ids), f"the client's request ids are not monotonic: {ids}")
    require(len(set(ids)) == len(ids), f"a request id was reused: {ids}")

    # 4. tools/list answered with the peer's three tools.
    listed = requests_of(client_frames, "tools/list")
    require(len(listed) == 1, f"expected exactly one tools/list, saw {len(listed)}")
    list_answer = answer_for(server_frames, listed[0].body["id"])
    require("result" in list_answer.body, f"tools/list was refused: {json.dumps(list_answer.body)[:200]}")
    names = [tool.get("name") for tool in list_answer.body["result"].get("tools", [])]
    for expected in (TOOL_ECHO, TOOL_FAIL, TOOL_SLOW):
        require(expected in names, f"tools/list did not offer {expected!r}: {names}")
    findings.append(f"tools/list offered {', '.join(str(name) for name in names)}")

    # 5. A successful call, a tool failure and a peer error are three different shapes.
    calls = requests_of(client_frames, "tools/call")
    require(len(calls) >= 4, f"expected at least four tools/call requests, saw {len(calls)}")

    # The echo is checked against the text that went out. "The answer had
    # content in it" would pass for a peer that returned any content at all,
    # which is not what this tool is on the wire to prove.
    echo_call = call_frame(client_frames, TOOL_ECHO)
    sent_text = echo_call.body.get("params", {}).get("arguments", {}).get("text")
    require(isinstance(sent_text, str) and sent_text != "",
            f"the {TOOL_ECHO!r} call carried no text argument: {json.dumps(echo_call.body)[:200]}")
    echo_answer = answer_for(server_frames, echo_call.body["id"])
    require("result" in echo_answer.body, f"the echo call was refused: {json.dumps(echo_answer.body)[:200]}")
    require(not echo_answer.body["result"].get("isError", False),
            "a successful tool call came back with isError")
    blocks = echo_answer.body["result"].get("content")
    require(isinstance(blocks, list) and blocks, "a successful tool call carried no content array")
    echoed = [block.get("text") for block in blocks
              if isinstance(block, dict) and block.get("type") == "text"]
    require(echoed == [sent_text],
            f"the {TOOL_ECHO!r} tool was sent {sent_text!r} and answered {echoed!r}")
    findings.append(f"the {TOOL_ECHO!r} tool answered with the text that went out, {sent_text!r}")

    fail_call = call_frame(client_frames, TOOL_FAIL)
    fail_answer = answer_for(server_frames, fail_call.body["id"])
    require("result" in fail_answer.body, f"the failing tool call was refused: {json.dumps(fail_answer.body)[:200]}")
    require(fail_answer.body["result"].get("isError") is True,
            f"a tool that failed did not answer with isError: {json.dumps(fail_answer.body)[:200]}")
    require("error" not in fail_answer.body,
            "a tool failure carried a JSON-RPC error member as well as isError, so the two could "
            "not be told apart")
    findings.append("a failing tool came back as result.isError with no error member")

    # The malformed call's own id, not the first error on the wire: the
    # cancelled call below is an error answer too, and a check that took
    # whichever arrived first would pass for the wrong reason.
    malformed = malformed_call(client_frames)
    peer_error = answer_for(server_frames, malformed.body["id"])
    require(isinstance(peer_error.body.get("error"), dict),
            f"the malformed tools/call was not answered with a JSON-RPC error: {peer_error.body}")
    require("result" not in peer_error.body, f"an error answer also carried a result: {peer_error.body}")
    invalid_code = peer_error.body["error"].get("code")
    require(invalid_code == INVALID_PARAMS,
            f"a tools/call whose params omit the required name was refused with code {invalid_code!r}, "
            f"and the SDK's own validation answers with {INVALID_PARAMS}")
    findings.append(
        f"a tools/call with no name came back as a JSON-RPC error, code {invalid_code}, "
        f"with no result member"
    )

    # 6. The cancellation, as the SDK acted on it.
    slow_call = call_frame(client_frames, TOOL_SLOW)
    cancels = [frame for frame in client_frames
               if frame.body.get("method") == "notifications/cancelled"
               and frame.body.get("params", {}).get("requestId") == slow_call.body["id"]]
    require(len(cancels) == 1, f"expected one cancellation for the slow call, saw {len(cancels)}")
    cancelled_answer = answer_for(server_frames, slow_call.body["id"])
    require("result" not in cancelled_answer.body,
            f"the cancelled call came back with a result, so it was answered as if it had run to "
            f"completion: {json.dumps(cancelled_answer.body)[:200]}")
    require(isinstance(cancelled_answer.body.get("error"), dict),
            f"the cancelled call was not answered with an error at all: {json.dumps(cancelled_answer.body)[:200]}")
    cancelled_code = cancelled_answer.body["error"].get("code")
    require(cancelled_code == REQUEST_CANCELLED,
            f"the cancelled call was answered with code {cancelled_code!r}, and the SDK answers a "
            f"cancelled id with {REQUEST_CANCELLED}")
    # The cancellation has to travel after the request it names: an SDK drops a
    # cancellation for an id that is not in flight, and a check that only
    # looked for the frame would pass on a cancellation that arrived first.
    chronology.require_after(slow_call, cancels[0], "the cancellation went out before the request it names")
    chronology.require_after(cancels[0], cancelled_answer,
                             "the peer answered the cancelled call before the cancellation crossed")

    events = [event.get("event") for event in peer_events]
    require("slow_entered" in events,
            "the peer's slow tool never started, so no cancellation could have been acted on")
    require("slow_completed" not in events,
            "the peer's slow tool ran to completion after the cancellation, so the SDK did not act "
            "on it")
    require("slow_cancelled" in events,
            "the peer's slow tool finished without being interrupted, so the SDK carried the "
            "cancellation without applying it")
    # On the peer's own clock, which is one process and therefore comparable to
    # itself: the tool was entered before it was interrupted.
    entered_at = monotonic_of(peer_events, "slow_entered")
    interrupted_at = monotonic_of(peer_events, "slow_cancelled")
    require(interrupted_at is not None and entered_at is not None and entered_at <= interrupted_at,
            f"the peer reports its tool interrupted at {interrupted_at!r} and entered at "
            f"{entered_at!r}, which is not an interruption of anything")
    findings.append(
        f"the cancellation crossed {chronology.gap(slow_call, cancels[0]) * 1000:.0f}ms after the "
        f"slow call went out, the SDK interrupted the in-flight handler and answered id "
        f"{slow_call.body['id']} with a peer error"
    )

    # 7. The peer saw end of file and shut itself down: its own session ended,
    #    which is what end of file on stdin looks like from inside the SDK.
    require("serve_end" in events,
            f"the peer's session never ended, so it never saw end of file: {events}")
    require("peer_exit" in events, f"the peer never recorded its exit: {events}")

    # 8. What the Zig client read, compared with the wire above. A disagreement
    #    means one of the two read the same bytes differently, which is worth
    #    more than either of them being right on its own.
    require(zig_report.exists(), f"the Zig client wrote no report: expected {zig_report}")
    zig = json.loads(zig_report.read_text(encoding="utf-8"))
    require(zig.get("failure") == "" and zig.get("ok") is True,
            f"the Zig client exited zero while reporting {zig.get('failure')!r} and "
            f"ok={zig.get('ok')!r}")
    require(zig.get("revision") == REVISION,
            f"the Zig client reports revision {zig.get('revision')!r}, not {REVISION!r}")
    require(zig.get("protocol_version") == negotiated,
            f"the Zig client reports the peer answered {zig.get('protocol_version')!r}, and the "
            f"wire says {negotiated!r}")
    require(zig.get("tools") == names,
            f"the Zig client reports the tools {zig.get('tools')!r}, and the wire says {names!r}")
    require(zig.get("tool_count") == len(names),
            f"the Zig client reports {zig.get('tool_count')!r} tools, and the wire carried {len(names)}")
    require(zig.get("echo_text") == sent_text,
            f"the Zig client reports the echo tool answered {zig.get('echo_text')!r}, and the "
            f"client sent {sent_text!r}")
    require(zig.get("fail_is_error") is True,
            f"the Zig client reports isError={zig.get('fail_is_error')!r} for the failing tool, and "
            f"the wire carries isError: true")
    require(zig.get("peer_error_code") == invalid_code,
            f"the Zig client reports the refusal code {zig.get('peer_error_code')!r}, and the wire "
            f"carries {invalid_code!r}")
    require(zig.get("cancelled_error_code") == cancelled_code,
            f"the Zig client reports the cancellation code {zig.get('cancelled_error_code')!r}, and "
            f"the wire carries {cancelled_code!r}")
    findings.append(
        "the Zig client's own decoder read the same revision, tool list, echo text and two error "
        "codes off the wire"
    )
    return findings


def monotonic_of(events: list[dict[str, Any]], name: str) -> float | None:
    """When the peer recorded one of its own events, on the peer's own clock."""
    for event in events:
        if event.get("event") == name:
            value = event.get("monotonic")
            if isinstance(value, (int, float)):
                return float(value)
    return None


def malformed_call(client_frames: list[Frame]) -> Frame:
    """The ``tools/call`` whose params name no tool.

    That is the call the peer has to refuse, and the refusal is bound to this
    frame's id so the check cannot be satisfied by some other error on the wire.
    """
    for frame in requests_of(client_frames, "tools/call"):
        if not frame.body.get("params", {}).get("name"):
            return frame
    raise InteropFailure("the client never sent a tools/call with no tool name")


# --- entry ----------------------------------------------------------------------

def run_preflight(args: argparse.Namespace) -> int:
    """Check where a run would write, with nothing else involved.

    No SDK, no child process, no pin check. This answers one question: whether
    the environment has somewhere for a generated work directory that is not a
    system temporary directory, and whether the generated case really is taken
    away afterwards. Both are proved rather than assumed — the directory is
    created, written to and removed here, exactly as a run does it.
    """
    if args.work_dir is not None:
        work = WorkDir(args.work_dir, args.work_dir_prefix)
        print(f"scratch: TMPDIR is {os.environ.get('TMPDIR', '<unset>')}, which a named work "
              f"directory does not need")
        print(f"  work directory: {work.path} (kept; a run leaves its capture and reports there)")
        return 0
    work = WorkDir(None, args.work_dir_prefix)
    (work / "preflight.txt").write_text(f"{MARKER}\n", encoding="utf-8")
    print(f"scratch: {work.path.parent}")
    work.discard()
    print(f"  generated, written to, and removed again: {work.path} "
          f"(exists now: {work.path.exists()})")
    return 0


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--role", choices=("supervise", "serve"), required=True)
    parser.add_argument("--pins", type=Path,
                        default=Path(os.environ.get("ZIG_AGENT_PROTO_SDK_PINS", DEFAULT_PINS)))
    parser.add_argument("--zig-binary", default="zig-out/bin/zig-agent-proto-mcp-interop",
                        help="the Zig MCP client executable; supervise only")
    parser.add_argument("--work-dir", default=None,
                        help="an absolute path outside /tmp and /var/tmp where the capture and "
                             "the reports are kept; a generated directory under TMPDIR otherwise, "
                             "removed when the run ends either way it went")
    parser.add_argument("--preflight", action="store_true",
                        help="check TMPDIR and the work-directory policy and exit, with no SDK, "
                             "no pins and no child process")
    parser.add_argument("--deadline", type=float, default=60.0,
                        help="seconds the whole exchange may take before it is killed")
    parser.add_argument("--slow-seconds", type=float, default=30.0,
                        help="how long the peer's slow tool sleeps when the call carries no "
                             "argument of its own. The Zig participant sends 30 and that is what "
                             "the peer sleeps, so this only applies to a call of its own making.")
    parser.add_argument("--report", type=Path, default=None, help="the peer's side channel; serve only")
    parser.add_argument("--slow-entered-file", type=Path, default=None,
                        help="the file the peer writes when its slow tool starts; serve only")
    parser.set_defaults(work_dir_prefix="mcp-interop-")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    try:
        if args.preflight:
            return run_preflight(args)
        if args.role == "serve":
            return run_serve(args)
        return run_supervise(args)
    except InteropFailure as failure:
        print(f"mcp interop FAILED: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
