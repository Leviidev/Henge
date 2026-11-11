"""Durable pre-swap intent and read-only inode-pair classification.

Only this authored-fixture test invokes renameatx_np to model an atomic swap;
the production intent API does not publish, roll back, or authorize VM boot.
"""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import test_guest_apfs as apfs

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin COW/exchange controls')
class GuestPublicationIntentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = tempfile.TemporaryDirectory(prefix='henge-publication-intent-build-')
        cls.addClassCleanup(cls.compiler.cleanup)
        folder = Path(cls.compiler.name)
        native = ROOT / 'compat/guest-provisioning'
        shim = folder / 'shim.c'
        shim.write_text(r'''
#include "HGGuestMedia.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode(const char *s){const char *m=getenv("HENGE_PUBLICATION_TEST");return m && !strcmp(m,s);}
int hg_guest_media_copy(const HGGuestDisk *disk,char **json,const char **error) {
 static int queries;queries++;(void)disk;
 *json=strdup(mode("busy") || (mode("copy-busy") && queries==2)?"[{}]":"[]");*error=NULL;return 0;
}
static int test_sync(int fd) {
 char path[4096];if(fcntl(fd,F_GETPATH,path))return -1;
 size_t n=strlen(path);
 if(n>=12 && !strcmp(path+n-12,"/publication")) {
  if(mode("sync-fail")){errno=EIO;return -1;}
  if(mode("corrupt")){char x='!';if(pwrite(fd,&x,1,0)!=1)abort();}
 }
 return fsync(fd);
}
#define fsync test_sync
#include "HGGuestPublicationIntent.c"
''')
        cls.control = folder / 'control'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-I', str(native), str(ROOT / 'tools/compat/guest_publication_intent_control.c'),
                        str(shim), *[str(native / f) for f in [
                            'HGGuestDisk.c', 'HGGuestAPFS.c', 'HGGuestClone.c',
                            'HGGuestRoles.c', 'HGGuestRoleWrite.c', 'HGGuestWorkspace.c',
                            'HGGuestWriteAuthority.c']], '-lz', '-o', str(cls.control)], check=True)
        cls.libc = ctypes.CDLL(None, use_errno=True)
        cls.swap = cls.libc.renameatx_np
        cls.swap.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        cls.swap.restype = ctypes.c_int

    def setUp(self):
        fixture = apfs.GuestAPFSTests(methodName='runTest')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.emit()
        self.source = fixture.path
        self.parent = fixture.path.parent / 'private'
        self.parent.mkdir(mode=0o700)
        self.original = self.source.read_bytes()

    def prepare(self, operation='prepare', mode='', valid=True):
        r = subprocess.run([str(self.control), operation, str(self.source), str(self.parent)],
                           env={**os.environ, 'HENGE_PUBLICATION_TEST': mode},
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0 if valid else 1, r.stdout + r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual(d['passed'], valid)
        self.assertTrue(d['source_unchanged'])
        self.assertEqual(self.original, self.source.read_bytes())
        self.workspace = self.parent / d['workspace']
        self.clone = self.workspace / d['clone']
        return d

    def inspect(self, valid=True):
        r = subprocess.run([str(self.control), 'inspect', str(self.source),
                            str(self.parent), self.workspace.name],
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0 if valid else 1, r.stdout + r.stderr)
        return json.loads(r.stdout)

    def exchange_fixture(self):
        left = os.open(self.source.parent, os.O_RDONLY | os.O_DIRECTORY)
        right = os.open(self.workspace, os.O_RDONLY | os.O_DIRECTORY)
        try:
            # Darwin RENAME_SWAP is 0x2; both files are authored scratch images.
            self.assertEqual(self.swap(left, self.source.name.encode(), right, self.clone.name.encode(), 2),
                             0, os.strerror(ctypes.get_errno()))
            os.fsync(left)
            os.fsync(right)
        finally:
            os.close(left)
            os.close(right)

    def test_durable_record_reopens_after_creator_exit(self):
        d = self.prepare()
        record = self.workspace / 'publication'
        self.assertEqual(record.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(record.read_bytes()), 1024)
        self.assertEqual(record.read_bytes()[:8], b'HGPB0001')
        self.assertEqual(d['pair'], 1)
        self.assertEqual(self.inspect()['pair'], 1)

    def test_inode_pair_classifies_atomic_exchange_and_rollback(self):
        self.prepare()
        original_inode, copy_inode = self.source.stat().st_ino, self.clone.stat().st_ino
        self.exchange_fixture()
        self.assertEqual((self.source.stat().st_ino, self.clone.stat().st_ino), (copy_inode, original_inode))
        self.assertEqual(self.inspect()['pair'], 2)
        self.assertEqual(self.clone.read_bytes(), self.original)
        self.exchange_fixture()
        self.assertEqual(self.inspect()['pair'], 1)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_unknown_inode_pair_never_treated_as_completed_swap(self):
        self.prepare()
        saved = self.clone.with_suffix('.saved')
        self.clone.rename(saved)
        self.clone.write_bytes(self.original)
        self.assertEqual(self.inspect(False)['error'], 'publication-pair-invalid')
        self.assertEqual(saved.read_bytes(), self.original)

    def test_tainted_or_neutralized_copies_rejected_before_record(self):
        for operation in ['tainted', 'neutral']:
            with self.subTest(operation=operation):
                self.prepare(operation=operation, valid=False)
                self.assertFalse((self.workspace / 'publication').exists())

    def test_busy_media_on_either_file_prevents_record_creation(self):
        for mode in ['busy', 'copy-busy']:
            with self.subTest(mode=mode):
                d = self.prepare(mode=mode, valid=False)
                self.assertEqual(d['error'], 'publication-media-cleanup-required')
                self.assertFalse((self.workspace / 'publication').exists())

    def test_failed_sync_or_readback_never_claims_durable_intent(self):
        for mode in ['sync-fail', 'corrupt']:
            with self.subTest(mode=mode):
                self.prepare(mode=mode, valid=False)
                self.assertTrue((self.workspace / 'publication').exists())
                self.assertTrue(self.clone.exists())

    def test_corrupt_or_substituted_record_is_preserved_and_refused(self):
        self.prepare()
        record = self.workspace / 'publication'
        original = record.read_bytes()
        record.write_bytes(b'partial')
        self.assertEqual(self.inspect(False)['error'], 'publication-intent-invalid')
        record.write_bytes(original)
        record.chmod(0o600)
        self.assertEqual(self.inspect()['pair'], 1)
        saved = record.with_suffix('.saved')
        record.rename(saved)
        record.symlink_to(saved)
        self.assertEqual(self.inspect(False)['error'], 'publication-intent-invalid')
        self.assertTrue(record.is_symlink())

    def test_generic_workspace_cleanup_preserves_pending_publication(self):
        self.prepare()
        for swapped in [False, True]:
            if swapped:
                self.exchange_fixture()
            before = {p.name: p.stat().st_ino for p in self.workspace.iterdir()}
            r = subprocess.run([str(self.control), 'discard', str(self.source),
                                str(self.parent), self.workspace.name],
                               capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertEqual(json.loads(r.stdout)['error'], 'workspace-entry-unknown')
            self.assertEqual(before, {p.name: p.stat().st_ino for p in self.workspace.iterdir()})
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.clone.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
