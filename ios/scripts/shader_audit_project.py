#!/usr/bin/env python3
"""Generate an unsigned audit app project from source; never needs a saved device project."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess


def create_project(output, runner, bundle_identifier='org.henge.shaderaudit'):
    output = Path(output).resolve()
    runner = Path(runner).resolve()
    if not runner.is_file() or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_identifier):
        raise ValueError('existing runner and reverse-DNS bundle identifier required')
    output.mkdir(parents=True, exist_ok=True)
    info = dict(CFBundleDevelopmentRegion='$(DEVELOPMENT_LANGUAGE)',
                CFBundleDisplayName='Henge Shader Audit', CFBundleExecutable='$(EXECUTABLE_NAME)',
                CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleInfoDictionaryVersion='6.0',
                CFBundleName='$(PRODUCT_NAME)', CFBundlePackageType='APPL',
                CFBundleShortVersionString='1.0', CFBundleVersion='1', UIFileSharingEnabled=True,
                UILaunchScreen={}, UIRequiresFullScreen=True,
                UISupportedInterfaceOrientations=['UIInterfaceOrientationLandscapeLeft',
                                                  'UIInterfaceOrientationLandscapeRight'])
    (output/'Info.plist').write_bytes(plistlib.dumps(info))
    spec = dict(name='HengeShaderAudit', options=dict(deploymentTarget=dict(iOS='17.0')),
                settings=dict(base=dict(CLANG_ENABLE_OBJC_ARC=True, CODE_SIGNING_ALLOWED=False)),
                targets=dict(HengeShaderAudit=dict(type='application', platform='iOS',
                    sources=[dict(path=str(runner)), dict(path='AuditAssets', buildPhase='resources')],
                    settings=dict(base=dict(PRODUCT_BUNDLE_IDENTIFIER=bundle_identifier,
                                            INFOPLIST_FILE='Info.plist', TARGETED_DEVICE_FAMILY='1,2')))))
    path = output/'project.json'
    path.write_text(json.dumps(spec, indent=2)+'\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(path), '--project', str(output)], check=True)
    return path


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path); p.add_argument('runner', type=Path)
    p.add_argument('--bundle-id', default='org.henge.shaderaudit')
    a=p.parse_args(); create_project(a.output,a.runner,a.bundle_id)
