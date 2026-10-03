"""Execute the complete Zig test suite in an isolated 32-bit ARM FreeBSD guest.

The published image is a Raspberry Pi SD card, and nothing in it can find its own
way onto a machine: an MBR disk whose first partition is the FAT boot partition
carrying `efi/boot/bootarm.efi`, FreeBSD's EFI loader for 32-bit ARM, and whose
second partition is the UFS root holding the GENERIC kernel.  Only FreeBSD reads
UFS, so the loader has to be started by UEFI firmware, and QEMU has none for
32-bit ARM.  The chain this driver builds is the one the platform supports:

  qemu-system-arm -machine virt  --  the machine the armv7 GENERIC kernel knows
      as hw.platform=virt: sys/arm/qemu/virt_machdep.c matches the device tree
      compatible "linux,dummy-virt" and maps the PL011 at 0x09000000, and the
      GENERIC config builds in pci_host_generic, the host bridge behind it
  -> u-boot.bin  --  CROSS_UBOOT_ARM, whose board file is this machine: TEXT_BASE
      0 with RAM at 0x40000000, a PL011 debug console at 0x09000000, and
      board_fdt_blob_setup() reading the device tree QEMU leaves at the base of
      RAM.  The tree is the one QEMU generates for this machine, asked for with
      the machine's own dumpdtb, so the firmware and the kernel see one tree
  -> bootarm.efi  --  read off the image's own FAT partition with U-Boot's load
      command, which records the device path the loader needs to reach the UFS
      root partition beside the boot partition
  -> GENERIC kernel  --  loaded by the EFI loader and handed that same device
      tree, so it finds hw.platform=virt and the PL011 console

Both disks are virtio-blk-pci: this U-Boot's board Kconfig implies VIRTIO_PCI
and VIRTIO_BLK, and the armv7 GENERIC config builds in virtio_blk.  The image is
the root disk, converted once from the published xz and booted through a private
overlay, and the read-only payload is the second disk.  The guest is driven over
its serial console and has no network device at all.
"""

from __future__ import annotations

import fcntl
import guest_process
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import guest_storage
import time
from collections.abc import Sequence
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import pexpect


TARGETS: tuple[str, ...] = ("arm-freebsd",)

# The published image and the only firmware QEMU can run for this machine.
MEDIA = "CROSS_FREEBSD_ARMV7_XZ"
FIRMWARE = "CROSS_UBOOT_ARM"

EMULATOR = "qemu-system-arm"
MACHINE = "virt"
# GENERIC's only CPU class is CPU_CORTEXA, which is the Cortex-A15.
CPU = "cortex-a15"
# The armv7 kernel is linked at KERNVIRTADDR (0xc1000000) and the EFI loader
# loads it there, so RAM has to reach past two gigabytes.  U-Boot relocates to
# the top of RAM, which stays well clear of it.
MEMORY_MIB = 2560
CPUS = 2

# FreeBSD's own loader, on the FAT partition of the image itself.
LOADER = "/efi/boot/bootarm.efi"
# Where this U-Boot's CONFIG_SYS_LOAD_ADDR puts ${loadaddr}.
LOAD_ADDRESS = "0x40200000"

# U-Boot's filesystem layer names a disk by the interface it is bound to and by
# the device/partition pair that interface reports, and both are properties of
# the firmware build rather than of the image, so each addressing form is tried
# until do_load() has read the file.  It prints a byte count only on success.
BOOT_DEVICES: tuple[tuple[str, str], ...] = (
    ("virtio", "0:1"), ("virtio", "0:0"), ("virtio", "1:1"), ("virtio", "1:0"),
)

# The firmware counts down to its own bootcmd, the loader and kernel then have
# to reach a login, and the suite and the shutdown take the rest of the run.
FIRMWARE_TIMEOUT = 600
BOOT_TIMEOUT = 1800
RUN_TIMEOUT = 7200

