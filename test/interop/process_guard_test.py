"""`test/interop/process_guard.py`: it stops a child, or it refuses to.

Every case here is a way the teardown of a supervised run could go wrong by
signalling a process it does not own: a pid the kernel has handed to somebody
else while the run was waiting, a command line that is not the one the run
started, a process belonging to another account, a process group holding
another account's process, a group the supervisor itself is standing in, a
group one of the supervisor's ancestors is standing in — and, underneath all
of them, the run that starts a child on a system where none of this can be
checked and therefore cannot stop it.

The children are real, and they are all the same kind of child: a Python child
in a new session that blocks reading its standard input until the test closes
it. Nothing here waits on a clock to find out whether a child is still there.
A case that expects a refusal therefore ends by closing a pipe rather than by
timing out, and every assertion about a refusal is made while the child is
still blocked on that pipe — not after a grace period that a loaded machine
could turn into a different answer. Nothing is asserted about a mock, and no
case reads the guard's source to decide what it should say.

What each case asserts is an outcome and not a sentence: whether anything was
signalled, what status the child left with, whether the refusal is there at
all, and whether the processes involved were still alive when it came back.
Where a refusal could have been the wrong one — the wrong guard, on the wrong
target — the case proves which it was by restoring the real kernel read and
showing that the same guard then stops the same child. Three facts cannot be
provoked as this account, and each is provoked by injecting only the one
kernel read that cannot be arranged otherwise: an owner read that reports
another account for a real pid, a start time that changes between the two
signals, and a `/proc` that is not there.

The last class is about the children this guard did not start. A supervisor on
this host can have a terminal library fork the child instead — which is what a
guest console is, and a pseudo-terminal child leads a session of its own, so no
group this harness chose can reach it. Adoption is the only way to hold such a
child, and what is checked here is that it holds the same way `spawn` does: the
command line the kernel shows has to be the one the run says it started, the
identity is read and read again, the polite signal still comes first, and a
command line that does not match is a refusal that leaves the process running
rather than a signal sent on the strength of a guess.

Nothing is killed without the guard. The teardown of every child in this file
ends it by closing its standard input and waiting, and reaches for a signal
only where the guard is entitled to and the case wants it stopped. A console is
ended the same way rather than a different way: one line down the terminal,
then end of file, so a case that could not stop an emulator still ends it with
no signal at all.

The last class is about the children a terminal library forked, which is what
a guest emulator is, and about the three questions that raises which `spawn`
never has to ask. Was the command provable before that library forked — a name
like `qemu-system-x86_64` is on a `PATH`, not in a directory, and a probe that
opened the name as given would refuse every emulator a real run starts. What
does a console that has stopped answering report, given that the guard is about
to close its master descriptor over whatever is still on it. And what is still
running when a run gives up on one: a refused adoption leaves a live console
behind, and the collector closes that console's master unless something holds
it, which hangs up the emulator the guard refused to signal. The consoles are
real and the emulators are real processes throughout; the only thing injected
is the answer the terminal library gives, which is the one fact this module
cannot read for itself, and every case still ends by asking the kernel what
happened.

One class needs a directory on disk — a real shebang script, because the
refusal it exercises is about what the kernel does to a command line, and a
directory holding this interpreter under a name nothing else has, because the
cases about resolving a name need a name only that directory carries. Those
directories are created under `TMPDIR` only after `TMPDIR` has been checked to
be this account's own directory on an approved volume, and their mode is
checked to be 0700, so the fixture is never in a state the remover would
refuse. They are then removed by the repository's own ``tools/safe-rm-dir.sh``,
never by name: a test's own fixture is under the same house rules as anything
else, and there is no fallback, so a remover that is absent or that declines
fails the case and names the path it left behind rather than deleting it some
other way. Nothing else here writes anything at all.

Linux with a procfs is a prerequisite, stated here and checked by `setUp`:
every check in the guard and in these cases is a read of `/proc`, and a host
that has none cannot run them. A host that has a procfs and cannot use it is
a failure here, not a skip — the absence of `/proc/self/task/*/children`, for
instance, means the claim "nothing was forked" cannot be checked, and that is
reported rather than passed over.
"""

from __future__ import annotations

import gc
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any
from unittest import mock

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

# The guest console module under test lives with the drivers rather than with
# the guard, and the gate runs this file from the repository root, so the path
# to it is resolved from this file instead of being left to whatever the
# runner's working directory happens to be.
TOOLS = HERE.parent.parent / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import pexpect

import guest_process
import process_guard
import workdir
from process_guard import Child, Guard, ProcUnavailable
from workdir import WorkDirRefused


def approved_scratch_root() -> str:
    """Where a fixture may be created, checked by the rule the peers are held to.

    The rule itself is not restated here. It lives in `workdir` because the
    repository's remover enforces the same one, and a second copy of a rule
    that a remover depends on is a rule that can drift away from it. Only the
    failure is restated: a refusal here has to fail the case, and
    `WorkDirRefused` is not an assertion failure.
    """
    try:
        return str(workdir.approved_scratch_root())
    except WorkDirRefused as refusal:
        raise AssertionError(str(refusal)) from refusal


# What every child here waits for: end of file on its standard input. The test
# ends a child by closing that pipe, so a child's aliveness is something the
# test decides rather than something a sleep decides for it. The loop exits on
# an empty read, which is end of file, and the process ends with status 0.
BLOCKS_ON_STDIN = """
import sys
sys.stdout.write("ready\\n")
sys.stdout.flush()
while sys.stdin.readline() != "":
    pass
"""

# A child that ends the way a peer is supposed to end: the polite signal
# arrives, it leaves with status 0, and the run never has to kill anything.
# Status 0 rather than -15 is what proves the polite signal was delivered
# rather than that the process happened to be gone already.
LEAVES_ON_TERM = """
import signal, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
""" + BLOCKS_ON_STDIN

# A child that will not answer the polite signal at all. Stopping it takes the
# second signal, and it can only be stopped if the grace between them was
# really waited out.
IGNORES_TERM = """
import signal, sys
signal.signal(signal.SIGTERM, signal.SIG_IGN)
""" + BLOCKS_ON_STDIN

# A child with a second process in its group. Signalling the group signals
# both, so the guard has to look at every member rather than at the process it
# was handed, and a member belonging to another account is what makes the
# whole group off limits.
#
# The member is started before this child's pid line is written, because that
# line is how the test above can name it, and it reads the same pipe this
# child does, so closing that pipe ends both of them.
MEMBER_PROGRAM = """
import sys
while sys.stdin.readline() != "":
    pass
"""

GROUP_WITH_A_NAMED_MEMBER = f"""
import subprocess, sys
member = subprocess.Popen([sys.executable, "-c", {MEMBER_PROGRAM!r}])
sys.stdout.write("ready\\n")
sys.stdout.write(str(member.pid) + "\\n")
sys.stdout.flush()
while sys.stdin.readline() != "":
    pass
"""

