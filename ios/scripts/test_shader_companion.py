import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

from shader_compiler_peer import Peer, TARGET, sha, write_json
from shader_companion import compile_request
from test_catalog_metallibs import fixture


class CompanionTests(unittest.TestCase):
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
        self.recipe = 'b' * 64
        self.peer = Peer(self.root, self.recipe)
        self.source = fixture((2,))
        self.source_sha = sha(self.source)
        (self.root / ('sonoma-guestlib-' + self.source_sha + '.metallib')).write_bytes(self.source)

    def tearDown(self):
        self.peer.close()
        self.temp.cleanup()

    def request(self):
        request = dict(protocol=2, sha256=self.source_sha, recipe=self.recipe, target=TARGET,
                       owner=self.peer.owner, request=str(uuid.uuid4()), function='test')
        write_json(self.peer.requests / (self.source_sha + '.json'), request)
        return request

    def run_client(self):
        result = subprocess.run([str(self.client), str(self.root), self.source_sha],
                                text=True, capture_output=True, timeout=15, check=True)
        return json.loads(result.stdout)

    def publish(self, request, output=None, **extra):
        data = output or self.source
        return self.peer.publish(dict(sha256=self.source_sha, request=request['request'],
                                      output=base64.b64encode(data).decode(), output_sha256=sha(data), **extra))

    def test_only_one_companion_can_own_directory(self):
        with self.assertRaises(BlockingIOError):
            Peer(self.root, self.recipe)

    def test_first_use_exact_output_and_cache_survives_offline(self):
        self.peer.handle(dict(op='poll'))
        stop = threading.Event()
        def serve():
            while not stop.is_set():
                for request in self.peer.handle(dict(op='poll'))['requests']:
                    self.publish(request)
                stop.wait(.02)
        thread = threading.Thread(target=serve)
        thread.start()
        try:
            result = self.run_client()
        finally:
            stop.set()
            thread.join()
        self.assertEqual(result['sha256'], sha(self.source))
        (self.root / 'shader-compiler.json').unlink()
        self.assertEqual(self.run_client()['sha256'], sha(self.source))
        # Tampering with output while retaining a receipt must not yield bytes.
        (self.peer.cache / (self.source_sha + '.metallib')).write_bytes(b'MTLBcorrupt')
        result = self.run_client()
        self.assertEqual(result['length'], 0)
        self.assertLess(result['seconds'], .5)

    def test_no_wait_for_absent_stale_or_wrong_recipe_lease(self):
        self.assertLess(self.run_client()['seconds'], .5)
        self.peer.handle(dict(op='poll'))
        path = self.root / 'shader-compiler.json'
        os.utime(path, (time.time()-10, time.time()-10))
        self.assertLess(self.run_client()['seconds'], .5)
        write_json(path, dict(self.peer.config, owner=self.peer.owner, recipe='c'*64))
        self.assertLess(self.run_client()['seconds'], .5)
        self.assertEqual(list(self.peer.requests.iterdir()), [])

    def test_disconnect_terminates_wait(self):
        self.peer.handle(dict(op='poll'))
        timer = threading.Timer(.25, lambda: (self.root / 'shader-compiler.json').unlink())
        timer.start()
        try:
            result = self.run_client()
        finally:
            timer.join()
        self.assertEqual(result['length'], 0)
        self.assertLess(result['seconds'], 1)

    def test_live_but_stuck_compiler_has_bounded_wait_and_circuit_breaker(self):
        self.peer.handle(dict(op='poll'))
        stop = threading.Event()
        def heartbeat():
            while not stop.is_set():
                self.peer.handle(dict(op='poll', slots=0))
                stop.wait(.1)
        thread = threading.Thread(target=heartbeat)
        thread.start()
        try:
            output = subprocess.check_output([str(self.client), str(self.root), self.source_sha, 'd'*64],
                                             text=True, timeout=15, stderr=subprocess.DEVNULL)
        finally:
            stop.set()
            thread.join()
        result = json.loads(output)
        self.assertEqual(result['length'], 0)
        self.assertGreaterEqual(result['seconds'], 12)
        self.assertLess(result['seconds'], 13)
        self.assertEqual(result['second_length'], 0)
        self.assertLess(result['second_seconds'], .5)

    def test_failed_request_returns_failure_not_success(self):
        self.peer.handle(dict(op='poll'))
        stop = threading.Event()
        def serve():
            while not stop.is_set():
                for request in self.peer.handle(dict(op='poll'))['requests']:
                    self.peer.publish(dict(sha256=self.source_sha, request=request['request'], error='unsupported AIR'))
                stop.wait(.02)
        thread = threading.Thread(target=serve)
        thread.start()
        try:
            result = self.run_client()
            second = self.run_client()
        finally:
            stop.set()
            thread.join()
        self.assertEqual(result['length'], 0)
        self.assertLess(result['seconds'], 1)
        self.assertEqual(second['length'], 0)
        self.assertLess(second['seconds'], .5)

    def test_hash_mismatch_and_superseded_request_not_published(self):
        request = self.request()
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.peer.publish(dict(sha256=self.source_sha, request=request['request'],
                                   output=base64.b64encode(self.source).decode(), output_sha256='0'*64))
        new_request = self.request()
        with self.assertRaisesRegex(ValueError, 'superseded'):
            self.publish(request)
        self.assertEqual(list(self.peer.cache.iterdir()), [])
        self.publish(new_request)

    def test_invalid_source_fails_matching_request(self):
        request = self.request()
        (self.root / ('sonoma-guestlib-' + self.source_sha + '.metallib')).write_bytes(b'MTLBwrong')
        self.assertEqual(self.peer.handle(dict(op='poll'))['requests'], [])
        receipt = json.loads((self.peer.cache / (self.source_sha + '.json')).read_text())
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['request'], request['request'])

    def test_recipe_isolates_cache_and_wrong_source_never_compiles(self):
        request = dict(self.request(), source=base64.b64encode(self.source).decode())
        request['sha256'] = '0'*64
        with patch('shader_companion.subprocess.Popen') as compiler:
            with self.assertRaisesRegex(ValueError, 'identity'):
                compile_request(request, self.root/'mac-cache', self.recipe)
            compiler.assert_not_called()
        valid = dict(self.request(), source=base64.b64encode(self.source).decode())
        folder = self.root/'mac-cache'/self.recipe
        folder.mkdir(parents=True)
        (folder/(self.source_sha+'.metallib')).write_bytes(self.source)
        write_json(folder/(self.source_sha+'.json'), dict(recipe=self.recipe, sha256=self.source_sha,
                                                        output_sha256=sha(self.source)))
        with patch('shader_companion.subprocess.Popen') as compiler:
            self.assertEqual(compile_request(valid, self.root/'mac-cache', self.recipe), self.source)
            compiler.assert_not_called()


if __name__ == '__main__':
    unittest.main()
