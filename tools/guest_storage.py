"""Guest scratch, checked by the same policy as the development shell.

A failed preflight or cleanup retains the directory and fails the run. Published
files acquire a second name before checked cleanup removes the staged name; no
existing cache entry is replaced and no directory is moved.
"""
from __future__ import annotations

from contextlib import contextmanager
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from collections.abc import Iterator

_HELPER = Path(__file__).resolve().with_name("safe-rm-dir.sh")


class StorageRefused(RuntimeError):
    pass


def _check(*arguments: str) -> None:
    result = subprocess.run(
        ["bash", str(_HELPER), *arguments], capture_output=True, text=True,
    )
    if result.returncode:
        reason = result.stderr.strip() or result.stdout.strip()
        raise StorageRefused(reason or f"storage check exited {result.returncode}")


def check_directory(path: Path) -> None:
    _check("--check", str(path))


@contextmanager
def temporary_directory(*, prefix: str, dir: str | Path) -> Iterator[str]:
    path = Path(tempfile.mkdtemp(prefix=prefix, dir=dir))
    # Refuse before unpacking a disk or starting a guest on a host whose live
    # references cannot be read. This path is retained if that check fails.
    check_directory(path)
    failure: BaseException | None = None
    try:
        yield str(path)
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            _check(str(path))
        except StorageRefused as error:
            raise error from failure


def publish(source: Path, destination: Path) -> None:
    check_directory(source.parent)
    source_stat = source.lstat()
    parent_stat = destination.parent.lstat()
    uid = os.getuid()
    if source_stat.st_uid != uid or not stat.S_ISREG(source_stat.st_mode):
        raise StorageRefused(f"{source} is not this account's regular staged file")
    if parent_stat.st_uid != uid or not stat.S_ISDIR(parent_stat.st_mode):
        raise StorageRefused(f"{destination.parent} is not this account's real directory")
    if source_stat.st_dev != parent_stat.st_dev:
        raise StorageRefused(f"{source} and {destination} are on different filesystems")
    # link() fails atomically on an existing name, including a dangling link.
    # The caller's lock still protects readers from an incomplete publication.
    os.link(source, destination, follow_symlinks=False)


def unlink_link(path: Path) -> None:
    _check("--link", str(path))