AUTOBOOT = rb"Hit any key to stop autoboot:"
PROMPT = rb"=> "
LOADED = rb"bytes read"
LOGIN = rb"[Ll]ogin: "
SHELL = rb"[#$%] "
# The loader says so itself when the device path it was given does not lead to
# a kernel; neither string can appear on a successful boot.
LOST = (rb"Failed to find bootable partition", rb"Booting from an empty disk",
        rb"failed to load.*kernel", rb"No such file or directory")

# The payload device is named by the kernel, so the mount searches the block
# devices this guest presents.  A guest that mounts none reports it in the
# receipt format the caller refuses instead of hanging.
PAYLOAD_MOUNT = "/home/cross-data"
SUITE = "suite.sh"
PAYLOAD_DEVICES = ("vtbd1", "cd0", "cd1", "acd0", "ahcsd1", "da0", "umsa0")


class GuestFailure(RuntimeError):
    """The guest did not boot, or did not report a complete run."""


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

    def tail(self) -> str:
        """The last lines of the console, for a failure report."""
        lines = self.text().decode("utf-8", "replace").splitlines()
        return " | ".join(lines[-12:])


def required_environment(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise GuestFailure(f"{name} is not set; enter devenv --profile bsd-cross shell")
    return value


def cache_root() -> Path:
    cache = Path(required_environment("CROSS_GUEST_CACHE"))
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    return cache


def prepared_image() -> Path:
    """The published SD card image, decompressed and converted once, and cached.

    The pinned file is opened read-only and only ever read: the cache holds a
    conversion of it, built under a lock and moved into place in one step, so a
    concurrent run either waits for that image or uses the finished one.
    """
    source = Path(required_environment(MEDIA))
    if not source.is_file():
        raise GuestFailure(f"{source} is not a file")
    cache = cache_root()
    # A store path is too long for a cache entry and Nix rewrites a pin in
    # place, so the name binds the source's identity instead of copying it.
    status = source.stat()
    key = hashlib.sha256(f"{source}\0{status.st_size}\0{status.st_mtime_ns}"
                         .encode("utf-8")).hexdigest()[:16]
    image = cache / f"freebsd-armv7-{key}.qcow2"
    with (cache / f"freebsd-armv7-{key}.lock").open("ab") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        if image.is_file():
            return image
        with guest_storage.temporary_directory(prefix="prepare-", dir=cache) as raw:
            work = Path(raw)
            decompressed = work / "sd.raw"
            converted = work / "sd.qcow2"
            with decompressed.open("wb") as output:
                subprocess.run(["xz", "--decompress", "--stdout", str(source)],
                               stdout=output, check=True)
            subprocess.run(["qemu-img", "convert", "-f", "raw", "-O", "qcow2",
                            str(decompressed), str(converted)], check=True)
            guest_storage.publish(converted, image)
    return image


def device_tree(work: Path) -> Path:
    """The device tree QEMU generates for this machine.

    Asking the machine for its own tree is what keeps the firmware and the
    kernel on one description of the hardware; no tree is written by hand.
    """
    dtb = work / "virt.dtb"
    subprocess.run([EMULATOR, "-machine", f"{MACHINE},dumpdtb={dtb}",
                    "-cpu", CPU, "-m", str(MEMORY_MIB), "-display", "none"],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.STDOUT, check=True)
    if not dtb.is_file() or dtb.read_bytes()[:4] != b"\xd0\x0d\xfe\xed":
        raise GuestFailure(f"{EMULATOR} produced no {MACHINE} device tree")
    return dtb

def root_overlay(image: Path, work: Path) -> Path:
    """A private overlay, so the cached image is never written to."""
    overlay = work / "root.qcow2"
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2",
                    "-b", str(image), str(overlay)], check=True)
    return overlay


