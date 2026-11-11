"""Native read-only GPT/lease controls using authored sparse files only."""
import fcntl
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zlib

ROOT = Path(__file__).resolve().parents[2]
APFS = uuid.UUID('7c3457ef-0000-11aa-aa11-00306543ecac').bytes_le


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin F_GETPATH/stat controls')
class GuestDiskTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler_temp = tempfile.TemporaryDirectory(prefix='henge-guest-disk-control-')
        cls.addClassCleanup(cls.compiler_temp.cleanup)
        folder = Path(cls.compiler_temp.name)
        source = folder / 'control.c'
        source.write_text('''
#include "HGGuestDisk.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>
int main(int n,char **v) {
    if(n!=3)return 64;
    int src=open(v[1],(!strcmp(v[2],"writable")?O_RDWR:O_RDONLY)|O_CLOEXEC);
    if(src<0)return 66;
    if(!strcmp(v[2],"shared") && flock(src,LOCK_SH|LOCK_NB))return 70;
    HGGuestDisk disk; const char *error=NULL;
    int status=hg_guest_disk_inspect_fd(src,&disk,&error);
    printf("{\\"ok\\":%s,\\"error\\":\\"%s\\",\\"fd\\":%d,\\"bytes\\":%llu,"
           "\\"partitions\\":%u,\\"first_apfs_lba\\":%llu,\\"last_apfs_lba\\":%llu,"
           "\\"readonly\\":%s,\\"cloexec\\":%s}\\n",
        status?"false":"true",error?error:"",disk.fd,(unsigned long long)disk.identity.st_size,
        disk.partitions,(unsigned long long)disk.first_apfs_lba,(unsigned long long)disk.last_apfs_lba,
        !status && (fcntl(disk.fd,F_GETFL)&O_ACCMODE)==O_RDONLY?"true":"false",
        !status && (fcntl(disk.fd,F_GETFD)&FD_CLOEXEC)?"true":"false");
    fflush(stdout);
    if(!strcmp(v[2],"hold") || !strcmp(v[2],"shared"))getchar();
    if(!status)printf("{\\"unchanged\\":%s}\\n",hg_guest_disk_unchanged(&disk)?"true":"false");
    hg_guest_disk_close(&disk); close(src);
    return status?1:0;
}
''')
        cls.control = folder / 'control'
        native = ROOT / 'compat/guest-provisioning'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-I', str(native),
                        str(source), str(native / 'HGGuestDisk.c'), '-lz', '-o', str(cls.control)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='henge-guest-disk-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'disk.img'
        self.sectors = 4096
        self.entries = bytearray(128 * 128)
        self.entry(0, APFS, 40, self.sectors - 40)
        self.emit()

    def entry(self, index, kind, first, last, guid=None):
        offset = index * 128
        self.entries[offset:offset + 16] = kind
        self.entries[offset + 16:offset + 32] = guid or uuid.UUID(int=index + 1).bytes_le
        struct.pack_into('<QQ', self.entries, offset + 32, first, last)

    def emit(self, primary_change=None, backup_change=None, mirror_change=None):
        primary = bytearray(512)
        primary[:8] = b'EFI PART'
        struct.pack_into('<IIII', primary, 8, 0x10000, 92, 0, 0)
        struct.pack_into('<QQQQ', primary, 24, 1, self.sectors - 1, 34, self.sectors - 34)
        primary[56:72] = uuid.UUID(int=12345).bytes_le
        struct.pack_into('<QIII', primary, 72, 2, 128, 128, zlib.crc32(self.entries))
        backup = bytearray(primary)
        struct.pack_into('<QQ', backup, 24, self.sectors - 1, 1)
        struct.pack_into('<Q', backup, 72, self.sectors - 33)
        for block, change in ((primary, primary_change), (backup, backup_change)):
            if change:
                change(block)
            struct.pack_into('<I', block, 16, 0)
            struct.pack_into('<I', block, 16, zlib.crc32(block[:92]))
        mirror = bytearray(self.entries)
        if mirror_change:
            mirror_change(mirror)
        mbr = bytearray(512)
        mbr[450] = 0xee
        mbr[510:512] = b'\x55\xaa'
        with self.path.open('wb') as stream:
            stream.truncate(self.sectors * 512)
            for offset, data in ((0, mbr), (512, primary), (1024, self.entries),
                                 ((self.sectors - 33) * 512, mirror), ((self.sectors - 1) * 512, backup)):
                stream.seek(offset)
                stream.write(data)

    def inspect(self, success=False, mode='inspect'):
        result = subprocess.run([str(self.control), str(self.path), mode], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(rows[0]['ok'], success)
        if not success:
            self.assertEqual(rows[0]['fd'], -1)
        return rows

    def hold(self, mode):
        process = subprocess.Popen([str(self.control), str(self.path), mode],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        row = json.loads(process.stdout.readline())
        return process, row

    def test_valid_metadata_is_readonly_and_unchanged(self):
        before = self.path.read_bytes()
        rows = self.inspect(True)
        self.assertTrue(rows[0]['readonly'])
        self.assertTrue(rows[0]['cloexec'])
        self.assertTrue(rows[1]['unchanged'])
        self.assertEqual(rows[0]['first_apfs_lba'], 40)
        self.assertEqual(before, self.path.read_bytes())

    def test_lease_blocks_alias_writers_and_readers_until_close(self):
        process, row = self.hold('hold')
        self.assertTrue(row['ok'])
        alias = self.path.with_name('alias.img')
        os.link(self.path, alias)
        with alias.open('rb') as stream:
            for operation in (fcntl.LOCK_EX, fcntl.LOCK_SH):
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(stream, operation | fcntl.LOCK_NB)
        process.communicate(b'\n', timeout=5)
        self.assertEqual(process.returncode, 0)
        with alias.open('rb') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_incoming_lock_is_not_converted_or_released(self):
        process, row = self.hold('shared')
        self.assertFalse(row['ok'])
        self.assertEqual(row['error'], 'image-in-use')
        with self.path.open('rb') as stream:
            fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)
            fcntl.flock(stream, fcntl.LOCK_UN)
            with self.assertRaises(BlockingIOError):
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        process.communicate(b'\n', timeout=5)
        self.assertEqual(process.returncode, 1)

    def test_writable_incoming_descriptor_is_rejected(self):
        self.inspect(mode='writable')

    def test_changes_after_inspection_are_detected(self):
        process, row = self.hold('hold')
        self.assertTrue(row['ok'])
        with self.path.open('r+b') as stream:
            stream.seek(100000)
            stream.write(b'changed fixture')
        output, _ = process.communicate(b'\n', timeout=5)
        self.assertFalse(json.loads(output)['unchanged'])

    def test_header_crc_and_mirrored_table(self):
        with self.path.open('r+b') as stream:
            stream.seek(512 + 56)
            stream.write(b'X')
        self.inspect()
        self.emit(mirror_change=lambda block: block.__setitem__(16, 99))
        self.inspect()

    def test_invalid_gpt_geometry_with_valid_header_crc(self):
        for offset, fmt, value in ((72, '<Q', 2**64 - 1), (80, '<I', 129),
                                   (84, '<I', 0), (84, '<I', 384), (40, '<Q', 3), (48, '<Q', self.sectors),
                                   (24, '<Q', 2), (32, '<Q', self.sectors - 2)):
            with self.subTest(offset=offset):
                self.emit(primary_change=lambda block: struct.pack_into(fmt, block, offset, value))
                self.inspect()

    def test_overlaps_duplicate_ids_and_multiple_apfs(self):
        other = uuid.UUID('c12a7328-f81f-11d2-ba4b-00a0c93ec93b').bytes_le
        for kind, first, last, guid in ((other, 39, 100, None),
                                        (other, 34, 39, uuid.UUID(int=1).bytes_le),
                                        (APFS, 34, 39, None)):
            with self.subTest(first=first, guid=guid):
                self.entry(1, kind, first, last, guid)
                self.emit()
                self.inspect()

    def test_no_apfs_and_nonsector_file(self):
        self.entries[:16] = uuid.UUID(int=10).bytes_le
        self.emit()
        self.inspect()
        with self.path.open('ab') as stream:
            stream.write(b'x')
        self.inspect()

    def test_unused_partition_slot_may_retain_stale_bytes(self):
        self.entries[128 + 56:128 + 70] = 'deleted'.encode('utf-16le')
        self.emit()
        self.inspect(True)


if __name__ == '__main__':
    unittest.main()
