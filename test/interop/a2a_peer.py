#!/usr/bin/env python3
"""A2A 1.0 interoperability: one genuine SDK peer, and the Zig participant on both ends of it.

The SDK is upstream `a2a-sdk` at the release `sdk-pins.json` records, and its
own 1.0 classes carry every message on the wire. Nothing here re-implements a
card, a message or a JSON-RPC frame to stand in for it: where the SDK can be
used, it is used, and the bytes the supervisor records are the bytes that
crossed a socket.

Four roles, all in this one file because they are the ends of one wire:

``--role serve``
    The genuine SDK agent: a Starlette app carrying the SDK's own Agent Card
    route and JSON-RPC route, served by uvicorn on loopback over a socket this
    process binds and starts listening on before it reports readiness, so a
    supervisor that dials the moment it reads that line is answered rather
    than refused. The card advertises one supported interface at a path that
    is deliberately neither the SDK default ``/`` nor the ``/rpc`` a client
    would guess, and with a query on it, because a client that reads the card
    and a client that guesses are not the same client and only one of them is
    being tested. The card may also name a port other than the one uvicorn
    listens on, which is what lets the supervisor relay the wire and still have
    the card advertise a dialable endpoint.

``--role probe``
    The genuine SDK client: resolve the card, select the advertised JSONRPC
    interface and its protocol version, bind the ``A2A-Version`` header to that
    version's major and minor, and send messages. It also asks for things the
    agent refuses, because a peer that only ever says yes proves nothing about
    the error path. Every fact it learns is recorded.

``--role zig-interop``
    The actual interoperability run. It drives both directions, each with the
    wire relayed through this process so the bytes are recorded rather than
    summarised:

    - the Zig client (``src/a2a_interop.zig --role client``) against the SDK's
      own agent, and
    - the SDK's own client against the Zig server
      (``src/a2a_interop.zig --role server``).

    Each direction asserts, from the recorded wire and not from a summary the
    participant wrote about itself: the card was discovered at the well-known
    path, every POST went to the endpoint that card advertises — path, query
    and authority alike, with the constant this process handed the participant
    checked against the card rather than the other way round — the
    ``A2A-Version`` header was bound to the selected major and minor,
    ``SendMessage`` answered with a Task on one path and a Message on the
    other, an unknown method came back as a JSON-RPC error with no result
    member beside it, and an unsupported version was refused with the agent's
    own code rather than ignored.

``--role supervise``
    The SDK client against the SDK agent. This is a **baseline**, not
    interoperability: two ends of the same library prove the SDK agrees with
    itself and they prove nothing at all about this repository. It is kept
    because it is what says what the SDK does when nothing of ours is in the
    way, and a Zig run whose SDK answers differ from this baseline has to be
    able to say which end moved.

The checks, and what each is evidence of:

* the card is discoverable at the well-known path the specification names, the
  bytes on it are the card, and the SDK's own resolver reads the same card;
* the interface selection follows the card: the first supported JSONRPC
  binding, its own protocol version, and a malformed advertised version refused
  rather than coerced;
* the ``A2A-Version`` header is bound to the selected major and minor, and a
  header the agent does not support is refused with the agent's own error code
  rather than quietly ignored;
* ``SendMessage`` answers with a typed result: a Task on one path and a Message
  on another. The two are a oneof on the wire, and a client has to tell them
  apart;
* an unknown method is a JSON-RPC error with no result member beside it.

Versions, hashes and the API facts this file depends on are recorded in
``sdk-pins.json``, which every role reads and checks itself against.

Where a run writes: the wire captures, the reports and the logs all go into one
work directory. Named with ``--work-dir``, it is kept, because a capture
somebody asked for is evidence. Otherwise it is created inside the
environment's ``TMPDIR`` and removed when the run ends, on success and on
failure alike, so a run leaves nothing behind and reports which of the two it
did instead of printing a path that no longer exists. ``TMPDIR`` is the only
thing that decides where a generated directory may be created, and a system
temporary directory is refused either way. Every role writes only the paths it
is given, so none creates a work directory of its own.

Nothing here makes any claim about what the SDK does internally: the captures
are bytes and the assertions are shapes.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from collections.abc import Callable
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urljoin, urlsplit

HERE = Path(__file__).resolve().parent
DEFAULT_PINS = HERE / "sdk-pins.json"

# The path the SDK's own route is mounted at, and the query the card advertises
# beside it. Two values because the route matches on the path and the card
# carries both: a client that reads the card has to send the query, and a route
# cannot be mounted on a path that still has one attached.
#
# The path is neither the SDK default (`/`) nor the `/rpc` a client would guess:
# a peer whose endpoint is where a guesser expects it cannot tell the two
# clients apart. The query is there for the same reason — an endpoint with
# nothing but a path is one a client could have reconstructed by accident.
RPC_PATH = "/agents/echo/a2a-v1"
RPC_QUERY = "peer=sdk"


def advertised_endpoint(path: str, query: str) -> str:
    """The path-and-query the card advertises, and every assertion compares to.

    Written down once because the card, the Zig client's `--expect-endpoint` and
    the endpoint assertions all have to agree on these bytes, and a query
    assembled in three places is a query that will be assembled three different
    ways.
    """
    return f"{path}?{query}" if query else path


# A fixed marker rather than a path or a hostname: what this writes is kept as
# evidence, and evidence should not carry anything about the machine. It is also
# what the card's own `version` member carries, that member being free text:
# the card names the agent it is, and claims no version of anything. Which SDK
# is behind it is a fact about this run, recorded in the readiness line and the
# summary rather than published as though it were part of the protocol.
MARKER = "zig-agent-proto-interop"

PROTOCOL_VERSION = "1.0"

# The binding token 1.0 spells, and the one an interface is matched against
# before its version is even read. Pinned as
# sdks["a2a-sdk"].protocol.TransportProtocol_JSONRPC and written down here
# because the wire checks read a captured card and cannot ask the SDK.
JSONRPC_BINDING = "JSONRPC"

# The text that asks the agent for the other arm of the result oneof. The agent
# is an echo agent and answers on what it is told, which is why this is the
# text rather than a request member: the switch has to survive the protobuf
# round trip, and the text is the one field both ends certainly carry.
ASK_FOR_TASK = "result:task"
ASK_FOR_MESSAGE = "result:message"


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
            f"pinned environment (`devenv shell`, then `interop-python`, or `interop-a2a`)."
        ) from exc


def check_pins(pins: dict[str, Any], distribution: str) -> dict[str, Any]:
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
# either: they are shared with every other process on the host, so an expected
# interface left there outlives the run that produced it and nobody can say
# whose it is. Which scratch is approved is the environment's decision, and it
# says so in TMPDIR; nothing here carries a path of its own.
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
            f"every process on the host. If you want the expected interface kept, name a "
            f"directory on this machine's own storage.",
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
                    f"  pass --work-dir <dir> to keep the expected interface and the reports")
        return f"  expected interface and reports: {self.path}"

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

    The same cap the wire capture gets on the MCP side, and for the same
    reason: an unbounded log beside a failing run is the artifact nobody opens.
    The last lines are kept in memory as well, because a generated work
    directory is removed on the way out and the message still has to carry the
    evidence.
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


# --- the agent ------------------------------------------------------------------


def build_agent_card(rpc_url: str) -> Any:
    """The card, with the endpoint it advertises in the place 1.0 puts it.

    `AgentCard` is a protobuf message in this SDK and it has no `url` field: the
    endpoints are `supported_interfaces`, each with its own url, binding and
    version. A card that advertised an endpoint any other way would be testing
    a shape 1.0 does not have.

    `version` is the marker and not the SDK's package version. 1.0 says a patch
    version must not appear in an Agent Card (PROTOCOLS.md §5.1, lines 997-999:
    "Patch versions MUST NOT appear in a request, a response, or an Agent
    Card"), and `1.2.1` is a patch version: putting the package version here
    would publish a version of a peer on the wire as though it were a version
    of the protocol. Which SDK is being spoken to is recorded where it belongs
    — `sdk-pins.json`, the readiness line, and the run's summary — and nothing
    about the card depends on it.
    """
    from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill

    return AgentCard(
        name=f"{MARKER}-agent",
        description="Interoperability peer for zig-agent-proto. Fixed inputs, fixed outputs.",
        version=MARKER,
        supported_interfaces=[
            AgentInterface(
                url=rpc_url,
                protocol_binding="JSONRPC",
                protocol_version=PROTOCOL_VERSION,
            )
        ],
        capabilities=AgentCapabilities(streaming=False, push_notifications=False),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        skills=[
            AgentSkill(
                id="echo",
                name="echo",
                description="Answer a message with a Task, or with a Message when the text asks for it.",
                tags=["interop"],
                examples=[ASK_FOR_TASK, ASK_FOR_MESSAGE],
                input_modes=["text/plain"],
                output_modes=["text/plain"],
            )
        ],
    )


def run_serve(args: argparse.Namespace) -> int:
    """The genuine SDK agent, over loopback HTTP.

    The port is bound and listening before the readiness line is written and
    uvicorn is handed the socket that was bound, so readiness here means the
    transport already accepts connections rather than that a process intends
    to.
    """
    pins = load_pins(args.pins)
    record = check_pins(pins, "a2a-sdk")

    import uvicorn
    from a2a.helpers import new_task_from_user_message
    from a2a.server.agent_execution import AgentExecutor
    from a2a.server.request_handlers import DefaultRequestHandler
    from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
    from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
    from a2a.types import Message, Part, Role
    from a2a.utils import constants as a2a_constants
    from a2a.utils.errors import UnsupportedOperationError
    from starlette.applications import Starlette

    require(
        a2a_constants.PROTOCOL_VERSION_CURRENT == PROTOCOL_VERSION,
        f"the installed SDK speaks {a2a_constants.PROTOCOL_VERSION_CURRENT!r}, not {PROTOCOL_VERSION!r}",
    )

    class EchoExecutor(AgentExecutor):
        """Answers one message, in whichever of the two result shapes it asked for."""

        async def execute(self, context: Any, event_queue: Any) -> None:
            text = context.get_user_input()
            if ASK_FOR_MESSAGE in text:
                # A bare message: no task, no status, and the framework treats a
                # message as the whole interaction, so this is the arm of the
                # result oneof that a task can never also be.
                #
                # Nothing has to be published before it, and that is a fact
                # about the framework rather than a choice: the task machinery
                # below starts on the first `Task` event and this arm never
                # sends one. What this arm does have to be is the only event —
                # `EventConsumer._handle_message_event` (a2a-sdk 1.2.1,
                # `src/a2a/server/agent_execution/active_task.py` lines
                # 240-249) refuses a Message that is not the first event, and
                # `EventConsumer._handle_task_event` refuses any task event
                # once one has been seen (same file, lines 258-261) — and it
                # is, because `execute` returns the moment it is queued and the
                # only thing after it is the producer's own `_RequestCompleted`
                # (same file, lines 617-619), which the consumer reads as a
                # request boundary and not as an agent event.
                await event_queue.enqueue_event(
                    Message(
                        message_id=f"{MARKER}-answer",
                        role=Role.ROLE_AGENT,
                        parts=[Part(text=f"{MARKER}:{text}")],
                    )
                )
                return

            # The Task goes first, before any `TaskStatusUpdateEvent` and before
            # any `TaskArtifactUpdateEvent`. That order is the framework's, and
            # getting it wrong is answered to the caller as a protocol error:
            # `ActiveTask` holds `_task_created` clear (same file, line 454)
            # until a `Task` event has been written to the task store
            # (`EventConsumer._process_event_inner`, lines 234-236), and
            # `EventConsumer._handle_task_modification_event` refuses a
            # `TaskStatusUpdateEvent` arriving while it is still clear and the
            # store has no task under that id (lines 285-299):
            # `InvalidAgentResponseError('Agent should enqueue Task before
            # TaskStatusUpdateEvent event')`. The dispatcher renders that
            # error as JSON-RPC -32006 (`src/a2a/utils/errors.py` line 143), so
            # publishing a `TaskUpdater.submit()` as the first event fails the
            # whole SendMessage rather than reporting a task.
            # `AgentExecutor.execute` states the same rule as one of two
            # allowed workflows: "Asynchronous/Long-running: Enqueue a `Task`
            # object, perform work, and emit multiple `TaskStatusUpdateEvent` /
            # `TaskArtifactUpdateEvent` objects over time"
            # (`src/a2a/server/agent_execution/agent_executor.py` lines
            # 55-58).
            #
            # The Task is the SDK's own factory rather than a protobuf written
            # out here, because that is where the two ids and the first message
            # belong: `new_task_from_user_message` takes `task_id` and
            # `context_id` off the user's message and seeds `history` with it
            # (`src/a2a/helpers/proto_helpers.py` lines 277-292), and those
            # two ids are ones the framework already resolved onto that very
            # message — `RequestContext._check_or_generate_task_id` and
            # `_check_or_generate_context_id` write them there before `execute`
            # is called (`src/a2a/server/agent_execution/context.py` lines
            # 168-192). So the Task carries the ids the framework is holding:
            # `TaskManager.save_task_event` refuses a Task whose id or
            # context_id differs from the ones it was constructed with
            # (`src/a2a/server/tasks/task_manager.py` lines 225-240), and
            # `on_message_send` compares the id once more before it answers
            # (`default_request_handler_v2.py` lines 408-413).
            await event_queue.enqueue_event(
                new_task_from_user_message(context.message)
            )

            updater = TaskUpdater(event_queue, context.task_id, context.context_id)
            await updater.submit()
            await updater.start_work()
            await updater.add_artifact([Part(text=f"{MARKER}:{text}")], name="echo")
            await updater.complete()

        async def cancel(self, context: Any, event_queue: Any) -> None:
            """There is no work in progress here, so this agent cancels nothing.

            `AgentExecutor` declares `cancel` abstract beside `execute`
            (a2a-sdk 1.2.1, `src/a2a/server/agent_execution/agent_executor.py`
            lines 69-82), so a subclass without it cannot be instantiated at
            all — which is the error this method was added for. Its docstring
            asks an agent to stop the work and publish TASK_STATE_CANCELED;
            `execute` answers inside a single call and every task it opens is
            terminal before that call returns, so there is no work to stop and
            publishing a cancellation would assert something that never
            happened.

            Refusing is the SDK's own way of saying so. `ActiveTask.cancel`
            awaits this coroutine and re-raises whatever comes out of it
            (`src/a2a/server/agent_execution/active_task.py` lines 833-842,
            after marking the task FAILED on the way out, lines 945-963), and
            `DefaultRequestHandlerV2._cancel_local` catches precisely
            `UnsupportedOperationError` and turns it into
            `TaskNotCancelableError`
            (`src/a2a/server/request_handlers/default_request_handler_v2.py`
            lines 244-253), which the dispatcher renders as JSON-RPC -32002
            (`src/a2a/utils/errors.py` line 139). A task that is already
            terminal never reaches this method: `on_cancel_task` refuses it
            before the registry lookup (same file, lines 232-234).

            The card claims nothing here either. 1.0 `AgentCapabilities` has
            no cancellation flag — its fields are `streaming`,
            `push_notifications`, `extensions` and `extended_agent_card`
            (`src/a2a/types/a2a_pb2.pyi` lines 235-245) — so there is nothing
            in what is advertised that this answer contradicts.
            """
            raise UnsupportedOperationError(
                message=(
                    f"{MARKER} holds no work between requests, so it cancels no "
                    f"task: {context.task_id!r} was not cancelled"
                ),
            )

    # The listening socket is bound and listening here, before the readiness
    # line further down is written. The supervisor reads that line and dials
    # straight away, and a socket that only came into being once uvicorn.run
    # had been called would answer the first connection with a refusal against
    # a port nothing had bound yet — a refusal this process caused, which
    # whoever read it would have to explain as somebody else's failure.
    #
    # uvicorn is then handed this same descriptor rather than a host and a
    # port. Serving a socket somebody else already owns is what
    # Config.bind_socket() followed by Server.run(sockets=[sock]) is for, and
    # it is what uvicorn's own reload and multi-worker paths do (uvicorn 0.51.0
    # main.py: `config.bind_socket()` then `ChangeReload(config,
    # target=server.run, sockets=[sock])`, the version devenv.nix resolves from
    # the pinned nixpkgs). Server.startup hands every socket in `sockets`
    # straight to loop.create_server(sock=sock, backlog=config.backlog), so
    # the descriptor answering requests is the one bound here and nothing binds
    # it twice. Server.run is synchronous — it drives serve() through
    # asyncio_run — so this call owns the process until the server stops.
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", args.port))
        # listen() and not bind() alone: a socket with no accept queue refuses
        # a connection the kernel would otherwise have completed.
        listener.listen(socket.SOMAXCONN)
        # What the kernel gave, not what was asked for: --port 0 is a port
        # chosen here, and a card or a readiness line naming 0 names nothing
        # dialable.
        bound_port = int(listener.getsockname()[1])

        # The card names the base a client can dial, which is not always the
        # base uvicorn listens on: the supervisor relays the wire through its
        # own socket and the card still has to advertise an endpoint that
        # reaches the agent. The route is mounted on the path alone, because
        # the query belongs to the card and a client appends it to the request
        # itself.
        card_url = f"{args.advertise_base or f'http://127.0.0.1:{bound_port}'}" \
                   f"{advertised_endpoint(args.rpc_path, args.rpc_query)}"
        card = build_agent_card(card_url)
        handler = DefaultRequestHandler(
            agent_executor=EchoExecutor(),
            task_store=InMemoryTaskStore(),
            agent_card=card,
        )
        # The card route and the JSON-RPC route are the SDK's own; the paths
        # are the only thing this file decides.
        app = Starlette(routes=[
            *create_agent_card_routes(card, card_url=a2a_constants.AGENT_CARD_WELL_KNOWN_PATH),
            *create_jsonrpc_routes(handler, rpc_url=args.rpc_path),
        ])

        # Readiness on stdout, which the wire does not use: this is an HTTP
        # agent. Written after the listen above and before uvicorn is handed
        # the socket, so the only thing a reader is not yet getting is a
        # protocol exchange — the connection itself is held by the kernel.
        print(json.dumps({
            "event": "listening",
            "port": bound_port,
            "card_path": a2a_constants.AGENT_CARD_WELL_KNOWN_PATH,
            "rpc_path": args.rpc_path,
            "rpc_query": args.rpc_query,
            "advertised_url": card_url,
            "a2a_sdk": record["version"],
        }), flush=True)

        uvicorn.Server(uvicorn.Config(
            app,
            host="127.0.0.1",
            port=bound_port,
            log_level="warning",
            access_log=False,
        )).run(sockets=[listener])
    finally:
        # Every way out closes the descriptor. Server.shutdown closes the
        # sockets it was given, so on a normal stop this is the second close
        # close_fd exists to absorb, and on a failure anywhere between the
        # bind and the run it is the only one.
        close_fd(listener)
    return 0


# --- the probe ------------------------------------------------------------------


async def probe(base_url: str, emit: Path | None, record: dict[str, Any]) -> dict[str, Any]:
    """Discover, select, bind, send, and refuse. Every fact is recorded."""
    import httpx
    from a2a.client import A2ACardResolver
    from a2a.client.client import ClientConfig
    from a2a.client.client_factory import ClientFactory
    from a2a.utils import constants as a2a_constants

    facts: dict[str, Any] = {
        "base_url": base_url,
        "card_path": a2a_constants.AGENT_CARD_WELL_KNOWN_PATH,
        "a2a_sdk": record["version"],
    }

    transport = httpx.AsyncClient(timeout=10.0)
    try:
        # 1. Discovery. The bytes first, because the card on the wire is what a
        #    client has to read, and the SDK's resolver second, because a
        #    client that cannot use the resolver is not interoperable either.
        card_response = await transport.get(f"{base_url}{facts['card_path']}")
        require(card_response.status_code == 200,
                f"the card came back as HTTP {card_response.status_code}")
        card_json = card_response.json()
        facts["card"] = card_json

        card = await A2ACardResolver(httpx_client=transport, base_url=base_url).get_agent_card()
        sdk_interfaces = [
            {"url": entry.url, "protocolBinding": entry.protocol_binding,
             "protocolVersion": entry.protocol_version}
            for entry in card.supported_interfaces
        ]
        facts["sdk_resolver_interfaces"] = sdk_interfaces
        require(
            sdk_interfaces == card_json.get("supportedInterfaces", []),
            f"the SDK's resolver read a different card than the wire carries: {sdk_interfaces} "
            f"against {card_json.get('supportedInterfaces')}",
        )

        interfaces = card_json.get("supportedInterfaces") or []
        require(interfaces, "the card advertises no supported interface at all")
        if card_json.get("protocolVersion"):
            require(
                card_json["protocolVersion"] == PROTOCOL_VERSION,
                f"the card advertises protocol {card_json['protocolVersion']!r}, not {PROTOCOL_VERSION!r}",
            )

        # 2. Selection: the first interface whose binding this client speaks,
        #    and its own version. A malformed advertised version is refused
        #    rather than coerced, because coercing it is how a client ends up
        #    binding a header the agent never agreed to.
        selected = None
        for entry in interfaces:
            version = entry.get("protocolVersion")
            require(
                isinstance(version, str) and version.strip() != "",
                f"the card advertises an interface with no protocol version: {entry}",
            )
            major_minor = ".".join(version.split(".")[:2])
            require(
                is_major_minor(major_minor),
                f"the card advertises a protocol version that is not Major.Minor: {version!r}",
            )
            if entry.get("protocolBinding") == a2a_constants.TransportProtocol.JSONRPC.value:
                selected = {**entry, "majorMinor": major_minor}
                break
        require(
            selected is not None,
            f"the card advertises no JSONRPC interface: "
            f"{[entry.get('protocolBinding') for entry in interfaces]}",
        )
        facts["selected_interface"] = selected
        facts["a2a_version_header"] = selected["majorMinor"]

        # The advertised URL is used as advertised, resolved against the origin
        # the card came from. A client that guessed would have used the SDK's
        # default; the difference is the point of the endpoint.
        advertised = selected.get("url") or ""
        require(
            advertised.startswith("/") or "://" in advertised,
            f"the card advertises a url that is neither a path nor absolute: {advertised!r}",
        )
        endpoint = urljoin(f"{base_url}/", advertised)
        facts["endpoint"] = endpoint

        # 3. The version header, bound to the selected major and minor.
        transport.headers[a2a_constants.VERSION_HEADER] = selected["majorMinor"]
        client = ClientFactory(ClientConfig(httpx_client=transport, streaming=False)).create(card)

        task_result = await _send(client, ASK_FOR_TASK)
        facts["send_message_task"] = task_result
        require(task_result["kind"] == "task",
                f"a SendMessage that asked for a task came back as {task_result['kind']}")

        message_result = await _send(client, ASK_FOR_MESSAGE)
        facts["send_message_message"] = message_result
        require(message_result["kind"] == "message",
                f"a SendMessage that asked for a message came back as {message_result['kind']}")

        # 4. A refusal. An unknown method is a JSON-RPC error, and that error
        #    is what tells a caller the method does not exist, as distinct from
        #    a call that was made and failed.
        refusal = await _raw_call(transport, endpoint, "NoSuchMethod", {},
                                  selected["majorMinor"])
        facts["unknown_method"] = refusal
        require(
            refusal.get("error") is not None and refusal.get("result") is None,
            f"an unknown method did not come back as a JSON-RPC error: {refusal}",
        )

        # 5. Version validation. A header the agent does not support is refused,
        #    rather than ignored and answered as if it had not been sent: a
        #    client that binds the wrong version has to find out.
        rejected = await _raw_call(transport, endpoint, "GetTask", {"id": "no-such-task"}, "0.3")
        facts["rejected_version"] = rejected
        require(
            rejected.get("error") is not None,
            f"an unsupported A2A-Version header was answered as if it had not been sent: {rejected}",
        )
        facts["rejected_version_code"] = rejected["error"].get("code")
    finally:
        await transport.aclose()

    if emit is not None:
        emit.write_text(json.dumps(facts, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return facts


async def _send(client: Any, text: str) -> dict[str, Any]:
    """One unary SendMessage, read as whichever arm of the oneof came back."""
    # The SDK's own converter, so the field names here are the names on the wire
    # rather than a second naming convention this file invented.
    from google.protobuf.json_format import MessageToDict

    from a2a.types import Message, Part, Role, SendMessageRequest

    request = SendMessageRequest(
        message=Message(
            message_id=f"{MARKER}-request",
            role=Role.ROLE_USER,
            parts=[Part(text=text)],
        ),
    )
    async for response in client.send_message(request):
        # The SDK converts a non-streaming answer into a StreamResponse so a
        # caller sees one iterator either way, and this client asked for
        # non-streaming, so the first item is the answer.
        if response.HasField("task"):
            return {"kind": "task", "task": MessageToDict(response.task)}
        if response.HasField("message"):
            return {"kind": "message", "message": MessageToDict(response.message)}
    raise InteropFailure(f"SendMessage for {text!r} produced no result at all")


async def _raw_call(client: Any, url: str, method: str, params: dict[str, Any],
                    version: str) -> dict[str, Any]:
    """A JSON-RPC call with no SDK help, for the paths the SDK would not take.

    The SDK's own client would refuse to send an unknown method or a version it
    does not speak, and the point here is to see what the agent answers, so the
    bytes go out by hand. The header is still bound, because the agent validates
    it on every method and a hand-written call must not be the one that skips it.
    """
    body = {"jsonrpc": "2.0", "id": f"{MARKER}-probe", "method": method, "params": params}
    response = await client.post(url, json=body, headers={
        "A2A-Version": version,
        "Content-Type": "application/json",
    })
    reply = response.json()
    require(
        isinstance(reply, dict) and reply.get("jsonrpc") == "2.0"
        and reply.get("id") == body["id"]
        and (("error" in reply) != ("result" in reply)),
        f"{method} returned an invalid or uncorrelated JSON-RPC response: {reply}",
    )
    # A peer error remains a peer error on a non-2xx HTTP response.
    require(response.status_code == 200 or "error" in reply,
            f"{method} came back as HTTP {response.status_code} without a peer error: "
            f"{response.text[:200]}")
    return reply


def is_major_minor(text: str) -> bool:
    parts = text.split(".")
    return len(parts) == 2 and all(part.isdigit() for part in parts)


# --- the supervisor -------------------------------------------------------------


def free_port() -> int:
    with socket.socket() as probe_socket:
        probe_socket.bind(("127.0.0.1", 0))
        return int(probe_socket.getsockname()[1])


def terminate(process: subprocess.Popen[str], grace: float) -> int | None:
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


# A readiness line is one JSON object, so a pipe carrying more than this
# without one in it is a child that is not reporting readiness. The cap is
# what keeps the wait bounded in memory as well as in time.
READINESS_LIMIT_BYTES = 64 * 1024
READINESS_CHUNK_BYTES = 4096


def wait_for_line(process: subprocess.Popen[str], deadline: float,
                  note: Callable[[], str] | None = None) -> dict[str, Any]:
    """The child's one line of readiness, or a failure naming why it never came.

    The deadline is enforced while waiting rather than between waits. A
    blocking read on a pipe the child holds open and writes nothing into
    returns only when the child writes, closes or exits, so a guard around the
    loop is never reached, and a child that comes up and then goes quiet holds
    the run open for good. Polling with whatever budget is left is what makes
    `--deadline` mean what it says for that child.

    Only whole lines are parsed, and what is held between them is bounded: a
    line the child never finishes is a line this run cannot use, so the rest of
    it is waited for rather than the partial line being taken as readiness.
    """
    assert process.stdout is not None
    # The agent's own stderr is what explains a child that never got this far,
    # and a generated work directory is about to be removed, so the note is
    # built here rather than left as a path for the caller to chase.
    where = "" if note is None else f"; {note()}"
    carry = b""
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if not selector.select(remaining):
                continue
            # The raw descriptor, the way the stderr drain reads it: nothing
            # has touched this pipe yet, and a buffered reader around it could
            # be holding bytes this loop needs to see.
            chunk = os.read(process.stdout.fileno(), READINESS_CHUNK_BYTES)
            if not chunk:
                # The child closed its readiness pipe, which is not the same as
                # the child being gone, so it is taken down here rather than
                # left for the caller's teardown to find.
                terminate(process, 5.0)
                raise InteropFailure(
                    f"the agent exited with {process.poll()} before it was ready{where}")
            carry += chunk
            if len(carry) > READINESS_LIMIT_BYTES:
                # A child that floods its pipe is not reporting readiness
                # either, and it is a child that would keep writing into a run
                # that has already failed.
                terminate(process, 5.0)
                raise InteropFailure(
                    f"the agent wrote more than {READINESS_LIMIT_BYTES} bytes to standard "
                    f"output without a line of readiness in it{where}")
            while b"\n" in carry:
                line, carry = carry.split(b"\n", 1)
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    continue
    finally:
        selector.close()
    # The deadline is the answer, so the child that missed it is taken down
    # here rather than left for the caller's teardown to find.
    terminate(process, 5.0)
    raise InteropFailure(f"the agent did not report itself ready within the deadline{where}")



class Capture:
    """The raw wire, one file per direction, byte for byte.

    Nothing is reformatted on the way in: what the supervisor writes is what
    crossed the socket, which is the only claim worth making about a capture.
    The bound is a cap on evidence, and reaching it fails the run rather than
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

    def close(self) -> int:
        self._handle.close()
        return self._written


class Relay:
    """Byte for byte between one client and one server, with a capture as a tee.

    The two ends of an HTTP exchange are two sockets this process opened
    neither, so without a relay the bytes between them are invisible and the
    only record of the exchange would be what one of the peers says about
    itself. Each connection is copied in both directions unmodified, so each
    peer sees the other's bytes exactly, and every byte that crossed is on
    disk before the run ends.

    Connections are handled one at a time and may be as many as the exchange
    opens, because an HTTP/1.1 client is free to reuse a connection and to open
    another for the next request; a relay that served one connection and closed
    would be testing a connection policy rather than a protocol.
    """

    def __init__(self, target_port: int, to_server: Capture, to_client: Capture,
                 deadline: float) -> None:
        self._target_port = target_port
        self._to_server = to_server
        self._to_client = to_client
        self._deadline = deadline
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(16)
        self._listener.settimeout(0.5)
        self._stop = threading.Event()
        self._live: list[socket.socket] = []
        self._live_lock = threading.Lock()
        self.failure: str | None = None
        self._thread = threading.Thread(target=self._accept, name="relay-accept", daemon=True)

    @property
    def port(self) -> int:
        return int(self._listener.getsockname()[1])

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        """Stop accepting and close what is open, so no socket outlives the run."""
        self._stop.set()
        try:
            self._listener.close()
        except OSError:  # pragma: no cover - already closed
            pass
        with self._live_lock:
            live, self._live = self._live, []
        for sock in live:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            close_fd(sock)
        self._thread.join(timeout=3.0)

    def _accept(self) -> None:
        while not self._stop.is_set():
            try:
                client, _ = self._listener.accept()
            except socket.timeout:
                if time.monotonic() >= self._deadline:
                    self.failure = self.failure or (
                        f"nothing connected to the relay on port {self.port} before the deadline"
                    )
                    return
                continue
            except OSError:
                # The listener was closed on the way out, which is the stop.
                return
            if time.monotonic() >= self._deadline:
                close_fd(client)
                self.failure = self.failure or "the deadline passed before the exchange finished"
                return
            try:
                server = socket.create_connection(("127.0.0.1", self._target_port), timeout=5.0)
            except OSError as exc:
                close_fd(client)
                self.failure = self.failure or (
                    f"the relay could not reach 127.0.0.1:{self._target_port}: {exc}"
                )
                continue
            for sock in (client, server):
                sock.settimeout(1.0)
                with self._live_lock:
                    self._live.append(sock)
            pump_thread = threading.Thread(
                target=self._shuttle, args=(client, server), name="relay-connection", daemon=True,
            )
            pump_thread.start()

    def _shuttle(self, client: socket.socket, server: socket.socket) -> None:
        """Copy one connection both ways, and take it down when either end goes."""
        threads = [
            threading.Thread(target=self._copy, args=(client, server, self._to_server),
                             name="relay-client-to-server", daemon=True),
            threading.Thread(target=self._copy, args=(server, client, self._to_client),
                             name="relay-server-to-client", daemon=True),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        for sock in (client, server):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            close_fd(sock)
        with self._live_lock:
            self._live = [sock for sock in self._live if sock not in (client, server)]

    def _copy(self, source: socket.socket, sink: socket.socket, capture: Capture) -> None:
        while not self._stop.is_set():
            try:
                data = source.recv(65536)
            except socket.timeout:
                if time.monotonic() >= self._deadline:
                    return
                continue
            except OSError:
                return
            if not data:
                # End of file on this side is end of file for the other, and the
                # peer is never told to stop: it is only left without input,
                # which is the thing under test.
                return
            capture.write(data)
            try:
                sink.sendall(data)
            except OSError:
                return


def close_fd(sock: Any) -> None:
    """Close a socket without letting a second close raise."""
    if sock is None:
        return
    try:
        sock.close()
    except OSError:  # pragma: no cover - already closed
        pass


# --- reading HTTP back out of a capture ----------------------------------------


def parse_http_messages(raw: bytes, label: str) -> list[dict[str, Any]]:
    """Every HTTP message in a capture, in the order the bytes arrived.

    The split is the one HTTP/1.1 defines: headers end at the first blank line,
    and the body is either the length the head states or, when the head says
    `chunked`, the chunks up to the terminating zero-length one. Nothing here
    reformats a message or guesses at one: a message whose framing cannot be
    followed is reported as a failure naming the label, because a capture that
    is silently half-parsed is exactly the artifact nobody opens.

    The message count is bounded so a peer that loops cannot make this list
    unbounded either.
    """
    messages: list[dict[str, Any]] = []
    offset = 0
    while offset < len(raw) and len(messages) < 256:
        head_end = raw.find(b"\r\n\r\n", offset)
        if head_end < 0:
            if raw[offset:].strip():
                raise InteropFailure(
                    f"the {label} capture ends inside a header block: "
                    f"{raw[offset:offset + 80]!r}"
                )
            break
        head = raw[offset:head_end].decode("utf-8", "replace")
        lines = head.split("\r\n")
        start = lines[0].split(" ")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        body_at = head_end + 4
        if headers.get("transfer-encoding", "").lower() == "chunked":
            body, offset = _read_chunked(raw, body_at, label)
        else:
            try:
                length = int(headers.get("content-length", "0"))
            except ValueError:
                raise InteropFailure(
                    f"the {label} capture has a content-length that is not a number: "
                    f"{headers.get('content-length')!r}"
                ) from None
            body = raw[body_at:body_at + length]
            offset = body_at + length
        entry: dict[str, Any] = {"head": head, "headers": headers, "body": body}
        if start[0].upper().startswith("HTTP/"):
            entry["status"] = int(start[1]) if start[1].isdigit() else 0
            entry["reason"] = " ".join(start[2:])
        else:
            entry["method"] = start[0]
            entry["target"] = " ".join(start[1:2])
        try:
            entry["json"] = json.loads(body) if body else None
        except json.JSONDecodeError:
            entry["json"] = None
        messages.append(entry)
    return messages


def _read_chunked(raw: bytes, offset: int, label: str) -> tuple[bytes, int]:
    """The body of a chunked message and where the next one starts."""
    body = b""
    while True:
        line_end = raw.find(b"\r\n", offset)
        if line_end < 0:
            raise InteropFailure(f"the {label} capture ends inside a chunk size line")
        try:
            size = int(raw[offset:line_end].split(b";")[0].strip(), 16)
        except ValueError:
            raise InteropFailure(
                f"the {label} capture has a chunk size that is not hexadecimal: "
                f"{raw[offset:line_end]!r}"
            ) from None
        offset = line_end + 2
        if size == 0:
            # The terminator is a blank line of its own after the zero chunk.
            return body, offset + 2
        body += raw[offset:offset + size]
        offset += size + 2


def header_of(message: dict[str, Any], name: str) -> str | None:
    """A header by its name, case-insensitively, as HTTP requires."""
    return message["headers"].get(name.lower())


# --- the supervisor -------------------------------------------------------------


def run_supervise(args: argparse.Namespace) -> int:
    pins = load_pins(args.pins)
    record = check_pins(pins, "a2a-sdk")
    work = WorkDir(args.work_dir, args.work_dir_prefix)
    try:
        return supervise_run(args, pins, record, work)
    finally:
        # Every path out, a failed check included: a generated work directory
        # belongs to this run and to nobody else. The notice is printed after
        # the removal rather than before it, because a line saying a directory
        # was taken away is only worth reading if it was.
        remove_temporary(work)
        print(work.notice())


def supervise_run(args: argparse.Namespace, pins: dict[str, Any], record: dict[str, Any],
                   work: WorkDir) -> int:
    port = args.port or free_port()
    base_url = f"http://127.0.0.1:{port}"
    emit = work / "expected-interface.json"

    # The same bound the wire capture gets on the MCP side, from the same pin:
    # one number for everything this run writes, so "bounded" means one thing.
    limit = int(pins.get("limits", {}).get("capture_bytes_per_direction", 262144))
    agent_log = BoundedLog(work / "agent-stderr.log", limit)

    # The flag is a number of seconds, as the pin file's
    # limits.deadline_seconds_default says, while the readiness wait wants an
    # instant on the same clock. Converted once, here.
    deadline = time.monotonic() + args.deadline

    agent: subprocess.Popen[str] | None = None
    drain: threading.Thread | None = None
    started = time.monotonic()
    try:
        agent = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()),
             "--role", "serve", "--pins", str(args.pins), "--port", str(port),
             "--rpc-path", args.rpc_path],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        drain = pump(agent.stderr, agent_log)
        ready = wait_for_line(agent, deadline, lambda: stderr_note(agent_log, work, "the agent"))
        require(ready.get("rpc_path") == args.rpc_path,
                f"the agent came up on {ready.get('rpc_path')!r}, not {args.rpc_path!r}; "
                f"{stderr_note(agent_log, work, 'the agent')}")
        facts = asyncio.run(probe(base_url, emit, record))
    finally:
        if agent is not None and agent.poll() is None:
            terminate(agent, 5.0)
        if drain is not None:
            # End of file arrives when the child the pipe belongs to is gone.
            # The join is bounded so a pipe that somehow outlives its child
            # cannot hold the run open, and the log is capped either way.
            drain.join(timeout=2.0)
        agent_log.close()

    elapsed = round(time.monotonic() - started, 3)
    require(
        not agent_log.truncated,
        f"the agent's stderr hit the {limit}-byte bound, so what it said is only a prefix. Raise "
        f"limits.capture_bytes_per_direction in the pin file; an incomplete record of a run is "
        f"not a passing one.",
    )
    require_bounded_size(emit, limit)
    findings = summarise(facts)
    summary = {
        "sdk": {"distribution": "a2a-sdk", "version": record["version"],
                "source": record["nix"]["src"]},
        "base_url": base_url,
        "work_dir": str(work.path),
        "work_dir_kept": not work.temporary,
        "elapsed_seconds": elapsed,
        "expected_interface": str(emit),
        "findings": findings,
        "facts": facts,
    }
    (work / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"a2a interop: a2a-sdk {record['version']}, protocol {PROTOCOL_VERSION}, {elapsed}s")
    print(f"  discovered at {facts['card_path']}, endpoint advertised at "
          f"{facts['selected_interface']['url']}")
    for finding in findings:
        print(f"  - {finding}")
    return 0


