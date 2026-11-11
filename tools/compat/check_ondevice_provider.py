#!/usr/bin/env python3
"""Reject absent, stale or mismatched build inputs before packaging Henge."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECEIPT = 'libHGOnDeviceShader.build.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(root):
    source = root / 'compat/ondevice-shaders'
    library = root / 'ios/deps/lib/libHGOnDeviceShader.a'
    receipt = json.loads((library.parent / RECEIPT).read_text())
    expected = {p.name: digest(p) for p in source.iterdir() if p.is_file()
                and p.name not in ('README.md', '.gitignore')}
    for name in ('stateless_link.cpp', 'HGStatelessLink.h'):
        expected['dynamic/' + name] = digest(root / 'compat/ondevice-dynamic' / name)
    for name in ('adapter.m', 'transport.m', 'runtime.m'):
        expected['guest/' + name] = digest(root / 'compat/dynamic-libraries/guest' / name)
    if receipt['source_package'] != expected:
        raise ValueError('On-device compiler source changed; rebuild the provider')
    if digest(library) != receipt['archive_sha256']:
        raise ValueError('On-device compiler archive differs from its build receipt')
    compiler = receipt['compiler_recipe']
    encoded = json.dumps(compiler['manifest'], sort_keys=True,
                         separators=(',', ':')).encode()
    if hashlib.sha256(encoded).hexdigest() != compiler['recipe']:
        raise ValueError('On-device compiler recipe identity is invalid')
    for name in ('HGOnDeviceShaderProvider.h', 'pvg_shader_profile.h', 'HGOnDeviceDynamicService.h'):
        if (source / name).read_bytes() != (root / 'devices' / name).read_bytes():
            raise ValueError('On-device compiler API contract differs: ' + name)
    if (source / 'LICENSE-LLVM.txt').read_bytes() != (
            root / 'ios/Henge/Resources/legal/LICENSE-LLVM.txt').read_bytes():
        raise ValueError('Bundled LLVM license differs from the provider source')
    return compiler['recipe']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        print('Verified on-device shader provider recipe ' + verify(args.root))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + '\nRebuild with tools/compat/build_ondevice_provider.py.\n')


if __name__ == '__main__':
    main()
