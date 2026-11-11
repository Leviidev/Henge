import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from check_ondevice_provider import verify, RECEIPT


class ProviderPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'compat/ondevice-shaders'
        self.lib = self.root / 'ios/deps/lib'
        for directory in (self.source, self.lib, self.root / 'devices',
                          self.root / 'ios/Henge/Resources/legal'):
            directory.mkdir(parents=True)
        for name in ('HGOnDeviceShaderProvider.h', 'pvg_shader_profile.h'):
            (self.source / name).write_text(name)
            (self.root / 'devices' / name).write_text(name)
        (self.source / 'rebuild_llvm.py').write_text('authored build fixture')
        (self.source / 'LICENSE-LLVM.txt').write_text('authored license fixture')
        (self.root / 'ios/Henge/Resources/legal/LICENSE-LLVM.txt').write_text(
            'authored license fixture')
        (self.lib / 'libHGOnDeviceShader.a').write_bytes(b'authored archive fixture')
        manifest = {'authored': 'test recipe'}
        encoded = json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()
        self.receipt = {
            'source_package': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in self.source.iterdir()},
            'archive_sha256': hashlib.sha256(b'authored archive fixture').hexdigest(),
            'compiler_recipe': {'recipe': hashlib.sha256(encoded).hexdigest(),
                                'manifest': manifest},
        }
        self.write_receipt()

    def write_receipt(self):
        (self.lib / RECEIPT).write_text(json.dumps(self.receipt))

    def test_matching_inputs(self):
        self.assertEqual(verify(self.root), self.receipt['compiler_recipe']['recipe'])

    def test_stale_source(self):
        (self.source / 'rebuild_llvm.py').write_text('changed compiler options')
        with self.assertRaisesRegex(ValueError, 'source changed'):
            verify(self.root)

    def test_archive_from_other_build(self):
        (self.lib / 'libHGOnDeviceShader.a').write_bytes(b'other archive')
        with self.assertRaisesRegex(ValueError, 'archive differs'):
            verify(self.root)

    def test_missing_receipt(self):
        (self.lib / RECEIPT).unlink()
        with self.assertRaises(FileNotFoundError):
            verify(self.root)

    def test_recipe_tamper(self):
        self.receipt['compiler_recipe']['manifest']['authored'] = 'changed'
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'recipe identity'):
            verify(self.root)

    def test_contract_mismatch(self):
        (self.root / 'devices/pvg_shader_profile.h').write_text('other ABI')
        with self.assertRaisesRegex(ValueError, 'API contract'):
            verify(self.root)

    def test_missing_bundled_license(self):
        (self.root / 'ios/Henge/Resources/legal/LICENSE-LLVM.txt').unlink()
        with self.assertRaises(FileNotFoundError):
            verify(self.root)
