#!/usr/bin/env python3
"""Build an unsigned direct-Metal audit app; no signing identity or device actions."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider-build', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle-id', default='org.henge.closureaudit')
    args = parser.parse_args()
    build, out = args.provider_build.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios17.0',
               '-isysroot', sdk, '-std=c++20', '-O2', '-frtti', '-fexceptions',
               '-I' + str(ROOT.parent / 'ondevice-shaders'),
               '-DHENGE_AIR_EMBEDDED=1', '-I' + str(build / 'llvm-source/llvm/include'),
               '-I' + str(build / 'llvm-ios/include'), '-c', str(ROOT / 'stateless_link.cpp'),
               '-o', str(out / 'closure.o')]
    subprocess.run(command, check=True)
    libraries = subprocess.check_output([str(build / 'llvm-native/bin/llvm-config'),
        '--libnames', 'linker', 'bitreader', 'bitwriter140', 'bitwriter', 'transformutils', 'core'], text=True).split()
    archive = out / 'libHGStatelessAudit.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(archive), str(out / 'closure.o'),
                    *[str(build / 'llvm-ios/lib' / name) for name in libraries]], check=True)
    shutil.copytree(args.fixtures, out / 'AuditAssets')
    info = dict(CFBundleDevelopmentRegion='$(DEVELOPMENT_LANGUAGE)',
        CFBundleDisplayName='On-device Closure Audit', CFBundleExecutable='$(EXECUTABLE_NAME)',
        CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleInfoDictionaryVersion='6.0',
        CFBundleName='$(PRODUCT_NAME)', CFBundlePackageType='APPL',
        CFBundleShortVersionString='1.0', CFBundleVersion='1', UIFileSharingEnabled=True,
        UILaunchScreen={}, UIRequiresFullScreen=True,
        UISupportedInterfaceOrientations=['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'])
    (out / 'Info.plist').write_bytes(plistlib.dumps(info))
    spec = dict(name='HengeClosureAudit', options=dict(deploymentTarget=dict(iOS='17.0')),
        settings=dict(base=dict(CLANG_ENABLE_OBJC_ARC=True, CLANG_CXX_LANGUAGE_STANDARD='c++20',
                                CODE_SIGNING_ALLOWED=False)),
        targets=dict(HengeClosureAudit=dict(type='application', platform='iOS',
            sources=[dict(path=str(ROOT / 'device_control.mm')),
                     dict(path='AuditAssets', type='folder', buildPhase='resources')],
            settings=dict(base=dict(PRODUCT_BUNDLE_IDENTIFIER=args.bundle_id, INFOPLIST_FILE='Info.plist',
                TARGETED_DEVICE_FAMILY='1,2', OTHER_LDFLAGS=[str(archive), '-lc++', '-Wl,-dead_strip',
                    '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'UIKit',
                    '-framework', 'CoreGraphics'])))))
    (out / 'project.json').write_text(json.dumps(spec, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(out / 'project.json'), '--project', str(out)], check=True)
    subprocess.run(['xcodebuild', '-project', str(out / 'HengeClosureAudit.xcodeproj'),
                    '-scheme', 'HengeClosureAudit', '-configuration', 'Release', '-sdk', 'iphoneos',
                    '-destination', 'generic/platform=iOS', '-derivedDataPath', str(out / 'build'),
                    'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)


if __name__ == '__main__':
    main()
