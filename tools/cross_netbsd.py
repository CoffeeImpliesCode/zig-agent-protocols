"""Execute the complete Zig test suite in isolated NetBSD guests.

Each port is described by two things: a local mirror of the NetBSD release
tree, named by the environment variable in ``GUESTS``, and how the guest
reaches a root filesystem. ``pkgs.fetchurl`` derivations declared in
``devenv.nix`` supply the mirror; nothing here downloads anything at run
time, and anita's own download layer only ever resolves ``file://`` URLs into
that mirror.

The guest is driven by anita 2.18 as a library. A port that ships a root disk
image gets that image decompressed (or copied, when the pin is already raw)
into a private ``wd0.img``, and anita runs with ``no_install=True`` so its
``start_boot`` never calls ``install()`` and never reaches
``Version.download()``. A port that does not is installed once by anita's own
sysinst driver against the mirror, which installs exactly the sets the port
pins, and the installed disk is cached and reused. Either way the suite
itself always runs against a disk opened with ``snapshot=on``, so a cached
image is never written by a test run.

Two ports publish no root disk image at all. Those get one this driver
assembles from the official kernel, base and etc sets, carrying the device
nodes the port's own MAKEDEV names, and it boots as a whole disk with no
disklabel. A port whose disk is an SD card gets its published copy padded up
to the next power of two, because QEMU's SD model takes nothing else.

QEMU is always started with ``-nic none``. After the login prompt everything
is a real console: the payload ISO is mounted read-only at
``/home/cross-data``, ``/home/cross-scratch`` is the writable working
directory the suite needs because the payload is read-only, and the raw
console bytes are streamed to stdout as they arrive and returned whole. The
suite does not halt the guest; this driver owns the shutdown, and the caller
validates the receipt.
"""

from __future__ import annotations

import argparse
import gzip
import guest_process
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import guest_storage
from dataclasses import dataclass
from types import ModuleType

RELEASE = "11.0"

# The NetBSD triples this driver executes, named exactly as the caller builds
# them.
TARGETS: tuple[str, ...] = ("x86_64-netbsd", "aarch64-netbsd", "aarch64_be-netbsd",
                            "x86-netbsd", "arm-netbsd", "armeb-netbsd", "powerpc-netbsd",
                            "mips-netbsd", "mipsel-netbsd")


# The built-root recipe. This driver assembles a root filesystem for the ports
# that publish no root disk image, and this number is what tells an entry
# cached by one recipe from an entry built by the next.
ROOT_RECIPE = 9

# Two gigabytes in bytes. This makefs takes -s as a plain byte count: a suffixed
# value such as 2g is rejected with "illegal number".
ROOT_BYTES = 2 * 1024 * 1024 * 1024

# The whole-disk device of the ports whose root this driver builds. It is where
# their root filesystem lives, and what both the kernel and /etc/fstab open to
# mount it. A port's own MAKEDEV gives the whole disk of a unit the minor
# number its makedisk_p16() uses for ro and so names that device wd0, block,
# and rwd0, raw; nothing here assumes a minor number of its own.
ROOT_DEVICE = "wd0"

# Where a NetBSD port's etc set installs its device list in the root, and so
# where the tree this driver unpacks those sets into holds it. The list is a
# /bin/sh script rather than data, so it is read from the unpacked set and
# never from the archive the set came in: an archive is a gzip stream, not
# text. Some ports install the script here and others a link to the copy under
# /etc, and both resolve to the script the port ships.
DEVICE_SCRIPT = "dev/MAKEDEV"

# The release-tree directory anita reads a distribution's sets from, which is
# what tells a set a port pins apart from the other files it pins.
SETS_DIR = "binary/sets"

# QEMU's SD card model takes a power of two capacity and nothing else, and the
# release's armv7 images are not one, so a port that boots its disk as an SD
# card gets a copy rounded up to the next power of two. This number is what
# tells a padded cache entry from an unpadded one.
SD_PADDING = 1

# The disk anita installs a system onto when a port publishes no root image.
# A sparse file costs nothing until sysinst writes to it, and eight gigabytes
# is the size NetBSD's own amd64 and i386 images use; anita's two gigabytes do
# not hold the six sets a standard installation unpacks, and sysinst fills the
# disk part-way through the 481 MiB comp set. Neither value reaches a port that
# comes with a root image, because anita creates no disk for those.
INSTALL_DISK_SIZE = "8G"
INSTALL_DISK_FORMAT = "sparse"

# What a port's own bootloader prints while it is being told what to boot, and
# what a getty asks the terminal before it prompts. The loader strings are read
# out of the amd64 live image this driver boots; every key is sent only once
# the guest has asked for it, because the guest takes them from a 16-byte
# serial FIFO that drops whatever it has not picked up yet.
LOADER_MENU = "Choose an option"
LOADER_OPTION = r"Option: \["
LOADER_PROMPT_OPTION = "3"
LOADER_COMMAND_PROMPT = r"> "
# The terminal queries a getty sends before it prompts, and the answers to
# them: a getty that is asked and not answered waits instead of prompting.
TERMINAL_QUERIES = (r"\033\[c", r"\033\[5n", r"login:")


