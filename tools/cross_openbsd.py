"""Bootstrap and execute the complete Zig test suite in isolated OpenBSD guests.

The base system is produced once per port by driving the official, immutable
OpenBSD 7.8 installation media over the serial console, with a private answer
file and a private set server reached through an installer-only host channel.
The installed, never-yet-booted image is then cached immutably; every test run
boots a private overlay of it with a read-only payload attached and no network
device at all.

No port assumes a firmware boot chain.  Each one states how its firmware
reaches the OpenBSD loader, and how the installed system is booted afterwards:

    amd64, i386    edk2 (UEFI) and SeaBIOS boot the second stage loader from
                   the install media, and boot the installed disk themselves.
    arm64          edk2-aarch64 has no SATA driver, so both storage devices go
                   over virtio; the firmware finds the EFI loader itself.
    riscv64, armv7
                   U-Boot is the only firmware that hands the EFI loader a
                   device tree here, so the install phase stops its autoboot
                   and loads the loader out of the media's EFI system partition
                   itself.  At runtime the installed disk carries its own EFI
                   system partition, which U-Boot's bootflow finds; a U-Boot
                   without it still finds it by hand.
    powerpc64      OPAL is the powernv9 firmware and it does not boot a kernel
                   image; the release's own loader, started out of the
                   powerpc64 miniroot disk image, is what reaches the
                   installer and what boots the installed kernel afterwards.
    macppc         Open Firmware starts the second stage loader itself, from the
                   media's HFS volume at install time and from the small FAT
                   partition installboot(8) creates afterwards.
"""

from __future__ import annotations

import contextlib
from dataclasses import dataclass
import fcntl
import gzip
import hashlib
import io
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
from collections.abc import Sequence

# The release the Zig BSD SDK is generated against; a newer release can change
# the C library major ABI.
VERSION = "7.8"

# install.sub(8) drops the dot from kern.osrelease when it names the sets.
SET_VERSION = VERSION.replace(".", "")

# Bump whenever a bootstrap input changes; the cached base image is keyed on it.
BOOTSTRAP = 2

# Boot phases fail fast: an unanswered prompt is a bug, not a slow machine.
FIRMWARE_TIMEOUT = 600
CONSOLE_TIMEOUT = 900
INSTALL_TIMEOUT = 5400
RUN_TIMEOUT = 7200

# How long a machine may take to power itself off once the suite has reported a
# complete receipt.  A guest whose firmware cannot power the machine down is
# still stopped here, because the receipt is the evidence the caller parses.
SHUTDOWN_GRACE = 180

# Slirp hands the guest this address and pipes the connection to a host
# command, so the installer reaches its answer file and its sets without any
# listening socket on the host and without any route out of the emulated LAN.
SERVER_ADDRESS = "10.0.2.100"
SERVER_PORT = 80

# The release numbers the installer image directory by the dotted version, but
# names the sets with the dotless one.
IMAGE_ROOT = f"/{VERSION}"

# Nothing outside the published SHA256 manifest is required: the installer
# image is pinned by its published hash, and every other file the installer
# sees is derived from it or written by this module.
REQUIRED_SETS = ("bsd", "bsd.mp", f"base{SET_VERSION}.tgz")

DISK = "sd0"
PAYLOAD_MOUNT = "/home/cross-data"
SUITE = "suite.sh"
SITE_SET = f"site{SET_VERSION}.tgz"

PLAIN_SUITE = f"{SUITE.upper()};1"

# The block devices the guest can be handed the payload on, in the order they
# are tried.  Every name is one the kernel of that transport actually
# enumerates, as the runs show: a CD-ROM behind scsibus is cd* or sr*, a disk
# behind scsibus is sd* -- virtio included, because vioblk binds through
# scsibus and never gets a vblk* node -- and macppc's ata(4) numbers its own
# four IDE buses hd* and cd*, which is how the third drive on that machine
# reaches the guest.
PAYLOAD_DEVICES = " ".join((
    "cd0 cd1 cd0a cd1a sr0 sr1 cd2 cd3",
    "sd0 sd1 sd0a sd0b sd0c sd1a sd1b sd1c",
    "hd0 hd1 hd2 hd0a hd0b hd1a hd1b hd2a hd2b",
))

# install.sub(8) runs /etc/rc.firsttime exactly once, sourced from a pipeline in
# /etc/rc, with /dev/console as the controlling terminal (init(8) hands the boot
# rc one).  It must not exit; it powers the machine off.  The payload device is
# named by the kernel, so the mount searches the block devices this port can
# present.  Nothing here is silenced: every attempt is reported, and a guest
# that mounts none says what it found.  The x86 run that reached this hook on
# an enumerated cd0 printed neither a mount diagnostic nor a single device
# name before reporting a setup failure, which left no evidence at all of
# where the payload went or of whether the image was readable at all.
FIRSTTIME = f"""\
# Installed by tools/cross_openbsd.py; runs once, on the first boot.
mkdir -p {PAYLOAD_MOUNT} || return 1
for device in {PAYLOAD_DEVICES}; do
	if mount -t cd9660 "/dev/$device" {PAYLOAD_MOUNT}; then
		echo "cross-data: payload mounted from /dev/$device"
		break
	fi
	echo "cross-data: /dev/$device is not the payload"
done
if [ -f {PAYLOAD_MOUNT}/{SUITE} ]; then
	sh {PAYLOAD_MOUNT}/{SUITE}
elif [ -f '{PAYLOAD_MOUNT}/{PLAIN_SUITE}' ]; then
	# The image was mounted, but the driver showed the ISO 9660 names
	# rather than the Rock Ridge ones, so the suite runs from the name the
	# guest actually has for it.
	sh '{PAYLOAD_MOUNT}/{PLAIN_SUITE}'
else
	ls -lA {PAYLOAD_MOUNT}
	echo ZAP_GUEST_SETUP_FAILED
	halt -p
	return 1
fi
halt -p
"""

# x86 boots the installed system with the second stage loader, whose default
# console is the display, so the site set moves it onto the serial line.  The
# arm64, riscv64 and armv7 loaders inherit the firmware console, which is
# already that line.
BOOT_CONF = "set tty {console}\nstty {console} 115200\n"

# The last thing install.sub(8) prints on a completed installation.
CONGRATULATIONS = b"CONGRATULATIONS!"

# The installer entry point, the receipt line the caller parses, and the
# prompts of the three firmwares that have to be driven.
INSTALL_PROMPT = b"(I)nstall, (U)pgrade, (A)utoinstall or (S)hell? "
COMPLETE = b"ZAP_GUEST_COMPLETE"
LOADER_PROMPT = b"boot> "
UBOOT_PROMPT = b"=> "
UBOOT_AUTOSTOP = b"Hit any key to stop autoboot:"
UBOOT_LOADED = b"bytes read in"
FIRMWARE_PROMPT = b"0 > "

