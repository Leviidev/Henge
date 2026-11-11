#!/usr/bin/env python3
"""Build the passive, source-only Sonoma payload. Never install or activate it."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile

from check_ondevice_provider import verify as verify_provider

ROOT = Path(__file__).resolve().parents[2]
LIBRARIES = ('libHengeDynamic.dylib', 'libHengeCGLDiscovery.dylib')
VLC_PLUGINS = ('libaacdecgap_plugin.dylib', 'libaacgap_plugin.dylib',
               'libaacpacketgap_plugin.dylib', 'libavgap_plugin.dylib',
               'libmacosx_plugin.dylib', 'libmux_mp4_plugin.dylib',
               'libsamplerate_plugin.dylib', 'libstream_out_transcode_plugin.dylib',
               'libx265_plugin.dylib')
EXECUTABLES = (*LIBRARIES, *VLC_PLUGINS)
VLC_LICENSES = {
    'LICENSE-VLC-GPL-2.0.txt': 'sources/vlc-3.0.24/COPYING',
    'LICENSE-VLC-LGPL-2.1.txt': 'sources/vlc-3.0.24/COPYING.LIB',
    'LICENSE-FFmpeg-LGPL-2.1.txt': 'sources/ffmpeg-8.1.2/COPYING.LGPLv2.1',
    'LICENSE-x265-GPL-2.0.txt': 'sources/x265_4.1/COPYING',
    'LICENSE-libsamplerate-BSD.txt': 'sources/libsamplerate-0.1.9/COPYING',
}
FILES = (*EXECUTABLES, 'LICENSE-Henge-GPL-2.0.txt', *VLC_LICENSES,
         'vlc-build-receipt.json')
SOURCES = ('compat/dynamic-libraries/guest/runtime.m',
           'compat/dynamic-libraries/guest/adapter.m',
           'compat/dynamic-libraries/guest/transport.m',
           'compat/opengl-discovery/registry_discovery.m', 'LICENSE',
           'tools/compat/build_guest_payload.py')
SOURCES += ('tools/compat/guest_library_load_control.c', 'compat/vlc/candidate.py',
            'compat/vlc/promote.py', 'tools/compat/ipad_update.py')
SOURCES += tuple('compat/vlc/' + name for name in (
    'build.py', 'reference.py', 'reference.lock.json', 'inputs.lock.json',
    'source-provenance.json', 'COPYING', 'COPYING.LIB'))
SOURCES += tuple(str(path.relative_to(ROOT)) for directory in ('patches', 'support')
                 for path in sorted((ROOT / 'compat/vlc' / directory).iterdir()) if path.is_file())


def vlc_target(root=ROOT):
    lock = json.loads((root / 'compat/vlc/reference.lock.json').read_text())
    return dict(version=lock['version'], bundle_identifier=lock['bundle_identifier'],
                reference_core_sha256=lock['core_sha256'],
                reference_lock_sha256=digest(root / 'compat/vlc/reference.lock.json'),
                plugins=list(VLC_PLUGINS), installation='unimplemented')


def digest(path):
    with path.open('rb') as stream:
        result = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
        return result.hexdigest()


def identity(manifest):
    body = {key: value for key, value in manifest.items() if key != 'payload_id'}
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def archive_payload(folder, target):
    """Stable flat tar/gzip, keeping guest code opaque to iOS package signers."""
    with target.open('xb') as stream, gzip.GzipFile(filename='', fileobj=stream, mode='wb', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for name in sorted((*FILES, 'manifest.json')):
                path = folder / name
                data = path.read_bytes()
                item = tarfile.TarInfo(name)
                item.size = len(data)
                item.mode = stat.S_IMODE(path.stat().st_mode)
                item.uid = item.gid = item.mtime = 0
                archive.addfile(item, io.BytesIO(data))


def verify_payload(folder, expected_recipe, root=ROOT):
    """Check bundle integrity before embedding, not authenticity of external input.

    The release app signature is the trust anchor for the embedded manifest.
    A self-consistent manifest alone never authorizes installing outside files.
    """
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError('Payload must be a real directory')
    names = set(FILES) | {'manifest.json'}
    if {p.name for p in folder.iterdir()} != names:
        raise ValueError('Unexpected or missing payload files')
    for name in names:
        item = folder / name
        info = item.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024:
            raise ValueError('Payload member must be a bounded regular file: ' + name)
    manifest = json.loads((folder / 'manifest.json').read_text())
    if ((folder / 'manifest.json').stat().st_size > 65536 or
            stat.S_IMODE((folder / 'manifest.json').stat().st_mode) != 0o644):
        raise ValueError('Invalid payload manifest size or mode')
    if set(manifest) != {'schema', 'kind', 'architecture', 'minimum_macos',
                         'compiler_recipe', 'sources', 'files', 'activation', 'payload_id', 'vlc'}:
        raise ValueError('Unsupported payload manifest fields')
    if (manifest['schema'] != 1 or manifest['kind'] != 'henge-sonoma-guest-compatibility' or
            manifest['architecture'] != 'arm64' or manifest['minimum_macos'] != '14.0' or
            manifest['compiler_recipe'] != expected_recipe or
            manifest['activation'] != 'unimplemented' or manifest['payload_id'] != identity(manifest)):
        raise ValueError('Payload identity, target or compiler recipe mismatch')
    if set(manifest['files']) != set(FILES):
        raise ValueError('Payload inventory mismatch')
    if manifest['vlc'] != vlc_target(root):
        raise ValueError('VLC compatibility unit or target ABI mismatch')
    if (set(manifest['sources']) != set(SOURCES) or
            not all(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value)
                    for value in manifest['sources'].values())):
        raise ValueError('Payload source inventory mismatch')
    for name in FILES:
        record = manifest['files'][name]
        path = folder / name
        if (set(record) != {'sha256', 'bytes', 'mode'} or
                record['sha256'] != digest(path) or record['bytes'] != path.stat().st_size or
                record['mode'] != (0o755 if name in EXECUTABLES else 0o644) or
                stat.S_IMODE(path.stat().st_mode) != record['mode']):
            raise ValueError('Payload member identity mismatch: ' + name)
    return manifest


def build(root, output, vlc_archives=None):
    recipe = verify_provider(root)
    if (root / 'tools/compat/build_guest_payload.py').read_bytes() != Path(__file__).read_bytes():
        raise ValueError('Payload builder differs from the selected source root')
    source_snapshot = {name: digest(root / name) for name in SOURCES}
    output.mkdir(parents=True, exist_ok=False)
    payload = output / 'payload'
    payload.mkdir()
    compiler = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--find', 'clang'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    guest = root / 'compat/dynamic-libraries/guest'
    discovery = root / 'compat/opengl-discovery/registry_discovery.m'
    commands = []
    for name, source, frameworks in (
            (LIBRARIES[0], guest / 'runtime.m', ('Foundation', 'Metal')),
            (LIBRARIES[1], discovery, ('Foundation', 'IOKit'))):
        target = payload / name
        command = [compiler, '-isysroot', sdk, '-arch', 'arm64', '-mmacosx-version-min=14.0',
                   '-dynamiclib', '-O2', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
                   '-Wno-deprecated-declarations', '-ffile-prefix-map=' + str(root) + '=.',
                   '-Wl,-reproducible', '-DHG_RECIPE_ID="' + recipe + '"',
                   '-install_name', '@rpath/' + name, str(source), '-o', str(target)]
        command += [value for framework in frameworks for value in ('-framework', framework)]
        commands.append(command)
        subprocess.run(command, check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(target)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
        if subprocess.check_output(['lipo', '-archs', str(target)], text=True).strip() != 'arm64':
            raise ValueError('Unexpected payload architecture')
        if b'HENGE_EMBEDDED_TEST_ENDPOINT' in target.read_bytes():
            raise ValueError('Native-only transport override leaked into production payload')
        target.chmod(0o755)
    license_file = payload / 'LICENSE-Henge-GPL-2.0.txt'
    license_file.write_bytes((root / 'LICENSE').read_bytes())
    license_file.chmod(0o644)
    loader = output / 'library-load-control'
    subprocess.run([compiler, '-arch', 'arm64', '-mmacosx-version-min=14.0', '-Wall',
                    '-Wextra', '-Werror', str(root / 'tools/compat/guest_library_load_control.c'),
                    '-o', str(loader)], check=True)
    subprocess.run([str(loader), *(str(payload / name) for name in LIBRARIES)], check=True)
    vlc_build = output / 'vlc-build'
    if vlc_archives is None:
        vlc_archives = root / '.compat-local/vlc-archives'
    subprocess.run([sys.executable, str(root / 'compat/vlc/build.py'),
                    '--archives', str(vlc_archives.resolve()), '--output', str(vlc_build),
                    '--fetch'], check=True)
    vlc_receipt = json.loads((vlc_build / 'build-receipt.json').read_text())
    target_abi = vlc_target(root)
    if (vlc_receipt['state'] != 'built; not installed' or
            vlc_receipt['reference_core_sha256'] != target_abi['reference_core_sha256'] or
            set(vlc_receipt['plugins']) != set(VLC_PLUGINS) or
            vlc_receipt['reference_provenance'] != dict(mode='pinned-automatic',
                lock_sha256=target_abi['reference_lock_sha256'], official_signature_verified=True)):
        raise ValueError('Incomplete or mismatched VLC source build')
    for name in VLC_PLUGINS:
        source = vlc_build / 'plugins' / name
        if digest(source) != vlc_receipt['plugins'][name]:
            raise ValueError('VLC build output differs from its receipt: ' + name)
        target = payload / name
        target.write_bytes(source.read_bytes())
        target.chmod(0o755)
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(target)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
        if subprocess.check_output(['lipo', '-archs', str(target)], text=True).strip() != 'arm64':
            raise ValueError('Unexpected VLC plugin architecture')
        exported = subprocess.check_output(['nm', '-gU', str(target)], text=True)
        if '_vlc_entry__3_0_0f' not in exported.split():
            raise ValueError('Missing VLC 3.0 plugin entry point: ' + name)
    for name, source in VLC_LICENSES.items():
        target = payload / name
        target.write_bytes((vlc_build / source).read_bytes())
        target.chmod(0o644)
    (payload / 'vlc-build-receipt.json').write_bytes((vlc_build / 'build-receipt.json').read_bytes())
    (payload / 'vlc-build-receipt.json').chmod(0o644)
    # Sign and inspect a separate candidate using VLC's own loader. The source
    # reference remains untouched; no GUI, playback or installed app is started.
    candidate = output / 'vlc-load-control'
    reference_app = vlc_archives.resolve() / ('reference-' + json.loads(
        (root / 'compat/vlc/reference.lock.json').read_text())['sha256']) / 'VLC.app'
    subprocess.run([sys.executable, str(root / 'compat/vlc/candidate.py'),
                    '--source-app', str(reference_app), '--build', str(vlc_build),
                    '--output', str(candidate)], check=True)
    env = dict(os.environ)
    for name in ('DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH', 'VLC_PLUGIN_PATH'):
        env.pop(name, None)
    result = subprocess.run([str(candidate / 'VLC Export Test.app/Contents/MacOS/VLC'),
                             '--ignore-config', '--no-plugins-cache', '--list'],
                            env=env, capture_output=True, timeout=45)
    (output / 'vlc-load-control.log').write_bytes(result.stdout + result.stderr)
    result.check_returncode()
    listed = {line.strip().split()[0] for line in result.stdout.decode().splitlines() if line.strip()}
    required_modules = {name.removeprefix('lib').removesuffix('_plugin.dylib') for name in VLC_PLUGINS}
    if not required_modules <= listed or b'cannot load module' in result.stderr:
        raise ValueError('VLC could not load the complete plugin unit; see vlc-load-control.log')
    if {name: digest(root / name) for name in SOURCES} != source_snapshot:
        raise ValueError('Guest payload source changed during the build')
    manifest = dict(schema=1, kind='henge-sonoma-guest-compatibility', architecture='arm64',
                    minimum_macos='14.0', compiler_recipe=recipe, activation='unimplemented', vlc=target_abi,
                    sources=source_snapshot,
                    files={name: dict(sha256=digest(payload / name), bytes=(payload / name).stat().st_size,
                                      mode=stat.S_IMODE((payload / name).stat().st_mode)) for name in FILES})
    manifest['payload_id'] = identity(manifest)
    (payload / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    (payload / 'manifest.json').chmod(0o644)
    verify_payload(payload, recipe, root)
    archive = output / 'henge-guest-payload.tar.gz'
    archive_payload(payload, archive)
    descriptor = dict(schema=1, payload_id=manifest['payload_id'], compiler_recipe=recipe,
                      archive_sha256=digest(archive), archive_bytes=archive.stat().st_size,
                      manifest_sha256=digest(payload / 'manifest.json'), activation='unimplemented')
    (output / 'henge-guest-payload.json').write_text(json.dumps(descriptor, indent=2) + '\n')
    receipt = dict(schema=1, payload_id=manifest['payload_id'], compiler_sha256=digest(Path(compiler)),
                   xcode=subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                   commands=commands, source_head=subprocess.check_output(
                       ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
                   installed=False, activation_implemented=False)
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vlc-archives', type=Path,
                        help='Build-time download cache; default .compat-local/vlc-archives')
    args = parser.parse_args()
    print(build(args.root.resolve(), args.output.resolve(), args.vlc_archives)['payload_id'])


if __name__ == '__main__':
    main()