# A child that moves itself into a named process group, which is only possible
# inside its own session. Used by the case that has to be posed in a process
# that shares this one's session.
JOINS_NAMED_GROUP = """
import os, sys
os.setpgid(0, int(sys.argv[1]))
sys.stdout.write("placed\\n")
sys.stdout.flush()
while sys.stdin.readline() != "":
    pass
"""

# The probe for the one case that cannot be posed in this process at all.
#
# A group this process's ancestors are in, which is not this process's own
# group, cannot be arranged here: every ancestor either shares this process's
# group or is in another session, and a process cannot join a group across
# sessions. It is arranged in a probe process instead, which leaves this
# process's session alone, makes itself the leader of a group of its own, and
# then starts the target into this process's group. From inside the probe the
# target's group is neither the probe's own group nor any group the probe
# chose, and it is exactly the group of one of the probe's ancestors.
#
# The probe reports what the kernel said as numbers, so the case can check
# which group the target was really in rather than what the refusal said about
# it. Nothing is signalled: the guard refuses, the target's input is closed,
# and the probe waits for it.
ANCESTOR_GROUP_PROBE = """
import json, os, subprocess, sys

sys.path.insert(0, sys.argv[1])
# Its own process group, inside the session it inherited, so that the target
# below is in a group that is neither this probe's own nor chosen by it.
os.setpgid(0, 0)

from process_guard import Guard

harness_pid = int(sys.argv[2])
harness_pgrp = int(sys.argv[3])
guard = Guard()
target = guard.spawn(
    [sys.executable, "-c", sys.argv[4], sys.argv[3]], "target",
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
target.process.stdout.readline()
target_pgrp = os.getpgid(target.process.pid)
own_pgrp = os.getpgid(0)
stop = guard.stop(target, grace=0.5)
still_running = target.process.poll() is None
target.process.stdin.close()
target.process.wait(timeout=30)
sys.stdout.write(json.dumps({
    "refused": stop.refused is not None,
    "signals": stop.signals,
    "exit": stop.exit,
    "target_pgrp": target_pgrp,
    "own_pgrp": own_pgrp,
    "harness_pgrp": os.getpgid(harness_pid),
    "declared_harness_pgrp": harness_pgrp,
    "still_running_after_refusal": still_running,
}))
"""


def child_pids() -> set[int]:
    """Every pid this process has forked, as the kernel reports it."""
    found: set[int] = set()
    for task in Path("/proc/self/task").iterdir():
        listing = task / "children"
        if not listing.exists():
            raise AssertionError(
                f"{listing} is missing: this kernel does not report a task's children, so the "
                f"claim that nothing was forked cannot be checked from here, and passing a case "
                f"that cannot check its own claim is worse than failing it"
            )
        for word in listing.read_text(encoding="utf-8").split():
            found.add(int(word))
    return found


def state_of(pid: int) -> str | None:
    """A live process's state letter, or None when it is not there at all."""
    fields = process_guard._stat_fields(pid)
    return None if fields is None else fields[0]


def is_running(pid: int) -> bool:
    """Whether a pid is a process rather than a reaped entry or an exited one."""
    return state_of(pid) not in (None, "Z")


class ScratchCase(unittest.TestCase):
    """A case whose fixtures live on an approved volume and are removed by the repository.

    Two classes here create files and both have to create them the same way:
    under the approved scratch root, mode 0700, removed through
    `tools/safe-rm-dir.sh` and never by name. One copy of that is a rule; two
    is a rule that can drift.
    """

    @staticmethod
    def drop_scratch(path: Path) -> None:
        """Remove one case's fixture through the same seam the peers use.

        There is no fallback here either, and for the same reason: a second way
        to delete this directory is exactly the unverified removal by name the
        helper exists to replace. So the helper being absent fails the case, a
        helper that runs and declines fails the case, and each message names
        the path that was left behind — a case that cannot clean up after
        itself needs a reader to hear that from the run rather than infer it
        from a directory that is still there afterwards.
        """
        try:
            workdir.remove_directory(path)
        except WorkDirRefused as refusal:
            raise AssertionError(str(refusal)) from refusal

    def scratch_dir(self) -> Path:
        """A private directory on an approved volume, removed through the repository's remover.

        The two things the remover checks before it removes anything are checked
        here as well, so a fixture that would be refused is never created in the
        first place: a place this account owns, and a directory no other
        account can enter. `mkdtemp` gives the second, and it is asserted rather
        than assumed, because the whole point of routing removal through the
        helper is that this directory is in a state the helper will accept.
        """
        path = Path(tempfile.mkdtemp(prefix="process-guard-", dir=approved_scratch_root()))
        self.addCleanup(self.drop_scratch, path)
        mode = path.stat().st_mode & 0o777
        self.assertEqual(mode, 0o700,
                         f"{path} was created with mode {mode:04o}; the repository's remover "
                         f"requires a directory no other account can enter")
        return path

    def interpreter_on_a_path_of_its_own(self) -> tuple[Path, str]:
        """A directory holding this interpreter under a name nothing else has.

        A symlink rather than a copy, so what the guard opens and probes is the
        very binary every other case in this file starts, and a name that
        cannot be found by accident: if it were `python3` or `sh`, a case
        about the search would pass for the wrong reason on a host whose
        default `PATH` happens to carry it.
        """
        scratch = self.scratch_dir()
        name = f"guard-probe-{os.getpid()}"
        (scratch / name).symlink_to(Path("/proc/self/exe").resolve())
        return scratch, name


