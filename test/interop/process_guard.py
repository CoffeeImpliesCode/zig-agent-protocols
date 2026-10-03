"""Guarded teardown for the children a supervisor starts.

Every interoperability supervisor in this directory starts two or three child
processes and must leave none of them running. This module is the one place
that does it, because the thing being decided is not "how do I stop a
process" — it is "how do I prove, at the instant the signal goes out, that the
pid I am about to signal is still the process I started". `Popen` hands back a
number, and a number is a name the kernel hands out again, so a pid read
before a signal is a claim about a moment that has already passed.

The proof is read fresh from the kernel for every signal, and it is five
facts, all of which must hold at the same moment:

* the child is still the one this guard started, identified by the moment it
  started rather than by its pid: `/proc/<pid>/stat` field 22 is the process's
  own clock reading at `fork`, and no other process ever has the same one for
  the same pid;
* the pid is not this harness, and not one of the processes it descends from;
* `/proc/<pid>` belongs to the account running the supervisor, so a process
  this account cannot signal is never attempted;
* `/proc/<pid>/cmdline`, in full, still spells the command line this run
  started with — an argv that does not match is a pid somebody else has since
  been given;
* the process group is neither this harness's own group nor the group of any
  process it descends from, and every member of that group belongs to the same
  account. Signalling a group signals everything in it, so one member that is
  not this account's makes the whole group off limits.

Refusing is the answer when any of those fails. A run that cannot prove a pid
is its own says so and leaves that process alone: signalling a stranger
because a guard was in a hurry is worse than leaving one process running, and
a run can report the second and cannot undo the first.

The order is the order a process should be stopped in. `SIGTERM` first, which
gives a peer that is about to end of file anyway the chance to leave the way
it meant to; then a bounded wait; then `SIGKILL`, and only after every guard
above has been read again, because the grace period is a long time for a pid
to be recycled and the decision made before it says nothing about the moment
the kill goes out.

There is no path from a refusal to a signal, and no signal in this file that
does not pass through the same checks as the one after it. A refusal is
reported rather than worked around: `Stop` carries it instead of an exit
status, so a caller that forgets to read `Stop.refused` fails loudly rather
than reporting a clean teardown that never happened. The two ways a child can
be started and not be stopped are both refusals rather than signals. One is
decided before the fork — an executable the kernel would not exec directly
shows a rewritten command line in `/proc`, so the argv this run passed is not
the argv a later read can be matched against, and `spawn` declines to start
it. That decision is made about the file the kernel would run, which is found
through the environment and the directory the child itself would be given: a
bare command name is most of what a supervisor runs, and `qemu-system-x86_64`
is a name on the child's `PATH` rather than a file in whatever directory this
process happens to be standing in. Finding it changes nothing about the words
that are recorded — the command line the kernel shows is the argv the caller
passed, and that is what every later read is compared against.
The other is the reading that came back empty after the fork: the child's
standard input is closed, which is how a child here is told the run is over,
and it is waited for within a bound. Neither sends anything, and the failure
names the child, its pid and its command line so that a report cannot imply a
child was never started when it was.

Every signal this module sends is `SIGTERM` or `SIGKILL` to a process group
whose members have been checked, and each of them is authorised by a reading
taken immediately before it.

`/proc` is a prerequisite, not a convenience. `Guard()` proves it answers
before anything is forked, and `spawn()` proves it again immediately before
each fork, so a supervisor on a system where the guards could not be applied
fails with nothing running instead of starting a child it will not be allowed
to stop.

The listing has to be the whole listing too. procfs mounted with `hidepid=`
takes other accounts' processes out of it, and the group check walks that
listing looking for anything foreign — so a listing missing them would let it
report a complete answer from a partial view, which is the same failure as a
check that passed because it could not see what it was looking for. That is
read out of the mount table before anything is forked, not inferred from what
happens to be visible.

Some children are not started here. A guest driver on this host opens a
pseudo terminal and gets a pid back from a terminal library that forks and
execs it, which puts the child in a session and process group of its own and
therefore out of reach of the group checks above: those are about the group
this harness chose for a child it forked, and this one was chosen by a
library that put it where a terminal requires it. `adopt` is the same
decision applied to a child somebody else started. It takes the pid, the
command line and a probe, and it requires all three to agree with `/proc` at
one moment before it records anything, which is the only claim this module is
willing to make about a process it did not fork: that this pid is running
this command line right now, as an unreaped child of this harness, so no
other process can be holding the number. Everything after that is the same
decision, the same order and the same refusals `spawn` and `stop` produce,
because adoption changes where the child came from and nothing else.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, NamedTuple, Protocol, Sequence

# Every kernel read in this module goes through this one path, so a run that
# cannot use procfs fails in one place and says so, rather than refusing
# half a teardown for a reason that took a second read to notice.
_PROC = Path("/proc")

# How far the parent chain is followed. A bound rather than a depth: /proc
# cannot describe a cycle, but a walk without one would never reach the signal
# it exists to make.
_ANCESTOR_LIMIT = 256

# The default wait between `SIGTERM` and `SIGKILL`, and between `SIGKILL` and
# the end of the teardown, for callers that do not pass their own.
DEFAULT_GRACE = 5.0

# How long `adopt` waits for a child somebody else started to show the command
# line it was started with. A terminal library blocks in `fork` until the child
# has exec'd, so the answer is normally there before the first read; the bound
# is for the case where it is not, and it is short, because a run that cannot
# prove a pid is its own is better off saying so than waiting on it.
ADOPT_TIMEOUT = 10.0


class ProcessGuardError(RuntimeError):
    """Anything this module refuses to do, and the reason it gives."""


class ProcUnavailable(ProcessGuardError):
    """The guard cannot exist here, because `/proc` is not there to be read.

    Raised before anything is forked. A run that cannot prove whose process a
    pid is has no business starting one: refusing first leaves nothing behind,
    where refusing halfway through a teardown leaves a child the run is not
    allowed to stop.
    """


class Stop(NamedTuple):
    """How one child was stopped, and what it exited with.

    A record rather than a verdict, because every field of it is evidence and
    a default would be a claim this run did not make. `signals` lists only
    the signals the kernel accepted, `exit` is the status `waitpid` reported
    and stays `None` while there is no such status, and `refused` names the
    guard that declined rather than being folded into either.
    """

    child: str
    signals: list[str]
    exit: int | None
    refused: str | None = None

    @property
    def sent(self) -> str:
        """What was sent, in the order it was sent, in words."""
        return " then ".join(self.signals) or "no signal"

    @property
    def refusal_note(self) -> str:
        """The refusal as a sentence fragment, or nothing when there is none."""
        return "" if self.refused is None else f"; {self.refused}"


class Process(Protocol):
    """The part of `subprocess.Popen` this module decides on.

    Four members, and nothing else. A real `Popen` satisfies it because this
    module's own `spawn` builds one, and so does the adapter below, which is
    how a child somebody else forked is held to the same decisions without
    those decisions being written a second time for it.
    """

    pid: int
    returncode: int | None

    def poll(self) -> int | None:
        """The status if the child has one, else None. Must not block."""

    def wait(self, timeout: float | None = None) -> int:
        """The status, waiting up to `timeout`. `TimeoutExpired` when it has none."""


class Child(NamedTuple):
    """One child this run is responsible for, bound to the identity it has now.

    `starttime` is the whole point of the record. `argv` is the command line
    the kernel shows for the pid, and it must not be normalised on the way in,
    because the later read compares against it exactly. That it compares at all
    is a promise both `spawn` and `adopt` keep before recording anything: an
    executable whose first bytes are `#!` is not exec'd directly, and the
    kernel shows a rewritten argv in `/proc/<pid>/cmdline` instead, so a
    command line nothing will ever match is refused at the point it is offered
    rather than recorded by a guard that has stopped checking.
    """

    label: str
    process: Process
    argv: tuple[str, ...]
    starttime: int


class Adopted:
    """A child somebody else forked, held to the `Process` surface above.

    `poll` and `wait` are the only thing this needs from whatever started the
    child, and both are asked for exactly one fact: has it exited, and with
    what status. That is not a second ownership decision — nothing here reads
    a pid out of a name, and no signal can be sent from this class — it is the
    one thing a terminal library knows and this module does not, because the
    library holds the `waitpid` the kernel returns and this module holds the
    identity that has to be re-read before anything is signalled.

    Reaping is not signalling: a `waitpid` reports an exit to the one process
    entitled to wait for it and sends the child nothing. So a probe may reap
    the child this run owns, and it may not signal it, which is why the probe
    is a callable the caller supplies rather than something read here.

    A probe answers in three ways, and the third one matters. A status, or
    `None` for still running, are the two this class was built for. A probe
    that cannot tell raises `ProcessStateUnknown`, and this class lets that out
    of both `poll` and `wait` rather than standing in a status for it: the
    callers below turn it into a refusal, which is the only outcome that leaves
    a console open over a child nobody observed leaving.

    `wait` polls rather than blocks, because the guard's grace periods are
    bounds and a blocking wait against a child whose console output nobody is
    draining does not end when the grace does.
    """

    def __init__(self, pid: int, argv: tuple[str, ...],
                 probe: Callable[[], int | None]) -> None:
        self.pid = pid
        self.argv = argv
        self.returncode: int | None = None
        self._probe = probe

    def poll(self) -> int | None:
        """The status if the child has one, else None. Never blocks.

        Raises `ProcessStateUnknown` when the probe cannot say, and does not
        cache the answer to that: the next call asks again, because a probe
        that could not answer once may be able to answer the next time, and
        this class has no standing to decide that it will not.
        """
        if self.returncode is None:
            code = self._probe()
            if code is not None:
                self.returncode = code
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        """The status within `timeout`, or `TimeoutExpired` while it has none."""
        budget = timeout
        deadline = None if budget is None else time.monotonic() + budget
        while True:
            code = self.poll()
            if code is not None:
                return code
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(list(self.argv), timeout)
            time.sleep(0.005)



class ProcessStateUnknown(ProcessGuardError):
    """The one source of a child's status cannot say whether it has exited.

    Only a child somebody else started can raise it, because only a child
    somebody else started has an exit status this module cannot read for
    itself: `Popen.wait` returns it or raises `TimeoutExpired`, and a terminal
    library is asked for it through a probe that has to answer one of three
    ways — a status, `None` for still running, or this.

    The third answer is not folded into either of the first two. A child whose
    console stopped answering and recorded nothing has not exited with status
    0; it has gone unaccounted for, and a teardown that reports the first
    reading instead would be reporting a fact nobody established. So it is an
    error the caller has to see, never a value, and it is what stops the
    console being closed over a process whose exit was never observed.
    """


class DeadlineMissed(ProcessGuardError):
    """A child outlived the deadline its run gave it, and has been stopped.

    The `Stop` is carried rather than formatted here: the caller already has
    the words its own run uses for a deadline miss, and what this raises is
    the evidence for that message rather than the message itself.
    """

    def __init__(self, stop: Stop) -> None:
        super().__init__(
            f"a {stop.child} did not exit within its deadline; stopped with {stop.sent} and "
            f"reaped, exit {stop.exit}{stop.refusal_note}"
        )
        self.stop = stop


# --- the kernel reads ------------------------------------------------------------


class _Stat(NamedTuple):
    """The few fields of `/proc/<pid>/stat` this module decides on.

    Indexed from the split after the command name, so these are fields 4, 5 and
    22 of the line and the first thing in the split is the state letter rather
    than a number.
    """

    ppid: int
    pgrp: int
    starttime: int


def _stat_fields(pid: int) -> list[str] | None:
    """`/proc/<pid>/stat` split into fields, read after the command name.

    After the last `)` rather than before it: the command name is
    parenthesised and may itself contain spaces and brackets, so the fields
    ahead of it are not a fixed count. A file with no `)` in it is not this
    file, and is not parsed.
    """
    try:
        raw = (_PROC / str(pid) / "stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    end = raw.rfind(")")
    if end < 0:
        return None
    fields = raw[end + 1:].split()
    # The first field here is the process state, which is field 3 of the
    # line; starttime is field 22, so it is the nineteenth from here.
    return fields if len(fields) >= 20 else None


def _stat_of(pid: int) -> _Stat | None:
    """The decided fields of a live process, or None when it cannot be read."""
    fields = _stat_fields(pid)
    if fields is None:
        return None
    try:
        return _Stat(
            ppid=int(fields[1]),
            pgrp=int(fields[2]),
            starttime=int(fields[19]),
        )
    except ValueError:
        return None


def _state_of(pid: int) -> str | None:
    """A live process's state letter, or None when the line cannot be read.

    Read from the same split as the numbers, so it says whether that split
    landed in the right place: a field that is not a single letter is a file
    this module is reading wrongly, not a process in an unknown state.
    """
    fields = _stat_fields(pid)
    return None if fields is None else fields[0]


def _parent_of(pid: int) -> int | None:
    """A live process's parent, or None when the kernel will not say."""
    stat = _stat_of(pid)
    return None if stat is None else stat.ppid


