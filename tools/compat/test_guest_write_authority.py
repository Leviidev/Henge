"""Explicit caller write capability and rename-namespace permission controls.

No source writes or publication; principal UID is supplied by this native test,
not proof of kernel peer attestation in the future helper transport.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import test_guest_disk as gpt

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin descriptor/ACL controls')
class GuestWriteAuthorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = tempfile.TemporaryDirectory(prefix='henge-write-authority-build-')
        cls.addClassCleanup(cls.compiler.cleanup)
        directory = Path(cls.compiler.name)
        source = directory / 'control.c'
        source.write_text(r'''
#include "HGGuestWriteAuthority.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv) {
 if(argc!=4)return 64;
 int read_fd=open(argv[1],O_RDONLY|O_CLOEXEC);
 HGGuestDisk disk={.fd=-1};const char *error=NULL;
 if(hg_guest_disk_inspect_fd(read_fd,&disk,&error))return 65;
 int flags=!strcmp(argv[3],"readonly")?O_RDONLY:!strcmp(argv[3],"writeonly")?O_WRONLY:O_RDWR;
 if(!strcmp(argv[3],"append"))flags|=O_APPEND;
 int write_fd=open(argv[2],flags);
 if(write_fd>=0)assert(lseek(write_fd,77,SEEK_SET)==77);
 HGGuestWriteAuthority authority=HG_GUEST_WRITE_AUTHORITY_INIT;
 uid_t principal=geteuid()+(!strcmp(argv[3],"wrong-principal")?1:0);
 int status=hg_guest_write_authority_open(&disk,write_fd,principal,&authority,&error);
 if(!status) {
  const char *second=NULL;
  assert(hg_guest_write_authority_open(&disk,write_fd,principal,&authority,&second)==-1);
  assert(!strcmp(second,"write-authority-already-open"));
 }
 printf("{\"opened\":%s,\"error\":\"%s\",\"witness_cloexec\":%s,\"parent_cloexec\":%s}\n",
  status?"false":"true",error?error:"",
  !status && (fcntl(authority.witness_fd,F_GETFD)&FD_CLOEXEC)?"true":"false",
  !status && (fcntl(authority.directory_fd,F_GETFD)&FD_CLOEXEC)?"true":"false");fflush(stdout);
 if(!status) {
  (void)getchar();
  printf("{\"unchanged\":%s}\n",hg_guest_write_authority_unchanged(&authority)?"true":"false");
 }
 hg_guest_write_authority_close(&authority);
 assert(fcntl(read_fd,F_GETFD)>=0 && fcntl(disk.fd,F_GETFD)>=0);
 if(write_fd>=0)assert(fcntl(write_fd,F_GETFD)>=0 && lseek(write_fd,0,SEEK_CUR)==77);
 hg_guest_disk_close(&disk);close(read_fd);if(write_fd>=0)close(write_fd);
 return status?1:0;
}
''')
        native = ROOT / 'compat/guest-provisioning'
        cls.control = directory / 'control'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-I', str(native), str(source), str(native / 'HGGuestDisk.c'),
                        str(native / 'HGGuestWriteAuthority.c'), '-lz', '-o', str(cls.control)], check=True)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='henge-write-authority-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.parent = Path(self.directory.name) / 'machine'
        self.parent.mkdir(mode=0o700)
        self.path = self.parent / 'source.img'
        image = gpt.GuestDiskTests(methodName='runTest')
        image.path, image.sectors = self.path, 4096
        image.entries = bytearray(128 * 128)
        image.entry(0, gpt.APFS, 40, image.sectors - 40)
        image.emit()
        self.original = self.path.read_bytes()

    def start(self, mode='normal', witness=None, approved=True):
        process = subprocess.Popen([str(self.control), str(self.path), str(witness or self.path), mode],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        line = process.stdout.readline()
        self.assertTrue(line, process.stderr.read() if process.poll() is not None else 'No control report')
        report = json.loads(line)
        self.assertEqual(report['opened'], approved, report)
        if approved:
            self.assertTrue(report['witness_cloexec'] and report['parent_cloexec'])
        else:
            out, err = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1, out + err)
        return process

    def finish(self, process, unchanged=True):
        out, err = process.communicate('\n', timeout=5)
        self.assertEqual(process.returncode, 0, out + err)
        self.assertEqual(json.loads(out)['unchanged'], unchanged)

    def test_explicit_witness_preserves_source_and_borrowed_descriptors(self):
        self.finish(self.start())
        self.assertEqual(self.original, self.path.read_bytes())

    def test_readonly_writeonly_and_append_witnesses_rejected(self):
        for mode in ['readonly', 'writeonly', 'append']:
            with self.subTest(mode=mode):
                self.start(mode=mode, approved=False)
        self.assertEqual(self.original, self.path.read_bytes())

    def test_different_inode_or_principal_cannot_authorize(self):
        other = self.parent / 'other.img'
        other.write_bytes(self.original)
        self.start(witness=other, approved=False)
        self.start(mode='wrong-principal', approved=False)
        self.assertEqual(self.original, self.path.read_bytes())

    def test_writable_file_without_directory_write_permission_is_not_enough(self):
        self.parent.chmod(0o500)
        try:
            self.start(approved=False)
        finally:
            self.parent.chmod(0o700)

    def test_group_or_other_writable_parent_rejected(self):
        for mode in [0o770, 0o777]:
            self.parent.chmod(mode)
            try:
                self.start(approved=False)
            finally:
                self.parent.chmod(0o700)

    def test_readable_nonwritable_to_others_parent_is_allowed(self):
        self.parent.chmod(0o755)
        self.finish(self.start())

    def test_source_or_parent_extended_acl_rejected(self):
        for path, acl in [(self.path, 'everyone allow read'),
                          (self.parent, 'everyone allow read,search')]:
            subprocess.run(['chmod', '+a', acl, str(path)], check=True)
            try:
                self.start(approved=False)
            finally:
                subprocess.run(['chmod', '-N', str(path)], check=True)

    def test_source_link_alias_rejected(self):
        other = self.parent / 'alias.img'
        os.link(self.path, other)
        self.start(approved=False)
        other.unlink()
        self.finish(self.start())

    def test_namespace_replacement_invalidates_live_authority(self):
        process = self.start()
        saved = self.parent / 'saved.img'
        self.path.rename(saved)
        self.path.write_bytes(b'preserve replacement')
        self.finish(process, False)
        self.assertEqual(saved.read_bytes(), self.original)
        self.assertEqual(self.path.read_bytes(), b'preserve replacement')

    def test_late_permissions_or_contents_change_invalidates(self):
        process = self.start()
        self.parent.chmod(0o777)
        self.finish(process, False)
        self.parent.chmod(0o700)
        process = self.start()
        with self.path.open('r+b') as stream:
            stream.seek(-1, os.SEEK_END)
            stream.write(b'!')
        self.finish(process, False)

    def test_late_acl_invalidates(self):
        process = self.start()
        subprocess.run(['chmod', '+a', 'everyone allow read,search', str(self.parent)], check=True)
        try:
            self.finish(process, False)
        finally:
            subprocess.run(['chmod', '-N', str(self.parent)], check=True)


if __name__ == '__main__':
    unittest.main()
