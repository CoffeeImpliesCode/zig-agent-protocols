"""Execute the complete Zig test suite in official FreeBSD POWER guests.

Two rows run here, ``powerpc64-freebsd`` and ``powerpc64le-freebsd``, and both
run on one machine: QEMU's ``pseries`` PowerPC paravirtual platform under SLOF,
the IEEE 1275 firmware QEMU ships prebuilt for it. FreeBSD/powerpc64le lists
"QEMU pSeries (LoPAR)" among the machines it supports (15.1 hardware notes,
2.4 POWER), so this is the documented guest platform for both byte orders. The
FreeBSD wiki page for POWER/QEMU (wiki.freebsd.org/powerpc/QEMU) gives the
command line this driver builds: the pseries machine, ``-cdrom`` of the
official image, ``-boot d``, the ``cap-cfpc``/``cap-sbbc``/``cap-ibs``
capabilities stated ``broken`` so the guest applies its own handling of those
errata instead of trusting the hypervisor's, and no video, so the console is
the serial line. Nothing here selects a byte order: ``qemu-system-ppc64`` runs
both, the machine and the CPU are the same for both rows, and the byte order is
whatever the kernel inside the pinned image is. Only the pin differs.

The media is the official ``bootonly.iso``, which is not a boot stub. The
release's own ``bootonly`` target (``release/Makefile``) stages
``installworld installkernel distribution`` into it, so the disc carries a
complete FreeBSD 15.1 userland, a kernel, and a loader. ``release/powerpc/
mkisoimages.sh`` gives it the two things a POWER machine needs: a PReP/CHRP
El Torito boot entry whose script runs ``ppc/chrp/loader`` (so SLOF hands over
to FreeBSD's own loader), and an ``/etc/fstab`` naming the disc it was built
into as the root ``cd9660`` volume. That is what makes a single-user boot of
the media a real shell: the root is the release's own filesystem, read-only,
served by the release's own libc and ``/bin/sh``, with no installation, no
installed disk, and no filesystem this driver had to build.

Multi-user is deliberately not used. The media's ``/etc/rc.local`` (copied in
by ``release/Makefile``) starts bsdinstall, so the media's multi-user entry is
an installer, not a shell. Single user is this driver's own choice, taken at
the media's loader: a key that is not Enter aborts its autoboot and returns it
to the ``OK`` prompt, and ``boot -s`` from there keeps the kernel and the root
the loader itself resolved - the root it finds is the one its own ``/etc/
fstab`` just named.

What the guest writes goes to memory. The media's root is read-only, so the
driver mounts a tmpfs over ``/home`` before anything else, and everything the
suite needs - ``/home/cross-data``, ``/home/cross-scratch``, the suite's
``TMPDIR``, the mount script - lands there. The payload the caller built is
attached read-only and mounted ``cd9660`` at ``/home/cross-data``, so the suite
runs from the mounted payload itself rather than from a copy; no private suite
tree is written into the guest. The machine has no disk image at all, so there
is nothing for a run to write and no snapshot to take: the only writable
storage is the memory the guest allocated itself, which dies with the guest.
The cached ISO and the pinned ``.xz`` are never opened for writing.

There is no network device. Every step is bounded: a guest that never reaches
the loader's prompt, a guest whose payload cannot be mounted, and a guest whose
suite exits nonzero each raise instead of returning a receipt, and the console
they produced has already been streamed to stdout. The suite's own progress
lines reset the inactivity bound, so a slow root is not a failure and a silent
guest is.
"""

from __future__ import annotations

import argparse
import fcntl
import guest_process
import lzma
import os
from pathlib import Path
import shutil
import sys
import guest_storage
from types import ModuleType

RELEASE = "15.1"

# The pinned bootonly image each row boots from. Both rows use the same machine
# and the same release; the pin is the only difference between them, and the
# kernel inside that image is what makes the row big- or little-endian.
MEDIA: dict[str, str] = {
    "powerpc64-freebsd": "CROSS_FREEBSD_POWERPC64_ISO_XZ",
    "powerpc64le-freebsd": "CROSS_FREEBSD_POWERPC64LE_ISO_XZ",
}