def _starttime_of(pid: int) -> int | None:
    """The moment a process started, in the kernel's own clock since boot.

    This is the identity a pid cannot fake. `fork` gives the child a reading
    of the same clock that nothing else will ever have for that pid again, so
    a pid whose reading has changed belongs to somebody else, whatever its
    command line and owner happen to say.
    """
    stat = _stat_of(pid)
    return None if stat is None else stat.starttime


def _group_of(pid: int) -> int | None:
    """The process group a live process is in, or None when it cannot be read."""
    stat = _stat_of(pid)
    return None if stat is None else stat.pgrp


def _owner_uid(pid: int) -> int | None:
    """The account a process belongs to, or None when there is nothing there.

    Read from `/proc/<pid>` itself rather than from any field of `stat`,
    because this is the question the kernel answers with an owner and not with
    a number the process chose. None means the pid is gone: the caller is
    looking at a process that left between the listing and this read, and
    there is nothing of it left to signal.
    """
    try:
        return os.stat(_PROC / str(pid)).st_uid
    except OSError:
        return None


def _cmdline_of(pid: int) -> list[str] | None:
    """A live process's full argv, or None when the file cannot be read.

    An empty list is an answer, not a failure: the kernel empties
    `/proc/<pid>/cmdline` for a process that has exited and not been reaped,
    which is a different fact from a file that could not be opened, and a
    caller deciding whether to signal this pid needs to tell them apart.

    The words are decoded with `os.fsdecode`, which is the exact inverse of
    the encoding `Popen` uses when it writes argv into a fork, so a path that
    is not valid UTF-8 still compares equal to the string that was passed.
    """
    try:
        raw = (_PROC / str(pid) / "cmdline").read_bytes()
    except OSError:
        return None
    return [os.fsdecode(word) for word in raw.split(b"\0") if word]


