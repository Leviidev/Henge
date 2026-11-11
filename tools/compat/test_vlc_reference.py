import hashlib
import importlib.util
import io
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'compat/vlc/reference.py'
SPEC = importlib.util.spec_from_file_location('henge_vlc_reference', SOURCE)
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class VLCReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cache = self.root / 'cache'
        self.data = b'authored reference image fixture'
        self.lock = dict(schema=1, filename='reference.dmg', url='https://example.invalid/reference.dmg',
                         bytes=len(self.data), sha256=hashlib.sha256(self.data).hexdigest())
        (self.root / 'reference.lock.json').write_text(json.dumps(self.lock))
        self.here = patch.object(reference, 'HERE', self.root)
        self.here.start()
        self.addCleanup(self.here.stop)

    def test_missing_reference_does_not_fetch_without_flag(self):
        with patch.object(reference.urllib.request, 'urlopen') as fetch:
            with self.assertRaisesRegex(ValueError, 'missing'):
                reference.obtain(self.cache, False)
            fetch.assert_not_called()

    def test_corrupt_cached_image_never_mounts(self):
        self.cache.mkdir()
        (self.cache / self.lock['filename']).write_bytes(b'corrupt')
        with patch.object(reference.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'checksum/length'):
                reference.obtain(self.cache, False)
            run.assert_not_called()

    def test_invalid_download_is_not_published(self):
        for data in (b'wrong', self.data + b'excess', b'x' * len(self.data)):
            with self.subTest(data=data):
                with patch.object(reference.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                    with self.assertRaises(ValueError):
                        reference.obtain(self.cache, True)
                self.assertFalse((self.cache / self.lock['filename']).exists())
                self.assertFalse(list(self.cache.glob('.reference-download-*')))

    def test_verified_download_survives_failed_mount_without_staging_debris(self):
        with patch.object(reference.urllib.request, 'urlopen', return_value=io.BytesIO(self.data)):
            with patch.object(reference.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'hdiutil')):
                with self.assertRaises(subprocess.CalledProcessError):
                    reference.obtain(self.cache, True)
        self.assertEqual((self.cache / self.lock['filename']).read_bytes(), self.data)
        self.assertFalse(list(self.cache.glob('.reference-stage-*')))

    def test_cached_app_is_reverified_without_network_or_mount(self):
        app = self.cache / ('reference-' + self.lock['sha256']) / 'VLC.app'
        app.mkdir(parents=True)
        with patch.object(reference, 'verify_app') as verify:
            with patch.object(reference.urllib.request, 'urlopen') as fetch:
                self.assertEqual(reference.obtain(self.cache, False), app)
                verify.assert_called_once_with(app, self.lock)
                fetch.assert_not_called()

    def test_failed_detach_retains_staging_without_recursive_cleanup(self):
        self.cache.mkdir()
        (self.cache / self.lock['filename']).write_bytes(self.data)

        def command(argv, **kwargs):
            if argv[:2] == ['hdiutil', 'detach']:
                raise subprocess.CalledProcessError(1, argv)
            if argv[:2] == ['hdiutil', 'attach']:
                mount = argv[argv.index('-mountpoint') + 1]
                return subprocess.CompletedProcess(argv, 0, plistlib.dumps({
                    'system-entities': [{'mount-point': mount}]}))
            return subprocess.CompletedProcess(argv, 0)

        with patch.object(reference.subprocess, 'run', side_effect=command):
            with patch.object(reference, 'verify_app'):
                with patch.object(Path, 'is_mount', return_value=True):
                    with self.assertRaises(subprocess.CalledProcessError):
                        reference.obtain(self.cache, False)
        stages = list(self.cache.glob('.reference-stage-*'))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0] / 'prepared/reference-receipt.json').is_file())


if __name__ == '__main__':
    unittest.main()
