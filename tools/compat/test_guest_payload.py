import json
import hashlib
from pathlib import Path
import tempfile
import tarfile
import unittest

from build_guest_payload import FILES, LIBRARIES, SOURCES, archive_payload, digest, identity, verify_payload


class GuestPayloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        for name in FILES:
            path = self.folder / name
            path.write_bytes(('authored fixture ' + name).encode())
            path.chmod(0o755 if name in LIBRARIES else 0o644)
        self.recipe = 'a' * 64
        self.manifest = dict(schema=1, kind='henge-sonoma-guest-compatibility',
                             architecture='arm64', minimum_macos='14.0',
                             compiler_recipe=self.recipe, activation='unimplemented',
                             sources={name: 'b' * 64 for name in SOURCES},
                             files={name: dict(sha256=digest(self.folder / name),
                                              bytes=(self.folder / name).stat().st_size,
                                              mode=(self.folder / name).stat().st_mode & 0o777)
                                    for name in FILES})
        self.write()

    def write(self):
        self.manifest['payload_id'] = identity(self.manifest)
        path = self.folder / 'manifest.json'
        path.write_text(json.dumps(self.manifest))
        path.chmod(0o644)

    def test_exact_inventory_and_recipe(self):
        self.assertEqual(verify_payload(self.folder, self.recipe), self.manifest)
        with self.assertRaises(ValueError):
            verify_payload(self.folder, 'c' * 64)

    def test_tampered_bytes_size_and_mode(self):
        path = self.folder / LIBRARIES[0]
        original = path.read_bytes()
        path.write_bytes(original[:-1] + b'!')
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)
        path.write_bytes(original + b'x')
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)
        path.write_bytes(original)
        path.chmod(0o777)
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)

    def test_symlinks_directories_and_extra_members(self):
        path = self.folder / LIBRARIES[0]
        path.unlink()
        path.symlink_to(self.folder / FILES[-1])
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)
        path.unlink()
        path.mkdir()
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)
        path.rmdir()
        path.write_bytes(b'authored')
        (self.folder / 'extra').write_text('unexpected')
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)

    def test_identity_and_protocol_changes(self):
        path = self.folder / 'manifest.json'
        path.write_text(path.read_text().replace('unimplemented', 'installed'))
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)
        self.manifest['architecture'] = 'x86_64'
        self.write()
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)

    def test_source_inventory_is_closed(self):
        self.manifest['sources']['unknown'] = 'b' * 64
        self.write()
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)

    def test_manifest_cannot_add_install_paths(self):
        self.manifest['destination'] = '/System/Library'
        self.write()
        with self.assertRaises(ValueError):
            verify_payload(self.folder, self.recipe)

    def test_archive_is_flat_and_reproducible(self):
        first, second = self.folder / 'first.gz', self.folder / 'second.gz'
        archive_payload(self.folder, first)
        archive_payload(self.folder, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with tarfile.open(first) as archive:
            self.assertEqual(set(archive.getnames()), set(FILES) | {'manifest.json'})
            for member in archive.getmembers():
                self.assertTrue(member.isfile())
                self.assertEqual(member.uid, 0)
                self.assertEqual(member.gid, 0)
                self.assertEqual(member.mtime, 0)
                self.assertEqual(member.mode, 0o755 if member.name in LIBRARIES else 0o644)
                self.assertEqual(hashlib.sha256(archive.extractfile(member).read()).hexdigest(),
                                 digest(self.folder / member.name))


if __name__ == '__main__':
    unittest.main()
