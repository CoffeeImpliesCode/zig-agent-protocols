import os
from pathlib import Path
import pexpect
import subprocess
import sys

work = Path(os.environ['TMPDIR']) / 'openbsd-arm-probe'
work.mkdir(exist_ok=True)
esp = work / 'esp.img'
with esp.open('wb') as stream:
    stream.truncate(64 * 1024 * 1024)
subprocess.run(['mformat', '-i', str(esp), '-F', '::'], check=True)
subprocess.run(['mmd', '-i', str(esp), '::/EFI', '::/EFI/BOOT'], check=True)
subprocess.run(['mcopy', '-i', str(esp), os.environ['CROSS_OPENBSD_ARMV7_BOOT_EFI'],
                '::/EFI/BOOT/BOOTARM.EFI'], check=True)
subprocess.run(['mcopy', '-i', str(esp), os.environ['CROSS_OPENBSD_ARMV7_RD'],
                '::/bsd'], check=True)
command = ['qemu-system-arm', '-machine', 'virt', '-cpu', 'cortex-a15',
           '-accel', 'tcg', '-m', '1024', '-smp', '1', '-nographic',
           '-monitor', 'none', '-no-reboot', '-nic', 'none',
           '-bios', os.environ['CROSS_UBOOT_ARM'],
           '-drive', f'file={esp},format=raw,if=none,id=media,snapshot=on',
           '-device', 'virtio-blk-device,drive=media']
child = pexpect.spawn(command[0], command[1:], timeout=120, encoding=None)
child.logfile_read = sys.stdout.buffer
try:
    child.expect(b'Hit any key to stop autoboot:')
    child.send(b' ')
    child.expect(b'=> ')
    for action in [b'virtio scan', b'fatls virtio 0:0 /EFI/BOOT',
                   b'fatload virtio 0:0 ${kernel_addr_r} /EFI/BOOT/BOOTARM.EFI']:
        child.send(action + b'\r')
        child.expect(b'=> ')
    child.send(b'bootefi ${kernel_addr_r} ${fdtcontroladdr}\r')
    child.expect(b'boot> ')
    child.send(b'boot\r')
    child.expect(b'(I)nstall, (U)pgrade, (A)utoinstall or (S)hell?', timeout=180)
    print('OPENBSD_ARM_INSTALLER_REACHED', flush=True)
finally:
    child.close(force=True)
