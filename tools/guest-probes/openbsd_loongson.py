"""Executable boot-chain probes for the OpenBSD guest ports.

Every probe mirrors the whole console to stdout, drives only what the primary
documentation says to drive, and prints one verdict line.  Nothing here is part
of the driver: it exists so a port's boot chain can be shown on its own, with
the failure named, instead of being inferred from a bootstrap that timed out.

    loongson [2e|2f]  PMON booting the release RAMDISK kernel out of an ext2
                      partition of an IDE disk (INSTALL.loongson)
    armv7             U-Boot booting the miniroot media's EFI system partition
                      on QEMU virt (INSTALL.armv7)
    macppc            Open Firmware booting the release HFS volume of the
                      install CD (INSTALL.macppc)
    riscv64           U-Boot booting the install image's EFI system partition
                      (INSTALL.riscv64)

Run one from the same shell the cross tests use, so the pinned assets and
e2fsprogs are on PATH:

    python3 "$TMPDIR/openbsd_loongson.py" loongson 2e
"""

from __future__ import annotations

import contextlib
import os
from pathlib import Path
import struct
import subprocess
import sys
import traceback

import pexpect

INSTALLER = b"(I)nstall, (U)pgrade, (A)utoinstall or (S)hell? "

# Every phase of a boot is bounded: an unanswered prompt is a finding, not a
# machine to wait on.
FIRMWARE = 180
KERNEL = 300


def work_root() -> Path:
    root = Path(os.environ.get("TMPDIR", "/tmp")) / "openbsd-probe"
    root.mkdir(parents=True, exist_ok=True)
    return root


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is unset; run this in the bsd-cross shell")
    return value


def run(command: list[str], stdin: bytes | None = None) -> None:
    subprocess.run(command, check=True, input=stdin)


def verdict(text: str) -> None:
    print(f"ZAP-PROBE {text}", flush=True)


def spawn(command: list[str]):
    child = pexpect.spawn(command[0], command[1:], timeout=FIRMWARE,
                          encoding=None)
    child.logfile_read = sys.stdout.buffer
    return child


def report(child, reached: str, phase: str, detail: str = "") -> None:
    """Say what happened; the transcript above the verdict is the evidence."""
    if not reached:
        with contextlib.suppress(pexpect.ExceptionPexpect):
            child.expect(pexpect.EOF, timeout=60)
    child.close(force=True)
    verdict(reached or f"{phase}: {detail or 'no verdict'}")


# --------------------------------------------------------------------------
# loongson: PMON boots a kernel out of an ext2 partition
# --------------------------------------------------------------------------

