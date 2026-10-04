"""Build and execute the test roots in isolated BSD guests."""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys
import guest_storage
from collections.abc import Iterable

GUESTS = {
    "x86_64-freebsd": ("CROSS_FREEBSD_AMD64_XZ", "qemu-system-x86_64"),
    "aarch64-freebsd": ("CROSS_FREEBSD_ARM64_XZ", "qemu-system-aarch64"),
    "riscv64-freebsd": ("CROSS_FREEBSD_RISCV64_XZ", "qemu-system-riscv64"),
}

# The payload is read-only; test fixtures and std.testing.tmpDir need a writable
# working directory, separate from both the binaries and the caller's payload.
SUITE = """#!/bin/sh
set -u
mkdir -p /home/cross-scratch || { echo ZAP_GUEST_SETUP_FAILED; exit 1; }
chmod 700 /home/cross-scratch
export TMPDIR=/home/cross-scratch
cd /home/cross-scratch || { echo ZAP_GUEST_SETUP_FAILED; exit 1; }
expected=$(wc -l < /home/cross-data/tests/manifest)
printf 'ZAP_GUEST_EXPECTED %s\\n' "$expected"
while IFS= read -r root; do
    printf 'ZAP_GUEST_BEGIN %s\\n' "$root"
    "/home/cross-data/tests/$root"
    status=$?
    printf 'ZAP_GUEST_END %s %s\\n' "$root" "$status"
done < /home/cross-data/tests/manifest
echo ZAP_GUEST_COMPLETE
"""

# No network device is attached. FreeBSD's nuageinit runs the data-CD hook.
USER_DATA = """#!/bin/sh
set -u
mkdir -p /home/cross-data
mount -t cd9660 /dev/cd0 /home/cross-data || { echo ZAP_GUEST_SETUP_FAILED; shutdown -p now; exit 1; }
sh /home/cross-data/suite.sh
shutdown -p now
"""


class GuestFailure(Exception):
    pass


def count_tests(lines: Iterable[bytes], required_roots: Iterable[str] | None = None) -> int:
    """Require a complete, unique, non-skipped receipt for every declared root.

    When required_roots is given, the receipt's root set must equal it
    exactly. The guest's own EXPECTED line is self-reported, so without the
    host-side manifest a truncated payload could print a smaller count, run
    fewer roots, and still validate.
    """
    expected: int | None = None
    current: bytes | None = None
    summary: int | None = None
    roots: set[bytes] = set()
    total = 0
    complete = False
    for raw in lines:
        line = raw.rstrip(b"\r\n")
        if line.startswith(b"ZAP_GUEST_") and complete:
            raise GuestFailure("guest receipt continues after completion")
        if match := re.fullmatch(rb"ZAP_GUEST_EXPECTED[ \t]+([1-9][0-9]*)", line):
            if expected is not None or current is not None or roots:
                raise GuestFailure("repeated or misplaced guest root count")
            expected = int(match[1])
        elif match := re.fullmatch(rb"ZAP_GUEST_BEGIN ([a-z][a-z0-9-]*)", line):
            if expected is None or current is not None or match[1] in roots:
                raise GuestFailure("missing root count, nested root, or duplicate root")
            current, summary = match[1], None
        elif match := re.fullmatch(rb"All ([1-9][0-9]*) tests passed\.", line):
            if current is not None:
                if summary is not None:
                    raise GuestFailure("multiple summaries for one test root")
                summary = int(match[1])
        elif match := re.fullmatch(rb"([0-9]+) passed; ([0-9]+) skipped; ([0-9]+) failed\.", line):
            if current is not None:
                if summary is not None or int(match[1]) == 0 or int(match[2]) or int(match[3]):
                    raise GuestFailure("a test root failed, skipped tests, or reported no tests")
                summary = int(match[1])
        elif match := re.fullmatch(rb"ZAP_GUEST_END ([a-z][a-z0-9-]*) ([0-9]+)", line):
            if current != match[1] or int(match[2]) != 0 or summary is None:
                raise GuestFailure("a root failed or did not report its executed tests")
            roots.add(current)
            total += summary
            current, summary = None, None
        elif line == b"ZAP_GUEST_COMPLETE":
            if expected is None or current is not None or len(roots) != expected:
                raise GuestFailure("guest stopped before every test root completed")
            complete = True
        elif line.startswith(b"ZAP_GUEST_"):
            raise GuestFailure("malformed guest receipt or guest setup failure")
    if not complete:
        raise GuestFailure("guest did not produce a complete test receipt")
    if required_roots is not None:
        required = set(required_roots)
        seen = {root.decode("ascii") for root in roots}
        if seen != required:
            raise GuestFailure(
                "guest roots do not match the exported manifest: "
                f"missing {sorted(required - seen)}, extra {sorted(seen - required)}"
            )
    return total

