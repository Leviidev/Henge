#!/usr/bin/env python3
"""Private stdio endpoint for shader_companion.py; no listening network socket.

Executed on the iPad over authenticated SSH. One process holds the directory
lock; its lease expires if polling stops. Successful receipts are published last.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import uuid

PROTOCOL = 2
TARGET = 'air64-apple-ios17.0.0'
LIMIT = 32 * 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        raise ValueError('invalid digest')
    return value


def read_file(path, limit=LIMIT):
    with path.open('rb') as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('file exceeds limit')
    return data


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.publish-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            parent = path.parent.stat()
            os.fchown(stream.fileno(), parent.st_uid, parent.st_gid)
            os.fchmod(stream.fileno(), 0o644)
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    atomic(path, json.dumps(value, sort_keys=True).encode())


class Peer:
    def __init__(self, root, recipe):
        self.root = Path(root).resolve(strict=True)
        self.recipe = digest(recipe)
        self.owner = str(uuid.uuid4())
        self.lock = (self.root / 'shader-compiler.lock').open('a')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock.close()
            raise
        self.cache = self.root / 'shader-cache' / self.recipe
        self.requests = self.root / 'shader-requests-v2'
        self.cache.mkdir(parents=True, exist_ok=True)
        self.requests.mkdir(exist_ok=True)
        # SSH may be root, while Henge is mobile. Match the app container's
        # owner so it can read receipts and create its request files.
        owner = self.root.stat()
        for directory in (self.cache.parent, self.cache, self.requests):
            os.chown(directory, owner.st_uid, owner.st_gid)
        self.config = dict(protocol=PROTOCOL, target=TARGET, recipe=self.recipe)
        write_json(self.root / 'shader-compiler-config.json', self.config)

    def request(self, source):
        request = json.loads(read_file(self.requests / (digest(source) + '.json'), 8192))
        if (request.get('protocol') != PROTOCOL or request.get('sha256') != source
                or request.get('recipe') != self.recipe or request.get('owner') != self.owner
                or request.get('target') != TARGET):
            raise ValueError('stale or mismatched request')
        uuid.UUID(request['request'])
        return request

    def handle(self, command):
        op = command['op']
        if op == 'poll':
            write_json(self.root / 'shader-compiler.json', dict(self.config, owner=self.owner))
            skip = set(command.get('skip', []))
            requests = []
            slots = max(0, min(2, int(command.get('slots', 2))))
            if not slots:
                return dict(owner=self.owner, requests=requests)
            # Two 32 MiB libraries per response at most; no unbounded archive.
            for path in sorted(self.requests.glob('*.json')):
                if path.stem in skip:
                    continue
                try:
                    request = self.request(path.stem)
                    receipt_path = self.cache / (path.stem + '.json')
                    if receipt_path.exists():
                        receipt = json.loads(read_file(receipt_path, 8192))
                        if receipt.get('request') == request['request']:
                            if receipt.get('status') == 'failed':
                                continue
                            if receipt.get('status') == 'ready':
                                try:
                                    cached = read_file(self.cache / (path.stem + '.metallib'))
                                    if sha(cached) == receipt.get('output_sha256') and len(cached) == receipt.get('length'):
                                        continue
                                except OSError:
                                    pass
                    source = read_file(self.root / ('sonoma-guestlib-' + path.stem + '.metallib'))
                    if sha(source) != path.stem or not source.startswith(b'MTLB'):
                        raise ValueError('source identity or magic mismatch')
                    requests.append(dict(request, source=base64.b64encode(source).decode()))
                except (OSError, ValueError, KeyError) as error:
                    # Invalid/missing source must be observable and terminate the
                    # matching wait, rather than silently burning its deadline.
                    try:
                        request = self.request(path.stem)
                        self.publish(dict(op='publish', sha256=path.stem,
                                          request=request['request'], error=str(error)))
                    except (OSError, ValueError, KeyError):
                        pass
                if len(requests) == slots:
                    break
            return dict(owner=self.owner, requests=requests)
        if op == 'publish':
            return self.publish(command)
        raise ValueError('unknown operation')

    def publish(self, command):
        source = digest(command['sha256'])
        request = self.request(source)
        if command['request'] != request['request']:
            raise ValueError('request superseded')
        receipt = dict(self.config, sha256=source, request=request['request'], owner=self.owner)
        if 'error' in command:
            receipt.update(status='failed', error=str(command['error'])[:2048])
        else:
            output = base64.b64decode(command['output'], validate=True)
            if not 4 <= len(output) <= LIMIT or not output.startswith(b'MTLB'):
                raise ValueError('invalid output size or magic')
            if sha(output) != digest(command['output_sha256']):
                raise ValueError('output identity mismatch')
            # Does not overwrite the legacy manually validated cache.
            atomic(self.cache / (source + '.metallib'), output)
            receipt.update(status='ready', output_sha256=sha(output), length=len(output))
        write_json(self.cache / (source + '.json'), receipt)
        if receipt['status'] == 'ready':
            atomic(self.root / 'shader-retry', b'')
        return dict(status=receipt['status'], sha256=source)

    def close(self):
        lease = self.root / 'shader-compiler.json'
        try:
            if json.loads(read_file(lease, 8192)).get('owner') == self.owner:
                lease.unlink()
        except (OSError, ValueError):
            pass
        self.lock.close()


def main():
    peer = Peer(sys.argv[1], sys.argv[2])
    try:
        while True:
            line = sys.stdin.buffer.readline(2 * LIMIT + 65536)
            if not line:
                break
            if not line.endswith(b'\n'):
                raise ValueError('oversized command')
            try:
                result = peer.handle(json.loads(line))
                print(json.dumps(dict(ok=True, result=result)), flush=True)
            except (OSError, ValueError, KeyError) as error:
                print(json.dumps(dict(ok=False, error=str(error))), flush=True)
    finally:
        peer.close()


if __name__ == '__main__':
    main()
