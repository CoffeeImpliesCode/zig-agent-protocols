"""Guarded BSD emulators, driven over a pseudo terminal or ordinary pipes.

Most drivers in this directory boot their guest with QEMU on a pseudo terminal
and then talk to it for an hour or two. Three facts make that different from
the children the interoperability supervisors start with `subprocess.Popen`,
and all three are why this module exists rather than a line in each driver.

The first is who forks it. `pexpect.spawn` forks and execs the emulator
itself, so `Guard.spawn` never sees the fork and cannot bind the pid to an
identity inside it — and inside the un-reaped fork is the only window in which
a pid provably cannot have been handed to somebody else. What the guard can do
is adopt it afterwards: `Guard.adopt` takes the pid, the command line the
terminal recorded, and a probe that says whether the child has exited, and it
requires `/proc` to agree with all three at one moment before it records
anything. Same decision as `spawn`, applied later, to a child this run did not
fork. Nothing here re-decides whether a pid is this run's; that answer is read
in one place and this module only supplies the facts it is asked for.

The second is the process group. `pty.fork` calls `setsid`, so the emulator
leads a session and a group of its own. The group a supervisor places its own
children in cannot reach it, and that is the guard working rather than failing:
it declines to signal a group this harness did not choose. An emulator has to
be held by pid, which is what adoption is for.

The third is who else may signal it. `pexpect.spawn.close(force=True)` and
`.terminate(force=True)` reach `os.kill` on their own, with SIGHUP, SIGCONT,
when the console object is collected — so a driver that forgets a `close` does
not leak a descriptor, it signals a pid nobody proved. anita calls both on the
machine it started. Adoption takes those doors away on that one object: the
terminal library is told its child is already closed, so its finaliser does
nothing and `kill()` becomes a refusal naming the pid and the signal it did not
send. Every stop after that is `Guard.stop`, which reads the same five facts
again immediately before each of the two signals it is willing to send.

The fourth thing is that the fork is not this run's to see. `pexpect.spawn`
execs whatever it was handed, resolved against this process's own `PATH`, so
the guard asks about the command before the library forks anything, through the
same preflight `Guard.spawn` uses. That is what makes a bare name like
`qemu-system-x86_64` a file rather than a name that cannot be read from
somewhere else, and it is the last moment at which a refusal leaves nothing
running.

Nothing here papers over any of it. A guard refusal is carried out in the
`Stop` the caller is handed, with the console left open and the emulator left
running rather than closed over; a console that cannot be adopted is left
running and named in the failure; a missing terminal library is a refusal and
not a fallback to pipes; and a cancellation is an exception the driver already
handles rather than a signal this process sends to itself.

Two limits are stated rather than papered over. A console this run refused to
stop is held, so that the collector cannot close the master of its pseudo
terminal and hang up an emulator nothing here decided to signal — but the hold
lasts exactly as long as this process, and when the harness exits the kernel
closes that descriptor anyway. And a cancellation that arrives while the guard
is between its two signals is recorded rather than raised at it: the teardown
finishes first, and the cancellation is raised afterwards, so a second Ctrl-C
cannot abandon an emulator halfway through being stopped.
"""

from __future__ import annotations

import os
from pathlib import Path
import signal
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from types import ModuleType
from typing import Any

# The guard lives with the supervisors it was written for, and this directory
# is on the interpreter's path rather than that one: a driver imports this
# module, and this module imports the guard from where the guard is kept. The
# directory is resolved from this file rather than searched for, so a run
# cannot pick up a different `process_guard` that happens to be on the path.
_HERE = Path(__file__).resolve().parent
_GUARD_DIR = _HERE.parent / "test" / "interop"
if str(_GUARD_DIR) not in sys.path:
    sys.path.insert(0, str(_GUARD_DIR))

from process_guard import (  # noqa: E402
    DEFAULT_GRACE,
    Child,
    Guard,
    ProcessStateUnknown,
    Stop,
)

# The wait between a guest's end of file and the guarded stop that follows it.
# Generous, because an emulator that is on its way out flushes first, and a
# guest that is stopped here would otherwise be stopped rather than waited for.
SHUTDOWN_GRACE = 30.0

# The wait `pexpect.spawn` gives its own `expect` calls when a driver names
# none. Every driver in this directory passes its own phase budget instead;
# this is here so a caller that forgets one still has a bound.
DEFAULT_CONSOLE_TIMEOUT = 60.0

