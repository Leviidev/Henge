"""Real descriptor-based APFS COW/lease controls; IOMedia boundary stubbed."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import test_guest_disk as gpt

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin APFS clonefile controls')
class GuestCloneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = tempfile.TemporaryDirectory(prefix='henge-clone-control-')
        cls.addClassCleanup(cls.compiler.cleanup)
        directory = Path(cls.compiler.name)
        source = directory / 'control.c'
        source.write_text(r'''
#include "HGGuestClone.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int busy,collision,inventory_error;
static void clone_random(void *p,size_t n) {
 if(collision)memset(p,0,n);else arc4random_buf(p,n);
}
int hg_guest_media_copy(const HGGuestDisk *disk,char **json,const char **error) {
 if(inventory_error){*json=NULL;*error="test-inventory-unavailable";return -1;}
 (void)disk;*json=strdup(busy?"[{\"owned\":true}]":"[]");*error=NULL;return 0;
}
#define arc4random_buf clone_random
#include "HGGuestClone.c"
int main(int n,char **v) {
 if(n!=4)return 64;
 busy=!strcmp(v[3],"busy");collision=!strcmp(v[3],"collision");
 inventory_error=!strcmp(v[3],"inventory-error");
 int src=open(v[1],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
 int parent=open(v[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 HGGuestDisk original={.fd=-1};HGGuestClone clone=HG_GUEST_CLONE_INIT;
 const char *error=NULL;int result=hg_guest_disk_inspect_fd(src,&original,&error);
 if(!result)result=hg_guest_clone_create(&original,parent,&clone,&error);
 if(!result && !strcmp(v[3],"double")) {
  const char *second=NULL;
  if(!hg_guest_clone_create(&original,parent,&clone,&second) || strcmp(second,"clone-already-open"))abort();
 }
 printf("{\"created\":%s,\"name\":\"%s\",\"error\":\"%s\",\"source_inode\":%llu,\"clone_inode\":%llu,\"mode\":%u,\"readonly\":%s,\"cloexec\":%s}\n",
 result?"false":"true",clone.name,error?error:"",(unsigned long long)original.identity.st_ino,
 (unsigned long long)clone.disk.identity.st_ino,(unsigned)(clone.disk.identity.st_mode&0777),
 !result && (fcntl(clone.disk.fd,F_GETFL)&O_ACCMODE)==O_RDONLY?"true":"false",
 !result && (fcntl(clone.disk.fd,F_GETFD)&FD_CLOEXEC)?"true":"false");fflush(stdout);
 if(!result) {
  getchar();
  int closed=hg_guest_clone_discard(&clone,&error);
  printf("{\"discarded\":%s,\"error\":\"%s\",\"source_unchanged\":%s}\n",
   closed?"false":"true",error?error:"",hg_guest_disk_unchanged(&original)?"true":"false");fflush(stdout);
  if(closed) {
   getchar();busy=0;inventory_error=0;closed=hg_guest_clone_discard(&clone,&error);
   printf("{\"discarded\":%s,\"error\":\"%s\"}\n",closed?"false":"true",error?error:"");fflush(stdout);
  }
 }
 if(parent>=0 && fcntl(parent,F_GETFD)<0)abort();
 hg_guest_disk_close(&original);if(src>=0)close(src);if(parent>=0)close(parent);
 return result?1:0;
}
''')
        cls.control = directory / 'control'
        native = ROOT / 'compat/guest-provisioning'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-I', str(native), str(source), str(native / 'HGGuestDisk.c'),
                        '-lz', '-o', str(cls.control)], check=True)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='henge-clone-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.image = self.base / 'source.img'
        self.parent = self.base / 'private'
        self.parent.mkdir(mode=0o700)
        image = gpt.GuestDiskTests(methodName='runTest')
        image.path, image.sectors = self.image, 4096
        image.entries = bytearray(128 * 128)
        image.entry(0, gpt.APFS, 40, image.sectors - 40)
        image.emit()

    def start(self, mode='hold', created=True):
        process = subprocess.Popen([str(self.control), str(self.image), str(self.parent), mode],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        report = json.loads(process.stdout.readline())
        self.assertEqual(report['created'], created, report)
        if not created:
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1)
        return process, report

    def release(self, process):
        output, errors = process.communicate(b'\n', timeout=5)
        self.assertEqual(process.returncode, 0, errors)
        return json.loads(output)

    def test_real_clone_is_private_identical_independent_and_leased(self):
        original = self.image.read_bytes()
        process, report = self.start()
        clone = self.parent / report['name']
        self.assertNotEqual(report['source_inode'], report['clone_inode'])
        self.assertEqual(report['mode'], 0o600)
        self.assertTrue(report['readonly'])
        self.assertTrue(report['cloexec'])
        self.assertEqual(clone.read_bytes(), original)
        for path in (self.image, clone):
            with path.open('rb') as f:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
        result = self.release(process)
        self.assertTrue(result['discarded'])
        self.assertTrue(result['source_unchanged'])
        self.assertEqual(list(self.parent.iterdir()), [])
        self.assertEqual(self.image.read_bytes(), original)

    def test_changed_source_does_not_change_copy_or_prevent_owned_discard(self):
        original = self.image.read_bytes()
        process, report = self.start()
        with self.image.open('r+b') as f:
            f.seek(100000)
            f.write(b'controlled uncooperative source change')
        self.assertEqual((self.parent / report['name']).read_bytes(), original)
        result = self.release(process)
        self.assertTrue(result['discarded'])
        self.assertFalse(result['source_unchanged'])

    def test_busy_media_retains_clone_for_retry(self):
        process, report = self.start('busy')
        process.stdin.write(b'\n')
        process.stdin.flush()
        refusal = json.loads(process.stdout.readline())
        self.assertFalse(refusal['discarded'])
        self.assertEqual(refusal['error'], 'clone-media-cleanup-required')
        self.assertTrue((self.parent / report['name']).exists())
        self.assertTrue(self.release(process)['discarded'])

    def test_failed_media_inventory_retains_owned_state_for_retry(self):
        process, report = self.start('inventory-error')
        process.stdin.write(b'\n')
        process.stdin.flush()
        refusal = json.loads(process.stdout.readline())
        self.assertFalse(refusal['discarded'])
        self.assertEqual(refusal['error'], 'clone-media-cleanup-required')
        self.assertTrue((self.parent / report['name']).exists())
        self.assertTrue(self.release(process)['discarded'])

    def test_changed_private_copy_can_be_discarded_without_changing_source(self):
        original = self.image.read_bytes()
        process, report = self.start()
        with (self.parent / report['name']).open('r+b') as f:
            f.seek(100000)
            f.write(b'controlled private-copy change')
        self.assertEqual(self.image.read_bytes(), original)
        self.assertTrue(self.release(process)['discarded'])
        self.assertEqual(self.image.read_bytes(), original)

    def test_replaced_name_is_preserved_and_discard_can_retry_after_restoration(self):
        process, report = self.start()
        path = self.parent / report['name']
        saved = self.parent / 'saved'
        path.rename(saved)
        path.write_text('preserve replacement')
        process.stdin.write(b'\n')
        process.stdin.flush()
        self.assertFalse(json.loads(process.stdout.readline())['discarded'])
        self.assertEqual(path.read_text(), 'preserve replacement')
        path.unlink()
        saved.rename(path)
        self.assertTrue(self.release(process)['discarded'])

    def test_untrusted_parent_and_existing_nonce_are_not_modified(self):
        self.parent.chmod(0o755)
        self.start(created=False)
        self.assertEqual(list(self.parent.iterdir()), [])
        self.parent.chmod(0o700)
        keep = self.parent / 'henge-clone-0000000000000000.img'
        keep.write_text('preserve collision')
        self.start('collision', created=False)
        self.assertEqual(keep.read_text(), 'preserve collision')
        self.assertEqual(list(self.parent.iterdir()), [keep])

    def test_existing_clone_handle_cannot_be_overwritten(self):
        process, _ = self.start('double')
        self.assertTrue(self.release(process)['discarded'])


if __name__ == '__main__':
    unittest.main()
