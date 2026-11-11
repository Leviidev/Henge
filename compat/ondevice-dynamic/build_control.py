#!/usr/bin/env python3
"""Build authored native closure controls against an existing pinned provider build."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider-build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--provider-archive', type=Path,
                        help='Qualify the actual combined provider archive instead of compiling another linker')
    args = parser.parse_args()
    build = args.provider_build.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    config = str(build / 'llvm-native/bin/llvm-config')
    flags = shlex.split(subprocess.check_output([
        config, '--ldflags',
        '--libs', 'linker', 'bitreader', 'bitwriter140', 'bitwriter',
        'transformutils', 'core', '--system-libs'], text=True))
    compile_flags = shlex.split(subprocess.check_output([config, '--cxxflags'], text=True))
    common = ['xcrun', '--sdk', 'macosx', 'clang++', *compile_flags, '-std=c++20',
              '-I' + str(ROOT.parent / 'ondevice-shaders'),
              '-DHENGE_AIR_EMBEDDED=1', '-fexceptions', '-frtti', '-O2']
    commands = [
        [*common, str(ROOT / 'stateless_link.cpp'), '-c', '-o', str(args.output / 'closure.o')],
        [*common, str(ROOT / 'native_control.mm'), str(args.output / 'closure.o'), *flags,
         '-fobjc-arc', '-framework', 'Foundation', '-framework', 'Metal',
         '-o', str(args.output / 'native-control')],
    ]
    if args.provider_archive:
        commands = [[*common, str(ROOT / 'native_control.mm'),
                     str(args.provider_archive.resolve()), '-fobjc-arc',
                     '-framework', 'Foundation', '-framework', 'Metal',
                     '-o', str(args.output / 'native-control')]]
    for command in commands:
        subprocess.run(command, check=True)
    (args.output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')


if __name__ == '__main__':
    main()