# Whether a guarded teardown is in progress, and the cancellation that arrived
# while it was. A signal handler runs between two bytecodes of whatever was
# executing, and during a teardown the bytecode it lands in is the middle of a
# `SIGTERM`-then-`SIGKILL` sequence that has already been decided on and must
# be finished: raising there unwinds a stop that cannot be taken back and skips
# the `finally` that restores the handlers. So inside the window the signum is
# recorded here and `finish_many` raises it once every guest has been through
# the guard. Outside the window nothing changes — the signal is the caller's,
# raised where it landed.
_TEARDOWN: bool = False
_PENDING: Cancelled | None = None


class GuestProcessError(RuntimeError):
    """A guest emulator could not be started, adopted or stopped under the guard."""


class SignalRefused(GuestProcessError):
    """Something reached for a guarded console's own signalling path."""


class Cancelled(RuntimeError):
    """The caller cancelled the run.

    Raised from the handler rather than acted on inside it. A handler that
    stops a guest and then re-raises its own signal at itself does the teardown
    twice over: once by hand, on whatever the pid looks like at that moment,
    and once through the interpreter's default disposition, where nothing was
    proved about anything. Raising instead unwinds into the same `finally` every
    other exit takes, so the guarded stop happens once and through the guard,
    and the driver reports the cancellation as an exit status.
    """

    def __init__(self, signum: int) -> None:
        super().__init__(f"the run was cancelled by {signal.Signals(int(signum)).name}")
        self.signum = int(signum)


@dataclass
class Guest:
    """One emulator, its console, and the guard's record of the same process.

    A terminal console is the object the driver talks to: `expect`,
    `sendline`, `after`, `exitstatus`. A pipe-driven guest has no console;
    its caller owns the pipes. Both use the same cancellation-safe teardown.
    `child` is the guard's record, which is the only thing here that may stop it.
    """

    label: str
    console: Any
    child: Child
    guard: Guard


def require_stopped(stop: Stop, label: str, cause: BaseException | None = None) -> Stop:
    """Raise when a teardown refused, chained to what the run was already reporting.

    Called on every exit, including the ones that already failed, because a
    refusal is not a detail to be appended to whatever went wrong first: a run
    that could not stop what it started has not accounted for the machine it
    was running, and that is the report. It is raised in place of the run's own
    verdict rather than after it, so no caller can reach a success line having
    passed over a refusal.

    What it says about the emulator is taken from the `Stop` rather than
    assumed. A refusal before any signal and a refusal after them are different
    situations and the report has to tell them apart: in the first, nothing was
    done to the process and it is certainly still running; in the second — a
    guard that decided twice and was refused the second time, or a console that
    stopped answering after `SIGTERM` went out — the process may or may not be
    there, and a sentence saying "nothing was signalled" would be false about
    a child this run had already signalled.
    """
    if stop.refused is not None:
        if stop.signals:
            where = (f"this run had already sent {stop.sent} before the guard refused, so whether "
                     f"the emulator is still running is not something this run can say, and only "
                     f"stopping it by hand will say")
        else:
            where = ("nothing was signalled, the emulator is still running, and only stopping it "
                     "by hand stops it")
        raise GuestProcessError(
            f"the {label} was NOT stopped and its console was NOT closed, because this run "
            f"could not prove what its child was doing: {stop.refused}. {where}"
        ) from cause
    return stop


def module(name: str) -> ModuleType:
    """Import a pinned package, which only the bsd-cross profile provides."""
    try:
        return __import__(name)
    except ImportError as error:
        raise GuestProcessError(
            f"{name} is not importable, so no guest console can be opened; run under "
            f"devenv --profile bsd-cross shell"
        ) from error


def spawn(guard: Guard, argv: Sequence[str], label: str,
          timeout: float = DEFAULT_CONSOLE_TIMEOUT) -> Guest:
    """Open a console on the emulator, and adopt it before it is driven at all.

    The guard is asked about the command before the terminal library forks
    anything, through the same preflight `Guard.spawn` runs and not a second
    copy of it. That check is what turns a bare name like `qemu-system-x86_64`
    into a file this run can read, by looking on the `PATH` the child would be
    given; a lookup against this process's own environment and directory would
    refuse every emulator a real run starts, and a refusal here is the last
    moment at which nothing has been forked yet.

    Everything after the fork is `adopt`'s, including what happens when the
    proof fails: the console is retained by `adopt` itself, so a caller cannot
    forget to and leave a live emulator to be hung up by a finaliser.
    """
    pexpect = module("pexpect")
    guard.check_spawn(argv, label)
    return adopt(guard, pexpect.spawn(argv[0], list(argv[1:]), timeout=timeout, encoding=None),
                 label)


