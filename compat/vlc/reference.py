"""Acquire the pinned official reference read-only; no app installation/launch."""
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def verify_app(app, lock):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != lock['bundle_identifier'] or
            info.get('CFBundleShortVersionString') != lock['version'] or
            sha(app / 'Contents/MacOS/lib/libvlccore.dylib') != lock['core_sha256']):
        raise ValueError('Pinned VLC app identity mismatch')
    architecture = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/VLC')], text=True).strip()
    if architecture != lock['architecture']:
        raise ValueError('Pinned VLC architecture mismatch')
    requirement = ('=anchor apple generic and identifier "' + lock['bundle_identifier'] +
                   '" and certificate leaf[subject.OU] = "' + lock['team_identifier'] + '"')
    subprocess.run(['codesign', '--verify', '--strict', '-R', requirement, str(app)], check=True)


def obtain(cache, fetch):
    lock = json.loads((HERE / 'reference.lock.json').read_text())
    cache = cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    # Cooperating builds must not race an incomplete app copy or image download.
    with (cache / '.reference.lock').open('a') as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        folder = cache / ('reference-' + lock['sha256'])
        app = folder / 'VLC.app'
        if app.exists():
            verify_app(app, lock)
            return app
        image = cache / lock['filename']
        if not image.exists():
            if not fetch:
                raise ValueError('Pinned VLC reference missing; use --fetch for automatic acquisition')
            with tempfile.NamedTemporaryFile(dir=cache, prefix='.reference-download-', delete=False) as output:
                partial = Path(output.name)
                try:
                    with urllib.request.urlopen(lock['url'], timeout=60) as response:
                        received = 0
                        while block := response.read(1024 * 1024):
                            received += len(block)
                            if received > lock['bytes']:
                                raise ValueError('Oversized VLC reference download')
                            output.write(block)
                    output.flush()
                    if received != lock['bytes'] or sha(partial) != lock['sha256']:
                        raise ValueError('VLC reference download checksum/length mismatch')
                    partial.rename(image)
                finally:
                    partial.unlink(missing_ok=True)
        if image.stat().st_size != lock['bytes'] or sha(image) != lock['sha256']:
            raise ValueError('Cached VLC reference checksum/length mismatch')
        stage = Path(tempfile.mkdtemp(dir=cache, prefix='.reference-stage-'))
        mount = stage / 'mount'
        try:
            mount.mkdir()
            attached = False
            try:
                result = subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist',
                                         '-mountpoint', str(mount), str(image)],
                                        capture_output=True, check=True, timeout=120)
                attached = True
                info = plistlib.loads(result.stdout)
                if not any(entity.get('mount-point') and Path(entity['mount-point']).resolve() == mount
                           for entity in info.get('system-entities', [])):
                    raise ValueError('VLC image did not mount at its private mountpoint')
                verify_app(mount / 'VLC.app', lock)
                prepared = stage / 'prepared'
                prepared.mkdir()
                subprocess.run(['ditto', str(mount / 'VLC.app'), str(prepared / 'VLC.app')], check=True)
                verify_app(prepared / 'VLC.app', lock)
                (prepared / 'reference-receipt.json').write_text(json.dumps(lock, indent=2) + '\n')
            finally:
                # Also handle a failed/expired attachment that nevertheless mounted.
                if attached or mount.is_mount():
                    subprocess.run(['hdiutil', 'detach', str(mount)], check=True, timeout=60)
            prepared.rename(folder)
        finally:
            # Never recurse into a still-mounted filesystem after detach fails.
            # Retain that private staging directory for diagnosis instead.
            if not mount.is_mount():
                shutil.rmtree(stage)
        return app
