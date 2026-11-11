"""Native process controls. Persona stubs do NOT qualify iPad root privileges."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin spawn/Foundation controls')
class RootHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='henge-root-controls-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.bundle = cls.base / 'Control.app'
        macos = cls.bundle / 'Contents/MacOS'
        macos.mkdir(parents=True)
        (cls.bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'Control', 'CFBundleIdentifier': 'org.henge.root-controls',
            'CFBundlePackageType': 'APPL'}))
        stub = cls.base / 'control.m'
        stub.write_text('''
#import <Foundation/Foundation.h>
#include <spawn.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include "HengeRootHelper.h"
/* Only this control executable supplies fake persona functions. */
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *a, uid_t u, uint32_t f)
{ (void)a; return !getenv("HENGE_CONTROL_DENY_PERSONA") && u == 99 && f == 1 ? 0 : 22; }
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *a, uid_t u)
{ (void)a; return u == 0 ? 0 : 22; }
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *a, uid_t u)
{ (void)a; return u == 0 ? 0 : 22; }
int main(void) {
    if (getenv("HENGE_CONTROL_INHERITED_FD")) {
        int fd = open("/dev/null", O_RDONLY); dup2(fd, 96); close(fd);
    }
    char *p = henge_root_helper_probe();
    if (!p) return 1; puts(p); free(p); return 0; }
''')
        cls.runner = macos / 'Control'
        native = ROOT / 'ios/Henge/Native'
        subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-Wl,-export_dynamic', '-I', str(native), str(stub),
                        str(native / 'HengeRootHelper.m'), '-framework', 'Foundation',
                        '-o', str(cls.runner)], check=True)
        cls.helper = cls.bundle / 'henge-root-helper'
        cls.real_helper = cls.base / 'real-helper'
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'compat/guest-provisioning/root_helper.c'),
                        '-o', str(cls.real_helper)], check=True)

    def fixture(self, body):
        source = self.base / 'fixture.c'
        source.write_text('#include <stdio.h>\n#include <unistd.h>\n#include <signal.h>\n'
                          '#include <stdlib.h>\nint main(void) {' + body + '}\n')
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(source),
                        '-o', str(self.helper)], check=True)

    def run_probe(self, **environment):
        import os
        return subprocess.run([str(self.runner)], capture_output=True, timeout=6,
                              env={**os.environ, **environment})

    def test_helper_rejects_every_other_operation(self):
        for args in ([], ['mount'], ['probe-v1', '/some/disk']):
            result = subprocess.run([str(self.real_helper), *args], capture_output=True)
            self.assertEqual(result.returncode, 64)
            self.assertFalse(result.stdout)

    def test_actual_probe_identity(self):
        result = subprocess.run([str(self.real_helper), 'probe-v1'], capture_output=True)
        report = json.loads(result.stdout)
        import os
        root = all(x == 0 for x in (os.getuid(), os.geteuid(), os.getgid(), os.getegid()))
        self.assertEqual(result.returncode, 0 if root else 77)
        self.assertEqual(report['root'], root)
        self.assertFalse(report['guest_disk_accessed'])

    def test_protocol_and_process_failures(self):
        valid = dict(schema=1, operation='probe-v1', root=True, uid=0, euid=0,
                     gid=0, egid=0, guest_disk_accessed=False)
        cases = [(valid, True), (dict(valid, root=False), False),
                 (dict(valid, euid=501), False), (dict(valid, schema=2), False),
                 (dict(valid, operation='mount'), False),
                 (dict(valid, guest_disk_accessed=True), False), ([], False), ({}, False)]
        for report, accepted in cases:
            with self.subTest(report=report):
                self.fixture('puts(' + json.dumps(json.dumps(report)) + '); return 0;')
                result = self.run_probe()
                self.assertEqual(result.returncode, 0 if accepted else 1, result.stderr)
        for body in ('puts("invalid JSON"); return 0;', 'return 77;',
                     'raise(SIGTERM); return 0;',
                     'for(int i=0;i<8192;i++) putchar(65); return 0;'):
            with self.subTest(body=body):
                self.fixture(body)
                self.assertEqual(self.run_probe().returncode, 1)

    def test_persona_denial_fails_without_starting_helper(self):
        self.fixture('for (;;) pause();')
        start = time.monotonic()
        self.assertEqual(self.run_probe(HENGE_CONTROL_DENY_PERSONA='1').returncode, 1)
        self.assertLess(time.monotonic() - start, 1)

    def test_parent_environment_and_descriptors_are_not_inherited(self):
        valid = json.dumps(dict(schema=1, operation='probe-v1', root=True, uid=0,
                                euid=0, gid=0, egid=0, guest_disk_accessed=False))
        source = self.base / 'fixture.c'
        source.write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <fcntl.h>\n'
                          'int main(void) { if (getenv("HENGE_CONTROL_INHERITED_FD") || '
                          'fcntl(96,F_GETFD) != -1) return 98; puts(' + json.dumps(valid) + '); return 0;}')
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(source),
                        '-o', str(self.helper)], check=True)
        self.assertEqual(self.run_probe(HENGE_CONTROL_INHERITED_FD='1').returncode, 0)

    def test_stalled_helper_is_reaped_at_deadline(self):
        self.fixture('for (;;) pause();')
        start = time.monotonic()
        self.assertEqual(self.run_probe().returncode, 1)
        self.assertGreaterEqual(time.monotonic() - start, 2.8)
        self.assertLess(time.monotonic() - start, 5)

    def test_missing_or_nonexecutable_helper(self):
        self.helper.unlink(missing_ok=True)
        self.assertEqual(self.run_probe().returncode, 1)
        self.helper.write_text('not executable')
        self.helper.chmod(0o644)
        self.assertEqual(self.run_probe().returncode, 1)


if __name__ == '__main__':
    unittest.main()