def summarise(facts: dict[str, Any]) -> list[str]:
    selected = facts["selected_interface"]
    task = facts["send_message_task"]["task"]
    return [
        f"the card was discovered at {facts['card_path']} and advertises "
        f"{selected['protocolBinding']} {selected['protocolVersion']} at {selected['url']}",
        f"the endpoint used was {facts['endpoint']}, the advertised one and not a guess",
        f"A2A-Version bound to {facts['a2a_version_header']}, and an unsupported one was "
        f"refused with code {facts['rejected_version_code']}",
        f"SendMessage answered with a Task in state "
        f"{(task.get('status') or {}).get('state')} and with a Message when asked for it",
        f"an unknown method came back as a JSON-RPC error, code "
        f"{facts['unknown_method']['error'].get('code')}, with no result member",
    ]



# --- the interoperability run ---------------------------------------------------
#
# Both directions are driven here, and each one is a separate process group with
# its own relay, its own captures and its own reports. The Zig client talks to
# the SDK's agent; the SDK's client talks to the Zig server. Nothing in either
# direction is a self-check: the peer at the far end is the genuine SDK, and the
# bytes are read back out of the capture rather than out of a report the
# participant wrote about itself.


def require_zig_binary(args: argparse.Namespace) -> Path:
    zig_binary = Path(args.zig_binary)
    require(
        zig_binary.exists(),
        f"the Zig participant is not at {zig_binary}. It is an executable target and build.zig "
 f"belongs to the integration owner, so build it first:\n"
 f"  zig build interop-a2a\n"
 f"which installs zig-out/bin/{zig_binary.name}, or point --zig-binary at an existing one.",
    )
    return zig_binary


