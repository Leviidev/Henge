#!/usr/bin/env python3
"""Serve first-use Henge AIR conversions over an existing authenticated SSH link.

No automatic installation/startup: run explicitly with --host and --documents.
The host remains required for uncached libraries. Ctrl-C revokes the lease;
the recipe-qualified, hash-checked cache remains usable offline.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from catalog_metallibs import inspect_metallib
from shader_compiler_peer import LIMIT, TARGET, atomic, digest, sha

HERE = Path(__file__).resolve().parent


def recipe_manifest():
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    os.environ['DEVELOPER_DIR'] = developer  # pin child processes to this toolchain
    tools = {}
    for name in ('metal', 'metallib'):
        path = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--find', name], text=True).strip()
        tools[name] = dict(path=path, sha256=sha(Path(path).read_bytes()))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-build-version'], text=True).strip()
    return dict(protocol=2, target=TARGET, developer=developer, sdk_build=sdk, tools=tools,
                sources={name: sha((HERE / name).read_bytes()) for name in
                         ('recompile_guest_metallib.py', 'catalog_metallibs.py', 'shader_companion.py')})


def inventory(data):
    parsed = inspect_metallib(data)
    if (parsed['format'] != 'metallib' or parsed['malformed_records']
            or parsed.get('integrity_mismatches') or not parsed['single_payload_extraction_valid']):
        raise ValueError('requires validated single-module AIR')
    return sorted((f['name'], f['type_raw']) for f in parsed['functions'])


def compile_request(request, cache, recipe):
    source_sha = digest(request['sha256'])
    source = base64.b64decode(request['source'], validate=True)
    if not 4 <= len(source) <= LIMIT or sha(source) != source_sha:
        raise ValueError('source identity or size mismatch')
    expected = inventory(source)
    folder = cache / recipe
    folder.mkdir(parents=True, exist_ok=True)
    output_path = folder / (source_sha + '.metallib')
    receipt_path = folder / (source_sha + '.json')
    if output_path.exists() and receipt_path.exists():
        output = output_path.read_bytes()
        receipt = json.loads(receipt_path.read_text())
        if (receipt.get('recipe') == recipe and receipt.get('sha256') == source_sha
                and receipt.get('output_sha256') == sha(output) and inventory(output) == expected):
            return output
    with tempfile.TemporaryDirectory(prefix='compile-', dir=folder) as temporary:
        root = Path(temporary)
        source_path = root / 'source.metallib'
        source_path.write_bytes(source)
        command = [sys.executable, str(HERE / 'recompile_guest_metallib.py'), str(source_path),
                   '--output-dir', str(root), '--target', TARGET]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            _, errors = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise TimeoutError('compiler exceeded 10 seconds')
        if process.returncode:
            raise ValueError(errors.decode(errors='replace')[-2048:])
        output = (root / ('sonoma-ioslib-' + source_sha + '.metallib')).read_bytes()
        if len(output) > LIMIT or inventory(output) != expected:
            raise ValueError('output structure or function inventory mismatch')
        atomic(output_path, output)
        atomic(receipt_path, json.dumps(dict(recipe=recipe, sha256=source_sha,
                                            output_sha256=sha(output))).encode())
        return output


class Connection:
    def __init__(self, command):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.pending = bytearray()

    def call(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 5
        while b'\n' not in self.pending:
            if not select.select([self.process.stdout], [], [], max(0, deadline-time.monotonic()))[0]:
                raise TimeoutError('SSH peer stopped responding')
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                raise ConnectionError('SSH peer closed')
            self.pending.extend(data)
            if len(self.pending) > 3 * LIMIT:
                raise ValueError('oversized peer response')
        line, _, rest = self.pending.partition(b'\n')
        self.pending = bytearray(rest)
        result = json.loads(line)
        if not result.get('ok'):
            raise ValueError(result.get('error', 'peer error'))
        return result['result']

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host')
    parser.add_argument('--host-key-alias')
    parser.add_argument('--documents', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--local', action='store_true', help='local integration test instead of SSH')
    args = parser.parse_args()
    if not args.local and not args.host:
        parser.error('--host required unless --local')
    manifest = recipe_manifest()
    recipe = sha(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode())
    atomic(args.cache / recipe / 'recipe.json', json.dumps(manifest, indent=2).encode())
    peer_source = (HERE / 'shader_compiler_peer.py').read_text()
    if args.local:
        command = [sys.executable, '-u', '-c', peer_source, str(args.documents), recipe]
    else:
        command = ['ssh', '-T', '-oBatchMode=yes', '-oConnectTimeout=5', '-oServerAliveInterval=2',
                   '-oServerAliveCountMax=2']
        if args.host_key_alias:
            command += ['-oHostKeyAlias=' + args.host_key_alias]
        command += [args.host, shlex.join(['/var/jb/usr/bin/python3', '-u', '-c', peer_source,
                                          str(args.documents), recipe])]
    connection = Connection(command)
    pending = {}
    print(json.dumps(dict(event='starting', recipe=recipe, target=TARGET)), flush=True)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            while True:
                for source, (request, future) in list(pending.items()):
                    if not future.done():
                        continue
                    publication = dict(op='publish', sha256=source, request=request['request'])
                    try:
                        output = future.result()
                        publication.update(output=base64.b64encode(output).decode(), output_sha256=sha(output))
                    except Exception as error:
                        publication['error'] = str(error)
                    result = connection.call(publication)
                    print(json.dumps(dict(event='published', **result)), flush=True)
                    del pending[source]
                result = connection.call(dict(op='poll', skip=list(pending), slots=2-len(pending)))
                for request in result['requests']:
                    if request['sha256'] not in pending:
                        if request.get('recipe') != recipe or request.get('target') != TARGET:
                            raise ValueError('peer recipe/target mismatch')
                        pending[request['sha256']] = (request, pool.submit(compile_request, request, args.cache, recipe))
                        print(json.dumps(dict(event='requested', sha256=request['sha256'])), flush=True)
                time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    finally:
        connection.close()


if __name__ == '__main__':
    main()