@dataclass(frozen=True)
class Guest:
    """One NetBSD port, the pinned files that realise it, and its guest disk.

    Each field names one environment variable holding one pinned file, next to
    the path that file occupies in the NetBSD release tree. anita derives the
    port from a local mirror of that tree, so the tree paths are what make the
    pins auditable against the release manifests.
    """

    port: str
    """NetBSD port directory name, which is also the anita distribution key."""

    emulator: str
    memory: str
    disk: str | None
    """Pinned root disk image, or None to let anita install one."""

    disk_member: str | None
    """Release-tree path of that image."""

    gzipped: bool
    """Whether the pinned disk file still has to be decompressed."""

    kernel: str | None = None
    kernel_member: str | None = None
    """Pinned kernel anita unzips and passes to -kernel, and its tree path."""

    boot_from: str | None = None
    """anita's install-medium selector, for a port that needs installing."""

    assets: tuple[tuple[str, str], ...] = ()
    """``(environment variable, release-tree path)`` for an install's media."""

    root_sets: tuple[tuple[str, str], ...] = ()
    """Sets unpacked into an FFS root this driver builds for the port."""

    image_name: str | None = None
    """Release name to record in anita's port table, where it differs."""

    machine_args: tuple[str, ...] = ()
    """Emulator arguments for a port anita has no recipe of its own for."""

    dtb: str | None = None
    """Pinned device tree for the machine anita boots this port on."""

    wire_disk: bool = False
    """Whether this port's disk needs a controller anita does not attach."""

    sd_card: bool = False
    """Whether this port's disk is an SD card, which takes a power of two."""

    loader_console: str | None = None
    """Console the port's own bootloader has to give the kernel."""

    payload: str = "cdrom"
    """QEMU media type for the payload drive."""

    endian: str | None = None
    """Filesystem byte order, when the host's does not match the guest's."""


