"""Exercise the production cache-selection helper, with an explicit fake loader.

The callback accepts only one output digest so failed library/function creation
can be tested without pretending protocol fixtures are real Metal libraries.
Actual Metal/pixel validation remains the device regression.
"""
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import uuid

from shader_compiler_peer import Peer, sha, write_json
from test_catalog_metallibs import fixture


class CachePriorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.client = Path(cls.build.name) / 'client'
        root = Path(__file__).resolve().parents[2]
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror',
                        '-Wno-deprecated-declarations', '-Wno-incompatible-pointer-types',
                        '-framework', 'Foundation', str(root / 'tests/shader_broker_client.m'),
                        '-o', str(cls.client)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.peer = Peer(self.root, 'b' * 64)
        self.data = fixture((2,))
        self.source = sha(self.data)
        (self.root / f'sonoma-guestlib-{self.source}.metallib').write_bytes(self.data)
        self.legacy = self.root / f'sonoma-ioslib-{self.source}.metallib'
        self.marker = self.root / f'sonoma-prefer-{self.source}'

    def tearDown(self):
        self.peer.close()
        self.temp.cleanup()

    def run_mode(self, mode, expected=None):
        args = [str(self.client), mode, str(self.root), self.source]
        if mode != '--cache-only':
            args.append(expected or sha(self.data))
        result = subprocess.run(args, capture_output=True, text=True, timeout=15, check=True)
        return json.loads(result.stdout)

    def publish_cached(self):
        request = dict(self.peer.config, sha256=self.source, owner=self.peer.owner,
                       request=str(uuid.uuid4()), function='test')
        write_json(self.peer.requests / (self.source + '.json'), request)
        self.peer.publish(dict(sha256=self.source, request=request['request'],
                               output=base64.b64encode(self.data).decode(), output_sha256=sha(self.data)))
        (self.peer.requests / (self.source + '.json')).unlink()

    def test_valid_cache_precedes_bad_preferred_legacy_without_companion(self):
        self.publish_cached()
        self.legacy.write_bytes(b'MTLBbroken legacy')
        self.marker.touch()
        result = self.run_mode('--load-cache')
        self.assertEqual(result['route'], 'recipe-cache')
        self.assertEqual(result['load_attempts'], [sha(self.data)])
        self.assertEqual(result['sha256'], sha(self.data))
        self.assertEqual(list(self.peer.requests.iterdir()), [])
        self.assertLess(result['seconds'], .5)

    def test_cache_miss_with_live_lease_never_requests_or_waits(self):
        self.peer.handle(dict(op='poll'))
        for mode in ('--cache-only', '--load-cache'):
            result = self.run_mode(mode)
            self.assertEqual(result['length'], 0)
            self.assertLess(result['seconds'], .5)
        self.assertEqual(list(self.peer.requests.iterdir()), [])

    def test_output_hash_mismatch_rejected(self):
        self.publish_cached()
        (self.peer.cache / (self.source + '.metallib')).write_bytes(b'MTLBchanged')
        result = self.run_mode('--load-cache')
        self.assertEqual(result['length'], 0)
        self.assertEqual(result['load_attempts'], [])
        self.assertEqual(list(self.peer.requests.iterdir()), [])

    def test_wrong_recipe_source_target_and_length_rejected(self):
        self.publish_cached()
        path = self.peer.cache / (self.source + '.json')
        original = json.loads(path.read_text())
        for key, value in [('recipe', 'c'*64), ('sha256', 'd'*64),
                           ('target', 'air64-apple-macosx14.0.0'), ('length', len(self.data)+1)]:
            with self.subTest(key=key):
                write_json(path, dict(original, **{key: value}))
                result = self.run_mode('--cache-only')
                self.assertEqual(result['length'], 0)
        write_json(path, original)
        config = self.root / 'shader-compiler-config.json'
        write_json(config, dict(self.peer.config, recipe='e'*64))
        self.assertEqual(self.run_mode('--cache-only')['length'], 0)

    def test_legacy_preference_preserved_only_when_explicit_early(self):
        self.legacy.write_bytes(self.data)
        self.assertEqual(self.run_mode('--load-cache')['length'], 0)
        self.marker.touch()
        result = self.run_mode('--load-cache')
        self.assertEqual(result['route'], 'legacy')
        self.assertEqual(result['sha256'], sha(self.data))

    def test_invalid_flat_file_does_not_suppress_online_recovery(self):
        self.legacy.write_bytes(b'MTLBunusable library or missing function')
        self.peer.handle(dict(op='poll'))
        stop = threading.Event()
        def serve():
            while not stop.is_set():
                for request in self.peer.handle(dict(op='poll'))['requests']:
                    self.peer.publish(dict(sha256=self.source, request=request['request'],
                        output=base64.b64encode(self.data).decode(), output_sha256=sha(self.data)))
                stop.wait(.02)
        thread = threading.Thread(target=serve)
        thread.start()
        try:
            result = self.run_mode('--load-converted')
        finally:
            stop.set()
            thread.join()
        self.assertEqual(result['route'], 'broker')
        self.assertEqual(result['load_attempts'], [sha(self.legacy.read_bytes()), sha(self.data)])
        self.assertEqual(result['sha256'], sha(self.data))

    def test_rejected_cached_and_identical_legacy_output_not_retried(self):
        self.publish_cached()
        self.legacy.write_bytes(self.data)
        result = self.run_mode('--load-converted', expected='f'*64)
        self.assertEqual(result['length'], 0)
        self.assertEqual(result['load_attempts'], [sha(self.data)])
        self.assertEqual(list(self.peer.requests.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