class Direction:
    """One direction of the exchange and everything a run of it owns.

    The captures and the logs are opened here and closed in `finish`, so a
    direction that fails between the two still leaves its evidence on disk and
    still closes what it opened. `children` is what the teardown walks: a
    process that was started and not reaped is the one failure this file must
    never produce.
    """

    def __init__(self, name: str, work: WorkDir, limit: int) -> None:
        self.name = name
        self.work = work
        self.limit = limit
        self.to_server = Capture(work / f"{name}-wire-client-to-server.log", limit)
        self.to_client = Capture(work / f"{name}-wire-server-to-client.log", limit)
        self.logs: dict[str, BoundedLog] = {}
        self.drains: list[threading.Thread] = []
        self.children: list[subprocess.Popen[Any]] = []
        self.relay: Relay | None = None
        self.ports: list[int] = []
        self.facts: dict[str, Any] = {}
        self.captured = 0

    def log(self, label: str) -> BoundedLog:
        entry = BoundedLog(self.work / f"{self.name}-{label}-stderr.log", self.limit)
        self.logs[label] = entry
        return entry

    def spawn(self, argv: list[str], label: str, text: bool, *,
              keep_stdout: bool = True) -> subprocess.Popen[Any]:
        entry = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if keep_stdout else subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=text, start_new_session=True,
        )
        self.children.append(entry)
        self.drains.append(pump(entry.stderr, self.log(label)))
        return entry

    def finish(self) -> None:
        if self.relay is not None:
            self.relay.stop()
        for child in self.children:
            if child.poll() is None:
                terminate(child, 5.0)
        for drain in self.drains:
            # End of file arrives when the child the pipe belongs to is gone.
            # The join is bounded so a pipe that somehow outlives its child
            # cannot hold the run open, and the log is capped either way.
            drain.join(timeout=2.0)
        self.captured = self.to_server.close() + self.to_client.close()
        for entry in self.logs.values():
            entry.close()

    def note(self, label: str) -> str:
        entry = self.logs.get(label)
        return "" if entry is None else stderr_note(entry, self.work, label)

    def require_not_truncated(self) -> None:
        require(
            not self.to_server.truncated and not self.to_client.truncated,
            f"{self.name}: the capture hit its {self.limit}-byte bound; raise "
 f"limits.capture_bytes_per_direction in the pin file or the evidence is incomplete",
        )
        for label, entry in self.logs.items():
            require(
                not entry.truncated,
                f"{self.name}: {label}'s stderr hit the {self.limit}-byte bound, so what it said "
 f"is only a prefix. Raise limits.capture_bytes_per_direction in the pin file; an incomplete "
 f"record of a run is not a passing one.",
            )


