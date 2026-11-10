#!/usr/bin/env python3
"""Test already-compiled AIR modules independently; never deploy or merge them.

Whole-archive linking can introduce symbol collisions absent from the original
per-function modules. This audit keeps those boundaries and records the exact
source function records covered by each output. It does not make a substitute
full-library artifact or claim runtime/pixel verification.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path

from audit_shader_conversion import command, function_delta, save
from catalog_metallibs import inspect_metallib


def link_one(source, module, folder, timeout):
    index = module['index']
    air = source / f'{index:05}.ios.air'
    output = folder / f'{index:05}.metallib'
    result = {**module, 'input_air_sha256': hashlib.sha256(air.read_bytes()).hexdigest(),
              'runtime_verified': False, 'pixel_verified': False}
    result['link'] = command(['xcrun', '--sdk', 'iphoneos', 'metallib', str(air), '-o', str(output)],
                             folder / f'{index:05}.log', timeout)
    if result['link']['status'] != 'passed':
        result['status'] = 'link_timeout' if result['link']['status'] == 'timeout' else 'link_failed'
        return result
    converted = inspect_metallib(output.read_bytes())
    result['output_sha256'] = converted['sha256']
    result['function_delta'] = function_delta({'functions': module['expected_functions']}, converted)
    result['output_header'] = converted['header']
    result['output_errors'] = converted['malformed_records']
    result['integrity_mismatches'] = converted.get('integrity_mismatches', [])
    if converted['format'] != 'metallib' or converted['malformed_records']:
        result['status'] = 'output_structure_failed'
    elif converted['header']['target_os'] != 'iOS':
        result['status'] = 'unexpected_target'
    elif any(result['function_delta'].values()):
        result['status'] = 'function_inventory_changed'
    elif result['integrity_mismatches']:
        result['status'] = 'module_inventory_preserved_integrity_review'
    else:
        result['status'] = 'module_inventory_preserved'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory_root', type=Path)
    parser.add_argument('--batch', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prefix', action='append', required=True)
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=4)
    parser.add_argument('--timeout', type=int, default=30)
    args = parser.parse_args()
    catalog = json.loads((args.inventory_root/'shipped/catalog.json').read_text())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    tasks = []
    selected = []
    for prefix in args.prefix:
        candidates = [x for x in catalog['libraries'] if x['sha256'].startswith(prefix)]
        if len(candidates) != 1:
            parser.error(f'ambiguous/missing prefix: {prefix}')
        lib = candidates[0]
        if lib['sha256'] in selected:
            parser.error('duplicate library selection')
        if lib['format'] != 'metallib' or lib['header']['library_type_raw'] != 0:
            parser.error('this audit supports ordinary type-0 libraries only')
        selected.append(lib['sha256'])
        source = args.batch.resolve()/lib['sha256']
        previous = json.loads((source/'result.json').read_text())
        if len(previous['modules']) != len(lib['air_regions']):
            parser.error('previous compile attempt did not cover every module')
        folder = output/lib['sha256']
        folder.mkdir()
        for index, region in enumerate(lib['air_regions']):
            compile_step = previous['modules'][index]
            if compile_step['index'] != index or compile_step['status'] != 'passed' or compile_step['source_air_sha256'] != region['sha256']:
                parser.error('previous compile result does not match catalogued module')
            module = {'source_library_sha256': lib['sha256'], 'index': index,
                      'source_air_sha256': region['sha256'], 'function_indices': region['function_indices'],
                      'expected_functions': [{'name': lib['functions'][i]['name'], 'type_raw': lib['functions'][i]['type_raw']}
                                             for i in region['function_indices']]}
            tasks.append((source, module, folder))
    save(output/'plan.json', {'libraries': selected, 'modules': len(tasks), 'input_batch': str(args.batch.resolve()),
                             'scope': 'Independent module linking; not a replacement whole library.'})
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(link_one, source, module, folder, args.timeout): module
                   for source, module, folder in tasks}
        for future in as_completed(futures):
            try:
                result = future.result()
            except Exception as error:
                result = {**futures[future], 'status': 'audit_error', 'error': str(error)}
            results.append(result)
            if len(results) % 100 == 0 or len(results) == len(tasks):
                save(output/'results.json', results)
                print(f'{len(results)}/{len(tasks)} {dict(Counter(x["status"] for x in results))}', flush=True)
    counts = {digest: dict(Counter(x['status'] for x in results if x['source_library_sha256'] == digest)) for digest in selected}
    save(output/'summary.json', {'modules': len(results), 'by_library': counts, 'runtime_tested': 0, 'deployed': 0})
    if any(x['status'] != 'module_inventory_preserved' for x in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
