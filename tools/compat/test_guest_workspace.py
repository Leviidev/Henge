"""Cross-process discard-only recovery of private COW copies; never mounts."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import test_guest_apfs as apfs

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin private COW/leases')
class GuestWorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = tempfile.TemporaryDirectory(prefix='henge-workspace-build-')
        cls.addClassCleanup(cls.compiler.cleanup)
        directory = Path(cls.compiler.name)
        native = ROOT / 'compat/guest-provisioning'
        shim = directory / 'shim.c'
        shim.write_text(r'''
#include "HGGuestMedia.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode(const char *s) { const char *m=getenv("HENGE_WORKSPACE_TEST");return m && !strcmp(m,s); }
int hg_guest_media_copy(const HGGuestDisk *disk,char **json,const char **error) {
 if(mode("inventory-error")){*json=NULL;*error="test-inventory-error";return -1;}
 if(mode("replace")) {
  char path[4096],saved[4096];
  if(fcntl(disk->fd,F_GETPATH,path) || strlen(path)>4080)abort();
  strcpy(saved,path);strcat(saved,".saved");if(rename(path,saved))abort();
  int fd=open(path,O_CREAT|O_EXCL|O_WRONLY,0600);
  if(fd<0 || write(fd,"preserve replacement",20)!=20)abort();close(fd);
 }
 if(mode("add-unknown")) {
  char path[4096];if(fcntl(disk->fd,F_GETPATH,path))abort();
  char *slash=strrchr(path,'/');if(!slash)abort();strcpy(slash+1,"unknown");
  int fd=open(path,O_CREAT|O_EXCL|O_WRONLY,0600);if(fd<0)abort();close(fd);
 }
 *json=strdup(mode("busy")?"[{}]":"[]");*error=NULL;return 0;
}
static int test_sync(int fd) {
 static int failed;char path[4096];if(fcntl(fd,F_GETPATH,path))return -1;
 if(mode("parent-sync") && !strstr(path,"henge-txn-") && !failed++) {errno=EIO;return -1;}
 return fsync(fd);
}
#define fsync test_sync
#include "HGGuestWorkspace.c"
''')
        cls.control = directory / 'control'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-I', str(native), str(ROOT / 'tools/compat/guest_workspace_control.c'),
                        str(shim), *[str(native / f) for f in [
                            'HGGuestDisk.c', 'HGGuestAPFS.c', 'HGGuestClone.c',
                            'HGGuestRoles.c', 'HGGuestRoleWrite.c']],
                        '-lz', '-o', str(cls.control)], check=True)

    def setUp(self):
        self.fixture = apfs.GuestAPFSTests(methodName='runTest')
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.emit()
        self.parent = self.fixture.path.parent / 'private'
        self.parent.mkdir(mode=0o700)
        self.original = self.fixture.path.read_bytes()

    def create(self, operation='create'):
        r = subprocess.run([str(self.control), operation, str(self.fixture.path), str(self.parent)],
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        d = json.loads(r.stdout)
        self.assertTrue(d['passed'])
        self.workspace = self.parent / d['workspace']
        self.clone = self.workspace / d['clone']
        return d

    def recover(self, valid=True, mode='', retry=False):
        r = subprocess.run([str(self.control), 'recover-retry' if retry else 'recover',
                            str(self.parent), self.workspace.name], capture_output=True, text=True,
                           env={**os.environ, 'HENGE_WORKSPACE_TEST': mode}, timeout=10)
        self.assertEqual(r.returncode, 0 if valid else 1, r.stderr + r.stdout)
        d = json.loads(r.stdout)
        self.assertEqual(d['passed'], valid)
        self.assertEqual(self.original, self.fixture.path.read_bytes())
        if valid:
            self.assertFalse(self.workspace.exists())
        return d

    def test_cross_process_recovery_after_abrupt_exit(self):
        self.create()
        self.assertEqual(self.workspace.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.workspace / 'owner').stat().st_mode & 0o777, 0o600)
        self.assertEqual(len((self.workspace / 'owner').read_bytes()), 96)
        self.recover()

    def test_recovery_after_role_mutation_and_journal_creation(self):
        self.create('roles')
        self.assertEqual(len(list(self.workspace.iterdir())), 3)
        self.recover()

    def test_torn_apfs_block_does_not_require_mount_or_replay(self):
        self.create('roles')
        with self.clone.open('r+b') as f:
            f.seek(40 * 512 + 5 * 4096)
            f.write(b'broken checksum and metadata')
            f.flush()
            os.fsync(f.fileno())
        self.recover()

    def test_live_workspace_lock_refuses_recovery(self):
        process = subprocess.Popen([str(self.control), 'hold', str(self.fixture.path), str(self.parent)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        d = json.loads(process.stdout.readline())
        self.workspace = self.parent / d['workspace']
        self.assertEqual(self.recover(False)['error'], 'workspace-in-use')
        process.communicate('\n', timeout=10)
        self.recover()

    def test_busy_or_unavailable_media_preserve_every_file(self):
        for mode in ['busy', 'inventory-error']:
            with self.subTest(mode=mode):
                self.create('roles')
                before = {p.name: p.stat().st_ino for p in self.workspace.iterdir()}
                self.assertEqual(self.recover(False, mode)['error'], 'workspace-media-cleanup-required')
                self.assertEqual(before, {p.name: p.stat().st_ino for p in self.workspace.iterdir()})
                self.recover()

    def test_unknown_files_and_symlinks_preserved(self):
        self.create()
        unknown = self.workspace / 'unknown'
        unknown.write_text('preserve')
        self.recover(False)
        self.assertTrue(self.clone.exists())
        unknown.unlink()
        saved = self.clone.with_suffix('.saved')
        self.clone.rename(saved)
        self.clone.symlink_to(self.fixture.path)
        self.recover(False)
        self.assertTrue(self.clone.is_symlink())
        self.clone.unlink()
        saved.rename(self.clone)
        self.recover()

    def test_hardlinks_never_unlinked(self):
        self.create()
        link = self.fixture.path.parent / 'extra-link'
        os.link(self.clone, link)
        self.recover(False)
        self.assertTrue(link.exists())
        link.unlink()
        self.recover()

    def test_receipt_protects_original_source_inode_even_if_moved(self):
        self.create()
        saved = self.fixture.path.parent / 'copy-saved.img'
        self.clone.rename(saved)
        original_inode = self.fixture.path.stat().st_ino
        self.fixture.path.rename(self.clone)
        self.fixture.path.write_bytes(self.original)
        self.recover(False)
        self.assertEqual(self.clone.stat().st_ino, original_inode)
        self.fixture.path.unlink()
        self.clone.rename(self.fixture.path)
        saved.rename(self.clone)
        self.recover()

    def test_partial_journal_is_discarded_without_replay(self):
        self.create()
        journal = self.clone.with_name(self.clone.name + '.roles-' + '0' * 16)
        journal.write_bytes(b'partial journal')
        journal.chmod(0o600)
        self.recover()

    def test_namespace_count_bound_preserves_all_files(self):
        self.create()
        journals = []
        for i in range(128):
            path = self.clone.with_name(self.clone.name + '.roles-' + f'{i:016x}')
            path.touch(mode=0o600)
            journals.append(path)
        self.recover(False)
        self.assertTrue(self.clone.exists())
        self.assertTrue(all(p.exists() for p in journals))
        for path in journals:
            path.unlink()
        self.recover()

    def test_live_image_lock_prevents_cleanup(self):
        self.create()
        with self.clone.open('rb') as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.recover(False)['error'], 'workspace-file-in-use')
        self.recover()

    def test_receipt_cannot_be_transplanted_to_replacement_directory(self):
        self.create()
        old = self.workspace.with_name(self.workspace.name + '-saved')
        self.workspace.rename(old)
        self.workspace.mkdir(mode=0o700)
        (self.workspace / 'owner').write_bytes((old / 'owner').read_bytes())
        (self.workspace / 'owner').chmod(0o600)
        self.assertEqual(self.recover(False)['error'], 'workspace-receipt-invalid')
        (self.workspace / 'owner').unlink()
        self.workspace.rmdir()
        old.rename(self.workspace)
        self.recover()

    def test_namespace_replacement_during_inventory_is_preserved(self):
        self.create()
        self.assertEqual(self.recover(False, 'replace')['error'], 'workspace-entry-changed')
        self.assertEqual(self.clone.read_bytes(), b'preserve replacement')
        self.clone.unlink()
        self.clone.with_name(self.clone.name + '.saved').rename(self.clone)
        self.recover()

    def test_added_unknown_entry_prevents_all_unlinks(self):
        self.create('roles')
        before = {p.name: p.stat().st_ino for p in self.workspace.iterdir()}
        self.assertEqual(self.recover(False, 'add-unknown')['error'], 'workspace-namespace-changed')
        for name, inode in before.items():
            self.assertEqual((self.workspace / name).stat().st_ino, inode)
        (self.workspace / 'unknown').unlink()
        self.recover()

    def test_cleanup_resumes_when_image_was_already_unlinked(self):
        self.create('roles')
        self.clone.unlink()
        self.recover()

    def test_damaged_or_missing_receipt_preserves_artifacts(self):
        self.create('roles')
        owner = self.workspace / 'owner'
        original = owner.read_bytes()
        owner.write_bytes(b'partial')
        self.assertEqual(self.recover(False)['error'], 'workspace-receipt-invalid')
        self.assertTrue(self.clone.exists())
        owner.write_bytes(original)
        self.recover()

    def test_parent_sync_failure_retries_without_deleting_new_names(self):
        self.create()
        r = self.recover(True, 'parent-sync', retry=True)
        self.assertEqual(r['first_error'], 'workspace-parent-sync')

    def test_untrusted_parent_and_invalid_name_refused(self):
        self.create()
        self.parent.chmod(0o755)
        self.assertEqual(self.recover(False)['error'], 'workspace-parent')
        self.parent.chmod(0o700)
        r = subprocess.run([str(self.control), 'recover', str(self.parent), '../outside'],
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(json.loads(r.stdout)['error'], 'workspace-name')
        self.recover()

    def test_extended_acl_is_not_mistaken_for_private_mode(self):
        self.create()
        for path, error in [(self.parent, 'workspace-parent'),
                            (self.workspace, 'workspace-identity')]:
            with self.subTest(path=path):
                subprocess.run(['chmod', '+a', 'everyone allow read,search', str(path)], check=True)
                try:
                    self.assertEqual(path.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(self.recover(False)['error'], error)
                finally:
                    subprocess.run(['chmod', '-N', str(path)], check=True)
        self.recover()


if __name__ == '__main__':
    unittest.main()
