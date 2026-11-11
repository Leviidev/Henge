#!/usr/bin/env python3
"""Build the real private HTTP service and a native-only guest adapter control."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider-archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    common = ['xcrun', '--sdk', 'macosx', 'clang', '-arch', 'arm64',
              '-mmacosx-version-min=14.0']
    commands = [
        [*common, '-std=c11', '-I' + str(ROOT.parents[1] / 'host'), '-c',
         str(ROOT.parents[1] / 'host/share.c'), '-o', str(out / 'share.o')],
        ['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-fobjc-arc',
         str(ROOT / 'service_control.mm'), str(out / 'share.o'),
         str(args.provider_archive.resolve()), '-framework', 'Foundation',
         '-framework', 'Metal', '-o', str(out / 'service-control')],
        [*common, '-fobjc-arc', '-fblocks', '-dynamiclib', '-DHG_ALLOW_NATIVE_TESTING=1',
         str(ROOT.parent / 'dynamic-libraries/guest/runtime.m'),
         '-framework', 'Foundation', '-framework', 'Metal', '-o', str(out / 'guest.dylib')],
        [*common, '-fobjc-arc', str(ROOT / 'guest_control.m'), '-framework', 'Foundation',
         '-framework', 'Metal', '-o', str(out / 'guest-control')],
    ]
    for command in commands:
        subprocess.run(command, check=True)
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')


if __name__ == '__main__':
    main()
