#!/usr/bin/env python3
"""ACP interoperability peer, driven against the Zig participant.

Two roles, both in this one file because they are two ends of the same wire:

``--role serve``
    The peer itself: a genuine ``agent-client-protocol`` SDK agent (the pinned
    release) speaking ACP over this process's own stdin and stdout. It is
    started as a child process, so its stdout is the protocol stream and cannot
    carry a log line; its observations go to a side-channel file the supervisor
    names. There is no readiness line, because on a stdio transport standard
    output *is* the wire: a byte written there that is not a frame is a
    protocol violation, not a signal. What the supervisor waits for instead is
    the first frame, and its deadline covers the wait.

``--role supervise``
    Starts that peer and the Zig client as two children, relays bytes between
    them verbatim, records the raw wire, asserts what the exchange has to
    prove, and reaps everything on any path out — through ``process_guard.py``,
    which is shared with the other supervisors: politely first, and only ever
    against a pid whose ``/proc`` still shows the command line, the owner, the
    start time and a process group that is neither this harness's own nor any
    of this harness's ancestors', with every one of those read again before
    the signal that is not refusable goes out.

What the exchange proves, and how each claim is checked:

* the wire version is negotiated, not assumed: the client asks for the version
  this run names, the agent answers with its own ``acp.PROTOCOL_VERSION``, and
  the answer the SDK parsed is compared with the answer on the wire;
* ``initialize`` carries real capabilities in both directions. The client
  advertises exactly what its handler can serve, which the checks read as a
  claim with no ``true`` in it: a capability this participant cannot back is a
  lie the wire would carry. The agent answers with an ``agentCapabilities``
  object the SDK's own model produced, and the Zig client's own
  ``acp.decodeCapabilityObject`` reads it back;
* ``session/new`` and ``session/prompt`` are answered, and the prompt's text
  comes back out of the agent's ``session/update`` — the text that went in
  compared with the text that arrived, because a notification carrying content
  is not evidence the agent ran;
* the direction the protocol runs the other way works: while ``session/prompt``
  is in flight the agent calls ``session/request_permission`` on the client,
  and the Zig participant answers it from its reader task;
* the answer is a refusal and the refusal is real. Three independent
  observations, none of them the writer's own opinion: the captured answer
  frame carries ``{"outcome":{"outcome":"cancelled"}}`` and no ``optionId``
  anywhere; the peer parsed that answer with the SDK's own
  ``RequestPermissionResponse`` model and recorded ``outcome == "cancelled"``
  with no option id; and the Zig report's ``permission_grants`` is false while
  the offer it read did contain a granting option. An answer this participant
  could not have read is not one it can write — ``answerPermissionRequest``
  takes a decision rather than a choice, so its grant arm is a JSON-RPC error
  rather than an approval;
* the ordering is the relay's own: the permission request crossed after the
  prompt it belongs to, and the prompt's answer crossed after the permission
  answer. Two indices into two captures cannot order these; the relay's write
  sequence and, where one read carried both, the byte offset inside it, can;
* what the Zig client's own decoder read is compared with those same bytes at
  the end. The report is never the evidence for a claim, only something the
  wire can be asked to agree with;
* the peer sees end of file and exits, and is reaped. Nothing is left running.

No mocks, no fakes, no synthetic responses: the peer is the upstream SDK and
the wire is the bytes that crossed the pipes. Versions, hashes and the API
facts this file depends on are recorded in ``sdk-pins.json``, which both roles
read and check themselves against, so a run against an environment that does
not match the pins fails instead of quietly testing something else.

Where a run writes: the wire, the reports and the logs all go into one work
directory. Named with ``--work-dir``, it is kept, because a capture somebody
asked for is evidence. Otherwise it is created inside the environment's
``TMPDIR`` and removed when the run ends, on success and on failure alike, so a
run leaves nothing behind and reports which of the two it did instead of
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
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Iterable, NamedTuple

# The teardown of every child this file starts is shared with the other
# supervisors: one module decides which pids this run is allowed to signal
# and in what order, because four copies of that decision drift apart.
from process_guard import (Child, DeadlineMissed, Guard, ProcessGuardError, Stop,
                           refusals)

# Where a run's work directory comes from and who may take it away, shared for
# the same reason as the guard above: one place decides whether a directory may
# be written into and whether it may be removed, because four copies of that
# decision drift apart — and this one had drifted into four `rmtree` calls.
from workdir import (WorkDirRefused, approved_scratch_root, remove_directory,
                     require_named_directory, require_private_directory)

HERE = Path(__file__).resolve().parent
DEFAULT_PINS = HERE / "sdk-pins.json"

# The PyPI distribution the peer imports. Its import package is `acp`, so the
# distribution name and the name a reader would `import` are two different
# strings and this one is the one the pin file keys on.
DISTRIBUTION = "agent-client-protocol"

# A fixed marker, not a path or a hostname: the capture is kept as evidence, so
# it must not carry anything about the machine that produced it.
MARKER = "zig-agent-proto-acp-interop"

# Everything both ends agree on. The Zig client sends these literals; they are
# repeated here rather than negotiated, which is what a client and an agent do:
# the names and the text are the interface, and an interop run that agreed on
# them at runtime would be testing the agreement instead of the protocol.
CLIENT_NAME = MARKER
CLIENT_VERSION = "0.0.0"
WORKSPACE_CWD = "/zig-agent-proto-acp-interop"
PROMPT_TEXT = "zig-agent-proto"

# The ids the peer answers with. Fixed rather than generated, for the same
# reason the names above are: two captures taken from two runs are then
# comparable, and neither carries anything about the machine that produced it.
SESSION_ID = "zig-agent-proto-acp-interop-session"
MESSAGE_ID = "zig-agent-proto-acp-interop-message"
TOOL_CALL_ID = "zig-agent-proto-acp-interop-tool"
PERMISSION_TITLE = "zig-agent-proto permission"

# The two option ids the offer carries, and their kinds. The offer deliberately
# contains a granting option: a permission run in which the client had nothing
# to refuse would prove nothing about refusal.
ALLOW_OPTION_ID = "allow"
REJECT_OPTION_ID = "reject"
ALLOW_OPTION_KIND = "allow_once"
REJECT_OPTION_KIND = "reject_once"

# The stable wire version and the draft one. PROTOCOLS.md 6.1 makes 1 stable
# and 2 a draft, and the SDK's own `acp.PROTOCOL_VERSION` is 1; 2 is asked for
# only when this run names it.
STABLE_WIRE = 1
DRAFT_WIRE = 2

# The `protocolVersion` v2 requires in both directions, and the one member a v1
# `initialize` has that v2 does not: v2 carries the implementation in `info`
# and this library composes that itself, so the client never sends `clientInfo`
# by hand.
EXPECTED_CLIENT_INFO = {"name": CLIENT_NAME, "version": CLIENT_VERSION}


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
            f"pinned environment (`devenv shell`, then `interop-python`, or `interop-acp`)."
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


def require_draft_runtime(side: SideChannel, record: dict[str, Any]) -> Any:
    """The experimental v2 runtime, or the exact reason this run cannot have one.

    Wire 2 is a draft bound to an alpha upstream schema, and the SDK ships it
    behind an opt-in subpackage that only exists in the two pre-release
    artifacts. A run asked for wire 2 against an SDK without it is refused here,
    with the prerequisite written out, rather than silently spoken at wire 1 —
    a v1 run wearing a `--protocol-version 2` on the command line would be
    evidence for nothing.
    """
    try:
        from acp.experimental import v2
    except ImportError as exc:
        side.event("draft_runtime_missing")
        raise InteropFailure(
            f"ACP wire version {DRAFT_WIRE} was asked for and {DISTRIBUTION} {record['version']} "
            f"has no v2 runtime at all: the `acp.experimental` package does not exist at this "
            f"tag. The prerequisite is an SDK pinned to 1.0.0rc1 or 1.0.0rc2, the only releases "
            f"that carry `acp.experimental.v2` — and those are pre-releases. Wire 2 is a draft "
            f"(bound to the upstream schema tag schema-v2.0.0-alpha.5), so this run is refused "
            f"rather than faked at wire {STABLE_WIRE}."
        ) from exc
    side.event("draft_runtime_found", protocol_version=v2.PROTOCOL_VERSION)
    require(
        v2.PROTOCOL_VERSION == DRAFT_WIRE,
        f"the installed experimental runtime reports protocol version {v2.PROTOCOL_VERSION}, "
        f"not {DRAFT_WIRE}. Refusing to run against a runtime whose constant this peer "
        f"cannot vouch for.",
    )
    return v2


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
    """The only directory a generated work directory may be created in.

    The rule itself lives in `workdir`, because the repository's remover
    enforces the same one: a directory created anywhere it would refuse to
    remove is a directory this run could only ever leave behind.
    """
    try:
        return approved_scratch_root()
    except WorkDirRefused as refusal:
        raise InteropFailure(str(refusal)) from None


class WorkDir:
    """Where one run's evidence goes, and who may take it away afterwards.

    Generated or named, the only difference is who may keep it. A generated
    directory is removed when the run ends, on every path out, through the
    repository's own remover, which checks ownership, mode, volume, mount
    points and liveness before it removes anything. A named directory is a
    deliverable and is never removed by this run at all.
    """

    def __init__(self, requested: str | None, prefix: str) -> None:
        if requested is None:
            self.path = Path(tempfile.mkdtemp(prefix=prefix, dir=os.fspath(scratch_root())))
            self.temporary = True
            try:
                require_private_directory(self.path)
            except WorkDirRefused as refusal:
                raise InteropFailure(str(refusal)) from None
            return
        named = Path(requested)
        require(named.is_absolute(), f"--work-dir {requested!r} is not an absolute path")
        require(
            not is_system_temporary(named),
            f"--work-dir {requested!r} is a system temporary directory, which is shared with "
            f"every process on the host. If you want the capture kept, name a directory on "
            f"this machine's own storage.",
        )
        # Checked before anything is written, not after: the wire and the
        # reports go into this directory, so a directory this account does not
        # own is a write into somebody else's storage whatever happens to it
        # afterwards, and a symlink means the bytes land somewhere the name
        # does not describe.
        try:
            require_named_directory(named)
        except WorkDirRefused as refusal:
            raise InteropFailure(str(refusal)) from None
        self.path = named
        self.temporary = False
        self.path.mkdir(parents=True, exist_ok=True)

    def __truediv__(self, name: str) -> Path:
        return self.path / name

    def notice(self) -> str:
        """What to print about this directory: a policy, not an outcome.

        Deliberately silent about removal. This supervisor prints this before
        the removal has run at all, so a line claiming the directory is gone
        would be claiming something that has not happened — and on a refusal it
        would keep claiming it. `remove_temporary` is what says whether it was.
        """
        if self.temporary:
            return (f"  temporary work directory, removed when the run ends: {self.path}\n"
                    f"  pass --work-dir <dir> to keep the wire capture and the reports")
        return f"  capture and reports: {self.path}"

    def discard(self) -> None:
        """Remove this generated directory through the repository's remover."""
        try:
            remove_directory(self.path)
        except WorkDirRefused as refusal:
            raise InteropFailure(str(refusal)) from None


