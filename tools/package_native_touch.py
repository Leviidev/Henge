#!/usr/bin/env python3
"""Package the USB-only guest companions with no restricted entitlement claims."""
import argparse
import gzip
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

ROOTS={'Henge Touch Agent.app','Henge Sharing Agent.app'}
def validate_members(members):
    for member in members:
        p=PurePosixPath(member.name)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0] not in ROOTS or not (member.isfile() or member.isdir()):
            raise ValueError('Unsafe guest-helper archive member: '+member.name)

def run(*args):
    return subprocess.run(args,check=True,capture_output=True).stdout

def package(args):
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='henge-usb-touch-',dir=args.output.parent) as directory:
        root=Path(directory)
        empty=root/'entitlements.plist';empty.write_bytes(plistlib.dumps({}))
        apps=[]
        for name,binary,bundle,minimum in [
            ('Henge Touch Agent',args.binary,'dev.henge.touch-agent','15.0'),
            ('Henge Sharing Agent',args.sharing_binary,'dev.henge.sharing-agent','12.0')]:
            app=root/(name+'.app');contents=app/'Contents';executable=contents/'MacOS'/binary.name
            executable.parent.mkdir(parents=True);shutil.copy2(binary,executable);executable.chmod(0o755)
            info=dict(CFBundleIdentifier=bundle,CFBundleExecutable=binary.name,CFBundleName=name,CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',LSMinimumSystemVersion=minimum,LSUIElement=True)
            if name=='Henge Sharing Agent':info['NSLocalNetworkUsageDescription']='Connect to Henge for the shared folder, clipboard, touch input.'
            (contents/'Info.plist').write_bytes(plistlib.dumps(info))
            run('codesign','--force','--sign','-','--identifier',bundle,'--entitlements',str(empty),str(app))
            run('codesign','--verify','--strict',str(app))
            claims=plistlib.loads(run('codesign','-d','--entitlements','-','--xml',str(app)))
            if claims:raise ValueError('USB companions must have empty entitlements')
            apps.append(app)
        archive=root/'helpers.tar.gz'
        def stable(member):
            member.uid=member.gid=member.mtime=0;member.uname=member.gname='';return member
        with archive.open('wb') as file,gzip.GzipFile(fileobj=file,mode='wb',filename='',mtime=0) as compressed,tarfile.open(fileobj=compressed,mode='w') as tar:
            for app in apps:tar.add(app,arcname=app.name,filter=stable)
        with tarfile.open(archive,'r:gz') as tar:validate_members(tar.getmembers())
        os.replace(archive,args.output)
    print(str(args.output)+': USB touch; two signed companions; no virtual HID entitlement')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True);p.add_argument('--sharing-binary',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    try:package(args)
    except (ValueError,subprocess.CalledProcessError) as error:p.exit(1,'USB helper packaging failed: '+str(error)+'\n')
if __name__=='__main__':main()