def adopt(guard: Guard, console: Any, label: str) -> Guest:
    """Bind a console somebody else opened to the guard, or refuse to.

    For an emulator an anita instance started: `adopt` is the earliest moment
    this run can hold the pid, and it is taken the moment the console exists
    rather than after the boot call returns, because a boot that fails half way
    is exactly the case where a child would otherwise be left unheld.

    The command line recorded is the one the terminal library says it handed to
    `exec`, with argv[0] already resolved to the path the kernel was given.
    That is not a guess at what `/proc` will show: it is the library's own
    record of it, and the adoption still reads `/proc` and compares, so a
    terminal that recorded something other than what it exec'd is refused
    rather than adopted.

    A refusal retains the console. The caller — a driver that has just been
    handed an emulator by a library it does not own — is about to drop its last
    reference to it, and dropping that reference closes the master of the
    pseudo terminal and hangs up a process this run declined to signal. So the
    abandonment is done here, where the console is in hand, and the caller has
    nothing to remember: a failed adoption is always a retained console and
    always a named pid.
    """
    pexpect = module("pexpect")
    try:
        child = guard.adopt(label, _recorded_argv(console, label), int(console.pid),
                            _probe(console, pexpect))
    except BaseException:
        _abandon(console)
        raise
    guest = Guest(label, console, child, guard)
    _claim(guest)
    return guest


def finish(guest: Guest, grace: float = DEFAULT_GRACE) -> Stop:
    """Stop one emulator through the guard, and close its console once it is gone.

    The one-guest case of `finish_many`, which is where the decisions live. The
    single-element call is the real path rather than a separate implementation
    of the same teardown, because a driver that adopts two consoles has to get
    exactly the behaviour this gets, and two code paths are two answers to
    what should be one question.
    """
    return finish_many([guest], grace)[0]


def finish_many(guests: Sequence[Guest], grace: float = DEFAULT_GRACE) -> list[Stop]:
    """Stop every guest this run holds, and close each console only once it is gone.

    A run can hold more than one emulator — an installer and the guest it
    installs, or a machine whose library started a second console while the
    first was being adopted — and each one is a process this run has to be able
    to account for. Stopping them one at a time from a `finally` block gets that
    wrong in three ways, and all three are fixed here rather than at each
    call site, because the call sites are the drivers and a rule the drivers
    each have to remember is a rule one of them will not.

    *One teardown.* Every guest in the list is stopped before this returns,
    whatever happens to any of them. An exception from one guest's stop — a
    cancellation most of all, because `Guard.stop` spends up to two grace
    periods inside it and an operator who hits Ctrl-C again is not going to
    wait — is held and the loop continues, so the emulators behind it are
    stopped rather than skipped. Raising it at the end, when every reachable
    stop has been made, is what "all reachable" means.

    *A refusal is primary.* A guard that refused is a run that ended with a
    process it could not account for, and that is the report. A pending
    cancellation is not raised over it: it is held, so the caller sees the
    refusal through the `Stop` it already has to read, and the cancellation is
    re-raised only when the teardown was otherwise clean — which is the case
    where `128 + signum` is an accurate description of how the run ended.

    *A console closes only over a process that has left.* Closing the master of
    a pseudo terminal hangs up everything still reading the slave, so a close
    that ran while the emulator was alive would be a signal no guard
    authorised. Each console is closed on its own evidence: after its own exit
    has been observed and only when its own `Stop` carries no refusal. A
    refused console is retained rather than closed, for the same reason
    `_abandon` retains one, and for the same limited lifetime.

    The list comes back in the order the guests went in, one `Stop` each, so a
    caller that indexed a particular emulator's result is indexing what it
    passed and not a filtered view of it.
    """
    global _TEARDOWN, _PENDING
    # A sequence is taken as a sequence, so the count in a failure below is the
    # number of guests that were asked for rather than the length of whatever
    # happened to be left of an iterator by the time it was needed.
    guests = list(guests)
    stops: list[Stop] = []
    cancelled: Cancelled | None = None
    failure: BaseException | None = None
    # Save rather than clear outright, so a teardown nested inside another one
    # cannot swallow the cancellation the outer window is waiting to report.
    outer, outer_pending = _TEARDOWN, _PENDING
    _TEARDOWN, _PENDING = True, None
    try:
        for guest in guests:
            try:
                stops.append(_stop_one(guest, grace))
            except Cancelled as pending:
                # Held rather than raised: the guests behind this one have not
                # been through the guard yet, and a teardown that stops the
                # first emulator and abandons the rest has done less than the
                # one that was interrupted was asked to do.
                cancelled = pending if cancelled is None else cancelled
            except BaseException as error:
                # The same, for the failures this run has no handling for. A
                # guest whose stop raised is not stopped, and the guests after
                # it still have to be, or the teardown is exactly as partial as
                # the one a cancellation would have made it.
                failure = error if failure is None else failure
        if cancelled is None and _PENDING is not None:
            # Recorded by the handler rather than raised: a signal that arrived
            # while the guard was between its two signals, where raising would
            # have abandoned the teardown it was meant to cancel.
            cancelled = _PENDING
    finally:
        _TEARDOWN = outer
        _PENDING = outer_pending if outer_pending is not None else _PENDING

    refused = [stop for stop in stops if stop.refused is not None]
    if failure is not None:
        # Raised rather than returned, because a short list is a lie about
        # what was stopped: a caller indexing the last entry would be reading
        # some other guest's result. Any refusal is named in the failure so it
        # is not lost with the stops that carried it.
        if refused:
            raise GuestProcessError(
                f"{failure}, and {len(refused)} of the {len(guests)} guests this run started were "
                f"left running because the guard refused: "
                + "; ".join(f"{stop.child}: {stop.refused}" for stop in refused)) from failure
        raise failure
    if refused:
        # The refusal stays primary. It is in the `Stop` the caller already has
        # to read, and `require_stopped` is what turns it into the run's report;
        # raising a pending cancellation over it instead would report how the
        # run was ended and not what it left behind.
        return stops
    if cancelled is not None:
        raise cancelled
    return stops


