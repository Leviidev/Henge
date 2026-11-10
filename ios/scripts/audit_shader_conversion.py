#!/usr/bin/env python3
"""Offline, non-deploying conversion audit for catalogued shipped Metal libraries.

The default writes a complete plan. --run-prefix selects explicit SHA prefixes
for a bounded experiment; no output is copied to Henge or labelled pixel-correct.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import time

from catalog_metallibs import inspect_metallib


def save(path, data):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def eligible_modules(record):
    """Return all bounded modules; never guess how to handle opaque containers."""
    if record['format'] != 'metallib' or record['malformed_records']:
        raise ValueError('requires structurally valid top-level MTLB')
    if record.get('integrity_mismatches'):
        raise ValueError('source integrity discrepancy requires explicit review')
    if record['uncovered_bitcode_ranges']:
        raise ValueError('unaccounted bytes in AIR section')
    modules = record['air_regions']
    if not modules or not all(x['structurally_valid_wrapper'] for x in modules):
        raise ValueError('missing or unsupported AIR module wrapper')
    covered = sorted(i for x in modules for i in x['function_indices'])
    if covered != list(range(len(record['functions']))):
        raise ValueError('not all function records have an accounted AIR module')
    return modules


def functions(record):
    return Counter((f['name'], f['type_raw']) for f in record['functions'])


def function_delta(before, after):
    def rows(counter):
        return [{'name': name, 'type_raw': kind, 'count': count}
                for (name, kind), count in counter.items()]
    left, right = functions(before), functions(after)
    return {'missing': rows(left - right), 'added': rows(right - left)}


def command(args, log, timeout):
    start = time.monotonic()
    try:
        with log.open('w') as stream:
            result = subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=timeout, check=False)
        status, code = ('passed' if result.returncode == 0 else 'failed'), result.returncode
    except subprocess.TimeoutExpired:
        status, code = 'timeout', None
    return {'command': args, 'status': status, 'returncode': code,
            'seconds': round(time.monotonic() - start, 3), 'log': str(log)}


def audit(job, output, target, timeout):
    folder = output / job['sha256']
    folder.mkdir()
    data = Path(job['source']).read_bytes()
    if hashlib.sha256(data).hexdigest() != job['sha256']:
        raise ValueError('source changed after planning')
    original = inspect_metallib(data)
    modules = eligible_modules(original)
    result = {'source_sha256': job['sha256'], 'paths': job['paths'],
              'target': target, 'status': 'running', 'modules': [],
              'runtime_verified': False, 'pixel_verified': False,
              'original_opaque_records': original['unsupported_records']}
    save(folder / 'result.json', result)
    objects = []
    # Preserve distinct module extents, including identical bytes at different
    # extents. Do not silently deduplicate definitions or change library linkage.
    for index, module in enumerate(modules):
        air, obj = folder / f'{index:05}.air', folder / f'{index:05}.ios.air'
        payload = data[module['offset']:module['offset'] + module['size']]
        if hashlib.sha256(payload).hexdigest() != module['sha256']:
            raise ValueError('AIR hash mismatch')
        air.write_bytes(payload)
        step = command(['xcrun', '--sdk', 'iphoneos', 'metal', '-x', 'ir', '-c',
                        str(air), '-o', str(obj), '-target', target],
                       folder / f'{index:05}.compile.log', timeout)
        step.update(index=index, source_air_sha256=module['sha256'],
                    function_indices=module['function_indices'])
        if step['status'] == 'passed':
            step['output_air_sha256'] = hashlib.sha256(obj.read_bytes()).hexdigest()
        result['modules'].append(step)
        if (index + 1) % 25 == 0 or index + 1 == len(modules):
            save(folder / 'result.json', result)
        if step['status'] == 'passed':
            objects.append(obj)
    if len(objects) != len(modules):
        result['status'] = 'module_compile_failed'
    else:
        # A response file avoids ARG_MAX for libraries with thousands of modules.
        response = folder / 'modules.rsp'
        response.write_text('\n'.join('"' + str(p).replace('\\', '\\\\').replace('"', '\\"') + '"'
                                      for p in objects) + '\n')
        linked = folder / 'converted.metallib'
        # The observed type-1 Core Image archives lose extern declarations
        # under default linking; --cikernel preserved the two pilot inventories.
        # Keep other library kinds on the baseline path and report discrepancies.
        flags = ['--cikernel'] if original['header']['library_type_raw'] == 1 else []
        result['link'] = command(['xcrun', '--sdk', 'iphoneos', 'metallib', *flags,
                                  '@' + str(response), '-o', str(linked)],
                                 folder / 'link.log', timeout)
        if result['link']['status'] != 'passed':
            result['status'] = 'link_timeout' if result['link']['status'] == 'timeout' else 'link_failed'
        else:
            converted = inspect_metallib(linked.read_bytes())
            save(folder / 'converted-catalog.json', converted)
            result['output_sha256'] = converted['sha256']
            result['integrity_mismatches'] = converted.get('integrity_mismatches', [])
            result['function_delta'] = function_delta(original, converted)
            if converted['format'] != 'metallib' or converted['malformed_records']:
                result['status'] = 'output_structure_failed'
            elif any(result['function_delta'].values()):
                result['status'] = 'function_inventory_changed'
            elif result['integrity_mismatches']:
                result['status'] = 'compiled_inventory_preserved_integrity_review'
            else:
                result['status'] = 'compiled_inventory_preserved'
    save(folder / 'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory_root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run-prefix', action='append', default=[])
    parser.add_argument('--run-all', action='store_true')
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=1)
    parser.add_argument('--target', default='air64-apple-ios17.0.0')
    parser.add_argument('--timeout', type=int, default=60)
    args = parser.parse_args()
    root, output = args.inventory_root.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    catalog = json.loads((root / 'shipped/catalog.json').read_text())
    native = json.loads((root / 'shipped/shipped-libraries.json').read_text())
    paths = {x['sha256']: x['paths'] for x in native['libraries']}
    jobs = []
    for record in catalog['libraries']:
        job = {'sha256': record['sha256'], 'source': record['source_paths'][0],
               'paths': paths.get(record['sha256'], []), 'format': record['format'],
               'function_records': len(record['functions']), 'air_regions': record['air_region_count']}
        try:
            eligible_modules(record)
            job['status'] = 'eligible_for_offline_attempt'
        except ValueError as error:
            job.update(status='requires_separate_handling', reason=str(error))
        jobs.append(job)
    plan = {'generated_at': datetime.now(timezone.utc).isoformat(), 'target': args.target,
            'jobs': jobs, 'counts': dict(Counter(x['status'] for x in jobs)),
            'limits': ['No outputs are deployed.', 'Function inventory preservation does not prove ABI or pixel correctness.',
                       'Opaque metadata is recorded, not proven preserved.', 'Driver tables and FAT slices need separate handling.']}
    save(output / 'plan.json', plan)
    selected = []
    if args.run_all and args.run_prefix:
        parser.error('use --run-all or --run-prefix, not both')
    for prefix in args.run_prefix:
        matches = [x for x in jobs if x['sha256'].startswith(prefix)]
        if len(matches) != 1:
            parser.error(f'prefix {prefix!r} must select exactly one artifact')
        if matches[0]['status'] != 'eligible_for_offline_attempt':
            parser.error(f'prefix {prefix!r} is not eligible')
        if matches[0] not in selected:
            selected.append(matches[0])
    if args.run_all:
        selected = [x for x in jobs if x['status'] == 'eligible_for_offline_attempt']
        selected.sort(key=lambda x: x['air_regions'])
    # Refuse to mix a new attempt with pre-existing outputs or stale successes.
    if any((output / job['sha256']).exists() for job in selected):
        parser.error('selected output already exists; choose a fresh --output directory')
    if selected:
        versions = {}
        for tool in ('metal', 'metallib'):
            versions[tool] = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', tool, '--version'], text=True)
        save(output / 'toolchain.json', versions)
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        pending = {pool.submit(audit, job, output, args.target, args.timeout): job for job in selected}
        for future in as_completed(pending):
            job = pending[future]
            try:
                result = future.result()
            except Exception as error:
                result = {'source_sha256': job['sha256'], 'status': 'audit_error',
                          'error': str(error), 'runtime_verified': False, 'pixel_verified': False}
                folder = output / job['sha256']
                folder.mkdir(exist_ok=True)
                save(folder / 'result.json', result)
            results.append(result)
            save(output / 'results.json', results)
            print(job['sha256'][:12], result['status'], flush=True)
    print(json.dumps(plan['counts']), flush=True)
    if any(x['status'] != 'compiled_inventory_preserved' for x in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
