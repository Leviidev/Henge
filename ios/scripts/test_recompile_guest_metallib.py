import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from recompile_guest_metallib import rebuild
from test_catalog_metallibs import fixture


class RecompileTests(unittest.TestCase):
    def test_integrity_discrepancy_requires_review_before_conversion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root/'source.metallib'
            data = bytearray(fixture((2,)))
            data[data.index(b'HASH')+6] ^= 1
            source.write_bytes(data)
            with patch('recompile_guest_metallib.subprocess.run') as run:
                with self.assertRaises(ValueError):
                    rebuild(source, root/'outputs', 'air64-apple-ios17.0.0')
                run.assert_not_called()

    def test_multi_module_input_is_not_silently_truncated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root/'source.metallib'
            source.write_bytes(fixture())
            with patch('recompile_guest_metallib.subprocess.run') as run:
                with self.assertRaisesRegex(ValueError, 'single-module'):
                    rebuild(source, root/'outputs', 'air64-apple-ios17.0.0')
                run.assert_not_called()

    def test_function_loss_does_not_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root/'source.metallib'
            data = fixture((2,))
            source.write_bytes(data)
            output = root/f'sonoma-ioslib-{hashlib.sha256(data).hexdigest()}.metallib'
            output.write_bytes(b'existing conversion')
            def fake_tool(args, **kwargs):
                if 'metallib' in args:
                    Path(args[args.index('-o')+1]).write_bytes(fixture((1,)))
            with patch('recompile_guest_metallib.subprocess.run', side_effect=fake_tool):
                with self.assertRaisesRegex(ValueError, 'function-inventory'):
                    rebuild(source, root, 'air64-apple-ios17.0.0')
            self.assertEqual(output.read_bytes(), b'existing conversion')


if __name__ == '__main__':
    unittest.main()