def _note_cancelled(signum: int) -> None:
    """Record the first cancellation of a teardown, keeping the first signum."""
    global _PENDING
    if _PENDING is None:
        _PENDING = Cancelled(signum)


def _stop_one(guest: Guest, grace: float) -> Stop:
    """Stop one guest, and decide what happens to its console from that alone.

    The console closes on an observed exit and on nothing else. A refusal is
    the one case where the child may still be there, so that is the one case
    where the descriptor pair is kept open — and kept reachable, because a
    console this module holds a reference to and a caller has dropped is a
    console the collector closes, which hangs up the emulator the refusal just
    said it would not touch.
    """
    stop = guest.guard.stop(guest.child, grace=grace)
    if guest.console is None:
        return stop
    if stop.refused is None:
        _close_console(guest.console)
    else:
        _retain(guest.console)
    return stop


def cancel_on(signum: int, _frame: object) -> None:
    """Turn a cancellation signal into an exception the driver already handles.

    Inside a guarded teardown the signum is recorded and the handler returns;
    outside one it raises where it landed, exactly as before.

    The distinction is not a convenience. `Guard.stop` spends up to two grace
    periods inside itself, between the reading that authorises `SIGTERM` and
    the reading that authorises `SIGKILL`, and a signal arriving in that
    window would raise `Cancelled` from the middle of it — abandoning a stop
    that cannot be taken back, skipping the `finally` that restores these
    handlers, and reporting a cancellation for a run that silently gave up on
    the machine it was driving. A run that keeps hitting Ctrl-C because the
    teardown is still going is being told to wait; answering it by unwinding
    is what makes the wait look like a hang.

    Recording it costs the operator nothing: `finish_many` raises the recorded
    cancellation once every guest has been through the guard, which is the
    first moment at which raising it is safe.
    """
    if _TEARDOWN:
        _note_cancelled(signum)
        return
    raise Cancelled(signum)


def install_cancellation() -> dict[int, Any]:
    """Route SIGINT and SIGTERM to `Cancelled`, and return what was replaced.

    Installed before anything is started, so a run cancelled during the boot is
    unwound the same way a run cancelled during the suite is.
    """
    return {number: signal.signal(number, cancel_on)
            for number in (signal.SIGINT, signal.SIGTERM)}


