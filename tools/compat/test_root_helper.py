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
#include <string.h>
#include "HengeRootHelper.h"
/* Only this control executable supplies fake persona functions. */
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *a, uid_t u, uint32_t f)
{ (void)a; return !getenv("HENGE_CONTROL_DENY_PERSONA") && u == 99 && f == 1 ? 0 : 22; }
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *a, uid_t u)
{ (void)a; return u == 0 ? 0 : 22; }
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *a, uid_t u)
{ (void)a; return u == 0 ? 0 : 22; }
int main(int argc, char **argv) {
    if (getenv("HENGE_CONTROL_INHERITED_FD")) {
        int fd = open("/dev/null", O_RDONLY); dup2(fd, 96); close(fd);
    }
    char *p = argc == 3 && !strcmp(argv[1],"--authority") ? henge_root_helper_check_write_authority(argv[2]) :
              argc == 2 && !strcmp(argv[1],"--attest") ? henge_root_helper_attest_caller() :
              argc == 2 && !strcmp(argv[1],"--recover") ? henge_root_helper_recover_workspaces() :
              argc == 2 ? henge_root_helper_inspect_disk(argv[1]) : henge_root_helper_probe();
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
                        '-fobjc-arc', str(ROOT / 'compat/guest-provisioning/HGGuestPayload.m'),
                        str(ROOT / 'compat/guest-provisioning/HGGuestDisk.c'),
                        str(ROOT / 'compat/guest-provisioning/HGGuestMedia.m'),
                        str(ROOT / 'compat/guest-provisioning/HGGuestWorkspace.c'),
                        str(ROOT / 'compat/guest-provisioning/HGGuestPeer.m'),
                        str(ROOT / 'compat/guest-provisioning/HGGuestCodeIdentity.c'),
                        str(ROOT / 'compat/guest-provisioning/HGGuestWriteAuthority.c'),
                        '-framework', 'Foundation', '-lz',
                        '-o', str(cls.real_helper)], check=True)

    def fixture(self, body):
        source = self.base / 'fixture.c'
        source.write_text('#include <stdio.h>\n#include <unistd.h>\n#include <signal.h>\n'
                          '#include <stdlib.h>\n#include <fcntl.h>\n#include <string.h>\n#include <sys/stat.h>\n'
                          'int main(int argc,char **argv) {(void)argc;(void)argv;' + body + '}\n')
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(source),
                        '-o', str(self.helper)], check=True)

    def run_probe(self, image=None, **environment):
        import os
        return subprocess.run([str(self.runner), *([str(image)] if image else [])], capture_output=True, timeout=6,
                              env={**os.environ, **environment})

    def test_helper_rejects_every_other_operation(self):
        for args in ([], ['mount'], ['probe-v1', '/some/disk'], ['recover-workspaces-v1', '/some/path'],
                     ['attest-caller-v1', '4242'], ['check-write-authority-v1', '/some/disk']):
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

    def test_unbound_helper_never_accepts_payload_resources(self):
        for operation in ('verify-payload-v1', 'inspect-image-v1', 'recover-workspaces-v1', 'attest-caller-v1', 'check-write-authority-v1'):
            result = subprocess.run([str(self.real_helper), operation], capture_output=True)
            self.assertEqual(result.returncode, 65)
            report = json.loads(result.stdout)
            self.assertFalse(report['payload_verified'])
            self.assertEqual(report['error'], 'unbound-build-identity')

    def test_protocol_and_process_failures(self):
        valid = dict(schema=1, operation='probe-v1', root=True, uid=0, euid=0,
                     gid=0, egid=0, payload_verified=True, guest_disk_accessed=False)
        cases = [(valid, True), (dict(valid, root=False), False),
                 (dict(valid, euid=501), False), (dict(valid, schema=2), False),
                 (dict(valid, operation='mount'), False), (dict(valid, payload_verified=False), False),
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

    def test_recovery_protocol_counters_and_fixed_operation(self):
        valid = dict(schema=1, operation='recover-workspaces-v1', root=True,
                     uid=0, euid=0, gid=0, egid=0, payload_verified=True,
                     workspace_parent_present=False, namespace_bounded=True,
                     enumerated=0, candidates=0, recovered=0, busy=0, retained=0,
                     changed=0, ignored=0, cleanup_complete=True,
                     original_guest_disk_accessed=False, volume_mounted=False)
        clean = dict(valid, workspace_parent_present=True, enumerated=2, candidates=2, recovered=2)
        pending = dict(clean, recovered=1, retained=1, cleanup_complete=False)
        cases = [(valid, True), (clean, True), (pending, True),
                 (dict(pending, cleanup_complete=True), False),
                 (dict(clean, workspace_parent_present=False), False),
                 (dict(clean, candidates=1), False), (dict(clean, recovered=1), False),
                 (dict(valid, busy=False), False), (dict(valid, changed='0'), False),
                 (dict(valid, enumerated=257), False), (dict(valid, ignored=0.5), False),
                 (dict(valid, namespace_bounded=False), False),
                 (dict(valid, original_guest_disk_accessed=True), False),
                 (dict(valid, volume_mounted=True), False)]
        prefix = 'if(argc!=2 || strcmp(argv[1],"recover-workspaces-v1") || fcntl(3,F_GETFD)!=-1 || fcntl(4,F_GETFD)!=-1)return 66;'
        for report, accepted in cases:
            with self.subTest(report=report):
                self.fixture(prefix + 'puts(' + json.dumps(json.dumps(report)) + '); return 0;')
                result = self.run_probe(image='--recover')
                self.assertEqual(result.returncode, 0 if accepted else 1, result.stderr)

    def test_caller_attestation_protocol_and_no_image_descriptor(self):
        valid = dict(schema=1, operation='attest-caller-v1', root=True,
                     uid=0, euid=0, gid=0, egid=0, payload_verified=True,
                     caller_verified=True, caller_no_sandbox_entitled=True,
                     caller_executable_verified=True, caller_uid=501, caller_pid=4242,
                     guest_disk_accessed=False)
        cases = [(valid, True), (dict(valid, caller_verified=False), False),
                 (dict(valid, caller_no_sandbox_entitled=False), False),
                 (dict(valid, caller_executable_verified=False), False),
                 (dict(valid, caller_uid=True), False), (dict(valid, caller_uid=-1), False),
                 (dict(valid, caller_pid=1), False), (dict(valid, caller_pid=2**31), False),
                 (dict(valid, guest_disk_accessed=True), False)]
        prefix = 'if(argc!=2 || strcmp(argv[1],"attest-caller-v1") || fcntl(3,F_GETFD)!=-1 || fcntl(4,F_GETFD)!=-1)return 66;'
        for report, accepted in cases:
            with self.subTest(report=report):
                self.fixture(prefix + 'puts(' + json.dumps(json.dumps(report)) + '); return 0;')
                result = self.run_probe(image='--attest')
                self.assertEqual(result.returncode, 0 if accepted else 1, result.stderr)

    def test_write_capabilities_are_opened_by_app_and_passed_without_paths(self):
        image=self.base/'authority.img';original=b'HGFD explicit authored capability';image.write_bytes(original)
        valid=dict(schema=1,operation='check-write-authority-v1',root=True,uid=0,euid=0,gid=0,egid=0,
                   payload_verified=True,caller_verified=True,caller_no_sandbox_entitled=True,
                   caller_executable_verified=True,caller_uid=501,caller_pid=4242,write_authority_verified=True,
                   image_inspected=True,exclusive_lease_verified=True,media_inventory_verified=True,
                   image_modified=False,image_attached=False,volume_mounted=False)
        checks='''if(argc!=2 || strcmp(argv[1],"check-write-authority-v1") ||
            (fcntl(3,F_GETFL)&O_ACCMODE)!=O_RDONLY || (fcntl(4,F_GETFL)&O_ACCMODE)!=O_RDWR ||
            fcntl(96,F_GETFD)!=-1)return 91;
            struct stat a,b;if(fstat(3,&a)||fstat(4,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)return 92;
            char data[4];if(pread(3,data,4,0)!=4||memcmp(data,"HGFD",4)||pread(4,data,4,0)!=4||memcmp(data,"HGFD",4))return 93;
        '''
        cases=[(valid,True)]
        for key in ('caller_verified','caller_no_sandbox_entitled','caller_executable_verified',
                    'write_authority_verified','image_inspected','exclusive_lease_verified','media_inventory_verified'):
            cases.append((dict(valid,**{key:False}),False))
        for key in ('image_modified','image_attached','volume_mounted'):
            cases.append((dict(valid,**{key:True}),False))
        for report,accepted in cases:
            self.fixture(checks+'puts('+json.dumps(json.dumps(report))+');return 0;')
            result=subprocess.run([str(self.runner),'--authority',str(image)],capture_output=True,timeout=6)
            self.assertEqual(result.returncode,0 if accepted else 1,result.stderr)
        self.assertEqual(image.read_bytes(),original)

    def test_authority_transport_rejects_nonregular_and_symlink_inputs(self):
        image=self.base/'authority-target.img';image.write_bytes(b'authored')
        link=self.base/'authority-symlink';link.symlink_to(image)
        fifo=self.base/'authority-fifo'
        import os
        os.mkfifo(fifo)
        self.fixture('return 99;')
        for path in (link,fifo,self.base,self.base/'missing'):
            result=subprocess.run([str(self.runner),'--authority',str(path)],capture_output=True,timeout=2)
            self.assertEqual(result.returncode,1)
        self.assertEqual(image.read_bytes(),b'authored')

    def test_parent_environment_and_descriptors_are_not_inherited(self):
        valid = json.dumps(dict(schema=1, operation='probe-v1', root=True, uid=0,
                                euid=0, gid=0, egid=0, payload_verified=True, guest_disk_accessed=False))
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

    def test_image_is_passed_only_as_readonly_descriptor_three(self):
        image = self.base / 'disk.img'
        original = b'HGFD authored disk control'
        image.write_bytes(original)
        report = dict(schema=1, operation='inspect-image-v1', root=True, uid=0,
                      euid=0, gid=0, egid=0, payload_verified=True, image_inspected=True,
                      exclusive_lease_verified=True, media_inventory_verified=True, image_modified=False,
                      image_attached=False, volume_mounted=False)
        checks = '''if(argc!=2 || strcmp(argv[1],"inspect-image-v1") ||
            (fcntl(3,F_GETFL)&O_ACCMODE)!=O_RDONLY) return 91;
            char b[4]; if(pread(3,b,4,0)!=4 || memcmp(b,"HGFD",4))return 92;
            if(write(3,"bad",3)>=0)return 93;
        '''
        self.fixture(checks + 'puts(' + json.dumps(json.dumps(report)) + '); return 0;')
        self.assertEqual(self.run_probe(image=image).returncode, 0)
        self.assertEqual(image.read_bytes(), original)
        for field, invalid in (('image_modified', True), ('image_attached', True),
                               ('media_inventory_verified', False)):
            altered = {**report, field: invalid}
            self.fixture('puts(' + json.dumps(json.dumps(altered)) + '); return 0;')
            self.assertEqual(self.run_probe(image=image).returncode, 1)

    def test_image_path_symlink_and_fifo_are_rejected_before_spawn(self):
        image = self.base / 'resource'
        image.write_bytes(b'authored file')
        alias = self.base / 'alias'
        alias.symlink_to(image)
        self.fixture('for (;;) pause();')
        self.assertEqual(self.run_probe(image=alias).returncode, 1)
        alias.unlink()
        import os
        os.mkfifo(alias)
        self.assertEqual(self.run_probe(image=alias).returncode, 1)


if __name__ == '__main__':
    unittest.main()
