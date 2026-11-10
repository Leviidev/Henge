#!/usr/bin/env python3
"""Review CI API/oracle evidence while retaining unresolved HASH semantics."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def sha(b):return hashlib.sha256(b).hexdigest()


def review(manifest_bytes,r):
    m=json.loads(manifest_bytes);issues=[];observations=[]
    def check(ok,why):
        if not ok:issues.append(why)
    check(r.get('manifest_sha256')==sha(manifest_bytes),'manifest mismatch');check(r.get('status')=='completed_requires_review','incomplete run');matches=[j for j in m['jobs'] if j['source_sha256']==r.get('source_sha256')]
    if len(matches)!=1:return {'status':'failed_or_incomplete','issues':issues+['unknown source identity']}
    j=matches[0];i=r.get('inspection',{});check(r.get('asset_hash_matches') and r.get('output_sha256')==j['sha256'] and i.get('sha256')==j['sha256'],'unchanged output bytes not verified');check(i.get('status')=='completed_requires_review' and i.get('enumeration_returned'),'CI inspection incomplete');check(Counter(i.get('ci_names',[]))==Counter(j['expected_names']),'CI export multiplicity mismatch');samples=i.get('constructor_samples',[]);check([s.get('name') for s in samples]==i.get('ci_names',[])[:3],'constructor sample set incomplete/changed')
    for s in samples:
        if s.get('resolved'):continue
        known=s.get('name') in j['known_original_constructor_rejections'] and 'Function does not return a supported type' in s.get('error','');observations.append({'name':s.get('name'),'error':s.get('error'),'classification':'same_original_CI_ABI_rejection' if known else 'unexpected_constructor_rejection'});check(known,'unexpected CI constructor rejection '+str(s.get('name')))
    if j['oracle']:
        check(i.get('oracle_kernel_resolved') and i.get('device') not in (None,'none'),'oracle kernel/device absent');cases=i.get('oracle_cases',[]);check(Counter(c.get('scale') for c in cases)==Counter([0,1]),'scale oracle cases missing/duplicated');pixels=bytes([255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255])
        for c in cases:check(c.get('scale') in (0,1) and c.get('output_created') and c.get('bytes_checked')==16 and c.get('actual_sha256')==sha(pixels if c.get('scale')==1 else bytes(16)),'exact CUIScaleClamp pixel oracle failed')
    else:check(not i.get('oracle_cases'),'uncontracted pixel execution claimed')
    check(r.get('shipped_full_library_execution_verified') is False or r.get('shipped_full_library_execution_verified')==0,'unsupported full-library verification claim')
    return {'status':'failed_or_incomplete' if issues else 'bounded_CI_API_checks_passed_HASH_semantics_unresolved','issues':issues,'source_sha256':j['source_sha256'],'output_sha256':j['sha256'],'integrity_mismatch_records_retained':j['declared_actual_mismatch_count'],'constructor_rejections':observations,'pixel_scope':j['oracle'] or 'not_executed_no_argument_contract','full_library_execution_verified':False,'hash_semantics_resolved':False,'metadata_boundary':('ci_filters loses563public CNST reflection records while AIR retains constant64999; normalization behavior is unverified' if j['source_sha256'].startswith('8236203350a9') else 'No public/private metadata byte changes observed in offline comparison'),'limits':['CI name enumeration/constructors do not establish all-function GPU execution.','Only the explicitly named CoreUI scale contract is rendered; output HASH discrepancy remains recorded and unpatched.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--output',type=Path);a=p.parse_args();r=review(a.manifest.read_bytes(),json.loads(a.report.read_text()));s=json.dumps(r,indent=2)+'\n'
    if a.output:a.output.write_text(s)
    print(s,end='');raise SystemExit(bool(r['issues']))


if __name__=='__main__':main()