# The partition numbers of an EFI system partition on one U-Boot block device.
# The install media is the published layout, whose loader is the first
# partition; the installed disk is laid out by the installer, so its loader is
# searched for in each partition in turn.
UBOOT_PARTITIONS = (1, 2, 3)

# U-Boot names the block devices it has scanned by their order in that scan,
# which is a property of the firmware build and its device tree rather than of
# the order the drives were attached.  Each index a port can have is searched,
# and each partition of it in turn, so the loader is found wherever the
# firmware enumerated it.
UBOOT_DEVICES = (0, 1)


class BootstrapError(RuntimeError):
    """The guest could not be installed or did not report a complete run."""


@dataclass(frozen=True)
class Port:
    """One Zig triple and the QEMU/OpenBSD plumbing that runs it."""

    target: str
    port: str
    emulator: str
    machine: tuple[str, ...]
    # Install image: an El Torito ISO attached as a CD, or a raw image that has
    # to be attached as a disk because the port's firmware boots it that way.
    media: str
    media_kind: str
    # Release files to publish as sets.  None means "extract them from the
    # install image", which only works when that image carries an ISO 9660
    # tree; the other ports publish their sets individually instead.
    sets: str | None
    # "pflash" needs a private variable store, "bios" is loaded whole, and
    # "uboot" is the firmware that hands the EFI loader a device tree; None is
    # the machine's own firmware.
    firmware: str | None
    # A firmware that reads the device tree the machine leaves for it needs that
    # tree to be this machine's own; naming the machine asks it for one.  The
    # CPU and memory of that request have to match the ones the guest runs on,
    # because the tree describes them.
    device_tree: str | None = None
    device_tree_cpu: str = "max"
    device_tree_memory: str = "2048M"
    code: str | None = None
    variables: str | None = None
    # Second stage loader console switch; None when the firmware console is
    # already the serial line and must not be overridden.
    loader_console: str | None = None
    # mac99 takes a single CPU, so each port states its own.
    cpus: int = 2
    # Peripherals the machine itself has to be given, for a board that models
    # a bus the kernel probes before anything else and hangs on an empty one.
    extra_devices: tuple[str, ...] = ()
    # Kernel arguments typed at the second stage loader's prompt.
    boot_args: tuple[str, ...] = ()
    set_names: tuple[str, ...] = REQUIRED_SETS
    # The disk the installer must partition, named as the kernel names it.  It
    # is the first disk the port attaches, so it always enumerates first.
    root_disk: str = DISK

    # Storage is described per port: some firmwares drive SATA and some only
    # virtio, and the root disk must be the first disk the port enumerates.
    # A port with root_index set has no PCI storage controller at all, so its
    # drives are attached by the machine's own drive indices instead.
    root_controller: str | None = "ich9-ahci,id=sata"
    root_device: str = "ide-hd"
    root_bus: str | None = "sata.0"
    root_index: int | None = None
    media_controller: str | None = None
    media_device: str = "ide-cd"
    media_bus: str | None = "sata.5"
    media_index: int | None = None
    # The payload is a CD-ROM wherever the guest can drive ATAPI.  A machine
    # with no such peripheral gets the ISO as a plain read-only block device,
    # whose ISO 9660 filesystem FIRSTTIME mounts by hand.
    payload_cd: bool = True
    payload_device: str = "ide-cd"
    payload_bus: str | None = "sata.5"
    payload_index: int | None = None

    # U-Boot boots by loading an EFI payload out of a FAT partition and handing
    # it the firmware's device tree: uboot names the pinned binary, uboot_option
    # how QEMU takes it, uboot_class the block device class it enumerates, and
    # efi_payload the file the loader is published under.
    uboot: str | None = None
    uboot_option: str = "-kernel"
    uboot_class: str = "scsi"
    efi_payload: str | None = None
    # Open Firmware boots nothing on its own, so each port states the boot
    # commands it understands, in the order they are worth trying.  The run
    # commands name the installed disk instead of the install media.
    open_firmware_boot: tuple[str, ...] = ()
    open_firmware_run: tuple[str, ...] = ()

    # How the install phase reaches the installer: "loader" types at the second
    # stage loader's prompt, "uboot" and "openfirmware" drive the firmware to
    # it, and "kernel" boots a RAMDISK kernel that presents the installer
    # itself.  run_boot is the same choice for the installed system, where
    # "firmware" means the firmware boots it unattended.
    install_boot: str = "loader"
    run_boot: str = "firmware"
    # A machine that takes a kernel directly names the installer kernel and the
    # installed kernel to hand it; answer_root is set when that kernel asks
    # which disk to mount instead of being told, and run_boot_args is what the
    # loader of the installed system is told to run.
    kernel_set: tuple[str, str] = ()
    answer_root: bool = False
    run_boot_args: tuple[str, ...] = ()