def restore_cancellation(handlers: dict[int, Any]) -> None:
    """Put back the handlers `install_cancellation` replaced."""
    for number, handler in handlers.items():
        signal.signal(number, handler)


# --- the console's own signalling, taken away --------------------------------


def _claim(guest: Guest) -> None:
    """Take the console's own teardown away from it, and give it to the guard.

    Three doors, all on this one object, because one emulator is one object.

    * `ptyproc.closed` is set, so `PtyProcess.close` returns without touching
      the descriptor and `PtyProcess.__del__` — which calls it, and would
      otherwise answer a forgotten `close`, or a garbage collection, with SIGHUP,
      SIGCONT, SIGINT and then SIGKILL — does nothing at all. The descriptor
      pair is released by `finish`, once the exit has been proven. That flag is
      not by itself enough to keep the pair open: the master is a file object
      with a finaliser of its own, so a console this run then refuses is held
      by `_retain` for as long as this process lives, and no longer.
    * `kill()` becomes a refusal, because `terminate()` reaches `os.kill`
      through it and nothing in this directory asked for either.
    * `close()` and `terminate()` become the guarded stop, so a caller that
      still reaches for them gets the five facts read again rather than a
      signal sent on a pid nobody has proved.
    """
    console, child, label = guest.console, guest.child, guest.label
    console.ptyproc.closed = True

    def kill(signum: int) -> None:
        raise SignalRefused(
            f"the {label} console was asked to send {signal.Signals(int(signum)).name} to pid "
            f"{child.process.pid} directly, and this run sent nothing: an adopted console is "
            f"stopped through process_guard.Guard, which reads the command line, the owner, the "
            f"start time and the process group again immediately before each signal it does send")

    def terminate(force: bool = False) -> bool:
        return finish(guest).refused is None

    def close(force: bool = True) -> None:
        finish(guest)

    console.kill = kill
    console.terminate = terminate
    console.close = close


# --- the probe ----------------------------------------------------------------


def _probe(console: Any, pexpect: ModuleType) -> Callable[[], int | None]:
    """A closure answering whether the console's child has exited, and with what.

    `isalive()` is the only way this terminal library will say, and the status
    it records is the one the drivers' own `exitstatus` and `signalstatus`
    checks read afterwards, so this reaps rather than reimplementing the reap.
    Reaping is not signalling: `waitpid` reports an exit to the one process
    entitled to wait for it, which this run is, and sends the child nothing.
    What must not happen is the library's other answer — `terminate()`, and
    `close(force=True)` — which walks to `os.kill` on a pid nothing has proved.

    End of file makes `isalive()` wait in the kernel instead of polling,
    because the child has usually closed its side by then, and a guard's grace
    period has to survive that. So the flag is held down across the call and put
    back afterwards, which leaves the console protocol the next `expect` sees
    exactly as it was.

    The third answer is the one this exists to refuse to give. A console that
    says its child is gone and has recorded neither an exit status nor a signal
    has not exited with status 0 — it has stopped answering, which is a
    different fact, and inventing a success for it would let `finish` close the
    master of a pseudo terminal over a process whose exit nobody observed. So
    that raises `ProcessStateUnknown`, which the guard turns into a refusal,
    and the refusal is what leaves the console open.
    """
    def probe() -> int | None:
        code = _recorded_status(console)
        if code is not None:
            return code
        ended = console.flag_eof
        console.flag_eof = False
        failure: str | None = None
        try:
            alive = console.isalive()
        except (pexpect.ExceptionPexpect, OSError) as error:
            # The library raises rather than answering when there is no child
            # left to wait for. Whether it recorded a status on the way out is
            # still a separate question, and it is asked below rather than
            # settled here.
            alive = False
            failure = f"{type(error).__name__}: {error}"
        finally:
            console.flag_eof = ended
        if alive:
            return None
        code = _recorded_status(console)
        if code is not None:
            return code
        raise ProcessStateUnknown(
            f"pid {console.pid} is no longer answering the console"
            + (f", which reported {failure}" if failure is not None else "")
            + f", and recorded neither an exit status ({console.exitstatus!r}) nor a signal "
            f"({console.signalstatus!r}), so whether that pid is still running cannot be known "
            f"from here and this run will not report a status for it")

    return probe


