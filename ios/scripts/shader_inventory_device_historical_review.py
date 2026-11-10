#!/usr/bin/env python3
"""Independent math/buffer/readback checks; never claim recovered historical draw."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import struct


def sha(data):return hashlib.sha256(data).hexdigest()


def expected_bgra(spec):
    dest=spec['clear_rgba'];x=[v/max(dest[3],0.000100017) for v in dest[:3]]+[dest[3]];m=spec['matrix_columns'];color=[sum(m[k][c]*x[k] for k in range(4))+m[4][c] for c in range(4)];color[3]=min(1,max(0,color[3]));color[:3]=[v*color[3] for v in color[:3]];color=[v*spec['coverage'] for v in color];out=[color[c]+(1-color[3])*dest[c] for c in range(4)];out[3]=min(1,max(0,out[3]));rgba=[max(0,min(255,math.floor(v*255+0.5))) for v in out];return [rgba[2],rgba[1],rgba[0],rgba[3]]


def packed_inputs(spec):
    vertices=bytearray(144);uniforms=bytearray(224)
    for i,pos in enumerate([(-1,-1,0,1),(3,-1,0,1),(-1,3,0,1)]):struct.pack_into('<4f',vertices,i*48,*pos);struct.pack_into('<4e',vertices,i*48+32,1,1,1,spec['coverage'])
    for column,values in enumerate(spec['matrix_columns']):struct.pack_into('<4e',uniforms,176+column*8,*values)
    matrix=struct.pack('<16f',1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1)
    return {'vertex_bytes_sha256':sha(vertices),'uniform_bytes_sha256':sha(uniforms),'mvp_bytes_sha256':sha(matrix)}


def review(manifest_bytes,r,raw_directory=None):
    m=json.loads(manifest_bytes);issues=[]
    def check(ok,why):
        if not ok:issues.append(why)
    check(r.get('manifest_sha256')==sha(manifest_bytes),'manifest mismatch');check(r.get('status')=='completed_requires_review','incomplete/exceptional run');check(r.get('exact_historical_descriptor_verified') in (False,0),'unsupported exact historical descriptor claim');check(r.get('pipeline_created'),'render pipeline not created')
    for role,kind in [('vertex',1),('fragment',2)]:check(r.get(role+'_loaded') and r.get(role+'_sha256')==m[role]['sha256'] and r.get(role+'_function')==m[role]['function'] and r.get(role+'_type')==kind,role+': exact historical function/bytes not established')
    d=r.get('descriptor',{});check(d.get('sample_count')==1 and d.get('color0')==80 and d.get('depth')==0 and d.get('stencil')==0 and d.get('hardware_blending') in (False,0) and d.get('vertex_descriptor')=='nil_manual_fetch_in_exact_vertex_shader','authored descriptor contract changed')
    expected={c['id']:c for c in m['cases']};rows=r.get('cases',[]);check(Counter(c.get('id') for c in rows)==Counter(expected.keys()),'oracle case matrix incomplete/duplicated')
    for c in rows:
        spec=expected.get(c.get('id'))
        if not spec:continue
        pixel=expected_bgra(spec);raw=bytes(pixel)*256;ident=spec['id'];check(pixel==spec['expected_bgra8'],ident+': manifest disagrees with CPU equation');check(c.get('clear_rgba')==spec['clear_rgba'] and c.get('coverage')==spec['coverage'],ident+': case inputs differ');check(all(c.get(k)==v for k,v in packed_inputs(spec).items()),ident+': shader buffer layout/bytes differ');check(c.get('draw_encoded') and c.get('dispatch_completed') and c.get('pixels_checked')==256 and c.get('mismatched_bytes')==0 and c.get('actual_sha256')==sha(raw) and c.get('first_pixel_bgra8')==pixel,ident+': exact framebuffer-fetch oracle failed');clear=bytes([round(spec['clear_rgba'][i]*255) for i in [2,1,0,3]])*256;check(sha(raw)!=sha(clear),ident+': oracle cannot distinguish unchanged clear')
        if raw_directory is not None:
            p=raw_directory/(ident+'.bgra8');check(p.is_file() and p.read_bytes()==raw,ident+': raw readback missing/incorrect')
    return {'status':'exact_historical_shaders_pass_authored_framebuffer_fetch_oracle' if not issues else 'failed_or_incomplete','issues':issues,'pixels_checked':768 if not issues else None,'exact_historical_descriptor_verified':False,'historical_draw_inputs_verified':False,'scope':'Exact specialized shader libraries/functions; authored descriptor and synthetic resources. No attribution of the missing historical descriptor, UI event, or original framebuffer pixels.'}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--raw-directory',type=Path);p.add_argument('--output',type=Path);a=p.parse_args();r=review(a.manifest.read_bytes(),json.loads(a.report.read_text()),a.raw_directory);s=json.dumps(r,indent=2)+'\n'
    if a.output:a.output.write_text(s)
    print(s,end='');raise SystemExit(bool(r['issues']))


if __name__=='__main__':main()
