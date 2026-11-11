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
 if(mode("rollback-private-changed") && queries==2) {struct stat st;if(fstat(disk->fd,&st) || fchmod(disk->fd,(st.st_mode&0777)^0001))abort();}
 *json=strdup(mode("busy") || (mode("copy-busy") && queries==2) || (mode("handoff-busy") && queries==3)?"[{}]":"[]");*error=NULL;return 0;
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
        metadata_shim=folder/'metadata-shim.c'
        metadata_shim.write_text(r'''
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int mode(const char *s){const char *m=getenv("HENGE_PUBLICATION_TEST");return m && !strcmp(m,s);}
static int test_chown(int fd,uid_t uid,gid_t gid) {
 if(mode("metadata-chown-fail")){errno=EPERM;return -1;}return fchown(fd,uid,gid);
}
static int test_chmod(int fd,mode_t permissions) {
 if(mode("metadata-chmod-fail")){errno=EIO;return -1;}return fchmod(fd,permissions);
}
static int test_sync(int fd) {
 if(mode("metadata-sync-fail")){errno=EIO;return -1;}return fsync(fd);
}
#define fchown test_chown
#define fchmod test_chmod
#define fsync test_sync
#include "HGGuestPublicationMetadata.c"
''')
        snapshot_shim=folder/'snapshot-shim.c'
        snapshot_shim.write_text(r'''
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode(const char *s){const char *m=getenv("HENGE_PUBLICATION_TEST");return m && !strcmp(m,s);}
static int test_sync(int fd) {
 char path[4096];if(fcntl(fd,F_GETPATH,path))return -1;
 const char *name=strrchr(path,'/');
 if(name && !strcmp(name,"/snapshot-invalidation") && mode("snapshot-sync-fail")){errno=EIO;return -1;}
 return fsync(fd);
}
static int test_rename(int a,const char *b,int c,const char *d,unsigned flags) {
 static int calls;calls++;
 if(calls==2 && mode("snapshot-second-rename-fail")){errno=EIO;return -1;}
 return renameatx_np(a,b,c,d,flags);
}
#define fsync test_sync
#define renameatx_np test_rename
#include "HGGuestSnapshotInvalidation.c"
''')
        rollback_shim=folder/'rollback-shim.c'
        rollback_shim.write_text(r'''
#include "HGGuestPeer.h"
#include <sys/stat.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int mode(const char *s){const char *m=getenv("HENGE_PUBLICATION_TEST");return m && !strcmp(m,s);}
int hg_guest_peer_unchanged(int fd,const HGGuestPeer *peer,const char **error) {
 static int calls;calls++;(void)fd;
 if(!peer->verified || (calls==2 && mode("rollback-peer-change")) || (calls==3 && mode("rollback-peer-late-change"))){*error="peer-parent-changed";return -1;}
 *error=NULL;return 0;
}
static int test_sync(int fd) {
 static int calls;calls++;
 if(calls==1 && mode("rollback-parent-change") && fchmod(fd,0500))abort();
 if(mode("rollback-sync-fail")){errno=EIO;return -1;}return fsync(fd);
}
static int test_rename(int a,const char *b,int c,const char *d,unsigned flags) {
 if(mode("rollback-rename-fail")){errno=EIO;return -1;}return renameatx_np(a,b,c,d,flags);
}
#define fsync test_sync
#define renameatx_np test_rename
#include "HGGuestPublicationRollback.c"
''')
        cls.control = folder / 'control'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-I', str(native), str(ROOT / 'tools/compat/guest_publication_intent_control.c'),
                        str(shim), str(metadata_shim), str(snapshot_shim), str(rollback_shim), *[str(native / f) for f in [
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
        self.source = fixture.path.with_name("disk.img")
        fixture.path.rename(self.source)
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

    def rollback(self, valid=True, mode=''):
        r=subprocess.run([str(self.control),'rollback',str(self.source),str(self.parent),self.workspace.name],
                         capture_output=True,text=True,timeout=10,env={**os.environ,'HENGE_PUBLICATION_TEST':mode})
        self.assertEqual(r.returncode,0 if valid else 1,r.stdout+r.stderr)
        return json.loads(r.stdout)

    def test_native_rollback_restores_original_and_preserves_failed_copy(self):
        self.prepare(operation='ready')
        with self.clone.open('r+b') as f:
            f.seek(1024*1024);f.write(b'authored uncommitted guest changes')
        failed=self.clone.read_bytes()
        original_inode,copy_inode=self.source.stat().st_ino,self.clone.stat().st_ino
        self.exchange_fixture()
        d=self.rollback()
        self.assertTrue(d['exchange_attempted']);self.assertTrue(d['rollback_durable']);self.assertEqual(d['rollback_pair'],1)
        self.assertEqual((self.source.stat().st_ino,self.clone.stat().st_ino),(original_inode,copy_inode))
        self.assertEqual(self.source.read_bytes(),self.original);self.assertEqual(self.clone.read_bytes(),failed)
        d=self.rollback()
        self.assertFalse(d['exchange_attempted']);self.assertTrue(d['rollback_durable']);self.assertEqual(d['rollback_pair'],1)
        self.assertEqual(self.clone.read_bytes(),failed)

    def test_native_rollback_sync_failure_retries_without_second_exchange(self):
        self.prepare(operation='ready');self.exchange_fixture()
        d=self.rollback(False,mode='rollback-sync-fail')
        self.assertTrue(d['exchange_attempted']);self.assertFalse(d['rollback_durable']);self.assertEqual(d['rollback_pair'],1)
        self.assertEqual(d['error'],'publication-rollback-sync')
        self.assertEqual(self.source.read_bytes(),self.original)
        d=self.rollback()
        self.assertFalse(d['exchange_attempted']);self.assertTrue(d['rollback_durable'])

    def test_native_rollback_late_peer_or_namespace_change_never_grants_durability(self):
        for mode in ('rollback-peer-late-change','rollback-parent-change'):
            with self.subTest(mode=mode):
                self.prepare(operation='ready');self.exchange_fixture()
                try:
                    d=self.rollback(False,mode=mode)
                    self.assertTrue(d['exchange_attempted']);self.assertFalse(d['rollback_durable'])
                    self.assertEqual(d['rollback_pair'],1);self.assertEqual(self.source.read_bytes(),self.original)
                finally:
                    self.source.parent.chmod(0o700)
                d=self.rollback()
                self.assertFalse(d['exchange_attempted']);self.assertTrue(d['rollback_durable'])

    def test_native_rollback_refuses_changed_peer_media_and_syscall_failure(self):
        self.prepare(operation='ready');self.exchange_fixture()
        copy_inode=self.source.stat().st_ino
        for mode in ('rollback-wrong-uid','rollback-peer-change','busy','copy-busy','rollback-rename-fail'):
            with self.subTest(mode=mode):
                d=self.rollback(False,mode=mode)
                self.assertFalse(d['rollback_durable']);self.assertEqual(self.source.stat().st_ino,copy_inode)
                self.assertEqual(self.inspect()['pair'],2)
                self.assertEqual(self.clone.read_bytes(),self.original)
        self.assertTrue(self.rollback()['rollback_durable'])

    def test_native_rollback_refuses_new_saved_state_and_private_metadata_changes(self):
        self.prepare(operation='ready');self.exchange_fixture()
        copy_inode=self.source.stat().st_ino
        saved=self.source.parent/'resume.hsnap';saved.write_bytes(b'new saved state')
        d=self.rollback(False)
        self.assertFalse(d['exchange_attempted']);self.assertEqual(saved.read_bytes(),b'new saved state')
        self.assertEqual(self.source.stat().st_ino,copy_inode);saved.unlink()
        d=self.rollback(False,mode='rollback-private-changed')
        self.assertFalse(d['exchange_attempted']);self.assertEqual(self.source.stat().st_ino,copy_inode)
        self.assertEqual(self.clone.read_bytes(),self.original)

    def snapshot_inspect(self, valid=True, complete=False, mode=""):
        r=subprocess.run([str(self.control),'snapshot-complete' if complete else 'snapshot-inspect',str(self.source),str(self.parent),self.workspace.name],
                         capture_output=True,text=True,timeout=10,env={**os.environ,"HENGE_PUBLICATION_TEST":mode})
        self.assertEqual(r.returncode,0 if valid else 1,r.stdout+r.stderr)
        return json.loads(r.stdout)

    def test_snapshot_quarantine_is_durable_and_preserves_bytes_inodes(self):
        saved=self.source.parent/'resume.hsnap';partial=self.source.parent/'resume.hsnap.part'
        saved.write_bytes(b'authored saved RAM');partial.write_bytes(b'authored partial RAM')
        identities=(saved.stat().st_ino,partial.stat().st_ino)
        self.prepare(operation='snapshot')
        self.assertFalse(saved.exists());self.assertFalse(partial.exists())
        quarantined=(self.workspace/'ram-resume.hsnap',self.workspace/'ram-resume.hsnap.part')
        self.assertEqual(tuple(p.stat().st_ino for p in quarantined),identities)
        self.assertEqual(tuple(p.read_bytes() for p in quarantined),(b'authored saved RAM',b'authored partial RAM'))
        self.assertEqual((self.workspace/'snapshot-invalidation').stat().st_mode & 0o777,0o600)
        self.assertTrue(self.snapshot_inspect()['passed'])
        retained={p.name:p.stat().st_ino for p in self.workspace.iterdir()}
        r=subprocess.run([str(self.control),'discard',str(self.source),str(self.parent),self.workspace.name],
                         capture_output=True,text=True,timeout=10)
        self.assertEqual(r.returncode,1)
        self.assertEqual(retained,{p.name:p.stat().st_ino for p in self.workspace.iterdir()})

    def test_no_snapshot_still_requires_durable_absence_receipt(self):
        self.prepare(operation='snapshot')
        self.assertTrue(self.snapshot_inspect()['passed'])
        (self.source.parent/'resume.hsnap').write_bytes(b'new saved RAM')
        self.assertEqual(self.snapshot_inspect(False)['error'],'snapshot-invalidation-incomplete')
        self.assertEqual((self.source.parent/'resume.hsnap').read_bytes(),b'new saved RAM')

    def test_snapshot_absence_verify_survives_swap_but_recovery_refuses_swapped_pair(self):
        self.prepare(operation='snapshot')
        self.exchange_fixture()
        self.assertTrue(self.snapshot_inspect()['passed'])
        self.assertEqual(self.snapshot_inspect(False,complete=True)['error'],'snapshot-invalidation-precondition')
        self.exchange_fixture()
        self.assertTrue(self.snapshot_inspect(complete=True)['passed'])

    def test_snapshot_completion_rejects_new_source_metadata_after_restart(self):
        self.source.chmod(0o600)
        self.prepare(operation='snapshot')
        self.source.chmod(0o640)
        self.assertEqual(self.snapshot_inspect(False,complete=True)['error'],'publication-authority-record')
        self.assertEqual(self.source.stat().st_mode & 0o777,0o640)
        self.assertTrue(self.snapshot_inspect()['passed'])

    def test_snapshot_receipt_cannot_be_reused_for_another_publication(self):
        self.prepare(operation='snapshot')
        receipt=(self.workspace/'snapshot-invalidation').read_bytes()
        self.prepare(operation='snapshot')
        (self.workspace/'snapshot-invalidation').write_bytes(receipt)
        self.assertEqual(self.snapshot_inspect(False)['error'],'snapshot-invalidation-receipt')

    def test_snapshot_partial_move_retains_both_and_refuses_completion(self):
        saved=self.source.parent/'resume.hsnap';partial=self.source.parent/'resume.hsnap.part'
        saved.write_bytes(b'first');partial.write_bytes(b'second')
        d=self.prepare(operation='snapshot',mode='snapshot-second-rename-fail',valid=False)
        self.assertEqual(d['error'],'snapshot-invalidation-rename')
        self.assertFalse(saved.exists());self.assertEqual((self.workspace/'ram-resume.hsnap').read_bytes(),b'first')
        self.assertEqual(partial.read_bytes(),b'second')
        self.assertEqual(self.snapshot_inspect(False)['error'],'snapshot-invalidation-incomplete')
        self.assertTrue(self.snapshot_inspect(complete=True)['passed'])
        self.assertFalse(partial.exists())
        self.assertEqual((self.workspace/'ram-resume.hsnap.part').read_bytes(),b'second')
        self.assertTrue(self.snapshot_inspect(complete=True)['passed'])

    def test_snapshot_recovery_preflights_all_names_before_moving_any(self):
        saved=self.source.parent/'resume.hsnap';saved.write_bytes(b'first')
        partial=self.source.parent/'resume.hsnap.part';partial.write_bytes(b'second')
        self.prepare(operation='snapshot',mode='snapshot-sync-fail',valid=False)
        self.snapshot_inspect(False,complete=True,mode='snapshot-sync-fail')
        self.assertEqual(saved.read_bytes(),b'first');self.assertEqual(partial.read_bytes(),b'second')
        retained=partial.with_suffix('.retained');partial.rename(retained);partial.write_bytes(b'replacement')
        self.assertFalse(self.snapshot_inspect(False,complete=True)['passed'])
        self.assertEqual(saved.read_bytes(),b'first')
        self.assertFalse((self.workspace/'ram-resume.hsnap').exists())
        partial.unlink();retained.rename(partial)
        self.assertTrue(self.snapshot_inspect(complete=True)['passed'])

    def test_snapshot_sync_failure_moves_nothing(self):
        saved=self.source.parent/'resume.hsnap';saved.write_bytes(b'unchanged RAM')
        d=self.prepare(operation='snapshot',mode='snapshot-sync-fail',valid=False)
        self.assertEqual(d['error'],'snapshot-invalidation-sync')
        self.assertEqual(saved.read_bytes(),b'unchanged RAM')
        self.assertFalse((self.workspace/'ram-resume.hsnap').exists())
        self.assertTrue((self.workspace/'snapshot-invalidation').exists())

    def test_snapshot_symlink_hardlink_and_busy_files_refused_before_receipt(self):
        import fcntl
        saved=self.source.parent/'resume.hsnap'
        target=self.source.parent/'ram-target';target.write_bytes(b'private RAM')
        saved.symlink_to(target)
        self.prepare(operation='snapshot',valid=False)
        self.assertFalse((self.workspace/'snapshot-invalidation').exists());saved.unlink()
        os.link(target,saved)
        self.prepare(operation='snapshot',valid=False)
        self.assertFalse((self.workspace/'snapshot-invalidation').exists());saved.unlink()
        saved.write_bytes(b'locked RAM')
        with saved.open('rb') as f:
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.prepare(operation='snapshot',valid=False)
            self.assertFalse((self.workspace/'snapshot-invalidation').exists())
        self.assertEqual(saved.read_bytes(),b'locked RAM')

    def test_snapshot_receipt_corruption_and_quarantine_replacement_are_refused(self):
        saved=self.source.parent/'resume.hsnap';saved.write_bytes(b'known RAM')
        self.prepare(operation='snapshot')
        record=self.workspace/'snapshot-invalidation';original=record.read_bytes()
        record.write_bytes(b'partial')
        self.assertEqual(self.snapshot_inspect(False)['error'],'snapshot-invalidation-receipt')
        record.write_bytes(original)
        private=self.workspace/'ram-resume.hsnap';retained=private.with_suffix('.retained');private.rename(retained)
        private.write_bytes(b'known RAM')
        self.assertEqual(self.snapshot_inspect(False)['error'],'snapshot-invalidation-incomplete')
        self.assertEqual(retained.read_bytes(),b'known RAM')

    def test_private_copy_handoff_preserves_source_metadata_and_bytes(self):
        self.source.chmod(0o640)
        before=self.source.stat()
        d=self.prepare(operation='handoff')
        after=self.source.stat()
        self.assertEqual((after.st_uid,after.st_gid,after.st_mode,after.st_mtime_ns,after.st_ctime_ns),
                         (before.st_uid,before.st_gid,before.st_mode,before.st_mtime_ns,before.st_ctime_ns))
        self.assertEqual(self.clone.stat().st_mode & 0o777,0o640)
        self.assertEqual(self.clone.read_bytes(),self.original)
        self.assertEqual(self.inspect()['pair'],1)
        self.assertTrue((self.workspace/'publication').exists())

    def test_handoff_metadata_faults_preserve_pair_and_taint_copy(self):
        self.source.chmod(0o640)
        for mode in ('metadata-chown-fail','metadata-chmod-fail','metadata-sync-fail'):
            with self.subTest(mode=mode):
                d=self.prepare(operation='handoff',mode=mode,valid=False)
                self.assertEqual(d['error'],'publication-metadata-write')
                self.assertTrue(d['copy_tainted'])
                self.assertEqual(self.inspect()['pair'],1)
                self.assertEqual(self.clone.read_bytes(),self.original)
                self.assertTrue((self.workspace/'publication').exists())

    def test_handoff_refuses_media_before_metadata_and_supports_retry(self):
        d=self.prepare(operation='handoff',mode='handoff-busy',valid=False)
        self.assertEqual(d['error'],'publication-metadata-media')
        self.assertFalse(d['copy_tainted'])
        self.assertEqual(self.clone.stat().st_mode & 0o777,0o600)
        self.prepare(operation='handoff-twice')
        self.assertEqual(self.inspect()['pair'],1)

    def test_abandoned_handoff_restores_private_copy_permissions(self):
        self.source.chmod(0o644)
        self.prepare(operation='handoff-restore')
        self.assertEqual(self.clone.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.source.stat().st_mode & 0o777,0o644)
        self.assertEqual(self.inspect()['pair'],1)
        self.assertEqual(self.clone.read_bytes(),self.original)

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
