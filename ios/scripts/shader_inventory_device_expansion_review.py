#!/usr/bin/env python3
"""Independent strict review: accepts load/metadata or explicit CI pixel scope only."""
import argparse,json,hashlib,struct
from pathlib import Path


def sha(b):return hashlib.sha256(b).hexdigest()
def review(manifest_bytes,r,directory,expected_platform=None):
    m=json.loads(manifest_bytes);issues=[]
    def check(ok,why):
        if not ok:issues.append(why)
    jobs={j['source_sha256']:j for j in m['libraries']};j=jobs.get(r.get('source_sha256'));check(j is not None,'source not in manifest')
    check(r.get('manifest_sha256')==sha(manifest_bytes),'manifest hash mismatch');check(r.get('status')=='completed_requires_review','run incomplete/exception/selection rejected');check(r.get('asset_verified'),'candidate asset hash/length unverified');check(r.get('explicit_metal_pipeline_creation_attempted')in(False,0),'unexpected explicit pipeline creation')
    if expected_platform:check(r.get('runtime_platform')==expected_platform,'runtime platform differs from requested gate')
    if j:
        check(r.get('candidate_sha256')==j['candidate_sha256'],'candidate hash mismatch');check(r.get('kind')==j['kind'],'kind mismatch');check(j['id'].startswith(r.get('selected',''))and bool(r.get('selected')),'selection binding')
        if j['kind']=='metal':
            check(r.get('library_loaded'),'Metal library load failed');check(r.get('functions')==j['expected_functions'],'function name/type/constant records differ');check(r.get('function_count')==len(j['expected_functions']),'function count differs');check(all(f.get('created')for f in r.get('functions',[])),'function creation failed');scope='library/function metadata only; pipelines and execution untested'
        elif j['kind']=='coreimage':
            check(r.get('ci_names')==j['expected_ci_names'],'CI function inventory differs');check(r.get('ci_kernel_resolved'),'CI constructor failed');check(r.get('coreimage_execution_attempted'),'CI execution absent');o=r.get('oracle',{});check(o.get('status')=='completed_requires_review'and o.get('kernel_resolved')and o.get('output_created'),'CI oracle not constructed/completed');check(o.get('source_sha256')==j['candidate_sha256'],'CI oracle asset mismatch')
            mask=[0,.015625,.03125,1];alpha=[1,.5,.25,1];color=[.0625,.03125,0,.5];values=[]
            for cov,a in zip(mask,alpha):values.extend([*color[:3],a*color[3]]if cov>.02 else[0,0,0,0])
            expected=struct.pack('<16f',*values);p=directory/'radar-oracle.json.rgba32f';check(p.is_file()and p.read_bytes()==expected,'CI raw2x2 readback mismatch/missing');check(o.get('actual_sha256')==sha(expected)and o.get('pixels_checked')==4,'CI result digest/count mismatch');check(o.get('actual')==values,'CI reported float values mismatch');check(o.get('radar_sha256')==sha(struct.pack('<16f',0,0,0,1,0,0,0,.5,0,0,0,.25,0,0,0,1)),'radar input mismatch');check(o.get('mask_sha256')==sha(struct.pack('<16f',0,0,0,1,.015625,0,0,1,.03125,0,0,1,1,0,0,1)),'mask input mismatch');scope='CI names/constructor and4-pixel synthetic oracle; HASH semantics review remains separate'
        else:check(False,'unsupported manifest kind');scope='unsupported'
    else:scope='unbound'
    return {'status':'pass_with_bounded_scope'if not issues else'failed_or_incomplete','issues':issues,'source_sha256':r.get('source_sha256'),'candidate_sha256':r.get('candidate_sha256'),'runtime_platform':r.get('runtime_platform'),'scope':scope,'canonical_CI_HASH_contract_verified':False,'all_shader_execution_verified':False}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--expected-platform',choices=['ios','macos']);a=p.parse_args();r=review(a.manifest.read_bytes(),json.loads(a.report.read_text()),a.report.parent,a.expected_platform);a.output.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,indent=2));raise SystemExit(bool(r['issues']))
if __name__=='__main__':main()