def guest_command(overlay: Path, payload: Path, dtb: Path) -> list[str]:
    """The machine the kernel boots on, its firmware, and its two disks.

    This machine boots its firmware from the flash window QEMU maps at zero,
    which is where U-Boot is linked, so the image is a plain disk rather than
    something the firmware would have to discover: the loader is read off it by
    address.  The payload follows it, so the disk the loader is handed is the
    first one the firmware sees.
    """
    return [
        EMULATOR, "-machine", MACHINE, "-cpu", CPU, "-m", str(MEMORY_MIB),
        "-smp", str(CPUS), "-nographic", "-monitor", "none", "-no-reboot",
        "-nic", "none",
        "-bios", required_environment(FIRMWARE),
        "-dtb", str(dtb),
        "-drive", f"file={overlay},format=qcow2,if=none,id=system",
        "-device", "virtio-blk-pci,drive=system",
        "-drive", f"file={payload},format=raw,if=none,id=payload,readonly=on",
        "-device", "virtio-blk-pci,drive=payload",
    ]


def guest_script() -> str:
    """What the guest runs once it is logged in.

    The payload is mounted read-only; the suite writes its fixtures to the
    overlay's own home directory, and the machine is powered off afterwards so
    the console ends at end of file.
    """
    devices = " ".join(PAYLOAD_DEVICES)
    return (f"mkdir -p {PAYLOAD_MOUNT}; for d in {devices}; do "
            f"mount -t cd9660 /dev/$d {PAYLOAD_MOUNT} 2>/dev/null && break; done; "
            f"[ -f {PAYLOAD_MOUNT}/{SUITE} ] && sh {PAYLOAD_MOUNT}/{SUITE} || "
            "echo ZAP_GUEST_SETUP_FAILED; shutdown -p now")


def matched(child: pexpect.spawn, pattern: bytes) -> bool:
    """Whether the last expect() matched this pattern and not another one."""
    return child.after is not None and re.search(pattern, child.after) is not None


def remaining(deadline: float) -> float:
    left = deadline - time.monotonic()
    if left <= 0:
        raise GuestFailure(f"the arm-freebsd guest did not finish in {RUN_TIMEOUT}s")
    return left


def stop_autoboot(child: pexpect.spawn, deadline: float) -> None:
    """Take the firmware's prompt; its countdown would otherwise boot nothing."""
    child.expect([AUTOBOOT, PROMPT], timeout=remaining(deadline))
    if matched(child, AUTOBOOT):
        child.send(b" ")
        child.expect(PROMPT, timeout=remaining(deadline))


def load_loader(child: pexpect.spawn, deadline: float) -> None:
    """Read the EFI loader off the image's FAT boot partition.

    The load command is what makes U-Boot's EFI machinery know which disk and
    partition the loader came from, which is how the loader finds the UFS root
    beside it; a memory image would carry no such path.
    """
    for interface, device in BOOT_DEVICES:
        child.sendline(f"load {interface} {device} {LOAD_ADDRESS} "
                       f"{LOADER}".encode())
        child.expect([LOADED, PROMPT], timeout=remaining(deadline))
        if matched(child, LOADED):
            return
    raise GuestFailure(
        f"U-Boot read no {LOADER}; the boot partition is not at any of "
        + ", ".join(f"{i} {d}" for i, d in BOOT_DEVICES)
    )