GUESTS: dict[str, Guest] = {
    # NetBSD ships no gzimg for amd64; the live image is the amd64 root
    # filesystem. It carries an MBR and a protective GPT and an FFS2 first
    # stage, so the pc machine's BIOS boots it and anita adds no -kernel. The
    # release publishes it under images/11.0/; NetBSD's own build installs it
    # at this path in the port tree (LIVEIMG_RELEASEDIR in
    # distrib/amd64/liveimage/Makefile.liveimage).
    #
    # It is also the one port whose own bootloader runs before the kernel: its
    # /boot/boot.cfg shows a three-entry menu and starts the first entry after
    # a countdown, and its root is the GPT wedge its /etc/fstab names
    # (NAME=NBImgRoot). The kernel takes its console from that loader, which
    # does not pick the serial one, so the driver names it there; see
    # loader_console and _boot_through_loader.
    "x86_64-netbsd": Guest(
        port="amd64",
        emulator="qemu-system-x86_64",
        memory="2048M",
        disk="CROSS_NETBSD_AMD64_LIVE_GZ",
        disk_member="installation/liveimage/NetBSD-11.0-amd64-live.img.gz",
        gzipped=True,
        loader_console="com0",
    ),
    # evbarm-aarch64 ships a GPT gzimg and an MBR one. The MBR one is the one
    # this driver uses, because the MBR root-device selection is the path
    # anita already implements. Its pin arrives already decompressed, since
    # the only digest the release publishes for this image is keyed to the
    # uncompressed name. The kernel is gzip-compressed and anita unzips it.
    "aarch64-netbsd": Guest(
        port="evbarm-aarch64",
        emulator="qemu-system-aarch64",
        memory="2048M",
        disk="CROSS_NETBSD_AARCH64_RAW",
        disk_member="binary/gzimg/arm64mbr.img",
        gzipped=False,
        kernel="CROSS_NETBSD_AARCH64_KERNEL_GZ",
        kernel_member="binary/kernel/netbsd-GENERIC64.img.gz",
        image_name="arm64mbr.img.gz",
    ),

    # NetBSD publishes no i386 root image, so anita's own sysinst driver
    # installs one. These are the six sets an installed system runs the suite
    # on, and naming them is what anita puts on the install medium and tells
    # sysinst to select, so the graphics firmware, recovery tools and test
    # programs its own table would add are neither offered nor extracted.
    # The boot CD is the seventh pin: anita's default for i386 is the floppy,
    # and boot_from picks the single CD instead of the seven floppy images.
    "x86-netbsd": Guest(
        port="i386",
        emulator="qemu-system-i386",
        memory="2048M",
        disk=None,
        disk_member=None,
        gzipped=False,
        boot_from="cdrom",
        assets=(
            ("CROSS_NETBSD_I386_BOOT_COM_ISO", "installation/cdrom/boot-com.iso"),
            ("CROSS_NETBSD_I386_BASE_TGZ", "binary/sets/base.tgz"),
            ("CROSS_NETBSD_I386_ETC_TGZ", "binary/sets/etc.tgz"),
            ("CROSS_NETBSD_I386_COMP_TGZ", "binary/sets/comp.tgz"),
            ("CROSS_NETBSD_I386_MISC_TGZ", "binary/sets/misc.tgz"),
            ("CROSS_NETBSD_I386_MODULES_TGZ", "binary/sets/modules.tgz"),
            ("CROSS_NETBSD_I386_KERN_GENERIC_TGZ", "binary/sets/kern-GENERIC.tgz"),
        ),
    ),

    # evbarm-aarch64eb is the same board and the same QEMU machine as the
    # little-endian port and differs only in the kernel the guest runs, so the
    # machine is stated here rather than borrowed from anita's little-endian
    # recipe. The CPU is the same 64-bit ARM CPU anita selects for the
    # little-endian port; nothing here chooses an endianness. anita supplies
    # -kernel from the port entry _register installs, and -append names the MBR
    # root device anita's own root selection would have chosen.
    "aarch64_be-netbsd": Guest(
        port="evbarm-aarch64eb",
        emulator="qemu-system-aarch64",
        memory="2048M",
        disk="CROSS_NETBSD_AARCH64EB_RAW",
        disk_member="binary/gzimg/arm64mbr.img",
        gzipped=False,
        kernel="CROSS_NETBSD_AARCH64EB_KERNEL_GZ",
        kernel_member="binary/kernel/netbsd-GENERIC64.img.gz",
        machine_args=("-M", "virt", "-cpu", "cortex-a57", "-append", "root=ld4a"),
    ),
    # evbarm-earmv7hf is a port anita already knows how to drive: it pairs the
    # armv7 gzimg with the vexpress-a15 machine, wires the disk onto that
    # machine's SD controller and selects the MBR root device. The device tree
    # is the one input anita takes from its caller, and anita's own test suite
    # pairs this board with the vexpress-v2p-ca15-tc1 tree.
    "arm-netbsd": Guest(
        port="evbarm-earmv7hf",
        emulator="qemu-system-arm",
        memory="2048M",
        disk="CROSS_NETBSD_ARMV7HF_RAW",
        disk_member="binary/gzimg/armv7.img",
        gzipped=False,
        kernel="CROSS_NETBSD_ARMV7HF_KERNEL_GZ",
        kernel_member="binary/kernel/netbsd-GENERIC.ub.gz",
        dtb="CROSS_NETBSD_ARMV7HF_DTB",
        sd_card=True,
    ),
    # evbarm-earmv7hfeb is the same board and machine as evbarm-earmv7hf and
    # differs only in the kernel the guest runs. anita ships no recipe for it,
    # so the machine, the SD-attached disk and the device tree are stated here;
    # anita contributes the -kernel from the port entry _register installs.
    "armeb-netbsd": Guest(
        port="evbarm-earmv7hfeb",
        emulator="qemu-system-arm",
        memory="2048M",
        disk="CROSS_NETBSD_ARMV7HFEB_RAW",
        disk_member="binary/gzimg/armv7.img",
        gzipped=False,
        kernel="CROSS_NETBSD_ARMV7HFEB_KERNEL_GZ",
        kernel_member="binary/kernel/netbsd-GENERIC.ub.gz",
        machine_args=("-M", "vexpress-a15", "-append", "root=ld0a"),
        dtb="CROSS_NETBSD_ARMV7HF_DTB",
        wire_disk=True,
        sd_card=True,
    ),
    # macppc installs through anita's sysinst driver like i386 does, and needs
    # two more files from the release tree: the kernel it installs from and the
    # kernel it boots the finished system with, which anita puts on a second CD
    # of its own making. The payload rides as a plain read-only disk here,
    # because anita pins that runtime CD to index 2 and a second CD cannot
    # share the index. The guest gets a gigabyte of memory rather than two: the
    # 32-bit OpenFirmware on this machine dies in oea_startup() reserving its
    # deadzone once the machine holds two gigabytes, which is where it failed.
    "powerpc-netbsd": Guest(
        port="macppc",
        emulator="qemu-system-ppc",
        memory="1024M",
        disk=None,
        disk_member=None,
        gzipped=False,
        payload="disk",
        assets=(
            ("CROSS_NETBSD_MACPPC_BASE_TGZ", "binary/sets/base.tgz"),
            ("CROSS_NETBSD_MACPPC_ETC_TGZ", "binary/sets/etc.tgz"),
            ("CROSS_NETBSD_MACPPC_COMP_TGZ", "binary/sets/comp.tgz"),
            ("CROSS_NETBSD_MACPPC_MISC_TGZ", "binary/sets/misc.tgz"),
            ("CROSS_NETBSD_MACPPC_MODULES_TGZ", "binary/sets/modules.tgz"),
            ("CROSS_NETBSD_MACPPC_KERN_GENERIC_TGZ", "binary/sets/kern-GENERIC.tgz"),
            ("CROSS_NETBSD_MACPPC_INSTALL_KERNEL_GZ", "binary/kernel/netbsd-INSTALL.gz"),
            ("CROSS_NETBSD_MACPPC_GENERIC_KERNEL_GZ", "binary/kernel/netbsd-GENERIC.gz"),
        ),
    ),
    # NetBSD publishes no root disk image for evbmips and anita ships no
    # installer for it, so the root this driver boots is an FFS filesystem it
    # assembles from the official kernel, base and etc sets, which the kernel
    # then mounts as a whole disk. Malta is the board this port officially
    # supports for MIPS32. qemu-system-mips is its big-endian machine and
    # qemu-system-mipsel the little-endian one; nothing here chooses an
    # endianness, the emulator binary does.
    "mips-netbsd": Guest(
        port="evbmips-mipseb",
        emulator="qemu-system-mips",
        memory="2048M",
        disk=None,
        disk_member=None,
        gzipped=False,
        kernel="CROSS_NETBSD_MIPS_MALTA_KERNEL_GZ",
        kernel_member="binary/kernel/netbsd-MALTA.gz",
        machine_args=("-M", "malta", "-append", f"root={ROOT_DEVICE}"),
        endian="big",
        root_sets=(
            ("CROSS_NETBSD_MIPS_KERN_MALTA_TGZ", "binary/sets/kern-MALTA.tgz"),
            ("CROSS_NETBSD_MIPS_BASE_TGZ", "binary/sets/base.tgz"),
            ("CROSS_NETBSD_MIPS_ETC_TGZ", "binary/sets/etc.tgz"),
        ),
    ),
    "mipsel-netbsd": Guest(
        port="evbmips-mipsel",
        emulator="qemu-system-mipsel",
        memory="2048M",
        disk=None,
        disk_member=None,
        gzipped=False,
        kernel="CROSS_NETBSD_MIPSEL_MALTA_KERNEL_GZ",
        kernel_member="binary/kernel/netbsd-MALTA.gz",
        machine_args=("-M", "malta", "-append", f"root={ROOT_DEVICE}"),
        endian="little",
        root_sets=(
            ("CROSS_NETBSD_MIPSEL_KERN_MALTA_TGZ", "binary/sets/kern-MALTA.tgz"),
            ("CROSS_NETBSD_MIPSEL_BASE_TGZ", "binary/sets/base.tgz"),
            ("CROSS_NETBSD_MIPSEL_ETC_TGZ", "binary/sets/etc.tgz"),
        ),
    ),
}

# Ports whose anita recipe already emits -dtb from the dtb argument, so their
# device tree is handed to anita rather than added to the command line here.
ANITA_DTB_PORTS = frozenset({"evbarm-earmv7hf"})

