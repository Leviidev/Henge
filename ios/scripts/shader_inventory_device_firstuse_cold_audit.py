#!/usr/bin/env python3
"""Offline independent cold-chain audit of retained first-use evidence."""
import argparse
import base64
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shutil
import uuid
from catalog_metallibs import inspect_metallib
from shader_inventory_device_firstuse_review import review


def sha(data):return hashlib.sha256(data).hexdigest()
def read(p):return json.loads(p.read_text())
def ref(p):return {'path':str(p.resolve()),'sha256':sha(p.read_bytes()),'byte_size':p.stat().st_size}


def audit(root,tile_report,tile_readback):
    evidence=root/'live-evidence';art=evidence/'device-artifacts';out=evidence/'worker-cold-audit';out.mkdir(exist_ok=True)
    before=read(evidence/'device-before.json');host_before=read(evidence/'host-before.json');after=read(evidence/'device-after-cold.json');start=read(evidence/'capture-start.json');log=(evidence/'cold.log').read_text();lines=log.splitlines();manifest_bytes=(root/'NativeResources/firstuse-manifest.json').read_bytes();manifest=json.loads(manifest_bytes);nonce=manifest['nonce'];issues=[]
    def check(ok,why):
        if not ok:issues.append(why)
    check(after['nonce']==nonce,'after snapshot nonce mismatch');check(log==after['log'],'log differs from retained after snapshot');check(before['captured_unix']<start['captured_unix'] and host_before['captured_unix']<start['captured_unix']<after['captured_unix'],'snapshot timing order invalid')
    after_files={f['path']:f for f in after['files']};before_paths=[f['path'] for f in before['files']];host_before_paths=[f['path'] for f in host_before['files']]
    for f in after['files']:
        p=art/f['path'];check(p.is_file(),'missing downloaded '+f['path'])
        if p.is_file():check(sha(p.read_bytes())==f['sha256'] and len(p.read_bytes())==f['size'] and p.read_bytes()==base64.b64decode(f['data_base64']),'download/snapshot mismatch '+f['path'])
    lease=read(art/'shader-compiler.json');config=read(art/'shader-compiler-config.json');before_lease=next(f['content'] for f in before['files'] if f['path']=='shader-compiler.json');before_config=next(f['content'] for f in before['files'] if f['path']=='shader-compiler-config.json');check(lease==before_lease and config==before_config,'lease/config identity changed across cold interval');recipe=lease['recipe'];check(recipe==after['recipe'] and all(config[k]==lease[k] for k in config),'recipe/config mismatch')
    source_ids=after['source_ids'];check(len(source_ids)==len(set(source_ids))==7,'expected seven distinct driver libraries');rows=[];source_names=[];request_ids=[];hostroot=Path(host_before['root']);hostcopy=out/'host-artifacts'/recipe;hostcopy.mkdir(parents=True,exist_ok=True)
    for ident in source_ids:
        row_issues_start=len(issues);source=art/('sonoma-guestlib-'+ident+'.metallib');request=art/'shader-requests-v2'/(ident+'.json');receipt=art/'shader-cache'/recipe/(ident+'.json');output=receipt.with_suffix('.metallib');req=read(request);ready=read(receipt);raw=source.read_bytes();converted=output.read_bytes();sr=inspect_metallib(raw);cr=inspect_metallib(converted);names=[f['name'] for f in sr['functions']];source_names.extend(names)
        check(sha(raw)==ident,ident+': source digest mismatch');check(not sr['malformed_records'] and not sr['integrity_mismatches'] and sr['air_region_count']==1 and len(names)==1 and all(nonce in n for n in names),ident+': source structure/function nonce mismatch');check(not cr['malformed_records'] and not cr['integrity_mismatches'] and Counter((f['name'],f['type_raw']) for f in sr['functions'])==Counter((f['name'],f['type_raw']) for f in cr['functions']),ident+': output structure/inventory mismatch');check(cr['header']['target_os']=='iOS' and cr['header']['target_os_version']==[17,0],ident+': output target not iOS17')
        device_hits=[p for p in before_paths if ident in p];host_hits=[p for p in host_before_paths if ident in p];check(not device_hits and not host_hits,ident+': source key existed before')
        for key in ['protocol','target','recipe','owner','request','sha256']:check(req.get(key)==ready.get(key),ident+': request/receipt '+key+' mismatch')
        check(req.get('sha256')==ident and req.get('protocol')==2 and req.get('target')=='air64-apple-ios17.0.0' and req.get('recipe')==recipe and req.get('owner')==lease['owner'],ident+': request identity mismatch')
        try:uuid.UUID(req['request']);uuid.UUID(req['owner'])
        except (ValueError,KeyError):check(False,ident+': malformed request/owner UUID')
        request_ids.append(req.get('request'));check(ready.get('status')=='ready' and ready.get('length')==len(converted) and ready.get('output_sha256')==sha(converted),ident+': ready output mismatch')
        hp=hostroot/recipe/(ident+'.metallib');hm=hostroot/recipe/(ident+'.json');hb=hp.read_bytes();metadata=read(hm);check(hb==converted and metadata.get('sha256')==ident and metadata.get('recipe')==recipe and metadata.get('output_sha256')==sha(converted),ident+': Mac/device converted outputs disagree');shutil.copyfile(hp,hostcopy/hp.name);shutil.copyfile(hm,hostcopy/hm.name)
        reqtime=after_files[str(request.relative_to(art))]['mtime_ns']/1e9;readytime=after_files[str(receipt.relative_to(art))]['mtime_ns']/1e9;check(start['captured_unix']<reqtime<=readytime<=after['captured_unix'],ident+': request/ready outside captured cold interval')
        first=[(i+1,l) for i,l in enumerate(lines) if 'shader-broker: first use '+ident+' ' in l];done=[(i+1,l) for i,l in enumerate(lines) if 'shader-broker: ready '+ident+' ' in l];check(len(first)==len(done)==1 and first[0][0]<done[0][0],ident+': first-use/ready log count/order invalid');latency=float(re.search(r'after ([0-9.]+)s',done[0][1]).group(1)) if done else None
        check(latency is not None and abs(latency-(readytime-reqtime))<0.15,ident+': receipt/log latency inconsistent')
        pipeline_events=[];pipelines=[]
        if names and names[0].startswith('tile_'):
            for p in (art/'shader-pipeline-audit').glob('*.json'):
                record=read(p);bindings=base64.b64decode(record['bindings_data_base64']);blob=p.with_suffix('.bin').read_bytes()
                if not any(f.get('library_identity')==ident+':ios-air' for f in record['function_refs'].values()):continue
                check(json.loads(bindings)==record['function_refs'] and sha(blob)==record['blob_sha256'] and len(blob)==record['byte_size'] and sha((sha(blob)+'\n').encode()+bindings)==record['sha256']==p.stem,ident+': pipeline descriptor/bindings identity mismatch');check(record['tag']==51 and record['state_created'] and not record['pipeline_error'],ident+': tile pipeline not created');check(all(f['name'] in names and f['function_type']==3 for f in record['function_refs'].values()),ident+': tile pipeline function identity mismatch');check(str(p.relative_to(art)) not in start['pipeline_paths_before'],ident+': pipeline already captured before');events=[(i+1,l) for i,l in enumerate(lines) if 'captured pipeline audit '+p.stem+' tag=51 created=1' in l];check(len(events)==1 and done and events[0][0]>done[0][0],ident+': tile pipeline log missing/out of order');pipeline_events+=events;pipelines.append({'descriptor':ref(p),'raw_blob':ref(p.with_suffix('.bin')),'record':record})
            check(len(pipelines)==1,ident+': unique tile pipeline audit not established')
        else:
            for state in ['created','queried','completed']:
                events=[(i+1,l) for i,l in enumerate(lines) if 'compute '+state+' function='+names[0]+' library='+ident+':ios-air' in l];check(len(events)==1 and done and events[0][0]>done[0][0],ident+': compute '+state+' route missing/out of order');pipeline_events+=events
            check([e[0] for e in pipeline_events]==sorted(e[0] for e in pipeline_events),ident+': compute event order invalid')
        rows.append({'source_id':ident,'function_names':names,'classification':'uncached_conversion_selected_and_executed' if len(issues)==row_issues_start else 'chain_failed','source':ref(source),'source_header':sr['header'],'source_air_regions':sr['air_regions'],'output':ref(output),'output_header':cr['header'],'output_air_regions':cr['air_regions'],'request':req,'request_artifact':ref(request),'ready_receipt':ready,'ready_artifact':ref(receipt),'host_output_copy':ref(hostcopy/hp.name),'host_metadata_copy':ref(hostcopy/hm.name),'before_device_matches':device_hits,'before_host_matches':host_hits,'request_unix_mtime':reqtime,'ready_unix_mtime':readytime,'receipt_elapsed_seconds':readytime-reqtime,'logged_ready_seconds':latency,'broker_events':[{'line':i,'text':l} for i,l in first+done],'pipeline_events':[{'line':i,'text':l} for i,l in pipeline_events],'tile_pipeline_audits':pipelines,'issues':issues[row_issues_start:]})
    check(len(set(request_ids))==7,'request UUID reuse across sources');expected_names=Counter({manifest['names']['basic']:1,manifest['names']['alpha']:2,manifest['names']['beta']:2,manifest['names']['static_consumer']:1,manifest['names']['tile']:1});check(Counter(source_names)==expected_names,'unexpected cold source function multiplicity')
    reports=[]
    for case in manifest['allowed_cases']:
        p=tile_report if case=='tile' else root/'guest-results'/case/'firstuse-report.json';r=read(p);checked=review(manifest_bytes,r);check(not checked['issues'],case+': independent execution review failed');check(r['selected_case']==case and 'Paravirtual' in r.get('device',''),case+': wrong case/device report');reports.append({'report':ref(p),'review':checked,'run_id':r['run_id']})
        if case=='tile':
            raw=tile_readback.read_bytes();e=r['result']['results'][0]['tile_execution'];check(len(raw)==1024 and sha(raw)==e['actual_sha256'],'raw guest tile readback differs from reviewed report')
    archive_ids=set(manifest['asset_sha256'].values());check(not set(source_ids)&archive_ids,'unexpected input archive/source key identity requires explicit review')
    limits=['Cold proof applies to seven driver-serialized single-function, single-AIR libraries, not conversion of the two-module packed input container.','Four specialized source hashes comprise two alpha and two beta instances. Exact false/true outputs are independently verified; receipt/log records do not encode the bool mode, so per-hash mode assignment is not asserted.','Static helper and consumer are linked offline into one executable AIR region before guest use; this is not runtime dynamic linking.','Request function is (library load); nonce function attribution comes from parsed captured libraries and pipeline identities, not the request function field.','Compute route and GPU completion have six log identities; only tile has a full descriptor+binding capture. Guest exact readback independently validates every bounded case.','Snapshots establish absence in the inventoried device and Mac cache paths at recorded before times; they are not a filesystem-wide or continuous adversarial audit.','File mtimes provide wall-clock ordering and log entries provide ordered events plus wait durations; individual broker log lines have no absolute timestamp.','No cached repeat is established by this cold audit. Guest dynamic-library APIs remain separately unsupported.','No shipped-function correctness, arbitrary shader compatibility, or broad multi-module converter support follows.']
    result={'status':'cold_first_use_conversion_chain_verified' if not issues else 'failed_or_incomplete','issues':issues,'nonce':nonce,'actual_serialized_source_count':len(rows),'original_input_assets':manifest['asset_sha256'],'guest_compute_values_exact':1536,'guest_tile_pixels_exact':256,'guest_tile_readback':ref(tile_readback),'recipe':recipe,'owner':lease['owner'],'snapshots':{n:ref(evidence/n) for n in ['device-before.json','host-before.json','capture-start.json','device-after-cold.json','cold.log']},'snapshot_times':{'device_before':before['captured_unix'],'host_before':host_before['captured_unix'],'capture_start':start['captured_unix'],'device_after':after['captured_unix']},'device_before_file_count':len(before_paths),'host_before_file_count':len(host_before_paths),'lease':lease,'config':config,'source_chains':rows,'guest_reports':reports,'limits':limits,'device_accessed_by_auditor':False}
    (out/'evidence-index.json').write_text(json.dumps(result,indent=2)+'\n');return result


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('kit',type=Path);p.add_argument('--tile-report',type=Path,required=True);p.add_argument('--tile-readback',type=Path,required=True);a=p.parse_args();r=audit(a.kit.resolve(),a.tile_report.resolve(),a.tile_readback.resolve());print(json.dumps({'status':r['status'],'source_count':r['actual_serialized_source_count'],'issues':r['issues']},indent=2));raise SystemExit(bool(r['issues']))


if __name__=='__main__':main()
