"""Real private COW role writes and fault injection; no image mounts."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import test_guest_apfs as apfs

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin APFS clone controls')
class GuestRoleWriteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = tempfile.TemporaryDirectory(prefix='henge-role-write-build-')
        cls.addClassCleanup(cls.compiler.cleanup)
        directory = Path(cls.compiler.name)
        native = ROOT / 'compat/guest-provisioning'
        shim = directory / 'shim.c'
        shim.write_text(r'''
#include "HGGuestMedia.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int image_writes;
static int mode(const char *s) { const char *m=getenv("HENGE_ROLE_TEST_MODE");return m && !strcmp(m,s); }
static int image(int fd) {
 char p[4096];if(fcntl(fd,F_GETPATH,p))return 0;size_t n=strlen(p);
 return n>4 && !strcmp(p+n-4,".img");
}
static ssize_t test_write(int fd,const void *p,size_t n,off_t off) {
 if(image(fd)) {
  image_writes++;
  if(mode("write-fail") && image_writes==2){errno=EIO;return -1;}
  if(mode("torn-write")) {
   if(image_writes==1)return pwrite(fd,p,n/2,off);
   errno=EIO;return -1;
  }
 }
 return pwrite(fd,p,n,off);
}
static int test_sync(int fd) {
 char p[4096];if(fcntl(fd,F_GETPATH,p))return -1;
 if((mode("journal-sync") && strstr(p,".roles-")) ||
    (mode("image-sync") && image(fd) && image_writes)) {errno=EIO;return -1;}
 if(mode("readback") && image(fd) && image_writes) {
  unsigned char x=7;if(pwrite(fd,&x,1,40*512+5*4096+80)!=1)abort();
 }
 if(mode("journal-readback") && strstr(p,".roles-")) {
  unsigned char x=7;if(pwrite(fd,&x,1,0)!=1)abort();
 }
 return fsync(fd);
}
int hg_guest_media_copy(const HGGuestDisk *disk,char **json,const char **error) {
 static int queries;queries++;
 (void)disk;*json=strdup(mode("busy") || (mode("busy-late") && queries==3)?"[{}]":"[]");*error=NULL;return 0;
}
#define pwrite test_write
#define fsync test_sync
#include "HGGuestRoleWrite.c"
''')
        # Inventory stub above must not impede discard after the writer refuses.
        control = (ROOT / 'tools/compat/guest_role_write_control.c').read_text()
        control = control.replace('int discarded=clone.source?',
                                  'unsetenv("HENGE_ROLE_TEST_MODE");\n    int discarded=clone.source?')
        control = '#include <stdlib.h>\n' + control
        main = directory / 'control.c'
        main.write_text(control)
        cls.control = directory / 'control'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-I', str(native), str(main), str(shim),
                        *[str(native / f) for f in ['HGGuestDisk.c', 'HGGuestAPFS.c',
                                                   'HGGuestClone.c', 'HGGuestRoles.c']],
                        '-lz', '-o', str(cls.control)], check=True)

    def run_control(self, mode='', expected=True):
        fixture = apfs.GuestAPFSTests(methodName='runTest')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.emit()
        parent = fixture.path.parent / 'private'
        parent.mkdir(mode=0o700)
        original = fixture.path.read_bytes()
        result = subprocess.run([str(self.control), str(fixture.path), str(parent)],
                                env={**os.environ, 'HENGE_ROLE_TEST_MODE': mode},
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['passed'], expected)
        self.assertTrue(report['source_unchanged'])
        self.assertTrue(report['discarded'])
        self.assertFalse(report['image_mounted'])
        self.assertEqual(original, fixture.path.read_bytes())
        journals = list(parent.iterdir())
        self.assertTrue(all('.roles-' in p.name for p in journals))
        for path in journals:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        return report, journals, original

    def test_roundtrip_and_durable_journal_contents(self):
        r, journals, original = self.run_control()
        self.assertEqual((r['neutral_edits'], r['restore_edits']), (2, 2))
        self.assertFalse(r['tainted'])
        self.assertEqual(len(journals), 2)
        for path in journals:
            data = path.read_bytes()
            self.assertEqual(data[:8], b'HGRJ0001')
            base, size, count, restore = struct.unpack_from('<QIII', data, 32)
            self.assertEqual((base, size, count), (40 * 512, 4096, 2))
            self.assertEqual(len(data), 64 + count * (8 + size * 2))
            pos = 64
            for _ in range(count):
                offset, = struct.unpack_from('<Q', data, pos)
                old = data[pos + 8:pos + 8 + size]
                new = data[pos + 8 + size:pos + 8 + size * 2]
                self.assertEqual(old[:8], apfs.checksum(old))
                self.assertEqual(new[:8], apfs.checksum(new))
                self.assertEqual(old[8:964], new[8:964])
                self.assertEqual(old[966:], new[966:])
                self.assertEqual(new if restore else old, original[offset:offset + size])
                pos += 8 + size * 2

    def test_preflight_busy_never_journals_or_writes(self):
        r, journals, _ = self.run_control('busy', False)
        self.assertFalse(r['tainted'])
        self.assertEqual(journals, [])
        self.assertEqual(r['neutral_edits'], 0)

    def test_journal_sync_failure_never_writes_image(self):
        r, _, _ = self.run_control('journal-sync', False)
        self.assertTrue(r['tainted'])
        self.assertFalse(r['journal_durable'])
        self.assertEqual(r['neutral_edits'], 0)

    def test_journal_corruption_never_writes_image(self):
        r, _, _ = self.run_control('journal-readback', False)
        self.assertTrue(r['tainted'])
        self.assertFalse(r['journal_durable'])
        self.assertEqual(r['neutral_edits'], 0)

    def test_media_appearing_after_journal_prevents_writes(self):
        r, _, _ = self.run_control('busy-late', False)
        self.assertTrue(r['tainted'])
        self.assertTrue(r['journal_durable'])
        self.assertEqual(r['neutral_edits'], 0)

    def test_partial_write_is_discard_only(self):
        for mode in ['write-fail', 'torn-write', 'image-sync', 'readback']:
            with self.subTest(mode=mode):
                r, journals, _ = self.run_control(mode, False)
                self.assertTrue(r['tainted'])
                self.assertTrue(r['journal_durable'])
                self.assertEqual(len(journals), 1)


if __name__ == '__main__':
    unittest.main()