PORTS: dict[str, Port] = {
    "x86_64-openbsd": Port(
        target="x86_64-openbsd",
        port="amd64",
        emulator="qemu-system-x86_64",
        machine=(),
        media="CROSS_OPENBSD_AMD64_ISO",
        media_kind="cd",
        sets=None,
        firmware="pflash",
        code="edk2-x86_64-code.fd",
        # QEMU ships the x86_64 firmware code, but no x86_64 variable store:
        # the store is the IA32 build's OVMF_VARS template, which is the same
        # format for both x86 firmware variants, and that is the name QEMU's
        # package installs it under.  It is copied per run, so the firmware can
        # write boot variables without touching the shipped one.
        variables="edk2-i386-vars.fd",
        loader_console="com0",
    ),
    "x86-openbsd": Port(
        target="x86-openbsd",
        port="i386",
        emulator="qemu-system-i386",
        machine=(),
        media="CROSS_OPENBSD_I386_ISO",
        media_kind="cd",
        sets=None,
        # The i386 image is a legacy BIOS El Torito disc with no EFI boot image,
        # so the UEFI shell would come up instead of the loader.
        firmware=None,
        loader_console="com0",
    ),
    "aarch64-openbsd": Port(
        target="aarch64-openbsd",
        port="arm64",
        emulator="qemu-system-aarch64",
        # QEMU's "max" core publishes the whole ARMv9-A feature set under the
        # ARMv8-A MIDR 0xf0510: SVE, SVE2, MOPS, BF16 and the rest all show up
        # in the cpu features line of a run that then dies with "FP exception
        # in kernel: esr 0x1fe00000 far 0x0", an instruction abort taken from
        # the lower exception level with the link register in the kernel.  The
        # 7.8 arm64 kernel is not built for those registers, so the machine's
        # own ARMv8-A core is used instead: it is what OpenBSD/arm64 is built
        # for and what the arm64 ISO is tested on.
        machine=("-machine", "virt", "-cpu", "cortex-a57"),
        media="CROSS_OPENBSD_ARM64_ISO",
        media_kind="cd",
        sets=None,
        # edk2-aarch64 has no SATA driver, so storage goes over virtio: the
        # root disk is a virtio-blk disk and the media a virtio-scsi CD-ROM.
        # OpenBSD/arm64 vioblk binds through scsibus, so both are sd0 and cd0.
        firmware="bios",
        code="edk2-aarch64-code.fd",
        root_controller=None,
        root_device="virtio-blk-pci",
        root_bus=None,
        media_controller="virtio-scsi-pci,id=cd",
        media_device="scsi-cd",
        media_bus="cd.0",
        payload_device="scsi-cd",
        payload_bus="cd.0",
    ),
    "riscv64-openbsd": Port(
        target="riscv64-openbsd",
        port="riscv64",
        emulator="qemu-system-riscv64",
        # The installed system boots and mounts its own filesystems, but its
        # /etc/rc stops between "starting RPC daemons:." and the savecore it
        # runs next -- that is, in the mount -a, swapctl, do_fsck -N,
        # kvm_mkdb and dev_mkdb stretch -- so it never reaches
        # run_upgrade_script firsttime and the site set never runs.  The stall
        # is therefore upstream of anything this module installs: the site set
        # does land (site78.tgz is unpacked by the installer) and
        # /etc/rc.firsttime is on the disk, it is simply never called.  No file
        # the site set could install is reached earlier than this, so the next
        # run has to name the step it stops in before the site set is worth
        # looking at again.
        machine=("-machine", "virt,acpi=off", "-cpu", "rv64"),
        # 7.8 publishes no riscv64 ISO: install78.img is an MBR image with a
        # FAT ESP that carries BOOTRISCV64.EFI, so the firmware boots it as a
        # disk and the sets come from the individually published files.
        media="CROSS_OPENBSD_RISCV64_IMG",
        media_kind="disk",
        sets="CROSS_OPENBSD_RISCV64_SETS",
        media_device="ide-hd",
        # U-Boot's EFI handoff reaches the loader; bundled edk2 instead faults
        # on its entry instruction with an instruction-access page fault.
        firmware="uboot",
        uboot="CROSS_UBOOT_RISCV64",
        efi_payload="/efi/boot/bootriscv64.efi",
        install_boot="uboot",
        run_boot="uboot",
    ),
    "arm-openbsd": Port(
        target="arm-openbsd",
        port="armv7",
        emulator="qemu-system-arm",
        # U-Boot reads the device tree QEMU leaves at the base of RAM and hands
        # it to the EFI loader, so the machine is asked for its own tree rather
        # than being left to find one: the firmware and the kernel then describe
        # the same hardware.
        device_tree="virt",
        device_tree_cpu="cortex-a15",
        machine=("-machine", "virt", "-cpu", "cortex-a15"),
        # OpenBSD publishes no armv7 ISO: the install media is one of the
        # miniroot disk images, an MBR image whose FAT ESP carries BOOTARM.EFI
        # and whose OpenBSD partition carries the RAMDISK installer kernel.
        media="CROSS_OPENBSD_ARMV7_IMG",
        media_kind="disk",
        sets="CROSS_OPENBSD_ARMV7_SETS",
        # The QEMU virt machine has no ATA or SCSI peripheral, so every block
        # device is virtio-mmio, and OpenBSD's vioblk binds through scsibus.
        root_controller=None,
        root_device="virtio-blk-device",
        root_bus=None,
        media_device="virtio-blk-device",
        media_bus=None,
        payload_cd=False,
        payload_device="virtio-blk-device",
        payload_bus=None,
        # armv7 publishes a GENERIC kernel only, so there is no bsd.mp set.
        set_names=("bsd", f"base{SET_VERSION}.tgz"),
        firmware="uboot",
        uboot="CROSS_UBOOT_ARM",
        uboot_option="-bios",
        uboot_class="virtio",
        efi_payload="/efi/boot/bootarm.efi",
        install_boot="uboot",
        run_boot="uboot",
    ),
    "powerpc64-openbsd": Port(
        target="powerpc64-openbsd",
        port="powerpc64",
        emulator="qemu-system-ppc64",
        machine=("-machine", "powernv9", "-cpu", "power9"),
        media="CROSS_OPENBSD_POWERPC64_ISO",
        media_kind="cd",
        sets=None,
        # powerpc64 GENERIC has ahci at pci, so an AHCI disk is an sd0 and the
        # CD-ROM on the same controller is a cd0.  OPAL is the powernv9
        # firmware, but it does not boot a kernel image: this run hands it the
        # RAMDISK kernel and OPAL reports "INIT: platform wait for kernel load
        # failed", assumes a kernel at 0x20000000, starts it, and the machine
        # stops at its own "Hello, World!" banner with no kernel messages at
        # all.  OpenBSD's powerpc64 kernel is entered by the loader, which
        # fills in its bootinfo, so what OPAL is given here is not a boot.
        # INSTALL.powerpc64 names the bootable media for this machine as
        # install78.img or miniroot78.img in the powerpc64 subdirectory of the
        # release: each is an MBR image whose 'MSDOS' partition is the
        # bootloader the install creates and whose 'OpenBSD' partition carries
        # bsd.rd, and the release publishes the loader itself beside them as
        # .../7.8/powerpc64/boot, an ELF64 EM_PPC64 executable.
        # install78.iso, which is what this port pins today, is the CD image:
        # it carries the sets and bsd.rd and nothing that can be started.
        # The missing input is therefore the powerpc64 install78.img from
        # .../7.8/powerpc64/, whose hash is in that directory's SHA256; the
        # parent owns the pin in devenv.nix, and this port then boots the
        # release's own loader out of that image instead of handing OPAL a
        # kernel.  QEMU's skiboot.lid is the pseries firmware and is a
        # different machine, so it is not a substitute either.
        firmware=None,
        install_boot="kernel",
        run_boot="kernel",
        kernel_set=("bsd.rd", "bsd"),
        # The powerpc64 kernel is handed no boot loader, so it asks which disk
        # to mount and what to swap on.
        answer_root=True,
        set_names=("bsd", "bsd.mp", "bsd.rd", f"base{SET_VERSION}.tgz"),
    ),
    "powerpc-openbsd": Port(
        target="powerpc-openbsd",
        port="macppc",
        emulator="qemu-system-ppc",
        # macppc is 32-bit powerpc; mac99 is its QEMU machine.
        machine=("-machine", "mac99", "-cpu", "G4"),
        # The macppc image is an ISO 9660 image with an Apple partition map and
        # a blessed HFS volume holding ofwboot and the sets, so Open Firmware
        # boots it from the CD and the sets come from the published files.
        media="CROSS_OPENBSD_MACPPC_ISO",
        media_kind="cd",
        sets="CROSS_OPENBSD_MACPPC_SETS",
        # OpenBIOS drives no PCI storage controller, so both drives use the
        # machine's own IDE buses: the root disk is the first master and the
        # CD-ROM the first slave, which is what Open Firmware calls hd and cd.
        root_controller=None,
        root_device="ide-hd",
        root_bus=None,
        root_index=0,
        media_device="ide-cd",
        media_bus=None,
        media_index=1,
        payload_cd=False,
        payload_device="ide-hd",
        payload_bus=None,
        payload_index=2,
        firmware=None,
        cpus=1,
        # mac99 models the ADB bus and its Keylargo controller but attaches no
        # device to it, and the kernel's adb(4) attach waits for a device to
        # answer the bus before it probes anything else: a run without these
        # devices stops with the last console line "adb0 at macobio0 offset
        # 0x16000", which is macobio announcing an empty bus.  These are the
        # devices that board is probed for, and QEMU accepts both names on the
        # mac99 macobio.  No run has exercised this yet -- the run that stalled
        # there had no -device adb-* on its command line at all -- so the
        # wiring is unproven until one gets that far.
        extra_devices=("-device", "adb-keyboard", "-device", "adb-mouse"),
        # INSTALL.macppc boots the release's own HFS volume, where the RAMDISK
        # kernel lives under the version directory; the installed disk instead
        # carries the loader installboot(8) put in its own FAT partition.
        open_firmware_boot=(
            f"boot cd:,ofwboot {IMAGE_ROOT}/macppc/bsd.rd",
            "boot cd:,ofwboot",
        ),
        # The installed disk is the first IDE master, and installboot(8) put
        # the loader in the FAT partition it created, where Open Firmware's
        # boot-device setting looks for it by default.
        open_firmware_run=("boot hd:,ofwboot",),
        boot_args=(f"{IMAGE_ROOT}/macppc/bsd.rd",),
        install_boot="openfirmware",
        run_boot="openfirmware",
        loader_console="com0",
    ),
}