def ext2_disk(target: Path, files: dict[str, Path], megabytes: int = 192) -> Path:
    """A disk PMON can boot from: an MBR partition holding an ext2 filesystem.

    PMON names the filesystem by device, not by partition
    (``/dev/fs/ext2@wd0/boot/bsd.rd`` in INSTALL.loongson), and the release
    miniroot puts that filesystem in the first MBR partition, so this image is
    laid out the same way: one partition of type 0x83 starting at sector 63.
    """
    filesystem = target.with_suffix(".ext2")
    if not filesystem.exists():
        run(["mkfs.ext2", "-q", "-F", "-b", "1024", "-I", "128",
             str(filesystem), str(megabytes * 1024)])
    script = "".join(["mkdir /boot\n"]
                     + [f"write {origin} {name}\n"
                        for name, origin in files.items()])
    run(["debugfs", "-w", "-f", "-", str(filesystem)], script.encode())

    start = 63
    with filesystem.open("rb") as payload, target.open("wb") as disk:
        disk.truncate(start * 512)
        disk.seek(start * 512)
        while chunk := payload.read(1 << 20):
            disk.write(chunk)
        size = disk.tell()
    # boot flag, CHS start, type 0x83 (Linux), CHS end, then the LBA extent.
    entry = bytes([0x00, 0x00, 0x02, 0x00, 0x83, 0xFE, 0xFF, 0xFF])
    entry += struct.pack("<II", start, (size // 512) - start)
    mbr = bytearray(512)
    mbr[446:462] = entry
    mbr[510:512] = b"\x55\xaa"
    with target.open("r+b") as disk:
        disk.seek(0)
        disk.write(bytes(mbr))
    return target


def pmon(child, command_line: bytes, timeout: int = 60) -> None:
    """Type one command at PMON's prompt and wait for the next one."""
    child.send(command_line + b"\r")
    child.expect(b"PMON>", timeout=timeout)


def loongson(cpu: str = "2e") -> None:
    model = f"Loongson-{cpu.upper()}"
    work = work_root() / "loongson"
    work.mkdir(exist_ok=True)
    sets = Path(required("CROSS_OPENBSD_LOONGSON_SETS"))
    files = {"/boot/bsd.rd": Path(required("CROSS_OPENBSD_LOONGSON_RD"))}
    for name in ("boot", "bsd"):
        origin = sets / name
        if origin.is_file():
            files[f"/boot/{name}"] = origin
    # boot.cfg is the stanza the bootloader reads for the kernel path;
    # INSTALL.loongson publishes exactly this one.
    cfg = work / "boot.cfg"
    cfg.write_text('title OpenBSD\nkernel /dev/fs/ext2@wd0/boot/boot\nargs ""\n',
                   encoding="ascii")
    files["/boot/boot.cfg"] = cfg
    disk = ext2_disk(work / "pmon.img", files)

    command = ["qemu-system-mips64el", "-machine", "fuloong2e",
               "-cpu", model, "-m", "256", "-smp", "1",
               "-bios", required("CROSS_PMON_2E"),
               "-nographic", "-monitor", "none", "-no-reboot", "-nic", "none",
               "-drive", f"file={disk},format=raw,if=ide,index=0,media=disk"]
    print(f"ZAP-PROBE command {' '.join(command)}", flush=True)
    child = spawn(command)
    reached = ""
    detail = ""
    try:
        # PMON prints its banner, then either its boot menu or its prompt.
        child.expect([b"PMON>", b"Press", pexpect.TIMEOUT], timeout=FIRMWARE)
        if child.after == pexpect.TIMEOUT:
            raise pexpect.TIMEOUT("no PMON prompt and no boot menu")
        # moresz keeps PMON from pausing on its own scrollback, and the boot
        # menu would otherwise take the keyboard the boot command needs.
        pmon(child, b"set moresz 30")
        pmon(child, b"set ShowBootMenu no")
        child.send(b"boot -k /dev/fs/ext2@wd0/boot/bsd.rd\r")
        child.expect([INSTALLER, b"Error", b"not found", b"PMON>"],
                     timeout=KERNEL)
        if child.after == INSTALLER:
            reached = f"loongson {model} installer prompt reached"
        else:
            detail = f"PMON answered {child.after!r}"
    except pexpect.ExceptionPexpect as error:
        detail = str(error)
    report(child, reached, f"loongson {model}", detail)


# --------------------------------------------------------------------------
# U-Boot ports: riscv64 and armv7
# --------------------------------------------------------------------------

def uboot_probe(phase: str, command: list[str], payload: str, scan: str,
                device: int) -> None:
    print(f"ZAP-PROBE command {' '.join(command)}", flush=True)
    child = spawn(command)
    reached = ""
    detail = ""
    try:
        child.expect_exact(b"Hit any key to stop autoboot:", timeout=FIRMWARE)
        child.send(b" ")
        child.expect_exact(b"=> ", timeout=FIRMWARE)
        # The root disk is the first device and the media the second; the media
        # publishes the loader in the first partition of its own layout.
        for line in (f"{scan} scan",
                     f"fatload {scan} {device}:1 ${{kernel_addr_r}} {payload}"):
            child.send(line.encode() + b"\r")
            child.expect_exact(b"=> ", timeout=FIRMWARE)
        child.send(b"bootefi ${kernel_addr_r} ${fdtcontroladdr}\r")
        child.expect_exact(b"boot> ", timeout=FIRMWARE)
        child.send(b"boot\r")
        child.expect([INSTALLER, pexpect.TIMEOUT], timeout=KERNEL)
        if child.after == INSTALLER:
            reached = f"{phase} installer prompt reached"
        else:
            detail = "the loader handed over without reaching the installer"
    except pexpect.ExceptionPexpect as error:
        detail = str(error)
    report(child, reached, phase, detail)


def blank_disk(work: Path) -> Path:
    disk = work / "root.qcow2"
    if not disk.exists():
        run(["qemu-img", "create", "-q", "-f", "qcow2", str(disk), "6G"])
    return disk


def armv7() -> None:
    work = work_root() / "armv7"
    work.mkdir(exist_ok=True)
    disk = blank_disk(work)
    command = ["qemu-system-arm", "-machine", "virt", "-cpu", "cortex-a15",
               "-accel", "tcg", "-m", "2048", "-smp", "1", "-nographic",
               "-monitor", "none", "-no-reboot", "-nic", "none",
               "-bios", required("CROSS_UBOOT_ARM"),
               "-drive", f"file={disk},format=qcow2,if=none,id=root,snapshot=on",
               "-device", "virtio-blk-device,drive=root",
               "-drive", "file=" + required("CROSS_OPENBSD_ARMV7_IMG")
                         + ",format=raw,if=none,id=media,snapshot=on",
               "-device", "virtio-blk-device,drive=media"]
    uboot_probe("armv7", command, "/efi/boot/bootarm.efi", "virtio", 1)


def riscv64() -> None:
    work = work_root() / "riscv64"
    work.mkdir(exist_ok=True)
    disk = blank_disk(work)
    command = ["qemu-system-riscv64", "-machine", "virt,acpi=off",
               "-cpu", "rv64", "-accel", "tcg", "-m", "2048", "-smp", "2",
               "-nographic", "-monitor", "none", "-no-reboot", "-nic", "none",
               "-kernel", required("CROSS_UBOOT_RISCV64"),
               "-device", "ich9-ahci,id=sata",
               "-drive", f"file={disk},format=qcow2,if=none,id=root,snapshot=on",
               "-device", "ide-hd,drive=root,bus=sata.0",
               "-drive", "file=" + required("CROSS_OPENBSD_RISCV64_IMG")
                         + ",format=raw,if=none,id=media,snapshot=on",
               "-device", "ide-hd,drive=media,bus=sata.5"]
    uboot_probe("riscv64", command, "/efi/boot/bootriscv64.efi", "scsi", 1)


# --------------------------------------------------------------------------
# macppc: Open Firmware boots the release HFS volume of the install CD
# --------------------------------------------------------------------------

def macppc() -> None:
    work = work_root() / "macppc"
    work.mkdir(exist_ok=True)
    disk = blank_disk(work)
    command = ["qemu-system-ppc", "-machine", "mac99", "-cpu", "G4",
               "-accel", "tcg", "-m", "2048", "-smp", "1", "-nographic",
               "-monitor", "none", "-no-reboot",
               "-drive", f"file={disk},format=qcow2,if=ide,index=0,media=disk",
               "-drive", "file=" + required("CROSS_OPENBSD_MACPPC_ISO")
                         + ",format=raw,if=ide,index=1,media=cdrom,readonly=on"]
    print(f"ZAP-PROBE command {' '.join(command)}", flush=True)
    child = spawn(command)
    reached = ""
    detail = ""
    try:
        # OpenBIOS boots nothing by itself here, so INSTALL.macppc's command is
        # typed at its prompt; the second form is for a firmware that refuses
        # the kernel argument.
        index = child.expect([b"boot> ", b"0 > "], timeout=FIRMWARE)
        for line in ("boot cd:,ofwboot /7.8/macppc/bsd.rd", "boot cd:,ofwboot"):
            if index == 0:
                break
            child.send(f"{line}\n".encode())
            index = child.expect([b"boot> ", b"0 > "], timeout=FIRMWARE)
        if index != 0:
            raise pexpect.TIMEOUT("Open Firmware did not start the loader")
        child.send(b"set tty com0\r")
        child.expect_exact(b"boot> ", timeout=FIRMWARE)
        child.send(b"boot /7.8/macppc/bsd.rd\r")
        child.expect([INSTALLER, pexpect.TIMEOUT], timeout=KERNEL)
        if child.after == INSTALLER:
            reached = "macppc installer prompt reached"
        else:
            detail = "the loader handed over without reaching the installer"
    except pexpect.ExceptionPexpect as error:
        detail = str(error)
    report(child, reached, "macppc", detail)


def main(argv: list[str]) -> int:
    probes = {"armv7": armv7, "macppc": macppc, "riscv64": riscv64}
    if len(argv) < 2 or argv[1] not in ("loongson", *probes):
        print(__doc__)
        return 2
    try:
        if argv[1] == "loongson":
            loongson(argv[2] if len(argv) > 2 else "2e")
        else:
            probes[argv[1]]()
    except Exception:  # the transcript above is the evidence
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))