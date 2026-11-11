"""Native parser controls use authored fixtures, not guest code qualification."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

from build_guest_payload import EXECUTABLES, FILES, VLC_PLUGINS, identity, vlc_target

ROOT = Path(__file__).resolve().parents[2]


def sha(data):
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(sys.platform == 'darwin', 'Native Foundation/zlib controls')
class NativeGuestPayloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler_temp = tempfile.TemporaryDirectory(prefix='henge-native-payload-control-')
        cls.addClassCleanup(cls.compiler_temp.cleanup)
        folder = Path(cls.compiler_temp.name)
        source = folder / 'control.c'
        source.write_text('''
#include "HGGuestPayload.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 7) return 64;
    HGGuestPayloadIdentity id = {argv[2],argv[3],argv[4],argv[5],argv[6]};
    char *report = NULL;
    int status = hg_guest_payload_verify_directory(argv[1], &id, &report);
    if (report) puts(report);
    free(report); return status;
}
''')
        cls.control = folder / 'control'
        native = ROOT / 'compat/guest-provisioning'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
                        '-I', str(native), str(source), str(native / 'HGGuestPayload.m'),
                        '-framework', 'Foundation', '-lz', '-o', str(cls.control)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='henge-native-payload-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.data = {name: ('authored fixture ' + name).encode() for name in FILES}
        self.recipe = 'a' * 64
        self.manifest = dict(schema=1, kind='henge-sonoma-guest-compatibility',
                             architecture='arm64', minimum_macos='14.0',
                             compiler_recipe=self.recipe, activation='unimplemented',
                             vlc=vlc_target(), sources={'authored-control.m': 'b' * 64},
                             files={name: dict(sha256=sha(data), bytes=len(data),
                                              mode=0o755 if name in EXECUTABLES else 0o644)
                                    for name, data in self.data.items()})
        self.manifest['payload_id'] = identity(self.manifest)
        self.emit()

    def emit(self, transform=None, raw_transform=None):
        manifest = json.dumps(self.manifest).encode()
        members = {**self.data, 'manifest.json': manifest}
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for name, data in sorted(members.items()):
                member = tarfile.TarInfo(name)
                member.mode = 0o755 if name in EXECUTABLES else 0o644
                member.size = len(data)
                if transform:
                    transform(member)
                archive.addfile(member, io.BytesIO(data))
        raw = stream.getvalue()
        if raw_transform:
            raw = raw_transform(raw)
        compressed = gzip.compress(raw, mtime=0)
        self.publish(compressed, manifest)

    def publish(self, compressed, manifest=None):
        if manifest is None:
            manifest = json.dumps(self.manifest).encode()
        self.descriptor = dict(schema=1, payload_id=self.manifest['payload_id'],
                               compiler_recipe=self.recipe, archive_sha256=sha(compressed),
                               archive_bytes=len(compressed), manifest_sha256=sha(manifest),
                               activation='unimplemented')
        (self.folder / 'henge-guest-payload.tar.gz').write_bytes(compressed)
        descriptor = json.dumps(self.descriptor).encode()
        (self.folder / 'henge-guest-payload.json').write_bytes(descriptor)
        self.descriptor_sha = sha(descriptor)

    def run_control(self, expected=65, descriptor_sha=None):
        vlc = vlc_target()
        result = subprocess.run([str(self.control), str(self.folder),
                                 descriptor_sha or self.descriptor_sha, self.recipe,
                                 self.manifest['payload_id'], vlc['reference_core_sha256'],
                                 vlc['reference_lock_sha256']], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, expected, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['payload_verified'], expected == 0)
        self.assertFalse(report['guest_disk_accessed'])
        return report

    def test_valid_complete_unit(self):
        self.assertEqual(self.run_control(0)['members'], len(FILES) + 1)

    def test_unbound_or_changed_descriptor(self):
        self.run_control(descriptor_sha='unbound')
        path = self.folder / 'henge-guest-payload.json'
        path.write_bytes(path.read_bytes() + b' ')
        self.run_control()

    def test_archive_corruption_and_resource_symlink(self):
        path = self.folder / 'henge-guest-payload.tar.gz'
        path.write_bytes(path.read_bytes() + b'corrupt')
        self.run_control()
        self.emit()
        backup = self.folder / 'other.gz'
        path.rename(backup)
        path.symlink_to(backup)
        self.run_control()

    def test_malformed_and_concatenated_gzip(self):
        original = (self.folder / 'henge-guest-payload.tar.gz').read_bytes()
        for data in (b'not gzip', original[:-8], original + b'trailing',
                     original + gzip.compress(b'extra', mtime=0)):
            with self.subTest(length=len(data)):
                self.publish(data)
                self.run_control()

    def test_fifo_resource_is_rejected_without_waiting_for_a_writer(self):
        path = self.folder / 'henge-guest-payload.tar.gz'
        path.unlink()
        os.mkfifo(path)
        self.run_control()

    def test_expansion_bound(self):
        self.publish(gzip.compress(b'\0' * (33 * 1024 * 1024), mtime=0))
        self.run_control()

    def test_tar_paths_links_modes_owners_and_timestamps(self):
        for attribute, value in [('name', '../outside'), ('name', '/outside'),
                                 ('type', tarfile.SYMTYPE), ('type', tarfile.LNKTYPE),
                                 ('mode', 0o4777), ('uid', 501), ('gid', 501), ('mtime', 1),
                                 ('uname', 'unexpected')]:
            with self.subTest(attribute=attribute, value=value):
                self.emit(lambda item: setattr(item, attribute, value))
                self.run_control()

    def test_tar_checksum_and_trailer(self):
        self.emit(raw_transform=lambda raw: b'X' + raw[1:])
        self.run_control()
        self.emit(raw_transform=lambda raw: raw + b'\0' * 511 + b'X')
        self.run_control()

    def test_duplicate_member_is_rejected(self):
        # The first authored fixture fits in one header and one data block.
        self.emit(raw_transform=lambda raw: raw[:1024] + raw)
        self.run_control()

    def test_missing_or_unexpected_member(self):
        self.data.pop(VLC_PLUGINS[0])
        self.emit()
        self.run_control()
        self.data['unexpected'] = b'unknown'
        self.emit()
        self.run_control()

    def test_member_hash_and_manifest_target(self):
        name = VLC_PLUGINS[0]
        before = self.data[name]
        self.data[name] += b'changed'
        self.emit()
        self.run_control()
        self.data[name] = before
        self.manifest['architecture'] = 'x86_64'
        self.emit()
        self.run_control()

    def test_partial_vlc_unit_and_unknown_manifest_fields(self):
        plugins = self.manifest['vlc']['plugins'].copy()
        self.manifest['vlc']['plugins'].pop()
        self.emit()
        self.run_control()
        self.manifest['vlc']['plugins'] = plugins
        self.manifest['destination'] = '/System/Library'
        self.emit()
        self.run_control()


if __name__ == '__main__':
    unittest.main()
