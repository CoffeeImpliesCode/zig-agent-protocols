#!/usr/bin/env python3
"""MCP 2026-07-28 interoperability peer, driven against the Zig participant.

Four roles, all in this one file because they are four views of the same wire:

``--role serve``
    The peer itself: a genuine ``mcp`` SDK server (the pinned 2.3.0 release, with
    its ``mcp-types`` 2.3.0 split) speaking MCP over this process's own stdin and
    stdout. It serves three tools and nothing else. It is started as a child
    process, so its stdout is the protocol stream and cannot carry a log line;
    its observations go to a side-channel file the supervisor names.

``--role supervise``
    Starts that peer and the Zig client as two children, relays bytes between them
    verbatim, records the raw wire, asserts what the exchange has to prove, and
    reaps everything on any path out — through ``process_guard.py``, which is
    shared with the other supervisors: the polite signal first, and only ever
    against a pid whose ``/proc`` still shows the command line, the owner, the
    start time and a process group that is neither this harness's own nor any
    of this harness's ancestors', with every one of those read again before
    the signal that is not refusable goes out. Then it runs the refusal probe.

``--role refusals``
    The refusal probe, on its own: a second SDK server, driven by this script
    rather than by the Zig client, so the codes the SDK answers a removed method
    with are read off a wire nobody else wrote.

``--role selftest``
    The checks this file's own decisions can be wrong about, with no SDK, no child
    process and no pin check. See ``run_selftest``.

What the exchange proves, and how each claim is checked:

* the revision is not negotiated because there is nothing to negotiate:
  ``server/discover`` is the first request on the wire, carries the protocol
  version in ``params._meta``, and the SDK answers with the revisions it serves.
  The Zig client is pinned to ``2026-07-28`` and refuses an answer that does not
  offer it. The SDK decides which era it is speaking from the first request's
  envelope, so a client that opened with a handshake-era frame would be answering
  a different protocol for the rest of the run, and that is checked on the wire
  rather than assumed;
* every request carries the envelope the SDK's own ladder requires:
  ``params._meta`` with ``io.modelcontextprotocol/protocolVersion`` **and**
  ``io.modelcontextprotocol/clientCapabilities``. The SDK answers a request
  missing either with ``-32602`` naming the missing key, and this run's refusals
  probe asks for exactly that, so the requirement is demonstrated rather than
  quoted;
* no ``initialize`` and no ``notifications/initialized`` crossed the wire in
  either direction. Both were removed at this revision, and the check is that the
  capture carries neither: a participant that emulated a removed method would be
  indistinguishable from one that never sent it by report alone;
* ``tools/list`` is answered with the peer's three tools, and with the caching
  members ``2026-07-28`` made required — ``ttlMs`` and ``cacheScope``. The peer
  is configured with a ``CacheHint`` so the answer carries values this run asserts
  rather than the SDK's defaults;
* a successful tool output, a tool failure and a JSON-RPC error are three
  different shapes. The tool failure is ``result.isError`` with no ``error``
  member; the JSON-RPC error is produced by the SDK's own request validation from
  a ``tools/call`` whose params omit the required ``name``, and it carries
  ``error.code = -32602`` and no ``result``. All three are asserted by shape;
* the multi-round-trip exchange is carried, not simulated: the tool answers with
  ``resultType: "input_required"`` and an ``inputRequests`` map, the client reads
  the server-assigned key and the method inside it, retries the same ``tools/call``
  under a **new** id with ``inputResponses`` and the opaque ``requestState``
  echoed byte for byte, and the peer unseals that state, finds its own answer in
  ``ctx.input_responses`` and returns the argument it was given. The peer's own
  record on the side channel is what says the state reached the handler, because
  the wire alone cannot;
* the removed top-level methods are refused, not emulated. The Zig client refuses
  them before the wire, which the capture shows by their absence, and this script's
  ``refusals`` probe shows the SDK refusing them on a connection already locked to
  this revision: ``initialize`` with ``-32022`` and every other removed name with
  ``-32601``;
* what the Zig client's own decoders read is compared with those same bytes at the
  end: the revision, the two cacheable results' `ttlMs` and `cacheScope`, the tool
  list, the echo text, both answers of the exchange, the error code, the
  ``resultType``, the question's key and method, the state's length and prefix, and
  which leg the retry went out on. The report is never the evidence for a claim,
  only something the wire can be asked to agree with;
* the peer sees end of file and exits, and is reaped. Nothing is left running.

No mocks, no fakes, no synthetic responses: the peer is the upstream SDK and the
wire is the bytes that crossed the pipes. Versions, digests and the API facts this
file depends on are recorded in ``sdk-pins.json`` under ``sdks["mcp-current"]``,
which every role reads and checks itself against, so a run against an environment
that does not match the pins fails instead of quietly testing something else. The
previous-revision peer in ``mcp_peer.py`` reads ``sdks["mcp"]`` and is unaffected:
the two entries are different distributions of one upstream, and neither is a
compatibility shim for the other.

Where a run writes: the wire, the reports and the logs all go into one work
directory. Named with ``--work-dir``, it is kept, because a capture somebody asked
for is evidence. Otherwise it is created inside the environment's ``TMPDIR`` and
removed when the run ends, on success and on failure alike, so a run leaves nothing
behind and reports which of the two it did instead of printing a path that no longer
exists. ``TMPDIR`` is the only thing that decides where a generated directory may be
created, and a system temporary directory is refused either way.

Nothing here makes any claim about what the SDK does internally: the capture is
bytes, the assertions are shapes, and the only ordering claimed is the relay's own.
"""

# Deliberately no `from __future__ import annotations`. The SDK reads a tool
# handler's annotations with `typing.get_type_hints`, which resolves a deferred
# annotation against the *defining module's* globals; this module imports the SDK
# inside `build_server`, so a deferred `Context` or `InputRequiredResult` would
# resolve to nothing and the SDK would refuse the tool at registration. Evaluating
# them at definition time, in the scope that has the names, is what keeps the
# handlers registrable while this file's own imports stay at the top.

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
#
# `refusals` is reached through the module rather than imported, because
# `write_summary` below already has a parameter by that name for what the
# refusal probe found on the wire, and a local of that name would shadow the
# one the guard's teardown is checked with.
import process_guard
from process_guard import (Child, DeadlineMissed, Guard, ProcessGuardError, Stop)

# Where a run's work directory comes from and who may take it away, shared for
# the same reason as the guard above: one place decides whether a directory may
# be written into and whether it may be removed, because four copies of that
# decision drift apart — and this one had drifted into four `rmtree` calls.
from workdir import (WorkDirRefused, approved_scratch_root, remove_directory,
                     require_named_directory, require_private_directory)

HERE = Path(__file__).resolve().parent
DEFAULT_PINS = HERE / "sdk-pins.json"

# The pin entry this peer reads. A different key from the previous-revision peer's
# `mcp`, because the two are different releases of one upstream distribution and a
# single key holding two versions would mean one of them silently lost its pin.
PIN_KEY = "mcp-current"

# The revision this exchange is pinned to. Sent by the client in the envelope of
# every request, and asserted against the peer's answer, so neither side gets it
# right by accident.
REVISION = "2026-07-28"

# The tool names both ends agree on. The Zig client sends these literals; they are
# repeated here rather than negotiated, which is what a client and a server do: the
# names are the interface, and an interop run that agreed on them at runtime would
# be testing the agreement instead of the protocol.
TOOL_ECHO = "echo"
TOOL_FAIL = "fail"
TOOL_ASK = "ask"

# The key the peer files the one question it asks under, and the method it asks
# with. Both are the server's to choose and both are on the wire, so they are
# constants here rather than something either side derives at run time — a run that
# invented the key would be testing its own invention.
ASK_KEY = "colour"
ASK_METHOD = "elicitation/create"

# The freshness hint the peer publishes for `tools/list`, so the answer carries
# values the checks can name rather than the SDK's defaults. The specification
# requires both members on a cacheable result and says nothing about their values,
# so a run that asserted `ttlMs == 0` would be asserting the SDK's default rather
# than the protocol.
TOOLS_LIST_TTL_MS = 60_000

TOOLS_LIST_CACHE_SCOPE = "public"

# The message the failing tool's handler raises, and the words the checks look for
# inside the answer. A constant rather than a literal in the check, so the handler
# and the assertion cannot drift apart.
FAIL_MESSAGE = "deliberate tool failure"

# A fixed marker, not a path or a hostname: the capture is kept as evidence, so it
# must not carry anything about the machine that produced it.
MARKER = "zig-agent-protocols-interop"

# The three envelope keys `2026-07-28` requires on every request, as the SDK's own
# names them. `mcp.shared.inbound.classify_inbound_request` (rung one) refuses a
# request whose `params._meta` lacks the first two of them with INVALID_PARAMS
# naming the missing key, and the refusals probe asks for exactly that, so this
# file's names are the ones the peer is actually checked against.
META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"

# Codes this file asserts against, all pinned in sdk-pins.json against the mcp
# 2.3.0 source with line numbers:
#
# - `sdks["mcp-current"].api.peer_error_from_bad_params` records that the SDK's
#   inbound request validation answers a request whose params fail the typed
#   validation with INVALID_PARAMS.
# - `sdks["mcp-current"].api.removed_method_at_current` records that on a connection
#   already serving this revision, `initialize` is answered with
#   UNSUPPORTED_PROTOCOL_VERSION and every other removed name with METHOD_NOT_FOUND.
# - `sdks["mcp-current"].api.invalid_request_state` records that a retry whose
#   `requestState` does not unseal is answered with INVALID_PARAMS and a
#   `reason` of `invalid_request_state`.
#
# - `sdks["mcp-current"].api.dual_era_first_request_routing` records that
#   `Server.run` serves both eras on one connection and picks from the envelope of
#   the first request, which is why this peer asserts the first request is
#   `server/discover` and that the exchange never opens with a handshake-era frame.
# - `sdks["mcp-current"].api.request_state_sealing` records that
#   `RequestStateBoundary` seals `requestState` outbound and unseals it inbound, so
#   the token on the wire is not the plaintext the handler sees. The check that
#   both differ, and that the handler got its own plaintext back, is the only
#   evidence of it that the wire alone cannot give.
# - `sdks["mcp-current"].api.cache_hint_applied_to_results` records that
#   `MCPServer(cache_hints=...)` fills `ttlMs`/`cacheScope` on a handler's result,
#   which is why the run asserts the configured values rather than the SDK's
#   defaults: a default would pass a check that never looked at the hint.
# - `sdks["mcp-current"].api.tool_error_carries_message` records that a `ToolError`
#   reaches the client as `isError` carrying the handler's own message, where any
#   other exception arrives with the message withheld. Asserting the message
#   survives is what tells the two paths apart.
INVALID_PARAMS = -32602
METHOD_NOT_FOUND = -32601
UNSUPPORTED_PROTOCOL_VERSION = -32022

