#!/usr/bin/env python3
"""Verify the actual guest bundle archive with native Apple signing tools."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
from package_native_touch import validate_members

def verify(archive):
    result={}
    with tempfile.TemporaryDirectory(prefix='henge-verify-touch-') as directory:
        root=Path(directory)
        with tarfile.open(archive,'r:gz') as tar:
            validate_members(tar.getmembers());tar.extractall(root,filter='data')
        for name,executable in [('Henge Touch Agent.app','henge-touch-agent'),('Henge Sharing Agent.app','henge-agent')]:
            app=root/name
            info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
            assert info['CFBundleExecutable']==executable and info['LSUIElement'] is True
            binary=app/'Contents/MacOS'/executable
            assert binary.read_bytes()[:4]==bytes.fromhex('cffaedfe')
            assert subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()=='arm64'
            subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
            claims=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements','-','--xml',str(app)]))
            assert claims=={}, 'Unexpected guest entitlement claims'
            assert not (app/'Contents/embedded.provisionprofile').exists()
            if executable=='henge-agent':assert info.get('NSLocalNetworkUsageDescription')
            result[executable]=dict(sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),arm64=True,signature_verified=True,entitlements={})
    return result
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('archive',type=Path);a=p.parse_args()
    print(json.dumps(verify(a.archive),indent=2))
