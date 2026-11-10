#!/usr/bin/env python3
"""Offline linker-mode probes using retained AIR; never deploys outputs."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time

from catalog_metallibs import inspect_metallib, tags_at


def inventory(record):
    return Counter((f['name'], f['type_raw']) for f in record['functions'])


def delta(expected, actual):
    return {label: [{'name': key[0], 'type_raw': key[1], 'count': count} for key, count in sorted(values.items())]
            for label, values in [('missing', expected - actual), ('added', actual - expected)]}


def run(command, output, expected, timeout=60):
    started = time.monotonic()
    row = {'command': command, 'runtime_verified': False, 'pixel_verified': False}
    try:
        cp = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        row.update(returncode=cp.returncode, stdout=cp.stdout, stderr=cp.stderr)
    except subprocess.TimeoutExpired:
        row.update(returncode=None, timeout=True)
    row['seconds'] = round(time.monotonic() - started, 3)
    if row.get('returncode') == 0 and output.exists():
        data = output.read_bytes()
        parsed = inspect_metallib(data)
        row.update(output=str(output), output_sha256=hashlib.sha256(data).hexdigest(),
                   format=parsed['format'], catalog_status=parsed['status'], header=parsed['header'],
                   malformed_records=parsed['malformed_records'], integrity_mismatches=parsed['integrity_mismatches'],
                   function_count=len(parsed['functions']), air_region_count=parsed['air_region_count'],
                   function_delta=delta(expected, inventory(parsed)))
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory_root', type=Path)
    args = parser.parse_args()
    root = args.inventory_root.resolve()
    destination = root / 'inventory-repair-02'
    destination.mkdir(exist_ok=True)
    catalog = json.loads((root / 'shipped/catalog.json').read_text())['libraries']
    results = []
    for record in catalog:
        if (record.get('header') or {}).get('library_type_raw') != 2:
            continue
        digest = record['sha256']
        source = root / 'shipped/artifacts' / (digest + '.metallib')
        data = source.read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest
        dynamic = next(t for t in record['unsupported_records'] if t.get('tag') == 'HDYN')
        offset, size = struct.unpack('<QQ', bytes.fromhex(dynamic['data_hex']))
        tags, end = tags_at(data, offset, offset + size)
        assert all(t['tag'] == 'NAME' for t in tags), 'Unexpected dependency; review explicitly'
        install_name = next(t['data'][:-1].decode() for t in tags if t['tag'] == 'NAME')
        output = destination / (digest + '-shared.metallib')
        air = root / 'batch-all-01' / digest / '00000.ios.air'
        command = ['xcrun', '--sdk', 'iphoneos', 'air-lld', '--create-shared-library',
                   '--arch', 'air64', '--ios_version_min', '17.0', '--install_name', install_name,
                   str(air), '-o', str(output)]
        row = run(command, output, inventory(record))
        row.update(source_sha256=digest, input_air_sha256=hashlib.sha256(air.read_bytes()).hexdigest(),
                   source_install_name=install_name)
        results.append(row)
        print(digest[:12], row.get('returncode'), row.get('function_count'), row.get('function_delta'), row.get('stderr'), flush=True)
    digest = '7fb0f218577f2c921e833d760f487ef4bd4e366b1290e02543528cc6ceadeb1d'
    air = root / 'batch-all-01' / digest / '00033.ios.air'
    for mode, extra in [('static', []), ('static-nostdlib', ['--nostdlib']), ('static-no-opt', ['--no-enable-link-optimizations'])]:
        output = destination / ('memcpy-' + mode + '.metallib')
        command = ['xcrun', '--sdk', 'iphoneos', 'air-lld', '--create-static-library', '--arch', 'air64',
                   '--ios_version_min', '17.0', *extra, str(air), '-o', str(output)]
        row = run(command, output, Counter({('memcpy', 2): 1}))
        row.update(source_sha256=digest, module_index=33, input_air_sha256=hashlib.sha256(air.read_bytes()).hexdigest())
        results.append(row)
        print(mode, row.get('returncode'), row.get('function_count'), row.get('function_delta'), row.get('stderr'), flush=True)
    (destination / 'link-mode-probe.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
