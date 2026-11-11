"""Real ad-hoc CodeDirectory/page verification plus malformed-file controls."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin Mach-O codesign')
class GuestCodeIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='henge-code-identity-')
        cls.addClassCleanup(cls.directory.cleanup)
        folder = Path(cls.directory.name)
        native = ROOT / 'compat/guest-provisioning'
        source = folder / 'control.c'
        source.write_text(r'''
#include "HGGuestCodeIdentity.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int n,char **v) {
 if(n!=3 && n!=4)return 64;unsigned char hash[20];
 if(strlen(v[2])!=40)return 64;
 for(unsigned i=0;i<20;i++){unsigned x;if(sscanf(v[2]+i*2,"%2x",&x)!=1)return 64;hash[i]=(unsigned char)x;}
 int fd=open(v[1],n==4?O_RDWR:O_RDONLY);if(fd<0)return 65;
 assert(lseek(fd,77,SEEK_SET)==77);const char *error=NULL;
 int r=hg_guest_code_identity_matches(fd,hash,&error);
 assert(fcntl(fd,F_GETFD)>=0 && lseek(fd,0,SEEK_CUR)==77);
 printf("{\"passed\":%s,\"error\":\"%s\"}\n",r?"false":"true",error?error:"");close(fd);return r?1:0;
}
''')
        cls.control = folder / 'control'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(native),
                        str(source), str(native / 'HGGuestCodeIdentity.c'), '-o', str(cls.control)], check=True)
        fixture = folder / 'fixture.c'
        fixture.write_text('int main(void){return 0;}\n')
        cls.signed = folder / 'signed'
        subprocess.run(['xcrun', 'clang', str(fixture), '-o', str(cls.signed)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(cls.signed)],
                       check=True, capture_output=True)
        cls.data = cls.signed.read_bytes()
        count = struct.unpack_from('<I', cls.data, 16)[0]
        off = 32
        for _ in range(count):
            command, size = struct.unpack_from('<II', cls.data, off)
            if command == 0x1d:
                cls.signature, cls.signature_size = struct.unpack_from('<II', cls.data, off + 8)
            off += size
        count = struct.unpack_from('>I', cls.data, cls.signature + 8)[0]
        for i in range(count):
            kind, offset = struct.unpack_from('>II', cls.data, cls.signature + 12 + i * 8)
            if kind == 0:
                cls.directory_offset = cls.signature + offset
        cls.directory_length = struct.unpack_from('>I', cls.data, cls.directory_offset + 4)[0]
        cls.hash = cls.cdhash(cls.data)

    @classmethod
    def cdhash(cls, data):
        return hashlib.sha256(data[cls.directory_offset:cls.directory_offset + cls.directory_length]).hexdigest()[:40]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='henge-code-file-')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'image'
        self.path.write_bytes(self.data)

    def check(self, valid=False, expected=None, write=False):
        before = self.path.read_bytes()
        r = subprocess.run([str(self.control), str(self.path), expected or self.hash] + (['write'] if write else []),
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0 if valid else 1, r.stdout + r.stderr)
        report = json.loads(r.stdout)
        self.assertEqual(report['passed'], valid)
        self.assertEqual(before, self.path.read_bytes())
        return report

    def test_real_signed_executable_and_borrowed_fd(self):
        self.check(True)

    def test_wrong_kernel_hash(self):
        self.assertEqual(self.check(expected='0' * 40)['error'], 'peer-code-directory-mismatch')

    def test_covered_bytes_tampered_with_old_directory_intact(self):
        data = bytearray(self.data)
        data[self.signature - 1] ^= 1
        self.path.write_bytes(data)
        self.assertEqual(self.check()['error'], 'peer-code-page-mismatch')

    def test_bad_directory_ranges_even_with_matching_simulated_hash(self):
        for offset, value in [(16, 0xffffffff), (28, 0xffffffff), (32, 1), (44, 1)]:
            with self.subTest(offset=offset):
                data = bytearray(self.data)
                struct.pack_into('>I', data, self.directory_offset + offset, value)
                self.path.write_bytes(data)
                self.check(expected=self.cdhash(data))

    def test_unsupported_page_profile(self):
        data = bytearray(self.data)
        data[self.directory_offset + 39] = 1
        self.path.write_bytes(data)
        self.assertEqual(self.check(expected=self.cdhash(data))['error'], 'peer-code-directory-profile')

    def test_superblob_bounds(self):
        for offset, value in [(4, 0xffffffff), (8, 33), (16, 0xffffffff)]:
            with self.subTest(offset=offset):
                data = bytearray(self.data)
                struct.pack_into('>I', data, self.signature + offset, value)
                self.path.write_bytes(data)
                self.check()

    def test_macho_bounds_truncation_and_unsigned_input(self):
        for data in [self.data[:100], b'not a Mach-O executable' * 8,
                     self.data[:self.signature], self.data + b'uncovered data']:
            self.path.write_bytes(data)
            self.check()

    def test_writable_expected_executable_fd_refused(self):
        self.check(write=True)

    def test_unused_signature_alignment_tail_is_not_treated_as_code(self):
        data = bytearray(self.data)
        length = struct.unpack_from('>I', data, self.signature + 4)[0]
        if length == self.signature_size:
            self.skipTest('This toolchain produced no signature alignment tail')
        self.assertLessEqual(self.signature_size, 4 * 1024 * 1024)
        data[self.signature + length] ^= 0x5a
        self.path.write_bytes(data)
        self.check(True)


if __name__ == '__main__':
    unittest.main()
