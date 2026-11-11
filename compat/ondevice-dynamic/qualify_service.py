#!/usr/bin/env python3
"""Exercise actual Unix HTTP transport, guest API interposition, GPU and cache."""
import argparse
import base64
import concurrent.futures
import copy
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import threading
import time


class UnixHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.host)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controls', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    controls, out = args.controls.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    assets = out / 'assets with spaces'
    shutil.copytree(args.fixtures, assets)
    sock = out / 's.sock'
    results = []

    def check(name, passed, **details):
        results.append(dict(case=name, passed=bool(passed), **details))
        if not passed:
            raise AssertionError(name)

    def call(method, path, body=None, headers=None, chunked=False):
        connection = UnixHTTP(str(sock), timeout=65)
        try:
            connection.request(method, '/.henge/shaders/' + path, body=body,
                               headers=headers or {}, encode_chunked=chunked)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def row(name, origin=True):
        data = (assets / name).read_bytes()
        return dict(sha256=hashlib.sha256(data).hexdigest(),
                    source_base64=base64.b64encode(data).decode(),
                    origin_url=(assets / name).as_uri() if origin else None)

    error_log = (out / 'service.stderr').open('w')
    process = subprocess.Popen([str(controls / 'service-control'), str(assets), str(sock),
                                '--hold-compiler'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=error_log, text=True, bufsize=1)
    proxy = None
    try:
        if not select.select([process.stdout], [], [], 10)[0] or process.stdout.readline().strip() != 'ready':
            raise RuntimeError('Service failed to start')
        status, data = call('GET', 'identity')
        identity = json.loads(data)
        check('identity', status == 200 and identity['protocol'] == 'embedded-close-v1')
        request = dict(schema=1, recipe=identity['recipe'], consumer=row('consumer-loader.metallib'),
                       libraries=[row('dynamic-loader.metallib')], preloaded_sha256=[],
                       compile_install_names=[], function_name='dynamic_consumer',
                       origin_semantics='guest-resolved-file-urls')

        def submit(value):
            raw = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
            key = hashlib.sha256(raw).hexdigest()
            status, body = call('POST', 'close/' + key, raw)
            return status, json.loads(body) if body else {}, key

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(submit, request)
            if not select.select([process.stdout], [], [], 5)[0] or process.stdout.readline().strip() != 'request entered':
                raise RuntimeError('Queued request was not admitted')
            try:
                raw = json.dumps(request).encode()
                status, _ = call('POST', 'close/' + hashlib.sha256(raw).hexdigest(), raw)
                check('bounded-backpressure', status == 429 and not future.done())
                status, _ = call('GET', 'identity')
                check('identity-during-compilation', status == 200 and not future.done())
            finally:
                process.stdin.write('r\n')
                process.stdin.flush()
            status, receipt, key = future.result(timeout=60)
        binary = base64.b64decode(receipt.get('output_base64', ''), validate=True)
        check('queued-loader-result', status == 200 and receipt.get('status') == 'ready' and
              receipt.get('request_sha256') == key and len(binary) == receipt.get('output_bytes') and
              hashlib.sha256(binary).hexdigest() == receipt.get('output_sha256'))
        check('guest-target-preserved', binary[:4] == b'MTLB' and binary[11] == 0x81 and
              int.from_bytes(binary[12:14], 'little') == 14)

        for name, mutate in [
            ('wrong-recipe', lambda r: r.update(recipe='0' * 64)),
            ('wrong-source-digest', lambda r: r['consumer'].update(sha256='0' * 64)),
            ('missing-loader-origin', lambda r: r['consumer'].update(origin_url=None)),
            ('missing-preload', lambda r: r.update(preloaded_sha256=['0' * 64])),
            ('missing-compile-identity', lambda r: r.update(compile_install_names=['/missing.metallib'])),
            ('nonlocal-origin', lambda r: r['consumer'].update(origin_url='https://example.invalid/lib')),
            ('malformed-inventory', lambda r: r.update(libraries=[None])),
        ]:
            changed = copy.deepcopy(request)
            mutate(changed)
            status, receipt, _ = submit(changed)
            check(name, status == 200 and receipt.get('status') == 'rejected' and
                  'output_base64' not in receipt)
        status, _ = call('POST', 'close/' + '0' * 64, b'{}')
        check('wire-identity-rejected', status == 400)
        status, _ = call('POST', 'close/' + '0' * 64, b'', {'Content-Length': str((24 << 20) + 1)})
        check('oversized-upload-rejected', status == 413)
        absolute = copy.deepcopy(request)
        absolute.update(consumer=row('consumer-absolute.metallib'), libraries=[row('dynamic-absolute.metallib')],
                        preloaded_sha256=[row('dynamic-absolute.metallib')['sha256']],
                        compile_install_names=['/HengeControls/helper.metallib'])
        status, receipt, _ = submit(absolute)
        check('explicit-compile-identity', status == 200 and receipt.get('status') == 'ready')
        raw = json.dumps(request, sort_keys=True, separators=(',', ':')).encode()
        status, body = call('POST', 'close/' + hashlib.sha256(raw).hexdigest(),
                            iter([raw[:13], raw[13:]]), chunked=True)
        check('chunked-upload', status == 200 and json.loads(body).get('status') == 'ready')
        start = time.monotonic()
        status, _ = call('POST', 'close/' + '0' * 64, b'', {'Content-Length': '1'})
        elapsed = time.monotonic() - start
        check('stalled-upload-deadline', status == 413 and 10 <= elapsed < 30, seconds=elapsed)
        status, receipt, _ = submit(request)
        check('admission-after-stalled-upload', status == 200 and receipt.get('status') == 'ready')

        # Loopback is a test-only bridge to the same Unix transport. Production
        # guest code always uses the private 10.0.2.4 address and no token/config.
        hits = []

        class Proxy(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def do_GET(self):
                self.forward()

            def do_POST(self):
                self.forward()

            def forward(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                path = self.path.removeprefix('/.henge/shaders/')
                status, data = call(self.command, path, body or None)
                hits.append((self.command, self.path, status))
                self.send_response(status)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        env = os.environ.copy()
        env.pop('HENGE_DYNAMIC_CONFIG', None)
        env.update(DYLD_INSERT_LIBRARIES=str(controls / 'guest.dylib'), HENGE_DYNAMIC_TEST_DEVICE='1',
                   HENGE_EMBEDDED_TEST_ENDPOINT=f'http://127.0.0.1:{proxy.server_port}/.henge/shaders',
                   HENGE_EMBEDDED_TEST_CACHE=str(out / 'guest-cache'))
        for phase in ['cold', 'warm']:
            start = sum(method == 'POST' for method, _, _ in hits)
            for kind in ['loader', 'absolute', 'preloaded']:
                path = out / f'{phase}-{kind}.json'
                run = subprocess.run([str(controls / 'guest-control'), str(assets), kind, str(path)],
                                     env=env, capture_output=True, text=True, timeout=65)
                (out / f'{phase}-{kind}.stderr').write_text(run.stderr)
                report = json.loads(path.read_text()) if path.exists() else {}
                check(f'{phase}-api-{kind}', run.returncode == 0 and report.get('mismatches') == 0 and
                      report.get('expected_values') == 256 and report.get('command_status') == 4,
                      report=report, exit=run.returncode)
            posts = sum(method == 'POST' for method, _, _ in hits) - start
            check(phase + '-compiler-requests', posts == (3 if phase == 'cold' else 0), requests=posts)
        (out / 'proxy-requests.json').write_text(json.dumps(hits, indent=2) + '\n')
    except Exception as error:
        results.append(dict(case='exception', passed=False, error=str(error)))
    finally:
        if proxy:
            proxy.shutdown()
            proxy.server_close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        error_log.close()
        report = dict(schema=1, passed=bool(results) and all(r['passed'] for r in results), cases=results,
                      scope='Native guest API + actual Unix HTTP + embedded LLVM + Metal GPU; no iPad guest qualification')
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