def _ancestor_chain() -> list[int]:
    """This process and every process it descends from, read now.

    Walked at every decision rather than snapshotted once. An ancestor that
    exits and whose pid is handed to something else is still in the kernel's
    parent chain at the moment a signal goes out, and it is that moment this
    module is deciding on; a chain read before the run started answers a
    question about a different moment.
    """
    chain = [os.getpid()]
    while len(chain) < _ANCESTOR_LIMIT:
        parent = _parent_of(chain[-1])
        if parent is None or parent <= 0 or parent in chain:
            return chain
        chain.append(parent)
    return chain


def _hidden_pids() -> str | None:
    """None when every pid on this host is visible in `/proc`, or what hides them.

    procfs can be mounted with `hidepid=`, which takes other accounts' processes
    out of the directory listing entirely rather than merely protecting their
    files. The group check below decides that a process group is safe to signal
    by looking at every member the listing shows, so a listing that is missing
    other accounts' processes would make that decision on a partial view and
    report it as complete — which is the same shape as a check that passes
    because it could not see what it was looking for.

    Read from the mount table rather than inferred from what is visible,
    because an empty listing is indistinguishable from a hidden one except by
    being wrong. Both tables are tried because `mountinfo` and `mounts` have
    gone missing on real systems; if neither can be read the answer is that
    this cannot be known, which is a refusal rather than a pass.
    """
    for source in (_PROC / "self" / "mountinfo", _PROC / "mounts"):
        try:
            lines = source.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            for option in line.replace(",", " ").split():
                if option.startswith("hidepid=") and option != "hidepid=0":
                    return (f"{source} says this proc filesystem is mounted with {option}, so "
                            f"other accounts' processes are absent from the listing and no process "
                            f"group can be checked completely here")
        return None
    return (f"neither {_PROC}/self/mountinfo nor {_PROC}/mounts can be read, so whether this "
            f"proc filesystem hides other accounts' processes is unknown")


