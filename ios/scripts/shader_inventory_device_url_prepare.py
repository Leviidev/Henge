#!/usr/bin/env python3
"""Separate URL-origin helper variant; baseline and candidate bytes stay intact."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def sha(data):return hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('base_kit',type=Path);a=p.parse_args();base=a.base_kit.resolve();root=base/'url-controls-v3';root.mkdir(exist_ok=True);proof=[]
    for sdk,dirname in [('iphoneos','AuditAssets'),('macosx','NativeResources')]:
        src=base/dirname;assets=root/dirname;shutil.copytree(src,assets,dirs_exist_ok=True);before=(src/'inventory-jobs.json').read_bytes();manifest=json.loads(before)
        # The offline-consumer experiment did not pass native pipeline linking.
        # Preserve its evidence outside runnable assets; do not adopt it.
        experiment=assets/'dynamic-consumer.metallib'
        if experiment.exists():
            folder=root/'excluded-experiments';folder.mkdir(exist_ok=True);destination=folder/('offline-consumer.'+sdk+'.metallib')
            if destination.exists():assert destination.read_bytes()==experiment.read_bytes();experiment.unlink()
            else:experiment.rename(destination)
        dynamic=manifest['controls']['dynamic'];dynamic.update(revision='shared-file-url-source-consumer-v3',dynamic_loading_route='file_url',consumer_loading_route='runtime_source')
        manifest['baseline_manifest_sha256']=sha(before);manifest['kit']='inventory-device-03-url-v3';manifest['control_route']='URL-backed shared library plus runtime-source consumer; byte-load diagnostic separately reported';manifest['unadvertised_dynamic_flag']='--attempt-unadvertised-dynamic explicitly attempts authored APIs while preserving the advertised false capability'
        (assets/'inventory-jobs.json').write_text(json.dumps(manifest,indent=2)+'\n')
        unchanged={j['file']:sha((src/j['file']).read_bytes())==sha((assets/j['file']).read_bytes())==j['sha256'] for j in manifest['jobs']};assert all(unchanged.values());assert before==(src/'inventory-jobs.json').read_bytes()
        proof.append({'sdk':sdk,'baseline_manifest_sha256':sha(before),'new_manifest_sha256':sha((assets/'inventory-jobs.json').read_bytes()),'shipped_candidates_unchanged':unchanged,'baseline_asset_files_unchanged':all((src/f).read_bytes()==(assets/f).read_bytes() for f in ['packed-control.metallib','dynamic-control.metallib','dynamic-consumer.metal'])})
    project=root/'HengeShaderAudit.xcodeproj';project.mkdir(exist_ok=True);s=(base/'HengeShaderAudit.xcodeproj/project.pbxproj').read_text();s=s.replace('shader_inventory_device_runner.m','shader_inventory_device_url_runner.m').replace('path = ../../Henge/ios/scripts;', 'path = ../../../Henge/ios/scripts;');(project/'project.pbxproj').write_text(s);shutil.copyfile(base/'Info.plist',root/'Info.plist')
    (root/'provenance.json').write_text(json.dumps({'baseline_kit':str(base),'variants':proof,'device_accessed':False,'preserved_failure_report':str(base/'device-results/3F3E0945-5D8B-402A-9A3F-1CEEA6ECA582/inventory-report.json'),'offline_consumer_status':'not_adopted_native_pipeline_undefined_symbol'},indent=2)+'\n');print(root)


if __name__=='__main__':main()
