#!/usr/bin/env python3
"""Host-only raw uint32 reviewer for the authored dynamic guest controls.

Reads collected reports, exit files and raw buffers. No guest Python, execution,
network access, compiler lifecycle changes or inference of arbitrary shaders.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

HERE = Path(__file__).resolve().parent
COUNT = 256


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(path):
    return json.loads(path.read_text())


def contained(directory, name):
    require(isinstance(name, str) and Path(name).name == name and name not in ('', '.', '..'),
            'Expected a single relative filename/directory')
    path = directory / name
    require(path.resolve().is_relative_to(directory.resolve()), 'Result path escapes its directory')
    return path


def checked_exit(root, name):
    path = root / name
    require(path.read_text().strip() == '0', f'{name}: executable did not exit0')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def raw_case(directory, execution, name, multiplier, addition):
    path = contained(directory, execution['raw_readback_file'])
    data = path.read_bytes()
    require(len(data) == COUNT * 4, f'{name}: expected256 little-endian uint32 values')
    actual = struct.unpack('<256I', data)
    expected = tuple((i * multiplier + addition) & 0xffffffff for i in range(COUNT))
    mismatch = next((i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]), None)
    require(mismatch is None, f'{name}: raw value differs at index{mismatch}')
    digest = hashlib.sha256(data).hexdigest()
    require(execution.get('actual_sha256') == digest, f'{name}: reported SHA differs from raw bytes')
    require(execution.get('elements_checked') == COUNT and execution.get('mismatches') == 0,
            f'{name}: inconsistent producer element counts')
    require(bool(execution.get('dispatch_completed')) and bool(execution.get('readback_exact'))
            and execution.get('command_error') == '', f'{name}: dispatch did not complete cleanly')
    return {'case': name, 'values': COUNT, 'sha256': digest,
            'expected_formula': f'i*{multiplier}+{addition}', 'raw_values_exact': True}


def matrix(root):
    latest = load(root / 'inventory-latest.json')
    directory = contained(root, latest['relative_directory'])
    report = load(directory / 'inventory-report.json')
    require(report['status'] == 'complete_results_require_review', 'Matrix report is incomplete')
    require(report['asset_verification'] and all(report['asset_verification'].values()),
            'Producer fixture verification failed')
    packed = report['packed_control']
    require(packed['origin'] == 'authored' and packed['asset_hash_matches'], 'Wrong packed fixture')
    expected = {('alpha', 0), ('alpha', 1), ('beta', 0), ('beta', 1)}
    rows = packed['cases']
    require(len(rows) == 4 and {(x['name'], x['mode']) for x in rows} == expected,
            'Missing/duplicate packed specialization')
    checks = []
    for row in rows:
        require(row['constant_index'] == 0 and row['constant_type'] == 'bool'
                and row['function_created'] and row['pipeline_created'], 'Wrong function specialization')
        name, mode = row['name'], row['mode']
        checks.append(raw_case(directory, row['execution'], f'packed-{name}-{mode}', 1,
                               (1000 if name == 'alpha' else 2000) + 100 * mode))
    dynamic = report['dynamic_control']
    require(dynamic['origin'] == 'authored' and dynamic['supports_dynamic_libraries'],
            'Wrong dynamic control mode')
    rows = dynamic['cases']
    kinds = {'relative_source', 'loader_file', 'absolute_source', 'preloaded_only'}
    require(len(rows) == 4 and {x['kind'] for x in rows} == kinds, 'Missing/duplicate dynamic route')
    for row in rows:
        require(row['asset_hash_matches'] and row['dynamic_created'] and row['consumer_library_created'],
                'Dynamic library/control asset failed')
        if row['kind'] == 'relative_source':
            require(not row['consumer_pipeline_created'] and row['gate'] == 'expected_rejection'
                    and 'execution' not in row, 'Relative source without URL must remain rejected')
        else:
            require(row['consumer_pipeline_created'], 'Dynamic pipeline not created')
            checks.append(raw_case(directory, row['execution'], row['kind'], 7, 19))
    return checks


def review(root, mode):
    root = Path(root).resolve()
    require(mode in ('full', 'cold', 'offline'), 'Unknown review mode')
    requested_mode = mode
    if mode == 'cold':
        mode = 'full'  # Historical coverage-selector alias; not proof of empty caches.
    checks, exits = [], {}
    if mode == 'full':
        exits['matrix.exit'] = checked_exit(root, 'matrix.exit')
        checks.extend(matrix(root / 'matrix-results'))
    prefix = 'offline-' if mode == 'offline' else ''
    for name in ('async', 'snapshot'):
        exits[prefix + name + '.exit'] = checked_exit(root, prefix + name + '.exit')
    asynchronous = load(root / 'async-results/async-report.json')
    require(asynchronous['source_callbacks'] == 2 and asynchronous['pipeline_callbacks'] == 1,
            'Wrong asynchronous callback counts')
    require(not any(asynchronous[key] for key in ('library_alive_after_callback',
                'function_alive_after_callback', 'dynamic_alive_after_callback', 'supports_render_dynamic')),
            'Unexpected retained weak reference or render capability')
    checks.append(raw_case(root / 'async-results', asynchronous['execution'], 'async', 7, 19))
    snapshot = load(root / 'snapshot-results/snapshot-report.json')
    require(snapshot['same_consumer_function_object'] and snapshot['same_install_name']
            and not snapshot['first_dynamic_alive'] and not snapshot['second_dynamic_alive'],
            'Dependency snapshot/lifetime contract changed')
    additions = {'old_object': 19, 'new_object_same_install_name': 23,
                 'old_pipeline_after_new_dependency': 19}
    rows = snapshot['cases']
    require(len(rows) == 3 and {x['case'] for x in rows} == set(additions), 'Missing/duplicate snapshot case')
    for row in rows:
        name = row['case']
        require(row['expected_add'] == additions[name], 'Producer expectation differs from authored fixture')
        checks.append(raw_case(root / 'snapshot-results', row['execution'], name, 7, additions[name]))
    require(sum(x['values'] for x in checks) == (1024 if mode == 'offline' else 2816), 'Wrong total coverage')
    sources = ['alpha.metal', 'beta.metal', 'dynamic-source.metal', 'dynamic-consumer.metal',
               'path_runner.m', 'async_lifetime.m', 'dependency_snapshot.m']
    return {'schema': 1, 'status': 'passed', 'mode': mode, 'requested_mode': requested_mode,
            'cache_state': 'Not determined: full matrix coverage does not prove an empty cache.',
            'values': sum(x['values'] for x in checks), 'checks': checks, 'exit_file_sha256': exits,
            'authored_control_sources': {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
                                        for name in sources},
            'scope': 'Raw authored uint32 formulas, producer callback/lifetime reports and recorded executable exits. Does not independently prove transport authentication, absence of relays, compiler shutdown or every dynamic shader contract.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--mode', choices=('full', 'offline', 'cold'), default='full',
                        help='full matrix or offline subset; cold is a legacy alias for full, not cache-state evidence')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = review(args.results, args.mode)
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(f"{result['values']} raw uint32 values passed ({result['mode']})")


if __name__ == '__main__':
    main()