# Bounds on how long one console expect may go unmatched. The caller owns the
# outer bound; these keep a silent guest from holding the run open forever.
BOOT_TIMEOUT = 3600
MOUNT_TIMEOUT = 600
SUITE_TIMEOUT = 5400
# The suite prints these between roots and inside them. Matching one of them
# resets the expect timeout, so SUITE_TIMEOUT is an inactivity bound rather
# than a bound on the whole run.
KEEPALIVE = (r"ZAP_GUEST_BEGIN ", r"All [0-9]+ tests passed\.",
             r"[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed\.")

# Written into the guest's scratch directory and then run on its own, so a
# mount failure is distinguishable from a shell failure. The payload is the
# only cd9660 volume in the guest, and how QEMU wired its drive differs per
# machine: it can be a CD-ROM, or a plain read-only disk, and it lands on
# whichever controller that machine has. So every block device the guest has
# is tried, read-only, and the one that mounts is the payload; anything else
# is a plain ENOENT, ENXIO or ENOTFS from a device that was never a CD, and a
# guest that mounts nothing says so and stops. The candidates are the device
# nodes themselves rather than the kernel's disk list: kern.disks is a sysctl
# node on this release, and asking a node for its value fails.
MOUNT_SCRIPT = """mkdir -p /home/cross-scratch /home/cross-data
chmod 700 /home/cross-scratch
cat > /home/cross-scratch/zap-payload.sh <<'ZAP_PAYLOAD_EOF'
set -u
payload=
for dev in /dev/cd* /dev/virtio* /dev/sd* /dev/wd* /dev/fd* /dev/ld* /dev/dk*; do
    [ -e "$dev" ] || continue
    if [ -z "$payload" ] && /sbin/mount -t cd9660 -o ro "$dev" /home/cross-data 2>/dev/null; then
        payload="$dev"
    fi
done
if [ -z "$payload" ]; then
    echo "ZAP_GUEST_SETUP_FAILED no cd9660 payload among /dev/cd* /dev/virtio* /dev/sd* /dev/wd* /dev/fd* /dev/ld* /dev/dk*"
    exit 1
fi
echo "ZAP-NETBSD payload $payload"
ZAP_PAYLOAD_EOF"""

SUITE_COMMAND = "/bin/sh /home/cross-data/suite.sh"


class GuestFailure(RuntimeError):
    """A NetBSD guest did not boot, or did not deliver a runnable suite."""


class Receipt:
    """The raw console, written to stdout as it arrives and kept whole."""

    def __init__(self) -> None:
        self.data = bytearray()

    def write(self, chunk: bytes) -> None:
        self.data += chunk
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

    def flush(self) -> None:
        sys.stdout.buffer.flush()


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


def _tree(guest: Guest) -> dict[str, Path]:
    """Resolve a port's pins into release-tree paths and pinned files.

    The pinned file names go into the cache key, so a changed pin lands in a
    new cache directory instead of reusing the image the old pin produced.
    """
    pins = [(guest.disk_member, guest.disk), (guest.kernel_member, guest.kernel)]
    pins += [(member, variable) for variable, member in guest.assets]
    pins += [(member, variable) for variable, member in guest.root_sets]
    tree: dict[str, Path] = {}
    for member, variable in pins:
        if member is None or variable is None:
            continue
        source = Path(_require(variable))
        if not source.is_file():
            raise GuestFailure(f"{variable} names {source}, which is not a file")
        tree[member] = source
    if not tree:
        raise GuestFailure(f"{guest.port} has no pinned assets")
    for member, variable in ((guest.disk_member, guest.disk),
                             (guest.kernel_member, guest.kernel)):
        if variable is not None and member not in tree:
            raise GuestFailure(f"{variable} is not a pinned {guest.port} asset")
    return tree


def _publish(source: Path, destination: Path, gzipped: bool,
             pad: bool = False) -> None:
    """Put a pinned file in the work directory once, under the caller's lock.

    The caller holds an exclusive lock on the cache, so a second caller sees
    either no file or the finished one, never a half-written disk. A padded
    file is grown to the next power of two with zeros, which is all the SD card
    model asks for: the partition table and every filesystem in the image keep
    the offsets the release gave them.
    """
    if destination.is_file():
        return
    with guest_storage.temporary_directory(prefix="netbsd-", dir=destination.parent) as scratch:
        staged = Path(scratch) / destination.name
        if gzipped:
            with gzip.open(source, "rb") as compressed, staged.open("wb") as output:
                shutil.copyfileobj(compressed, output, 1024 * 1024)
        else:
            shutil.copyfile(source, staged)
        if pad:
            os.truncate(staged, 1 << (staged.stat().st_size - 1).bit_length())
        staged.chmod(0o444)
        guest_storage.publish(staged, destination)


def _host_bin() -> Path:
    """Return a directory holding the two commands the port's MAKEDEV runs.

    MAKEDEV sets its own PATH to NetBSD directories that do not exist here, so
    the runnable copy of it is given a host directory instead. It only ever
    calls cat and mkdir, so any directory holding both will do, and the
    caller's PATH is tried first because the pinned profiles put them on it.
    """
    candidates = [os.path.dirname(found) for found in
                  (shutil.which(tool) for tool in ("cat", "mkdir")) if found]
    candidates += ["/usr/bin", "/bin"]
    for directory in candidates:
        if all(os.access(os.path.join(directory, tool), os.X_OK)
               for tool in ("cat", "mkdir")):
            return Path(directory)
    raise GuestFailure("MAKEDEV runs cat and mkdir, which are on neither PATH "
                       "nor /usr/bin or /bin")