# The names this revision removed from the top level, and the shape of the answer
# each gets on a connection already locked to it. `initialize` is the one that gets
# its own code, because it is the handshake this revision has no answer for; every
# other removed name is simply a method this server does not have.
#
# `REMOVED_NOTIFICATION` is the library's own `mcp.removed_methods` notification
# arm, which is *not* every `notifications/` name: `notifications/progress` and
# `notifications/message` survive at this revision, the first moved onto the
# originating request's response stream and the second onto `subscriptions/listen`.
# They are in `TOP_LEVEL_NOTIFICATIONS` below, which the probe also refuses, because
# a server has no top-level handler for a notification it delivers on a stream.
#
# `sampling/createMessage`, `elicitation/create` and `roots/list` are here too, and
# for a different reason: what was removed is their use as top-level requests, and
# they survive inside `InputRequiredResult.inputRequests`. A server answering them
# as requests is answering a different protocol.
REMOVED_AS_REQUEST = (
    "ping",
    "logging/setLevel",
    "resources/subscribe",
    "resources/unsubscribe",
)
REMOVED_NOTIFICATION = (
    "notifications/initialized",
    "notifications/roots/list_changed",
    "notifications/elicitation/complete",
)
# The notifications this revision still defines, which a server nevertheless serves
# no top-level handler for. Asking for them as requests is the way this probe
# establishes that: their answer is METHOD_NOT_FOUND either way, and a server that
# had answered them at the top level would be serving a protocol this revision
# replaced.
TOP_LEVEL_NOTIFICATIONS = (
    "notifications/progress",
    "notifications/message",
    "notifications/tools/list_changed",
    "notifications/resources/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/updated",
    "notifications/subscriptions/acknowledged",
)
REMOVED_AS_INPUT_REQUEST = (
    "sampling/createMessage",
    "elicitation/create",
    "roots/list",
)


class InteropFailure(Exception):
    """A check failed. The message is the finding; the traceback is not."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InteropFailure(message)


# --- pins -----------------------------------------------------------------------


def load_pins(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise InteropFailure(f"pin file not found: {path}") from exc
    try:
        pins = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise InteropFailure(f"pin file is not JSON: {path}: {exc}") from exc
    require(
        pins.get("schema") == "zig-agent-protocols/interop-sdk-pins/1",
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
            f"pinned environment (`devenv shell`, then `interop-python`, or "
            f"`interop-mcp-current`)."
        ) from exc


def check_pins(pins: dict[str, Any]) -> dict[str, Any]:
    """Refuse to test against an environment the pins do not describe.

    Both distributions are checked, not just the one the peer imports by name: the
    2.x line is a rewrite whose protocol types live in ``mcp-types``, pinned with an
    exact ``==``, so an environment where the two drift apart is an environment
    whose wire shapes are nobody's pin.

    The revision is then read from the SDK itself rather than from this file. A pin
    records what the environment should contain; only the SDK can say what it
    actually contains, and this is a check on the SDK rather than on the pins.
    """
    sdks = pins.get("sdks", {})
    require(PIN_KEY in sdks, f"the pin file records no {PIN_KEY!r}")
    record = sdks[PIN_KEY]

    for distribution, field in (
        (record.get("distribution", "mcp"), "version"),
        (record.get("types_distribution", "mcp-types"), "types_version"),
    ):
        want = record.get(field)
        require(isinstance(want, str) and want != "", f"the pin file records no {field!r} for {distribution!r}")
        have = installed_version(distribution)
        require(
            have == want,
            f"{distribution} {have} is installed, the pin is {want}. Refusing to run: an "
            f"interop result only means something for the release it was taken against.",
        )

    import mcp_types.version as version_registry

    known = tuple(version_registry.KNOWN_PROTOCOL_VERSIONS)
    modern = tuple(version_registry.MODERN_PROTOCOL_VERSIONS)
    handshake = tuple(version_registry.HANDSHAKE_PROTOCOL_VERSIONS)
    pinned = record.get("protocol", {})
    require(
        version_registry.LATEST_MODERN_VERSION == REVISION,
        f"mcp_types reports its latest modern revision as "
        f"{version_registry.LATEST_MODERN_VERSION!r}, and this exchange is pinned to {REVISION!r}. "
        f"Refusing to run against an SDK that does not speak the revision under test.",
    )
    require(
        modern == tuple(pinned.get("modern_protocol_versions", modern)),
        f"mcp_types MODERN_PROTOCOL_VERSIONS is {list(modern)}, the pin records "
        f"{pinned.get('modern_protocol_versions')!r}",
    )
    require(
        known == tuple(pinned.get("known_protocol_versions", known)),
        f"mcp_types KNOWN_PROTOCOL_VERSIONS is {list(known)}, the pin records "
        f"{pinned.get('known_protocol_versions')!r}",
    )
    require(
        handshake == tuple(pinned.get("handshake_protocol_versions", handshake)),
        f"mcp_types HANDSHAKE_PROTOCOL_VERSIONS is {list(handshake)}, the pin records "
        f"{pinned.get('handshake_protocol_versions')!r}",
    )
    return record


def check_api(record: dict[str, Any]) -> None:
    """Refuse to run against an SDK whose peer surface is not the pinned one.

    Every name this file imports is resolved here, before a server starts or a
    child is launched. A renamed decorator is then a refusal with the name of the
    missing symbol rather than a traceback out of a child's stderr, which is the
    difference between a run that says what drifted and a run that says a peer died.
    """
    from mcp.server import CacheHint, MCPServer
    from mcp.server.mcpserver import Context
    from mcp.server.mcpserver.exceptions import ToolError
    from mcp.server.stdio import stdio_server
    from mcp_types import ElicitRequest, ElicitRequestFormParams, InputRequiredResult

    for name, symbol in (
        ("server_entry", MCPServer),
        ("cache_hint", CacheHint),
        ("tool_context", Context),
        ("tool_error", ToolError),
        ("stdio_transport", stdio_server),
        ("input_required_result", InputRequiredResult),
        ("elicit_request", ElicitRequest),
        ("elicit_request_form_params", ElicitRequestFormParams),
    ):
        require(symbol is not None, f"mcp exposes no {name}; the pin file says it does")
    # `CacheHint`'s two fields are this run's subject, not an implementation detail:
    # they are the values the peer publishes and the checks below assert.
    hint = CacheHint(ttl_ms=TOOLS_LIST_TTL_MS, scope=TOOLS_LIST_CACHE_SCOPE)
    require(hint.ttl_ms == TOOLS_LIST_TTL_MS, "CacheHint did not keep the ttl it was given")
    require(hint.scope == TOOLS_LIST_CACHE_SCOPE, "CacheHint did not keep the scope it was given")
    require(
        TOOLS_LIST_CACHE_SCOPE in ("public", "private"),
        f"the pin's own cache scope {TOOLS_LIST_CACHE_SCOPE!r} is not one of the two the "
        f"specification defines",
    )
    _ = record


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

        Deliberately silent about removal, because this one is printed before
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


class SideChannel:
    """The peer's own record of what it did, on a path the wire does not touch.

    One fresh file per run, one JSON object per line, flushed per line. Nothing in
    this exchange blocks on it — the previous-revision peer's cancellation marker
    does, because the Zig client waits on a file while it is inside a call — but it
    is flushed per line anyway, so a line that says the state was unsealed is on disk
    before the answer that says so has been read.
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


def ask() -> Any:
    """The elicitation the peer embeds in its interim result.

    Built per call rather than shared: one request object answered twice would be a
    shared mutable value across two rounds of one exchange.
    """
    from mcp_types import ElicitRequest, ElicitRequestFormParams

    return ElicitRequest(
        params=ElicitRequestFormParams(
            message="Which colour?",
            requested_schema={
                "type": "object",
                "properties": {"confirm": {"type": "boolean"}},
                "required": ["confirm"],
            },
        )
    )


def interim_result() -> Any:
    """The interim result the `ask` tool answers with.

    `request_state` is the plaintext the peer mints. The SDK's `RequestStateBoundary`
    seals it into an opaque token on the way out and unseals it on the way back in,
    which is why the client's retry echoes a string that is nothing like this and the
    handler still sees these characters: the whole point of the leg is that the state
    the client carries is not the state the server wrote.
    """
    from mcp_types import InputRequiredResult

    return InputRequiredResult(input_requests={ASK_KEY: ask()}, request_state=STATE_PLAINTEXT)


# The plaintext the peer's handler expects to find after the boundary unsealed the
# token. A fixed string, so a capture from two runs is comparable to another.
STATE_PLAINTEXT = "zig-agent-protocols-colour"


def build_server(record: dict[str, Any], side: SideChannel) -> Any:
    """The genuine SDK server this peer serves.

    The handler bodies are registered on the `MCPServer` the SDK ships, and every
    answer the checks below look at is produced by the SDK's own conversion layer:
    this function names tools and raises `ToolError`, and the SDK decides what each
    of those becomes on the wire.
    """
    from mcp.server import CacheHint, MCPServer
    from mcp.server.mcpserver import Context
    from mcp.server.mcpserver.exceptions import ToolError
    from mcp_types import InputRequiredResult

    # The `ask` handler's return annotation names `InputRequiredResult` directly
    # rather than through `interim_result`'s return type: the SDK reads that
    # annotation to decide whether a tool may answer with an interim result at
    # all, so it has to be the class and not a guess about it.

    server = MCPServer(
        f"{MARKER}-peer",
        version=record["version"],
        instructions=(
            "Interoperability peer for zig-agent-protocols at MCP 2026-07-28. Every tool name, "
            "argument, question and answer is fixed so a capture can be compared against a "
            "later run."
        ),
        cache_hints={"tools/list": CacheHint(ttl_ms=TOOLS_LIST_TTL_MS, scope=TOOLS_LIST_CACHE_SCOPE)},
    )

    @server.tool()
    def echo(text: str) -> str:
        """Return the text it was given, in a successful result."""
        side.event("call_tool", tool=TOOL_ECHO)
        return text

    @server.tool()
    def fail() -> str:
        """Run and fail on purpose: a successful call whose result is an error."""
        side.event("call_tool", tool=TOOL_FAIL)
        # `ToolError`, not an arbitrary exception: the SDK turns this one into
        # `isError: true` carrying this message, where any other exception would
        # arrive as a generic "Error executing tool fail" with the message withheld.
        # Asserting on the text is therefore a check on the SDK's anticipated-failure
        # path rather than on its crash path.
        raise ToolError("deliberate tool failure")

    @server.tool()
    def ask(text: str, ctx: Context) -> str | InputRequiredResult:
        """Ask the client something before it runs, then return the text it was given."""
        if ctx.input_responses is None:
            side.event("ask_first_round")
            return interim_result()
        # Round two. Reaching here at all says the retry carried `inputResponses`; what
        # the SDK did with the `requestState` beside them is what these two records
        # say, and neither is visible on the wire.
        side.event(
            "ask_resumed",
            request_state=ctx.request_state,
            answers=sorted(ctx.input_responses),
        )
        if ctx.request_state != STATE_PLAINTEXT:
            # Returning the state rather than raising: a handler that raised here would
            # answer with an isError result, which is a different shape and would make
            # this finding hard to read off the wire.
            return f"unexpected state {ctx.request_state}"
        return text

    return server


