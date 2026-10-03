"""Where a run's work directory comes from, and who may take it away.

Every supervisor in this directory ends by removing a generated work
directory, and all four used to do it with `shutil.rmtree` on a path they
recorded a moment earlier. That is the wrong shape for a shared volume: a
recursive delete by name does not check that the directory is still the one
this run made, still this account's, still somewhere the rest of the machine
treats as per-account storage, and still holding nothing — so when one of
those is no longer true the removal is exactly the wrong action rather than a
refusal.

This repository already has the tool that answers those questions
before it removes anything, `tools/safe-rm-dir.sh`, and it is the only thing
that removes a work directory here. This module is the small seam between it
and the four supervisors: it resolves the helper, it states the two
preconditions the helper enforces (a directory this account owns and no other
account can reach, on this account's own directory of an approved volume), and
it turns the helper's refusal into an error naming the path that is still
there — never a message claiming the directory is gone.

Nothing else belongs here. A work directory's captures, logs and lifecycle
stay in each peer, because those are the evidence of that peer's exchange and
none of the four has a reason to share them.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from process_guard import Guard, ProcessGuardError

# The repository's own remover. Resolved from this file rather than from PATH
# so a run cannot pick up something else that happens to be called the same
# thing.
HERE = Path(__file__).resolve().parent
REMOVE = HERE.parent.parent / "tools" / "safe-rm-dir.sh"

# The volumes the remover accepts, and the per-account directory on each. Read
# off the helper rather than restated from memory: these are the paths it will
# remove from, and a directory outside them is one it must refuse, so a
# generated directory created outside them could only ever be left behind.
APPROVED_VOLUMES = ("/home/tmp2", "/home/tmp", "/vol/tmp2", "/vol/tmp")

# How long the remover is given before the run stops waiting for it. It is a
# recursive removal of a capture and a handful of reports, so this is a bound
# on a process that has stopped making progress, not a budget.
REMOVE_TIMEOUT = 120.0


class WorkDirRefused(RuntimeError):
    """A work directory was not removed, or not written to.

    Carries the path in the message, because the one thing a caller must be
    able to say afterwards is where the directory is.
    """


def account_name() -> str:
    """The account this run is running as, resolved the way the helper does."""
    return subprocess.run(
        ["id", "-un"], capture_output=True, text=True, check=True
    ).stdout.strip()


def _within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def approved_scratch_root() -> Path:
    """The one directory a generated work directory may be created in.

    `TMPDIR`, checked against what the remover will accept. This is stricter
    than refusing `/tmp`: the helper only removes from this account's own
    directory on an approved volume, so a generated directory anywhere else is
    one the run could create and then never be allowed to take away.
    """
    raw = os.environ.get("TMPDIR")
    if raw is None or raw.strip() == "":
        raise WorkDirRefused(
            "TMPDIR is not set. These peers keep a run's work on the scratch the environment "
            "provides and never fall back to a system temporary directory: export "
            f"TMPDIR=<one of {', '.join(APPROVED_VOLUMES)}>/{account_name()}>, or pass "
            "--work-dir <dir> to name the place yourself."
        )
    root = Path(raw)
    if not root.is_absolute():
        raise WorkDirRefused(f"TMPDIR={raw!r} is not an absolute path")
    resolved = Path(os.path.realpath(root))
    if root.is_symlink():
        raise WorkDirRefused(
            f"TMPDIR={raw!r} is a symlink to {resolved}; a symlinked scratch root is a path this "
            f"run would be creating directories under on trust, and the remover resolves through "
            f"it rather than following the name given here"
        )
    mine = Path(account_name())
    for volume in APPROVED_VOLUMES:
        account_root = Path(volume) / mine
        if resolved == account_root or _within(resolved, account_root):
            break
    else:
        raise WorkDirRefused(
            f"TMPDIR={raw!r} resolves to {resolved}, which is not this account's directory "
            f"({mine}) on one of {', '.join(APPROVED_VOLUMES)}. A work directory created there "
            f"would sit on storage shared with other accounts, and the repository's remover would "
            f"refuse to take it away at the end of the run."
        )
    try:
        owner = resolved.stat().st_uid
    except OSError as exc:
        raise WorkDirRefused(
            f"TMPDIR={raw!r} resolves to {resolved}, which cannot be examined ({exc}), so this "
            f"run cannot tell whose directory it would be creating work in"
        ) from exc
    if owner != os.getuid():
        raise WorkDirRefused(
            f"TMPDIR={raw!r} resolves to {resolved}, which belongs to uid {owner} rather than to "
            f"uid {os.getuid()}; this run does not write into another account's directory"
        )
    resolved.mkdir(parents=True, exist_ok=True)
    if not os.access(resolved, os.W_OK | os.X_OK):
        raise WorkDirRefused(f"TMPDIR={raw!r} resolves to {resolved}, which is not writable")
    return resolved


def require_private_directory(path: Path) -> None:
    """A generated work directory must be one no other account can reach.

    Mode 0700 is the remover's precondition, and it is also the only thing
    that makes its liveness check mean anything: no other account has a path
    into a 0700 directory, so none can have opened anything under it. A
    directory created any other way could be removed while something in it was
    still being written by somebody else, and the remover cannot see that.
    """
    try:
        mode = path.stat().st_mode & 0o777
    except OSError as exc:
        raise WorkDirRefused(
            f"the generated work directory {path} cannot be examined ({exc}), so this run cannot "
            f"confirm it is safe to write into and then remove"
        ) from exc
    if mode != 0o700:
        raise WorkDirRefused(
            f"the generated work directory {path} has mode {mode:04o}; the repository's remover "
            f"removes only a directory no other account can enter, and mode 0700 is what makes "
            f"its check that nothing is holding the tree a real one"
        )
    owner = path.stat().st_uid
    if owner != os.getuid():
        raise WorkDirRefused(
            f"the generated work directory {path} belongs to uid {owner} rather than to uid "
            f"{os.getuid()}; this run does not write into another account's directory"
        )


def require_named_directory(path: Path, flag: str = "--work-dir") -> None:
    """A named work directory must be this account's, and must not be a link.

    A named directory is a deliverable and is never removed, so the checks
    here are about what this run is about to write into rather than about
    what it may later delete. Writing a capture into a directory another
    account owns is still a write into that account's directory, and following
    a symlink means the bytes land somewhere the name does not describe.
    """
    if path.is_symlink():
        target = Path(os.path.realpath(path))
        raise WorkDirRefused(
            f"{flag} {path} is a symlink to {target}; a named work directory is written into, so "
            f"the name has to be the directory the bytes will land in rather than a link that "
            f"points somewhere else"
        )
    if not path.exists():
        return
    try:
        info = path.stat()
    except OSError as exc:
        raise WorkDirRefused(
            f"{flag} {path} cannot be examined ({exc}), so this run cannot tell whose directory it "
            f"would be writing the capture into"
        ) from exc
    if not os.path.isdir(path):
        raise WorkDirRefused(f"{flag} {path} exists and is not a directory")
    if info.st_uid != os.getuid():
        raise WorkDirRefused(
            f"{flag} {path} belongs to uid {info.st_uid} rather than to uid {os.getuid()}; this "
            f"run does not write into another account's directory. Name a directory this account "
            f"owns, or leave it out and let the run generate one under TMPDIR."
        )


def remove_directory(path: Path) -> None:
    """Take a generated work directory away with the repository's remover.

    There is no fallback and no second way to do this. If the helper is absent
    or declines, the directory stays and this raises, naming it — because a
    caller that carried on would then print that a directory was removed while
    it is still there, which is the one thing a teardown notice must never do.

    The remover runs as a guarded child rather than as a bare `subprocess.run`.
    That is what keeps the deadline from becoming an unguarded kill: a helper
    that stops answering is stopped by `process_guard`, which re-reads the
    ownership, start time, command line and process group before every signal
    and reports a refusal instead of sending one. Prerequisite refusals leave
    the directory intact. After the helper starts, a refusal does not prove
    whether it removed all, some or none of the directory.
    """
    if not REMOVE.is_file() or not os.access(REMOVE, os.X_OK):
        raise WorkDirRefused(
            f"{REMOVE} is not an executable file, so the generated work directory {path} cannot "
            f"be removed by the repository's remover and has been left in place. There is "
            f"deliberately no fallback: removing it by name instead is the thing that helper "
            f"exists to prevent."
        )
    bash = shutil.which("bash")
    if bash is None:
        raise WorkDirRefused(f"bash is unavailable; leaving {path} in place")
    try:
        # Built before anything is started, and on this account a guard that
        # cannot read its own proofs does not exist. That is a prerequisite
        # failure like any other here: the directory is still there and the
        # caller is told where.
        guard = Guard()
    except ProcessGuardError as exc:
        raise WorkDirRefused(
            f"this run cannot prove which processes are its own, so the generated work directory "
            f"{path} cannot be removed and has been left in place: {exc}"
        ) from exc
    try:
        child = guard.spawn(
            [bash, str(REMOVE), str(path)], "scratch remover",
            start_new_session=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            # Decoded leniently on purpose: a byte the helper's streams carry
            # that is not UTF-8 must not raise out of the wait below, because a
            # raise there unwinds past the stop and leaves a child nobody
            # waited for and a directory nobody was told about.
            text=True, errors="replace",
        )
    except ProcessGuardError as exc:
        raise WorkDirRefused(f"cannot start the checked remover for {path}: {exc}") from exc
    try:
        try:
            stdout, stderr = child.process.communicate(timeout=REMOVE_TIMEOUT)
        except subprocess.TimeoutExpired:
            # The one place this module ends a process, and it goes through the
            # guard. A stop that refused, or that killed and still found the
            # child there, reports itself in the fields below; the directory is
            # whatever the helper managed before the deadline, which is never
            # claimed either way here.
            stop = guard.stop(child)
            raise WorkDirRefused(
                f"removing {path} exceeded {REMOVE_TIMEOUT}s; removal is unconfirmed; "
                f"pid {child.process.pid}, signals={stop.signals}, exit={stop.exit}, "
                f"refusal={stop.refused}"
            ) from None
        if child.process.returncode != 0:
            raise WorkDirRefused(
                f"the repository's remover refused {path} and left it in place: "
                f"{(stderr or stdout).strip()}"
            )
    finally:
        for pipe in (child.process.stdout, child.process.stderr):
            if pipe is not None:
                pipe.close()