def _device_spec(stage: Path, scratch: Path) -> Path:
    """Ask the port's own MAKEDEV for an mtree spec of every device it names.

    The device list is the /bin/sh script the etc set installs at
    /dev/MAKEDEV, and the root sets are already unpacked into the staging tree
    the image is built from, so the script that answers is the one the port
    ships rather than a table carried here: an archive the set came in is a
    gzip stream, and reading it as the script it holds fails on its header.

    MAKEDEV -s writes the spec instead of creating anything, so it needs no
    mknod and no privilege: it is the only way to obtain these numbers in this
    environment. The spec covers the whole node set rather than a hand-picked
    few, so the root holds every device init and login ask for, and it has to
    name the whole-disk block device the fstab mounts as root, because that
    device is where the root filesystem lives and nothing else in the recipe
    may disagree about it.

    The runnable copy of the script and the spec it writes both go to the
    build's scratch directory rather than to the staging tree, since makefs
    copies the staging tree into the image and neither file belongs in it.
    """
    makedev = stage / DEVICE_SCRIPT
    if not makedev.is_file():
        raise GuestFailure(f"the unpacked root sets hold no {DEVICE_SCRIPT}, so "
                           "its device numbers are unknown and the image would "
                           "carry no device nodes at all")
    runnable = scratch / "MAKEDEV.run"
    runnable.write_text(
        "".join(f"\tPATH={_host_bin()}\n" if line.startswith("\tPATH=") else line
                for line in makedev.read_text(encoding="ascii").splitlines(keepends=True)),
        encoding="ascii")
    runnable.chmod(0o700)
    spec = scratch / "devices.mtree"
    with spec.open("w", encoding="ascii") as output:
        subprocess.run(["sh", str(runnable), "-s", "all"],
                       cwd=makedev.parent, stdout=output, check=True)
    entries = spec.read_text(encoding="ascii").splitlines()
    if not any("device=netbsd" in line for line in entries):
        raise GuestFailure("MAKEDEV -s produced no device entries")
    if not any(line.startswith(f"./{ROOT_DEVICE} ") and "type=block" in line
               for line in entries):
        raise GuestFailure(f"MAKEDEV -s names no {ROOT_DEVICE} block device; "
                           "the fstab mounts it as the root filesystem")
    return spec


def _root_image(guest: Guest, tree: dict[str, Path], cache: Path) -> None:
    """Write an immutable FFS root filesystem from a port's pinned sets.

    NetBSD publishes no root disk image for this port and anita ships no
    installer for it, so the root this driver boots is assembled here from the
    same official sets a sysinst run would unpack.

    The image is one filesystem over the whole disk with no disklabel, which is
    the layout newfs(8) -F describes: the whole-disk device is opened directly,
    so there is no partition and no label for the kernel to read first. It is a
    UFS2 filesystem in the byte order of the machine that has to read it, both
    stated on the command line rather than left to the host's defaults, and -s
    gives it two gigabytes so the suite has scratch room. The blank root
    password comes from the official etc set. Written once, then only ever
    opened with snapshot=on.
    """
    if (cache / "wd0.img").is_file():
        return
    makefs = _require("CROSS_NETBSD_MAKEFS")
    if not os.access(makefs, os.X_OK):
        raise GuestFailure(f"CROSS_NETBSD_MAKEFS names {makefs}, which is not executable")
    _require_mtree(makefs)
    with guest_storage.temporary_directory(prefix="netbsd-root-", dir=cache) as workdir:
        scratch = Path(workdir)
        stage = scratch / "root"
        stage.mkdir()
        for variable, member in guest.root_sets:
            subprocess.run(["tar", "-xf", tree[member], "-C", stage], check=True)
        _configure_root(stage)
        spec = _device_spec(stage, scratch)
        endian = [] if guest.endian is None else ["-B", guest.endian]
        staged = scratch / "wd0.img"
        subprocess.run([makefs, "-t", "ffs", "-s", str(ROOT_BYTES), *endian,
                        "-o", "version=2,bsize=8192",
                        "-F", str(spec), str(staged), str(stage)], check=True)
        staged.chmod(0o444)
        guest_storage.publish(staged, cache / "wd0.img")


def _require_mtree(makefs: str) -> None:
    """Refuse a makefs that cannot create the device nodes the root needs.

    NetBSD mounts no devfs by default and the base set ships only four
    directories under /dev, so the nodes have to be built into the image.
    makefs is the only thing here that can do that, and only through its -F
    mtree option: a build without it would copy the staging directory verbatim
    and produce a root whose /dev holds no devices at all, which boots to
    nothing and looks correct in an image listing.
    """
    usage = subprocess.run([makefs], capture_output=True, text=True, check=False)
    if "-F" not in (usage.stderr + usage.stdout).split("usage:", 1)[-1]:
        raise GuestFailure(
            f"{makefs} cannot take an mtree spec: its usage has no -F option, so "
            "it cannot create the /dev nodes a NetBSD root needs. bsd-cross must "
            "declare a NetBSD makefs, not an OpenBSD or FreeBSD one.")


def _configure_root(stage: Path) -> None:
    """Finish the guest configuration the official etc set leaves open.

    A stock NetBSD /etc is deliberately unconfigured: rc.conf says
    rc_configured=NO so an installer completes it, and the etc set ships no
    fstab at all because the installer writes one. This guest has no
    installer, so all three are stated here: rc.conf is marked configured,
    fstab mounts the root filesystem on the whole-disk device the image was
    built on, and a getty is enabled for the console -nographic gives the
    guest.
    """
    etc = stage / "etc"
    etc.mkdir(parents=True, exist_ok=True)
    rc = etc / "rc.conf"
    text = rc.read_text(encoding="ascii") if rc.is_file() else ""
    text = "\n".join(line for line in text.splitlines()
                      if not line.startswith("rc_configured="))
    rc.write_text(text + "\nrc_configured=YES\ngetty_on_com0=YES\n", encoding="ascii")
    # The image is one filesystem over the whole disk with no disklabel, so it
    # has no partitions: root is the whole-disk device, and a swap partition
    # named here would only make rc's swapon fail at every boot.
    (etc / "fstab").write_text(
        f"# The root filesystem is the whole disk, so root is {ROOT_DEVICE}.\n"
        f"/dev/{ROOT_DEVICE}\t/\tffs\trw\t1\t1\n", encoding="ascii")
    ttys = etc / "ttys"
    if ttys.is_file():
        lines = []
        for line in ttys.read_text(encoding="ascii").splitlines():
            fields = line.split()
            # The set ships every getty off and names the board's real serial
            # ports, so the only change is to enable the console and the first
            # serial line. The names and termios stay as NetBSD wrote them.
            if fields and fields[0] in ("console", "tty00"):
                line = line.replace(" off ", " on ")
            lines.append(line)
        ttys.write_text("\n".join(lines) + "\n", encoding="ascii")