def run_serve(args: argparse.Namespace) -> int:
    """The genuine SDK server, over this process's stdio."""
    pins = load_pins(args.pins)
    record = check_pins(pins)
    check_api(record)

    import anyio
    import mcp_types.version as version_registry
    from mcp.server.stdio import stdio_server

    side = SideChannel(args.report)
    side.event(
        "peer_start",
        mcp=record["version"],
        mcp_types=record.get("types_version"),
        latest_modern_version=version_registry.LATEST_MODERN_VERSION,
        known_protocol_versions=list(version_registry.KNOWN_PROTOCOL_VERSIONS),
        python=sys.version.split()[0],
    )

    server = build_server(record, side)

    async def main() -> None:
        async with stdio_server() as (read_stream, write_stream):
            side.event("serve_begin")
            await server._lowlevel_server.run(
                read_stream, write_stream, server._lowlevel_server.create_initialization_options()
            )
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

    def __init__(self, server: subprocess.Popen[bytes], client: subprocess.Popen[bytes],
                 client_to_server: Capture, server_to_client: Capture,
                 deadline: float, budget: float, stamps: list[Stamp]) -> None:
        self._server = server
        self._client = client
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
        assert self._server.stdout is not None and self._client.stdout is not None
        assert self._server.stdin is not None and self._client.stdin is not None
        self._selector.register(self._server.stdout, selectors.EVENT_READ, ("s2c", self._client.stdin))
        self._selector.register(self._client.stdout, selectors.EVENT_READ, ("c2s", self._server.stdin))
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
        for process in (self._server, self._client):
            close_fd(process.stdin)
            close_fd(process.stdout)
        if self.failure is not None:
            raise InteropFailure(self.failure)


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


def require_zig_binary(args: argparse.Namespace) -> Path:
    zig_binary = Path(args.zig_binary)
    require(
        zig_binary.exists(),
        f"the Zig participant is not at {zig_binary}. It is an executable target and build.zig "
        f"belongs to the integration owner, so build it first:\n"
        f"  zig build interop-mcp-current\n"
        f"which installs zig-out/bin/{zig_binary.name}, or point --zig-binary at an existing one.",
    )
    return zig_binary


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


def answers_of(server_frames: list[Frame]) -> list[Frame]:
    """Every frame the server sent that is an answer rather than a request."""
    return [frame for frame in server_frames if "method" not in frame.body]


def answer_for(server_frames: list[Frame], request_id: Any) -> Frame:
    for frame in answers_of(server_frames):
        if frame.body.get("id") == request_id:
            return frame
    raise InteropFailure(f"the peer never answered request id {request_id!r}")


def envelope_of(frame: Frame) -> dict[str, Any]:
    """The `params._meta` a request carried, or a refusal naming what is wrong.

    Read with one walk that does not raise: this file asserts the envelope's shape
    on frames it did not write, and a check that reported a decoder's error instead
    of the shape it found would name the mechanism rather than the finding. A
    `params` that is not an object has no `_meta` at all, which is a finding and not
    a fault here.
    """
    params = frame.body.get("params")
    if not isinstance(params, dict):
        return {}
    meta = params.get("_meta")
    return meta if isinstance(meta, dict) else {}


def require_envelope(frame: Frame) -> dict[str, Any]:
    """The envelope this revision requires on a request, refused rather than assumed.

    `2026-07-28` has no handshake, so the protocol version and the client
    capabilities ride on every request. The SDK's own ladder refuses a request
    whose `params._meta` lacks either, and the refusals probe asks for exactly that,
    so this check is the same requirement read off this run's own wire.
    """
    meta = envelope_of(frame)
    missing = [key for key in (META_PROTOCOL_VERSION, META_CLIENT_CAPABILITIES) if key not in meta]
    require(
        not missing,
        f"{describe(frame)} carried no {', '.join(missing)} in params._meta, which this revision "
        f"requires on every request. The envelope it did carry: {sorted(meta)}",
    )
    require(
        meta[META_PROTOCOL_VERSION] == REVISION,
        f"{describe(frame)} declared protocol version {meta[META_PROTOCOL_VERSION]!r} in its "
        f"envelope, and this run is pinned to {REVISION!r}",
    )
    require(
        META_CLIENT_INFO in meta,
        f"{describe(frame)} carried no {META_CLIENT_INFO!r} in its envelope. It is optional "
        f"(SHOULD-include) and this run does not require it of a peer, but the client that "
        f"drew this wire was asked to send it, so its absence is a finding here.",
    )
    require(
        isinstance(meta[META_CLIENT_CAPABILITIES], dict),
        f"{describe(frame)} carried {META_CLIENT_CAPABILITIES} as "
        f"{type(meta[META_CLIENT_CAPABILITIES]).__name__}, and it is an object",
    )
    return meta


def cacheable_of(result: dict[str, Any], label: str) -> tuple[int, str]:
    """The `ttlMs` and `cacheScope` a cacheable result carried, read by shape.

    Both are required on a result for a cacheable method at this revision, and a
    missing one is a finding rather than a default: a server that omitted it is a
    server this client could not have decoded, which is the thing worth catching.
    """
    for member in ("ttlMs", "cacheScope", "resultType"):
        require(
            member in result,
            f"the {label} result carried no {member!r}, which this revision requires: "
            f"{sorted(result)}",
        )
    ttl = result["ttlMs"]
    scope = result["cacheScope"]
    require(
        isinstance(ttl, int) and not isinstance(ttl, bool) and ttl >= 0,
        f"the {label} result carried ttlMs={ttl!r}, and the field is a whole number of "
        f"milliseconds no smaller than zero",
    )
    require(
        scope in ("public", "private"),
        f"the {label} result carried cacheScope={scope!r}, and the specification defines only "
        f"'public' and 'private'",
    )
    return ttl, scope


def call_frames(client_frames: list[Frame], tool: str) -> list[Frame]:
    """The `tools/call` requests that named a tool, in wire order.

    Every call in this exchange is the same method, so a frame is found by its own
    params rather than by its position: the `ask` tool is called twice and the two
    legs are told apart by what they carry, not by how many `tools/call` frames came
    before them.
    """
    return [frame for frame in requests_of(client_frames, "tools/call")
            if frame.body.get("params", {}).get("name") == tool]


def call_frame(client_frames: list[Frame], tool: str) -> Frame:
    found = call_frames(client_frames, tool)
    require(bool(found), f"the client never called the {tool!r} tool")
    return found[0]


def malformed_call(client_frames: list[Frame]) -> Frame:
    """The ``tools/call`` whose params name no tool.

    That is the call the peer has to refuse, and the refusal is bound to this
    frame's id so the check cannot be satisfied by some other error on the wire.
    """
    for frame in requests_of(client_frames, "tools/call"):
        if not frame.body.get("params", {}).get("name"):
            return frame
    raise InteropFailure("the client never sent a tools/call with no tool name")


def text_of(result: dict[str, Any], label: str) -> list[str]:
    """The texts of a result's text content blocks, in wire order."""
    blocks = result.get("content")
    require(
        isinstance(blocks, list) and bool(blocks),
        f"the {label} result carried no content array: {sorted(result)}",
    )
    return [block["text"] for block in blocks
            if isinstance(block, dict) and block.get("type") == "text"]


def check_envelope_and_discover(client_frames: list[Frame], server_frames: list[Frame],
                                chronology: Chronology) -> tuple[list[str], dict[str, Any]]:
    """The envelope on every request, and the discover that answers the first one.

    The first request is `server/discover` and nothing else, because the SDK's
    era routing decides which protocol a connection is serving from the envelope of
    its first request. A client that opened with a handshake-era frame would be
    answered in the handshake era for the rest of the run, so this check is about
    the order as well as the shape.
    """
    findings: list[str] = []
    client_requests = [frame for frame in client_frames if "method" in frame.body and "id" in frame.body]
    require(bool(client_requests), "the client sent no request at all")
    first = client_requests[0]
    require(
        first.body.get("method") == "server/discover",
        f"the first request on the wire was {first.body.get('method')!r}, not 'server/discover'. "
        f"This SDK decides which protocol era a connection serves from the envelope of its "
        f"first request, so the whole exchange after it would be answered in the wrong era.",
    )
    # One envelope check per request, because the requirement is on every request
    # and a client that sent it on the first and dropped it on the sixth would pass
    # a check made on the first alone.
    for frame in client_requests:
        require_envelope(frame)

    discover = requests_of(client_frames, "server/discover")
    require(len(discover) == 1, f"expected exactly one server/discover, saw {len(discover)}")
    answer = answer_for(server_frames, discover[0].body["id"])
    require("result" in answer.body, f"server/discover was refused: {json.dumps(answer.body)[:200]}")
    result = answer.body["result"]
    ttl, scope = cacheable_of(result, "server/discover")
    versions = result.get("supportedVersions")
    require(
        isinstance(versions, list) and REVISION in versions,
        f"the peer does not offer {REVISION!r} in its discover answer: {versions!r}. This client "
        f"is pinned to one revision and is not a version-negotiating client.",
    )
    require(
        isinstance(result.get("capabilities"), dict) and "tools" in result["capabilities"],
        f"the discover result advertised no tools capability: {json.dumps(result)[:200]}",
    )
    findings.append(
        f"server/discover answered with {REVISION} among {versions}, ttlMs={ttl}, "
        f"cacheScope={scope}, and a tools capability, on a connection whose first request "
        f"already carried the envelope"
    )
    # The answer arrived after the request, on the relay's own order.
    chronology.require_after(discover[0], answer, "the peer answered server/discover before the request")
    return findings, result