def remove_temporary(work: WorkDir) -> None:
    """Take a generated work directory away, without ever hiding why a run failed.

    A refusal raises when the run was otherwise succeeding, because a directory
    this run could not take away means the run did not do what it says it did.
    It does not raise when the run was already failing: there it is a second
    finding rather than the reason the exchange failed, and it is printed
    beside the original instead of replacing it. That distinction is the whole
    point of this function — `main` catches `InteropFailure` and prints one
    line without a traceback, so raising from here during a failure would
    replace the line naming what actually went wrong with a line about a
    directory, and the real cause would survive only as context nothing prints.

    A named directory is a deliverable and is left alone whatever else is true.
    """
    if not work.temporary:
        return
    # Read before the attempt: inside the handler below, `sys.exc_info()`
    # reports this refusal rather than whatever the run is unwinding from.
    already_failing = sys.exc_info()[0] is not None
    try:
        work.discard()
    except InteropFailure as refusal:
        if not already_failing:
            raise
        print(f"  cleanup, reported beside the failure above: {refusal}", file=sys.stderr)
        return
    print(f"  temporary work removed: {work.path}")


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

    One fresh file per run, one JSON object per line, flushed per line: a line
    somebody reads has to be on the disk when they read it.
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
        self._handle.write(json.dumps(record, sort_keys=True, default=repr) + "\n")
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


def block_text(block: Any) -> str:
    """The text of one content block, however the SDK handed it over.

    A handler's parameters are expanded, so a block arrives as a model instance;
    the SDK's own example reads both shapes, and so does this, because a peer
    that read only one would fail on the other for a reason that has nothing to
    do with the protocol.
    """
    if isinstance(block, dict):
        return str(block.get("text", ""))
    return str(getattr(block, "text", ""))


def dump_model(model: Any) -> Any:
    """A model's own reading of a document, as the wire spellings.

    `exclude_none` and nothing else: the falses are the point, because a
    capability set of `false` everywhere and one of `true` somewhere are
    different claims and this record has to be able to tell them apart.
    """
    if model is None:
        return None
    return model.model_dump(mode="json", by_alias=True, exclude_none=True)


def permission_offer() -> list[tuple[str, str, str]]:
    """The (id, name, kind) triples this peer offers, shared by both versions.

    One offer, built once, because the two versions take the same three facts
    and a run whose v1 and v2 offers differed would be comparing two things
    rather than two revisions of one thing.
    """
    return [
        (ALLOW_OPTION_ID, "Allow once", ALLOW_OPTION_KIND),
        (REJECT_OPTION_ID, "Reject once", REJECT_OPTION_KIND),
    ]