TARGETS: tuple[str, ...] = tuple(PORTS)


def required_environment(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise BootstrapError(f"{name} is unset; the parent must pin the media")
    return value


def cache_root() -> Path:
    cache = Path(required_environment("CROSS_GUEST_CACHE"))
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    return cache


def bundled_firmware() -> Path | None:
    """The share/qemu directory of the QEMU the parent pinned, if it is on PATH."""
    executable = shutil.which("qemu-system-x86_64")
    if executable is None:
        return None
    # <prefix>/bin/qemu-system-x86_64 -> <prefix>/share/qemu
    share = Path(executable).resolve().parent.parent / "share" / "qemu"
    return share if share.is_dir() else None


def code_image(port: Port) -> Path:
    if port.code is None:
        raise BootstrapError(f"the {port.port} port names no firmware image")
    share = bundled_firmware()
    if share is None:
        raise BootstrapError(f"the {port.code} image must ship with QEMU")
    code = share / port.code
    if not code.is_file():
        raise BootstrapError(f"QEMU does not ship {port.code}")
    return code


def variable_image(port: Port, work: Path) -> Path:
    """A private UEFI variable store; OVMF and edk2 need one they may write to."""
    if port.variables is None:
        raise BootstrapError(f"the {port.port} firmware has no variable store")
    share = bundled_firmware()
    if share is None:
        raise BootstrapError(f"{port.variables} must ship with QEMU")
    variables = share / port.variables
    if not variables.is_file():
        raise BootstrapError(f"QEMU does not ship {port.variables}")
    store = work / "variables.fd"
    shutil.copyfile(variables, store)
    store.chmod(0o600)
    return store


# --------------------------------------------------------------------------
# Answer file
# --------------------------------------------------------------------------

def answer_file(port: Port) -> str:
    """Render the response file in install.conf(5) syntax.

    A key is a whole question.  install.sub(8) accepts it only when it is
    a prefix of the question followed by blanks or a question mark, so keys are
    the full question text, and a question with no default is fatal unless the
    key is present.  Keys that no question matches are never consumed.  Every
    key below is copied from the question the shipped installer asks.
    """
    server = f"http://{SERVER_ADDRESS}:{SERVER_PORT}"
    answers: list[tuple[str, str]] = [
        ("System hostname? (short form, e.g. 'foo')", "cross-test"),
        ("What timezone are you in? ('?' for list)", "UTC"),
        # The installer asks for a root password with no default, and encr_pwd()
        # writes this one straight into /etc/master.passwd, so the installed
        # root account holds no usable password.  Nothing ever logs in: the
        # first boot hook runs from /etc/rc with /dev/console.
        ("Password for root account?", "*************"),
        # Exactly one interface, DHCP, no IPv6: the answer file and the sets are
        # reached through the installer-only host channel.
        ("Network interface to configure? (name, lladdr, '?', or 'done')", "em0"),
        ("Symbolic (host) name for em0?", "cross-test"),
        ("IPv4 address for em0? (or 'autoconf' or 'none')", "autoconf"),
        ("Netmask for em0?", "255.255.255.0"),
        ("Default IPv4 route? (IPv4 address or 'none')", "none"),
        ("IPv6 address for em0? (or 'autoconf' or 'none')", "none"),
        ("IPv6 address for em0? (IPv6 address, list#, 'none' or '?')", "none"),
        ("IPv6 route? (choose from list# or 'none')", "none"),
        ("DNS domain name? (e.g. 'example.com')", "cross-test"),
        ("DNS nameservers? (IP address list or 'none')", "none"),
        # The guest needs no remote access and no display.
        ("Start sshd(8) by default?", "no"),
        ("Allow root ssh login? (yes, no, prohibit-password)", "no"),
        ("Do you expect to run the X Window System?", "no"),
        ("Do you want the X Window System to be started by xenodm(1)?", "no"),
        ("Setup a user? (enter a lower-case loginname, or 'no')", "no"),
        # Take the whole disk; the site set moves the loader console to serial.
        ("Which disk is the root disk? ('?' for details)", port.root_disk),
        ("Use (W)hole disk MBR, whole disk (G)PT or (E)dit?", "w"),
        ("Use (W)hole disk or (E)dit the MBR?", "w"),
        ("Use (W)hole disk or (E)dit the GPT?", "w"),
        ("Encrypt the root disk with a (p)assphrase or (k)eydisk?", "no"),
        # Sets come from the installer-only host channel, never from a mirror.
        ("Location of sets? (cd0 disk http or 'done')", "http"),
        ("HTTP proxy URL? (e.g. 'http://proxy:8080', or 'none')", "none"),
        ("HTTP Server? (hostname, list#, 'done' or '?')", server),
        ("HTTP Server? (hostname or 'done')", server),
        ("Server directory?", "/"),
        ("Set name(s)? (or 'abort' or 'done')",
         " ".join((*port.set_names, SITE_SET))),
        # The served directory is derived from the pinned installer image, so
        # it carries no release signature.  The installer still refuses a set
        # it cannot find, and still reports every failure it can.
        ("Directory does not contain SHA256.sig. Continue without verification?",
         "yes"),
    ]
    return "".join(f"{question} = {value}\n" for question, value in answers)


# --------------------------------------------------------------------------
# Site set
# --------------------------------------------------------------------------

def site_archive(port: Port) -> bytes:
    """Build the first boot site set as a reproducible gzip tar archive."""
    files = {"etc/rc.firsttime": FIRSTTIME.encode("ascii")}
    if port.loader_console is not None:
        files["etc/boot.conf"] = BOOT_CONF.format(
            console=port.loader_console).encode("ascii")
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for name in sorted(files):
            entry = tarfile.TarInfo(name)
            entry.size = len(files[name])
            entry.mtime = 0
            entry.mode = 0o644
            entry.uid = entry.gid = 0
            entry.uname = entry.gname = "root"
            archive.addfile(entry, io.BytesIO(files[name]))
    packed = io.BytesIO()
    with gzip.GzipFile(fileobj=packed, mode="wb", compresslevel=6, mtime=0) as stream:
        stream.write(raw.getvalue())
    return packed.getvalue()


def index_text(names: Sequence[str], sizes: dict[str, int]) -> str:
    """Render the set list install.sub(8) reads back out of index.txt."""
    return "".join(
        f"-rw-r--r-- 1 0 0 {sizes[name]:>12} Jan  1 00:00 {name}\n" for name in names
    )


def extract_from_image(port: Port, image: Path, name: str, target: Path) -> Path:
    """Copy one released file out of the port's install image."""
    if not image.is_file():
        raise BootstrapError(f"{image} is not a file")
    subprocess.run(
        ["xorriso", "-osirrox", "on", "-indev", str(image), "-extract",
         f"{IMAGE_ROOT}/{port.port}/{name}", str(target)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return target


def set_directory(port: Port, image: Path, work: Path) -> Path:
    """Publish the selected sets, the site set and the answer file.

    Ports whose install image carries an ISO 9660 tree hand their sets to
    xorriso; the others are published from the individually released files the
    parent pinned, because their image is a raw partition map.
    """
    root = work / "sets"
    root.mkdir()
    published = (*port.set_names, f"INSTALL.{port.port}")
    if port.sets is None:
        for name in published:
            extract_from_image(port, image, name, root / name)
    else:
        source = Path(required_environment(port.sets))
        if not source.is_dir():
            raise BootstrapError(f"{port.sets} does not name a directory of sets")
        for name in published:
            origin = source / name
            if not origin.is_file():
                raise BootstrapError(f"{port.sets} is missing the {name} set")
            shutil.copyfile(origin, root / name)
    (root / SITE_SET).write_bytes(site_archive(port))
    names = [*published, SITE_SET]
    sizes = {name: (root / name).stat().st_size for name in names}
    (root / "index.txt").write_text(index_text(names, sizes), encoding="ascii")
    (root / "install.conf").write_text(answer_file(port), encoding="ascii")
    return root


def machine_kernel(port: Port, work: Path, phase: str) -> Path:
    """The kernel the port's machine boots directly, taken from its own media.

    OPAL (powernv9) takes its payload from the machine, so it needs a file on
    the host.  The install phase boots the released RAMDISK kernel, and the run
    phase boots the released GENERIC kernel, which is the one install.sub(8)
    installs for a single-processor machine.  Both are read out of the pinned
    media rather than built.
    """
    if len(port.kernel_set) != 2:
        raise BootstrapError(f"the {port.port} port names no machine kernel")
    name = port.kernel_set[0 if phase == "install" else 1]
    return extract_from_image(port, Path(required_environment(port.media)), name,
                              work / name)


# --------------------------------------------------------------------------
# Installer-only host channel
# --------------------------------------------------------------------------

def serve_http(root: Path) -> int:
    """Answer one HTTP/1.0 GET on stdin/stdout, driven by QEMU guestfwd.

    QEMU connects the guest's TCP stream to this process' standard streams, so
    the installer reaches its answer file and its sets with no listening socket
    on the host and no route out of the emulated LAN.  The installer asks for
    one file per connection and closes it, so this process answers that one
    request and exits.
    """
    source = sys.stdin.buffer
    sink = sys.stdout.buffer
    line = source.readline()
    if not line:
        return 1
    request = line.split()
    while True:  # consume the request headers
        header = source.readline()
        if not header or header in (b"\r\n", b"\n"):
            break
    if len(request) < 2 or request[0] != b"GET":
        sink.write(b"HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
        sink.flush()
        return 1
    target = request[1].split(b"?")[0].lstrip(b"/").decode("utf-8", "replace")
    base = root.resolve()
    path = (base / target).resolve()
    if not path.is_file() or base not in path.parents:
        sink.write(b"HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        sink.flush()
        return 1
    with path.open("rb") as published:
        size = path.stat().st_size
        sink.write(f"HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\n"
                   f"Content-Length: {size}\r\nConnection: close\r\n\r\n"
                   .encode("ascii"))
        while chunk := published.read(65536):
            sink.write(chunk)
        sink.flush()
    return 0


def guest_channel(root: Path) -> str:
    """The slirp option that hands guest TCP to a private HTTP server."""
    command = f"{sys.executable} '{Path(__file__).resolve()}' __http '{root}'"
    for argument in (sys.executable, str(Path(__file__).resolve()), str(root)):
        if "," in argument or "\n" in argument:
            raise BootstrapError(f"host channel path is not usable: {argument!r}")
    return (f"user,id=net0,restrict=on,ipv6=off,"
            f"guestfwd=tcp:{SERVER_ADDRESS}:{SERVER_PORT}-cmd:{command}")


# --------------------------------------------------------------------------
# QEMU command lines
# --------------------------------------------------------------------------

def storage(port: Port) -> list[str]:
    """The controllers the port's devices attach to.

    The root disk is enumerated first so the installer's disk list always names
    it first; the media goes on the last bus so a disk-attached image cannot
    take that name.  Which bus each device uses is per port, because some
    firmwares drive SATA and others only virtio.
    """
    devices: list[str] = []
    if port.root_controller is not None:
        devices += ["-device", port.root_controller]
    if port.media_controller is not None:
        devices += ["-device", port.media_controller]
    return devices


def uboot_pin(port: Port) -> str:
    """The environment variable naming the U-Boot build this port boots with."""
    if port.uboot is None:
        raise BootstrapError(f"the {port.port} port names no U-Boot image")
    return port.uboot


def firmware_arguments(port: Port, work: Path) -> list[str]:
    """Boot the install media through a firmware whose console is serial.

    The x86 OpenBSD loader only reaches the serial line when it is told to, and
    it prints its prompt on the display by default, so x86 boots through UEFI,
    where the second stage loader inherits the serial console.  The other ports
    either inherit the firmware console already or need no switch.
    """
    match port.firmware:
        case None:
            return []
        case "bios":
            return ["-bios", str(code_image(port))]
        case "pflash":
            code = code_image(port)
            return ["-drive", f"if=pflash,format=raw,readonly=on,file={code}",
                    "-drive", f"if=pflash,format=raw,snapshot=on,"
                              f"file={variable_image(port, work)}"]
        case "uboot":
            return [port.uboot_option, required_environment(uboot_pin(port))]
        case unknown:
            raise BootstrapError(f"unknown firmware kind: {unknown}")


def device_tree(port: Port, work: Path) -> Path:
    """The device tree QEMU generates for this machine.

    Asking the machine for its own tree is what keeps the firmware and the
    kernel on one description of the hardware; no tree is written by hand.
    """
    if port.device_tree is None:
        raise BootstrapError(f"the {port.port} port names no machine to ask")
    dtb = work / f"{port.device_tree}.dtb"
    subprocess.run([port.emulator, "-machine", f"{port.device_tree},dumpdtb={dtb}",
                    "-cpu", port.device_tree_cpu, "-m", port.device_tree_memory,
                    "-display", "none"],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.STDOUT, check=True)
    if not dtb.is_file() or dtb.read_bytes()[:4] != b"\xd0\x0d\xfe\xed":
        raise BootstrapError(f"{port.emulator} produced no {port.port} device tree")
    return dtb


def machine_arguments(port: Port, work: Path, phase: str) -> list[str]:
    """The machine and CPU, the tree it leaves behind, and the kernel it takes."""
    command = list(port.machine)
    if port.device_tree is not None:
        command += ["-dtb", str(device_tree(port, work))]
    kind = port.install_boot if phase == "install" else port.run_boot
    if kind == "kernel":
        command += ["-kernel", str(machine_kernel(port, work, phase))]
    return command


def overlay_drive(image: Path, drive: str, work: Path) -> Path:
    """A private copy-on-write view of a published image.

    QEMU refuses a read-only block node for an ide-hd, so a disk-attached image
    gets a private qcow2 overlay instead: the published file is never opened
    for writing, and whatever the guest writes is discarded.
    """
    overlay = work / f"{drive}.qcow2"
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "raw",
                    "-b", str(image), str(overlay)], check=True)
    return overlay


def bus_drive(drive: str, path: Path, options: str, device: str,
              bus: str | None, index: int | None, media: str) -> list[str]:
    """Attach one drive the way this port's machine enumerates storage."""
    if index is not None:
        return ["-drive", f"file={path},{options},if=ide,index={index},"
                          f"media={media}"]
    return ["-drive", f"file={path},{options},if=none,id={drive}",
            "-device", f"{device},drive={drive}"
                       + (f",bus={bus}" if bus else "")]


def media_drive(port: Port, image: Path, work: Path) -> list[str]:
    """Attach the install image read-only, as the CD or disk its port boots."""
    if port.media_kind == "cd":
        return bus_drive("media", image, "format=raw,readonly=on",
                         port.media_device, port.media_bus, port.media_index,
                         "cdrom")
    overlay = overlay_drive(image, "media", work)
    return bus_drive("media", overlay, "format=qcow2", port.media_device,
                     port.media_bus, port.media_index, "disk")


def root_drive(port: Port, image: Path, snapshot: bool = False) -> list[str]:
    """Attach the disk the installer partitions, or the installed overlay."""
    options = "format=qcow2,snapshot=on" if snapshot else "format=qcow2"
    return bus_drive("root", image, options, port.root_device, port.root_bus,
                     port.root_index, "disk")


def payload_drive(port: Port, artifact: Path, work: Path) -> list[str]:
    """Attach the read-only payload the suite is mounted from.

    A CD-ROM wherever the guest can drive ATAPI; elsewhere the ISO is a plain
    block device, which cd9660(5) mounts by hand from the first-boot hook.
    """
    if port.payload_cd:
        return bus_drive("payload", artifact, "format=raw,readonly=on",
                         port.payload_device, port.payload_bus, None, "cdrom")
    overlay = overlay_drive(artifact, "payload", work)
    return bus_drive("payload", overlay, "format=qcow2", port.payload_device,
                     port.payload_bus, port.payload_index, "disk")


def install_command(port: Port, work: Path, image: Path, disk: Path,
                    sets: Path) -> list[str]:
    return [
        port.emulator, "-accel", "tcg", "-m", "2048", "-smp", str(port.cpus),
        "-nographic", "-monitor", "none", "-no-reboot", "-boot", "order=dc",
        *machine_arguments(port, work, "install"), *storage(port),
        *port.extra_devices,
        *firmware_arguments(port, work),
        *root_drive(port, disk),
        *media_drive(port, image, work),
        "-netdev", guest_channel(sets),
        "-device", "e1000,netdev=net0",
    ]


def runtime_command(port: Port, image: Path, artifact: Path, work: Path) -> list[str]:
    """Boot a private overlay with the payload attached and no network at all."""
    command = [
        port.emulator, "-accel", "tcg", "-m", "2048", "-smp", str(port.cpus),
        "-nographic", "-monitor", "none", "-no-reboot", "-nic", "none",
        *machine_arguments(port, work, "run"), *storage(port),
        *port.extra_devices,
        *firmware_arguments(port, work),
    ]
    command += [*root_drive(port, image, snapshot=True),
                *payload_drive(port, artifact, work)]
    return command


# --------------------------------------------------------------------------
# Console
# --------------------------------------------------------------------------

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


# --------------------------------------------------------------------------
# Firmware
# --------------------------------------------------------------------------

def uboot_command(child: object, command: bytes, patterns: Sequence[object]) -> int:
    """Type one U-Boot command and report which of the patterns ended it.

    U-Boot echoes what it is given and answers on its own prompt, so every
    command is terminated and every answer is awaited.
    """
    child.send(command + b"\r")
    return child.expect(list(patterns), timeout=CONSOLE_TIMEOUT)


def uboot_scan(child: object, port: Port) -> None:
    """Enumerate the block devices U-Boot boots from."""
    uboot_command(child, f"{port.uboot_class} scan".encode(), [UBOOT_PROMPT])


def uboot_load(child: object, port: Port) -> None:
    """Load the port's EFI loader out of a FAT partition and run it.

    U-Boot names a partition as <class> <device>:<partition>, where the device
    is the order in which that firmware enumerated the block devices, which is
    not stated by the command line that attached them.  Every device the port
    can have is searched, and each of its partitions in turn: the install media
    is the published layout, whose loader is its first partition, and the
    installed disk is laid out by the installer, so its loader is searched for
    wherever the firmware numbered it.
    """
    if port.efi_payload is None:
        raise BootstrapError(f"the {port.port} port names no EFI payload")
    for device in UBOOT_DEVICES:
        for partition in UBOOT_PARTITIONS:
            loaded = uboot_command(
                child,
                f"fatload {port.uboot_class} {device}:{partition} "
                f"${{kernel_addr_r}} {port.efi_payload}".encode(),
                [UBOOT_LOADED, UBOOT_PROMPT])
            if loaded == 0:
                # bootefi hands the loader the firmware's own device tree, which
                # is how these ports learn their hardware.
                child.send(b"bootefi ${kernel_addr_r} ${fdtcontroladdr}\r")
                return
    tried = ", ".join(f"{port.uboot_class} {device}:{partition}"
                      for device in UBOOT_DEVICES for partition in UBOOT_PARTITIONS)
    raise BootstrapError(
        f"U-Boot found no EFI system partition on any of {tried} "
        f"for {port.port}")


def uboot_shell(child: object) -> None:
    """Stop U-Boot's autoboot and wait at its prompt."""
    child.expect_exact(UBOOT_AUTOSTOP, timeout=FIRMWARE_TIMEOUT)
    child.send(b" ")
    child.expect_exact(UBOOT_PROMPT, timeout=FIRMWARE_TIMEOUT)


def drive_uboot_install(child: object, port: Port) -> None:
    """Boot the installer out of the EFI system partition of its media."""
    uboot_shell(child)
    uboot_scan(child, port)
    uboot_load(child, port)


def drive_uboot_run(child: object, port: Port) -> None:
    """Boot the installed system out of its own EFI system partition.

    The installed disk carries the loader the installer published there, which
    is what INSTALL.riscv64 and INSTALL.armv7 tell U-Boot to start through
    "distro_bootcmd".  A U-Boot with bootflow enabled finds it without this
    driver naming a partition; one without it still finds it by hand.
    """
    uboot_shell(child)
    uboot_scan(child, port)
    if uboot_command(child, b"bootflow scan", [LOADER_PROMPT, UBOOT_PROMPT]) == 0:
        return
    uboot_load(child, port)


def drive_open_firmware(child: object, port: Port, commands: Sequence[str]) -> None:
    """Boot the OpenBSD loader through Open Firmware.

    Open Firmware boots nothing on its own, so the install phase names the
    media and the RAMDISK kernel INSTALL.macppc publishes on it, and the run
    phase names the loader installboot(8) put on the installed disk.
    """
    if child.expect([LOADER_PROMPT, FIRMWARE_PROMPT],
                    timeout=FIRMWARE_TIMEOUT) == 0:
        return
    for command in commands:
        child.send(f"{command}\n".encode())
        if child.expect([LOADER_PROMPT, FIRMWARE_PROMPT],
                        timeout=CONSOLE_TIMEOUT) == 0:
            return
    raise BootstrapError(f"Open Firmware did not start the {port.port} loader")


def drive_loader(child: object, port: Port, arguments: Sequence[str]) -> None:
    """Type at the second stage loader's prompt until the kernel runs.

    The loader reads its console raw and ignores a bare line feed, so its
    commands end in a carriage return; the kernel console further down is
    canonical and does want a plain line feed.
    """
    child.expect_exact(LOADER_PROMPT, timeout=FIRMWARE_TIMEOUT)
    if port.loader_console is not None:
        child.send(f"set tty {port.loader_console}\r".encode())
        child.expect_exact(LOADER_PROMPT, timeout=CONSOLE_TIMEOUT)
    child.send(f"{' '.join(('boot', *arguments))}\r".encode())


def drive_installer(command: list[str], port: Port) -> bytes:
    """Boot the installer image and answer the prompts that come before the
    response file: whatever boots the image, then the installer entry point."""
    import pexpect

    console = Console()
    child = pexpect.spawn(command[0], command[1:], timeout=FIRMWARE_TIMEOUT,
                          encoding=None)
    child.logfile_read = console
    try:
        if port.install_boot == "uboot":
            drive_uboot_install(child, port)
        elif port.install_boot == "openfirmware":
            drive_open_firmware(child, port, port.open_firmware_boot)
        if port.install_boot in ("loader", "openfirmware", "uboot"):
            drive_loader(child, port, port.boot_args)
        child.expect_exact(INSTALL_PROMPT, timeout=CONSOLE_TIMEOUT)
        child.sendline(b"a")
        child.expect_exact(b"Response file location? ", timeout=CONSOLE_TIMEOUT)
        child.sendline(f"http://{SERVER_ADDRESS}:{SERVER_PORT}/install.conf".encode())
        # A failed autoinstall drops to a shell instead of finishing, so the
        # installer's own failure lines are awaited as well: without them an
        # unanswered question looks like a slow machine.
        finished = child.expect(
            [CONGRATULATIONS, b"failed; check /tmp/ai/ai.log",
             b"Question has no answer in response file"],
            timeout=INSTALL_TIMEOUT)
        if finished != 0:
            raise BootstrapError(
                f"the {port.port} installer stopped: "
                f"{child.after.decode('utf-8', 'replace').strip()}")
        # do_autoinstall(8) reboots into nothing; -no-reboot ends the machine.
        child.expect(pexpect.EOF, timeout=CONSOLE_TIMEOUT)
    except pexpect.ExceptionPexpect as error:
        raise BootstrapError(
            f"the {port.port} installer did not complete: {error}"
        ) from error
    finally:
        child.close(force=True)
    return console.text()


# --------------------------------------------------------------------------
# Base image
# --------------------------------------------------------------------------

def image_key(port: Port) -> str:
    """Bind the cached image to every pinned input and to this module's bytes.

    Nix normalises mtimes, so a changed pin of the same length would otherwise
    reuse a stale image.  Each source contributes its store name and size, the
    selected firmware and the machine it is driven on contribute their own, and
    everything this module derives from them (the answer file and the site set)
    is digested outright.  What
    identifies the cache entry is one bounded digest: a file name has to fit a
    name component on every filesystem, and a port pins a whole Nix store
    directory name.
    """
    sources = [required_environment(port.media)]
    if port.sets is not None:
        source = Path(required_environment(port.sets))
        sources += [str(source / name) for name in
                    (*port.set_names, f"INSTALL.{port.port}")]
    parts = [f"openbsd-{port.port}-v{VERSION}-b{BOOTSTRAP}"]
    for name in sources:
        status = Path(name).stat()
        parts.append(f"{Path(name).name}-{status.st_size:x}")
    if port.firmware == "uboot":
        code = Path(required_environment(uboot_pin(port)))
        parts.append(f"{code.parent.name}-{code.stat().st_size:x}")
    if port.code is not None:
        code = code_image(port).stat()
        parts.append(f"{port.code}-{code.stat().st_size:x}")
    # The base image is produced by driving this release's installer on this
    # exact machine, so the machine and the peripherals it is given identify
    # it as much as the media do: a port whose CPU or board devices change
    # must not be handed an image that was installed under the old ones.
    parts.append(" ".join((*port.machine, *port.extra_devices)))
    parts.append(hashlib.sha256(answer_file(port).encode("ascii")
                                + site_archive(port)).hexdigest())
    digest = hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()[:32]
    return f"openbsd-{port.port}-v{VERSION}-b{BOOTSTRAP}-{digest}"


def installed_image(port: Port) -> Path:
    """The cached, never-booted installed system, built once per port."""
    cache = cache_root()
    key = image_key(port)
    final = cache / f"{key}.qcow2"
    with (cache / f"{key}.lock").open("ab") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        if final.is_file():
            return final
        image = Path(required_environment(port.media))
        if not image.is_file():
            raise BootstrapError(f"{image} is not a file")
        with tempfile.TemporaryDirectory(prefix=f"bootstrap-{port.port}-",
                                         dir=cache) as raw:
            work = Path(raw)
            # The published image is never opened for writing: CD media is
            # attached read-only, and disk media gets a private overlay.
            sets = set_directory(port, image, work)
            disk = work / "root.qcow2"
            subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2",
                            str(disk), "6G"], check=True)
            drive_installer(install_command(port, work, image, disk, sets), port)
            converted = work / "base.qcow2"
            subprocess.run(["qemu-img", "convert", "-O", "qcow2", str(disk),
                            str(converted)], check=True)
            os.replace(converted, final)
    return final


# --------------------------------------------------------------------------
# Public interface
# --------------------------------------------------------------------------

def terminate(process: subprocess.Popen[bytes]) -> None:
    """Stop the machine and everything it started, however we got here."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired, ProcessLookupError):
        process.wait(60)


def watch_guest(port: Port, command: list[str]) -> bytes:
    """Run a guest whose firmware boots it unattended, and keep its console."""
    console = Console()
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    assert process.stdout is not None
    try:
        deadline = time.monotonic() + RUN_TIMEOUT
        with process.stdout:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, RUN_TIMEOUT)
                if not select.select([process.stdout], [], [],
                                     min(remaining, 30))[0]:
                    continue
                chunk = process.stdout.read1(65536)
                if not chunk:
                    break
                console.write(chunk)
        status = process.wait(max(1, deadline - time.monotonic()))
    except subprocess.TimeoutExpired as expired:
        terminate(process)
        raise BootstrapError(
            f"the {port.port} guest did not halt within {RUN_TIMEOUT} seconds"
        ) from expired
    except BaseException:
        terminate(process)
        raise
    if status != 0:
        raise BootstrapError(
            f"{port.emulator} exited {status} for {port.port}; "
            f"the guest did not halt")
    return console.text()


def drive_guest(port: Port, command: list[str]) -> bytes:
    """Run a guest whose firmware or kernel has to be answered.

    The suite's receipt is the evidence, so the machine is stopped once it has
    printed a complete one even if it cannot power itself off; a machine that
    powers off on its own is never stopped early.
    """
    import pexpect

    console = Console()
    child = pexpect.spawn(command[0], command[1:], timeout=CONSOLE_TIMEOUT,
                          encoding=None)
    child.logfile_read = console
    deadline = time.monotonic() + RUN_TIMEOUT
    try:
        if port.run_boot == "uboot":
            drive_uboot_run(child, port)
        elif port.run_boot == "openfirmware":
            drive_open_firmware(child, port, port.open_firmware_run)
            drive_loader(child, port, port.run_boot_args)
        # A machine that was handed its kernel has no loader behind it, so the
        # kernel asks which disk to mount and what to swap on.
        answers: dict[int, bytes] = {}
        patterns: list[object] = []
        if port.answer_root:
            patterns += [b"root device", b"swap device"]
            answers = {0: f"{port.root_disk}\n".encode(), 1: b"\n"}
        patterns += [COMPLETE, pexpect.EOF, pexpect.TIMEOUT]
        complete = len(patterns) - 3
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BootstrapError(
                    f"the {port.port} guest did not finish within "
                    f"{RUN_TIMEOUT} seconds")
            index = child.expect(patterns, timeout=min(remaining, 30))
            if index in answers:
                child.send(answers[index])
            elif index == complete:
                break
            elif index in (complete + 1, complete + 2):
                break
        if child.expect([pexpect.EOF, pexpect.TIMEOUT],
                        timeout=SHUTDOWN_GRACE) == 1:
            # The suite is finished; a guest with no way to power the machine
            # off is stopped here instead of holding the run open until the
            # outer deadline.
            child.terminate(force=True)
    except pexpect.ExceptionPexpect as error:
        raise BootstrapError(
            f"the {port.port} guest did not complete: {error}") from error
    finally:
        child.close(force=True)
    return console.text()


def run_guest(target: str, artifact: Path) -> bytes:
    """Run the suite in a real OpenBSD guest and return its raw console.

    The base image is installed on first use and reused unchanged; the run
    itself is a private overlay of that image, so the first boot hook always
    sees a freshly installed system.
    """
    if target not in PORTS:
        raise BootstrapError(f"unsupported OpenBSD target: {target}")
    payload = artifact.resolve()
    if not payload.is_file():
        raise BootstrapError(f"payload {payload} is not a file")
    port = PORTS[target]
    image = installed_image(port)
    # A private firmware variable store and a private scratch per run; both are
    # discarded, so nothing the firmware or the guest writes is kept and the
    # cached base image is never touched.
    with tempfile.TemporaryDirectory(prefix=f"run-{port.port}-",
                                     dir=cache_root()) as raw:
        work = Path(raw)
        command = runtime_command(port, image, payload, work)
        receipt = (watch_guest(port, command) if port.run_boot == "firmware"
                   else drive_guest(port, command))
    if COMPLETE not in receipt:
        raise BootstrapError(f"the {target} guest produced no complete receipt")
    return receipt


def _main(argv: Sequence[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    build = commands.add_parser("bootstrap", help="install and cache the base image")
    build.add_argument("target", choices=TARGETS)
    run = commands.add_parser("run", help="run the suite in a guest")
    run.add_argument("target", choices=TARGETS)
    run.add_argument("artifact", type=Path)
    args = parser.parse_args(argv)
    if args.operation == "bootstrap":
        print(installed_image(PORTS[args.target]))
    else:
        run_guest(args.target, args.artifact)
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["__http"]:
        raise SystemExit(serve_http(Path(sys.argv[2])))
    raise SystemExit(_main(sys.argv[1:]))