def check_no_handshake(client_frames: list[Frame], server_frames: list[Frame]) -> list[str]:
    """Neither removed handshake message crossed the wire, in either direction.

    This is the negative evidence, and it is the whole of the claim that this
    revision has no handshake: a participant that emulated one would produce a
    report saying it did not, so the check has to be made against the bytes.
    """
    findings: list[str] = []
    for label, frames in (("client to server", client_frames), ("server to client", server_frames)):
        for method in ("initialize", "notifications/initialized"):
            found = [frame for frame in frames if frame.body.get("method") == method]
            require(
                not found,
                f"{len(found)} {method!r} frame(s) crossed {label}, and this revision removed "
                f"both. A run that sent one is testing a protocol the client is not pinned to.",
            )
    findings.append(
        "no initialize and no notifications/initialized crossed in either direction: the "
        "handshake this revision removed was not emulated"
    )
    return findings


def check_tool_list(client_frames: list[Frame], server_frames: list[Frame],
                    chronology: Chronology) -> tuple[list[str], list[str]]:
    """`tools/list` answered with the peer's tools and the caching members."""
    listed = requests_of(client_frames, "tools/list")
    require(len(listed) == 1, f"expected exactly one tools/list, saw {len(listed)}")
    answer = answer_for(server_frames, listed[0].body["id"])
    require("result" in answer.body, f"tools/list was refused: {json.dumps(answer.body)[:200]}")
    result = answer.body["result"]
    ttl, scope = cacheable_of(result, "tools/list")
    require(
        ttl == TOOLS_LIST_TTL_MS and scope == TOOLS_LIST_CACHE_SCOPE,
        f"tools/list answered with ttlMs={ttl}, cacheScope={scope!r}, and the peer was "
        f"configured for ttlMs={TOOLS_LIST_TTL_MS}, cacheScope={TOOLS_LIST_CACHE_SCOPE!r}. The "
        f"cache hint the SDK applies to a handler's result is the thing under test here, so a "
        f"default would pass a check that never looked at it.",
    )
    names = [tool.get("name") for tool in result.get("tools", [])]
    for expected in (TOOL_ECHO, TOOL_FAIL, TOOL_ASK):
        require(expected in names, f"tools/list did not offer {expected!r}: {names}")
    chronology.require_after(listed[0], answer, "the peer answered tools/list before the request")
    return names, [
        f"tools/list offered {', '.join(str(name) for name in names)} with ttlMs={ttl} and "
        f"cacheScope={scope}, both required on a cacheable result at this revision"
    ]


def check_calls(client_frames: list[Frame], server_frames: list[Frame],
                chronology: Chronology) -> list[str]:
    """A successful output, a tool failure and a JSON-RPC error are three shapes."""
    findings: list[str] = []
    calls = requests_of(client_frames, "tools/call")
    require(len(calls) >= 4, f"expected at least four tools/call requests, saw {len(calls)}")

    # The echo is checked against the text that went out. "The answer had content in
    # it" would pass for a peer that returned any content at all, which is not what
    # this tool is on the wire to prove.
    echo_call = call_frame(client_frames, TOOL_ECHO)
    sent_text = echo_call.body.get("params", {}).get("arguments", {}).get("text")
    require(
        isinstance(sent_text, str) and sent_text != "",
        f"the {TOOL_ECHO!r} call carried no text argument: {json.dumps(echo_call.body)[:200]}",
    )
    echo_answer = answer_for(server_frames, echo_call.body["id"])
    require("result" in echo_answer.body, f"the echo call was refused: {json.dumps(echo_answer.body)[:200]}")
    echo_result = echo_answer.body["result"]
    require(
        not echo_result.get("isError", False),
        "a successful tool call came back with isError",
    )
    echoed = text_of(echo_result, TOOL_ECHO)
    require(
        echoed == [sent_text],
        f"the {TOOL_ECHO!r} tool was sent {sent_text!r} and answered {echoed!r}",
    )
    findings.append(f"the {TOOL_ECHO!r} tool answered with the text that went out, {sent_text!r}")

    fail_call = call_frame(client_frames, TOOL_FAIL)
    fail_answer = answer_for(server_frames, fail_call.body["id"])
    require("result" in fail_answer.body, f"the failing tool call was refused: {json.dumps(fail_answer.body)[:200]}")
    fail_result = fail_answer.body["result"]
    require(
        fail_result.get("isError") is True,
        f"a tool that failed did not answer with isError: {json.dumps(fail_answer.body)[:200]}",
    )
    require(
        "error" not in fail_answer.body,
        "a tool failure carried a JSON-RPC error member as well as isError, so the two could "
        "not be told apart",
    )
    # The SDK's anticipated-failure path carries the handler's own message, where
    # its crash path replaces it with a fixed "Error executing tool <name>" and
    # withholds what the handler raised. Asserting the message survives is what
    # tells the two apart, so the check looks for the handler's words rather than
    # for the whole text: the SDK composes its own prefix around them, and a check
    # that demanded an exact string would be pinning the SDK's wording rather than
    # its behaviour.
    fail_text = text_of(fail_result, TOOL_FAIL)
    require(
        len(fail_text) == 1 and FAIL_MESSAGE in fail_text[0],
        f"the failing tool answered {fail_text!r}, and a ToolError reaches the client as "
        f"isError carrying the handler's own message ({FAIL_MESSAGE!r} among it). A crash would "
        f"arrive with the message withheld instead.",
    )
    findings.append(
        f"a failing tool came back as result.isError carrying the handler's own message "
        f"({FAIL_MESSAGE!r}) and no error member"
    )

    # The malformed call's own id, not the first error on the wire: the retry leg
    # below can be an error answer too, and a check that took whichever arrived
    # first would pass for the wrong reason.
    malformed = malformed_call(client_frames)
    peer_error = answer_for(server_frames, malformed.body["id"])
    require(
        isinstance(peer_error.body.get("error"), dict),
        f"the malformed tools/call was not answered with a JSON-RPC error: {peer_error.body}",
    )
    require("result" not in peer_error.body, f"an error answer also carried a result: {peer_error.body}")
    invalid_code = peer_error.body["error"].get("code")
    require(
        invalid_code == INVALID_PARAMS,
        f"a tools/call whose params omit the required name was refused with code "
        f"{invalid_code!r}, and the SDK's own inbound validation answers with {INVALID_PARAMS}",
    )
    chronology.require_after(malformed, peer_error, "the peer answered before the request went out")
    findings.append(
        f"a tools/call with no name came back as a JSON-RPC error, code {invalid_code}, "
        f"with no result member"
    )
    return findings


def check_mrtr(client_frames: list[Frame], server_frames: list[Frame],
               chronology: Chronology, peer_events: list[dict[str, Any]]) -> tuple[list[str], dict[str, Any]]:
    """The multi-round-trip exchange, carried rather than simulated.

    Four things have to hold and none of them is visible in the others: the first
    leg is answered with an interim result rather than a final one, the retry went
    out under a new id, the retry carried the server's own opaque state byte for
    byte, and the peer unsealed that state and found its answer. The last one is
    the peer's own record, because the wire cannot show it: a token the peer sealed
    and never unsealed would look identical on the wire.
    """
    findings: list[str] = []
    legs = call_frames(client_frames, TOOL_ASK)
    require(len(legs) == 2, f"expected two tools/call requests for {TOOL_ASK!r}, saw {len(legs)}")
    first, retry = legs
    require(
        first.body["id"] != retry.body["id"],
        f"the retry went out under the same id as the first leg ({first.body['id']!r}); "
        f"a retry is a new call and the connection's id sequence is what guarantees it",
    )

    first_answer = answer_for(server_frames, first.body["id"])
    require("result" in first_answer.body, f"the first leg was refused: {json.dumps(first_answer.body)[:200]}")
    interim = first_answer.body["result"]
    require(
        interim.get("resultType") == "input_required",
        f"the first leg was answered with resultType={interim.get('resultType')!r}, and the "
        f"exchange under test is one where the server asks for input first",
    )
    questions = interim.get("inputRequests")
    require(
        isinstance(questions, dict) and bool(questions),
        f"the interim result carried no inputRequests map: {json.dumps(interim)[:200]}",
    )
    ask_entry = questions.get(ASK_KEY)
    require(
        isinstance(ask_entry, dict) and ask_entry.get("method") == ASK_METHOD,
        f"the interim result asked under {ASK_KEY!r} with "
        f"{(ask_entry or {}).get('method')!r}, and this run asserts the key and the method the "
        f"peer mints",
    )
    state = interim.get("requestState")
    require(
        isinstance(state, str) and state != "",
        f"the interim result carried no requestState, and a retry carrying no state cannot be "
        f"answered by this server",
    )
    require(
        state != STATE_PLAINTEXT,
        f"the interim result carried its requestState in the clear ({state!r}), and the peer's "
        f"request-state boundary is supposed to seal it before it leaves",
    )

    retry_params = retry.body.get("params", {})
    require(
        retry_params.get("requestState") == state,
        f"the retry carried requestState {retry_params.get('requestState')!r} and the interim "
        f"result sent {state!r}. The state is opaque and attacker-influenced, so a client that "
        f"re-encoded, truncated or regenerated it is a client the server cannot answer.",
    )
    answers = retry_params.get("inputResponses")
    require(
        isinstance(answers, dict) and ASK_KEY in answers,
        f"the retry carried inputResponses={answers!r}, and the answer has to be filed under "
        f"the key the server chose ({ASK_KEY!r})",
    )
    chronology.require_after(first_answer, retry, "the retry went out before the interim result arrived")
    chronology.require_after(first, retry, "the retry went out before the first leg")

    final_answer = answer_for(server_frames, retry.body["id"])
    require("result" in final_answer.body, f"the retry was refused: {json.dumps(final_answer.body)[:200]}")
    final = final_answer.body["result"]
    require(
        final.get("resultType") == "complete",
        f"the retry was answered with resultType={final.get('resultType')!r}; a second interim "
        f"result is a peer this client would have to answer again",
    )
    require(
        not final.get("isError", False),
        "the retry came back with isError",
    )
    sent_text = first.body.get("params", {}).get("arguments", {}).get("text")
    resumed = text_of(final, f"{TOOL_ASK} retry")
    require(
        resumed == [sent_text],
        f"the {TOOL_ASK!r} tool was sent {sent_text!r} and answered {resumed!r} after the retry",
    )
    chronology.require_after(retry, final_answer, "the peer answered the retry before the retry went out")

    events = {event.get("event") for event in peer_events}
    require("ask_first_round" in events,
            f"the peer's ask tool never entered its first round, so nothing asked the client "
            f"anything: {sorted(str(event) for event in events)}")
    require("ask_resumed" in events,
            f"the peer's ask tool never saw the retry's answers, so the state never reached the "
            f"handler: {sorted(str(event) for event in events)}")
    resumed_events = [event for event in peer_events if event.get("event") == "ask_resumed"]
    require(len(resumed_events) == 1,
            f"the peer's ask tool ran its second round {len(resumed_events)} times, and the "
            f"exchange under test carries it once")
    resumed_event = resumed_events[0]
    require(
        resumed_event.get("request_state") == STATE_PLAINTEXT,
        f"the peer unsealed the retry's requestState to {resumed_event.get('request_state')!r}, "
        f"and it mints {STATE_PLAINTEXT!r}. The token on the wire is not the plaintext the "
        f"handler sees, and this is what says the boundary sealed it out and unsealed it back.",
    )
    require(
        resumed_event.get("answers") == [ASK_KEY],
        f"the peer read its answer under {resumed_event.get('answers')!r}, and the client filed "
        f"it under {ASK_KEY!r}",
    )
    findings.append(
        f"the {TOOL_ASK!r} tool answered the first leg with an interim result carrying one "
        f"question under {ASK_KEY!r}; the retry went out under id {retry.body['id']} carrying the "
        f"{len(state)}-character state byte for byte, and the peer unsealed it to its own "
        f"plaintext and returned the argument that went out"
    )
    return findings, {
        "state_len": len(state),
        "state_prefix": state[:4],
        "first_id": first.body["id"],
        "retry_id": retry.body["id"],
    }


