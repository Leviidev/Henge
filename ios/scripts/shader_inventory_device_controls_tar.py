#!/usr/bin/env python3
"""Build a controls-only arm64/macOS14 tar with executable-relative AuditAssets."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

from shader_inventory_device_review import review


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('kit',type=Path);p.add_argument('--revision',default='appkit-v2');p.add_argument('--runner-source',type=Path,default=Path(__file__).with_name('shader_inventory_device_runner.m'));a=p.parse_args();root=a.kit.resolve()
    if not a.revision.replace('-','').isalnum():raise ValueError('Revision must contain letters, digits and hyphens only')
    package=root/('sonoma-controls-'+a.revision);assets=package/'AuditAssets';assets.mkdir(parents=True,exist_ok=True)
    manifest=json.loads((root/'NativeResources/inventory-jobs.json').read_text());manifest['jobs']=[];manifest['allowed_stages']=['controls'];manifest['scope']='authored controls only; no shipped candidate assets';manifest['default_stage']='controls'
    asset_names=['packed-control.metallib','dynamic-control.metallib','dynamic-consumer.metal']
    if manifest['controls']['dynamic'].get('consumer_library_file'):asset_names.append(manifest['controls']['dynamic']['consumer_library_file'])
    if manifest.get('asset_sha256'):asset_names=sorted(manifest['asset_sha256'])
    for name in asset_names:shutil.copyfile(root/'NativeResources'/name,assets/name)
    m=assets/'inventory-jobs.json';m.write_text(json.dumps(manifest,indent=2)+'\n')
    source=a.runner_source.resolve();binary=package/'native-runner'
    command=['xcrun','--sdk','macosx','clang','-arch','arm64','-mmacosx-version-min=14.0','-std=gnu11','-fobjc-arc','-fblocks',str(source),'-framework','Foundation','-framework','Metal','-framework','AppKit','-o',str(binary)]
    build=subprocess.run(command,capture_output=True,text=True,timeout=45);assert build.returncode==0,build.stderr
    version=subprocess.run(['xcrun','vtool','-show-build',str(binary)],capture_output=True,text=True,timeout=30);assert version.returncode==0 and 'minos 14.0' in version.stdout,version.stdout
    results=root/('sonoma-controls-'+a.revision+'-host-results')
    runcommand=[str(binary),str(assets),str(results),'--inventory-stage','controls'];run=subprocess.run(runcommand,capture_output=True,text=True,timeout=100)
    assert run.returncode==0,run.stderr
    latest=json.loads((results/'inventory-latest.json').read_text())['relative_directory'];report=results/latest/'inventory-report.json'
    checked=review(m.read_bytes(),json.loads(report.read_text()));assert not checked['issues'],checked
    members=['native-runner','AuditAssets/inventory-jobs.json']+['AuditAssets/'+name for name in asset_names]
    archive=root/('sonoma-controls-macos14-arm64-'+a.revision+'.tar.gz')
    with tarfile.open(archive,'w:gz') as tar:
        for name in members:tar.add(package/name,arcname=name,recursive=False)
    with tarfile.open(archive) as tar:assert sorted(tar.getnames())==sorted(members)
    result={'status':'controls_only_kit_built_host_validated_guest_unrun','archive':str(archive),'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'archive_bytes':archive.stat().st_size,
            'members':{name:hashlib.sha256((package/name).read_bytes()).hexdigest() for name in members},'build_command':command,'build_stdout':build.stdout,'build_stderr':build.stderr,
            'build_version':version.stdout,'native_host_control_review':checked,'native_host_report':str(report),
            'startup':json.loads(report.read_text()).get('startup'),
            'guest_run_command':'./native-runner ./AuditAssets ./results --inventory-stage controls','layout':'Extract into an empty directory and run there. native-runner and AuditAssets are siblings. Metal relative install names resolve from the referencing/entrypoint MTLLibrary origin; runtime-source consumers have no file URL.',
            'limits':['No shipped candidates included.','macOS14 minimum deployment target checked; actual Sonoma execution remains unrun by this worker.','Native-host pass is not proof of Henge guest bridge support.'],'device_or_guest_accessed':False}
    (root/('sonoma-controls-'+a.revision+'-kit.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:result[k] for k in ['status','archive','archive_sha256','archive_bytes','guest_run_command','build_version','startup']},indent=2))


if __name__=='__main__':main()
