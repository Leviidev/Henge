#!/usr/bin/env python3
"""Validate helper evidence without upgrading load checks to execution claims."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct


def digest(data):return hashlib.sha256(data).hexdigest()


def review(manifest_bytes, report):
    manifest=json.loads(manifest_bytes)
    if manifest.get("control_route")=="path_resolution_matrix_v4":
        from shader_inventory_device_path_review import review_path
        return review_path(manifest_bytes,report)
    issues=[];open_checks=[]
    def check(condition, reason):
        if not condition:issues.append(reason)
    check(report.get('manifest_sha256')==digest(manifest_bytes),'manifest digest mismatch')
    check(report.get('status')=='complete_results_require_review','incomplete, timed out, or exceptional run')
    check(report.get('shipped_kernels_dispatched') is False or report.get('shipped_kernels_dispatched')==0,'unexpected shipped dispatch claim')
    stage=report.get('stage');check(stage in manifest['allowed_stages'],'unknown stage')
    if stage=='controls':
        packed=report.get('packed_control',{});cases=packed.get('cases',[])
        check(packed.get('asset_hash_matches') and packed.get('library_loaded'),'packed control did not load hash-checked bytes')
        check(Counter((c.get('name'),c.get('mode')) for c in cases)==Counter((name,mode) for name in ('alpha','beta') for mode in (0,1)), 'specialization matrix incomplete/duplicated')
        for c in cases:
            name,mode=c.get('name'),c.get('mode');execution=c.get('execution',{})
            if name not in ('alpha','beta') or mode not in (0,1):continue
            expected=b''.join(struct.pack('<I',(1000 if name=='alpha' else 2000)+100*mode+i) for i in range(256))
            check(c.get('function_created') and c.get('pipeline_created'),f'{name}/{mode}: specialization or pipeline failed')
            check(execution.get('dispatch_completed') and execution.get('elements_checked')==256 and execution.get('mismatches')==0 and execution.get('actual_sha256')==digest(expected),f'{name}/{mode}: exact execution oracle failed')
        dynamic=report.get('dynamic_control',{})
        unsupported=dynamic.get('supports_dynamic_libraries') in (False,0)
        unadvertised=bool(dynamic.get('attempt_unadvertised_dynamic'))
        if unsupported and not unadvertised:
            check(bool(dynamic.get('asset_hash_matches')),'unsupported dynamic control assets were not verified')
            check(not dynamic.get('execution'),'unsupported dynamic control unexpectedly claims execution')
            open_checks.append('Device advertises supportsDynamicLibraries=false; dynamic-object creation/consumer linking/execution were not attempted. This is a coverage gap, not a shader failure or dynamic pass.')
            status='authored_packed_control_exact_dynamic_unsupported' if not issues else 'failed_or_incomplete'
        else:
            for key in ('asset_hash_matches','library_loaded','dynamic_created','consumer_library_created','consumer_function_created','consumer_pipeline_created'):
                check(bool(dynamic.get(key)),f'dynamic control: {key} not established')
            check(bool(dynamic.get('supports_dynamic_libraries')) or unadvertised,'unadvertised API attempt not explicit')
            execution=dynamic.get('execution',{});expected=b''.join(struct.pack('<I',i*7+19) for i in range(256))
            check(execution.get('dispatch_completed') and execution.get('elements_checked')==256 and execution.get('mismatches')==0 and execution.get('actual_sha256')==digest(expected),'dynamic linked execution oracle failed')
            expected_route=manifest.get('controls',{}).get('dynamic',{}).get('dynamic_loading_route')
            if expected_route:
                check(dynamic.get('dynamic_loading_route')==expected_route and dynamic.get('consumer_loading_route')==manifest['controls']['dynamic']['consumer_loading_route'],'dynamic control loading route not established')
            if unsupported:
                open_checks.append('Explicit authored API attempt while advertised capability remains false; do not upgrade production capability from this result.')
                status='authored_controls_exact_unadvertised_dynamic' if not issues else 'unadvertised_dynamic_attempt_rejected_or_failed'
            else:status='authored_controls_exact' if not issues else 'failed_or_incomplete'
    elif stage in ('libraries','pipelines'):
        selected=report.get('selection','');jobs={j['id']:j for j in manifest['jobs'] if not selected or j['id'].startswith(selected)}
        check(not selected or len(jobs)==1,'ambiguous candidate selection')
        actual=report.get('jobs',[]);check(Counter(r.get('id') for r in actual)==Counter(jobs.keys()),'candidate result set incomplete/duplicated')
        for row in actual:
            job=jobs.get(row.get('id'))
            if job is None:continue
            ident=job['id'][:12]
            check(row.get('sha256')==job['sha256'] and row.get('source_sha256')==job['source_sha256'],f'{ident}: artifact identity changed')
            check(row.get('asset_hash_matches') and row.get('library_loaded'),f'{ident}: library did not load verified bytes')
            check(row.get('actual_library_type')==(1 if job['library_type']==2 else 0),f'{ident}: wrong Metal library type')
            check(Counter(row.get('actual_function_names',[]))==Counter(f['name'] for f in job['expected_functions']),f'{ident}: native name multiplicity mismatch')
            check(row.get('execution_status')=='not_tested_no_argument_contract' and not row.get('pixel_verified'),f'{ident}: unsupported execution claim')
            if job['library_type']==2:
                check(row.get('dynamic_created'),f'{ident}: dynamic object creation not established')
                open_checks.append(f'{ident}: no shipped consumer linking/execution contract')
            elif stage=='pipelines':
                functions=row.get('functions',[])
                check(Counter(f.get('name') for f in functions)==Counter(f['name'] for f in job['pipeline_samples']),f'{ident}: pipeline sample set incomplete')
                for f in functions:
                    check(f.get('function_created') and f.get('actual_type')==3,f'{ident}/{f.get("name")}: kernel creation/type failed')
                    if f.get('pipeline_status')=='not_tested_required_constants_without_contract':
                        check(any(c.get('required') for c in f.get('constants',[])),f'{ident}: skipped pipeline without required constant evidence')
                        open_checks.append(f'{ident}/{f.get("name")}: required constants lack contract')
                    else:check(f.get('pipeline_created'),f'{ident}/{f.get("name")}: pipeline creation not established')
                open_checks.append(f'{ident}: unsampled functions and shipped execution remain untested')
            else:open_checks.append(f'{ident}: pipelines and shipped execution remain untested')
        status='bounded_checks_passed_with_open_contracts' if not issues else 'failed_or_incomplete'
    else:status='failed_or_incomplete'
    return {'status':status,'stage':stage,'issues':issues,'open_checks':open_checks,'shipped_execution_verified':False,
            'scope':'Evidence applies only to exact manifest and stage; authored controls are not shipped-function or pixel proof.'}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--output',type=Path)
    a=p.parse_args();result=review(a.manifest.read_bytes(),json.loads(a.report.read_text()));text=json.dumps(result,indent=2)+'\n'
    if a.output:a.output.write_text(text)
    print(text,end='');raise SystemExit(bool(result['issues']))


if __name__=='__main__':main()
