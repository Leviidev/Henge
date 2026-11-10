#!/usr/bin/env python3
"""Package and native-qualify an authored fixture; optionally sign isolated iOS app."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from shader_inventory_device_firstuse_review import review


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('kit',type=Path);p.add_argument('--sign-identity');p.add_argument('--profile',type=Path);p.add_argument('--entitlements',type=Path);a=p.parse_args();root=a.kit.resolve();commands=[]
    def run(cmd,timeout=100):
        cp=subprocess.run(cmd,capture_output=True,text=True,timeout=timeout);commands.append(dict(command=cmd,returncode=cp.returncode,stdout=cp.stdout,stderr=cp.stderr));save(root/'package-commands.json',commands)
        if cp.returncode:raise RuntimeError(cp.stderr or cp.stdout[-4000:])
        return cp
    package=root/'sonoma-controls';package.mkdir(exist_ok=False);assets=package/'AuditAssets';shutil.copytree(root/'NativeResources',assets);binary=package/'native-runner';source=Path(__file__).with_name('shader_inventory_device_firstuse_runner.m').resolve()
    run(['xcrun','--sdk','macosx','clang','-arch','arm64','-mmacosx-version-min=14.0','-std=gnu11','-fobjc-arc','-fblocks',str(source),'-framework','Foundation','-framework','Metal','-framework','AppKit','-o',str(binary)])
    build_version=run(['xcrun','vtool','-show-build',str(binary)]).stdout;assert 'minos 14.0' in build_version
    m=assets/'firstuse-manifest.json';manifest=json.loads(m.read_text());reviews=[]
    for case in manifest['allowed_cases']:
        run([str(binary),str(assets),str(root/'package-native-results'),'--firstuse-case',case]);latest=json.loads((root/'package-native-results/firstuse-latest.json').read_text())['relative_directory'];report=root/'package-native-results'/latest/'firstuse-report.json';checked=review(m.read_bytes(),json.loads(report.read_text()));assert not checked['issues'],checked;reviews.append(dict(report=str(report),report_sha256=sha(report),review=checked))
    members=['native-runner']+['AuditAssets/'+p.name for p in sorted(assets.iterdir())];archive=root/'sonoma-firstuse-macos14-arm64.tar.gz'
    with tarfile.open(archive,'w:gz') as tar:
        for name in members:tar.add(package/name,arcname=name,recursive=False)
    result=dict(status='authored_fixtures_host_qualified_guest_ipad_unrun',nonce=manifest['nonce'],archive=str(archive),archive_sha256=sha(archive),archive_bytes=archive.stat().st_size,members={name:sha(package/name) for name in members},build_version=build_version,native_reviews=reviews,device_accessed=False,conversion_provenance='unknown_requires_host_receipts',source_sha256=sha(source))
    if a.sign_identity:
        if not a.profile or not a.entitlements:raise ValueError('Signing requires explicit existing profile and entitlements')
        build=Path(tempfile.mkdtemp(prefix='henge-firstuse04-build-',dir='/private/tmp'));run(['xcodebuild','-project',str(root/'HengeShaderAudit.xcodeproj'),'-scheme','HengeShaderAudit','-configuration','Release','-sdk','iphoneos','-destination','generic/platform=iOS','-derivedDataPath',str(build),'CODE_SIGNING_ALLOWED=NO','ENABLE_DEBUG_DYLIB=NO','build'],timeout=120)
        app=Path(tempfile.mkdtemp(prefix='henge-firstuse04-signed-',dir='/private/tmp'))/'HengeShaderAudit.app';shutil.copytree(build/'Build/Products/Release-iphoneos/HengeShaderAudit.app',app);shutil.copyfile(a.profile,app/'embedded.mobileprovision');im=root/'AuditAssets/firstuse-manifest.json';assert (app/'AuditAssets/firstuse-manifest.json').read_bytes()==im.read_bytes()
        for name,digest in json.loads(im.read_text())['asset_sha256'].items():assert Path(name).name==name and sha(app/'AuditAssets'/name)==digest
        assert not (app/'Resources').exists();run(['codesign','--force','--sign',a.sign_identity,'--entitlements',str(a.entitlements.resolve()),'--timestamp=none','--generate-entitlement-der',str(app)]);run(['codesign','--verify','--strict','--verbose=2',str(app)])
        result['signed_app']={'path':str(app),'executable_sha256':sha(app/'HengeShaderAudit'),'manifest_sha256':sha(im),'profile_sha256':sha(a.profile),'entitlements_sha256':sha(a.entitlements),'identity':a.sign_identity,'strict_verification':True}
    save(root/'package.json',result);print(json.dumps({k:v for k,v in result.items() if k not in ('members','native_reviews','build_version')},indent=2))


if __name__=='__main__':main()