TARGETS: tuple[str, ...] = tuple(MEDIA)

# One emulator for both rows. qemu-system-ppc64 runs big- and little-endian
# POWER guests; which of the two this driver starts is a property of the pinned
# image, not of this command line.
EMULATOR = "qemu-system-ppc64"

# The documented pseries machine. The three capabilities are stated broken on
# purpose: QEMU's own default is "workaround", which tells the guest that the
# hypervisor already handled those POWER9 errata, and FreeBSD reads that as a
# boot parameter and then skips its own handling, which is not what TCG does.
# "broken" leaves the guest applying its own.
MACHINE = "pseries,cap-cfpc=broken,cap-sbbc=broken,cap-ibs=broken"

# POWER9 is the CPU the FreeBSD hardware notes name for both byte orders, and
# the one both rows are covered by.
CPU = "power9"

# The suite writes into tmpfs, so the guest needs memory to write into: the
# media's root is read-only and there is no disk.
MEMORY = "4096M"
CPUS = 2

# SLOF hands over to FreeBSD's loader, which then finds its own kernel and
# loads it. Under TCG on this machine both steps are slow, so each bound is
# generous; every phase fails closed rather than passing a partial receipt.
FIRMWARE_TIMEOUT = 3600
KERNEL_TIMEOUT = 3600
SETUP_TIMEOUT = 1800
SUITE_TIMEOUT = 5400
SHUTDOWN_TIMEOUT = 1800

# The FreeBSD loader prints a countdown while its autoboot is armed. Either that
# or the prompt is enough to know the loader is the one running, because SLOF's
# own output contains neither.
COUNTDOWN = rb"Autoboot in"
# The loader's prompt, at the start of a line. It is only matched before the
# kernel runs, so "OK" elsewhere in a boot log cannot be mistaken for it.
LOADER_PROMPT = rb"(?m)^OK "
LOADER_MARKERS = (COUNTDOWN, LOADER_PROMPT, rb"/boot/defaults/loader\.conf",
                  rb"Loading /boot/")
# init(8) prints this before it hands the console to the single-user shell.
SHELL_READY = rb"Entering /bin/sh"

# Sent as one line. The console echoes every command that is typed, so each
# marker this driver waits for is anchored to the start of a line: the echoed
# copy of a command never starts with the marker it prints.
PREPARE = (
    b"[ -c /dev/null ] || mount -t devfs devfs /dev; "
    b"ifconfig lo0 inet 127.0.0.1 netmask 0xff000000 up 2>/dev/null || ifconfig lo0 up; "
    b"if mount -t tmpfs -o size=3g tmpfs /home && "
    b"mkdir -p /home/cross-data /home/cross-scratch; then "
    b"mount -t tmpfs -o size=256m tmpfs /tmp 2>/dev/null; "
    b"export TMPDIR=/home/cross-scratch; "
    b"echo ZAP_HOME_READY; "
    b"else echo \"ZAP_GUEST_SETUP_FAILED /home is not a writable tmpfs\"; fi"
)
HOME_READY = rb"(?m)^ZAP_HOME_READY"
SETUP_FAILED = rb"(?m)^ZAP_GUEST_SETUP_FAILED[^\n]*"

