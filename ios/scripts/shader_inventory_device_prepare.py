#!/usr/bin/env python3
"""Prepare hash-pinned offline assets for the isolated iPad inventory helper."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from catalog_metallibs import inspect_metallib
from shader_inventory_repair_pack import pack
from shader_audit_project import create_project


def sha(data): return hashlib.sha256(data).hexdigest()


def save(path, value): path.write_text(json.dumps(value, indent=2)+'\n')


def checked_asset(source, resources, filename):
    data=source.read_bytes();record=inspect_metallib(data)
    if record['malformed_records'] or record['integrity_mismatches']:
        raise ValueError(f'Unreviewed candidate: {source}')
    (resources/filename).write_bytes(data)
    return {'file':filename,'sha256':sha(data),'byte_size':len(data)},record


def controls(root, resources, sdk, target, platform_flag, commands):
    products=[]
    def invoke(command):
        cp=subprocess.run(command,capture_output=True,text=True,timeout=45)
        commands.append({'command':command,'returncode':cp.returncode,'stdout':cp.stdout,'stderr':cp.stderr})
        if cp.returncode: raise RuntimeError(cp.stderr)
    for name,base in [('alpha',1000),('beta',2000)]:
        source=root/(name+'.metal')
        source.write_text('#include <metal_stdlib>\nusing namespace metal;\nconstant bool mode [[function_constant(0)]];\nkernel void '+name+'(device uint *out [[buffer(0)]],uint i [[thread_position_in_grid]]) { out[i]='+str(base)+'u+(mode?100u:0u)+i; }\n')
        air=root/(name+'.'+sdk+'.air');lib=root/(name+'.'+sdk+'.metallib')
        invoke(['xcrun','--sdk',sdk,'metal','-c',str(source),'-target',target,'-o',str(air)])
        invoke(['xcrun','--sdk',sdk,'air-lld','--arch','air64',platform_flag,'17.0' if sdk=='iphoneos' else '14.0',str(air),'-o',str(lib)])
        products.append(lib)
    data,evidence=pack(products);path=root/('packed-control.'+sdk+'.metallib');path.write_bytes(data)
    save(path.with_suffix('.manifest.json'),evidence)
    packed,_=checked_asset(path,resources,'packed-control.metallib')
    shared=root/'dynamic-control.metal'
    shared.write_text('#include <metal_stdlib>\nusing namespace metal;\nextern "C" uint inventory_transform(uint value) { return value*7u+19u; }\n')
    air=root/('dynamic-control.'+sdk+'.air');lib=root/('dynamic-control.'+sdk+'.metallib')
    invoke(['xcrun','--sdk',sdk,'metal','-c','-fvisibility=default',str(shared),'-target',target,'-o',str(air)])
    invoke(['xcrun','--sdk',sdk,'air-lld','--create-shared-library','--arch','air64',platform_flag,'17.0' if sdk=='iphoneos' else '14.0',
            '--install_name','@executable_path/AuditAssets/dynamic-control.metallib',str(air),'-o',str(lib)])
    dynamic,rec=checked_asset(lib,resources,'dynamic-control.metallib')
    if Counter((f['name'],f['type_raw']) for f in rec['functions'])!=Counter({('inventory_transform',3):1}):
        raise ValueError('Dynamic export inventory changed')
    consumer='#include <metal_stdlib>\nusing namespace metal;\nextern "C" uint inventory_transform(uint value);\nkernel void dynamic_consumer(device uint *out [[buffer(0)]],uint i [[thread_position_in_grid]]) { out[i]=inventory_transform(i); }\n'
    (resources/'dynamic-consumer.metal').write_text(consumer)
    dynamic['consumer_file']='dynamic-consumer.metal';dynamic['consumer_sha256']=sha(consumer.encode())
    dynamic['install_name']='@executable_path/AuditAssets/dynamic-control.metallib'
    dynamic['revision']='auditassets-install-name-v2'
    return {'packed':packed,'dynamic':dynamic,'elements_per_dispatch':256,
            'packed_specializations':4,'expected_total_values':1280,'origin':'authored oracle; never shipped-kernel execution'}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inventory_root',type=Path);p.add_argument('--bundle-id',default='org.henge.shaderaudit');a=p.parse_args()
    inventory_root=a.inventory_root.resolve();root=inventory_root/'inventory-device-03';root.mkdir(exist_ok=True)
    resources=root/'AuditAssets';resources.mkdir(exist_ok=True);native=root/'NativeResources';native.mkdir(exist_ok=True)
    review_path=inventory_root/'inventory-repair-02/current-offline-review.json'
    review=json.loads(review_path.read_text());jobs=[]
    for row in review['libraries']:
        if row['route']=='retained-existing-output':continue
        source=Path(row['output']);need=row['output_sha256'];data=source.read_bytes()
        if sha(data)!=need:raise ValueError(f'Candidate changed: {source}')
        asset,rec=checked_asset(source,resources,row['source_sha256']+'.metallib')
        all_functions=[{'name':f['name'],'type_raw':f['type_raw']} for f in rec['functions']]
        kernels=[f for f in all_functions if f['type_raw']==2]
        chosen=[]
        if kernels:
            chosen=[kernels[i] for i in sorted(set([0,len(kernels)//2,len(kernels)-1]))]
            for f in kernels:
                if f['name']=='memcpy' and f not in chosen:chosen.append(f)
        jobs.append(dict(asset,id=row['source_sha256'],source_sha256=row['source_sha256'],source_paths=row['source_paths'],
                         origin='shipped_candidate',route=row['route'],library_type=rec['header']['library_type_raw'],
                         expected_functions=all_functions,pipeline_samples=chosen,
                         execution_contract=None,execution_status='not_tested_no_argument_contract',
                         shipped_dynamic_link_status='not_tested_no_consumer_contract' if rec['header']['library_type_raw']==2 else 'not_applicable'))
    if len(jobs)!=7:raise ValueError('Expected exactly seven candidates')
    commands=[]
    manifest={'schema':1,'kit':'inventory-device-03','candidate_review_sha256':sha(review_path.read_bytes()),
              'default_stage':'controls','allowed_stages':['controls','libraries','pipelines'],
              'watchdog_seconds':90,'command_timeout_seconds':15,'max_pipeline_samples_per_job':4,
              'jobs':jobs,'controls':controls(root,resources,'iphoneos','air64-apple-ios17.0.0','--ios_version_min',commands),
              'limitations':['Shipped functions are never dispatched.','Required shipped constants are recorded, never guessed.',
                 'Dynamic object creation is separate from linking an actual consumer.','Authored controls do not establish shipped-kernel correctness.',
                 'Name enumeration is not pipeline or execution success.','Historical pipelines, embedded/dyld and opaque inventory boundaries are not covered.']}
    save(resources/'inventory-jobs.json',manifest)
    mac=dict(manifest,jobs=[],controls=controls(root,native,'macosx','air64-apple-macos14.0.0','--macos_version_min',commands))
    save(native/'inventory-jobs.json',mac);save(root/'prepare-commands.json',commands)
    spec=create_project(root,Path(__file__).with_name('shader_inventory_device_runner.m'),a.bundle_id)
    save(root/'kit-provenance.json',{'generated_project_spec_sha256':sha(spec.read_bytes()),
         'manifest_sha256':sha((resources/'inventory-jobs.json').read_bytes()),'candidates':len(jobs),
         'candidate_bytes':sum(j['byte_size'] for j in jobs),'candidate_function_records':sum(len(j['expected_functions']) for j in jobs),
         'pipeline_sample_upper_bound':sum(len(j['pipeline_samples']) for j in jobs),'device_accessed':False,
         'source_files':{p.name:sha(p.read_bytes()) for p in Path(__file__).parent.glob('shader_inventory_device_*') if p.is_file()}})
    print(root)


if __name__=='__main__':main()
