#!/usr/bin/env python3
"""Exercise the real pipe client against a deliberately asynchronous parent."""
import base64
import json
import os
import select
import subprocess
import sys
import time


def exercise(mode):
    process = subprocess.Popen([sys.argv[1], mode], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    buffered = b''

    def read():
        nonlocal buffered
        deadline = time.monotonic() + 5
        while b'\n' not in buffered:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([process.stdout], [], [], remaining)[0], mode
            chunk = os.read(process.stdout.fileno(), 4096)
            assert chunk, f'{mode}: unexpected EOF'
            buffered += chunk
            assert len(buffered) <= 8192
        line, buffered = buffered.split(b'\n', 1)
        message = json.loads(line)
        assert message['version'] == 1
        return message

    def reply(identifier, status, body):
        response = dict(version=1, id=identifier, status=status,
                        body=base64.b64encode(body).decode())
        process.stdin.write(json.dumps(response).encode() + b'\n')
        process.stdin.flush()

    try:
        first = read()
        if mode == 'multiplex':
            second = read()
            messages = {item['method']: item for item in [first, second]}
            assert base64.b64decode(messages['PUT']['body']) == bytes(range(36))
            # An orphan reply must not consume a live continuation. Reverse the
            # real replies to detect accidental FIFO response matching.
            reply(first['id'] + 1000, 200, b'orphan')
            reply(messages['PUT']['id'], 204, b'report')
            reply(messages['GET']['id'], 200, b'metadata')
        elif mode == 'eof':
            process.stdin.close()
        assert process.wait(timeout=6) == 0, process.stderr.read().decode(errors='replace')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


for name in ['multiplex', 'cancel', 'timeout', 'eof']:
    exercise(name)
print('Guest pipe transport: out-of-order replies, orphan replies, binary bodies, cancellation, timeout and EOF passed')