def zig_client_direction(direction: Direction, args: argparse.Namespace, record: dict[str, Any],
                          zig_binary: Path, work: WorkDir,
                          deadline_seconds: float) -> None:
    """The Zig client against the SDK's own agent, with the wire relayed here.

    The SDK agent listens on a port of its own and the card it serves names the
    relay's port instead, so every byte of the exchange — the card GET and both
    SendMessage posts — crosses this process and lands in the capture. A card
    that named the agent's real port would send the two posts straight past the
    capture, and the record would be missing exactly the part being tested.
    """
    endpoint = advertised_endpoint(args.rpc_path, args.rpc_query)
    agent_port = free_port()
    relay = Relay(agent_port, direction.to_server, direction.to_client,
                 time.monotonic() + deadline_seconds)
    direction.relay = relay
    relay.start()

    agent = direction.spawn([
        sys.executable, str(Path(__file__).resolve()),
        "--role", "serve", "--pins", str(args.pins), "--port", str(agent_port),
        "--rpc-path", args.rpc_path, "--rpc-query", args.rpc_query,
        "--advertise-base", f"http://127.0.0.1:{relay.port}",
    ], "sdk-agent", text=True)
    ready = wait_for_line(agent, time.monotonic() + deadline_seconds,
                          lambda: direction.note("sdk-agent"))
    require(ready.get("rpc_path") == args.rpc_path,
            f"the SDK agent came up on {ready.get('rpc_path')!r}, not {args.rpc_path!r}; "
            f"{direction.note('sdk-agent')}")
    require(ready.get("advertised_url") == f"http://127.0.0.1:{relay.port}{endpoint}",
            f"the SDK agent advertises {ready.get('advertised_url')!r}, which is not the relay "
            f"port and the endpoint this run asked for; {direction.note('sdk-agent')}")

    # Standard output is discarded rather than piped and left undrained: the
    # client role reports on standard error and in its report file, and a pipe
    # nobody reads is a pipe that fills and stops the process writing to it.
    zig = direction.spawn([
        str(zig_binary), "--role", "client",
        "--base-url", f"http://127.0.0.1:{relay.port}",
        "--expect-endpoint", endpoint,
        "--report-file", str(work / "zig-client-report.json"),
    ], "zig-client", text=False, keep_stdout=False)
    zig_code = wait_for(zig, time.monotonic() + deadline_seconds)
    require(zig_code == 0,
            f"the Zig client exited with {zig_code}; {direction.note('zig-client')}")

    direction.facts = {
        "direction": direction.name,
        "peer": "a2a-sdk agent",
        "sdk": {"distribution": "a2a-sdk", "version": record["version"],
                "source": record["nix"]["src"]},
        "zig_participant": str(zig_binary),
        "agent_port": agent_port,
        "relay_port": relay.port,
        "expect_endpoint": endpoint,
        "report": json.loads((work / "zig-client-report.json").read_text(encoding="utf-8")),
    }
    require(relay.failure is None, f"{direction.name}: {relay.failure}")


