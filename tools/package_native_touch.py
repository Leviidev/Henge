#!/usr/bin/env python3
"""Bundle the guest helper without claiming unauthorized restricted entitlements."""
import argparse
import datetime
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

HID = 'com.apple.developer.hid.virtual.device'
APP_ID = 'com.apple.application-identifier'
TEAM_ID = 'com.apple.developer.team-identifier'


def profile_entitlements(profile, bundle_id, development=False):
    if 'OSX' not in profile.get('Platform', []):
        raise ValueError('A macOS provisioning profile is required')
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime.datetime) or expires <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError('The provisioning profile is expired or has no expiry')
    if profile.get('ProvisionsAllDevices') is not True:
        if not development:
            raise ValueError('Release helpers require a Developer ID profile valid on all devices; use --development only for registered test Macs')
        if not profile.get('ProvisionedDevices'):
            raise ValueError('The development profile lists no registered Macs')
    allowed = profile.get('Entitlements', {})
    teams = profile.get('TeamIdentifier', [])
    if len(teams) != 1 or allowed.get(TEAM_ID) != teams[0]:
        raise ValueError('The profile team identifiers do not match')
    app_id = allowed.get(APP_ID)
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    if not prefixes or not any(app_id == f'{prefix}.{bundle_id}' for prefix in prefixes) or '*' in bundle_id:
        raise ValueError(f'The profile must authorize the exact bundle ID {bundle_id}')
    if allowed.get(HID) is not True:
        raise ValueError(f'The profile does not authorize {HID}')
    if not profile.get('DeveloperCertificates'):
        raise ValueError('The profile contains no signing certificates')
    return {APP_ID: app_id, TEAM_ID: teams[0], HID: True}


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def package(args):
    if bool(args.profile) != bool(args.identity):
        raise ValueError('--profile and --identity must be supplied together')
    if args.identity == '-':
        raise ValueError('A provisioning profile requires an Apple signing identity, not ad-hoc signing')
    if args.development and not args.profile:
        raise ValueError('--development requires a provisioning profile')
    profile = None
    entitlements = None
    if args.profile:
        profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(args.profile)))
        entitlements = profile_entitlements(profile, args.bundle_id, args.development)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='henge-touch-package-', dir=args.output.parent) as temporary:
        root = Path(temporary)
        app = root / 'Henge Touch Agent.app'
        contents = app / 'Contents'
        executable = contents / 'MacOS' / 'henge-touch-agent'
        executable.parent.mkdir(parents=True)
        shutil.copy2(args.binary, executable)
        executable.chmod(0o755)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': args.bundle_id,
            'CFBundleExecutable': executable.name,
            'CFBundleName': 'Henge Touch Agent',
            'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.0',
            'LSMinimumSystemVersion': '15.0',
            'LSUIElement': True,
            'NSHumanReadableCopyright': 'Henge contributors',
        }))
        command = ['codesign', '--force', '--sign', args.identity or '-', '--identifier', args.bundle_id]
        if profile:
            shutil.copy2(args.profile, contents / 'embedded.provisionprofile')
            entitlement_path = root / 'entitlements.plist'
            entitlement_path.write_bytes(plistlib.dumps(entitlements))
            command += ['--entitlements', str(entitlement_path), '--options', 'runtime']
            if not args.development:
                command += ['--timestamp']
        else:
            # Explicitly strip any inherited restricted claim from the input binary.
            entitlement_path = root / 'entitlements.plist'
            entitlement_path.write_bytes(plistlib.dumps({}))
            command += ['--entitlements', str(entitlement_path)]
        run(*command, str(app))
        run('codesign', '--verify', '--strict', str(app))
        claimed = plistlib.loads(run('codesign', '-d', '--entitlements', '-', '--xml', str(app)))
        if claimed != (entitlements or {}):
            raise ValueError('The signed helper does not have the expected entitlements')
        if profile:
            prefix = root / 'certificate'
            run('codesign', '-d', f'--extract-certificates={prefix}', str(app))
            if prefix.with_name(prefix.name + '0').read_bytes() not in profile['DeveloperCertificates']:
                raise ValueError('The signing certificate is not authorized by the profile')
        # Compressed bundles survive IPA signing tools without guest re-signing.
        sharing_app = None
        if args.sharing_binary:
            sharing_app = root / 'Henge Sharing Agent.app'
            sharing_contents = sharing_app / 'Contents'
            sharing_executable = sharing_contents / 'MacOS' / 'henge-agent'
            sharing_executable.parent.mkdir(parents=True)
            shutil.copy2(args.sharing_binary, sharing_executable)
            sharing_executable.chmod(0o755)
            (sharing_contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'dev.henge.sharing-agent',
                'CFBundleExecutable': sharing_executable.name,
                'CFBundleName': 'Henge Sharing Agent',
                'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1',
                'LSMinimumSystemVersion': '12.0',
                'LSUIElement': True,
                'NSLocalNetworkUsageDescription': 'Connect to Henge on your device for the shared folder, clipboard and touch input.',
            }))
            empty_entitlements = root / 'sharing-entitlements.plist'
            empty_entitlements.write_bytes(plistlib.dumps({}))
            run('codesign', '--force', '--sign', '-', '--entitlements', str(empty_entitlements), str(sharing_app))
            run('codesign', '--verify', '--strict', str(sharing_app))
            sharing_claims = plistlib.loads(run('codesign', '-d', '--entitlements', '-', '--xml', str(sharing_app)))
            if sharing_claims:
                raise ValueError('The sharing helper must not claim restricted entitlements')
        archive = root / 'helper.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(app, arcname=app.name)
            if sharing_app:
                tar.add(sharing_app, arcname=sharing_app.name)
        os.replace(archive, args.output)
    mode = 'registered test Macs only' if args.development else 'all devices' if profile else 'USB touch; no virtual HID entitlement'
    print(f'{args.output}: {mode}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--sharing-binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle-id', default=os.getenv('HENGE_TOUCH_BUNDLE_ID', 'dev.henge.touch-agent'))
    parser.add_argument('--profile', type=Path, default=os.getenv('HENGE_TOUCH_PROFILE'))
    parser.add_argument('--identity', default=os.getenv('HENGE_TOUCH_IDENTITY'))
    parser.add_argument('--development', action='store_true', default=os.getenv('HENGE_TOUCH_DEVELOPMENT') == '1')
    args = parser.parse_args()
    try:
        package(args)
    except (ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors='replace') if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        parser.exit(1, f'Native touch packaging failed: {detail}\n')


if __name__ == '__main__':
    main()
