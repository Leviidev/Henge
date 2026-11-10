#!/usr/bin/env python3
"""Negative controls for independent authored-buffer review; no Metal/device calls."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / 'controls/review_results.py'
SPEC = importlib.util.spec_from_file_location('dynamic_review', PATH)
reviewer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reviewer)


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.path = self.root / 'result.u32'
        self.values = [i * 7 + 19 for i in range(256)]
        self.execution = {'raw_readback_file': 'result.u32', 'elements_checked': 256,
                          'mismatches': 0, 'dispatch_completed': True,
                          'readback_exact': True, 'command_error': ''}
        self.write(struct.pack('<256I', *self.values))

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, data):
        self.path.write_bytes(data)
        self.execution['actual_sha256'] = hashlib.sha256(data).hexdigest()

    def evaluate(self):
        return reviewer.raw_case(self.root, self.execution, 'authored', 7, 19)

    def test_valid_authored_data(self):
        self.assertEqual(self.evaluate()['values'], 256)

    def test_changed_word_rejected_even_with_forged_success_and_matching_sha(self):
        self.values[123] += 1
        self.write(struct.pack('<256I', *self.values))
        with self.assertRaisesRegex(ValueError, 'index123'):
            self.evaluate()

    def test_wrong_dependency_body_rejected(self):
        self.write(struct.pack('<256I', *(i * 7 + 23 for i in range(256))))
        with self.assertRaises(ValueError):
            self.evaluate()

    def test_wrong_byte_order_rejected(self):
        self.write(struct.pack('>256I', *self.values))
        with self.assertRaises(ValueError):
            self.evaluate()

    def test_truncated_buffer_rejected(self):
        self.write(self.path.read_bytes()[:-4])
        with self.assertRaisesRegex(ValueError, 'little-endian'):
            self.evaluate()

    def test_stale_report_hash_rejected(self):
        self.execution['actual_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'SHA'):
            self.evaluate()

    def test_report_path_cannot_escape_collection(self):
        self.execution['raw_readback_file'] = '../outside.u32'
        with self.assertRaisesRegex(ValueError, 'relative'):
            self.evaluate()

    def test_nonzero_executable_status_rejected(self):
        (self.root / 'async.exit').write_text('1\n')
        with self.assertRaisesRegex(ValueError, 'exit0'):
            reviewer.checked_exit(self.root, 'async.exit')

    def test_incomplete_dispatch_rejected_despite_matching_pixels(self):
        self.execution['dispatch_completed'] = False
        with self.assertRaisesRegex(ValueError, 'dispatch'):
            self.evaluate()


if __name__ == '__main__':
    unittest.main()