def zig_server_direction(direction: Direction, args: argparse.Namespace, record: dict[str, Any],
                          zig_binary: Path, work: WorkDir,
                          deadline_seconds: float) -> None:

    """The SDK's own client against the Zig server, with the wire relayed here.

    The port the Zig server listens on is named here rather than left to the
    kernel, because the relay is bound before the server is started: the card
    is composed at startup out of the port this run hands it, and that port
    has to be one something is already listening on. The server is told to
    advertise the relay's port, so both of the SDK's discovery GETs and all
    four of its calls cross this process and land in the capture.
    """
    endpoint = advertised_endpoint(args.rpc_path, args.rpc_query)
    # The port the Zig server listens on is named here rather than left to the
    # kernel, because the relay has to be bound in front of it: the card is
    # composed at startup out of a port the supervisor hands over, and that
    # port has to be one something is already listening on. Naming a port and
    # closing it again, which is what a free-port probe does, is the difference
    # between a card a client can dial and a card pointing at nothing.
    listen_port = free_port()
    relay = Relay(listen_port, direction.to_server, direction.to_client,
                 time.monotonic() + deadline_seconds)
    direction.relay = relay
    relay.start()

    server = direction.spawn([
        str(zig_binary), "--role", "server",
        "--port", str(listen_port),
        "--advertise-port", str(relay.port),
        "--rpc-target", endpoint,
        "--requests", str(args.zig_requests),
        "--report-file", str(work / "zig-server-report.json"),
    ], "zig-server", text=True)
    ready = wait_for_line(server, time.monotonic() + deadline_seconds,
                          lambda: direction.note("zig-server"))
    require(ready.get("port") == listen_port,
            f"the Zig server reported port {ready.get('port')!r}, not the {listen_port} it was "
            f"asked to listen on; {direction.note('zig-server')}")
    require(ready.get("advertise_port") == relay.port,
            f"the Zig server's card advertises {ready.get('advertise_port')!r}, not the relay's "
            f"port {relay.port}; {direction.note('zig-server')}")
    require(ready.get("rpc_target") == endpoint,
            f"the Zig server serves {ready.get('rpc_target')!r}, not {endpoint!r}; "
            f"{direction.note('zig-server')}")
    direction.ports.append(listen_port)

    facts = asyncio.run(probe(f"http://127.0.0.1:{relay.port}", work / "sdk-client-facts.json",
                              record))
    server_code = wait_for(server, time.monotonic() + deadline_seconds)
    require(server_code == 0,
            f"the Zig server exited with {server_code}; {direction.note('zig-server')}")

    direction.facts = {
        "direction": direction.name,
        "peer": "a2a-sdk client",
        "sdk": {"distribution": "a2a-sdk", "version": record["version"],
                "source": record["nix"]["src"]},
        "zig_participant": str(zig_binary),
        "listen_port": listen_port,
        "relay_port": relay.port,
        "expect_endpoint": endpoint,
        "sdk_client_facts": facts,
        "report": json.loads((work / "zig-server-report.json").read_text(encoding="utf-8")),
    }
    require(relay.failure is None, f"{direction.name}: {relay.failure}")