def drive(command: list[str]) -> bytes:
    """Boot the guest, run the suite, and return every byte of its console.

    The emulator is held from the moment it is started. `pexpect.spawn` forks it
    into a session of its own, so the process group a supervisor would put it in
    is a group this run did not choose and the guard refuses to signal; the only
    way to hold a pty child is by pid, which is what `guest_process` does. It
    adopts the console the terminal library opened — proving from `/proc` that
    this pid is running this command line before it records anything — and it
    takes the library's own `close(force=True)`, `terminate()` and finaliser
    away, so that the polite stop and the kill that may follow it are the only
    signals this emulator can receive, and both are authorised by the same
    reading taken again immediately before each.

    Every exit runs the same teardown, including the ones that already failed,
    and a teardown that refused is raised in place of the run's own verdict
    rather than left for the next reader to find.
    """
    import pexpect

    console = Console()
    label = f"{EMULATOR} for arm-freebsd"
    guard = guest_process.Guard()
    handlers = guest_process.install_cancellation()
    try:
        guest = guest_process.spawn(guard, command, label, timeout=FIRMWARE_TIMEOUT)
    except BaseException:
        guest_process.restore_cancellation(handlers)
        raise
    child = guest.console
    child.logfile_read = console
    deadline = time.monotonic() + RUN_TIMEOUT
    failure: BaseException | None = None
    try:
        stop_autoboot(child, deadline)
        load_loader(child, deadline)
        # Without an address of its own the loader takes the firmware's device
        # tree, which is the tree this machine generated.
        child.sendline(f"bootefi {LOAD_ADDRESS}".encode())
        # The loader and the kernel have their own budget; the rest of the run
        # belongs to the suite.
        child.expect([LOGIN, *LOST], timeout=min(BOOT_TIMEOUT, remaining(deadline)))
        if not matched(child, LOGIN):
            raise GuestFailure(f"the FreeBSD loader did not reach a login: "
                               f"{console.tail()}")
        # The release image has no root password.
        child.sendline(b"root")
        # A login prompt that does not become a shell is a refused login, not a
        # slow machine, so this waits briefly rather than for the whole budget.
        child.expect(SHELL, timeout=min(300, remaining(deadline)))
        child.sendline(guest_script().encode())
        child.expect(pexpect.EOF, timeout=remaining(deadline))
    except pexpect.ExceptionPexpect as error:
        # Ahead of the broad handler below, and not replaced by it: a console
        # that timed out or hung up is a guest failure this run has to report,
        # and the tail is the one thing that makes a cross-run failure
        # readable. `Cancelled` is not one of these and falls through.
        failure = GuestFailure(
            f"the arm-freebsd console did not complete: {error}: {console.tail()}")
    except BaseException as error:
        failure = error
    finally:
        try:
            stop = guest_process.finish(guest, guest_process.SHUTDOWN_GRACE)
        except BaseException as teardown:
            # A refusal outranks whatever the run was already failing on, so
            # the teardown's own error is what propagates — with the run's
            # failure chained behind it rather than dropped.
            if failure is None:
                raise
            raise teardown from failure
        finally:
            # Restored whatever the stop did, including when a cancellation
            # arrives inside it: a handler left installed over this report is
            # one that would answer the next signal by unwinding a run that
            # has already torn its guest down.
            guest_process.restore_cancellation(handlers)
    guest_process.require_stopped(stop, label, failure)
    if failure is not None:
        raise failure
    if child.exitstatus != 0:
        raise GuestFailure(f"{EMULATOR} exited {child.exitstatus} for arm-freebsd; "
                           f"the guest did not power off: {console.tail()}")
    return console.text()


def run_guest(target: str, artifact: Path) -> bytes:
    """Run the suite in a real arm-freebsd guest and return its raw console."""
    if target not in TARGETS:
        raise GuestFailure(f"unsupported FreeBSD target: {target}")
    payload = artifact.resolve()
    if not payload.is_file():
        raise GuestFailure(f"payload {payload} is not a file")
    image = prepared_image()
    with guest_storage.temporary_directory(prefix="arm-freebsd-", dir=cache_root()) as raw:
        work = Path(raw)
        command = guest_command(root_overlay(image, work), payload,
                                device_tree(work))
        receipt = drive(command)
    if b"ZAP_GUEST_COMPLETE" not in receipt:
        raise GuestFailure("the arm-freebsd guest produced no complete receipt")
    return receipt


def _main(argv: Sequence[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    prepare = commands.add_parser("prepare", help="convert and cache the image")
    run = commands.add_parser("run", help="run the suite in a guest")
    run.add_argument("target", choices=TARGETS)
    run.add_argument("artifact", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.operation == "prepare":
            print(prepared_image())
        else:
            run_guest(args.target, args.artifact)
    except guest_process.Cancelled as cancelled:
        print(f"cross-freebsd-arm: {cancelled}", file=sys.stderr)
        return 128 + cancelled.signum
    except (GuestFailure, RuntimeError, OSError) as error:
        print(f"cross-freebsd-arm: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))