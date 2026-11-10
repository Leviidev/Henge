#!/usr/bin/env python3
"""Create nonce-authored paired targets; no cache installation or device access."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import uuid
from catalog_metallibs import inspect_metallib
from shader_inventory_repair_pack import pack
from shader_audit_project import create_project


def sha(data):return hashlib.sha256(data).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);p.add_argument('--nonce',default=None);p.add_argument('--bundle-id',default='org.henge.shaderaudit');a=p.parse_args();nonce=a.nonce or uuid.uuid4().hex
    if len(nonce)!=32 or any(c not in '0123456789abcdef' for c in nonce):raise ValueError('nonce must be32lowercasehex')
    root=a.output.resolve()/nonce;root.mkdir(parents=True,exist_ok=False);n=int(nonce[:6],16);names={k:k+'_'+nonce for k in ['basic','alpha','beta','static_consumer','static_helper','tile']};sources={};head='#include <metal_stdlib>\nusing namespace metal;\n'
    sources['basic']=head+f'kernel void {names["basic"]}(device uint *out [[buffer(0)]],uint i [[thread_position_in_grid]]) {{ out[i]={n}u+17u*i; }}\n'
    for k,add in [('alpha',0),('beta',10000)]:sources[k]=head+f'constant bool mode [[function_constant(0)]];\nkernel void {names[k]}(device uint *out [[buffer(0)]],uint i [[thread_position_in_grid]]) {{ out[i]={n+add}u+(mode?1000u:0u)+i; }}\n'
    sources['static_helper']=head+f'extern "C" uint {names["static_helper"]}(uint i) {{ return {n}u+29u*i+11u; }}\n'
    sources['static_consumer']=head+f'extern "C" uint {names["static_helper"]}(uint);\nkernel void {names["static_consumer"]}(device uint *out [[buffer(0)]],uint i [[thread_position_in_grid]]) {{ out[i]={names["static_helper"]}(i); }}\n'
    sources['tile']=head+f'''struct Pixel {{ float4 color [[color(0)]]; }};
kernel void {names['tile']}(imageblock<Pixel, imageblock_layout_implicit> image, ushort2 tid [[thread_position_in_threadgroup]]) {{
    uint v={n}u ^ ((uint(tid.x)+16u*uint(tid.y))*0x045d9f3bu);
    Pixel p; p.color=float4(float(v&255u),float((v>>8)&255u),float((v>>16)&255u),float(v>>24))/255.0f; image.write(p,tid);
}}
'''
    source_dir=root/'sources';source_dir.mkdir()
    for k,s in sources.items():(source_dir/(k+'.metal')).write_text(s)
    commands=[];inventories={}
    def run(cmd):
        cp=subprocess.run(cmd,capture_output=True,text=True,timeout=60);commands.append(dict(command=cmd,returncode=cp.returncode,stdout=cp.stdout,stderr=cp.stderr));save(root/'commands.json',commands)
        if cp.returncode:raise RuntimeError(cp.stderr)
    for sdk,folder,target,flag,version in [('iphoneos','AuditAssets','air64-apple-ios17.0.0','--ios_version_min','17.0'),('macosx','NativeResources','air64-apple-macos14.0.0','--macos_version_min','14.0')]:
        assets=root/folder;assets.mkdir();build=root/sdk;build.mkdir();airs={};libs={}
        for key in sources:
            air=build/(key+'.air');airs[key]=air;cmd=['xcrun','--sdk',sdk,'metal','-c',str(source_dir/(key+'.metal')),'-target',target,'-o',str(air)]
            if key=='static_helper':cmd.insert(5,'-fvisibility=default')
            run(cmd)
        for key in ['alpha','beta','tile']:
            lib=build/(key+'.metallib');run(['xcrun','--sdk',sdk,'air-lld','--arch','air64',flag,version,str(airs[key]),'-o',str(lib)]);libs[key]=lib
        packed,evidence=pack([libs['alpha'],libs['beta']]);(assets/'packed.metallib').write_bytes(packed);save(build/'packed-provenance.json',evidence)
        run(['xcrun','--sdk',sdk,'air-lld','--arch','air64',flag,version,str(airs['static_consumer']),str(airs['static_helper']),'-o',str(assets/'static.metallib')]);shutil.copyfile(libs['tile'],assets/'tile.metallib');shutil.copyfile(source_dir/'basic.metal',assets/'basic.metal')
        inv={}
        for file in assets.glob('*.metallib'):
            rec=inspect_metallib(file.read_bytes());assert not rec['malformed_records'] and not rec['integrity_mismatches'];inv[file.name]=rec
        assert inv['packed.metallib']['air_region_count']==2
        manifest={'schema':1,'kit':'inventory-firstuse-04','nonce':nonce,'nonce_value':n,'sdk':sdk,'target':target,'allowed_cases':['basic','packed','static','tile'],'names':names,'asset_sha256':{f.name:sha(f.read_bytes()) for f in assets.iterdir()},'cases':{'basic':{'file':'basic.metal','route':'runtime_source'},'packed':{'file':'packed.metallib','route':'library_bytes'},'static':{'file':'static.metallib','route':'library_bytes'},'tile':{'file':'tile.metallib','route':'library_bytes'}},'limits':['Authored execution only.','Runtime report alone cannot establish broker conversion/cache route.','macOS and iOS assets are separately compiled targets from identical nonce sources.','Each launch runs exactly one selected case.']};save(assets/'firstuse-manifest.json',manifest);inventories[sdk]=inv
    save(root/'catalogs.json',inventories);save(root/'provenance.json',{'nonce':nonce,'nonce_value':n,'source_sha256':{p.name:sha(p.read_bytes()) for p in source_dir.iterdir()},'status':'built_runtime_unverified','device_accessed':False,'broker_cache_installed':False})
    create_project(root,Path(__file__).with_name('shader_inventory_device_firstuse_runner.m'),a.bundle_id);print(root)


if __name__=='__main__':main()