def wait_for(process: subprocess.Popen[Any], deadline: float) -> int | None:
    """A child's exit status, or a failure naming the deadline it missed."""
    budget = max(deadline - time.monotonic(), 0.0)
    try:
        return process.wait(timeout=budget)
    except subprocess.TimeoutExpired:
        raise InteropFailure(
            f"the child did not exit within {budget:.0f}s of the deadline"
        ) from None


# --- what the wire has to say --------------------------------------------------


def selected_interface_url(card: dict[str, Any], label: str) -> str:
    """The url of the interface a client of this protocol binds, as the card gives it.

    The rule is the one both clients select with: among the interfaces whose
    binding is JSONRPC, the first one whose own version is 1.0. A card that
    advertises none of those is a card no client of this protocol can use, and
    naming some later entry to make a run pass would be naming an endpoint
    neither peer ever bound.
    """
    interfaces = card.get("supportedInterfaces") or []
    require(interfaces, f"{label}: the card advertises no supported interface at all")
    jsonrpc = [entry for entry in interfaces if entry.get("protocolBinding") == JSONRPC_BINDING]
    require(
        jsonrpc,
        f"{label}: the card advertises no JSONRPC interface: "
        f"{[entry.get('protocolBinding') for entry in interfaces]}",
    )
    for entry in jsonrpc:
        version = entry.get("protocolVersion")
        require(
            isinstance(version, str) and is_major_minor(version),
            f"{label}: the card advertises a JSONRPC interface whose protocol version is not "
            f"Major.Minor: {version!r}",
        )
    selected = next((entry for entry in jsonrpc
                     if entry.get("protocolVersion") == PROTOCOL_VERSION), None)
    require(
        selected is not None,
        f"{label}: the card advertises JSONRPC interfaces at "
        f"{[entry.get('protocolVersion') for entry in jsonrpc]}, none of them "
        f"{PROTOCOL_VERSION!r}, so no client of this protocol would have bound one",
    )
    url = selected.get("url")
    require(
        isinstance(url, str) and (url.startswith("/") or "://" in url),
        f"{label}: the card advertises an interface url that is neither a path nor an "
        f"absolute url: {url!r}",
    )
    return url


