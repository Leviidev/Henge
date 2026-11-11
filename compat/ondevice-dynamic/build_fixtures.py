#!/usr/bin/env python3
"""Build three authored closure profiles using build-machine Metal tools only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1] / 'dynamic-libraries/controls'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    commands = []

    def run(command):
        subprocess.run(command, check=True)
        commands.append(command)

    for name in ['dynamic-source', 'dynamic-consumer']:
        run(['xcrun', '--sdk', 'macosx', 'metal', '-c', str(ROOT / (name + '.metal')),
             '-target', 'air64_v26-apple-macosx14.0.0', '-o', str(out / (name + '.air'))])
    linker = ['xcrun', '--sdk', 'macosx', 'air-lld', '--arch', 'air64', '--macos_version_min', '14.0']
    for kind, install in [('loader', '@loader_path/dynamic-loader.metallib'),
                          ('absolute', '/HengeControls/helper.metallib'),
                          ('control', '@executable_path/AuditAssets/dynamic-control.metallib')]:
        library = out / ('dynamic-' + kind + '.metallib')
        run([*linker, '--create-shared-library', '--install_name', install,
             str(out / 'dynamic-source.air'), '-o', str(library)])
        if kind != 'control':
            run([*linker, str(out / 'dynamic-consumer.air'), str(library),
                 '-o', str(out / ('consumer-' + kind + '.metallib'))])
    run([*linker, '--undefined', 'suppress', str(out / 'dynamic-consumer.air'),
         '-o', str(out / 'consumer-preloaded.metallib')])
    report = {'scope': 'newly authored source; generated libraries are local build outputs',
              'sources': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                          for name in ['dynamic-source.metal', 'dynamic-consumer.metal']},
              'libraries': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in out.glob('*.metallib')}, 'commands': commands}
    (out / 'fixture-build.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