# The payload is found by probing rather than by naming a device: it rides as a
# read-only block device, and the name FreeBSD gives it depends on the
# controller its driver binds to. The media this boots from is itself a cd9660
# volume and is in the same probe list, so a candidate only counts once the
# suite it has to run is visible through the mount.
PAYLOAD_SCRIPT = b"""\
# Written by tools/cross_freebsd_power.py; mounts the caller's payload read-only.
set -u
payload=
for disk in $(/sbin/sysctl -n kern.disks); do
    for part in '' s1 s2 s3 p1 p2 p3; do
        candidate="/dev/$disk$part"
        [ -e "$candidate" ] || continue
        /sbin/mount -t cd9660 "$candidate" /home/cross-data 2>/dev/null || continue
        if [ -f /home/cross-data/suite.sh ]; then
            payload="$candidate"
            break 2
        fi
        /sbin/umount /home/cross-data 2>/dev/null
    done
done
if [ -z "$payload" ]; then
    echo "ZAP_GUEST_SETUP_FAILED no payload among: $(/sbin/sysctl -n kern.disks)"
    exit 1
fi
chmod 700 /home/cross-scratch
echo "ZAP_FS_READY payload=$payload"
"""
PAYLOAD_READY = rb"(?m)^ZAP_FS_READY payload=[!-~]+"

# The suite runs from the mounted payload, from the writable tmpfs, with its
# exit status printed for this driver. The caller's receipt reader, not this
# one, decides whether the run is a pass.
SUITE_COMMAND = b"sh /home/cross-data/suite.sh; echo ZAP_SUITE_STATUS $?"
SUITE_STATUS = rb"(?m)^ZAP_SUITE_STATUS ([0-9]+)"

# Printed between roots and inside them. Each one restarts the inactivity
# window, so SUITE_TIMEOUT bounds silence rather than the whole run.
KEEPALIVE = (rb"(?m)^ZAP_GUEST_BEGIN ", rb"(?m)^All [0-9]+ tests passed\.",
             rb"(?m)^[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed\.")


class GuestFailure(RuntimeError):
    """A FreeBSD POWER guest did not boot, or did not deliver a runnable suite."""


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise GuestFailure(f"{name} is unset; it is declared in devenv.nix")
    return value


def _module(name: str) -> ModuleType:
    """Import a pinned package, which only the bsd-cross profile provides."""
    try:
        return __import__(name)
    except ImportError as error:
        raise GuestFailure(
            f"{name} is not importable; run under devenv --profile bsd-cross shell"
        ) from error


class Console:
    """A pexpect logfile that mirrors the console and keeps every byte."""

    def __init__(self) -> None:
        self.chunks: list[bytes] = []

    def write(self, chunk: bytes) -> None:
        self.chunks.append(chunk)
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

    def flush(self) -> None:
        sys.stdout.buffer.flush()

    def text(self) -> bytes:
        return b"".join(self.chunks)


def _is_iso9660(image: Path) -> bool:
    """Whether ``image`` starts with an ISO 9660 primary volume descriptor."""
    if not image.is_file():
        return False
    with image.open("rb") as descriptor:
        descriptor.seek(0x8001)
        return descriptor.read(5) == b"CD001"


def published_iso(variable: str) -> Path:
    """The pinned image, decompressed once into the shared guest cache.

    The cache entry is named after the pinned file and its size, so a changed
    pin lands a new entry instead of reusing the image the old pin produced.
    The caller holds an exclusive lock on it, so a second caller sees either no
    file or the finished one, and the work directory for the conversion is the
    cache itself.
    """
    source = Path(_require(variable))
    if not source.is_file():
        raise GuestFailure(f"{variable} names {source}, which is not a file")
    cache = Path(_require("CROSS_GUEST_CACHE"))
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    entry = f"freebsd-{RELEASE}-{source.name}-{source.stat().st_size:x}"
    image = cache / f"{entry}.iso"
    with (cache / f"{entry}.lock").open("ab") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not _is_iso9660(image):
            _decompress(source, image)
    return image


def _decompress(source: Path, image: Path) -> None:
    """Write the pinned xz out as an immutable ISO, atomically."""
    with guest_storage.temporary_directory(prefix="freebsd-power-", dir=image.parent) as scratch:
        staged = Path(scratch) / image.name
        try:
            with lzma.open(source, "rb", format=lzma.FORMAT_XZ) as packed, \
                    staged.open("wb") as raw:
                shutil.copyfileobj(packed, raw, 1024 * 1024)
        except (lzma.LZMAError, EOFError, OSError) as error:
            raise GuestFailure(f"{source} did not decompress: {error}") from error
        if not _is_iso9660(staged):
            raise GuestFailure(f"{source} did not decompress into an ISO 9660 image")
        staged.chmod(0o444)
        guest_storage.publish(staged, image)