def request_target_of(url: str) -> str:
    """The path and query a client puts on the request line for this url.

    The authority is not part of it, because a request line carries no host and
    the host is the connection's business; a target with no query has no `?` on
    it either.
    """
    parts = urlsplit(url)
    return parts.path + (f"?{parts.query}" if parts.query else "")


def check_wire(direction: Direction, limit: int, *, expect_refusals: bool) -> list[str]:
    """Every claim below is read out of the capture, not out of a report.

    A participant's own report says what it believes happened; the capture says
    what crossed the socket. Where the two could disagree, this reads the
    capture, which is why nothing in this function is handed a report.
    """
    to_server = parse_http_messages(
        (direction.work / f"{direction.name}-wire-client-to-server.log").read_bytes(),
        f"{direction.name} client to server")
    to_client = parse_http_messages(
        (direction.work / f"{direction.name}-wire-server-to-client.log").read_bytes(),
        f"{direction.name} server to client")

    card_path = direction.facts.get("card_path", "/.well-known/agent-card.json")
    expected = direction.facts["expect_endpoint"]
    findings: list[str] = []

    # 1. Discovery happened, at the well-known path and by a GET.
    discovery = [m for m in to_server if m.get("method") == "GET" and m.get("target") == card_path]
    require(discovery,
            f"{direction.name}: nothing on the wire asked for the card at {card_path}; the "
            f"endpoints used were {[m.get('target') for m in to_server]}")
    answered_cards = [
        m for m in to_client
        if m.get("status") == 200 and isinstance(m.get("json"), dict)
        and m["json"].get("supportedInterfaces") is not None
    ]
    require(
        answered_cards,
        f"{direction.name}: the card was requested {len(discovery)} times and no answer on the "
 f"wire was an HTTP 200 carrying a card's supportedInterfaces",
 )
    card = answered_cards[0]["json"]
    advertised = card["supportedInterfaces"]
    findings.append(
        f"the card came back as an HTTP 200 advertising "
        f"{[entry.get('protocolBinding') for entry in advertised]}"
    )

    # 2. Every POST went to the endpoint the card on the wire advertises, path,
    # query and authority alike. The constant this process handed the
    # participant is compared below as a second opinion rather than as the
    # expectation, because it is what the participant was told to use: a POST
    # that matches it shows the instruction was obeyed, not that the card was
    # read.
    discovery_host = header_of(discovery[0], "host")
    require(discovery_host,
            f"{direction.name}: the discovery GET carried no Host header, so a relative "
            f"advertised url has no origin to resolve against: {discovery[0]['head']!r}")
    endpoint = urljoin(f"http://{discovery_host}/", selected_interface_url(card, direction.name))
    expect_target = request_target_of(endpoint)
    expect_authority = urlsplit(endpoint).netloc

    posts = [m for m in to_server if m.get("method") == "POST"]
    require(posts, f"{direction.name}: nothing on the wire was a POST")
    targets = {m["target"] for m in posts}
    require(
        targets == {expect_target},
        f"{direction.name}: the POSTs went to {sorted(targets)}, and the card on the wire "
        f"advertises {expect_target!r}. A client that used the advertised endpoint and one "
        f"that guessed differ exactly here.",
    )
    # The authority is checked beside the path, because a target can match
    # while the call went somewhere else: that is a different agent answering,
    # and the card read to find this endpoint is not its card.
    authorities = {header_of(m, "host") for m in posts}
    require(
        authorities == {expect_authority},
        f"{direction.name}: the POSTs carried Host {sorted(a for a in authorities if a)}, and "
        f"the card on the wire advertises {expect_authority!r}",
    )
    require(
        expect_target == expected,
        f"{direction.name}: the card on the wire advertises {expect_target!r} while this run "
        f"told the participant to expect {expected!r}; they are the same endpoint or the run "
        f"is not testing what it says it is.",
    )

    # 3. The version header was bound to the selected major and minor on every
    # call that carried one, and named case-insensitively because HTTP header
    # names are case-insensitive.
    send_posts = [m for m in posts if (m["json"] or {}).get("method") == "SendMessage"]
    require(len(send_posts) >= 2,
            f"{direction.name}: {len(send_posts)} SendMessage calls on the wire, and the typed "
 f"arms this run exists to prove need at least two")
    for message in send_posts:
        version = header_of(message, "a2a-version")
        require(
            version == PROTOCOL_VERSION,
            f"{direction.name}: a SendMessage went out with A2A-Version {version!r}, not "
 f"{PROTOCOL_VERSION!r}",
 )
    findings.append(
        f"the card was discovered at {card_path} and every call went to {expect_target} on "
        f"{expect_authority}, which is what the card that crossed the wire advertises"
    )

    # 4. Both arms of the result oneof came back, typed, and neither is the other.
    #
    # Answers are paired in wire order rather than looked up by id alone: the
    # SDK probe's two hand-written calls carry the *same* string id, so a lookup
    # keyed on the id would hand both calls the second answer and every
    # assertion below would be made about the wrong bytes.
    answers = [m for m in to_client if m.get("json") is not None]
    task_arm: dict[str, Any] | None = None
    message_arm: dict[str, Any] | None = None
    claimed = [False] * len(answers)
    for request in send_posts:
        answer = claim_answer(answers, claimed, request)
        require(
            answer is not None,
            f"{direction.name}: the SendMessage with id {request['json'].get('id')!r} was never "
 f"answered on the wire",
 )
        body = answer["json"]
        require("error" not in body or body.get("error") is None,
                f"{direction.name}: a SendMessage was answered with an error, code "
                f"{(body.get('error') or {}).get('code')!r}")
        result = body.get("result") or {}
        require(
            result.get("task") is not None or result.get("message") is not None,
            f"{direction.name}: a SendMessage came back with a result carrying neither a task nor "
 f"a message: {sorted(result)}",
 )
        require(
            result.get("task") is None or result.get("message") is None,
            f"{direction.name}: a SendMessage came back with both arms of the oneof at once, "
 f"which is not a shape the wire has",
 )
        if result.get("task") is not None and task_arm is None:
            task_arm = answer
        if result.get("message") is not None and message_arm is None:
            message_arm = answer
    require(task_arm is not None,
            f"{direction.name}: no SendMessage came back with a Task")
    require(message_arm is not None,
            f"{direction.name}: no SendMessage came back with a Message")
    findings.append(
        f"SendMessage answered with a Task in state "
        f"{((task_arm['json']['result'].get('task') or {}).get('status') or {}).get('state')} and "
 f"with a Message on the other call, as two arms of one oneof"
 )

    # 5. An explicit peer error, when this direction is asked for one. Only the
    # SDK client sends calls this side of the wire refuses on purpose, so the
    # check is a function of the direction rather than a fixture both share.
    if not expect_refusals:
        return findings

    refusals = [(m["json"].get("method"), m) for m in posts if m.get("json") is not None]
    require(
        any(method != "SendMessage" for method, _ in refusals),
        f"{direction.name}: every call on the wire was a SendMessage; this direction exists to "
 f"prove the error path and nothing exercised it",
    )
    for method, request in refusals:
        if method == "SendMessage":
            continue
        answer = claim_answer(answers, claimed, request)
        require(
            answer is not None,
            f"{direction.name}: the {method} call was never answered on the wire",
 )
        body = answer["json"]
        require(
            body.get("error") is not None and body.get("result") is None,
            f"{direction.name}: {method} came back as "
            f"{'a result' if body.get('result') is not None else 'neither a result nor an error'} "
 f"rather than as a JSON-RPC error",
 )
        version = header_of(request, "a2a-version")
        code = (body.get("error") or {}).get("code")
        if version != PROTOCOL_VERSION:
            require(
                code == -32009,
                f"{direction.name}: {method} sent with A2A-Version {version!r} was refused with "
 f"code {code!r}, and an unsupported version is -32009 rather than a method the peer lacks",
 )
            findings.append(
                f"an unsupported A2A-Version {version} was refused with code {code}, the agent's "
 f"own VersionNotSupportedError rather than silence"
            )
        else:
            require(
                code == -32601,
                f"{direction.name}: the unknown method {method} was refused with code {code!r}, "
 f"and a method the peer does not have is -32601",
 )
            findings.append(
                f"the unknown method {method} came back as a JSON-RPC error, code {code}, with no "
 f"result member beside it"
            )
    return findings