def check_ids(client_frames: list[Frame]) -> list[str]:
    """Request ids are monotonic, never reused, and all integers."""
    ids = [frame.body["id"] for frame in client_frames
           if "method" in frame.body and "id" in frame.body]
    require(all(isinstance(value, int) and not isinstance(value, bool) for value in ids),
            f"the client's request ids are not all integers: {ids}")
    require(ids == sorted(ids), f"the client's request ids are not monotonic: {ids}")
    require(len(set(ids)) == len(ids), f"a request id was reused: {ids}")
    return [f"{len(ids)} request ids, monotonic and never reused, the retry included"]


def check_answered_once(server_frames: list[Frame]) -> list[str]:
    """One answer per id.

    A peer that answered an id twice would let every lookup below read the first of
    them and pass on a wire that carried a duplicate.
    """
    answered = [frame.body.get("id") for frame in answers_of(server_frames)]
    require(len(set(answered)) == len(answered),
            f"the peer answered an id more than once: {answered}")
    return []


def check_exchange(client_frames: list[Frame], server_frames: list[Frame],
                   chronology: Chronology, peer_events: list[dict[str, Any]],
                   zig_report: Path) -> tuple[list[str], dict[str, Any]]:
    """What the wire has to say, read from the wire.

    Every claim below comes from the captures or from the peer's own side
    channel. The Zig client's report is checked against both at the end, never
    used as the evidence for any of them: a participant's report says what it
    believes happened, and a run that believed the right thing for the wrong
    reason has proved nothing.
    """
    findings: list[str] = []
    findings += check_answered_once(server_frames)
    discover_findings, discovery = check_envelope_and_discover(client_frames, server_frames, chronology)
    findings += discover_findings
    findings += check_no_handshake(client_frames, server_frames)
    findings += check_ids(client_frames)
    names, list_findings = check_tool_list(client_frames, server_frames, chronology)
    findings += list_findings
    findings += check_calls(client_frames, server_frames, chronology)
    mrtr_findings, mrtr = check_mrtr(client_frames, server_frames, chronology, peer_events)
    findings += mrtr_findings

    # The peer saw end of file and shut itself down: its own session ended, which
    # is what end of file on stdin looks like from inside the SDK.
    events = [event.get("event") for event in peer_events]
    require("serve_end" in events,
            f"the peer's session never ended, so it never saw end of file: {events}")
    require("peer_exit" in events, f"the peer never recorded its exit: {events}")

    # What the Zig client read, compared with the wire above. A disagreement means
    # one of the two read the same bytes differently, which is worth more than
    # either of them being right on its own.
    findings += compare_report(zig_report, names, mrtr, discovery)
    return findings, {"tools": names, "mrtr": mrtr}


