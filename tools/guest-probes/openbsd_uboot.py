import os
from pathlib import Path
import pexpect

work = Path(os.environ['TMPDIR']) / 'openbsd-uboot-probe'
work.mkdir(exist_ok=True)
disk = work / 'root.qcow2'
if not disk.exists():
    import subprocess
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', str(disk), '6G'], check=True)
command = ['qemu-system-riscv64', '-machine', 'virt,acpi=off', '-cpu', 'rv64',
           '-accel', 'tcg', '-m', '2048', '-smp', '2', '-nographic',
           '-monitor', 'none', '-no-reboot', '-nic', 'none',
           '-kernel', os.environ['CROSS_UBOOT_RISCV64'],
           '-device', 'ich9-ahci,id=sata',
           '-drive', f'file={disk},format=qcow2,if=none,id=root,snapshot=on',
           '-device', 'ide-hd,drive=root,bus=sata.0',
           '-drive', 'file=' + os.environ['CROSS_OPENBSD_RISCV64_IMG'] +
                     ',format=raw,if=none,id=media,snapshot=on',
           '-device', 'ide-hd,drive=media,bus=sata.5']
child = pexpect.spawn(command[0], command[1:], timeout=120, encoding=None)
import sys
child.logfile_read = sys.stdout.buffer
try:
    child.expect(b'Hit any key to stop autoboot:')
    child.send(b' ')
    child.expect(b'=> ')
    for action in [b'scsi scan', b'fatls scsi 1:1 /EFI/BOOT',
                   b'fatload scsi 1:1 ${kernel_addr_r} /EFI/BOOT/BOOTRISCV64.EFI']:
        child.send(action + b'\r')
        child.expect(b'=> ')
    child.send(b'bootefi ${kernel_addr_r} ${fdtcontroladdr}\r')
    child.expect(b'boot> ')
    child.send(b'boot\r')
    child.expect(b'(I)nstall, (U)pgrade, (A)utoinstall or (S)hell?', timeout=180)
    print('OPENBSD_RISCV_INSTALLER_REACHED', flush=True)
finally:
    child.close(force=True)