class GuardCase(ScratchCase):
    """The guard, against children it really started."""

    def setUp(self) -> None:
        if not Path("/proc/self/stat").exists():
            self.skipTest(
                "this host has no procfs, and every check in this file and in the guard is a "
                "read of it; the guard requires a Linux procfs and says so itself when it "
                "cannot be built"
            )
        # Anything past that is a failure rather than a skip. A host that has a
        # procfs and cannot use it has something wrong that a reader of these
        # results needs to hear about.
        self.guard = Guard()
        self.children: list[Child] = []

    def tearDown(self) -> None:
        # Every child this test started ends the same way: its standard input
        # is closed, which is end of file, and it is waited for. A signal is
        # reached for only where the guard is entitled to and the case wanted
        # the child stopped — never to tidy up after a refusal, because a
        # teardown that answered a refusal with a signal is the thing these
        # cases exist to catch.
        for child in self.children:
            if child.process.stdin is not None:
                child.process.stdin.close()
            if child.process.poll() is None:
                self.guard.stop(child, grace=5.0)
            try:
                child.process.wait(timeout=30.0)
            except subprocess.TimeoutExpired:
                self.fail(f"the {child.label} child {child.process.pid} was still running after "
                          f"its standard input was closed and the guard had stopped it")
            if child.process.stdout is not None:
                child.process.stdout.close()

    def spawn_child(self, program: str, label: str, *, new_session: bool = True) -> Child:
        """A real child, waited for until its own code is running.

        The line the program writes is the barrier that matters: it is written
        after `exec`, so by the time it arrives the process in `/proc` is the
        one whose command line the guard will read, and not this process still
        on its way to becoming it. Standard input is a pipe this test holds,
        which is what makes every case here end by closing something rather
        than by waiting out a sleep.
        """
        argv = [sys.executable, "-c", program]
        child = self.guard.spawn(argv, label, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 start_new_session=new_session)
        self.children.append(child)
        assert child.process.stdout is not None
        self.assertEqual(child.process.stdout.readline(), b"ready\n",
                         f"the {label} child never reached its own code")
        return child

    def foreign_owner_of(self, pid: int) -> tuple[int, object]:
        """Report one real pid as belonging to some other account.

        An account this one cannot signal cannot be created from here without
        root, so the owner read — the one fact in the guard that describes the
        account rather than the process — is the only thing injected.
        Everything else about the process stays real.
        """
        real = process_guard._owner_uid
        other = os.getuid() + 1

        def owner(candidate: int) -> int | None:
            return other if candidate == pid else real(candidate)

        return other, mock.patch.object(process_guard, "_owner_uid", owner)

    def spawned_on_a_path(self, argv: Sequence[str], label: str, *, cwd: Path | None = None,
                          env: Mapping[str, str] | None = None) -> Child:
        """A real child whose command name is resolved the way a child's would be.

        Started with the environment and directory the case is about, so the
        name in `argv` is found on the child's `PATH` rather than this
        process's, and waited for to the same barrier every other child here
        reaches: the line it writes is written after `exec`, so the process the
        guard is about to read is the one that ran.
        """
        child = self.guard.spawn(argv, label, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True,
                                 cwd=None if cwd is None else str(cwd), env=env)
        self.children.append(child)
        assert child.process.stdout is not None
        self.assertEqual(child.process.stdout.readline(), b"ready\n",
                         f"the {label} child never reached its own code")
        return child

    # --- a child that ends properly --------------------------------------------

    def test_a_child_that_leaves_on_sigterm_is_reaped_and_never_killed(self):
        child = self.spawn_child(LEAVES_ON_TERM, "polite")
        stop = self.guard.stop(child, grace=10.0)

        self.assertEqual(stop.signals, ["SIGTERM"])
        self.assertIsNone(stop.refused)
        # Status 0 and not -15: this child handled the polite signal and left
        # the way it meant to, which is the whole reason the polite signal
        # goes first.
        self.assertEqual(stop.exit, 0)
        self.assertFalse(is_running(child.process.pid))

    def test_pipe_teardown_finishes_before_reporting_cancellation(self):
        handlers = guest_process.install_cancellation()
        failure = None
        try:
            child = self.spawn_child(SIGNALS_ITS_PARENT_ON_TERM, "pipe cancellation")
            guest = guest_process.Guest(child.label, None, child, self.guard)
            try:
                guest_process.finish(guest, grace=0.5)
            except BaseException as error:
                failure = error
        finally:
            guest_process.restore_cancellation(handlers)
        self.assertIsInstance(failure, guest_process.Cancelled)
        self.assertEqual(failure.signum, int(signal.SIGINT))
        self.assertEqual(child.process.returncode, -int(signal.SIGKILL))
        self.assertFalse(is_running(child.process.pid))

    def test_a_child_that_has_already_left_is_reaped_without_any_signal(self):
        child = self.spawn_child(BLOCKS_ON_STDIN, "already gone")
        child.process.stdin.close()
        self.assertEqual(child.process.wait(timeout=20.0), 0)

        stop = self.guard.stop(child, grace=10.0)

        self.assertEqual(stop.signals, [])
        self.assertEqual(stop.exit, 0)
        self.assertIsNone(stop.refused)

    # --- a child that does not end politely ------------------------------------

    def test_a_child_that_ignores_sigterm_is_killed_after_the_guards_are_read_again(self):
        child = self.spawn_child(IGNORES_TERM, "stubborn")
        real = process_guard._starttime_of
        readings: list[int] = []

        def counted(pid: int) -> int | None:
            value = real(pid)
            if pid == child.process.pid and value is not None:
                readings.append(value)
            return value

        with mock.patch.object(process_guard, "_starttime_of", counted):
            stop = self.guard.stop(child, grace=0.5)

        self.assertEqual(stop.signals, ["SIGTERM", "SIGKILL"])
        self.assertIsNone(stop.refused)
        self.assertEqual(stop.exit, -int(signal.SIGKILL))
        # Exactly one reading of this pid's identity per signal. Two signals
        # and one reading would be a kill decided from a proof taken before
        # the grace, which is the proof that has had the longest time to go
        # stale.
        self.assertEqual(len(readings), 2)

    def test_a_pid_that_changed_between_the_signals_is_not_killed(self):
        child = self.spawn_child(IGNORES_TERM, "recycled")
        real = process_guard._starttime_of
        readings: list[int | None] = []

        def changed(pid: int) -> int | None:
            value = real(pid)
            readings.append(value)
            # The first reading is the one taken before SIGTERM and is the
            # child's real start time. Every reading after it is what a pid the
            # kernel has given to another process would produce.
            if value is None or len(readings) == 1:
                return value
            return value + 1

        with mock.patch.object(process_guard, "_starttime_of", changed):
            stop = self.guard.stop(child, grace=0.3)

        # A second decision was taken — the count is two — and it refused, so
        # the kill never went out from a proof taken before the grace.
        self.assertGreaterEqual(len(readings), 2)
        self.assertEqual(stop.signals, ["SIGTERM"])
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        # Still blocked on its pipe: the guard refused and nothing else tried.
        self.assertIsNone(child.process.poll())

    # --- refusals ---------------------------------------------------------------

    def test_a_command_line_that_is_not_the_one_this_run_started_is_not_signalled(self):
        child = self.spawn_child(BLOCKS_ON_STDIN, "other argv")

        stop = self.guard.stop(child._replace(argv=("a-program-this-run-never-started",)),
                               grace=5.0)

        self.assertEqual(stop.signals, [])
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        self.assertIsNone(child.process.poll())
        # The refusal was about the command line and about nothing else: the
        # same guard, on the same live child, stops it as soon as the argv it
        # was given is the argv the kernel is showing.
        recovered = self.guard.stop(child, grace=5.0)
        self.assertIsNone(recovered.refused)
        self.assertEqual(recovered.signals, ["SIGTERM"])

    def test_a_process_this_account_does_not_own_is_not_signalled(self):
        child = self.spawn_child(BLOCKS_ON_STDIN, "not ours")
        _, patch = self.foreign_owner_of(child.process.pid)

        with patch:
            stop = self.guard.stop(child, grace=5.0)

        self.assertEqual(stop.signals, [])
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        self.assertIsNone(child.process.poll())
        recovered = self.guard.stop(child, grace=5.0)
        self.assertIsNone(recovered.refused)
        self.assertEqual(recovered.signals, ["SIGTERM"])

    def test_a_group_holding_a_process_this_account_does_not_own_is_not_signalled(self):
        child = self.spawn_child(GROUP_WITH_A_NAMED_MEMBER, "with a member")
        assert child.process.stdout is not None
        member = int(child.process.stdout.readline())
        self.assertTrue(is_running(member))
        self.assertEqual(process_guard._group_of(member),
                         process_guard._group_of(child.process.pid),
                         "the case needs a second process in the child's own group")
        _, patch = self.foreign_owner_of(member)

        with patch:
            stop = self.guard.stop(child, grace=5.0)

        self.assertEqual(stop.signals, [])
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        self.assertIsNone(child.process.poll())
        self.assertTrue(is_running(member),
                        "the refusal left a process this run could not prove it owned inside the "
                        "group it was about to signal")
        # With the real owner read back, the same guard signals the group and
        # both processes in it go, which is what makes the refusal about the
        # member and not about the group.
        recovered = self.guard.stop(child, grace=5.0)
        self.assertIsNone(recovered.refused)
        self.assertEqual(recovered.signals, ["SIGTERM"])
        self.assertFalse(is_running(member),
                         "the member was left in a group this run has now signalled")

    def test_a_child_sharing_this_harnesss_own_process_group_is_not_signalled(self):
        child = self.spawn_child(BLOCKS_ON_STDIN, "same group", new_session=False)
        # The fact the rule is about, read from the kernel rather than from
        # the refusal: this child really is in the group this process is in.
        self.assertEqual(process_guard._group_of(child.process.pid), os.getpgid(0))

        stop = self.guard.stop(child, grace=5.0)

        self.assertEqual(stop.signals, [])
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        self.assertIsNone(child.process.poll())

    def test_a_group_one_of_this_harnesss_ancestors_belongs_to_is_not_signalled(self):
        # In this process every ancestor either shares this process's group or
        # is in another session, so the case is posed in a probe that leaves
        # this process alone. The probe is a real child of this process and is
        # waited for, never signalled: it is in this process's group, so the
        # guard here would refuse to stop it, which is the rule under test.
        probe = subprocess.run(
            [sys.executable, "-c", ANCESTOR_GROUP_PROBE, str(HERE), str(os.getpid()),
             str(os.getpgid(0)), JOINS_NAMED_GROUP],
            capture_output=True, text=True, timeout=120, start_new_session=False)

        self.assertEqual(probe.returncode, 0,
                         f"the probe did not finish: {probe.stderr[-400:]}")
        facts = json.loads(probe.stdout)
        self.assertTrue(facts["refused"])
        self.assertEqual(facts["signals"], [])
        self.assertIsNone(facts["exit"])
        self.assertTrue(facts["still_running_after_refusal"])
        # The target was in a group one of the probe's ancestors was in, and
        # not in the probe's own group: those two numbers are what the rule is
        # about, and they come from the kernel rather than from the refusal.
        self.assertEqual(facts["target_pgrp"], facts["harness_pgrp"])
        self.assertEqual(facts["harness_pgrp"], facts["declared_harness_pgrp"])
        self.assertNotEqual(facts["target_pgrp"], facts["own_pgrp"])

    # --- starting what cannot be guarded ---------------------------------------

    def test_a_child_this_guard_cannot_name_is_never_started(self):
        scratch = self.scratch_dir()
        wrapper = scratch / "wrapper.py"
        with wrapper.open("w", encoding="utf-8") as handle:
            handle.write("#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n")
        wrapper.chmod(0o755)
        before = child_pids()

        with self.assertRaises(ProcUnavailable) as raised:
            self.guard.spawn([str(wrapper), "ARG"], "wrapped",
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True)

        # The refusal names the child it would have started, so a report
        # cannot leave a reader thinking this never happened.
        self.assertIn("wrapped", str(raised.exception))
        self.assertEqual(child_pids(), before,
                         "a child was forked although the guard could not name it later")
    def test_a_bare_command_name_is_started_and_its_executed_argv_is_recorded(self):
        # The whole point of resolving a name before probing it. `sleep` and
        # `qemu-system-x86_64` are names on a PATH, not files in whatever
        # directory this process is standing in, and a guard that opened the
        # name as given would refuse every emulator a real run starts.
        scratch, name = self.interpreter_on_a_path_of_its_own()

        child = self.spawned_on_a_path([name, "-c", BLOCKS_ON_STDIN], "named",
                                       env={"PATH": str(scratch)})

        self.assertEqual(process_guard._cmdline_of(child.process.pid), list(child.argv),
                         "what the kernel shows has to be the command line the record holds, or "
                         "the guard would be comparing against something no read will ever say")
        # The child really did run the interpreter the name resolved to, which
        # is the fact the probe decided on: `exe` is the kernel's own answer
        # and not a second reading of the name.
        self.assertEqual(os.path.realpath(os.readlink(f"/proc/{child.process.pid}/exe")),
                         os.path.realpath("/proc/self/exe"))

        stop = self.guard.stop(child, grace=10.0)

        self.assertIsNone(stop.refused)
        self.assertEqual(stop.signals, ["SIGTERM"])

    def test_a_relative_path_entry_is_resolved_against_the_childs_own_directory(self):
        # `PATH=.` is a search the kernel performs *after* the child's chdir,
        # so the entry means the directory the child runs in. Asked from here,
        # it means this process's directory, where there is nothing by that
        # name — so the same command is provable with a cwd and is not without
        # one, and both halves are checked because either alone proves less.
        scratch, name = self.interpreter_on_a_path_of_its_own()
        before = child_pids()

        child = self.spawned_on_a_path([name, "-c", BLOCKS_ON_STDIN], "relative",
                                       cwd=scratch, env={"PATH": "."})
        self.assertEqual(process_guard._cmdline_of(child.process.pid), list(child.argv))

        with self.assertRaises(ProcUnavailable):
            self.guard.spawn([name, "-c", BLOCKS_ON_STDIN], "no directory",
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True,
                             env={"PATH": "."})

        self.assertEqual(child_pids() - before, {child.process.pid},
                         "the refused lookup forked a child anyway")

    def test_a_name_that_is_on_no_path_the_child_would_be_given_is_never_started(self):
        # The child's `PATH` is this one's minus the directory the name lives
        # in, so the name is one this process can find and the child cannot.
        # A guard that searched its own environment would start it.
        scratch, name = self.interpreter_on_a_path_of_its_own()
        environment = dict(os.environ, PATH=str(scratch))
        self.assertIsNotNone(shutil.which(name, path=environment["PATH"]),
                             "the case needs the name to be findable the way this process looks")
        before = child_pids()

        with self.assertRaises(ProcUnavailable) as raised:
            self.guard.spawn([name, "-c", BLOCKS_ON_STDIN], "not on the child's path",
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True,
                             env={"PATH": "/usr/bin:/bin"})

        self.assertIn("not on the child's path", str(raised.exception))
        self.assertEqual(child_pids(), before,
                         "a child was forked for a command the kernel could not have exec'd")

    def test_a_child_with_no_path_of_its_own_is_probed_through_the_default_one(self):
        # `execvp` with an environment that carries no `PATH` searches
        # `os.defpath`, not nothing. A probe that treated a missing `PATH` as
        # an empty search would refuse every child started with a minimal
        # environment, which is what a sandbox or a service manager hands.
        found = os.path.isfile(os.path.join(os.defpath.split(os.pathsep)[0], "sh"))
        self.assertTrue(found, f"{os.defpath} carries no sh on this host, so the default path "
                              f"cannot be probed for anything this case could start")

        program = "printf 'ready\\n'; while IFS= read -r line; do :; done"
        child = self.spawned_on_a_path(["sh", "-c", program], "no PATH", env={})

        self.assertEqual(process_guard._cmdline_of(child.process.pid), list(child.argv))
        self.assertEqual(self.guard.stop(child, grace=10.0).signals, ["SIGTERM"])

    def test_a_name_the_child_cannot_execute_is_refused_before_the_fork(self):
        # Three things a directory on a `PATH` can hold that `execv` will not
        # run: nothing at all, a dangling link, and a directory. All three are
        # refused here rather than left to `Popen`, because the point of the
        # preflight is that a refusal leaves nothing running.
        scratch = self.scratch_dir()
        (scratch / "a-directory").mkdir()
        (scratch / "a-dangling-link").symlink_to(scratch / "nothing-is-here")
        environment = {"PATH": str(scratch)}
        before = child_pids()

        for name in ("a-directory", "a-dangling-link", "no-such-file-here"):
            with self.subTest(name=name):
                with self.assertRaises(ProcUnavailable):
                    self.guard.spawn([name, "-c", BLOCKS_ON_STDIN], f"unrunnable {name}",
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, start_new_session=True,
                                     env=environment)

        self.assertEqual(child_pids(), before,
                         "a child was forked for a command the kernel could not have exec'd")

    def test_an_identity_that_cannot_be_read_leaves_a_child_unsignalled_and_named(self):
        real = process_guard._starttime_of

        def unreadable_for_children(pid: int) -> int | None:
            # The reading this guard makes about itself still answers; the one
            # about a child does not, which is the state the child is in
            # between the fork and its first read.
            return real(pid) if pid == os.getpid() else None

        before = child_pids()
        with mock.patch.object(process_guard, "_starttime_of", unreadable_for_children):
            with self.assertRaises(ProcUnavailable) as raised:
                self.guard.spawn([sys.executable, "-c", BLOCKS_ON_STDIN], "unreadable",
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, start_new_session=True)

        # The child was started, is named, and was not signalled: it ended on
        # its own when its input was closed, which is why nothing is left.
        self.assertIn("unreadable", str(raised.exception))
        self.assertEqual(child_pids(), before,
                         "a child was left running after the guard could not read its identity")

    def test_a_group_holding_a_process_this_run_cannot_read_is_not_signalled(self):
        child = self.spawn_child(GROUP_WITH_A_NAMED_MEMBER, "with an unreadable member")
        assert child.process.stdout is not None
        member = int(child.process.stdout.readline())
        real = process_guard._stat_of

        def unreadable(candidate: int):
            # The member is still there and its entry is still in /proc; only
            # the read fails. Treating that as "not a member" would be the
            # group check reporting a complete answer about a pid it could
            # not look at.
            return None if candidate == member else real(candidate)

        with mock.patch.object(process_guard, "_stat_of", unreadable):
            stop = self.guard.stop(child, grace=5.0)

        self.assertEqual(stop.signals, [])
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        self.assertIsNone(child.process.poll())
        self.assertTrue(is_running(member),
                        "the refusal left a process this run could not read inside the group it "
                        "was about to signal")

    def test_a_proc_filesystem_that_hides_other_accounts_is_refused_before_anything_starts(self):
        # The group check concludes a group is safe by walking /proc looking
        # for anything foreign. A procfs mounted with hidepid takes other
        # accounts' processes out of that listing, so the same walk would
        # report a complete answer from a partial view. It has to be refused
        # from the mount table rather than inferred from what happens to be
        # visible, and refused before a child exists.
        scratch = self.scratch_dir()
        table = scratch / "self" / "mountinfo"
        table.parent.mkdir(parents=True)
        mounted = ("29 23 0:26 / /proc rw,nosuid shared:9 - proc proc "
                   "rw{extra}\n")

        table.write_text(mounted.format(extra=""), encoding="utf-8")
        with mock.patch.object(process_guard, "_PROC", scratch):
            self.assertIsNone(process_guard._hidden_pids(),
                              "a procfs with no hidepid option is the ordinary case and must pass")
            table.write_text(mounted.format(extra=",hidepid=2"), encoding="utf-8")
            self.assertIsNotNone(process_guard._hidden_pids())
            with self.assertRaises(ProcUnavailable):
                Guard()

    def test_a_run_where_the_guards_cannot_be_read_starts_nothing(self):
        argv = [sys.executable, "-c", BLOCKS_ON_STDIN]
        before = child_pids()

        with mock.patch.object(process_guard, "_PROC", Path("/nonexistent-procfs")):
            with self.assertRaises(ProcUnavailable):
                Guard()
            # A guard built when /proc was there refuses to fork now that it
            # is not, rather than starting a child this run would not be
            # allowed to stop.
            with self.assertRaises(ProcUnavailable):
                self.guard.spawn(argv, "never started", stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 start_new_session=True)

        self.assertEqual(child_pids(), before,
                         "something was forked while the guards could not be read")