def media_command(media: Path, payload: Path) -> list[str]:
    """The machine, the media, and the payload; nothing else is attached.

    The official image is the only CD-ROM, so "boot d" names one device. The
    payload rides as a read-only block device rather than as a second CD, which
    keeps the firmware's boot choice unambiguous and lets the guest mount the
    same ISO 9660 volume the other rows mount. No disk image is created, so a
    run cannot write to anything but the memory it allocated itself.
    """
    return [
        EMULATOR, "-accel", "tcg",
        "-machine", MACHINE, "-cpu", CPU,
        "-smp", str(CPUS), "-m", MEMORY,
        "-nographic", "-monitor", "none", "-vga", "none", "-no-reboot",
        "-nic", "none",
        "-boot", "order=d",
        "-cdrom", str(media),
        "-drive", f"if=none,id=payload,file={payload},format=raw,readonly=on",
        "-device", "virtio-blk-pci,drive=payload",
    ]


def _loader_prompt(child, pexpect: ModuleType) -> None:
    """Stop the loader's autoboot so the boot below is this driver's choice.

    The media's loader would otherwise boot its own default entry, which on
    this media is the installer. A key that is not Enter aborts the countdown
    and returns the loader to its prompt, which is where ``boot -s`` is typed:
    the loader keeps its own kernel and root, so neither is named here.
    """
    index = child.expect([*LOADER_MARKERS], timeout=FIRMWARE_TIMEOUT)
    if LOADER_MARKERS[index] is LOADER_PROMPT:
        return
    if LOADER_MARKERS[index] is not COUNTDOWN:
        child.expect(COUNTDOWN, timeout=FIRMWARE_TIMEOUT)
    child.send(b"\x1b")
    child.expect(LOADER_PROMPT, timeout=FIRMWARE_TIMEOUT)


def _boot_single_user(child, pexpect: ModuleType) -> None:
    """Boot the media's own root read-only and hand over its shell.

    The media's ``/etc/fstab`` names the disc it was built into as the root
    ``cd9660`` volume, so this boots the release's own filesystem rather than
    anything this driver assembled. The command ends in a carriage return: the
    loader reads its console raw, and the shell that comes up reads a line
    feed.
    """
    child.send(b"boot -s\r")
    child.expect(SHELL_READY, timeout=KERNEL_TIMEOUT)


def _prepare(child, pexpect: ModuleType) -> None:
    """Make /home writable, then mount the caller's payload read-only."""
    child.sendline(PREPARE)
    index = child.expect([HOME_READY, SETUP_FAILED], timeout=SETUP_TIMEOUT)
    if index:
        raise GuestFailure("the guest could not make a writable /home: "
                           f"{child.after.decode('ascii', 'replace')}")
    # Written one line at a time, the way it would be typed: a whole heredoc in
    # one write can outrun the console's input queue.
    child.sendline(b"cat > /home/cross-scratch/zap-payload.sh <<'ZAP_PAYLOAD_EOF'")
    for line in PAYLOAD_SCRIPT.splitlines(keepends=True):
        child.send(line)
    child.sendline(b"ZAP_PAYLOAD_EOF")
    child.sendline(b"/bin/sh /home/cross-scratch/zap-payload.sh")
    index = child.expect([PAYLOAD_READY, SETUP_FAILED], timeout=SETUP_TIMEOUT)
    if index:
        raise GuestFailure("the guest found no payload to mount: "
                           f"{child.after.decode('ascii', 'replace')}")