def manifest_roots(manifest: Path) -> list[str]:
    """The roots an export carries, validated the way build_payload validates."""
    try:
        roots = manifest.read_text(encoding="ascii").splitlines()
    except OSError as error:
        raise GuestFailure(f"exported manifest {manifest} is unreadable: {error}") from error
    if not roots or len(set(roots)) != len(roots):
        raise GuestFailure(f"exported manifest {manifest} has no roots or duplicates one")
    for root in roots:
        if not re.fullmatch(r"[a-z][a-z0-9-]*", root):
            raise GuestFailure(f"exported manifest names an unsafe root: {root!r}")
    return roots


def expected_roots(target: str, artifact: Path) -> list[str]:
    """The host-side manifest the payload for target was built from.

    build_payload writes the ISO to <prefix>/<target>.iso and the manifest to
    <prefix>/guest-artifacts/<target>/tests/manifest, so the run derives one
    from the other. A missing manifest fails closed rather than running
    without the root-set check.
    """
    return manifest_roots(
        Path(artifact).resolve().parent / "guest-artifacts" / target / "tests" / "manifest"
    )


def required_environment(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise GuestFailure(f"{name} is unset; enter devenv --profile bsd-cross shell")
    return value


def build_payload(args: argparse.Namespace) -> None:
    prefix = args.prefix.resolve()
    target_prefix = prefix / "guest-artifacts" / args.target
    subprocess.run([args.zig, "build", "test-artifacts", f"-Dtarget={args.target}",
                    f"-j{args.jobs}", "--prefix", str(target_prefix), "--cache-dir",
                    str(args.cache / args.target), "--summary", "all", "--color", "off",
                    *args.build_args], check=True)
    roots = manifest_roots(target_prefix / "tests" / "manifest")
    tests = target_prefix / "tests"
    for root in roots:
        if not (tests / root).is_file():
            raise GuestFailure(f"exported test root is missing: {root!r}")
    with guest_storage.temporary_directory(prefix="guest-seed-", dir=args.cache) as temporary:
        seed = Path(temporary)
        (seed / "meta-data").write_text(f"instance-id: zig-agent-protocols-{args.target}\n"
                                        "local-hostname: cross-test\n", encoding="ascii")
        (seed / "user-data").write_text(USER_DATA, encoding="ascii")
        (seed / "suite.sh").write_text(SUITE, encoding="ascii")
        subprocess.run(["xorriso", "-as", "mkisofs", "-quiet", "-r", "-J", "-V", "cidata",
                        "-o", str(prefix / f"{args.target}.iso"),
                        "-graft-points", f"tests={tests}",
                        f"meta-data={seed / 'meta-data'}", f"user-data={seed / 'user-data'}",
                        f"suite.sh={seed / 'suite.sh'}"],
                       check=True)


def prepared_image(target: str) -> Path:
    variable, _ = GUESTS[target]
    source = Path(required_environment(variable))
    cache = Path(required_environment("CROSS_GUEST_CACHE"))
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    # A fixed-output Nix store name binds the cached conversion to verified bytes.
    image = cache / f"{source.name}.qcow2"
    with (cache / f"{source.name}.lock").open("ab") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if image.is_file():
            return image
        with guest_storage.temporary_directory(prefix="prepare-", dir=cache) as temporary:
            raw, converted = Path(temporary) / "base.raw", Path(temporary) / "base.qcow2"
            with raw.open("wb") as output:
                subprocess.run(["xz", "--decompress", "--stdout", str(source)],
                               stdout=output, check=True)
            subprocess.run(["qemu-img", "convert", "-f", "raw", "-O", "qcow2",
                            str(raw), str(converted)], check=True)
            guest_storage.publish(converted, image)
    return image


def run_guest(args: argparse.Namespace) -> None:
    _, emulator = GUESTS[args.target]
    image = prepared_image(args.target)
    command = [emulator, "-accel", "tcg", "-m", "2048", "-smp", "2", "-cpu", "max",
               "-nographic", "-monitor", "none", "-no-reboot", "-nic", "none",
               "-drive", f"file={image},format=qcow2,if=none,id=system,snapshot=on",
               "-device", "virtio-blk-pci,drive=system"]
    if args.target == "riscv64-freebsd":
        # This image attaches VirtIO SCSI but provides no CD peripheral. Its
        # already-working block driver can mount the same read-only ISO volume.
        command += [
            "-drive", f"file={args.artifact.resolve()},format=raw,if=none,id=data,readonly=on",
            "-device", "virtio-blk-pci,drive=data",
        ]
    else:
        command += [
            "-device", "virtio-scsi-pci,id=scsi",
            "-drive", f"file={args.artifact.resolve()},format=raw,if=none,id=data,media=cdrom,readonly=on",
            "-device", "scsi-cd,drive=data,bus=scsi.0",
        ]
    if args.target == "aarch64-freebsd":
        firmware = Path(required_environment("CROSS_QEMU_FIRMWARE")) / "edk2-aarch64-code.fd"
        command += ["-machine", "virt", "-bios", str(firmware)]
    if args.target == "riscv64-freebsd":
        # The official VM image has no nuageinit hook. Drive its local console;
        # neither installation nor a network connection is needed.
        firmware = Path(required_environment("CROSS_QEMU_FIRMWARE"))
        command += [
            "-machine", "virt,acpi=off",
            "-drive", f"file={firmware / 'edk2-riscv-code.fd'},format=raw,if=pflash,unit=0,readonly=on",
            "-drive", f"file={firmware / 'edk2-riscv-vars.fd'},format=raw,if=pflash,unit=1,snapshot=on",
        ]
        import pexpect
        import guest_process

        class Console:
            def __init__(self) -> None:
                self.chunks: list[bytes] = []

            def write(self, chunk: bytes) -> None:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                self.chunks.append(chunk)

            def flush(self) -> None:
                sys.stdout.buffer.flush()

        console = Console()
        guard = guest_process.Guard()
        handlers = guest_process.install_cancellation()
        guest = None
        failure: BaseException | None = None
        try:
            guest = guest_process.spawn(guard, command, args.target, timeout=900)
            child = guest.console
            child.logfile_read = console
            # RISC-V boots from its FDT, not ACPI. The generic VM's comconsole
            # setting names no console this architecture's EFI loader provides.
            child.expect(rb"Autoboot")
            child.send(b"3")
            child.expect(rb"OK ")
            child.sendline(b"set console=efi")
            child.expect(rb"OK ")
            child.sendline(b"boot -h")
            child.expect(rb"login: ")
            child.sendline(b"root")
            child.expect(rb"[#%] ")
            child.sendline(b"mkdir -p /home/cross-data && "
                           b"mount -t cd9660 /dev/vtbd1 /home/cross-data && "
                           b"sh /home/cross-data/suite.sh; shutdown -p now")
            child.expect(pexpect.EOF)
        except BaseException as error:
            failure = error
        finally:
            try:
                stopped = guest_process.finish(guest) if guest is not None else None
            finally:
                guest_process.restore_cancellation(handlers)
        if stopped is not None:
            guest_process.require_stopped(stopped, args.target, failure)
        if failure is not None:
            raise failure
        if child.exitstatus != 0:
            raise GuestFailure(f"QEMU exited {child.exitstatus}, signal {child.signalstatus}")
        count_tests(b"".join(console.chunks).splitlines(), expected_roots(args.target, args.artifact))
        return
    import guest_process

    chunks: list[bytes] = []
    guard = guest_process.Guard()
    handlers = guest_process.install_cancellation()
    child = None
    failure: BaseException | None = None
    try:
        child = guard.spawn(command, args.target, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True)
        process = child.process
        assert process.stdout is not None
        while chunk := process.stdout.read1(65536):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            chunks.append(chunk)
        status = process.wait()
    except BaseException as error:
        failure = error
    finally:
        try:
            stopped = (guest_process.finish(guest_process.Guest(args.target, None, child, guard))
                       if child is not None else None)
        finally:
            guest_process.restore_cancellation(handlers)
    if stopped is not None:
        guest_process.require_stopped(stopped, args.target, failure)
        process.stdout.close()
    if failure is not None:
        raise failure
    if status != 0:
        raise GuestFailure(f"QEMU exited {status}")
    count_tests(b"".join(chunks).splitlines(), expected_roots(args.target, args.artifact))


def main() -> int:
    import guest_process
    import cross_freebsd_arm
    import cross_freebsd_power
    import cross_netbsd
    import cross_openbsd

    drivers = {
        **dict.fromkeys(cross_freebsd_arm.TARGETS, cross_freebsd_arm.run_guest),
        **dict.fromkeys(cross_freebsd_power.TARGETS, cross_freebsd_power.run_guest),
        **dict.fromkeys(cross_netbsd.TARGETS, cross_netbsd.run_guest),
        **dict.fromkeys(cross_openbsd.TARGETS, cross_openbsd.run_guest),
    }
    targets = (*GUESTS, *drivers)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    build = commands.add_parser("build")
    build.add_argument("target", choices=targets)
    build.add_argument("--zig", required=True)
    build.add_argument("--prefix", type=Path, required=True)
    build.add_argument("--cache", type=Path, required=True)
    build.add_argument("--jobs", type=int, required=True)
    build.add_argument("build_args", nargs=argparse.REMAINDER)
    run = commands.add_parser("run")
    run.add_argument("target", choices=targets)
    run.add_argument("artifact", type=Path)
    count = commands.add_parser("count")
    count.add_argument("log", type=Path)
    count.add_argument("--require-manifest", type=Path, default=None)
    args = parser.parse_args()
    try:
        if args.operation == "build":
            if args.build_args[:1] == ["--"]:
                args.build_args = args.build_args[1:]
            build_payload(args)
        elif args.operation == "run":
            if args.target in drivers:
                count_tests(
                    drivers[args.target](args.target, args.artifact).splitlines(),
                    expected_roots(args.target, args.artifact),
                )
            else:
                run_guest(args)
        else:
            required = manifest_roots(args.require_manifest) if args.require_manifest else None
            with args.log.open("rb") as log:
                print(count_tests(log, required))
    except guest_process.Cancelled as error:
        print(f"cross-guest: {error}", file=sys.stderr)
        return 128 + error.signum
    except (GuestFailure, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"cross-guest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