def _install_sets(guest: Guest) -> list[str]:
    """The NetBSD sets a port installs, named by the sets it pins.

    anita's table of a distribution's sets is the union of every set any NetBSD
    release has published, and it installs the ones marked as wanted and leaves
    a ".MISSING" marker wherever the rest are not held: what it leaves behind
    is the graphics firmware, the recovery tools and the test programs, none of
    which a standard installation of a serial-console guest uses. sysinst
    extracts the sets that are on the medium it booted, and a marker in the
    sets directory reads as a set that is there, so the install selects it and
    then stops on it, because a marker is not an archive. Naming the sets
    here keeps both the medium and the selection down to the sets this driver
    pins, which are the ones an installed system runs on: a kernel, the base
    system, the compiler tools, the kernel modules, the miscellaneous files
    and the configuration.
    """
    prefix = f"{SETS_DIR}/"
    sets = sorted(member[len(prefix):-len(".tgz")]
                  for _, member in guest.assets
                  if member.startswith(prefix) and member.endswith(".tgz"))
    if not any(name.startswith("kern-") for name in sets) or \
            not {"base", "etc"} <= set(sets):
        raise GuestFailure(
            f"{guest.port} pins no installable NetBSD sets: a kernel, base and "
            f"etc are what a system runs on, and it pins "
            f"{', '.join(sets) or 'no set at all'}")
    return sets


def prepare(guest: Guest) -> Path:
    """Return the private work directory for a port, fully populated.

    The distribution mirror is rebuilt every run, because it is symlinks and
    because it is what makes the pinned assets auditable by eye against the
    release manifests. The root disk is published once and then only ever
    opened with snapshot=on.
    """
    tree = _tree(guest)
    # The recipe keys the parts of the work directory this driver builds rather
    # than the pins it publishes: the root filesystem for a port that has none
    # to publish, the padding for a port that boots an SD card, and the sets
    # an installed disk is made of.
    recipe = []
    if guest.root_sets:
        recipe.append(f"root-recipe={ROOT_RECIPE}")
    if guest.sd_card:
        recipe.append(f"sd-padding={SD_PADDING}")
    if guest.disk is None and not guest.root_sets:
        recipe.append(f"install-disk={INSTALL_DISK_SIZE}/{INSTALL_DISK_FORMAT}")
        recipe.append(f"install-sets={','.join(_install_sets(guest))}")
    digest = hashlib.sha256("\n".join(
        recipe + [f"{member}={tree[member].name}" for member in sorted(tree)]
    ).encode()).hexdigest()[:16]
    cache = Path(_require("CROSS_GUEST_CACHE")) / f"netbsd-{RELEASE}" / guest.port / digest
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    guest_storage.check_directory(cache)
    with (cache / "lock").open("ab") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for member, source in tree.items():
            link = cache / "dist" / guest.port / member
            link.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            if link.is_symlink() and link.readlink() == source:
                continue
            if link.exists() or link.is_symlink():
                guest_storage.unlink_link(link)
            link.symlink_to(source)
        if guest.disk_member is not None:
            _publish(tree[guest.disk_member], cache / "wd0.img", guest.gzipped,
                     pad=guest.sd_card)
        if guest.root_sets:
            _root_image(guest, tree, cache)
        if guest.kernel_member is not None:
            # anita's actual_kernel() looks for the kernel in the work
            # directory, under the name the release gives it minus the .gz.
            _publish(tree[guest.kernel_member],
                     cache / Path(guest.kernel_member).name[:-3], gzipped=True)
    return cache


def _register(anita: ModuleType, guest: Guest) -> None:
    """Give anita the port entry it requires, and nothing it does not.

    anita refuses a port it has no entry for, and reads two things out of that
    entry: which emulator to run, and the release names of the image and the
    kernel it is booting. Those names are what make anita pass -kernel and look
    the right file up in the work directory. Every other machine-specific
    decision is stated in GUESTS. A port anita already knows keeps anita's own
    entry, apart from the image name where this driver uses the other gzimg.
    """
    table = anita.arch_props
    if guest.port not in table:
        table[guest.port] = {"qemu": {"executable": guest.emulator},
                             "image_name": Path(guest.disk_member or
                                                guest.kernel_member).name,
                             "kernel_name": [Path(guest.kernel_member).name]}
    elif guest.image_name is not None:
        table[guest.port]["image_name"] = guest.image_name


def _extras(guest: Guest, workdir: Path) -> list[str]:
    """Emulator arguments for a port anita has no complete recipe of its own for.

    anita keys most of its machine wiring on the literal port names it ships, so
    a port it does not know would get a disk with no controller attached, no
    device tree and no root device. Those three facts are stated here instead.
    """
    extras = list(guest.machine_args)
    if guest.dtb is not None and guest.port not in ANITA_DTB_PORTS:
        extras += ["-dtb", str(Path(_require(guest.dtb)))]
    if guest.wire_disk:
        extras += ["-drive",
                   f"file={workdir / 'wd0.img'},format=raw,media=disk,if=sd,snapshot=on"]
    return extras


def _payload(guest: Guest, machine, artifact: str) -> list[str]:
    """Attach the payload ISO, as a CD unless this port has no index left.

    macppc is the exception: anita pins the CD it builds to boot the installed
    system to index 2, and a second CD cannot share that index. The payload
    rides as a read-only disk instead, which the same cd9660 lookup finds.
    """
    if guest.payload == "cdrom":
        return list(machine.qemu_add_cdrom(artifact)[0])
    return ["-drive", f"file={artifact},format=raw,media=disk,readonly=on"]


