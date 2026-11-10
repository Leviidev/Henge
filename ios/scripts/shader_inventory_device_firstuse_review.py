#!/usr/bin/env python3
"""Check authored first-use readback; runtime data never proves broker provenance."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct


def sha(data):return hashlib.sha256(data).hexdigest()


def review(manifest_bytes,report):
    m=json.loads(manifest_bytes);issues=[];case=report.get('selected_case');r=report.get('result',{});n=m['nonce_value']
    def check(ok,message):
        if not ok:issues.append(message)
    check(report.get('manifest_sha256')==sha(manifest_bytes),'manifest mismatch');check(report.get('nonce')==m['nonce'],'nonce mismatch');check(report.get('status')=='complete_results_require_review','incomplete/exceptional run');check(report.get('shipped_kernels_dispatched') in (False,0),'unexpected shipped execution claim')
    check(report.get('conversion_route')=='unknown_requires_host_receipts','runtime report cannot establish conversion route')
    if case not in m['allowed_cases']:return {'status':'failed_or_incomplete','issues':issues+['unknown selected case'],'conversion_route':'unknown'}
    spec=m['cases'][case];check(r.get('id')==case and r.get('library_route')==spec['route'],'wrong selected route');check(r.get('asset_hash_matches') and r.get('input_sha256')==m['asset_sha256'][spec['file']] and r.get('library_loaded'),'hash-checked library not established')
    keys=['alpha','beta'] if case=='packed' else ['static_consumer' if case=='static' else case];expected=[(k,mode) for k in keys for mode in (range(2) if case=='packed' else range(1))];rows=r.get('results',[])
    check(Counter(r.get('function_names',[]))==Counter(m['names'][k] for k in keys),'function inventory mismatch');check(Counter((c.get('key'),c.get('mode')) for c in rows)==Counter(expected),'case matrix missing/duplicated')
    for c in rows:
        key,mode=c.get('key'),c.get('mode')
        if (key,mode) not in expected:continue
        check(c.get('function_created') and c.get('function_type')==3 and c.get('name')==m['names'][key],f'{key}/{mode}: function identity/type not established')
        if case=='packed':check(c.get('constant_index')==0 and c.get('constant_type')=='bool',f'{key}/{mode}: known constant contract missing')
        if case=='tile':
            e=c.get('tile_execution',{});pixels=b''.join(struct.pack('<I',n^((i*0x045d9f3b)&0xffffffff)) for i in range(256))
            check(e.get('pipeline_created') and e.get('dispatch_api')=='dispatchThreadsPerTile' and e.get('tile_dispatch_encoded') and e.get('dispatch_completed'),'tile pipeline/actual dispatch incomplete')
            check(e.get('width')==16 and e.get('height')==16 and e.get('pixel_format')=='RGBA8Unorm' and e.get('pixels_checked')==256 and e.get('bytes_checked')==1024,'tile readback geometry incomplete')
            check(e.get('actual_sha256')==sha(pixels) and e.get('mismatched_bytes')==0 and e.get('clear_sentinel_pixels')==sum(pixels[i:i+4]==bytes([255,0,255,255]) for i in range(0,1024,4)) and e.get('clear_sentinel_pixels',256)<256,'tile exact pixel oracle failed/unchanged sentinel')
        else:
            e=c.get('execution',{});mul=17 if case=='basic' else 29 if case=='static' else 1;add=11 if case=='static' else 1000*mode+(10000 if key=='beta' else 0) if case=='packed' else 0;expected_bytes=b''.join(struct.pack('<I',n+mul*i+add) for i in range(256))
            check(c.get('pipeline_created') and e.get('dispatch_completed') and e.get('elements_checked')==256 and e.get('mismatches')==0 and e.get('actual_sha256')==sha(expected_bytes),f'{key}/{mode}: exact compute oracle failed')
    return {'status':'failed_or_incomplete' if issues else 'authored_execution_exact_conversion_route_unproven','selected_case':case,'issues':issues,'nonce':m['nonce'],'conversion_route':'unknown','uncached_conversion_proven':False,'shipped_execution_verified':False,'limits':['Need actual host serialized SHA, negative cache-before evidence, matched request/ready receipt and pipeline route to classify broker first-use conversion.','Separate native target execution is not guest bridge proof.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--output',type=Path);a=p.parse_args();result=review(a.manifest.read_bytes(),json.loads(a.report.read_text()));s=json.dumps(result,indent=2)+'\n'
    if a.output:a.output.write_text(s)
    print(s,end='');raise SystemExit(bool(result['issues']))


if __name__=='__main__':main()