def record_permission(side: SideChannel, response: Any, offered: list[tuple[str, str, str]]) -> dict[str, Any]:
    """What the SDK's own models made of the client's answer.

    Read through `RequestPermissionResponse` rather than through the bytes, so
    this is an independent observation: it is the SDK's decoder saying what the
    answer was, not this script re-reading its own encoder. The two facts the
    supervisor needs are the outcome's discriminator and whether it carried an
    option id, because an outcome with an id is a choice and one without is a
    cancellation.
    """
    outcome = response.outcome
    kind = getattr(outcome, "outcome", None)
    option_id = getattr(outcome, "option_id", None)
    granted = kind == "selected"
    facts = {
        "outcome": kind,
        "option_id": option_id,
        "granted": granted,
        "offered": [{"option_id": oid, "name": name, "kind": kind_} for oid, name, kind_ in offered],
    }
    side.event("permission_answer", **facts)
    return facts


async def serve_stable(args: argparse.Namespace, record: dict[str, Any], side: SideChannel) -> int:
    """The genuine SDK agent at the stable wire version, over this process's stdio."""
    import acp
    from acp.schema import (
        AgentCapabilities,
        AgentMessageChunk,
        Implementation,
        McpCapabilities,
        NewSessionResponse,
        PermissionOption,
        PromptCapabilities,
        PromptResponse,
        RequestPermissionResponse,
        TextContentBlock,
        ToolCallUpdate,
    )

    require(hasattr(acp, "InitializeResponse"),
            f"the installed SDK exports no InitializeResponse, so {DISTRIBUTION} "
            f"{record['version']} is not the API this peer was written against")

    require(acp.PROTOCOL_VERSION == STABLE_WIRE,
            f"the installed SDK's PROTOCOL_VERSION is {acp.PROTOCOL_VERSION}, not {STABLE_WIRE}")

    offered = permission_offer()

    class StableAgent(acp.Agent):
        """One prompt, one permission, no provider behind it.

        No live model is called and no external system is touched: the agent
        echoes what it was sent, asks the client one permission question with a
        fixed offer, and answers the prompt from what the client decided. That
        is enough to drive every frame the exchange needs, and it is why the
        run is deterministic.
        """

        def on_connect(self, conn: Any) -> None:
            self._conn = conn

        async def initialize(
            self,
            protocol_version: int,
            client_capabilities: Any = None,
            client_info: Any = None,
            **kwargs: Any,
        ) -> Any:
            side.event("initialize", protocol_version=protocol_version,
                       client_capabilities=dump_model(client_capabilities),
                       client_info=dump_model(client_info),
                       extra_keys=sorted(kwargs))
            # Real capabilities, all of them false: this agent serves
            # `session/new`, `session/prompt` and nothing else, and PROTOCOLS.md
            # 6.5 makes an unadvertised capability mean unsupported. The
            # `acp` member of `mcpCapabilities` is deliberately not set, so it
            # is absent from the wire rather than claimed.
            return acp.InitializeResponse(
                protocol_version=protocol_version,
                agent_capabilities=AgentCapabilities(
                    load_session=False,
                    prompt_capabilities=PromptCapabilities(
                        image=False, audio=False, embedded_context=False),
                    mcp_capabilities=McpCapabilities(http=False, sse=False),
                ),
                auth_methods=[],
                agent_info=Implementation(name=f"{MARKER}-peer", version=record["version"]),
            )

        async def new_session(
            self,
            cwd: str,
            additional_directories: list[Any] | None = None,
            mcp_servers: list[Any] | None = None,
            **kwargs: Any,
        ) -> Any:
            side.event("new_session", cwd=cwd,
                       additional_directories=additional_directories,
                       mcp_servers=mcp_servers, extra_keys=sorted(kwargs))
            require(cwd.startswith("/"), f"the client named a relative workspace root: {cwd!r}")
            return NewSessionResponse(session_id=SESSION_ID)

        async def prompt(self, session_id: str, prompt: list[Any], **kwargs: Any) -> Any:
            texts = [block_text(block) for block in prompt]
            side.event("prompt", session_id=session_id, blocks=texts,
                       extra_keys=sorted(kwargs))
            require(session_id == SESSION_ID,
                    f"the client prompted a session this peer never issued: {session_id!r}")

            # The ordinary agent-to-client notification, over the SDK's own API,
            # carrying the text that went out back. A notification with content
            # in it is not evidence the agent ran; the same text in both
            # directions is.
            await self._conn.session_update(
                session_id=session_id,
                update=AgentMessageChunk(
                    content=TextContentBlock(text=PROMPT_TEXT),
                ),
            )
            side.event("session_update_sent")

            # The direction this exchange exists for: the agent asking the
            # client, and the client's answer parsed by the SDK's own model.
            response: RequestPermissionResponse = await self._conn.request_permission(
                session_id=session_id,
                tool_call=ToolCallUpdate(tool_call_id=TOOL_CALL_ID, title=PERMISSION_TITLE),
                options=[
                    PermissionOption(option_id=oid, name=name, kind=kind)
                    for oid, name, kind in offered
                ],
            )
            facts = record_permission(side, response, offered)

            # The stop reason is the agent's own conclusion, not a constant: a
            # client that granted would get `end_turn`, and the supervisor's
            # check on that field is what tells the two runs apart.
            return PromptResponse(stop_reason="refusal" if not facts["granted"] else "end_turn")


    agent = StableAgent()
    try:
        await acp.run_agent(agent)
    except KeyboardInterrupt:  # pragma: no cover - a signal, not a scenario
        side.event("interrupted")
    return 0


