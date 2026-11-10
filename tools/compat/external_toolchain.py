#!/usr/bin/env python3
"""Record exact external tool/SDK provenance, without changing runtime recipes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(*command):
    return subprocess.check_output(command, text=True).strip()


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--llvm-config', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit('Output must be new')
    tools = {}
    for name in ('clang', 'clang++', 'ld', 'metal', 'metallib', 'air-lld'):
        path = Path(run('xcrun', '--sdk', 'macosx', '--find', name)).resolve()
        tools[name] = {'sha256': sha(path), 'bytes': path.stat().st_size}
    for name in ('cmake', 'make', 'python3', 'xcodegen', 'ffmpeg', 'ffprobe'):
        found = shutil.which(name)
        if found:
            path = Path(found).resolve()
            tools[name] = {'sha256': sha(path), 'bytes': path.stat().st_size}
    llvm = None
    if args.llvm_config:
        config = args.llvm_config.resolve()
        bindir = Path(run(str(config), '--bindir'))
        libdir = Path(run(str(config), '--libdir'))
        llvm_tools = {}
        for name in ('llvm-config', 'llvm-dis', 'llvm-as', 'opt', 'clang'):
            path = (bindir / name).resolve()
            if path.is_file():
                llvm_tools[name] = {'sha256': sha(path), 'bytes': path.stat().st_size}
        libraries = {}
        for path in sorted(libdir.glob('libLLVM*.dylib')):
            libraries[path.name] = {'sha256': sha(path.resolve()), 'bytes': path.stat().st_size}
        llvm = {'version': run(str(config), '--version'),
                'shared_mode': run(str(config), '--shared-mode'),
                'tools': llvm_tools, 'libraries': libraries}
    result = {
        'schema': 1, 'xcode': run('xcodebuild', '-version'),
        'host_os': run('sw_vers', '-productVersion'),
        'host_os_build': run('sw_vers', '-buildVersion'),
        'sdks': {sdk: {'version': run('xcrun', '--sdk', sdk, '--show-sdk-version'),
                       'build': run('xcrun', '--sdk', sdk, '--show-sdk-build-version')}
                 for sdk in ('macosx', 'iphoneos')},
        'tools': tools, 'llvm': llvm,
        'scope': 'Build provenance only. Does not alter or strengthen an existing runtime cache recipe. Tool names are roles; machine-specific mount paths are excluded.'
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