def _run_suite(child, pexpect: ModuleType) -> None:
    """Run the mounted suite and require that it finished as a whole."""
    child.sendline(SUITE_COMMAND)
    while True:
        try:
            index = child.expect([*KEEPALIVE, SUITE_STATUS], timeout=SUITE_TIMEOUT)
        except pexpect.TIMEOUT as error:
            raise GuestFailure(
                f"the suite reported nothing for {SUITE_TIMEOUT} seconds"
            ) from error
        if index == len(KEEPALIVE):
            status = int(child.match.group(1))
            break
    if status:
        raise GuestFailure(f"the suite exited {status}")
    # The suite does not halt the guest; this driver owns the shutdown, and the
    # console reaches end of file only when the guest really powered off.
    child.sendline(b"sync; shutdown -p now")
    child.expect(pexpect.EOF, timeout=SHUTDOWN_TIMEOUT)


def run_guest(target: str, artifact: Path) -> bytes:
    """Boot ``target``, run the suite from ``artifact``, return the console.

    The console is streamed to stdout as it arrives and returned whole, so the
    caller can require a complete, unique, non-skipped receipt for every
    declared test root. A guest that cannot boot, cannot mount the payload, or
    whose suite exits nonzero raises instead of returning a receipt; the
    console it produced has been written to stdout either way.

    The emulator is held from the moment it is started, by the same rules as
    every other driver here: a pty child leads a session of its own, so it is
    adopted by pid from `/proc` and stopped only through the guard, and the
    terminal library's own `close(force=True)`, `terminate()` and finaliser are
    taken away so that no path out of this function signals a pid that nothing
    has proved.

    A cancellation is an exception rather than a signal this process sends to
    itself. The old handler closed every console it had and then re-raised its
    own signal, which stopped the machine twice over: once on whatever the pid
    looked like inside the handler and once through the interpreter's default
    disposition, where no guard had been read at all. Raising unwinds into the
    same `finally` every other exit takes, so the machine is stopped once and
    through the guard, and `main` reports the cancellation as an exit status.
    """
    if target not in MEDIA:
        raise GuestFailure(f"{target} is not a FreeBSD POWER target this driver "
                           f"runs; it runs {', '.join(TARGETS)}")
    payload = Path(artifact).resolve()
    if not payload.is_file():
        raise GuestFailure(f"{artifact} is not a file")
    if shutil.which(EMULATOR) is None:
        raise GuestFailure(f"{EMULATOR} is not on PATH")
    pexpect = _module("pexpect")

    command = media_command(published_iso(MEDIA[target]), payload)
    console = Console()
    label = f"{EMULATOR} for {target}"
    guard = guest_process.Guard()
    handlers = guest_process.install_cancellation()
    try:
        guest = guest_process.spawn(guard, command, label, timeout=FIRMWARE_TIMEOUT)
    except BaseException:
        guest_process.restore_cancellation(handlers)
        raise
    child = guest.console
    child.logfile_read = console
    failure: BaseException | None = None
    try:
        _loader_prompt(child, pexpect)
        _boot_single_user(child, pexpect)
        _prepare(child, pexpect)
        _run_suite(child, pexpect)
    except pexpect.ExceptionPexpect as error:
        failure = GuestFailure(
            f"{target}: the guest console stopped responding: {error}"
        )
    except BaseException as error:
        failure = error
    finally:
        try:
            stop = guest_process.finish(guest, guest_process.SHUTDOWN_GRACE)
        finally:
            guest_process.restore_cancellation(handlers)
    guest_process.require_stopped(stop, label, failure)
    if failure is not None:
        raise failure

    if child.exitstatus:
        raise GuestFailure(f"{EMULATOR} exited {child.exitstatus} for {target}; "
                           f"the guest did not power off")
    return console.text()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ("run", "media"):
        command = commands.add_parser(name)
        command.add_argument("target", choices=TARGETS)
        if name == "run":
            command.add_argument("artifact", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "run":
            run_guest(args.target, args.artifact)
        else:
            print(published_iso(MEDIA[args.target]))
    except guest_process.Cancelled as cancelled:
        print(f"cross-freebsd-power: {cancelled}", file=sys.stderr)
        return 128 + cancelled.signum
    except (GuestFailure, RuntimeError, OSError) as error:
        print(f"cross-freebsd-power: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())