def claim_answer(answers: list[dict[str, Any]], claimed: list[bool],
                 request: dict[str, Any]) -> dict[str, Any] | None:
    """The first answer on the wire carrying this request's id and not yet read.

    Wire order is the pairing, because a peer is free to answer calls out of
    order and free to reuse one id across two of them, and both facts are
    invisible to a lookup keyed on the id. Marking an answer claimed is what
    stops the second call with a reused id from being handed the first call's
    answer.
    """
    key = json.dumps(request["json"].get("id"))
    for index, answer in enumerate(answers):
        if claimed[index]:
            continue
        if json.dumps(answer["json"].get("id")) == key:
            claimed[index] = True
            return answer
    return None


def run_zig_interop(args: argparse.Namespace) -> int:
    pins = load_pins(args.pins)
    record = check_pins(pins, "a2a-sdk")
    zig_binary = require_zig_binary(args)
    work = WorkDir(args.work_dir, args.work_dir_prefix)
    try:
        zig_interop_run(args, pins, record, zig_binary, work)
    finally:
        # Every path out, a failed direction included: a generated work
        # directory belongs to this run and to nobody else, and the notice is
        # printed after the removal rather than before it, because a line
        # saying a directory was taken away is only worth reading if it was.
        remove_temporary(work)
        print(work.notice())
    return 0


def zig_interop_run(args: argparse.Namespace, pins: dict[str, Any], record: dict[str, Any],
                    zig_binary: Path, work: WorkDir) -> None:
    limit = int(pins.get("limits", {}).get("capture_bytes_per_direction", 262144))
    started = time.monotonic()
    # Both directions are registered before either runs, so a failure inside
    # the first one still finds a teardown that closes the captures and reaps
    # whatever it had already started. A direction that is only registered once
    # it succeeds is a direction whose sockets and children outlive the failure.
    directions = [Direction("zig-client", work, limit), Direction("zig-server", work, limit)]
    try:
        zig_client_direction(directions[0], args, record, zig_binary, work, args.deadline)
        zig_server_direction(directions[1], args, record, zig_binary, work, args.deadline)
    finally:
        # Every path out, a failed direction included: a direction owns
        # processes and sockets, and neither may outlive the run that made it.
        for direction in directions:
            direction.finish()

    elapsed = round(time.monotonic() - started, 3)
    for direction in directions:
        direction.require_not_truncated()
        for produced in (work / "zig-client-report.json", work / "zig-server-report.json",
                         work / "sdk-client-facts.json"):
            require_bounded_size(produced, limit)

    client_findings = check_wire(directions[0], limit, expect_refusals=False)
    server_findings = check_wire(directions[1], limit, expect_refusals=True)

    summary = {
        "sdk": {"distribution": "a2a-sdk", "version": record["version"],
                "source": record["nix"]["src"]},
        "zig_participant": str(zig_binary),
        "protocol_version": PROTOCOL_VERSION,
        "work_dir": str(work.path),
        "work_dir_kept": not work.temporary,
        "elapsed_seconds": elapsed,
        "directions": [
            {
                "name": direction.name,
                "peer": direction.facts["peer"],
                "bytes_captured": direction.captured,
                "findings": findings,
                "facts": direction.facts,
                "capture": {
                    "client_to_server": str(direction.work /
                                            f"{direction.name}-wire-client-to-server.log"),
                    "server_to_client": str(direction.work /
                                            f"{direction.name}-wire-server-to-client.log"),
                },
            }
            for direction, findings in ((directions[0], client_findings),
                                        (directions[1], server_findings))
        ],
    }
    (work / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"a2a interop: a2a-sdk {record['version']} against {zig_binary.name}, "
          f"protocol {PROTOCOL_VERSION}, {elapsed}s")
    for direction, findings in ((directions[0], client_findings), (directions[1], server_findings)):
        print(f"  {direction.name} ({direction.facts['peer']}): "
              f"{direction.captured} bytes captured on the wire")
        for finding in findings:
            print(f"    - {finding}")


# --- entry ----------------------------------------------------------------------


def run_preflight(args: argparse.Namespace) -> int:
    """Check where a run would write, with nothing else involved.

    No SDK, no agent, no pin check. This answers one question: whether the
    environment has somewhere for a generated work directory that is not a
    system temporary directory, and whether the generated case really is taken
    away afterwards. Both are proved rather than assumed — the directory is
    created, written to and removed here, exactly as a run does it.
    """
    if args.work_dir is not None:
        work = WorkDir(args.work_dir, args.work_dir_prefix)
        print(f"scratch: TMPDIR is {os.environ.get('TMPDIR', '<unset>')}, which a named work "
              f"directory does not need")
        print(f"  work directory: {work.path} (kept; a run leaves the expected interface there)")
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
    parser.add_argument("--role", choices=("supervise", "serve", "probe", "zig-interop"),
                        required=True)
    parser.add_argument("--pins", type=Path,
                        default=Path(os.environ.get("ZIG_AGENT_PROTO_SDK_PINS", DEFAULT_PINS)))
    parser.add_argument("--port", type=int, default=None, help="serve and supervise")
    parser.add_argument("--rpc-path", default=RPC_PATH,
                        help="the path the card's route is mounted at")
    parser.add_argument("--rpc-query", default=RPC_QUERY,
                        help="the query the card advertises beside --rpc-path; the SDK's route "
                             "matches on the path alone, and a client that reads the card sends "
                             "the query")
    parser.add_argument("--advertise-base", default=None,
                        help="serve only. The scheme, host and port the card's advertised URL "
                             "names, when that is not the base uvicorn listens on; the "
                             "supervisor sets it so the card names its relay")
    parser.add_argument("--zig-binary", default="zig-out/bin/zig-agent-proto-a2a-interop",
                        help="the Zig participant executable; zig-interop only")
    parser.add_argument("--zig-requests", type=int, default=6,
                        help="zig-interop only. How many requests the Zig server may serve "
                             "before it stops, which bounds that direction: the SDK client "
                             "fetches the card twice (its own and the resolver's), sends two "
                             "SendMessage calls and makes two more it expects to be refused, "
                             "so six is what it makes. A larger budget leaves the server "
                             "waiting for a request that is not coming")
    parser.add_argument("--base-url", default=None, help="probe only")
    parser.add_argument("--emit", type=Path, default=None, help="probe only")
    parser.add_argument("--work-dir", default=None,
                        help="an absolute path outside /tmp and /var/tmp where the expected "
                             "interface and the reports are kept; a generated directory under "
                             "TMPDIR otherwise, removed when the run ends either way it went")
    parser.add_argument("--preflight", action="store_true",
                        help="check TMPDIR and the work-directory policy and exit, with no SDK, "
                             "no pins and no child process")
    parser.add_argument("--deadline", type=float, default=60.0,
                        help="seconds the agent may take to come up and answer")
    parser.set_defaults(work_dir_prefix="a2a-interop-")
    return parser.parse_args(list(argv))


def run_probe_role(args: argparse.Namespace) -> int:
    pins = load_pins(args.pins)
    record = check_pins(pins, "a2a-sdk")
    require(args.base_url is not None, "--role probe needs --base-url")
    if args.emit is not None:
        # The probe writes only where it is told, and a system temporary
        # directory is not a place where an expected interface should outlive
        # the process that observed it.
        require(
            not is_system_temporary(args.emit),
            f"--emit {args.emit} is a system temporary directory, which is shared with every "
            f"process on the host. Name a path on this machine's own storage for the expected "
            f"interface, or leave it out and read the findings on stdout.",
        )
    for finding in summarise(asyncio.run(probe(args.base_url, args.emit, record))):
        print(f"  - {finding}")
    return 0


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    try:
        if args.preflight:
            return run_preflight(args)
        if args.role == "serve":
            require(args.port is not None, "--role serve needs --port")
            return run_serve(args)
        if args.role == "probe":
            return run_probe_role(args)
        if args.role == "zig-interop":
            return run_zig_interop(args)
        return run_supervise(args)
    except InteropFailure as failure:
        print(f"a2a interop FAILED: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
