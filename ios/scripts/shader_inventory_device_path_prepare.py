#!/usr/bin/env python3
"""Build authored-only Metal install-name diagnostics without shipped changes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from catalog_metallibs import inspect_metallib


def sha(data):return hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('base',type=Path);a=p.parse_args();base=a.base.resolve();root=base/'path-controls-v4';root.mkdir(exist_ok=True);commands=[]
    for sdk,folder,target,flag,version in [('iphoneos','AuditAssets','air64-apple-ios17.0.0','--ios_version_min','17.0'),('macosx','NativeResources','air64-apple-macos14.0.0','--macos_version_min','14.0')]:
        assets=root/folder;assets.mkdir(exist_ok=True);baseline=base/folder;manifest=json.loads((baseline/'inventory-jobs.json').read_text())
        for name in ['packed-control.metallib','dynamic-control.metallib','dynamic-consumer.metal']:shutil.copyfile(baseline/name,assets/name)
        shutil.copyfile(base/'dynamic-control.metal',assets/'dynamic-source.metal')
        shared=assets/'dynamic-loader.metallib';client=assets/'consumer-loader.metallib';air=root/('consumer.'+sdk+'.air')
        for cmd in [['xcrun','--sdk',sdk,'air-lld','--create-shared-library','--arch','air64',flag,version,'--install_name','@loader_path/dynamic-loader.metallib',str(base/('dynamic-control.'+sdk+'.air')),'-o',str(shared)],
                    ['xcrun','--sdk',sdk,'metal','-c',str(assets/'dynamic-consumer.metal'),'-target',target,'-o',str(air)],
                    ['xcrun','--sdk',sdk,'air-lld','--arch','air64',flag,version,str(air),str(shared),'-o',str(client)]]:
            cp=subprocess.run(cmd,capture_output=True,text=True,timeout=45);commands.append({'command':cmd,'returncode':cp.returncode,'stderr':cp.stderr});assert cp.returncode==0,cp.stderr
        for file in [shared,client]:
            rec=inspect_metallib(file.read_bytes());assert not rec['malformed_records'] and not rec['integrity_mismatches']
        refs={p.name:sha(p.read_bytes()) for p in assets.iterdir() if p.is_file() and p.name!='inventory-jobs.json'}
        common={'consumer_source_file':'dynamic-consumer.metal','consumer_source_sha256':refs['dynamic-consumer.metal']}
        baseline_case=dict(common,id='relative_source_baseline',kind='relative_source',shared_file='dynamic-control.metallib',shared_sha256=refs['dynamic-control.metallib'],gate='diagnostic_preserve_failure_or_success')
        file_case=dict(common,id='loader_file_consumer',kind='loader_file',shared_file='dynamic-loader.metallib',shared_sha256=refs['dynamic-loader.metallib'],consumer_library_file='consumer-loader.metallib',consumer_library_sha256=refs['consumer-loader.metallib'],gate='native_qualified_oracle')
        absolute_case=dict(common,id='absolute_serialized_source_consumer',kind='absolute_source',shared_source_file='dynamic-source.metal',shared_source_sha256=refs['dynamic-source.metal'],gate='native_qualified_oracle')
        preload_case=dict(common,id='undefined_allowed_preloaded_only',kind='preloaded_only',shared_file='dynamic-control.metallib',shared_sha256=refs['dynamic-control.metallib'],gate='native_qualified_oracle')
        manifest.update(kit='inventory-device-03-path-v4',jobs=[],allowed_stages=['controls'],control_route='path_resolution_matrix_v4',baseline_manifest_sha256=sha((baseline/'inventory-jobs.json').read_bytes()),asset_sha256=refs)
        manifest['controls']={'packed':manifest['controls']['packed'],'dynamic':{'cases':[baseline_case,file_case,absolute_case,preload_case]},'origin':'authored-only path diagnostics; no shipped assets','elements_per_dispatch':256,'packed_specializations':4}
        (assets/'inventory-jobs.json').write_text(json.dumps(manifest,indent=2)+'\n')
    project=root/'HengeShaderAudit.xcodeproj';project.mkdir(exist_ok=True);s=(base/'HengeShaderAudit.xcodeproj/project.pbxproj').read_text().replace('shader_inventory_device_runner.m','shader_inventory_device_path_runner.m').replace('path = ../../Henge/ios/scripts;','path = ../../../Henge/ios/scripts;');(project/'project.pbxproj').write_text(s);shutil.copyfile(base/'Info.plist',root/'Info.plist')
    (root/'prepare-commands.json').write_text(json.dumps(commands,indent=2)+'\n');print(root)


if __name__=='__main__':main()