def _machine(guest: Guest, workdir: Path, anita: ModuleType):
    """Build the anita instance for a port, with its console captured later.

    The disk size and format only reach a port anita installs a system onto,
    because anita creates that disk itself and ignores both where the work
    directory already holds the image.

    A port anita installs is given the sets it pins, which is the one place
    anita takes an installation's shape from: it downloads them, and it marks
    the sets of its own table for selection, from the same list. A port that
    publishes its own disk is installed by nothing, and anita would refuse a
    set list with no kernel set in it, so it is given none.
    """
    if shutil.which(guest.emulator) is None:
        raise GuestFailure(f"{guest.emulator} is not on PATH")
    _register(anita, guest)
    selection = {"sets": _install_sets(guest)} if guest.assets else {}
    machine = anita.Anita(
        dist=anita.distribution(f"{workdir / 'dist' / guest.port}/", **selection),
        workdir=str(workdir),
        vmm="qemu",
        vmm_args=["-nic", "none"],
        memory_size=guest.memory,
        disk_size=INSTALL_DISK_SIZE,
        image_format=INSTALL_DISK_FORMAT,
        boot_from=guest.boot_from,
        persist=False,
        no_install=guest.disk is not None or bool(guest.root_sets),
        dtb=None if guest.dtb is None else str(Path(_require(guest.dtb))),
    )
    if guest.wire_disk:
        # This port attaches its disk itself, on a controller anita does not
        # wire. anita's own attachment is dropped rather than left in place,
        # because it points at the same image: with both, the guest finds the
        # one disk twice and neither copy is the root device it was promised.
        machine.qemu_disk_args = lambda *args, **kwargs: []
    return machine


def _boot_through_loader(machine, guest: Guest, workdir: Path,
                         payload: list[str]) -> None:
    """Boot a port whose own bootloader has to name the kernel's console.

    anita's boot() starts the emulator and waits for the login prompt in one
    call, which leaves no room for a conversation with a bootloader in
    between. A port that boots through one needs that room, because the
    console that bootloader picks for itself is not the serial one this driver
    reads: the kernel then prints nothing at all, and its getty, which follows
    that console, prompts where nobody is looking.

    The port's boot.cfg puts a menu on screen and starts its first entry after
    a countdown; the third entry drops to the loader's prompt, where the
    console can be named and the boot started. The loader's own help reads
    `consdev {pc|com[0123][,{speed}]|com,{ioport}[,{speed}]}`, and the value
    given there is what the kernel gets as its console.
    """
    machine.dist.set_workdir(machine.workdir)
    machine.start_boot([*_extras(guest, workdir), *payload])
    child = machine.child
    child.expect(LOADER_MENU, timeout=BOOT_TIMEOUT)
    child.send(" ")
    child.expect(LOADER_OPTION, timeout=BOOT_TIMEOUT)
    child.send(f"{LOADER_PROMPT_OPTION}\r")
    child.expect(LOADER_COMMAND_PROMPT, timeout=BOOT_TIMEOUT)
    child.send(f"consdev {guest.loader_console}\r")
    child.expect(LOADER_COMMAND_PROMPT, timeout=BOOT_TIMEOUT)
    child.send("boot\r")
    _wait_for_login(child)


def _wait_for_login(child) -> None:
    """Wait for the login prompt, answering the queries the getty sends first."""
    while True:
        index = child.expect(list(TERMINAL_QUERIES))
        if index == 0:
            child.send("\033[?1;2c")
        elif index == 1:
            child.send("\033[0n")
        else:
            return


def _hold_on_configure_child(machine, guard: guest_process.Guard, label: str,
                             held: list) -> None:
    """Adopt every emulator anita starts, the moment its console exists.

    anita forks the machine inside its own `start_*` calls, and each of them
    hands the new console to `configure_child` before it returns it. That one
    method is the only seam every emulator passes through, and it is the one
    that has to be hooked to cover an installation: anita's sysinst driver
    calls `start_qemu` itself and never comes back through `start_boot`, so a
    wrapper on `start_boot` alone holds the runtime emulator and leaves the
    installer's unheld — and anita closes the installer's console itself when
    the install is over. That close is `PtyProcess.close(force=True)`, which
    hangs up the pseudo terminal and then escalates to SIGKILL on a pid this
    run has not proved is its own.

    Adoption runs after the original method, because recording the console as
    `machine.child` is what anita's own teardown and this driver's halt both
    go through, and both are only guarded on the object anita is holding.

    Every console is kept, not just the first: a port anita installs starts
    two emulators in one run, and both have to be stopped through the guard.
    The wrapper goes on this one machine object rather than on anita's class,
    so nothing outside this run changes.
    """
    original = machine.configure_child

    def configure_child(child) -> object:
        result = original(child)
        held.append(guest_process.adopt(guard, child, label))
        return result

    machine.configure_child = configure_child


def _halt(machine, pexpect: ModuleType) -> str | None:
    """Power the guest down through anita, and report why it could not be asked.

    A halt is a login plus a command on the console, so it is only asked of a
    machine that reached a login prompt; one that did not would spend a second
    full expect timeout on a question that has no answer. Whatever anita does
    about a machine that will not halt — and it escalates, through the
    console's own `terminate()`, to signals that adoption replaced with a
    refusal — the guarded stop that follows is what actually accounts for the
    pid.

    The reason is returned rather than raised, because this is called on the
    way out of a run that may already have failed for a better reason, and a
    run that reports both is more useful than one that reports the first and
    leaves the second inside a `finally` where nobody reads it.
    """
    if machine.halted or machine.child is None:
        return None
    try:
        machine.halt()
    except (pexpect.ExceptionPexpect, OSError, RuntimeError) as error:
        return str(error)
    return None


