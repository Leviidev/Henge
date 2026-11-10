#!/usr/bin/env python3
"""Isolated protocol3 converter. Requires matching profiled host viewport replay."""
import argparse,hashlib,json,subprocess,sys,tempfile
from pathlib import Path
HERE=Path(__file__).resolve().parent
from catalog_metallibs import inspect_metallib
from gl_position_lower import get_plan,lower
from shader_profile import CONTRACT,check_profile

def rebuild(source,destination,target):
 data=source.read_bytes();r=inspect_metallib(data)
 if r['malformed_records']or r['integrity_mismatches']or not r['single_payload_extraction_valid']:raise ValueError('requires validated single-module AIR')
 digest=hashlib.sha256(data).hexdigest();destination.mkdir(parents=True,exist_ok=True);output=destination/('profiled-ioslib-'+digest+'.metallib')
 with tempfile.TemporaryDirectory(prefix='profiled-air-',dir=destination)as t:
  root=Path(t);air=root/'original.air';a=r['air_regions'][0];air.write_bytes(data[a['offset']:a['offset']+a['size']]);plan=get_plan(air);input_air=air
  profile=dict(schema=1,gl_clip_zero_to_one=False,vertex_functions=[],viewport_contract=None)
  if plan['gl_clip_zero_to_one']:
   text=root/'original.ll';subprocess.run(['xcrun','--sdk','macosx','metal','-x','ir','-S','-emit-llvm',str(air),'-target',plan['target_triple'],'-o',str(text)],check=True,timeout=10)
   changed=root/'normalized.ll';result=lower(text,changed);input_air=changed
   profile.update(gl_clip_zero_to_one=True,vertex_functions=result['profile']['vertex_functions'],viewport_contract=CONTRACT)
  ios=root/'ios.air';candidate=root/'candidate.metallib'
  subprocess.run(['xcrun','--sdk','iphoneos','metal','-x','ir','-c',str(input_air),'-target',target,'-o',str(ios)],check=True,timeout=10)
  subprocess.run(['xcrun','--sdk','iphoneos','metallib',str(ios),'-o',str(candidate)],check=True,timeout=10)
  b=candidate.read_bytes();converted=inspect_metallib(b)
  inventory=lambda q:sorted((f['name'],f['type_raw'])for f in q['functions'])
  if converted['malformed_records']or converted['integrity_mismatches']or inventory(converted)!=inventory(r):raise ValueError('output inventory/integrity mismatch')
  if profile['gl_clip_zero_to_one']:
   if set(profile['vertex_functions'])!={f['name']for f in converted['functions']if f['type_raw']==0}:raise ValueError('profile differs from actual exported vertex inventory')
   for a in converted['air_regions']:
    check=root/'output-check.air';check.write_bytes(b[a['offset']:a['offset']+a['size']]);post=get_plan(check)
    if post['changed']or not post['gl_clip_zero_to_one']or sorted(x['name']for x in post['functions'])!=sorted(profile['vertex_functions']):raise ValueError('position marker lost or changed by compiler/linker')
  profile=check_profile(profile);candidate.replace(output)
  sidecar=dict(schema=1,source_sha256=digest,output_sha256=hashlib.sha256(b).hexdigest(),length=len(b),profile=profile)
  output.with_suffix(output.suffix+'.profile.json').write_text(json.dumps(sidecar,indent=2)+'\n')
 return output
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('sources',type=Path,nargs='+');p.add_argument('--output-dir',type=Path,required=True);p.add_argument('--target',default='air64-apple-ios17.0.0');a=p.parse_args()
 for source in a.sources:print(rebuild(source,a.output_dir,a.target))