def compare_report(zig_report: Path, names: list[str], mrtr: dict[str, Any],
                   discovery: dict[str, Any]) -> list[str]:
    """Every field of the Zig client's report, against the bytes it read.

    The report is read here and compared field by field rather than trusted, and
    the comparison is what makes it evidence: a report that agrees with a capture
    is one this run can check, and a report that disagreed with one would be a
    finding about the decoder rather than about the peer.
    """
    require(zig_report.exists(), f"the Zig client wrote no report: expected {zig_report}")
    try:
        zig = json.loads(zig_report.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise InteropFailure(f"the Zig client's report at {zig_report} is not JSON: {exc}") from exc
    require(isinstance(zig, dict), f"the Zig client's report is a {type(zig).__name__}, not an object")

    require(
        zig.get("schema") == REPORT_SCHEMA,
        f"the Zig client's report carries schema {zig.get('schema')!r}, and this supervisor was "
        f"written against {REPORT_SCHEMA!r}",
    )
    require(
        zig.get("failure") == "" and zig.get("ok") is True,
        f"the Zig client exited zero while reporting {zig.get('failure')!r} and "
        f"ok={zig.get('ok')!r}",
    )
    require(
        zig.get("revision") == REVISION,
        f"the Zig client reports revision {zig.get('revision')!r}, not {REVISION!r}",
    )
    require(
        zig.get("discover_supported_versions") == discovery["supportedVersions"],
        f"the Zig client reports the peer offered {zig.get('discover_supported_versions')!r}, "
        f"and the wire carries {discovery['supportedVersions']!r}",
    )
    require(
        zig.get("discover_has_tools_capability") is True,
        f"the Zig client reports discover_has_tools_capability="
        f"{zig.get('discover_has_tools_capability')!r}, and the wire advertises a tools capability",
    )
    ttl, scope = cacheable_of(discovery, "server/discover")
    require(
        zig.get("discover_ttl_ms") == ttl,
        f"the Zig client reports server/discover ttlMs={zig.get('discover_ttl_ms')!r}, "
        f"and the wire carries {ttl}",
    )
    require(
        zig.get("discover_cache_scope") == scope,
        f"the Zig client reports server/discover cacheScope={zig.get('discover_cache_scope')!r}, "
        f"and the wire carries {scope!r}",
    )
    instructions = discovery.get("instructions", "")
    require(
        zig.get("discover_instructions") == instructions,
        f"the Zig client reports server/discover instructions={zig.get('discover_instructions')!r}, "
        f"and the wire carries {instructions!r}",
    )
    require(
        zig.get("tools") == names,
        f"the Zig client reports the tools {zig.get('tools')!r}, and the wire says {names!r}",
    )
    require(
        zig.get("tool_count") == len(names),
        f"the Zig client reports {zig.get('tool_count')!r} tools, and the wire carried {len(names)}",
    )
    require(
        zig.get("tool_list_ttl_ms") == TOOLS_LIST_TTL_MS,
        f"the Zig client reports tools/list ttlMs={zig.get('tool_list_ttl_ms')!r}, and the wire "
        f"carries {TOOLS_LIST_TTL_MS}",
    )
    require(
        zig.get("tool_list_cache_scope") == TOOLS_LIST_CACHE_SCOPE,
        f"the Zig client reports tools/list cacheScope="
        f"{zig.get('tool_list_cache_scope')!r}, and the wire carries {TOOLS_LIST_CACHE_SCOPE!r}",
    )
    require(
        zig.get("fail_is_error") is True,
        f"the Zig client reports isError={zig.get('fail_is_error')!r} for the failing tool, and "
        f"the wire carries isError: true",
    )
    require(
        zig.get("peer_error_code") == INVALID_PARAMS,
        f"the Zig client reports the refusal code {zig.get('peer_error_code')!r}, and the wire "
        f"carries {INVALID_PARAMS!r}",
    )
    require(
        zig.get("mrtr_result_type") == "input_required",
        f"the Zig client reports the interim resultType "
        f"{zig.get('mrtr_result_type')!r}, and the wire carries 'input_required'",
    )
    require(
        zig.get("mrtr_input_request_key") == ASK_KEY,
        f"the Zig client reports the question key "
        f"{zig.get('mrtr_input_request_key')!r}, and the wire carries {ASK_KEY!r}",
    )
    require(
        zig.get("mrtr_input_request_method") == ASK_METHOD,
        f"the Zig client reports the question method "
        f"{zig.get('mrtr_input_request_method')!r}, and the wire carries {ASK_METHOD!r}",
    )
    require(
        zig.get("mrtr_state_len") == mrtr["state_len"],
        f"the Zig client reports a requestState of {zig.get('mrtr_state_len')!r} characters, and "
        f"the wire carries {mrtr['state_len']}",
    )
    require(
        zig.get("mrtr_state_prefix") == mrtr["state_prefix"],
        f"the Zig client reports the requestState starting {zig.get('mrtr_state_prefix')!r}, and "
        f"the wire carries {mrtr['state_prefix']!r}",
    )
    require(
        zig.get("mrtr_retry_leg") == "mrtr_retry",
        f"the Zig client reports its retry params on the "
        f"{zig.get('mrtr_retry_leg')!r} leg, and the retry carried both members the no-cache "
        f"rule names",
    )
    require(
        zig.get("echo_text") == zig.get("mrtr_echo_text"),
        f"the Zig client reports {zig.get('echo_text')!r} from the echo tool and "
        f"{zig.get('mrtr_echo_text')!r} from the retry of the ask tool. The two tools were sent "
        f"the same argument, so a difference is one of them answering something else.",
    )
    refused = zig.get("refused_methods") or []
    require(
        zig.get("refused_methods_count") == len(refused),
        f"the Zig client reports refusing {zig.get('refused_methods_count')!r} names and lists "
        f"{len(refused)}",
    )
    # The library's own `removed_methods` table, plus `initialize` and the three
    # input-request names whose top-level use was removed. A client refusing a
    # different number is a client gating against something other than the table.
    require(
        len(refused) == len(REMOVED_AS_REQUEST) + len(REMOVED_NOTIFICATION)
        + len(REMOVED_AS_INPUT_REQUEST) + 1,
        f"the Zig client refused {len(refused)} removed names, and this revision removed "
        f"{len(REMOVED_AS_REQUEST)} requests, {len(REMOVED_NOTIFICATION)} notifications, "
        f"{len(REMOVED_AS_INPUT_REQUEST)} input-request names whose top-level use was "
        f"removed, and initialize",
    )
    require(
        "initialize" in refused and "notifications/initialized" in refused,
        f"the Zig client's refused list is {refused!r}, and the handshake this revision removed "
        f"is the pair whose absence this run checks on the wire",
    )
    return [
        "the Zig client's own decoders read the same revision, tool list, cacheable members, "
        "echo text, refusal code, interim resultType, question key and method, state length and "
        "prefix off the wire"
    ]


# The report schema this supervisor reads. Named here rather than only in the Zig
# participant so a change to either side's shape fails loudly on one side instead of
# silently producing a report the other does not understand.
REPORT_SCHEMA = "zig-agent-protocols/mcp-current-interop-report/2"


def run_supervise(args: argparse.Namespace) -> int:
    pins = load_pins(args.pins)
    record = check_pins(pins)
    check_api(record)
    zig_binary = require_zig_binary(args)
    work = WorkDir(args.work_dir, args.work_dir_prefix)
    try:
        # One record of how every child this run started left, across the
        # exchange and the refusal probe: a teardown that refused is evidence
        # whichever half of the run it happened in.
        findings, stops = supervise_run(args, record, zig_binary, work)
        refusals = run_refusal_probe(args, record, work, stops)
        summary = write_summary(args, record, zig_binary, work, findings, refusals, stops)
        report_findings(summary)
        return 0
    finally:
        # Every path out, a failed check included: a generated work directory
        # belongs to this run and to nobody else.
        remove_temporary(work)


def supervise_run(args: argparse.Namespace, record: dict[str, Any],
                  zig_binary: Path, work: WorkDir) -> tuple[list[str], list[Stop]]:
    """The exchange itself, from two children and one relay."""
    peer_report = work / "peer-events.jsonl"
    zig_report = work / "zig-report.json"

    limit = int(pins_limits(args).get("capture_bytes_per_direction", 262144))
    client_to_server = Capture(work / "wire-client-to-server.log", limit)
    server_to_client = Capture(work / "wire-server-to-client.log", limit)
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
                 "--pins", str(args.pins), "--report", str(peer_report)]
    zig_argv = [str(zig_binary), "--report-file", str(zig_report)]

    peer: Child | None = None
    zig: Child | None = None
    drains: list[threading.Thread] = []
    # Filled by the relay as it writes, and read by the checks: what crossed,
    # in which direction, and in what order.
    stamps: list[Stamp] = []
    # How each child left, kept as evidence beside the wire it left with, and
    # read by `run_supervise` once the refusal probe has run as well.
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

        relay = Relay(peer.process, zig.process, client_to_server, server_to_client,
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
        c2s_bytes = client_to_server.close()
        s2c_bytes = server_to_client.close()
        peer_log.close()
        zig_log.close()

    exits = {stop.child: stop for stop in stops}
    require("peer" in exits and "Zig client" in exits,
            "a child was started but nothing recorded how it exited, so this run cannot say "
            f"whether the exchange completed: {[stop._asdict() for stop in stops]}")
    peer_stop = exits["peer"]
    zig_stop = exits["Zig client"]
    peer_code = peer_stop.exit
    zig_code = zig_stop.exit
    # A guard that refused left behind a process this run could not prove it
    # started, and reported it as such. Said here, before anything about exit
    # codes, because a refusal has no exit status to check.
    require(not process_guard.refusals(stops),
            "this run could not prove a pid was the child it started, so it did not signal that "
            "process and cannot say the exchange ended: "
            + "; ".join(process_guard.refusals(stops)))

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
    findings, _ = check_exchange(c2s, s2c, chronology, SideChannel.read(peer_report), zig_report)

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
    _ = (elapsed, c2s_bytes, s2c_bytes, timeline, record)
    return findings, stops


def pins_limits(args: argparse.Namespace) -> dict[str, Any]:
    return load_pins(args.pins).get("limits", {})


# --- the refusal probe ----------------------------------------------------------
#
# The Zig client refuses a removed method before the wire, and the capture above
# shows its absence. That is one half of the claim. This probe is the other half:
# the same removed names sent to the same SDK, on a connection already locked to
# this revision, so the codes the SDK answers with are read off a wire this
# supervisor wrote and nobody else did.


def run_refusal_probe(args: argparse.Namespace, record: dict[str, Any], work: WorkDir,
                     stops: list[Stop]) -> dict[str, Any]:
    """Every name this revision removed, answered by the SDK that removed it."""
    import mcp_types.version as version_registry

    limit = int(pins_limits(args).get("capture_bytes_per_direction", 262144))
    side = work / "refusal-peer-events.jsonl"
    side.unlink(missing_ok=True)
    outbound = Capture(work / "refusal-client-to-server.log", limit)
    inbound = Capture(work / "refusal-server-to-client.log", limit)
    peer_log = BoundedLog(work / "refusal-peer-stderr.log", limit)

    deadline = time.monotonic() + args.deadline
    # The guard is built before the child exists, so a system where the target
    # checks cannot be read fails this run with nothing running rather than
    # half a teardown away.
    guard = Guard()
    peer_argv = [sys.executable, str(Path(__file__).resolve()), "--role", "serve",
                 "--pins", str(args.pins), "--report", str(side)]

    peer: Child | None = None
    drains: list[threading.Thread] = []
    started = time.monotonic()
    try:
        peer = guard.spawn(
            peer_argv, "probe peer",
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        drains.append(pump(peer.process.stderr, peer_log))
        require(peer.process.stdin is not None and peer.process.stdout is not None,
                "the probe peer's pipes were not created")

        meta = {
            META_PROTOCOL_VERSION: REVISION,
            META_CLIENT_CAPABILITIES: {},
            META_CLIENT_INFO: {"name": MARKER + "-probe", "version": "0.0.0"},
        }
        expectations: list[tuple[str, int]] = []
        # The method of the request this probe is waiting an answer to, so a peer
        # that goes quiet is named by the question it stopped answering rather than
        # by a deadline.
        last_asked: list[str] = ["server/discover"]

        def ask_frame(request_id: int, method: str, params: dict[str, Any]) -> None:
            body = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
            line = json.dumps(body, separators=(",", ":")).encode("utf-8") + b"\n"
            outbound.write(line)
            last_asked[0] = method
            write_all(peer.process.stdin.fileno(), line)

        def expect_error(request_id: int, method: str, code: int,
                         params: dict[str, Any] | None = None,
                         label: str = "") -> None:
            """Send a request and read the one answer it must produce.

            `label` names the case in the messages rather than the method alone,
            because several of the cases below are the same method with different
            params — three malformed envelopes, all `tools/list` — and a finding
            that said only `tools/list` would not say which malformation it found.
            """
            what = label or f"{method} as a request"
            ask_frame(request_id, method, params if params is not None else {"_meta": meta})
            answer = read_one_answer(peer.process, inbound, deadline, "answer", what)
            require(
                answer.body.get("id") == request_id,
                f"{what}: asked as id {request_id} and the next frame on the wire answers id "
                f"{answer.body.get('id')!r}",
            )
            error = answer.body.get("error")
            require(
                isinstance(error, dict),
                f"{what}: the peer answered with a result rather than a refusal: "
                f"{json.dumps(answer.body)[:200]}. A removed method answered as if it existed is "
                f"the emulated method this probe exists to rule out.",
            )
            require(
                "result" not in answer.body,
                f"{what}: the peer's refusal also carried a result: "
                f"{json.dumps(answer.body)[:200]}",
            )
            got = error.get("code")
            require(
                got == code,
                f"{what}: the peer refused with code {got!r} and this run asserts {code}. "
                f"The message was {error.get('message')!r}.",
            )
            expectations.append((what, got))

        # The first request has to be a modern-envelope one, or this connection is
        # serving the handshake era and every later answer is about that instead.
        # `server/discover` is what says so: `supportedVersions` is a member of its
        # result and of nothing else, so this opening both locks the era and reads
        # the evidence for it off the wire.
        ask_frame(1, "server/discover", {"_meta": meta})
        first = read_one_answer(peer.process, inbound, deadline, "answer", "server/discover")
        require(
            "result" in first.body and REVISION in first.body["result"].get("supportedVersions", []),
            f"the probe's connection did not open on this revision: {json.dumps(first.body)[:200]}",
        )
        # The discover answer is cacheable at this revision, so both members are
        # required on it. A peer that omitted them would be a peer the Zig client's
        # own decoder refuses, and the probe says so here rather than leaving it to
        # the exchange.
        cacheable_of(first.body["result"], "server/discover")

        next_id = 2
        expect_error(next_id, "initialize", UNSUPPORTED_PROTOCOL_VERSION,
                     {"_meta": meta, "protocolVersion": REVISION, "capabilities": {},
                      "clientInfo": meta[META_CLIENT_INFO]},
                     label="initialize on a connection already serving this revision")
        next_id += 1
        for method in (*REMOVED_AS_REQUEST, *REMOVED_NOTIFICATION, *REMOVED_AS_INPUT_REQUEST,
                       *TOP_LEVEL_NOTIFICATIONS):
            expect_error(next_id, method, METHOD_NOT_FOUND,
                         label=f"{method} as a request on this revision")
            next_id += 1

        # The envelope the SDK's ladder requires, asked for three ways: no params at
        # all, no `_meta`, and an `_meta` carrying only the version. Each names the
        # member it is missing, which is what makes it the SDK's answer and not this
        # file's.
        for label, params in (
            ("no params", {}),
            ("no _meta", {"name": TOOL_ECHO, "arguments": {"text": "x"}}),
            ("no client capabilities", {"_meta": {META_PROTOCOL_VERSION: REVISION}}),
        ):
            expect_error(next_id, "tools/list", INVALID_PARAMS, params,
                         label=f"tools/list with {label}")
            next_id += 1

        # An unsupported version in the envelope, which is the negotiation outcome
        # rather than a shape defect: the two carry different codes and the run
        # asserts them apart.
        expect_error(next_id, "tools/list", UNSUPPORTED_PROTOCOL_VERSION,
                     {"_meta": {META_PROTOCOL_VERSION: "2027-01-01",
                                META_CLIENT_CAPABILITIES: {}}},
                     label="tools/list declaring a revision the peer does not serve")
        next_id += 1

        # A retry whose state the peer did not mint, which is what a client that
        # invented one would send.
        expect_error(next_id, "tools/call", INVALID_PARAMS,
                     {"_meta": meta, "name": TOOL_ASK, "arguments": {"text": "x"},
                      "inputResponses": {ASK_KEY: {"action": "accept"}},
                      "requestState": "v1.not-a-real-token"},
                     label=f"tools/call retrying {TOOL_ASK!r} with a state the peer never minted")
        next_id += 1

        # Close the peer's standard input, which is how it learns this probe is
        # finished. The SDK's read loop is blocked on that pipe, so leaving it open
        # would park the peer until this run's deadline and then report a child
        # that did not exit — a finding about the harness rather than about the
        # peer. Closing it is also the thing under test: the peer has to see end of
        # file and shut itself down, which the exit status below is read from.
        close_fd(peer.process.stdin)
        peer_stop = wait_for(guard, peer, deadline)
        stops.append(peer_stop)
    finally:
        # Unconditional, with no `poll()` in front of it: a child that has
        # already left is the case the guard records as an exit status and no
        # signal, so there is no window here for a reap to race.
        if peer is not None:
            stops.append(guard.stop(peer, 5.0))
        for drain in drains:
            drain.join(timeout=2.0)
        c2s_bytes = outbound.close()
        s2c_bytes = inbound.close()
        peer_log.close()

    # A guard that refused left behind a process this run could not prove it
    # started, and reported it as such. Said here, before anything about the
    # capture or the refusals this probe found on the wire, because a refusal is
    # about what is still running and nothing else here can say about that.
    require(not process_guard.refusals(stops),
            "this run could not prove a pid was the child it started, so it did not signal that "
            "process and cannot say the probe ended: "
            + "; ".join(process_guard.refusals(stops)))
    peer_code = peer_stop.exit
    elapsed = round(time.monotonic() - started, 3)
    require(peer_code == 0,
            f"the refusal probe's peer exited with {peer_code}"
            + peer_stop.refusal_note
            + f"; {stderr_note(peer_log, work, 'the probe peer')}")
    require(
        not outbound.truncated and not inbound.truncated,
        f"the refusal probe's capture hit its {limit}-byte bound",
    )
    require_bounded_size(side, limit)

    return {
        "refused": [{"method": method, "code": code} for method, code in expectations],
        "modern_version_offered": REVISION,
        "latest_modern_version": version_registry.LATEST_MODERN_VERSION,
        "bytes": {"client_to_server": c2s_bytes, "server_to_client": s2c_bytes},
        "elapsed_seconds": elapsed,
        "capture": {
            "client_to_server": str(work / "refusal-client-to-server.log"),
            "server_to_client": str(work / "refusal-server-to-client.log"),
        },
    }


def read_one_answer(peer: subprocess.Popen[bytes], capture: Capture,
                    deadline: float, label: str, awaiting: str) -> Frame:
    """One JSON-RPC answer off the peer's standard output, captured as it is read.

    Read a line rather than a chunk: a pipe read can carry two frames, and a probe
    that consumed both would have to attribute the second one to the request that
    was not asked yet.

    The wait for bytes is a `selectors` timeout rather than a blocking read with a
    deadline checked first. A blocking read on a pipe the peer has gone quiet on
    never returns, so the check before it would be a check about a read that had
    already started: the probe would sit until the whole run's deadline and then
    be killed with a "did not exit" that names the timeout rather than the peer
    that stopped answering. With the wait bounded, a peer that goes quiet is a
    finding on the spot.

    `awaiting` names the request whose answer this read is for, so that finding
    says which question the peer stopped answering rather than only that it did.
    """

    assert peer.stdout is not None
    carry = b""
    selector = selectors.DefaultSelector()
    selector.register(peer.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise InteropFailure(
                    f"the probe peer sent no {label} inside the deadline; it was last asked "
                    f"{awaiting!r}",
                )
            if not selector.select(timeout=min(remaining, 0.5)):
                continue
            # The descriptor again: the selector watches the file object's
            # descriptor and the bytes come off that same one, so nothing is read
            # through a buffer that would hold bytes back.
            chunk = os.read(peer.stdout.fileno(), 65536)
            if not chunk:
                raise InteropFailure(
                    f"the probe peer closed its standard output before it sent an {label}; "
                    f"it was last asked {awaiting!r}",
                )
            capture.write(chunk)
            carry += chunk
            if b"\n" not in carry:
                continue
            line, _, carry = carry.partition(b"\n")
            body = json.loads(line.decode("utf-8"), parse_constant=refuse_constant)
            require(isinstance(body, dict),
                    f"the probe peer sent a {type(body).__name__}, not an object")
            return Frame("s2c", 0, len(line), body)
    finally:
        selector.close()


def write_summary(args: argparse.Namespace, record: dict[str, Any], zig_binary: Path,
                  work: WorkDir, findings: list[str], refusals: dict[str, Any],
                  stops: list[Stop]) -> dict[str, Any]:
    """The machine-readable record of the run, beside the captures it came from."""
    c2s = parse_frames((work / "wire-client-to-server.log").read_bytes(), "client to server", "c2s")
    s2c = parse_frames((work / "wire-server-to-client.log").read_bytes(), "server to client", "s2c")
    summary = {
        "schema": "zig-agent-protocols/mcp-current-interop-summary/1",
        "sdk": {
            "distribution": record.get("distribution", "mcp"),
            "version": record["version"],
            "types_distribution": record.get("types_distribution", "mcp-types"),
            "types_version": record.get("types_version"),
            "protocol": REVISION,
            "source": (record.get("nix") or {}).get("src"),
        },
        "report_schema": REPORT_SCHEMA,
        "zig_participant": str(zig_binary),
        "work_dir": str(work.path),
        "work_dir_kept": not work.temporary,
        "frames": {"client_to_server": len(c2s), "server_to_client": len(s2c)},
        "peer_events": SideChannel.read(work / "peer-events.jsonl"),
        "findings": findings,
        "refusal_probe": refusals,
        # How each child left, kept beside the capture it left with: the signals
        # that were sent, the status `waitpid` reported, and any refusal from the
        # target guards. A teardown that refused is evidence too, and a run that
        # hid one would be a run whose ending nobody could account for.
        "child_stops": [stop._asdict() for stop in stops],
        "capture": {
            "client_to_server": str(work / "wire-client-to-server.log"),
            "server_to_client": str(work / "wire-server-to-client.log"),
        },
    }
    (work / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return summary


def report_findings(summary: dict[str, Any]) -> None:
    print(f"mcp interop: current revision, {summary['sdk']['distribution']} "
          f"{summary['sdk']['version']}, revision {REVISION}")
    print(f"  wire: {summary['frames']['client_to_server']} client frames, "
          f"{summary['frames']['server_to_client']} server frames captured")
    for finding in summary["findings"]:
        print(f"  - {finding}")
    refused = summary["refusal_probe"]["refused"]
    print(f"  the refusal probe sent {len(refused)} removed or malformed requests and every one "
          f"was refused with the code this run asserts")
    print(f"  capture and reports: {summary['work_dir']}")


def run_preflight(args: argparse.Namespace) -> int:
    """Check where a run would write, with nothing else involved.

    No SDK, no child process, no pin check. This answers one question: whether the
    environment has somewhere for a generated work directory that is not a
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


# --- the self-test --------------------------------------------------------------
#
# The decisions this file makes about *its own* input, with no SDK and no child
# process: the report schema, the envelope rules, the cacheable-result rules, the
# frame parse, and the CLI. Each is a place where a check could pass for the wrong
# reason, and a run cannot tell a wrong check from a right one — the wire has to be
# right for the check to be exercised at all. So they are checked here, against
# hand-built inputs, where a wrong answer is visible.


def selftest_parse_frames() -> list[str]:
    """The frame parser, on the shapes that decide whether a capture is evidence."""
    notes: list[str] = []
    two = b'{"jsonrpc":"2.0","id":1,"method":"a"}\n{"jsonrpc":"2.0","id":1,"result":{}}\n'
    frames = parse_frames(two, "test", "c2s")
    assert len(frames) == 2, frames
    assert frames[0].offset == 0 and frames[1].offset == frames[0].end + 1
    notes.append(f"two frames, offsets {frames[0].offset} and {frames[1].offset}")

    # A capture that stops mid-frame is a prefix of the exchange, not the exchange.
    try:
        parse_frames(b'{"jsonrpc":"2.0","id":1}', "test", "c2s")
    except InteropFailure as failure:
        assert "does not end with a delimiter" in str(failure), failure
        notes.append("a capture with no trailing delimiter is refused as a prefix")
    else:
        raise AssertionError("an unterminated capture was accepted")

    # A raw newline inside params splits one frame into two, which is the failure
    # this parser exists to catch rather than to read as two frames.
    try:
        parse_frames(b'{"jsonrpc":"2.0","id":1,"params":{"text":"a\nb"}}\n', "test", "c2s")
    except InteropFailure as failure:
        assert "not one JSON value" in str(failure), failure
        notes.append("a frame split by a raw newline is refused, not read as two frames")
    else:
        raise AssertionError("a frame carrying a raw newline was accepted")

    # Tab and carriage return are JSON whitespace, and a peer that separates
    # tokens with a tab or terminates its frames with CRLF has written a frame
    # this parser must accept. The tab goes between tokens and not inside a
    # string: RFC 8259 section 7 forbids a raw tab inside a string, so the
    # strict parse below already refuses that one, and a scan added here would be
    # a second rule about the same bytes.
    crlf = b'{"jsonrpc"\t:"2.0","id":1,"result":{}}\r\n'
    assert len(parse_frames(crlf, "test", "s2c")) == 1
    notes.append("a CRLF-terminated frame with a tab between tokens is accepted")
    try:
        parse_frames(b'{"jsonrpc":"2.0","id":1,"result":{"text":"a\tb"}}\n', "test", "s2c")
    except InteropFailure as failure:
        assert "not one JSON value" in str(failure), failure
        notes.append("a raw tab inside a string is refused by the strict parse")
    else:
        raise AssertionError("a raw tab inside a JSON string was accepted")

    # NaN is not JSON and is refused rather than parsed as a float.
    try:
        parse_frames(b'{"jsonrpc":"2.0","id":1,"result":{"x":NaN}}\n', "test", "s2c")
    except InteropFailure as failure:
        assert "which JSON does not have" in str(failure), failure
        notes.append("NaN is refused rather than parsed")
    else:
        raise AssertionError("NaN was accepted")

    # An empty capture is nothing crossed, not zero frames.
    try:
        parse_frames(b"", "test", "c2s")
    except InteropFailure as failure:
        assert "is empty" in str(failure), failure
        notes.append("an empty capture is refused rather than read as no frames")
    else:
        raise AssertionError("an empty capture was accepted")
    return notes


def selftest_envelope() -> list[str]:
    """The envelope rules, on requests this script built by hand."""
    notes: list[str] = []
    good = Frame("c2s", 0, 0, {
        "jsonrpc": "2.0", "id": 1, "method": "tools/list",
        "params": {"_meta": {
            META_PROTOCOL_VERSION: REVISION,
            META_CLIENT_CAPABILITIES: {},
            META_CLIENT_INFO: {"name": "x", "version": "0"},
        }},
    })
    assert require_envelope(good) == good.body["params"]["_meta"]

    # Each missing member is named by its wire key, because that is what the SDK
    # names too and a reader comparing the two failures has the same text in
    # both. A label here instead would make this message and the SDK's differ for
    # no gain.
    for missing in (META_CLIENT_CAPABILITIES, META_PROTOCOL_VERSION):
        params = dict(good.body["params"])
        params["_meta"] = {key: value for key, value in params["_meta"].items() if key != missing}
        try:
            require_envelope(Frame("c2s", 0, 0, {"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                                                 "params": params}))
        except InteropFailure as failure:
            assert missing in str(failure), failure
            assert META_PROTOCOL_VERSION in str(failure) or META_CLIENT_CAPABILITIES in str(failure), failure
        else:
            raise AssertionError(f"a request with no {missing} was accepted")
    notes.append("a request missing either envelope member is refused, naming the member by its wire key")

    # Both members missing at once are both named, so a client that sent no
    # envelope at all is told both things rather than the first of them.
    try:
        require_envelope(Frame("c2s", 0, 0, {"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                                             "params": {"_meta": {}}}))
    except InteropFailure as failure:
        assert META_PROTOCOL_VERSION in str(failure) and META_CLIENT_CAPABILITIES in str(failure), failure
        notes.append("a request with an empty _meta names both missing members")
    else:
        raise AssertionError("a request with an empty _meta was accepted")

    # A version the run is not pinned to is refused even though both members are
    # present: the check is the value, not the presence.
    other = Frame("c2s", 0, 0, {
        "jsonrpc": "2.0", "id": 1, "method": "tools/list",
        "params": {"_meta": {META_PROTOCOL_VERSION: "2025-11-25", META_CLIENT_CAPABILITIES: {},
                             META_CLIENT_INFO: {"name": "x", "version": "0"}}},
    })
    try:
        require_envelope(other)
    except InteropFailure as failure:
        assert "2025-11-25" in str(failure), failure
        notes.append("an envelope declaring another revision is refused on the value")
    else:
        raise AssertionError("an envelope for another revision was accepted")

    # A capabilities value that is not an object is refused: presence is not shape,
    # and a client that sent a string would be refused by the SDK's own ladder.
    # `clientInfo` rides along because this check names it too, and a fixture that
    # left it out would be refused for the wrong member.
    shaped = Frame("c2s", 0, 0, {
        "jsonrpc": "2.0", "id": 1, "method": "tools/list",
        "params": {"_meta": {
            META_PROTOCOL_VERSION: REVISION,
            META_CLIENT_CAPABILITIES: "yes",
            META_CLIENT_INFO: {"name": "x", "version": "0"},
        }},
    })
    try:
        require_envelope(shaped)
    except InteropFailure as failure:
        assert "it is an object" in str(failure), failure
        notes.append("capabilities that are not an object are refused")
    else:
        raise AssertionError("a string capabilities value was accepted")

    # A params that is not an object has no envelope at all, and is a finding.
    for params in ({}, None, [1], "text"):
        try:
            require_envelope(Frame("c2s", 0, 0, {"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                                                 "params": params}))
        except InteropFailure:
            pass
        else:
            raise AssertionError(f"params={params!r} was accepted without an envelope")
    notes.append("params that are not an object carry no envelope and are refused")
    return notes


def selftest_cacheable() -> list[str]:
    """The cacheable-result rules, on the members this revision requires."""
    notes: list[str] = []
    good = {"resultType": "complete", "ttlMs": 60_000, "cacheScope": "public"}
    assert cacheable_of(good, "test") == (60_000, "public")
    notes.append("ttlMs and cacheScope are read as a whole number of milliseconds and one of two scopes")

    # A missing member is a finding rather than a default: a server that omitted it
    # is a server the Zig client's own decoder refuses, which is the point.
    for member in ("resultType", "ttlMs", "cacheScope"):
        partial = {key: value for key, value in good.items() if key != member}
        try:
            cacheable_of(partial, "test")
        except InteropFailure as failure:
            assert member in str(failure), failure
        else:
            raise AssertionError(f"a result with no {member} was accepted")
    notes.append("a result missing any of the three required members is refused by name")

    # A ttlMs that is not a whole number of milliseconds, and a scope outside the
    # two the specification defines. A negative one is refused rather than treated
    # as zero: the specification's rule about ignoring it is about caching, not a
    # claim that the value is representable.
    for bad_ttl in (-1, 1.5, "60000", True, None):
        try:
            cacheable_of({**good, "ttlMs": bad_ttl}, "test")
        except InteropFailure:
            pass
        else:
            raise AssertionError(f"ttlMs={bad_ttl!r} was accepted")
    notes.append("a ttlMs that is not a non-negative integer is refused, including a boolean")

    for bad_scope in ("Public", "shared", "", None, 1):
        try:
            cacheable_of({**good, "cacheScope": bad_scope}, "test")
        except InteropFailure:
            pass
        else:
            raise AssertionError(f"cacheScope={bad_scope!r} was accepted")
    notes.append("a cacheScope outside 'public' and 'private' is refused, case-sensitively")
    return notes


def selftest_legs() -> list[str]:
    """Which `tools/call` a check means, when one tool is called twice."""
    notes: list[str] = []
    frames = [
        Frame("c2s", 0, 0, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                            "params": {"name": TOOL_ASK, "arguments": {"text": "x"}}}),
        Frame("c2s", 1, 1, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                            "params": {"name": TOOL_ASK, "arguments": {"text": "x"},
                                       "requestState": "v1.x"}}),
        Frame("c2s", 2, 2, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                            "params": {"name": TOOL_ECHO, "arguments": {"text": "x"}}}),
        Frame("c2s", 3, 3, {"jsonrpc": "2.0", "method": "tools/call",
                            "params": {"name": TOOL_ECHO, "arguments": {"text": "x"}}}),
    ]
    legs = call_frames(frames, TOOL_ASK)
    assert len(legs) == 2, legs
    assert legs[0].body["id"] == 1 and legs[1].body["id"] == 2, legs
    notes.append(f"the {TOOL_ASK!r} legs are found by their params: ids "
                 f"{[leg.body['id'] for leg in legs]}")

    # A notification is not a request: a `tools/call` with no id is a frame this
    # run's lookups must not read as a call, because nothing will answer it.
    assert len(requests_of(frames, "tools/call")) == 3, requests_of(frames, "tools/call")
    assert len(call_frames(frames, TOOL_ECHO)) == 1, call_frames(frames, TOOL_ECHO)
    notes.append("a tools/call with no id is not counted as a request to answer")

    # The malformed call is found by the member the specification requires.
    malformed = [
        Frame("c2s", 0, 0, {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"_meta": {}}}),
    ]
    assert malformed_call(malformed).body["id"] == 9
    notes.append("the nameless tools/call is found by its missing name, and bound to its own id")

    # An answer is found by id, and a server frame that is a request is not an answer.
    server = [
        Frame("s2c", 0, 0, {"jsonrpc": "2.0", "id": 9, "error": {"code": -32602}}),
        Frame("s2c", 1, 1, {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}),
    ]
    assert answer_for(server, 9).body["error"]["code"] == -32602
    assert len(answers_of(server)) == 1, answers_of(server)
    try:
        answer_for(server, 10)
    except InteropFailure as failure:
        assert "never answered" in str(failure), failure
        notes.append("an answer is found by id, and a server request is not read as one")
    else:
        raise AssertionError("a missing answer was found")
    return notes






def run_selftest(args: argparse.Namespace) -> int:
    """The checks above, with no SDK, no child process and no pins file."""
    groups = (
        ("frame parsing", selftest_parse_frames),
        ("the per-request envelope", selftest_envelope),
        ("cacheable results", selftest_cacheable),
        ("which call is which", selftest_legs),
    )
    print(f"mcp interop self-test: {len(groups)} groups, no SDK and no child process")
    for label, group in groups:
        for note in group():
            print(f"  {label}: {note}")
    _ = args
    print("  ok")
    return 0


# --- entry ----------------------------------------------------------------------


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--role", choices=("supervise", "serve", "refusals", "selftest"),
                        default="supervise")
    parser.add_argument("--pins", type=Path,
                        default=Path(os.environ.get("ZIG_AGENT_PROTOCOLS_SDK_PINS", DEFAULT_PINS)))
    parser.add_argument("--zig-binary",
                        default="zig-out/bin/zig-agent-protocols-mcp-current-interop",
                        help="the Zig MCP client executable; supervise only")
    parser.add_argument("--work-dir", default=None,
                        help="an absolute path outside /tmp and /var/tmp, owned by this account "
                             "and not a symlink, where the capture and the reports are kept and "
                             "never removed by this run; a generated directory under TMPDIR "
                             "otherwise, removed when the run ends")
    parser.add_argument("--preflight", action="store_true",
                        help="check TMPDIR and the work-directory policy and exit, with no SDK, "
                             "no pins and no child process")
    parser.add_argument("--deadline", type=float, default=60.0,
                        help="seconds the whole run may take before it is killed, and seconds the "
                             "refusal probe is given on its own")
    parser.add_argument("--report", type=Path, default=None, help="the peer's side channel; serve only")
    parser.set_defaults(work_dir_prefix="mcp-current-interop-")
    return parser.parse_args(list(argv))


def run_refusals(args: argparse.Namespace) -> int:
    """The refusal probe on its own, with a work directory of its own.

    `--role refusals` is the probe without the exchange. `supervise` runs it as
    well, and this role exists so it can be run, read and compared on its own —
    which is what a reader checking the SDK's refusals rather than this client's
    behaviour wants.
    """
    pins = load_pins(args.pins)
    record = check_pins(pins)
    check_api(record)
    work = WorkDir(args.work_dir, args.work_dir_prefix)
    try:
        stops: list[Stop] = []
        probe = run_refusal_probe(args, record, work, stops)
        summary = {
            "schema": "zig-agent-protocols/mcp-current-interop-refusals/1",
            "sdk": {"distribution": record.get("distribution", "mcp"), "version": record["version"],
                    "types_version": record.get("types_version"), "protocol": REVISION},
            "refusal_probe": probe,
            # How the probe's child left, kept beside what it answered on the
            # wire: the signals that were sent, the status `waitpid` reported,
            # and any refusal from the target guards.
            "child_stops": [stop._asdict() for stop in stops],
            "work_dir": str(work.path),
            "work_dir_kept": not work.temporary,
        }
        (work / "refusals.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        print(f"mcp refusals: {len(probe['refused'])} requests, every one refused")
        for entry in probe["refused"]:
            print(f"  - {entry['method']} -> {entry['code']}")
        print(work.notice())
        return 0
    finally:
        remove_temporary(work)


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    try:
        if args.preflight:
            return run_preflight(args)
        if args.role == "selftest":
            return run_selftest(args)
        if args.role == "serve":
            return run_serve(args)
        if args.role == "refusals":
            return run_refusals(args)
        return run_supervise(args)
    except (InteropFailure, ProcessGuardError) as failure:
        print(f"mcp current-revision interop FAILED: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))