def run_guest(target: str, artifact: Path) -> bytes:
    """Boot ``target``, run the suite from ``artifact``, return the console.

    The console is streamed to stdout as it arrives. The returned bytes are
    every byte the emulator wrote, unfiltered, so the caller can require a
    complete, unique, non-skipped receipt for every declared test root. A
    guest that cannot boot, cannot mount the payload, or whose suite exits
    nonzero raises instead of returning a receipt; the console it produced
    has already been written to stdout either way.

    anita forks the emulator itself, on a pseudo terminal and therefore in a
    session and process group of its own, which is out of reach of any group
    this driver chose. So every pid is adopted from `/proc` at the moment anita
    has started it, and every stop goes through `process_guard`. A port anita
    installs starts two of them — the sysinst emulator and the one that runs
    the suite — and both are held. Adoption also takes anita's own teardown
    away on each console object: `halt()` and the error paths reach `os.kill`
    through `close(force=True)`, `terminate()` and `kill()`, and those now
    send nothing this run has not proved is its own — they say which pid and
    which signal they would have sent instead.

    A cancellation is an exception, not a signal this process sends to itself.
    The old handler shut the guest down and then re-raised its own signal, which
    stopped the machine twice: once on whatever the pid looked like inside the
    handler, and once through the interpreter's default disposition with no
    guard read at all. Raising unwinds into the same `finally` every other exit
    takes, so the machine is stopped once and through the guard.
    """
    if target not in GUESTS:
        raise GuestFailure(f"{target} is not a NetBSD target this driver runs; "
                           f"it runs {', '.join(TARGETS)}")
    if not Path(artifact).is_file():
        raise GuestFailure(f"{artifact} is not a file")

    anita, pexpect = _module("anita"), _module("pexpect")
    guest = GUESTS[target]
    workdir = prepare(guest)
    machine = _machine(guest, workdir, anita)
    receipt = Receipt()
    # anita builds its console log from this attribute when it spawns the
    # emulator, so it has to be in place before the boot begins.
    machine.unstructured_log_f = receipt
    payload = _payload(guest, machine, str(Path(artifact).resolve()))
    label = f"{guest.emulator} for {target}"
    guard = guest_process.Guard()
    held: list = []
    _hold_on_configure_child(machine, guard, label, held)
    handlers = guest_process.install_cancellation()
    booted = False
    status = 0
    halt_note: str | None = None
    failure: BaseException | None = None
    stops: list = []
    try:
        try:
            # The boot and what follows it are two phases with two different
            # failures, so they do not share a handler. A timeout or an end of
            # file while the machine is coming up says the boot failed; the
            # same two while the suite runs say a console that had already
            # answered a login prompt stopped answering, and an OSError then
            # says the console could not be driven — not that an emulator this
            # run has been talking to for an hour was never started.
            try:
                if guest.loader_console is None:
                    machine.boot([*_extras(guest, workdir), *payload])
                else:
                    _boot_through_loader(machine, guest, workdir, payload)
            except pexpect.TIMEOUT as error:
                raise GuestFailure(f"{target}: the guest never reached a login prompt") from error
            except pexpect.EOF as error:
                raise GuestFailure(f"{target}: the console closed during boot") from error
            except OSError as error:
                raise GuestFailure(f"{target}: the emulator could not be started") from error
            try:
                booted = True
                if machine.shell_cmd(MOUNT_SCRIPT, timeout=MOUNT_TIMEOUT) != 0:
                    raise GuestFailure(f"{target}: the guest could not write its bootstrap")
                if machine.shell_cmd("/bin/sh /home/cross-scratch/zap-payload.sh",
                                     timeout=MOUNT_TIMEOUT) != 0:
                    raise GuestFailure(f"{target}: the guest found no payload to mount")
                status = machine.shell_cmd(SUITE_COMMAND, timeout=SUITE_TIMEOUT,
                                           keepalive_patterns=list(KEEPALIVE))
            except pexpect.ExceptionPexpect as error:
                raise GuestFailure(
                    f"{target}: the guest console stopped responding after the login prompt: "
                    f"{error}") from error
            except OSError as error:
                raise GuestFailure(
                    f"{target}: the guest console could not be driven any further: "
                    f"{error}") from error
        finally:
            halt_note = _halt(machine, pexpect) if booted else None
            machine.child = None
    except BaseException as error:
        # Recorded rather than raised: the teardown below has to run before
        # anything is reported, and a refusal from it outranks whatever the run
        # was already failing on.
        failure = error
    finally:
        # Stop every adopted console before restoring the handlers.
        try:
            stops = guest_process.finish_many(held, guest_process.SHUTDOWN_GRACE)
        except BaseException as teardown:
            if failure is None:
                raise
            raise teardown from failure
        finally:
            guest_process.restore_cancellation(handlers)
    for stop in stops:
        guest_process.require_stopped(stop, label, failure)
    if failure is not None:
        raise failure

    # `stops` is in the order the consoles were adopted, and the last of them
    # is the emulator `halt()` was asked to power off — an installer starts an
    # earlier one, which anita stopped itself at the end of the install.
    if halt_note is not None and stops and stops[-1].signals:
        raise GuestFailure(
            f"{target}: the guest was not asked to power itself off, because {halt_note}; "
            f"it was stopped with {stops[-1].sent} instead and the receipt is complete")

    console = bytes(receipt.data)
    if status:
        raise GuestFailure(f"{target}: the suite exited {status}")
    return console


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ("run", "tree"):
        sub = commands.add_parser(name)
        sub.add_argument("target", choices=TARGETS)
        if name == "run":
            sub.add_argument("artifact", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "run":
            run_guest(args.target, args.artifact)
        else:
            print(prepare(GUESTS[args.target]))
    except guest_process.Cancelled as cancelled:
        print(f"cross-netbsd: {cancelled}", file=sys.stderr)
        return 128 + cancelled.signum
    except (GuestFailure, RuntimeError, OSError) as error:
        print(f"cross-netbsd: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