async def serve_draft(args: argparse.Namespace, record: dict[str, Any], side: SideChannel,
                      v2: Any) -> int:
    """The same agent against the experimental v2 runtime, when it is asked for.

    Written against `acp.experimental.v2` rather than adapted from the v1
    agent, because the two revisions disagree on the contracts this exchange
    uses: v2 answers `session/prompt` with the id of the user message it
    inserted instead of a stop reason, its echo is a `user_message_chunk`
    rather than an `agent_message_chunk`, and `session/request_permission`
    takes a required `title` instead of a `toolCall`. The refusal the client
    sends is the same `{"outcome":{"outcome":"cancelled"}}` at both, which is
    the one thing a v1-to-v2 adapter would have to preserve and the reason the
    Zig participant's answer needs no branch.
    """
    schema = v2.schema
    require(hasattr(schema, "InitializeResponse"),
            "the experimental v2 runtime publishes no v2.schema.InitializeResponse")

    offered = permission_offer()

    class DraftAgent(v2.Agent):
        """The v1 agent's behaviour, spelled the way the draft schema spells it."""

        # Declared rather than assigned only inside `initialize`, so an
        # attribute lookup before the runtime hands the agent a connection
        # raises the AttributeError it would anywhere else rather than
        # silently answering `None`.
        _conn: Any = None

        def on_connect(self, conn: Any) -> None:
            self._conn = conn

        async def initialize(
            self,
            protocol_version: int,
            info: Any,
            capabilities: Any = None,
            **kwargs: Any,
        ) -> Any:
            side.event("initialize", protocol_version=protocol_version, info=dump_model(info),
                       capabilities=dump_model(capabilities), extra_keys=sorted(kwargs))
            return schema.InitializeResponse(
                protocol_version=v2.PROTOCOL_VERSION,
                info=schema.Implementation(name=f"{MARKER}-peer", version=record["version"]),
                # An empty capability object, present rather than absent: this
                # is the agent's real capability set — it serves `session/new`,
                # `session/prompt` and nothing else — and PROTOCOLS.md 6.5
                # makes an unadvertised capability mean unsupported, so the
                # Zig client's own decoder is given something to read.
                capabilities=schema.AgentCapabilities(),
            )

        async def new_session(
            self,
            cwd: str,
            additional_directories: list[Any] | None = None,
            mcp_servers: list[Any] | None = None,
            **kwargs: Any,
        ) -> Any:
            side.event("new_session", cwd=cwd,
                       additional_directories=additional_directories,
                       mcp_servers=mcp_servers, extra_keys=sorted(kwargs))
            require(cwd.startswith("/"), f"the client named a relative workspace root: {cwd!r}")
            return schema.NewSessionResponse(session_id=SESSION_ID)

        async def prompt(self, session_id: str, prompt: list[Any], **kwargs: Any) -> Any:
            texts = [block_text(block) for block in prompt]
            side.event("prompt", session_id=session_id, blocks=texts, extra_keys=sorted(kwargs))
            require(session_id == SESSION_ID,
                    f"the client prompted a session this peer never issued: {session_id!r}")

            # v2 asks the agent to echo the user message it inserted, carrying
            # the same id the prompt response will name.
            await self._conn.session_update(
                session_id=session_id,
                update=schema.UserMessageChunk(
                    message_id=MESSAGE_ID,
                    content=schema.TextContentBlock(text=PROMPT_TEXT),
                ),
            )
            side.event("session_update_sent")

            response = await self._conn.request_permission(
                session_id=session_id,
                title=PERMISSION_TITLE,
                options=[
                    schema.PermissionOption(option_id=oid, name=name, kind=kind)
                    for oid, name, kind in offered
                ],
            )
            record_permission(side, response, offered)
            # v2 has no stop reason: the response says the user message was
            # inserted, and the denial is visible in the side channel and on the
            # wire rather than in this member.
            return schema.PromptResponse(message_id=MESSAGE_ID)

    draft_agent = DraftAgent()
    try:
        await v2.run_agent(draft_agent)
    except KeyboardInterrupt:  # pragma: no cover - a signal, not a scenario
        side.event("interrupted")
    return 0


def run_serve(args: argparse.Namespace) -> int:
    """The genuine SDK agent, over this process's stdio."""
    import asyncio

    pins = load_pins(args.pins)
    record = check_pins(pins, DISTRIBUTION)

    import acp

    side = SideChannel(args.report)
    side.event(
        "peer_start",
        distribution=DISTRIBUTION,
        version=record["version"],
        sdk_protocol_version=acp.PROTOCOL_VERSION,
        requested_wire_version=args.protocol_version,
        python=sys.version.split()[0],
    )

    async def main() -> int:
        if args.protocol_version == DRAFT_WIRE:
            v2 = require_draft_runtime(side, record)
            return await serve_draft(args, record, side, v2)
        return await serve_stable(args, record, side)

    try:
        return asyncio.run(main())
    finally:
        side.event("peer_exit")
        side.close()


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


def wait_for(guard: Guard, child: Child, deadline: float) -> Stop:
    """Wait for a child to leave, and stop it if the deadline arrives first.

    The guard is what stops it on the way past, because it is the only thing in
    this run permitted to signal anything; this only says so in the words this
    run uses for a deadline miss.
    """
    try:
        return guard.wait(child, deadline)
    except DeadlineMissed as missed:
        raise InteropFailure(
            f"a {child.label} did not exit within the deadline; stopped with "
            f"{missed.stop.sent} and reaped, exit {missed.stop.exit}"
            f"{missed.stop.refusal_note}"
        ) from None


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

    Two indices into two captures are not comparable: the fourth frame from the
    client and the second from the agent say nothing about which came first, and
    a check that pretends otherwise passes for a reason unrelated to the
    exchange. What does compare is the order this relay wrote the two in,
    because it wrote them one at a time to the same pipe — bytes handed over
    earlier were in the pipe before the later write began, so the reader at the
    far end had them first. Every "after" claim below is made from that, and
    from nothing else.

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
        """Where a frame sits in the relay's own order: its write, then its byte."""
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
                 client_to_agent: Capture, agent_to_client: Capture,
                 deadline: float, budget: float, stamps: list[Stamp]) -> None:
        self._peer = peer
        self._zig = zig
        self._captures = {"c2a": client_to_agent, "a2c": agent_to_client}
        # The instant the exchange must be finished by, and the number of
        # seconds it was given: one to compare against the clock, one to say
        # in the failure.
        self._deadline = deadline
        self._budget = budget
        self._selector = selectors.DefaultSelector()
        self._open: set[str] = set()
        self.failure: str | None = None
        # One stamp per write, appended as the write happens and shared with
        # the checks below. This is the run's only ordering evidence.
        self.stamps = stamps
        self._order = 0

    def run(self) -> None:
        assert self._peer.stdout is not None and self._zig.stdout is not None
        assert self._peer.stdin is not None and self._zig.stdin is not None
        self._selector.register(self._peer.stdout, selectors.EVENT_READ, ("a2c", self._zig.stdin))
        self._selector.register(self._zig.stdout, selectors.EVENT_READ, ("c2a", self._peer.stdin))
        self._open = {"c2a", "a2c"}

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
                # before the next write began.
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


def require_zig_binary(args: argparse.Namespace) -> Path:
    zig_binary = Path(args.zig_binary)
    require(
        zig_binary.exists(),
        f"the Zig participant is not at {zig_binary}. It is an executable target and build.zig "
        f"belongs to the integration owner, so build it first:\n"
        f"  zig build interop-acp\n"
        f"which installs zig-out/bin/{zig_binary.name}, or point --zig-binary at an existing one.",
    )
    return zig_binary


