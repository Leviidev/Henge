#!/usr/bin/env python3
"""Run authored GPU controls and pre-GPU semantic rejection controls."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    fixtures = args.fixtures.resolve()
    # Coherent structure/AIR hashes, but a deliberately different declared
    # dependency export. It must be rejected before producing a GPU library.
    mismatch = out / 'export-mismatch-input'
    mismatch.mkdir()
    shutil.copy2(fixtures / 'consumer-loader.metallib', mismatch / 'consumer-loader.metallib')
    dependency_bytes = (fixtures / 'dynamic-loader.metallib').read_bytes()
    needle = b'NAME\x14\x00inventory_transform\x00'
    if dependency_bytes.count(needle) != 1:
        raise ValueError('Authored export record shape changed')
    (mismatch / 'dynamic-loader.metallib').write_bytes(
        dependency_bytes.replace(needle, b'NAME\x14\x00_nventory_transform\x00', 1))
    cases = [
        ('loader', 'consumer-loader.metallib', 'dynamic-loader.metallib', [], None),
        ('absolute', 'consumer-absolute.metallib', 'dynamic-absolute.metallib', ['0', 'source'], None),
        ('preloaded', 'consumer-preloaded.metallib', 'dynamic-control.metallib', ['2', 'source'], None),
        ('loader-source-no-origin', 'consumer-loader.metallib', 'dynamic-loader.metallib',
         ['2', 'source'], 'loader path needs consumer origin'),
        ('missing-loader', 'consumer-loader.metallib', 'dynamic-absolute.metallib', [],
         'missing declared loader dependency'),
        ('missing-preloaded', 'consumer-preloaded.metallib', 'dynamic-control.metallib',
         ['0', 'source'], 'unresolved'),
        ('export-mismatch', str(mismatch / 'consumer-loader.metallib'),
         str(mismatch / 'dynamic-loader.metallib'), [], 'AIR definition missing from container exports'),
    ]
    results = []
    for name, consumer, dependency, extra, rejected in cases:
        run = out / name
        command = [str(args.control.resolve()), str(fixtures / consumer),
                   str(fixtures / dependency), str(run), *extra]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (out / (name + '.stdout')).write_text(result.stdout)
        (out / (name + '.stderr')).write_text(result.stderr)
        if rejected:
            passed = result.returncode == 1 and rejected in result.stderr and not (run / 'closed.metallib').exists()
            record = {'case': name, 'passed': passed, 'expected_rejection': rejected,
                      'exit': result.returncode, 'no_gpu_library_published': not (run / 'closed.metallib').exists()}
        else:
            report_path = run / 'report.json'
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            passed = (result.returncode == 0 and report.get('mismatches') == 0 and
                      report.get('expected_values') == 256 and report.get('command_status') == 4)
            record = {'case': name, 'passed': passed, 'report': report}
        results.append(record)
    report = {'schema': 1, 'passed': all(row['passed'] for row in results), 'cases': results,
              'expected_exact_values': 768, 'scope': 'native Metal controls; no iPad/guest integration claim'}
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
