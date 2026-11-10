#!/usr/bin/env python3
"""Review bounded authored path matrix; preserve negative observations explicitly."""
from collections import Counter
import hashlib
import json
import struct


def sha(data):return hashlib.sha256(data).hexdigest()


def review_path(manifest_bytes,report):
    manifest=json.loads(manifest_bytes);issues=[];observed=[];gaps=[]
    def check(value,message):
        if not value:issues.append(message)
    def exact(row,base,mul,add):
        e=row.get('execution',{});expected=b''.join(struct.pack('<I',base+mul*i+add) for i in range(256))
        return bool(e.get('dispatch_completed') and e.get('elements_checked')==256 and e.get('mismatches')==0 and e.get('actual_sha256')==sha(expected))
    check(report.get('manifest_sha256')==sha(manifest_bytes),'manifest digest mismatch')
    check(report.get('status')=='complete_results_require_review','incomplete or exceptional run')
    check(report.get('stage')=='controls' and report.get('jobs')==[],'unexpected stage or candidate results')
    check(report.get('shipped_kernels_dispatched') in (False,0),'unexpected shipped dispatch claim')
    check(set(report.get('asset_verification',{}))==set(manifest['asset_sha256']) and all(report.get('asset_verification',{}).values()),'pinned asset verification incomplete')
    packed=report.get('packed_control',{});cases=packed.get('cases',[])
    check(packed.get('asset_hash_matches') and packed.get('library_loaded'),'packed bytes or library not verified')
    check(Counter((c.get('name'),c.get('mode')) for c in cases)==Counter((n,m) for n in ('alpha','beta') for m in (0,1)),'packed specialization matrix incomplete/duplicated')
    for c in cases:
        name,mode=c.get('name'),c.get('mode')
        if name in ('alpha','beta') and mode in (0,1):check(c.get('function_created') and c.get('pipeline_created') and exact(c,1000 if name=='alpha' else 2000,1,100*mode),f'packed {name}/{mode}: exact execution not established')
    dynamic=report.get('dynamic_control',{});rows=dynamic.get('cases',[]);unsupported=dynamic.get('supports_dynamic_libraries') in (False,0);attempt=bool(dynamic.get('attempt_unadvertised_dynamic'))
    check(dynamic.get('control_route')=='path_resolution_matrix_v4','wrong dynamic report shape/route')
    if unsupported and not attempt:
        check(rows==[] and dynamic.get('dynamic_status')=='not_attempted_advertised_unsupported','unsupported dynamic route unexpectedly attempted or malformed')
        gaps.append('Advertised dynamic libraries unsupported; no dynamic API cases executed. Packed execution does not prove dynamic support.')
        status='packed_exact_dynamic_unsupported'
    else:
        check(bool(dynamic.get('supports_dynamic_libraries')) or attempt,'dynamic capability or explicit unadvertised attempt missing')
        expected={c['id']:c for c in manifest['controls']['dynamic']['cases']}
        check(Counter(r.get('id') for r in rows)==Counter(expected.keys()),'dynamic case matrix incomplete/duplicated')
        for row in rows:
            spec=expected.get(row.get('id'))
            if not spec:continue
            ident=spec['id'];kind=spec['kind'];check(row.get('kind')==kind and row.get('gate')==spec['gate'],ident+': route identity changed')
            check(row.get('asset_hash_matches'),ident+': pinned assets not verified')
            success=all(row.get(k) for k in ('library_loaded','dynamic_created','consumer_library_created','consumer_function_created','consumer_pipeline_created')) and exact(row,0,7,19)
            if not success:
                observed.append({'id':ident,'status':row.get('dynamic_status'),'gate':spec['gate'],'evidence':row})
                if spec['gate']!='diagnostic_preserve_failure_or_success':issues.append(ident+': required API/pipeline/exact execution failed')
                else:check(row.get('library_loaded') and row.get('dynamic_created') and row.get('consumer_library_created') and row.get('consumer_function_created') and row.get('dynamic_status')=='consumer_pipeline_rejected' and bool(row.get('pipeline_error')),ident+': baseline failure was not the bounded pipeline observation')
            if row.get('consumer_pipeline_created'):check(exact(row,0,7,19),ident+': pipeline accepted but readback failed')
            if kind=='loader_file':check(row.get('shared_origin')=='file_url' and row.get('consumer_origin')=='file_url' and row.get('install_name')=='@loader_path/dynamic-loader.metallib' and row.get('preloaded_library_count')==0,ident+': file loader route missing')
            elif kind=='absolute_source':check(row.get('shared_origin')=='runtime_source' and row.get('consumer_origin')=='runtime_source' and row.get('serialized') and bool(row.get('serialized_sha256')) and row.get('install_name','').startswith('/') and row.get('install_name')==row.get('requested_install_name') and row.get('preloaded_library_count')==0,ident+': absolute serialized route missing')
            elif kind=='preloaded_only':check(row.get('consumer_origin')=='runtime_source' and row.get('allow_undefined_symbols') and row.get('compile_library_count')==0 and row.get('preloaded_library_count')==1,ident+': preloaded-only route missing')
            elif kind=='relative_source':check(row.get('shared_origin')=='file_url' and row.get('consumer_origin')=='runtime_source' and row.get('preloaded_library_count')==1,ident+': relative baseline route missing')
        if unsupported:gaps.append('Explicit unadvertised API attempt; advertised capability remains false regardless of this authored result.')
        status='qualified_paths_exact_with_observed_baseline_failure' if observed else 'all_authored_path_oracles_exact'
        if unsupported:status='unadvertised_'+status
    gaps.append('Authored path controls are not shipped dependency, first-use broker conversion, or shipped pixel proof.')
    return {'status':'failed_or_incomplete' if issues else status,'stage':'controls','issues':issues,'observed_failures':observed,'open_checks':gaps,'shipped_execution_verified':False,'report_shape':'path_resolution_matrix_v4'}