def run_supervise(args: argparse.Namespace) -> int:
    pins = load_pins(args.pins)
    record = check_pins(pins, DISTRIBUTION)
    if args.protocol_version == DRAFT_WIRE:
        # Asked for before a child is started, so the prerequisite is the
        # answer rather than a child that exits with it.
        require_draft_runtime(SideChannel(None), record)
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
    zig_report = work / "zig-report.json"

    limit = int(pins.get("limits", {}).get("capture_bytes_per_direction", 262144))
    client_to_agent = Capture(work / "wire-client-to-agent.log", limit)
    agent_to_client = Capture(work / "wire-agent-to-client.log", limit)
    peer_log = BoundedLog(work / "peer-stderr.log", limit)
    zig_log = BoundedLog(work / "zig-stderr.log", limit)

    # The flag is a number of seconds, as the pin file's
    # limits.deadline_seconds_default says, while the relay and the waits want
    # an instant on the same clock. Converted once, here.
    deadline = time.monotonic() + args.deadline

    # The guard is built before either child exists, so a system where the
    # target checks cannot be read fails this run with nothing running rather
    # than half a teardown away.
    guard = Guard()
    peer_argv = [sys.executable, str(Path(__file__).resolve()), "--role", "serve",
                 "--pins", str(args.pins), "--report", str(peer_report),
                 "--protocol-version", str(args.protocol_version)]
    zig_argv = [str(zig_binary), "--protocol-version", str(args.protocol_version),
                "--report-file", str(zig_report)]

    peer: Child | None = None
    zig: Child | None = None
    drains: list[threading.Thread] = []
    # Filled by the relay as it writes, and read by the checks: what crossed,
    # in which direction, and in what order.
    stamps: list[Stamp] = []
    # How each child left, kept as evidence beside the wire it left with.
    stops: list[Stop] = []
    started = time.monotonic()
    try:
        peer = guard.spawn(
            peer_argv, "peer",
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        drains.append(pump(peer.process.stderr, peer_log))
        zig = guard.spawn(
            zig_argv, "Zig client",
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        drains.append(pump(zig.process.stderr, zig_log))
        require(peer.process.stdin is not None and peer.process.stdout is not None,
                "the peer's pipes were not created")
        require(zig.process.stdin is not None and zig.process.stdout is not None,
                "the Zig client's pipes were not created")

        relay = Relay(peer.process, zig.process, client_to_agent, agent_to_client,
                      deadline, args.deadline, stamps)
        relay.run()
        relay.finish()

        stops.append(wait_for(guard, peer, deadline))
        stops.append(wait_for(guard, zig, deadline))
    finally:
        for child in (peer, zig):
            # A child no wait has already accounted for. Decided from the list
            # rather than from `poll()`, which would reap and hand the pid back
            # before the guard has read it; a record that already says how this
            # child left is not worth a second row.
            if child is not None and not any(s.child == child.label for s in stops):
                stops.append(guard.stop(child, 5.0))
        for drain in drains:
            # End of file arrives when the child the pipe belongs to is gone.
            # The join is bounded so a pipe that somehow outlives its child
            # cannot hold the run open, and the log is capped either way.
            drain.join(timeout=2.0)
        c2a_bytes = client_to_agent.close()
        a2c_bytes = agent_to_client.close()
        peer_log.close()
        zig_log.close()

    exits = {stop.child: stop for stop in stops}
    require("peer" in exits and "Zig client" in exits,
            "a child was started but nothing recorded how it exited, so this run cannot say "
            f"whether the exchange completed: {[stop._asdict() for stop in stops]}")
    # A guard that refused left behind a process this run could not prove it
    # started, and reported it as such. Said here, before anything about exit
    # codes, because a refusal has no exit status to check.
    require(not refusals(stops),
            "this run could not prove a pid was the child it started, so it did not signal that "
            "process and cannot say the exchange ended: "
            + "; ".join(refusals(stops)))
    peer_stop = exits["peer"]
    zig_stop = exits["Zig client"]
    peer_code = peer_stop.exit
    zig_code = zig_stop.exit
    elapsed = round(time.monotonic() - started, 3)
    require(peer_code == 0,
            f"the peer exited with {peer_code}"
            + peer_stop.refusal_note
            + f"; {stderr_note(peer_log, work, 'the peer')}")
    require(zig_code == 0,
            f"the Zig client exited with {zig_code}"
            + zig_stop.refusal_note
            + f"; {stderr_note(zig_log, work, 'the Zig client')}")
    require(
        not client_to_agent.truncated and not agent_to_client.truncated,
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

    c2a = parse_frames((work / "wire-client-to-agent.log").read_bytes(), "client to agent", "c2a")
    a2c = parse_frames((work / "wire-agent-to-client.log").read_bytes(), "agent to client", "a2c")
    chronology = Chronology(stamps)
    findings = check_exchange(c2a, a2c, chronology, SideChannel.read(peer_report),
                              zig_report, args.protocol_version)

    # Every frame with the write that carried it and the byte it starts at
    # inside that write, because one read routinely carries several frames and
    # a row carrying only the write number cannot show the order this run
    # checked. One row per frame, which the capture bound caps.
    timeline: list[dict[str, Any]] = []
    for frame in [*c2a, *a2c]:
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
        "sdk": {"distribution": DISTRIBUTION, "version": record["version"],
                "wire_version": args.protocol_version,
                "source": record.get("nix", {}).get("src")},
        "zig_participant": str(zig_binary),
        "work_dir": str(work.path),
        "work_dir_kept": not work.temporary,
        "elapsed_seconds": elapsed,
        "bytes": {"client_to_agent": c2a_bytes, "agent_to_client": a2c_bytes},
        "frames": {"client_to_agent": len(c2a), "agent_to_client": len(a2c)},
        "peer_events": SideChannel.read(peer_report),
        # The timeline computed above, which is the same ordering evidence the
        # checks above were made from.
        "relay_writes": timeline,
        # How each child left, kept beside the wire it left with: the signals
        # that were sent, the status `waitpid` reported, and any refusal from
        # the target guards. A teardown that refused is evidence too, and a run
        # that hid one would be a run whose ending nobody could account for.
        "child_stops": [stop._asdict() for stop in stops],
        "findings": findings,
        "capture": {
            "client_to_agent": str(work / "wire-client-to-agent.log"),
            "agent_to_client": str(work / "wire-agent-to-client.log"),
        },
    }
    (work / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print(f"acp interop: {DISTRIBUTION} {record['version']}, wire version "
          f"{args.protocol_version}, {elapsed}s")
    print(f"  wire: {len(c2a)} client frames, {len(a2c)} agent frames, "
          f"{c2a_bytes} + {a2c_bytes} bytes captured")
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
    carrying a raw newline in its params arrives here as two lines that are not
    JSON values. A capture that is not a whole number of delimited lines is
    refused for the same reason rather than read as the frames it happens to
    contain.

    There is no separate scan for raw control bytes, and adding one would be a
    mistake rather than belt and braces. Tab and carriage return are JSON
    whitespace (RFC 8259 section 2), so a peer that terminates its frames with
    CRLF has written a frame this function is here to accept. Every other byte
    below 0x20 is already refused by the strict parse below. The check for a
    whole number of delimited lines is the one that proves the capture is whole
    frames rather than a prefix of the exchange, and it stays.
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
    way = "to agent" if frame.direction == "c2a" else "to client"
    method = frame.body.get("method") or "answer"
    return f"{way} {method} at byte {frame.offset}"


def requests_of(frames: list[Frame], method: str) -> list[Frame]:
    return [frame for frame in frames
            if frame.body.get("method") == method and "id" in frame.body]


def notifications_of(frames: list[Frame], method: str) -> list[Frame]:
    return [frame for frame in frames
            if frame.body.get("method") == method and "id" not in frame.body]


def answer_for(frames: list[Frame], request_id: Any) -> Frame:
    for frame in frames:
        if "method" not in frame.body and frame.body.get("id") == request_id:
            return frame
    raise InteropFailure(f"the agent never answered request id {request_id!r}")


def one_of(frames: list[Frame], method: str, what: str) -> Frame:
    found = requests_of(frames, method)
    require(len(found) == 1,
            f"expected exactly one {method} request on the wire and found {len(found)}: {what}")
    return found[0]


def result_of(frame: Frame) -> dict[str, Any]:
    """The `result` member of an answer, which has to be there to be read."""
    require(frame.body.get("error") is None,
            f"{describe(frame)} is a refusal, not an answer: {frame.body.get('error')!r}")
    result = frame.body.get("result")
    require(isinstance(result, dict),
            f"{describe(frame)} carries no object result member: {frame.body.get('result')!r}")
    return result


def no_true(value: Any, path: str = "") -> list[str]:
    """Every path in a capability object that claims something is supported.

    A capability is a claim about what the other end may rely on, so a client
    that advertised `true` for a method it does not serve would be making a
    promise the run could not keep. This reads the object the way a peer would
    and returns the paths that claimed support, which is what the check then
    refuses: this participant's handler answers `session/request_permission` and
    counts `session/update`, both ungated, and every gated client method is
    refused.
    """
    found: list[str] = []
    if isinstance(value, dict):
        for key, member in value.items():
            where = f"{path}.{key}" if path else key
            if member is True:
                found.append(where)
            else:
                found.extend(no_true(member, where))
    elif isinstance(value, list):
        for index, member in enumerate(value):
            found.extend(no_true(member, f"{path}[{index}]"))
    return found


def advertised_paths(value: dict[str, Any], parent: str = "") -> list[str]:
    """Presence objects and true booleans, in wire order; metadata is not a gate."""
    paths: list[str] = []
    for key, member in value.items():
        if key == "_meta":
            continue
        path = f"{parent}.{key}" if parent else key
        if isinstance(member, dict):
            paths.append(path)
            paths.extend(advertised_paths(member, path))
        elif member is True:
            paths.append(path)
    return paths


def check_exchange(client_frames: list[Frame], agent_frames: list[Frame],
                   chronology: Chronology, peer_events: list[dict[str, Any]],
                   zig_report: Path, wire_version: int) -> list[str]:
    """What the wire has to say, read from the wire.

    Every claim below is made from the captured bytes or from a report the peer
    checked against them. Nothing is claimed about the SDK's internals: the
    capture is bytes, the side channel is the SDK's own record, and the ordering
    claimed is the relay's own.
    """
    findings: list[str] = []
    draft = wire_version == DRAFT_WIRE

    try:
        report = json.loads(zig_report.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InteropFailure(
            f"the Zig participant's report at {zig_report} is missing or not JSON, so there is "
            f"nothing to compare the wire against: {exc}"
        ) from exc
    require(isinstance(report, dict), f"the Zig report at {zig_report} is not a JSON object")

    # 1. The version is negotiated, not assumed.
    initialize = one_of(client_frames, "initialize", "the handshake is the first thing both sides do")
    require(initialize.body.get("jsonrpc") == "2.0", f"{describe(initialize)} does not spell JSON-RPC 2.0")
    require(isinstance(initialize.body.get("id"), (int, str)),
            f"{describe(initialize)} carries no usable id: {initialize.body.get('id')!r}")
    params = initialize.body.get("params")
    require(isinstance(params, dict), f"{describe(initialize)} carries no params object")
    require(params.get("protocolVersion") == wire_version,
            f"the client asked for wire version {params.get('protocolVersion')!r} and this run "
            f"names {wire_version}")
    handshake = result_of(answer_for(agent_frames, initialize.body["id"]))
    require(handshake.get("protocolVersion") == wire_version,
            f"the agent answered with protocol version {handshake.get('protocolVersion')!r}, "
            f"not the {wire_version} the client asked for and the SDK's own constant")
    require(report.get("requested_version") == wire_version
            and report.get("negotiated_version") == wire_version,
            f"the Zig report says it asked for {report.get('requested_version')!r} and negotiated "
            f"{report.get('negotiated_version')!r}, not {wire_version} on both counts")
    findings.append(
        f"initialize: protocolVersion={wire_version} requested, answered and reported by both ends")

    # 2. Real capabilities in both directions.
    capabilities_member = "clientCapabilities" if not draft else "capabilities"
    sent_caps = params.get(capabilities_member)
    require(isinstance(sent_caps, dict),
            f"the client sent no {capabilities_member} object, so the handshake claims no "
            f"capabilities at all rather than the ones this participant actually has")
    claimed = no_true(sent_caps)
    require(not claimed,
            f"the client advertised support for {claimed}, and its handler serves no gated "
            f"client method: a capability the wire claims has to be one this participant can back")
    findings.append(
        f"initialize: {capabilities_member} advertises no capability, which is what this "
        f"participant serves; the SDK accepted it and parsed it as a capability object")
    # The implementation block is named differently at the two versions and
    # required at both, so one check reads whichever member this version spells
    # and holds both to the same fixed identity.
    info_member = "info" if draft else "clientInfo"
    sent_info = params.get(info_member)
    require(isinstance(sent_info, dict) and sent_info.get("name") == CLIENT_NAME
            and sent_info.get("version") == CLIENT_VERSION,
            f"the client sent {info_member} {sent_info!r}, not the fixed name and version this "
            f"participant advertises ({EXPECTED_CLIENT_INFO})")
    answer_caps = handshake.get("agentCapabilities" if not draft else "capabilities")
    require(isinstance(answer_caps, dict),
            f"the agent answered with no capability object, so the Zig client's own capability "
            f"decoder had nothing to read")
    # Stable SDK defaults include nested objects containing false booleans.
    # The objects remain presence entries; their false leaves claim no gate.
    expected_paths = advertised_paths(answer_caps, "capabilities" if draft else "")
    require(report.get("agent_capabilities") == expected_paths,
            f"the Zig report's capability paths differ from the wire: "
            f"{report.get('agent_capabilities')!r} != {expected_paths!r}")
    require(report.get("agent_capability_count") == len(expected_paths),
            "the Zig report's capability count differs from its wire projection")
    require(not no_true(answer_caps), "the fixed agent unexpectedly advertised a true boolean")
    findings.append(
        f"initialize: the SDK's capability object decoded to {len(expected_paths)} presence "
        f"paths and no true boolean leaves")

    # 3. The peer saw the same handshake through its own decoder.
    peer_initialize = next((e for e in peer_events if e.get("event") == "initialize"), None)
    require(peer_initialize is not None,
            "the peer recorded no initialize, so nothing here was read by the SDK's models")
    require(peer_initialize.get("protocol_version") == wire_version,
            f"the peer parsed protocol version {peer_initialize.get('protocol_version')!r}, "
            f"not {wire_version}")
    peer_caps_member = "capabilities" if draft else "client_capabilities"
    require(isinstance(peer_initialize.get(peer_caps_member), dict),
            f"the peer parsed no {peer_caps_member} out of the request, so the SDK's own model "
            f"did not accept the object the client sent")

    # 4. A session, and one the agent issues.
    new_session = one_of(client_frames, "session/new", "a session precedes every prompt")
    created = result_of(answer_for(agent_frames, new_session.body["id"]))
    require(created.get("sessionId") == SESSION_ID,
            f"the agent answered session/new with sessionId {created.get('sessionId')!r}, not the "
            f"fixed id this peer issues")
    require(report.get("session_id") == SESSION_ID,
            f"the Zig report read sessionId {report.get('session_id')!r}, not the id on the wire")
    new_params = new_session.body.get("params")
    require(isinstance(new_params, dict) and isinstance(new_params.get("cwd"), str)
            and new_params["cwd"].startswith("/"),
            f"session/new carried no absolute cwd: {new_params!r}")
    if not draft:
        require(isinstance(new_params.get("mcpServers"), list),
                "a v1 session/new requires mcpServers and the client omitted it")
    peer_session = next((e for e in peer_events if e.get("event") == "new_session"), None)
    require(peer_session is not None and peer_session.get("cwd") == WORKSPACE_CWD,
            f"the peer parsed cwd {peer_session!r}, not the fixed root the client named")
    findings.append(f"session/new: sessionId={SESSION_ID}, cwd={WORKSPACE_CWD}, agreed by both ends")

    # 5. A prompt, and the text coming back out of the agent's own notification.
    prompt = one_of(client_frames, "session/prompt", "the permission happens inside a prompt")
    prompt_params = prompt.body.get("params")
    require(isinstance(prompt_params, dict) and prompt_params.get("sessionId") == SESSION_ID,
            f"the client prompted a session the agent did not issue: {prompt_params!r}")
    blocks = prompt_params.get("prompt")
    require(isinstance(blocks, list) and len(blocks) == 1 and isinstance(blocks[0], dict),
            f"the prompt carried {blocks!r}, not one content block")
    require(blocks[0].get("type") == "text",
            f"the prompt block is {blocks[0].get('type')!r}, not the text block every agent "
            f"must support")
    require(blocks[0].get("text") == PROMPT_TEXT,
            f"the prompt text was {blocks[0].get('text')!r}, not the fixed text this peer echoes")
    prompt_answer = result_of(answer_for(agent_frames, prompt.body["id"]))
    updates = notifications_of(agent_frames, "session/update")
    require(updates, "the agent sent no session/update notification, so nothing came back out "
                     "of the prompt and no text was echoed")
    for update in updates:
        params = update.body.get("params")
        require(isinstance(params, dict) and params.get("sessionId") == SESSION_ID,
                f"a session/update names another session: {params!r}")
    carried = [u for u in updates
               if isinstance(u.body.get("params"), dict)
               and isinstance(u.body["params"].get("update"), dict)
               and isinstance(u.body["params"]["update"].get("content"), dict)
               and isinstance(u.body["params"]["update"]["content"].get("text"), str)]
    require(carried,
            "no session/update carried a content object, so there is no echoed text to compare")
    first_text = carried[0].body["params"]["update"]["content"].get("text")
    require(first_text == PROMPT_TEXT,
            f"the agent echoed {first_text!r}, not the text that went out")
    require(report.get("session_update_count") == len(updates),
            f"the Zig report counted {report.get('session_update_count')!r} session/update "
            f"notifications and the capture holds {len(updates)}")
    require(report.get("echoed_text") == PROMPT_TEXT,
            f"the Zig report read echoed text {report.get('echoed_text')!r}, not the prompt text")
    echoed_variant = carried[0].body["params"]["update"].get("sessionUpdate")
    expected_variant = "user_message_chunk" if draft else "agent_message_chunk"
    require(echoed_variant == expected_variant,
            f"the SDK text update has variant {echoed_variant!r}, not {expected_variant!r}")
    require(report.get("session_update_variant") == echoed_variant,
            f"the Zig report read variant {report.get('session_update_variant')!r}, "
            f"and the captured text update carries {echoed_variant!r}")
    findings.append(
        f"session/prompt: the agent echoed {PROMPT_TEXT!r} back in a "
        f"{echoed_variant!r} notification, read by the client's own decoder")
    if draft:
        require(prompt_answer.get("messageId") == MESSAGE_ID,
                f"a v2 prompt answers with the messageId it inserted, and this one is "
                f"{prompt_answer.get('messageId')!r}, not {MESSAGE_ID!r}")
        require(report.get("prompt_message_id") == MESSAGE_ID,
                f"the Zig report read messageId {report.get('prompt_message_id')!r}")
    else:
        require(prompt_answer.get("stopReason") == "refusal",
                f"the agent answered stopReason {prompt_answer.get('stopReason')!r}: the client "
                f"refused the permission, so the agent's own conclusion should be `refusal`")
        require(report.get("stop_reason") == "refusal",
                f"the Zig report read stopReason {report.get('stop_reason')!r}")

    # 6. The direction the protocol runs the other way.
    permissions = requests_of(agent_frames, "session/request_permission")
    require(len(permissions) == 1,
            f"expected exactly one session/request_permission from the agent and found "
            f"{len(permissions)}")
    permission = permissions[0]
    permission_params = permission.body.get("params")
    require(isinstance(permission_params, dict), f"{describe(permission)} carries no params")
    require(permission_params.get("sessionId") == SESSION_ID,
            f"the agent asked for permission on a session it never issued: "
            f"{permission_params.get('sessionId')!r}")
    if draft:
        # v2 replaced `toolCall` with an optional structured `subject`, and an
        # omitted subject means approval with no structured content — so the
        # member this v1 run reads has no v2 counterpart to check, and the
        # `title` that v2 made required is checked instead.
        require(isinstance(permission_params.get("title"), str) and permission_params["title"],
                f"a v2 permission request requires a title and this one has "
                f"{permission_params.get('title')!r}")
        require(permission_params.get("title") == PERMISSION_TITLE,
                f"the agent asked for permission with the title {permission_params.get('title')!r}, "
                f"not the fixed one this peer sends")
    else:
        tool_call = permission_params.get("toolCall")
        require(isinstance(tool_call, dict) and tool_call.get("toolCallId") == TOOL_CALL_ID,
                f"a v1 permission request carries a toolCall with a toolCallId, and this one "
                f"has {tool_call!r}")
    offered = permission_params.get("options")
    require(isinstance(offered, list) and len(offered) == 2,
            f"the agent offered {offered!r} rather than the fixed two-option offer")
    offered_ids = [option.get("optionId") for option in offered if isinstance(option, dict)]
    require(offered_ids == [ALLOW_OPTION_ID, REJECT_OPTION_ID],
            f"the offer carried option ids {offered_ids!r}, not {[ALLOW_OPTION_ID, REJECT_OPTION_ID]!r}")
    offered_kinds = [option.get("kind") for option in offered if isinstance(option, dict)]
    require(offered_kinds == [ALLOW_OPTION_KIND, REJECT_OPTION_KIND],
            f"the offer carried kinds {offered_kinds!r}, not {[ALLOW_OPTION_KIND, REJECT_OPTION_KIND]!r}")

    # The answer, read off the wire: a cancellation and no option id anywhere.
    denial_frame = answer_for(client_frames, permission.body["id"])
    denial = result_of(denial_frame)
    outcome = denial.get("outcome")
    require(isinstance(outcome, dict) and outcome.get("outcome") == "cancelled",
            f"the client answered the permission with {outcome!r}, not the cancellation the "
            f"participant is able to write")
    require("optionId" not in outcome and "optionId" not in denial,
            f"the client's answer names an option id: {denial!r}. A cancellation is the one "
            f"outcome the specification states without one, and an id here is a choice nobody made")
    findings.append(
        f"session/request_permission: offered {offered_ids} of kinds {offered_kinds}, answered "
        f"with outcome=cancelled and no optionId")

    # 7. The refusal reached the agent, read by the SDK's own models.
    peer_answer = next((e for e in peer_events if e.get("event") == "permission_answer"), None)
    require(peer_answer is not None,
            "the peer recorded no permission answer, so the SDK's own decoder never read what "
            "the client sent")
    require(peer_answer.get("outcome") == "cancelled",
            f"the SDK parsed the client's answer as outcome {peer_answer.get('outcome')!r}, not "
            f"`cancelled`")
    require(peer_answer.get("option_id") is None,
            f"the SDK parsed an option id {peer_answer.get('option_id')!r} out of an answer the "
            f"wire shows has none")
    require(peer_answer.get("granted") is False,
            f"the SDK read the answer as a grant: {peer_answer!r}")
    peer_offered = [option.get("option_id") for option in peer_answer.get("offered", [])]
    require(peer_offered == offered_ids,
            f"the SDK's record of the offer {peer_offered!r} and the wire's {offered_ids!r} disagree")

    # 8. The client's own report, against the same bytes.
    require(report.get("permission_request_count") == len(permissions),
            f"the Zig report counted {report.get('permission_request_count')!r} permission "
            f"requests and the capture holds {len(permissions)}")
    require(report.get("permission_option_count") == len(offered),
            f"the Zig report read {report.get('permission_option_count')!r} options and the wire "
            f"carries {len(offered)}")
    require(report.get("permission_options") == offered_ids,
            f"the Zig report read option ids {report.get('permission_options')!r} and the wire "
            f"carries {offered_ids!r}")
    require(report.get("permission_granting_option_count") == 1,
            f"the Zig report read {report.get('permission_granting_option_count')!r} granting "
            f"options out of an offer whose first kind is {ALLOW_OPTION_KIND!r}")
    require(report.get("permission_answer") == "cancelled",
            f"the Zig report recorded the answer as {report.get('permission_answer')!r}")
    require(report.get("permission_grants") is False,
            "the Zig report recorded a grant. The participant's only writable outcome is a "
            "cancellation, so this is the report disagreeing with the program that wrote it")
    require(report.get("ok") is True,
            f"the Zig participant recorded a failure: {report.get('failure')!r}")
    findings.append(
        "session/request_permission: the SDK parsed the answer as a cancellation with no option "
        "id, and the Zig report agrees; the offer did contain a granting option, so the refusal "
        "is a refusal and not an empty offer")

    # 9. The ordering, from the relay's own record.
    prompt_answer_frame = answer_for(agent_frames, prompt.body["id"])
    chronology.require_after(prompt, permission,
                             "the permission request must cross after the prompt it belongs to")
    chronology.require_after(permission, denial_frame,
                             "the permission answer must cross after the request it answers")
    chronology.require_after(
        denial_frame, prompt_answer_frame,
        "the prompt's answer must cross after the permission answer, because the agent cannot "
        "finish a prompt it is still asking permission for")
    findings.append(
        f"ordering: the permission request crossed {chronology.gap(prompt, permission):.3f}s after "
        f"the prompt, and the prompt's answer crossed "
        f"{chronology.gap(denial_frame, prompt_answer_frame):.3f}s "
        f"after the permission answer, in the relay's own write order")

    return findings


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
    parser.add_argument("--zig-binary", default="zig-out/bin/zig-agent-proto-acp-interop",
                        help="the Zig ACP client executable; supervise only")
    parser.add_argument("--work-dir", default=None,
                        help="an absolute path outside /tmp and /var/tmp, owned by this account "
                             "and not a symlink, where the capture and the reports are kept and "
                             "never removed by this run; a generated directory under TMPDIR "
                             "otherwise, removed when the run ends")
    parser.add_argument("--preflight", action="store_true",
                        help="check TMPDIR and the work-directory policy and exit, with no SDK, "
                             "no pins and no child process")
    parser.add_argument("--deadline", type=float, default=60.0,
                        help="seconds the whole exchange may take before it is killed")
    parser.add_argument("--protocol-version", type=int, default=STABLE_WIRE,
                        choices=(STABLE_WIRE, DRAFT_WIRE),
                        help="the ACP wire version to exchange. 1 is the stable version and the "
                             "default; 2 is the draft, and is refused unless the installed SDK "
                             "really carries its experimental runtime.")
    parser.add_argument("--report", type=Path, default=None, help="the peer's side channel; serve only")
    parser.set_defaults(work_dir_prefix="acp-interop-")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    try:
        if args.preflight:
            return run_preflight(args)
        if args.role == "serve":
            return run_serve(args)
        return run_supervise(args)
    except (InteropFailure, ProcessGuardError) as failure:
        print(f"acp interop FAILED: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))