def _recorded_argv(console: Any, label: str) -> tuple[str, ...]:
    """The command line the terminal library says it exec'd, as words.

    A terminal that keeps no such record is refused rather than accommodated:
    without it there is nothing to compare `/proc` against, and a guard that
    records a command line nothing can match has stopped checking.
    """
    recorded = getattr(getattr(console, "ptyproc", None), "argv", None)
    if not recorded:
        raise GuestProcessError(
            f"the {label} console records no command line for pid {console.pid}, so this run "
            f"cannot state what that pid is running, will not signal it and will not close it")
    return tuple(os.fsdecode(word) if isinstance(word, bytes) else str(word)
                 for word in recorded)


def _recorded_status(console: Any) -> int | None:
    """The status the terminal library has recorded, or None when it has none.

    The convention is `Popen`'s, because that is what the guard reads: an exit
    code as it is, and a fatal signal as its negative. Those are the two real
    answers and they are passed through untouched — a negative signal is a
    process that was killed, and rounding it to zero would be the same
    invention as never having looked.

    None is a third thing rather than a third answer: it means the library has
    recorded nothing, which is both what a running child looks like and what a
    console that stopped answering looks like. The caller tells those apart by
    asking whether the child is alive at all, and refuses when it cannot.
    """
    if console.exitstatus is not None:
        return int(console.exitstatus)
    if console.signalstatus is not None:
        return -int(console.signalstatus)
    return None


# --- the descriptor pair -----------------------------------------------------


# Consoles this run refused to stop, held for the life of the process.
#
# Setting `ptyproc.closed` is not enough on its own. It stops
# `PtyProcess.close` and `PtyProcess.__del__` from signalling, but the master
# descriptor is a Python file object in `ptyproc.fileobj`, and a file object's
# own finaliser closes the descriptor when it is collected — which hangs up
# every process still reading the slave, on a pid this run declined to signal,
# by a route nobody decided on. So the object graph is kept alive here instead
# of being left to the collector.
#
# The lifetime this buys is exactly the lifetime of the harness process, and
# it is no longer than that. When the harness exits, the kernel closes the
# descriptor whatever holds a reference to it, and the emulator still on the
# other end is hung up then. Nothing here survives that, and a refusal says so
# rather than implying the process outlives the run: stopping it by hand, or
# from whatever supervises the harness, is what ends it.
_RETAINED: list[Any] = []


def _close_console(console: Any) -> None:
    """Release a console's descriptors, once its child has been reaped.

    The precondition is the whole function. Closing the master of a pseudo
    terminal hangs up every process still reading the slave, so this runs only
    after the child's exit has been observed and only when nothing refused —
    and `_retain` is what happens in the other case, which is why a caller that
    reaches for it directly is skipping the decision rather than making one.
    """
    ptyproc = getattr(console, "ptyproc", None)
    if ptyproc is not None and ptyproc.fd != -1:
        try:
            ptyproc.fileobj.close()
        except OSError:  # pragma: no cover - already closed
            pass
        ptyproc.fd = -1
    console.child_fd = -1
    console.closed = True


def _retain(console: Any) -> None:
    """Keep a console this run refused to stop out of the collector's reach.

    Refusing to stop a process and then letting the collector hang it up are
    the same act by different routes, so a refusal that only set `closed` would
    leave the emulator running only until the last reference to its console
    went away — which is exactly when nobody is left to stop it by hand. The
    reference is held for the life of this process and no longer; see the note
    on `_RETAINED` for what happens when the harness itself exits.
    """
    if not any(held is console for held in _RETAINED):
        _RETAINED.append(console)


def _abandon(console: Any) -> None:
    """Leave an emulator this run may not signal exactly as it found it.

    The terminal library is told its child is closed so that its finaliser
    cannot answer a failed adoption with four signals and a kill — the one path
    out of this module that would do the thing it exists to prevent. That also
    means the descriptor pair stays open, because closing the master of a
    pseudo terminal hangs up the child on it, which is a signal too. Both are
    stated in the failure the caller raises: the pid, and that it is running.

    And it is retained, because a caller that abandons a console has just
    dropped its own reference to it: without one held here the descriptor pair
    would be collected and closed, hanging up the emulator this run could not
    prove anything about. The failure names the pid; this is what makes that
    name still be true a moment later.
    """
    ptyproc = getattr(console, "ptyproc", None)
    if ptyproc is not None:
        ptyproc.closed = True
    _retain(console)