def _signal_group(group: int, sig: signal.Signals) -> bool:
    """Whether the kernel accepted a signal for a whole process group.

    False is not an error here but it is not a success either, and the caller
    records a signal only when this says yes: a group that has already gone
    is a group nothing was sent to.
    """
    try:
        os.killpg(group, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _resolve_executable(name: str, *, cwd: str | os.PathLike[str] | None,
                        env: Mapping[str, str] | None) -> str | None:
    """The file the kernel would exec for this word, or None when there is none.

    This is `subprocess`'s own rule, applied to the environment and directory
    the *child* would be given rather than to this process's, because that is
    what the kernel does with it. A word that names a directory is that file,
    resolved against the child's directory when it is relative. A bare name is
    searched for on the child's `PATH` — `os.get_exec_path` is the search the
    kernel performs, including the `os.defpath` a child with no `PATH` of its
    own is given, and including a relative `PATH` entry meaning a directory
    relative to where the child runs.

    The caller decides which argv to pass. `Guard.spawn` uses this path for
    argv[0] when no explicit executable was supplied, so an interpreter that
    expands its own name does not invalidate the recorded command line.
    """
    if os.path.dirname(name):
        return name if os.path.isabs(name) or cwd is None else os.path.join(os.fspath(cwd), name)
    for entry in os.get_exec_path(env):
        # `os.get_exec_path` already yields the default path when `env` carries
        # no `PATH`, which is the rule `execvp` itself applies, so a missing
        # `PATH` is searched the way the child would search it.
        directory = entry or os.curdir
        candidate = os.path.join(directory, name)
        if not os.path.isabs(candidate) and cwd is not None:
            candidate = os.path.join(os.fspath(cwd), candidate)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _exec_is_provable(name: str, *, cwd: str | os.PathLike[str] | None = None,
                      env: Mapping[str, str] | None = None) -> str | None:
    """None when the kernel will exec this file itself, or why it will not.

    The file is found first, through the child's `PATH` and directory, because
    most of what a supervisor runs is named rather than spelled out: refusing
    `sleep` for not being readable in this process's directory would refuse
    every bare command name a real run uses, and refusing to start a child is
    not the same mistake as failing to prove one.

    An executable whose first bytes are `#!` is not exec'd by the kernel
    directly. It runs the interpreter that line names and rewrites argv to
    `[interpreter, optional-argument, the script, *argv[1:]]`, so what appears
    in `/proc/<pid>/cmdline` is not the argv this run passed. Probed on this
    host rather than assumed: a `#!/usr/bin/env python3` script shows as
    `['python3', script, ...]` — `env` execs the interpreter and argv[0]
    becomes the interpreter's own name — while `#!/usr/bin/python3 -E` shows as
    `['/usr/bin/python3', '-E', script, ...]`. An interpreter that is itself a
    script is expanded again, which is why the answer here is a refusal rather
    than a predicted command line: a guard that cannot name its target at the
    moment a signal goes out is not a guard.

    This says nothing about whether the callers in this repository happen to
    name real binaries. That was checked for one interpreter on one host and
    not for any other, and no caller is assumed to be safe by it: an
    environment whose `sys.executable` is a wrapper is refused here, with the
    reason, rather than accommodated by a guess at what the kernel would show.
    """
    executable = _resolve_executable(name, cwd=cwd, env=env)
    if executable is None:
        return (f"no executable named {name!r} is on the PATH the child would be given "
                f"({os.pathsep.join(os.get_exec_path(env))!r}), so the kernel would not exec it "
                f"and what it would exec instead cannot be known")
    try:
        with open(executable, "rb") as handle:
            first = handle.readline(256)
    except OSError as exc:
        return (f"{executable} cannot be read ({exc}), so what the kernel would exec for it "
                f"cannot be known")
    if not first.startswith(b"#!"):
        return None
    return (f"{executable} begins with {first[:64]!r}, so the kernel would exec the interpreter "
            f"that line names and show a rewritten command line in /proc, not the argv this run "
            f"passes; this guard only starts children whose command line it can name exactly")


def _release(process: subprocess.Popen[Any]) -> None:
    """Close the pipes this process opened for a child, so it can see the run end.

    End of file is how every child in these supervisors is told the run is
    over, and it is the only thing said to a child this run will not signal.
    """
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is None:
            continue
        try:
            stream.close()
        except OSError:  # pragma: no cover - already closed
            pass


# --- the decision ----------------------------------------------------------------


class _Decision(NamedTuple):
    """One set of guards, read at one moment: a group, an absence, or a reason."""

    group: int | None
    gone: bool
    refused: str | None


# --- the guard -------------------------------------------------------------------


class Guard:
    """The children of one process, and the proof that each is still its own.

    Built before anything is started, and refusing to be built at all on a
    system where the proofs cannot be read.
    """

    def __init__(self) -> None:
        # The account whose children these are. Read once, at the moment the
        # guard is built, because it is a property of the run rather than of
        # any one signal.
        self.uid = os.getuid()
        self._require_proc()

    def check_spawn(self, argv: Sequence[str], label: str, *, executable: str | None = None,
                    cwd: str | os.PathLike[str] | None = None,
                    env: Mapping[str, str] | None = None) -> None:
        """Everything `spawn` refuses a command for, before anything is forked.

        The same preflight `spawn` runs, factored out because a caller is not
        the only thing that forks a child this run has to be able to stop: a
        guest console is forked and exec'd by a terminal library, and
        `spawn` never sees that fork. So the caller asks this first, and gets
        the identical refusal for the identical reason rather than a second
        opinion about whether the kernel would rewrite the command line — two
        opinions is one too many, because only one of them would be checked.

        `executable`, `cwd` and `env` are the answers to questions about the
        child rather than about this process, and they are asked the way
        `Popen` asks them: an explicit `executable` replaces argv[0] as the
        file to run, and the directory and environment decide where a bare
        name is found. Passing the child's own values is what makes a name
        like `qemu-system-x86_64` resolvable at all.

        This method does not change argv. `spawn` uses the resolved path for
        argv[0] unless the caller supplied an explicit executable. The record
        then contains the exact words passed to `Popen`.
        """
        self._require_proc()
        words = list(argv)
        if not words:
            raise ProcUnavailable(f"the {label} was to be started with no command line at all")
        unwritable = _exec_is_provable(
            str(executable) if executable is not None else str(words[0]), cwd=cwd, env=env)
        if unwritable is not None:
            raise ProcUnavailable(
                f"the {label} was NOT started: {unwritable}, and the command line "
                f"{words!r} cannot be matched against /proc later"
            )

    def spawn(self, argv: Sequence[str], label: str, **popen: Any) -> Child:
        """Start one child and bind it to the identity it has right now.

        Two refusals happen here, both of them before or instead of a signal
        rather than after one.

        Before the fork: an executable the kernel would not exec directly is
        refused, because the command line this child would later be matched
        against is then not the argv this run passed, and a guard that records
        a command line nothing can match is a guard that stops checking. The
        check itself is `check_spawn`, so a caller that forks elsewhere gets
        the same one, and it is asked with this child's own `executable`,
        `cwd` and `env` — a bare name is found on the PATH the child would be
        given rather than in whatever directory this process is standing in.

        After the fork: if `/proc` does not answer for the pid it just gave
        back, the child cannot be bound to an identity and nothing is sent to
        it. The pipes this process opened are closed instead — end of file is
        how a child here is told the run is over — and the child is waited for
        within a bound. The failure that follows names the child, its pid and
        its command line, and says plainly that nothing was signalled and
        whether it left on its own, because a report that implied this child
        was never started would be false: it was, and it is named.

        The identity is read inside this function, between the fork and the
        return, because that is the only window in which it is safe to read
        it: while the child has not been waited for, the kernel still holds
        its pid, so nothing else can be given that number. A caller that
        fetched the identity itself would have to promise not to have polled
        the child first, and a poll reaps.

        Callers start their children with `start_new_session=True`, which is
        what makes the group kill a group of one; the guard does not add it,
        because a caller that has deliberately placed a child in a group it
        shares with something else is exactly the case the guards below exist
        to refuse.
        """
        self.check_spawn(argv, label, executable=popen.get("executable"),
                         cwd=popen.get("cwd"), env=popen.get("env"))
        words = list(argv)
        if popen.get("executable") is None:
            resolved = _resolve_executable(str(words[0]), cwd=popen.get("cwd"),
                                           env=popen.get("env"))
            if resolved is None:
                raise ProcUnavailable(f"the {label} executable disappeared before it was started")
            words[0] = os.path.abspath(resolved)
        process = subprocess.Popen(words, **popen)
        starttime = _starttime_of(process.pid)
        if starttime is None:
            # Nothing is signalled. Every check the rest of this module makes
            # is a check on a read, and this one came back empty; sending a
            # signal on that evidence is the accident the checks exist to
            # prevent, so this child is ended the way a child that was never
            # going to leave is ended — its input is closed and it is waited
            # for.
            _release(process)
            left: int | None = None
            try:
                left = process.wait(timeout=DEFAULT_GRACE)
            except subprocess.TimeoutExpired:
                pass
            raise ProcUnavailable(
                f"the {label} WAS started, as pid {process.pid} running {words!r}, and NOT "
                f"signalled: {process.pid}/stat could not be read between the fork and the "
                f"reading of when it started, so it was never bound to an identity and no "
                f"signal was sent on that evidence. Its pipes were closed and it was waited "
                f"for {DEFAULT_GRACE}s; "
                + (f"it left on its own with status {left}"
                   if left is not None
                   else "it had not left when the wait ended and is left running for the kernel "
                        "to reap")
            )
        return Child(label, process, tuple(words), starttime)

    def adopt(self, label: str, argv: Sequence[str], pid: int,
              probe: Callable[[], int | None], ready: float = ADOPT_TIMEOUT) -> Child:
        """Bind a child this guard did not start, or refuse to.

        The case is a terminal: a pseudo-terminal child is forked into a
        session of its own, so the group this harness chose for the children
        `spawn` starts says nothing about it, and the guard has to hold the
        pid rather than a group. What is asked here is the same evidence
        `spawn` gathers between its fork and its return, gathered late
        instead: the command line the caller says this pid was started with
        has to be what `/proc` shows for it, and the moment it started has to
        be readable, at the same moment, or nothing is recorded.

        `probe` answers one question — has the child exited, and with what
        status — and is the only thing read from whatever started it. It may
        reap, which is how a terminal library reports an exit, and it may not
        signal. Two refusals are possible here and both are refusals rather
        than signals, because the child is already running and a refusal here
        is the only way to leave it alone:

        * it is already gone when the proof is attempted, which is reported
          with its status, because a run that reports an emulator as never
          started when it was is lying about the one thing that matters;
        * `/proc` does not show this pid running this command line within
          `ready` seconds, which is reported with both command lines, so a
          mismatch can be read rather than guessed at. A child whose argv was
          rewritten by an interpreter is caught before the fork here, by the
          same `_exec_is_provable` probe `spawn` uses.
        """
        self._require_proc()
        words = tuple(argv)
        if not words:
            raise ProcUnavailable(
                f"the {label} was already started, as pid {pid}, and cannot be adopted: no "
                f"command line was offered to match /proc/{pid}/cmdline against, so nothing "
                f"was signalled")
        unwritable = _exec_is_provable(words[0])
        if unwritable is not None:
            raise ProcUnavailable(
                f"the {label} WAS already started, as pid {pid}, and was NOT adopted and NOT "
                f"signalled: {unwritable}, and the command line {list(words)!r} cannot be "
                f"matched against /proc/{pid}/cmdline later")
        deadline = time.monotonic() + ready
        answer = f"pid {pid} did not show the command line {list(words)!r} within {ready}s"
        while True:
            left = probe()
            if left is not None:
                raise ProcUnavailable(
                    f"the {label} WAS started, as pid {pid} running {list(words)!r}, and had "
                    f"already exited with status {left} before this run could bind it to an "
                    f"identity; nothing was signalled and there is nothing left to signal")
            started = _starttime_of(pid)
            if started is not None:
                cmdline = _cmdline_of(pid)
                if cmdline == list(words):
                    # Read again after the match, because the number belongs to
                    # this harness' child only while it is unreaped, and a
                    # recycled pid that happened to answer the same question
                    # would have to answer it with a different start time.
                    again = _starttime_of(pid)
                    if again != started:
                        answer = (f"pid {pid} started at {started} and at {again} across a single "
                                  f"reading, so it was not one process and was NOT adopted")
                        break
                    return Child(label, Adopted(pid, words, probe), words, started)
                if cmdline is not None:
                    answer = (f"pid {pid} is running {cmdline!r} rather than {list(words)!r}, the "
                              f"command line this run was told it started")
            if time.monotonic() >= deadline:
                break
            time.sleep(0.005)
        raise ProcUnavailable(
            f"the {label} WAS started, as pid {pid}, and was NOT adopted and NOT signalled: "
            f"{answer}. It is left running, because a run that cannot prove a pid is the "
            f"process it started does not get to stop it")

    def stop(self, child: Child, grace: float = DEFAULT_GRACE) -> Stop:
        """Stop one child the way a stopping child deserves, and reap it.

        `SIGTERM`, then a bounded wait, then `SIGKILL` — and `SIGKILL` only
        after the guards have been read a second time. The decision before
        `SIGTERM` says the pid was the run's child at that moment; the grace
        that follows is long enough for the pid to be recycled, and a group
        number is a number the kernel hands out again too. The second reading
        is what makes the kill a statement about the process that is running
        now.

        Nothing here reaches a signal after a refusal, and there is no second
        way to stop a child. A refusal is reported and the process is left
        running, which is the one outcome this module is willing to produce.

        A child this guard did not fork can also fail to answer at all — its
        console stopped reporting and recorded no status — and that is a
        refusal too, arrived at from a different direction. It is not a status
        of zero and not a pass: the only honest record of a child whose exit
        was never observed is one that says so, and it is the one that leaves
        the caller's console open rather than closing it over a process whose
        fate nobody established.
        """
        sent: list[str] = []

        def unanswerable(unknown: ProcessStateUnknown) -> Stop:
            """The record for a probe that cannot say, given what went out already.

            Naming the signals that were already sent is not politeness. The
            caller decides whether to close a console or reach for a signal on
            the strength of this sentence, and a teardown that reported "nothing
            was signalled" over a child it had just sent `SIGKILL` to would
            have it close a descriptor over a process that may still be running
            and tell a reader nothing had been done to it.
            """
            if sent:
                reason = (f"{unknown}; this run had already sent "
                          f"{' then '.join(sent)} to it, so whether it is still running is "
                          f"unknown and only stopping it by hand will say")
            else:
                reason = (f"{unknown}; nothing was signalled, the child is left as it was found, "
                          f"and only stopping it by hand stops it")
            return Stop(child.label, list(sent), None, reason)

        try:
            decision = self._decide(child)
        except ProcessStateUnknown as unknown:
            return unanswerable(unknown)
        if decision.gone:
            # It left on its own, which is how it was supposed to end. The
            # status `waitpid` reported is the whole record.
            return Stop(child.label, [], child.process.returncode, None)
        if decision.refused is not None:
            return Stop(child.label, [], None, decision.refused)

        if _signal_group(decision.group, signal.SIGTERM):
            sent.append(signal.SIGTERM.name)
        try:
            code = self._wait(child, grace)
        except ProcessStateUnknown as unknown:
            return unanswerable(unknown)
        if code is not None:
            return Stop(child.label, sent, code, None)

        # The grace expired with the child still there, so it is a child that
        # does not answer the polite signal. Everything is read again: the
        # reading is not a confirmation of the first one, it is a second
        # decision, and it can refuse where the first one agreed.
        try:
            again = self._decide(child)
        except ProcessStateUnknown as unknown:
            return unanswerable(unknown)
        if again.gone:
            return Stop(child.label, sent, child.process.returncode, None)
        if again.refused is not None:
            return Stop(child.label, sent, None,
                        f"the target guards refused again before SIGKILL: {again.refused}")
        if _signal_group(again.group, signal.SIGKILL):
            sent.append(signal.SIGKILL.name)
        try:
            code = self._wait(child, grace)
        except ProcessStateUnknown as unknown:
            return unanswerable(unknown)
        if code is None:
            return Stop(child.label, sent, None,
                        f"the {child.label} did not exit after SIGKILL")
        return Stop(child.label, sent, code, None)

    def wait(self, child: Child, deadline: float,
             grace: float = DEFAULT_GRACE) -> Stop:
        """Wait for a child to leave; stop it if the deadline arrives first.

        The deadline is enforced here rather than by a caller wrapping this,
        because the child that misses it has still to be stopped, and the
        `Stop` that stopped it is what the raised `DeadlineMissed` carries.
        """
        budget = max(deadline - time.monotonic(), 0.1)
        try:
            return Stop(child.label, [], child.process.wait(timeout=budget), None)
        except subprocess.TimeoutExpired:
            raise DeadlineMissed(self.stop(child, grace)) from None

    def _wait(self, child: Child, grace: float) -> int | None:
        """The status `waitpid` reports within the grace, or None while it has not."""
        try:
            return child.process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            return None

    def _require_proc(self) -> None:
        """Prove the guards can be read at all, before anything is forked.

        Not a formality. A procfs that is absent, empty or mounted somewhere
        unexpected turns every check below into a silent pass, and a silent
        pass is a guard that signs everything it is shown. This raises while
        the run still has nothing running.
        """
        problems: list[str] = []
        try:
            entries = os.listdir(_PROC)
        except OSError as exc:
            raise ProcUnavailable(
                f"{_PROC} cannot be listed ({exc}), so no pid can be proved to be a process this "
                f"run started; refusing before anything is started rather than starting a child this "
                f"run would not be allowed to stop"
            ) from exc
        if not any(entry.isdigit() for entry in entries):
            problems.append(f"{_PROC} lists no processes at all")
        # The listing the group check walks has to be the whole listing. A
        # procfs that hides other accounts' processes would let that check
        # conclude a group is safe on a partial view and report it as complete.
        hidden = _hidden_pids()
        if hidden is not None:
            problems.append(hidden)

        # The state letter is the field the split starts on, so reading it as
        # one is what proves the split landed after the command name rather
        # than somewhere inside it. A file that parses as numbers but not as a
        # state is a file every check below would misread.
        state = _state_of(os.getpid())
        if state is None or len(state) != 1 or not state.isalpha():
            problems.append(
                f"{_PROC}/self/stat does not parse: the field after the command name is "
                f"{state!r}, which is not a process state")
        if _stat_of(os.getpid()) is None:
            problems.append(f"{_PROC}/self/stat carries no parent, group or start time")
        if _cmdline_of(os.getpid()) is None:
            problems.append(f"{_PROC}/self/cmdline cannot be read")
        if _owner_uid(os.getpid()) != self.uid:
            problems.append(
                f"{_PROC}/self is not owned by uid {self.uid}, so the owner checks cannot work")
        if problems:
            raise ProcUnavailable(
                "this is not a Linux procfs a supervisor can guard its children against: "
                + "; ".join(problems)
            )

    def _decide(self, child: Child) -> _Decision:
        """Every guard, read now, about the pid this child is holding.

        The order is the order in which a fact makes the next one pointless:
        a process that has already left needs no ownership proof, a pid that
        is this harness is not going to be anything else by the time its
        owner is read, and a pid whose start time has changed is somebody
        else's whatever its argv says.
        """
        process = child.process
        pid = process.pid

        if process.poll() is not None:
            return _Decision(None, True, None)

        chain = _ancestor_chain()
        if pid in chain:
            return _Decision(None, False,
                             f"pid {pid} is this harness or a process it descends from, and a "
                             f"supervisor does not signal itself")

        started = _starttime_of(pid)
        if started is None:
            return _Decision(None, False,
                             f"{_PROC}/{pid}/stat cannot be read, so this pid cannot be proved "
                             f"to be the process this run started")
        if started != child.starttime:
            return _Decision(None, False,
                             f"pid {pid} started at {child.starttime} and at {started} now, so it "
                             f"is a different process wearing a pid this run started a child on")

        owner = _owner_uid(pid)
        if owner is None:
            return _Decision(None, False,
                             f"{_PROC}/{pid} is gone, so nothing there can be signalled")
        if owner != self.uid:
            return _Decision(None, False,
                             f"pid {pid} belongs to uid {owner} rather than uid {self.uid}, so "
                             f"this run does not own it and will not signal it")

        cmdline = _cmdline_of(pid)
        if cmdline is None:
            return _Decision(None, False,
                             f"{_PROC}/{pid}/cmdline cannot be read, so the command line this run "
                             f"started cannot be compared")
        if list(cmdline) != list(child.argv):
            # An empty command line is what the kernel shows for a process
            # that has exited and is waiting to be reaped, which is a child
            # that ended rather than a pid that was reused. Decided by asking
            # rather than by special-casing the empty list, because that is
            # the same question the first line of this function asked.
            if not cmdline and process.poll() is not None:
                return _Decision(None, True, None)
            return _Decision(None, False,
                             f"pid {pid} is running {cmdline!r} rather than "
                             f"{list(child.argv)!r}, the command line this run started it with")

        group = _group_of(pid)
        if group is None:
            return _Decision(None, False,
                             f"{_PROC}/{pid}/stat names no process group")
        mine = os.getpgid(0)
        if group == mine:
            return _Decision(None, False,
                             f"pid {pid} is in process group {group}, which is this harness's own "
                             f"group; a signal to it would land on this process and on everything "
                             f"sharing its group")
        for ancestor in chain[1:]:
            if _group_of(ancestor) == group:
                return _Decision(None, False,
                                 f"pid {pid} is in process group {group}, which is the group of "
                                 f"this harness's ancestor {ancestor}; a signal to it would land "
                                 f"on a process this run does not own")

        try:
            entries = sorted(os.listdir(_PROC))
        except OSError as exc:
            return _Decision(None, False,
                             f"the process table cannot be listed ({exc}), so no member of group "
                             f"{group} could be checked and the group was left alone")
        for entry in entries:
            if not entry.isdigit():
                continue
            member = int(entry)
            member_stat = _stat_of(member)
            if member_stat is None:
                # Two different facts share this branch and only one of them is
                # safe to skip on. A pid that has left has no entry left to
                # read and cannot be in the group. A pid whose entry is still
                # there and cannot be read is a process this run cannot place,
                # and treating it as a non-member would be deciding the group
                # is safe on a listing it did not fully understand.
                if (_PROC / str(member)).exists():
                    return _Decision(None, False,
                                     f"pid {member} is listed in {_PROC} but its stat could not be "
                                     f"read, so whether it is a member of process group {group} "
                                     f"cannot be known and the group was left alone")
                continue
            if member_stat.pgrp != group:
                continue
            member_owner = _owner_uid(member)
            if member_owner is None:
                if (_PROC / str(member)).exists():
                    return _Decision(None, False,
                                     f"pid {member} is a member of process group {group} but "
                                     f"{_PROC}/{member} cannot be read for an owner, so whether "
                                     f"this run may signal the group cannot be known")
                # It left between the two reads, so there is nothing left in
                # the group that belongs to it.
                continue
            if member_owner != self.uid:
                return _Decision(None, False,
                                 f"process group {group} holds pid {member}, which belongs to uid "
                                 f"{member_owner} rather than uid {self.uid}; a signal to the "
                                 f"group would signal a process this run does not own")

        return _Decision(group, False, None)


def refusals(stops: Iterable[Stop]) -> list[str]:
    """Every refusal in a teardown, named, for a run to fail on.

    A teardown that refused is a run that ended with something it could not
    account for. This is what makes that visible to the caller rather than a
    field in a record nobody looked at.
    """
    return [f"{stop.child}: {stop.refused}" for stop in stops if stop.refused is not None]