def probe_for(process: subprocess.Popen[bytes]) -> Callable[[], int | None]:
    """The one thing a foreign starter is asked for: whether its child has left.

    `Popen.poll` is the same answer a terminal library gives, reaped the same
    way, and like it it signals nothing: `waitpid` reports an exit to the one
    process entitled to wait for it. What it cannot do is decide whether the pid
    is still this run's child, and it is not asked to — that decision is the
    guard's, and it is made again before every signal.
 """
    def probe() -> int | None:
        return process.poll()

    return probe


class AdoptedChildCase(unittest.TestCase):
    """The guard, against a child something other than `spawn` started."""

    def setUp(self) -> None:
        if not Path("/proc/self/stat").exists():
            self.skipTest(
                "this host has no procfs, and every check in this file and in the guard is a "
                "read of it; the guard requires a Linux procfs and says so itself when it "
                "cannot be built"
            )
        self.guard = Guard()
        self.foreign: list[subprocess.Popen[bytes]] = []
        self.adopted: list[Child] = []

    def tearDown(self) -> None:
        # The same rule the class above is held to. A child this test started by
        # itself is ended by closing the pipe it blocks on; an adopted one is
        # ended by the guard, and by nothing else, because a teardown that
        # answered a refusal with a signal is the thing these cases exist to
        # catch.
        for child in self.adopted:
            if child.process.poll() is None:
                self.guard.stop(child, grace=5.0)
        for process in self.foreign:
            if process.poll() is None:
                self.guard.stop(self.guard.adopt(
                    "tidy", list(process.args), process.pid, probe_for(process)),
                    grace=5.0)
            process.stdin.close()
            try:
                process.wait(timeout=30.0)
            except subprocess.TimeoutExpired:
                self.fail(f"the child {process.pid} was still running after its standard input "
                          f"was closed and the guard had stopped it")
            if process.stdout is not None:
                process.stdout.close()

    def start_outside(self, program: str, label: str) -> subprocess.Popen[bytes]:
        """A real child this guard's `spawn` never saw, waited for into its own code.

        Started the way a terminal library starts one — its own session, and
        its own process group, which is what makes it a child no group this
        harness chose could signal — and the line it writes is the same barrier
        the class above uses: it is written after `exec`, so by the time it
        arrives the process in `/proc` is the one the guard will read.
        """
        process = subprocess.Popen([sys.executable, "-c", program],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        self.foreign.append(process)
        assert process.stdout is not None
        self.assertEqual(process.stdout.readline(), b"ready\n",
                         f"the {label} child never reached its own code")
        return process

    def adopt(self, process: subprocess.Popen[bytes], label: str,
              argv: list[str] | None = None,
              ready: float = process_guard.ADOPT_TIMEOUT) -> Child:
        """Bind a foreign child to the guard, on the command line it really has."""
        words = argv if argv is not None else list(process.args)
        child = self.guard.adopt(label, words, process.pid, probe_for(process), ready)
        self.adopted.append(child)
        return child

    def test_an_adopted_child_is_bound_to_the_command_line_the_kernel_shows(self):
        process = self.start_outside(BLOCKS_ON_STDIN, "adopted")

        child = self.adopt(process, "adopted")

        self.assertEqual(list(child.argv), list(process.args),
                         "the record must hold the command line the later read compares against")
        self.assertEqual(child.starttime, process_guard._starttime_of(process.pid),
                         "the identity has to be the moment this process started, or a pid this "
                         "run never started could wear it")

    def test_an_adopted_child_that_leaves_on_sigterm_is_reaped_and_never_killed(self):
        process = self.start_outside(LEAVES_ON_TERM, "polite")

        stop = self.guard.stop(self.adopt(process, "polite"), grace=10.0)

        self.assertEqual(stop.signals, ["SIGTERM"])
        self.assertIsNone(stop.refused)
        self.assertEqual(stop.exit, 0,
                         "status 0 and not -15: this child handled the polite signal, which is "
                         "what the polite signal going first is for")
        self.assertFalse(is_running(process.pid))

    def test_an_adopted_child_that_ignores_sigterm_is_killed_only_after_the_grace(self):
        process = self.start_outside(IGNORES_TERM, "stubborn")

        stop = self.guard.stop(self.adopt(process, "stubborn"), grace=0.5)

        self.assertEqual(stop.signals, ["SIGTERM", "SIGKILL"])
        self.assertIsNone(stop.refused)
        self.assertFalse(is_running(process.pid))

    def test_a_command_line_that_is_not_the_one_the_run_started_is_refused(self):
        process = self.start_outside(BLOCKS_ON_STDIN, "misnamed")
        running = is_running(process.pid)

        with self.assertRaises(ProcUnavailable) as raised:
            self.adopt(process, "misnamed", argv=[sys.executable, "-c", "raise SystemExit(1)"],
                       ready=0.5)

        message = str(raised.exception)
        self.assertIn(str(process.pid), message,
                      "a refusal has to name the pid it declined to signal")
        self.assertIn("NOT adopted", message,
                      "a refusal that does not say what was not done reads as a failure that did")
        self.assertEqual(is_running(process.pid), running,
                         "a pid this run may not stop must be left exactly as it was found")

    def test_a_child_that_left_before_it_could_be_adopted_is_named_as_started(self):
        process = self.start_outside(BLOCKS_ON_STDIN, "gone")
        process.stdin.close()
        self.assertEqual(process.wait(timeout=30.0), 0)

        with self.assertRaises(ProcUnavailable) as raised:
            self.guard.adopt("gone", list(process.args), process.pid, probe_for(process))

        message = str(raised.exception)
        self.assertIn("WAS started", message,
                      "a run that reports a child as never started when it was, is lying about "
                      "the one thing a reader of the failure needs to know")
        self.assertIn(str(process.pid), message)

    def test_an_adopted_child_whose_command_line_cannot_be_read_is_refused(self):
        process = self.start_outside(BLOCKS_ON_STDIN, "unreadable")
        real = process_guard._cmdline_of

        def unreadable(pid: int) -> list[str] | None:
            return None if pid == process.pid else real(pid)

        with mock.patch.object(process_guard, "_cmdline_of", unreadable):
            with self.assertRaises(ProcUnavailable):
                self.adopt(process, "unreadable", ready=0.5)



# A guest that will not answer the polite signal at all, and still leaves when
# it is told to, so a case can pose a teardown that has to reach the second
# signal and then end the console by hand like any other.
IGNORES_TERM_THEN_LEAVES = """
import signal, sys
signal.signal(signal.SIGTERM, signal.SIG_IGN)
sys.stdout.write("ready\\n")
sys.stdout.flush()
sys.stdin.readline()
sys.exit(0)
"""


# A guest console ends by being told to, rather than by its input closing,
# because these cases have to leave one running to ask about it. It leaves on
# one line and on end of file, which is what makes a case that could not stop
# it able to end it by hand through the same console protocol and without a
# signal: the rule this file is held to is that nothing is killed without the
# guard, and a teardown that reached for `os.kill` would break it.
EXIT_ON_INPUT = """
import sys
sys.stdout.write("ready\\n")
sys.stdout.flush()
sys.stdin.readline()
sys.exit(0)
"""

LEAVES_ON_TERM_THEN_INPUT = """
import signal, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
""" + EXIT_ON_INPUT


# A guest that cancels its parent's run from inside the guard's first signal.
# The polite signal arrives, and before the guard has decided whether to send
# the second one, the child signals the harness that is stopping it. That is
# the exact moment a cancellation must not be able to interrupt, and it is
# arranged by a real child sending a real signal to a real parent rather than
# by a clock or a mock. It stays alive afterwards — handling the polite signal
# is all it does with it — so the guard has to reach its second one, and it
# leaves when the console is told, so a case that could not stop it can still
# end it without reaching for a signal.
SIGNALS_ITS_PARENT_ON_TERM = """
import os, signal, sys
def cancel(*_):
    os.kill(os.getppid(), signal.SIGINT)
signal.signal(signal.SIGTERM, cancel)
sys.stdout.write("ready\\n")
sys.stdout.flush()
sys.stdin.readline()
sys.exit(0)
"""


class GuestConsoleCase(ScratchCase):
    """The guard, against a console a terminal library forked and exec'd.

    These are the children the drivers actually start. `pexpect.spawn` forks,
    puts the child in a session of its own, and execs it, so the guard never
    sees the fork and has to adopt the pid afterwards — which makes three
    things that `Guard.spawn` gets for free into questions this class asks
    about real consoles instead: whether the command was provable before that
    library forked, what happens when the console will not say how its child
    left, and what is still running when a run gives up on it.

    Every console here is a real one and every emulator is a real process. The
    only thing ever injected is the answer the terminal library gives, which
    is the one fact this module cannot read for itself, and each of those cases
    still asserts on what the kernel says about the process afterwards.
    """

    def setUp(self) -> None:
        if not Path("/proc/self/stat").exists():
            self.skipTest(
                "this host has no procfs, and every check in this file and in the guard is a "
                "read of it; the guard requires a Linux procfs and says so itself when it "
                "cannot be built"
            )
        self.guard = Guard()
        # (console, guest, pid) for every console opened here, in the order
        # opened. A console this case has deliberately dropped every reference
        # to is recorded as (None, None, pid), because holding it here would
        # be the very thing the case is checking that the module does instead.
        self.held: list[tuple[Any, Any, int]] = []
        self.handlers = guest_process.install_cancellation()
        self.addCleanup(guest_process.restore_cancellation, self.handlers)

    def tearDown(self) -> None:
        # Every console first, and only then the verdict, so a case that leaves
        # one running ends it anyway: a teardown that gave up half way would
        # leak an emulator into the next case on this host.
        trouble: list[str] = []
        for console, guest, pid in self.held:
            if console is None:
                try:
                    console = self.retained_console(pid)
                except AssertionError as error:
                    trouble.append(str(error))
                    continue
            if guest is not None:
                try:
                    guest_process.finish(guest, grace=5.0)
                except (guest_process.Cancelled, guest_process.GuestProcessError) as error:
                    trouble.append(f"the {guest.label} console was still running when the case "
                                   f"finished: {error}")
            try:
                self.end_console(console)
            except (pexpect.ExceptionPexpect, OSError) as error:
                trouble.append(f"the console for pid {pid} would not close: {error}")
        if trouble:
            self.fail("; ".join(trouble))

    def end_console(self, console: Any) -> None:
        """End a console this case opened, by its own protocol and with no signal.

        A console the guard claimed has its `close` and `terminate` taken away,
        and a console it refused has the library's told to stop signalling
        either, so neither can be closed from here — which is the point. What is
        left is the terminal protocol itself: one line, then end of file, then
        the reaping that records how the child left, and only then the
        descriptors this module closes because the child has gone.
        """
        if console.closed or console.child_fd == -1:
            return
        console.sendline("leave")
        console.expect(pexpect.EOF, timeout=60)
        # `isalive` is the library's reap, and it records the status without
        # signalling anything. `wait` is avoided on purpose: it ends by closing,
        # and closing is what these consoles are not allowed to do for us.
        self.assertFalse(console.isalive(),
                         f"the console for pid {console.pid} still has a live child after its "
                         f"input was closed")
        guest_process._close_console(console)

    def open_console(self, program: str, *, keep: bool = True) -> Any:
        """A real console on a real child, held open until the case ends it.

        `keep=False` records the pid alone, for the one case that goes on to
        drop the console itself and has to find it again afterwards.
        """
        console = pexpect.spawn(sys.executable, ["-c", program], timeout=60, encoding=None)
        self.held.append((console, None, console.pid) if keep else (None, None, console.pid))
        console.expect([b"ready"], timeout=60)
        return console

    def spawn_guest(self, program: str, label: str,
                    argv: Sequence[str] | None = None) -> Any:
        """A real console opened and adopted the way a driver opens one."""
        words = list(argv) if argv is not None else [sys.executable, "-c", program]
        guest = guest_process.spawn(self.guard, words, label, timeout=60)
        self.held.append((guest.console, guest, guest.console.pid))
        guest.console.expect([b"ready"], timeout=60)
        return guest

    def retained_console(self, pid: int) -> Any:
        """The console this module is holding for a pid it refused to stop.

        Read back out of the registry rather than kept here, because the case
        that needs it has just dropped every reference of its own — which is the
        whole of what it is testing.
        """
        for console in guest_process._RETAINED:
            if console.pid == pid and not console.closed:
                return console
        self.fail(f"no console is being held for pid {pid}; one that this run refused to stop "
                  f"must be kept reachable or its master is closed and the emulator hung up")
        raise AssertionError  # pragma: no cover - `fail` does not return

    # --- a console that is adopted and stopped normally ------------------------

    def test_an_adopted_console_is_stopped_and_its_descriptors_released(self):
        guest = self.spawn_guest(LEAVES_ON_TERM_THEN_INPUT, "guest")
        pid = guest.console.pid

        stop = guest_process.finish(guest, grace=10.0)

        self.assertIsNone(stop.refused)
        self.assertEqual(stop.signals, ["SIGTERM"])
        self.assertEqual(stop.exit, 0)
        self.assertFalse(is_running(pid))
        self.assertTrue(guest.console.closed)
        self.assertEqual(guest.console.child_fd, -1,
                         "the master descriptor has to be released only once the child has left")

    def test_an_emulator_that_only_a_kill_will_stop_reports_the_signal_it_died_on(self):
        guest = self.spawn_guest(IGNORES_TERM_THEN_LEAVES, "stubborn guest")
        pid = guest.console.pid

        stop = guest_process.finish(guest, grace=0.5)

        self.assertEqual(stop.signals, ["SIGTERM", "SIGKILL"])
        self.assertIsNone(stop.refused)
        # The status the terminal library recorded, in `Popen`'s convention.
        # A zero here would be the guard inventing a clean exit for a process
        # it watched being killed.
        self.assertEqual(stop.exit, -int(signal.SIGKILL))
        self.assertFalse(is_running(pid))

    def test_a_bare_emulator_name_on_a_path_of_its_own_is_adopted_and_stopped(self):
        # The driver's own case: `port.emulator` is `qemu-system-x86_64`, a
        # name, and every BSD port that does not spell out a path would be
        # unable to start its guest if a bare name could not be proved.
        scratch, name = self.interpreter_on_a_path_of_its_own()
        with mock.patch.dict(os.environ, {"PATH": str(scratch)}, clear=True):
            guest = self.spawn_guest(LEAVES_ON_TERM_THEN_INPUT, "named emulator",
                                     argv=[name, "-c", LEAVES_ON_TERM_THEN_INPUT])
            pid = guest.console.pid
            # The name really was resolved: this is the kernel's own answer
            # about what the emulator process is, not a second reading of the
            # name the same way the guard made the first.
            ran = os.path.realpath(os.readlink(f"/proc/{pid}/exe"))

            stop = guest_process.finish(guest, grace=10.0)

        self.assertIsNone(stop.refused)
        self.assertEqual(stop.exit, 0)
        self.assertFalse(is_running(pid))
        self.assertEqual(ran, os.path.realpath("/proc/self/exe"))

    def test_an_emulator_this_run_cannot_prove_is_never_started(self):
        scratch = self.scratch_dir()
        wrapper = scratch / "emulator.sh"
        wrapper.write_text("#!/bin/sh\nexec sleep 30\n", encoding="utf-8")
        wrapper.chmod(0o755)
        before = child_pids()

        with self.assertRaises(ProcUnavailable):
            guest_process.spawn(self.guard, [str(wrapper)], "wrapped emulator", timeout=60)

        self.assertEqual(child_pids(), before,
                         "a terminal library forked a child the guard had already refused")

    # --- a console that will not answer ----------------------------------------

    def test_a_console_that_stops_answering_never_reports_a_clean_exit(self):
        guest = self.spawn_guest(EXIT_ON_INPUT, "unanswerable")
        pid = guest.console.pid

        def stopped_answering() -> bool:
            raise OSError(5, "I/O error")

        with mock.patch.object(guest.console, "isalive", stopped_answering):
            stop = guest_process.finish(guest, grace=5.0)

        # Not zero, and not None: a refusal, because the console said its child
        # was gone and recorded nothing about how.
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        self.assertFalse(guest.console.closed,
                         "closing the master of a pseudo terminal hangs up whatever is still on "
                         "it, so an exit nobody observed must leave the console alone")
        self.assertTrue(is_running(pid), "the emulator this run refused to account for is gone")

    def test_a_refused_stop_leaves_the_console_open_and_the_emulator_running(self):
        guest = self.spawn_guest(EXIT_ON_INPUT, "refused")
        pid = guest.console.pid
        real = process_guard._cmdline_of

        def unreadable(candidate: int) -> list[str] | None:
            return None if candidate == pid else real(candidate)

        with mock.patch.object(process_guard, "_cmdline_of", unreadable):
            stop = guest_process.finish(guest, grace=5.0)

        self.assertEqual(stop.signals, [])
        self.assertIsNone(stop.exit)
        self.assertIsNotNone(stop.refused)
        self.assertTrue(is_running(pid))
        self.assertFalse(guest.console.closed)

    def test_a_refusal_after_a_signal_says_so_rather_than_claiming_nothing_was_sent(self):
        guest = self.spawn_guest(IGNORES_TERM_THEN_LEAVES, "refused late")
        pid = guest.console.pid
        real = process_guard._cmdline_of

        readings: list[int] = []

        def unreadable_after_the_first(candidate: int) -> list[str] | None:
            # The first reading, which authorises SIGTERM, succeeds; every one
            # after it fails, so the guard decides twice and is refused the
            # second time with a signal already out.
            if candidate != pid:
                return real(candidate)
            readings.append(candidate)
            return None if len(readings) > 1 else real(candidate)

        with mock.patch.object(process_guard, "_cmdline_of", unreadable_after_the_first):
            stop = guest_process.finish(guest, grace=0.5)

        self.assertEqual(stop.signals, ["SIGTERM"])
        self.assertIsNotNone(stop.refused)
        with self.assertRaises(guest_process.GuestProcessError):
            guest_process.require_stopped(stop, "refused late")
        self.assertTrue(is_running(pid))

    def test_a_refused_adoption_keeps_the_console_so_the_emulator_is_not_hung_up(self):
        # The caller of a refused adoption is about to drop its last reference
        # to the console, and dropping it closes the master of the pseudo
        # terminal — which hangs up the very emulator the guard refused to
        # signal, by a route nobody decided on. Measured rather than asserted
        # from the source: the child is still running after a collection that
        # no reference in this case survives.
        console = self.open_console(EXIT_ON_INPUT, keep=False)
        pid = console.pid

        with mock.patch.object(guest_process, "_recorded_argv",
                               lambda _console, _label: ("a-program-this-run-never-started",)):
            with self.assertRaises(ProcUnavailable) as raised:
                guest_process.adopt(self.guard, console, "misnamed")

        self.assertIn(str(pid), str(raised.exception),
                      "a refusal has to name the pid it left running")
        del console
        gc.collect()
        gc.collect()
        self.assertTrue(is_running(pid),
                        "the emulator was hung up by the collector after a refused adoption, which "
                        "is the signal this run declined to send")

    # --- a cancellation arriving mid-teardown ----------------------------------

    def test_a_cancellation_cannot_abandon_the_guests_behind_the_one_it_arrived_in(self):
        # The first emulator cancels this run from inside the guard's first
        # signal, while the guard is deciding whether to send the second one,
        # and the second emulator is still running. A teardown that acted on
        # the cancellation there would leave the second machine going and report
        # a clean exit for a run that abandoned it.
        first = self.spawn_guest(SIGNALS_ITS_PARENT_ON_TERM, "cancels its parent")
        second = self.spawn_guest(EXIT_ON_INPUT, "behind it")
        pids = [first.console.pid, second.console.pid]

        with self.assertRaises(guest_process.Cancelled) as raised:
            guest_process.finish_many([first, second], grace=5.0)

        self.assertEqual(raised.exception.signum, int(signal.SIGINT))
        # Both machines are gone and both consoles closed: the cancellation was
        # raised only once the teardown had nothing left to do.
        self.assertFalse(is_running(pids[0]))
        self.assertFalse(is_running(pids[1]))
        self.assertTrue(first.console.closed)
        self.assertTrue(second.console.closed)

    def test_repeated_cancellation_still_leaves_every_registered_guest_stopped(self):
        # The same, three times over, because the point is that it holds however
        # many times the operator presses Ctrl-C while the teardown runs. The
        # third emulator refuses, so the run has both a cancellation and a
        # refusal pending: the refusal is the one that has to be reported.
        first = self.spawn_guest(SIGNALS_ITS_PARENT_ON_TERM, "cancelling")
        second = self.spawn_guest(SIGNALS_ITS_PARENT_ON_TERM, "cancelling again")
        third = self.spawn_guest(EXIT_ON_INPUT, "refused")
        refused_pid = third.console.pid
        real = process_guard._cmdline_of

        def refuse_this_one(candidate: int) -> list[str] | None:
            return None if candidate == refused_pid else real(candidate)

        with mock.patch.object(process_guard, "_cmdline_of", refuse_this_one):
            stops = guest_process.finish_many([first, second, third], grace=5.0)

        # The refusal is primary: the pending cancellation is not raised over
        # it, and the stops come back in the order the guests went in, one for
        # each, so a caller indexing the refused one indexes what it passed.
        self.assertEqual([stop.child for stop in stops],
                         ["cancelling", "cancelling again", "refused"])
        self.assertIsNone(stops[0].refused)
        self.assertIsNone(stops[1].refused)
        self.assertIsNotNone(stops[2].refused)
        self.assertFalse(is_running(first.console.pid),
                         "a cancellation arriving during the teardown stopped the first guest "
                         "but abandoned the second")
        self.assertFalse(is_running(second.console.pid))
        self.assertTrue(is_running(refused_pid))
        self.assertFalse(third.console.closed,
                         "a refused console must not be closed over a process that may be running")



if __name__ == "__main__":
    unittest.main()