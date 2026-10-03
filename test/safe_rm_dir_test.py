"""`tools/safe-rm-dir.sh`: it removes a path, or it refuses and says why.

Every case here is a way the removal could go wrong on a shared mount — a
tree that is not this account's, a path that resolves off an approved volume,
a mount point, a link or a device inside the tree, a process holding it open
or standing in it, a symlink offered where a directory was promised — and the
assertion in every one of them is the same: exit 1, the reason named, and the
path left exactly as it was.

The checks that cannot be provoked from a test as this account (another
account's uid, a real mount point, a path on a volume that is not approved, a
process whose /proc entries the kernel will not open) are provoked by fault
injection instead: the helper resolves `id` and `realpath` from PATH, so a
case puts a one-line stand-in in front of them and proves the branch fires and
refuses. The mount table is read with `awk`, and the path a mount point is
named at is the only way a mount point can be posed here, so `awk` is stood in
for the same reason. The tools inside the liveness walk are stood in for the
same reason, where a case needs one of them to answer "I could not read that"
without needing the kernel to make it true.

Nothing here needs root, and nothing outside the case's own temporary
directory is ever touched, signalled or removed. Every process this file
starts is stopped through `test/interop/process_guard.py`: the owner, the
command line, the start time and the process group are read again before each
signal, and a refusal is reported instead of one being sent.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "tools" / "safe-rm-dir.sh"

# The guard the interoperability supervisors use, shared rather than
# reimplemented: a test's own fixture process is stopped the way a supervised
# child is, and a second copy of that decision is a second copy that drifts.
GUARD_MODULE = REPO / "test" / "interop"
if str(GUARD_MODULE) not in sys.path:
    sys.path.insert(0, str(GUARD_MODULE))

from process_guard import Child, Guard, ProcessGuardError


# The binary a holder is, rather than a shell that runs one. `bash -c "cd D &&
# exec sleep 60"` becomes `sleep 60` in `/proc/<pid>/cmdline` — the exec
# replaces the command line the guard recorded with one nothing can match, so a
# guard asked to stop it would refuse a process the case had just started and
# proved. The holder is the process itself, started with the working directory
# or the descriptor it stands in for.
HOLDER = shutil.which("sleep") or "/bin/sleep"


# The volumes `safe-rm-dir.sh` accepts, and the per-account directory on each.
# A case whose TMPDIR is none of these cannot exercise the accepting path, and
# says so rather than quietly passing.
APPROVED = ("/home/tmp2", "/home/tmp", "/vol/tmp2", "/vol/tmp")


def account_name() -> str:
    """The account name the helper resolves, from the same source it does."""
    return subprocess.run(
        ["id", "-un"], capture_output=True, text=True, check=True
    ).stdout.strip()


def approved_root(path: Path) -> str | None:
    resolved = Path(os.path.realpath(path))
    for mount in APPROVED:
        root = Path(mount) / account_name()
        if resolved == root or root in resolved.parents:
            return str(root)
    return None


def wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


class SafeRmDirCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="safe-rm-dir-"))
        # Registered before anything else this case builds, and ahead of the
        # holders so that cleanups run in the order: every holder stops, then
        # the directory goes to the remover. A holder still standing in the
        # tree is a live reference, and the remover would refuse for a reason
        # that belongs to this case rather than to the code under test.
        self.addCleanup(self.drop_scratch)
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        self.holder: Child | None = None
        self.addCleanup(self._stop_holder)
        # Built before anything is started, and built to be the real thing:
        # a guard that cannot read its own proofs cannot prove a fixture is
        # this run's, and a case that swapped in a weaker one to get past that
        # would be asserting against a stand-in.
        try:
            self.guard = Guard()
        except ProcessGuardError as exc:
            raise AssertionError(
                f"the guard for this run's own fixtures could not be built, and this file does "
                f"not fall back to signalling a pid without one: {exc}"
            ) from exc

    def drop_scratch(self) -> None:
        """Remove this case's world with the repository's own remover.

        House rules apply to a test's own fixtures too: nothing here is
        deleted by name either. `safe-rm-dir.sh` checks ownership, volume,
        containment and live references before it removes anything, and a
        refusal leaves the directory and says where it is.
        """
        result = subprocess.run(
            [str(HELPER), str(self.tmp)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            print(
                f"safe-rm-dir left {self.tmp} in place: {result.stderr.strip()}",
                file=sys.stderr,
            )

    def _stop_holder(self) -> None:
        """End the fixture process through the guard, or say why it was not.

        `SIGTERM`, a bounded wait, and `SIGKILL` only after the guards have
        been read again — the same sequence the interoperation supervisors
        use, and for the same reason: the pid is a number the kernel hands out
        again, so what it names has to be the process this case started. A
        refusal is not retried and is not worked around. It fails the case,
        because a fixture that outlives its test is a process nobody accounted
        for, and a test that hides that is a green run over an orphan.
        """
        if self.holder is None:
            return
        child, self.holder = self.holder, None
        if child.process.poll() is not None:
            child.process.wait(timeout=30)
            return
        stop = self.guard.stop(child)
        if stop.refused is not None:
            raise AssertionError(
                f"the {stop.child} fixture (pid {child.process.pid}) was left running: the guard "
                f"could not prove it was the process this case started, so nothing was signalled. "
                f"{stop.refused}"
            )
        child.process.wait(timeout=30)

    # -- running --------------------------------------------------------

    def stub(self, name: str, script: str) -> None:
        path = self.stubs / name
        path.write_text(script, encoding="utf-8")
        path.chmod(0o755)

    def run_helper(
        self,
        *args: str,
        stub: bool = False,
        path: str | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env.pop("PATH", None)
        if extra_env:
            env.update(extra_env)
        if path is not None:
            env["PATH"] = path
        else:
            entries = [str(self.stubs)] if stub else []
            # The real tools follow: only the stubbed one is shadowed.
            entries.append(os.environ.get("PATH", "/usr/bin:/bin"))
            env["PATH"] = os.pathsep.join(entries)
        return subprocess.run(
            [str(HELPER), *args],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def tree(self, name: str = "tree") -> Path:
        # 0700, because that is the helper's precondition and not a detail: the
        # liveness evidence covers this account's processes, and mode 0700 is
        # what makes "no other account can have anything open under it" a fact
        # rather than an assumption. A fixture that arrived 0755 would be
        # refused for a reason the case is not testing.
        path = self.tmp / name
        (path / "nested" / "deeper").mkdir(parents=True)
        path.chmod(0o700)
        (path / "nested" / "deeper" / "file.txt").write_text("x", encoding="utf-8")
        (path / "top.txt").write_text("y", encoding="utf-8")
        return path

    def test_check_mode_preserves_the_whole_tree(self) -> None:
        self.require_approved()
        tree = self.tree()
        inode = tree.stat().st_ino
        result = self.run_helper("--check", str(tree))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(tree.stat().st_ino, inode)
        self.assertEqual((tree / "top.txt").read_text(encoding="utf-8"), "y")
        self.assertEqual(
            (tree / "nested" / "deeper" / "file.txt").read_text(encoding="utf-8"), "x",
        )

    def assertRefused(
        self,
        result: subprocess.CompletedProcess[str],
        path: Path,
        why: str,
        kept: bool = True,
    ) -> None:
        """Exit 1, the reason named, and — unless there was nothing there —
        the path exactly as the helper found it."""
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        # The refusal's subject is the check that failed, which each case
        # names; the sentence wrapped around it is not what is under test.
        if kept:
            self.assertTrue(path.exists() or path.is_symlink(), f"{path} was removed anyway")

    def require_approved(self) -> None:
        if approved_root(self.tmp) is None:
            self.skipTest(
                f"TMPDIR is {self.tmp}, which is not a per-account directory on "
                f"{', '.join(APPROVED)}; the accepting path cannot run there"
            )

    def stand_in(self, tree: Path, *, holds: Path | None = None) -> Child:
        """A process of this account in the tree until stopped, guarded.

        The one thing the liveness check must always catch, so the cases about
        procfs answering badly are built on top of it rather than inventing a
        fixture of their own.

        Spawned through the guard, and started as the process the kernel will
        show rather than as a shell on its way to becoming one — see `HOLDER`.
        `cwd` puts it in the tree the way the walk looks for it, through
        `/proc/<pid>/cwd`; `holds` gives it an inherited descriptor on a file
        inside the tree, which it finds through `/proc/<pid>/fd`. The case's own
        copy of that descriptor is closed immediately: it is the child's
        reference, and leaving the parent's open would make the helper find the
        test rather than the fixture.
        """
        descriptor = os.open(holds, os.O_RDONLY) if holds is not None else None
        try:
            child = self.guard.spawn(
                [HOLDER, "60"], f"the holder standing in {tree.name}",
                cwd=str(tree if holds is None else self.tmp),
                pass_fds=() if descriptor is None else (descriptor,),
                start_new_session=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        finally:
            if descriptor is not None:
                os.close(descriptor)
        self.holder = child
        if holds is None:
            self.assertTrue(
                wait_for(lambda: os.readlink(f"/proc/{child.process.pid}/cwd") == str(tree)),
                f"the holder never landed in {tree}",
            )
        else:
            # The descriptor is the only thing putting this process in the
            # tree, so it stands in the case's own directory instead and the
            # reading below is what proves it holds what it was handed.
            self.assertTrue(
                wait_for(
                    lambda: os.readlink(f"/proc/{child.process.pid}/fd/{descriptor}") == str(holds)
                ),
                f"pid {child.process.pid} never held {holds} open",
            )
        return child

    def reap(self, pid: int) -> None:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    def zombie(self) -> int:
        """A process of this account that exited and has not been reaped.

        The boundary where there is a pid and nothing behind it. The kernel
        closes a process's descriptors and drops its address space before it
        becomes a zombie, so what is left in /proc is the links with their
        targets gone: cwd, root and exe read to nothing and the descriptor
        directory will not open. That is the same pair of shapes as a reading
        this account is not allowed to take, and it must not be answered as
        one — a zombie holds nothing, and a host with a leftover zombie must
        still be able to remove a directory.
        """
        pid = os.fork()
        if pid == 0:
            os._exit(0)
        self.addCleanup(self.reap, pid)
        self.assertTrue(
            wait_for(lambda: self.state_of(pid) == "Z"), f"pid {pid} never became a zombie"
        )
        return pid

    @staticmethod
    def state_of(pid: int) -> str:
        """The state field of a process, or "" once it is not there."""
        try:
            line = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        except OSError:
            return ""
        return line[line.rindex(")") + 2 :][:1]

    def unreadable_processes(self) -> list[int]:
        """The pids of this account whose /proc entries will not open.

        The same question the helper asks, asked here first so a case can say
        whether the host has one: a pid directory this account owns, still
        running, whose descriptor directory it cannot search or whose map file
        it cannot read. A host where the account logs in over SSH always has
        some — the session process and its pam helper are not dumpable, so
        their /proc entries belong to root — and where it has none there is
        nothing for a case to prove.
        """
        uid = os.getuid()
        found = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                status = (entry / "status").read_text(encoding="utf-8")
            except OSError:
                continue
            if f"Uid:\t{uid}\t{uid}\t{uid}\t{uid}" not in status:
                continue
            if self.state_of(int(entry.name)) in {"Z", "X"}:
                continue
            try:
                # Reading it is the question, not access(2): a map file the
                # kernel will not hand to its own user is mode 0444 and
                # owned by root, so every permission bit says yes and the
                # open still fails.
                with open(entry / "maps", "rb") as handle:
                    handle.read(1)
            except OSError:
                found.append(int(entry.name))
                continue
            if not os.access(entry / "fd", os.X_OK):
                found.append(int(entry.name))
        return sorted(found)

    @staticmethod
    def has_locale(name: str) -> bool:
        """Whether this host has the locale, since the walk's answer must not
        depend on it and a case needs somewhere to change it to."""
        listing = subprocess.run(
            ["locale", "-a"], capture_output=True, text=True, check=False
        ).stdout.split()
        wanted = name.replace("-", "").replace("_", "").lower()
        return wanted in {entry.replace("-", "").replace("_", "").lower() for entry in listing}

    # -- it removes what it checked -------------------------------------

    def test_it_removes_an_owned_tree(self) -> None:
        self.require_approved()
        tree = self.tree()
        result = self.run_helper(str(tree))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(tree.exists())

    def test_it_removes_an_empty_directory(self) -> None:
        self.require_approved()
        empty = self.tmp / "empty"
        empty.mkdir(mode=0o700)
        self.assertEqual(self.run_helper(str(empty)).returncode, 0)
        self.assertFalse(empty.exists())

    def test_it_unlinks_a_dangling_link_and_never_touches_the_target(self) -> None:
        self.require_approved()
        link = self.tmp / "p"
        link.symlink_to(self.tmp / "gone")
        result = self.run_helper("--link", str(link))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(link.is_symlink())

    def test_it_unlinks_a_link_that_points_at_an_owned_directory(self) -> None:
        self.require_approved()
        target = self.tree("target")
        link = self.tmp / "p"
        link.symlink_to(target)
        self.assertEqual(self.run_helper("--link", str(link)).returncode, 0)
        self.assertFalse(link.is_symlink())
        self.assertTrue((target / "top.txt").exists(), "the target must survive the unlink")

    # -- containment ----------------------------------------------------

    def test_an_owned_link_inside_the_tree_is_removed_and_its_target_is_not(self) -> None:
        # `rm` unlinks a symlink and does not follow it, so a link inside the
        # tree is safe to remove — which matters, because pytest plants
        # `*current` links in its own temporary directories.
        #
        # The target is a file this account owns, OUTSIDE the tree, and what is
        # checked is its content rather than its existence. A sentinel chosen
        # for being unwritable, like /etc/passwd, would still pass if the
        # remover emptied it or replaced it with something else, and would say
        # nothing at all about a delete that reached past the link into a
        # neighbouring directory it could actually write to.
        self.require_approved()
        outside = self.tmp / "outside-the-tree"
        outside.mkdir()
        sentinel = outside / "sentinel.txt"
        sentinel.write_text("this must survive byte for byte\n", encoding="utf-8")
        neighbour = outside / "neighbour.txt"
        neighbour.write_text("and so must this\n", encoding="utf-8")

        tree = self.tree()
        (tree / "out").symlink_to(sentinel)
        result = self.run_helper(str(tree))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(tree.exists())
        self.assertEqual(
            sentinel.read_text(encoding="utf-8"), "this must survive byte for byte\n"
        )
        self.assertEqual(neighbour.read_text(encoding="utf-8"), "and so must this\n")

    def test_a_device_inside_the_tree_is_refused(self) -> None:
        self.require_approved()
        tree = self.tree()
        os.mkfifo(tree / "pipe")
        self.assertRefused(self.run_helper(str(tree)), tree, "device, a socket or a fifo")

    def test_a_directory_offered_as_a_link_is_refused(self) -> None:
        self.require_approved()
        tree = self.tree()
        result = self.run_helper("--link", str(tree))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a symlink", result.stderr)
        self.assertTrue((tree / "top.txt").exists())

    def test_a_symlink_offered_as_a_directory_is_refused(self) -> None:
        self.require_approved()
        link = self.tmp / "p"
        link.symlink_to(self.tree())
        self.assertRefused(self.run_helper(str(link)), link, "--link removes a link")

    # -- ownership, volume, mount ---------------------------------------

    def test_a_tree_of_another_accounts_files_is_refused(self) -> None:
        self.require_approved()
        tree = self.tree()
        # The helper asks `id -u` for the account it is removing on behalf of.
        # Answering with an id this tree does not own is exactly the situation
        # of a second account's leftovers in a shared scratch root.
        self.stub("id", '#!/bin/sh\n[ "$1" = "-u" ] && echo 4242 || exec /usr/bin/id "$@"\n')
        self.assertRefused(self.run_helper(str(tree), stub=True), tree, "belongs to another account")

    def test_a_path_off_the_approved_volumes_is_refused(self) -> None:
        self.require_approved()
        tree = self.tree()
        self.stub("realpath", '#!/bin/sh\necho /tmp/not-approved-$$\n')
        self.assertRefused(self.run_helper(str(tree), stub=True), tree, "not on an approved volume")

    def test_a_link_pointing_off_the_approved_volumes_is_refused(self) -> None:
        self.require_approved()
        link = self.tmp / "p"
        link.symlink_to("/etc")
        self.assertRefused(
            self.run_helper("--link", str(link)), link, "not on an approved volume"
        )

    def path_without(self, tool: str) -> str:
        """A PATH that resolves every command except `tool`.

        The helper refuses when a tool it needs is not there, because a tool
        that is missing cannot answer the question it was asked — `awk` reads
        the mount table, `lsof` is the second witness that nothing is open —
        and "could not look" is not "nothing there". Taking it off PATH is how
        that refusal is proved without touching the system copy of anything.
        """
        farm = self.tmp / f"path-without-{tool}"
        farm.mkdir(exist_ok=True)
        for entry in os.environ.get("PATH", "").split(os.pathsep):
            if not entry or not os.path.isdir(entry):
                continue
            for name in sorted(os.listdir(entry)):
                if name == tool or name.startswith(tool + "-"):
                    continue
                source = os.path.join(entry, name)
                link = farm / name
                if link.is_symlink() or os.path.islink(source) or not os.access(source, os.X_OK):
                    continue
                link.symlink_to(source)
        return str(farm)

    def test_without_lsof_nothing_is_removed(self) -> None:
        # The helper requires both witnesses rather than preferring one: lsof
        # reads the same procfs the walk does and so cannot widen its reach,
        # but the helper asks both and refuses when either cannot answer, and
        # with lsof off PATH that answer is "unknown", not "safe".
        self.require_approved()
        tree = self.tree()
        result = self.run_helper(str(tree), path=self.path_without("lsof"))
        self.assertRefused(result, tree, "lsof is not on PATH")

    def test_the_root_directory_is_refused(self) -> None:
        self.assertRefused(self.run_helper("/"), Path("/"), "root directory")

    def test_a_path_that_is_not_there_is_refused(self) -> None:
        missing = self.tmp / "never"
        # Nothing was there to keep, so the refusal is about the refusal.
        self.assertRefused(self.run_helper(str(missing)), missing, "not a directory", kept=False)


    # -- the mount table ------------------------------------------------

    def mountinfo_double(self, fixture: str) -> dict[str, str]:
        """Put a mount table in front of `awk` and return the environment.

        The helper reads /proc/self/mountinfo by that exact path, so a crafted
        table can only be exercised by standing something in front of awk.
        The double substitutes the fixture for that one path and is otherwise
        the real awk, so the comparison under test is the decoder's, not the
        double's.
        """
        table = self.tmp / "mountinfo.fixture"
        table.write_text(fixture, encoding="utf-8")
        self.stub(
            "awk",
            "#!/usr/bin/env bash\n"
            "# Test double: serves MOCK_MOUNTINFO in place of the real mount\n"
            "# table and is the real awk for every other invocation.\n"
            "args=()\n"
            'for a in "$@"; do\n'
            '    if [ "$a" = "/proc/self/mountinfo" ]; then\n'
            '        args+=("$MOCK_MOUNTINFO")\n'
            "    else\n"
            '        args+=("$a")\n'
            "    fi\n"
            "done\n"
            'exec "$MOCK_REAL_AWK" "${args[@]}"\n',
        )
        return {
            "MOCK_MOUNTINFO": str(table),
            "MOCK_REAL_AWK": shutil.which("awk") or "/usr/bin/awk",
        }

    def mountinfo_line(self, mount_point: str) -> str:
        """One mount-table line whose mount point is exactly `mount_point`."""
        return f"7 8 9:10 / {mount_point} rw,noatime - tmpfs tmpfs rw 0 0\n"

    def table_with(self, mount_point: str) -> dict[str, str]:
        """The environment that puts a filesystem at `mount_point` itself."""
        return self.mountinfo_double(
            "1 2 3:4 / / rw - tmpfs tmpfs rw 0 0\n" + self.mountinfo_line(mount_point)
        )

    def test_the_tree_itself_mounted_is_refused(self) -> None:
        # The question `mountpoint` used to be asked, answered from the mount
        # table — which is the only place the answer exists. The old call read
        # the tool's exit status, and 1 (not a mount point), 32 (could not
        # decide) and 127 (not installed) all meant the same thing to a `&&`.
        self.require_approved()
        tree = self.tree()
        env = self.table_with(str(Path(os.path.realpath(tree))))
        self.assertRefused(
            self.run_helper(str(tree), stub=True, extra_env=env), tree, "is a mount point"
        )

    def test_a_tool_denying_a_mount_point_does_not_allow_the_removal(self) -> None:
        # The fail-open this file exists to catch: a helper that asked
        # `mountpoint -q` and took "not a mount point" as the answer removed the
        # tree while the table said a filesystem was sitting in it. The tool's
        # answer no longer reaches the decision at all, so the table still
        # refuses with the tool denying it.
        self.require_approved()
        tree = self.tree()
        env = self.table_with(str(Path(os.path.realpath(tree))))
        self.stub("mountpoint", "#!/bin/sh\nexit 1\n")
        self.assertRefused(
            self.run_helper(str(tree), stub=True, extra_env=env),
            tree,
            "is a mount point",
        )

    def test_without_awk_the_whole_tree_is_left_intact(self) -> None:
        # `awk` reads the mount table, so with it off PATH there is no way to
        # ask whether a filesystem is mounted at or under the tree. A missing
        # reader is not an empty answer: the case proves the refusal happens
        # before `rm`, by checking the whole tree is still there afterwards and
        # not only its top directory.
        self.require_approved()
        tree = self.tree()
        result = self.run_helper(str(tree), path=self.path_without("awk"))
        self.assertRefused(result, tree, "awk could not read the mount table")
        self.assertTrue((tree / "top.txt").exists())
        self.assertTrue((tree / "nested" / "deeper" / "file.txt").exists())

    def test_without_awk_a_link_is_not_unlinked(self) -> None:
        # The same reader, asked on the unlink path, and the reason this mode
        # has its own answer to every other question: a link whose target is
        # already gone is the ordinary reason `--link` exists, so the target is
        # neither inspected nor required to exist — and the link is still left
        # in place when the mount question cannot be answered at all.
        self.require_approved()
        link = self.tmp / "p"
        link.symlink_to(self.tmp / "gone")
        result = self.run_helper("--link", str(link), path=self.path_without("awk"))
        self.assertRefused(result, link, "awk could not read the mount table")
        self.assertTrue(link.is_symlink())

    def test_a_link_to_a_mount_point_is_refused(self) -> None:
        # The target is inspected before anything is unlinked, and a mount at
        # that target is a refusal: the link goes, the mounted directory it
        # named never does, and the link itself stays because the unlink never
        # happened.
        self.require_approved()
        target = self.tree("target")
        link = self.tmp / "p"
        link.symlink_to(target)
        env = self.table_with(str(Path(os.path.realpath(target))))
        self.assertRefused(
            self.run_helper("--link", str(link), stub=True, extra_env=env),
            link,
            "is a mount point",
        )
        self.assertTrue(link.is_symlink())
        self.assertTrue((target / "top.txt").exists())

    def test_a_mount_point_under_a_backslash_path_is_found(self) -> None:
        # The kernel escapes a backslash in a path as `\134`, so the mount
        # table names this directory that way. If the helper handed the path
        # to awk as a program fragment instead of through the environment, the
        # backslash would be interpreted a second time on the way in and the
        # comparison would silently miss a filesystem sitting inside the tree
        # — the one failure mode here that produces no output at all.
        self.require_approved()
        tree = self.tmp / "back\\slash"
        (tree / "nested").mkdir(parents=True)
        tree.chmod(0o700)
        encoded = f"{tree}/nested".replace("\\", "\\134")
        env = self.mountinfo_double(
            "1 2 3:4 / / rw - tmpfs tmpfs rw 0 0\n" + self.mountinfo_line(encoded)
        )
        self.assertRefused(
            self.run_helper(str(tree), stub=True, extra_env=env),
            tree,
            "is a filesystem mounted inside it",
        )

    def test_a_mount_table_that_cannot_be_read_is_refused(self) -> None:
        # awk failing is not "no mount found". The helper has to distinguish
        # the two, and the tree has to survive the case where it does not.
        self.require_approved()
        tree = self.tree()
        self.stub("awk", "#!/bin/sh\necho \"awk: can't open file\" >&2\nexit 2\n")
        self.assertRefused(
            self.run_helper(str(tree), stub=True),
            tree,
            "could not read the mount table",
        )

    def test_a_short_mount_table_line_is_refused(self) -> None:
        # A line that is not a mount table line is unreadable, not empty.
        self.require_approved()
        tree = self.tree()
        env = self.mountinfo_double("not a mount table line\n")
        self.assertRefused(
            self.run_helper(str(tree), stub=True, extra_env=env),
            tree,
            "a line of /proc/self/mountinfo could not be read",
        )

    # -- liveness -------------------------------------------------------

    def test_a_process_inside_the_tree_blocks_removal(self) -> None:
        self.require_approved()
        tree = self.tree()
        holder = self.stand_in(tree)
        result = self.run_helper(str(tree))
        self.assertRefused(result, tree, "a process still holds it")
        self._stop_holder()

    def test_an_open_descriptor_blocks_removal(self) -> None:
        self.require_approved()
        tree = self.tree()
        handle = tree / "top.txt"
        self.stand_in(tree, holds=handle)
        self.assertRefused(self.run_helper(str(tree)), tree, "a process still holds it")
        self._stop_holder()

    def test_the_tree_is_removed_once_the_holder_is_gone(self) -> None:
        self.require_approved()
        tree = self.tree()
        self.stand_in(tree)
        self.assertEqual(self.run_helper(str(tree)).returncode, 1)
        self._stop_holder()
        self.assertEqual(self.run_helper(str(tree)).returncode, 0)
        self.assertFalse(tree.exists())

    # -- procfs at its edges --------------------------------------------

    def test_a_zombie_of_this_account_is_not_a_live_reference(self) -> None:
        # There is a pid and nothing behind it: cwd, root and exe read to
        # nothing and the descriptor directory will not open. That is the
        # same pair of shapes as a process this account is not allowed to
        # read, and answering it as one stops a host that has a zombie — a
        # host with an unreaped child, which any long-running session here
        # has — from removing anything again, over a process that has
        # already given back every file it held.
        self.require_approved()
        tree = self.tree()
        # Forked before the holder, so the zombie's pid is the lower of the
        # two and the walk meets it first: with the zombie answered as an
        # unreadable process this run stops on it, not on the holder.
        dead = self.zombie()
        self.stand_in(tree)
        result = self.run_helper(str(tree))
        self.assertRefused(result, tree, "a process still holds it")
        self.assertNotIn(
            f"/proc/{dead}/",
            result.stderr,
            "a zombie was answered as a process this account may not read",
        )
        self._stop_holder()

    def test_the_answer_does_not_change_with_the_locale(self) -> None:
        # Every tool in the walk complains in the host's language: under this
        # one `find` reports a process that has gone as `Datei oder
        # Verzeichnis nicht gefunden`, so a scan that recognised a vanished
        # process by its English spelling drops nothing here and turns every
        # ordinary exit on a busy host into a refusal that never goes away.
        # The complaint is not the answer, so the answer must not move when
        # the locale does.
        self.require_approved()
        if not self.has_locale("de_DE.UTF-8"):
            self.skipTest("de_DE.UTF-8 is not generated on this host")
        tree = self.tree()
        dead = self.zombie()
        self.stand_in(tree)
        english = self.run_helper(str(tree), extra_env={"LC_ALL": "C", "LANG": "C"})
        german = self.run_helper(
            str(tree), extra_env={"LC_ALL": "de_DE.UTF-8", "LANG": "de_DE.UTF-8"}
        )
        self._stop_holder()
        self.assertEqual(
            english.returncode, german.returncode, english.stderr + german.stderr
        )
        for result in (english, german):
            self.assertNotIn(f"/proc/{dead}/", result.stderr)
            self.assertTrue(tree.exists(), "the tree was removed anyway")

    def test_a_process_map_that_cannot_be_read_is_refused(self) -> None:
        # The last witness in the walk is a file, and a file that will not
        # open is not a file with nothing in it. `grep` answers 2 for "no
        # such file" and for "no permission" alike and puts the difference in
        # text this account reads in its own language, so the status alone
        # has to carry the refusal.
        self.require_approved()
        tree = self.tree()
        self.stub("grep", "#!/bin/sh\nexit 2\n")
        result = self.run_helper(str(tree), stub=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(tree.exists(), "the tree was removed anyway")
        # Which entry is named depends on which process this account cannot
        # read first, and on a host with a session of its own that is not
        # this one; what is under test is that an entry which will not open
        # is a refusal and never a clean answer.
        self.assertRegex(result.stderr, r"/proc/\d+/(cwd|root|exe|fd|maps)")

    def test_a_process_of_this_account_that_cannot_be_read_is_refused_and_named(self) -> None:
        # The session this very test runs in is such a process on a host where
        # the account logs in over SSH: not dumpable, so its /proc entries
        # belong to root and open with EACCES for its own user. Skipping it —
        # by name, because it is not a shell, or by reading "cannot read" as
        # "holds nothing" — would report a clean answer about a process that
        # was never looked at, which is the one thing this helper exists not
        # to do. Where the host has none there is nothing to prove.
        blind = self.unreadable_processes()
        if not blind:
            self.skipTest("every process of this account can be read here")
        self.require_approved()
        tree = self.tree()
        result = self.run_helper(str(tree))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(tree.exists(), "the tree was removed anyway")
        named = set(re.findall(r"/proc/(\d+)/", result.stderr))
        self.assertTrue(
            named & {str(pid) for pid in blind},
            f"the refusal named {named or 'no pid at all'}, and not one of the "
            f"processes this account cannot read ({blind}): {result.stderr}",
        )


if __name__ == "__main__":
    unittest.main()