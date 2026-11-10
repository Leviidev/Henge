#!/usr/bin/env python3
"""Join artifact inventories and observed runtime evidence without implying full coverage."""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
import hashlib
from pathlib import Path
import re


def device_evidence(result_path, manifest_path):
    if not result_path and not manifest_path:
        return {}, {}
    if not result_path or not manifest_path:
        raise ValueError('Device evidence requires both result and manifest paths')
    data=manifest_path.read_bytes();manifest=json.loads(data);report=json.loads(result_path.read_text())
    if report['manifest_sha256']!=hashlib.sha256(data).hexdigest() or report['status']!='complete':
        raise ValueError('Device evidence is incomplete or bound to another manifest')
    jobs={x['source_sha256']:x for x in manifest['jobs']}
    seen=set();functions={}
    for item in report['results']:
        digest=item['source_sha256']
        if digest in seen or digest not in jobs:
            raise ValueError('Duplicate or unexpected device result identity')
        seen.add(digest);job=jobs[digest]
        if item.get('sha256')!=job['sha256']:
            raise ValueError('Device evidence does not match shader bytes')
        expected={(f['name'],f['type_raw']) for f in job['functions']}
        for f in item['functions']:
            if (f['name'],f['declared_type']) not in expected:
                raise ValueError('Unexpected device function identity')
            functions[(digest,f['name'])]=f
    if seen!=set(jobs):
        raise ValueError('Missing device results')
    return report,functions


def render_evidence(result_path, manifest_path):
    if not result_path and not manifest_path:return {},{}
    if not result_path or not manifest_path:raise ValueError('Render evidence requires a result and manifest')
    data=manifest_path.read_bytes();manifest=json.loads(data);report=json.loads(result_path.read_text())
    if report['status']!='complete' or report['manifest_sha256']!=hashlib.sha256(data).hexdigest():
        raise ValueError('Render evidence is incomplete or stale')
    expected={c['sha256']:c for c in manifest['render_cases']}
    jobs={j['source_sha256']:j for j in manifest['jobs']};seen=set();functions=defaultdict(list)
    for case in report['render_cases']:
        identity=case['sha256']
        if identity not in expected or identity in seen:raise ValueError('Unexpected or duplicate render case')
        seen.add(identity)
        if case['status']!='pipeline_created':continue
        refs=expected[identity]['function_refs'];bound=set()
        for binding in case['bindings']:
            ref=binding['ref'];source=binding['source_sha256'];name=binding['name']
            if ref in bound or ref not in refs:raise ValueError('Unexpected render reference')
            if (refs[ref]['library_identity'].split(':')[0]!=source or refs[ref]['name']!=name
                    or jobs[source]['sha256']!=binding['output_sha256']):
                raise ValueError('Render binding does not match the captured shader identity')
            bound.add(ref)
            if identity not in functions[(source,name)]:functions[(source,name)].append(identity)
        if bound!=set(refs):raise ValueError('Incomplete successful render bindings')
    if seen!=set(expected):raise ValueError('Missing render results')
    return report,functions


def build(root, batch_results=None, module_results=None, device_results=None, device_manifest=None,
          render_results=None, render_manifest=None):
    shipped=json.loads((root/'shipped/catalog.json').read_text())
    native=json.loads((root/'shipped/shipped-libraries.json').read_text())
    captured=json.loads((root/'runtime-current/catalog.json').read_text())
    cached=json.loads((root/'device-conversions.json').read_text())
    batch=json.loads(batch_results.read_text()) if batch_results else []
    batch_by_hash={x['source_sha256']:x for x in batch}
    device,device_functions=device_evidence(device_results,device_manifest)
    rendered,render_functions=render_evidence(render_results,render_manifest)
    modules=json.loads(module_results.read_text()) if module_results else []
    module_by_function={}
    for item in modules:
        for index,expected in zip(item['function_indices'],item['expected_functions']):
            module_by_function[(item['source_library_sha256'],index)]=(item,expected)
    comparison_path=root.parent/'image-effects-audit/guest-final/comparison.json'
    repeatability_path=root.parent/'image-effects-audit/guest-final/repeatability.json'
    comparison=json.loads(comparison_path.read_text())
    repeatability=json.loads(repeatability_path.read_text())
    effect_counts=Counter(x['status'] for x in comparison['results'])
    ipad_comparison_path=root/'native-ipad-effects-01/guest-comparison.json'
    ipad_comparison=json.loads(ipad_comparison_path.read_text()) if ipad_comparison_path.exists() else None
    native_by_hash={x['sha256']:x for x in native['libraries']}
    installed={x['source_sha256']:x for x in cached['libraries']}
    observations=defaultdict(lambda: {'compute':set(),'rejections':0})
    log=(root/'current-runtime.log').read_text(errors='replace')
    for line in log.splitlines():
        m=re.search(r'compute (created|queried|completed|dispatch-failed) function=(\S+) library=([0-9a-f]{64}):',line)
        if m:observations[(m[3],m[2])]['compute'].add(m[1])
        if 'rejected compute state' in line or 'rejected render state' in line:
            for name,digest in re.findall(r'(?:function|vertex|fragment)=(\S+) library=([0-9a-f]{64}):',line):
                observations[(digest,name)]['rejections']+=1
    artifacts=[];rows=[]
    shipped_names=defaultdict(set)
    for lib in shipped['libraries']:
        for f in lib['functions']:
            if f.get('name'):shipped_names[f['name']].add(lib['sha256'])
    for origin,catalog in [('shipped',shipped),('captured',captured)]:
        for lib in catalog['libraries']:
            digest=lib['sha256'];n=native_by_hash.get(digest,{}) if origin=='shipped' else {}
            index=len(artifacts)
            artifacts.append({'origin':origin,'sha256':digest,'format':lib.get('format'),
                'size':lib['byte_size'],'paths':n.get('paths',lib['source_paths']),
                'function_records':len(lib['functions']),'runtime_symbols':len(lib.get('symbols',[])),
                'air_regions':lib['air_region_count'],'structural_status':lib['status'],
                'native_metadata_status':n.get('status'),'single_payload_safe':lib['single_payload_extraction_valid'],
                'converted_on_device':origin=='captured' and digest in installed,
                'offline_conversion_status':batch_by_hash.get(digest,{}).get('status') if origin=='shipped' else None,
                'opaque_gpu_slices':sum(s.get('format')!='metallib' for s in lib.get('slices',[]))})
            for f in lib['functions']:
                obs=observations.get((digest,f['name']),{'compute':set(),'rejections':0})
                module,expected=module_by_function.get((digest,f.get('index')),({},{})) if origin=='shipped' else ({},{})
                if expected and (expected['name']!=f['name'] or expected['type_raw']!=f['type_raw']):
                    raise ValueError('Module result does not match the catalogued function identity')
                rows.append({'artifact':index,'name':f['name'],'type':f.get('function_type') or 'unknown',
                    'source_function_index':f.get('index'),'module_link_status':module.get('status'),
                    'device_function_status':device_functions.get((digest,f['name']),{}).get('status') if origin=='captured' else None,
                    'device_pipeline_status':device_functions.get((digest,f['name']),{}).get('pipeline_status') if origin=='captured' else None,
                    'render_pipeline_cases':render_functions.get((digest,f['name']),[]) if origin=='captured' else [],
                    'stage':f.get('shader_stage'),'native_name_listed':f['name'] in n.get('function_names',[]),
                    'compute_observed':sorted(obs['compute']),'rejection_events':obs['rejections'],
                    'same_name_shipped_candidates':sorted(shipped_names.get(f['name'],set())) if origin=='captured' else [],
                    'pixel_verified':False})
            for symbol in lib.get('symbols',[]):
                rows.append({'artifact':index,'name':symbol['name'],'type':'driver-runtime-symbol','stage':None,
                    'native_name_listed':False,'compute_observed':[],'rejection_events':0,
                    'same_name_shipped_candidates':[],'pixel_verified':False})
    capture_hashes={x['sha256'] for x in captured['libraries']}
    missing=[x for x in artifacts if x['origin']=='captured' and not x['converted_on_device']]
    denied=(root/'shipped/shader-search-errors.txt').read_text().splitlines()
    return {'schema':1,'generated_at':datetime.now(timezone.utc).isoformat(),
      'scope':{'guest_os':native['os'],'guest_device':native['device'],
        'searched_roots':['/System/Library','/System/Applications','/Applications','/Library'],
        'extensions':['.metallib','.metalar','.air'],'search_errors':denied,
        'gaps':['Protected directories listed in search_errors were not inspected.',
          'Embedded libraries in executables/dyld shared caches have not been exhaustively scanned.',
          'Eight machine-code GPU slices remain opaque.',
          'Future runtime-generated and function-constant variants cannot be counted by this file inventory.',
          'Static declaration, native metadata load, conversion cache, pipeline creation, dispatch, and pixel correctness are separate gates.',
          'Function-name matches are candidates, not proof of source-library identity.',
          'Runtime logs are cumulative; a recorded rejection may precede a subsequently installed conversion.',
          'Offline conversion inventory checks do not establish preservation of opaque metadata, runtime loading, pipeline creation or correct output.']},
      'summary':{'shipped_paths':len(native['files']),'shipped_unique_artifacts':len(shipped['libraries']),
        'shipped_formats':shipped['summary']['format_counts'],
        'shipped_function_records':sum(len(x['functions']) for x in shipped['libraries']),
        'shipped_runtime_symbols':sum(len(x.get('symbols',[])) for x in shipped['libraries']),
        'shipped_native_function_names':sum(len(x.get('function_names',[])) for x in native['libraries']),
        'shipped_air_regions':sum(x['air_region_count'] for x in shipped['libraries']),
        'shipped_unique_air_contents':len({a['sha256'] for x in shipped['libraries'] for a in x['air_regions']}),
        'shipped_single_payload_safe':sum(x['single_payload_extraction_valid'] for x in shipped['libraries']),
        'captured_unique_libraries':len(captured['libraries']),
        'captured_with_conversion':len(captured['libraries'])-len(missing),
        'captured_missing_conversion':len(missing),
        'installed_conversions_not_in_current_capture_set':len(set(installed)-capture_hashes),
        'exact_container_overlap':len({x['sha256'] for x in shipped['libraries']}&capture_hashes),
        'known_compute_dispatch_identities':sum('completed' in o['compute'] for o in observations.values()),
        'offline_conversion_results':dict(Counter(x['status'] for x in batch)),
        'independent_module_link_results':dict(Counter(x['status'] for x in modules))},
      'artifacts':artifacts,'entries':rows,
      'verification':{'offline_batch_evidence':str(batch_results) if batch_results else None,
        'native_ipad_image_effects':None if ipad_comparison is None else {
            'evidence':str(ipad_comparison_path),'reference_os':ipad_comparison['reference_os'],
            'candidate_os':ipad_comparison['candidate_os'],'threshold_rmse':ipad_comparison['threshold'],
            'cases':len(ipad_comparison['results']),
            'within_tolerance':sum(x['status']=='match' for x in ipad_comparison['results']),
            'byte_exact':sum(x.get('rmse')==0 for x in ipad_comparison['results']),
            'limitation':'Same authored scenes on native iPad Metal. Tolerance passes are not exact matches or exhaustive shader coverage.'},
        'independent_module_evidence':str(module_results) if module_results else None,
        'render_descriptor_replay':{'evidence':str(render_results) if render_results else None,
            'cases':dict(Counter(x['status'] for x in rendered.get('render_cases',[]))),
            'unique_shader_identities':len(render_functions),
            'previously_failed_cases_now_created':sum(x.get('live_state_created') is False and x['status']=='pipeline_created' for x in rendered.get('render_cases',[])),
            'limitation':'Recorded configurations only; pipeline creation is not draw execution or pixel correctness. Legacy capture scope is not exhaustive.'},
        'device_preflight':{'evidence':str(device_results) if device_results else None,
            'device':device.get('device'),'os':device.get('os'),
            'libraries':dict(Counter(x['status'] for x in device.get('results',[]))),
            'functions':dict(Counter(x['status'] for x in device_functions.values())),
            'pipelines':dict(Counter(x.get('pipeline_status') for x in device_functions.values())),
            'compute_control':device.get('compute_control'),'image_control':device.get('image_control'),
            'limitation':'Isolated signed iPad app. Framework shaders were not dispatched; render descriptors and scene pixels remain separate tests.'},
        'image_effects':{'cases':len(comparison['results']),
        'reference_matches':effect_counts['match'],
        'review':len(comparison['results'])-effect_counts['match'],
        'repeatability_matches':sum(x['status']=='match' for x in repeatability['results']),
        'reference_os':comparison['reference_os'],'candidate_os':comparison['candidate_os'],
        'evidence':'../image-effects-audit/guest-final/comparison.json',
        'limitation':'Scene-level results; not attributed to individual library functions.'},
        'fallback_logging':'Enabled in the installed checkpoint; zero allocations in the final effects/HEIC scene.',
        'checkpoint':'../checkpoints/2026-11-09-working-renderer/manifest.json'},
      'next_gates':['Complete remaining inventory boundaries and classify their relevance to the paravirtual Metal path.',
        'Make bulk conversion preserve all declared AIR modules and required linkage; do not use the one-payload converter on multi-module libraries.',
        'Batch conversion and pipeline checks, grouping failures by shared cause.',
        'Pixel/output verification across formats, effects, video and app regression scenes.',
        'General OpenGL/video compatibility; automatic new-variant conversion remains a later complementary task.']}


HTML=r'''<!doctype html><html lang="en"><meta charset="utf-8"><title>Sonoma shader coverage map</title>
<style>body{font:15px system-ui;max-width:1400px;margin:32px auto;padding:0 24px;color:#202633;background:#f6f7f9}h1{font-size:28px}p{line-height:1.5}.cards{display:flex;gap:12px;flex-wrap:wrap}.card{background:white;border:1px solid #d7dce3;padding:16px;min-width:170px;border-radius:8px}.card strong{font-size:27px;display:block}input,select{padding:10px;border:1px solid #aab4c2;border-radius:5px;margin:8px 8px 8px 0}input{min-width:380px}table{border-collapse:collapse;width:100%;background:white;font-size:13px}th,td{text-align:left;padding:9px;border-bottom:1px solid #e0e4e9;vertical-align:top}th{background:#e8edf3;position:sticky;top:0}td:nth-child(2){max-width:470px;overflow-wrap:anywhere}td:nth-child(4){max-width:420px;overflow-wrap:anywhere}small{color:#526172}details{background:white;padding:14px;margin:16px 0;border:1px solid #d7dce3}li{margin:8px 0}.state{color:#705200}.ok{color:#12613b}button{padding:9px 15px;margin:10px 5px 10px 0;cursor:pointer}</style>
<h1>Sonoma shader coverage map</h1><p>This maps the inspected artifacts and observed tests. It is not a claim that every shader or graphics feature works.</p><div class="cards" id="cards"></div>
<details><summary>Scope, evidence and remaining gaps</summary><div id="scope"></div></details>
<p><a href="coverage-map.json">Download complete map (JSON)</a> · <a href="batch-plan.json">Test order and verification gates</a> · Source catalogs retain bounds, hashes, aliases and opaque records.</p>
<input id="q" placeholder="Search function, library path or SHA" aria-label="Search"><select id="origin"><option value="">All sources</option><option value="shipped">Shipped artifacts</option><option value="captured">Runtime captures</option></select><select id="gate"><option value="">All evidence levels</option><option value="missing">Missing runtime conversion</option><option value="dispatch">Compute dispatch observed</option><option value="rejected">Rejection observed</option><option value="driver">Driver runtime symbols</option></select>
<p id="count"></p><table><thead><tr><th>Source</th><th>Function / symbol</th><th>Type</th><th>Library</th><th>Evidence</th></tr></thead><tbody id="rows"></tbody></table><button id="prev">Previous</button><button id="next">Next</button>
<script id="data" type="application/json">__DATA__</script><script>
const d=JSON.parse(document.getElementById('data').textContent),s=d.summary;let page=0,filtered=[];
for(const [label,value] of [['Shipped artifacts',s.shipped_unique_artifacts],['Metal function records',s.shipped_function_records],['Driver runtime symbols',s.shipped_runtime_symbols],['Captured libraries',s.captured_unique_libraries],['Captured with conversion',s.captured_with_conversion],['Captured missing conversion',s.captured_missing_conversion]]){const c=document.createElement('div');c.className='card';const n=document.createElement('strong');n.textContent=value.toLocaleString();c.append(n,document.createTextNode(label));document.getElementById('cards').append(c)}
const scope=document.getElementById('scope'),info=document.createElement('p');info.textContent=d.scope.guest_os+' · '+d.scope.guest_device+' · '+d.scope.search_errors.length+' recorded search errors';scope.append(info);const ul=document.createElement('ul');for(const g of d.scope.gaps){const li=document.createElement('li');li.textContent=g;ul.append(li)}scope.append(ul);const p=document.createElement('p');const v=d.verification.image_effects;p.textContent='Image tests: '+v.cases+' scenes, '+v.reference_matches+' reference matches, '+v.review+' require review; '+v.repeatability_matches+' repeatability matches. These are scene-level checks, not proof for every function.';scope.append(p);const b=document.createElement('p');b.textContent='Offline conversion audit: '+JSON.stringify(d.summary.offline_conversion_results)+'. Outputs have not been deployed or pixel-verified.';scope.append(b);const ml=document.createElement('p');ml.textContent='Independent module linking: '+JSON.stringify(d.summary.independent_module_link_results)+'. This does not replace the whole-library result or establish execution.';scope.append(ml);const dp=document.createElement('p');dp.textContent='iPad preflight: '+JSON.stringify(d.verification.device_preflight.pipelines)+'. '+d.verification.device_preflight.limitation;scope.append(dp);const rp=document.createElement('p');rp.textContent='Recorded render/tile descriptor replay: '+JSON.stringify(d.verification.render_descriptor_replay.cases)+'. '+d.verification.render_descriptor_replay.limitation;scope.append(rp);
const ni=d.verification.native_ipad_image_effects;if(ni){const p=document.createElement('p');p.textContent='Native iPad image reference: '+ni.within_tolerance+'/'+ni.cases+' within RMSE '+ni.threshold_rmse+'; '+ni.byte_exact+' byte-exact. '+ni.limitation;scope.append(p);}
const data=d.entries.map(r=>({...r,a:d.artifacts[r.artifact]}));
function search(){page=0;const q=document.getElementById('q').value.toLowerCase(),o=document.getElementById('origin').value,g=document.getElementById('gate').value;filtered=data.filter(r=>(!o||r.a.origin===o)&&(!q||(r.name+' '+r.a.paths.join(' ')+' '+r.a.sha256).toLowerCase().includes(q))&&(!g||(g==='missing'&&r.a.origin==='captured'&&!r.a.converted_on_device)||(g==='dispatch'&&r.compute_observed.includes('completed'))||(g==='rejected'&&r.rejection_events>0)||(g==='driver'&&r.type==='driver-runtime-symbol')));render()}
function render(){const tbody=document.getElementById('rows');tbody.replaceChildren();for(const r of filtered.slice(page*100,(page+1)*100)){const tr=document.createElement('tr'),e=[];if(r.native_name_listed)e.push('Native name listed');if(r.render_pipeline_cases?.length)e.push('Recorded pipeline configurations passed: '+r.render_pipeline_cases.length);if(r.device_pipeline_status)e.push('iPad: '+r.device_pipeline_status.replaceAll('_',' '));else if(r.device_function_status)e.push('iPad: '+r.device_function_status.replaceAll('_',' '));if(r.module_link_status)e.push('Module: '+r.module_link_status.replaceAll('_',' '));if(r.a.offline_conversion_status)e.push('Offline: '+r.a.offline_conversion_status.replaceAll('_',' '));if(r.a.converted_on_device)e.push('Conversion cached');if(r.compute_observed.includes('completed'))e.push('Compute dispatch completed');if(r.rejection_events)e.push('Rejection recorded: '+r.rejection_events);if(!e.length)e.push('Parsed only');for(const v of [r.a.origin,r.name,r.type,r.a.paths[0],e.join(' · ')]){const td=document.createElement('td');td.textContent=v;tr.append(td)}tr.title=r.a.sha256+'\n'+r.a.paths.join('\n');tbody.append(tr)}document.getElementById('count').textContent=filtered.length.toLocaleString()+' matching entries · page '+(page+1)+' of '+Math.max(1,Math.ceil(filtered.length/100));document.getElementById('prev').disabled=page===0;document.getElementById('next').disabled=(page+1)*100>=filtered.length}
for(const id of ['q','origin','gate'])document.getElementById(id).addEventListener('input',search);document.getElementById('prev').onclick=()=>{page--;render()};document.getElementById('next').onclick=()=>{page++;render()};search();
</script></html>'''


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inventory_root',type=Path);p.add_argument('--batch-results',type=Path);p.add_argument('--module-results',type=Path);p.add_argument('--device-results',type=Path);p.add_argument('--device-manifest',type=Path);p.add_argument('--render-results',type=Path);p.add_argument('--render-manifest',type=Path);args=p.parse_args()
    result=build(args.inventory_root,args.batch_results,args.module_results,args.device_results,args.device_manifest,args.render_results,args.render_manifest)
    (args.inventory_root/'coverage-map.json').write_text(json.dumps(result,indent=2)+'\n')
    payload=json.dumps(result,separators=(',',':')).replace('<','\\u003c').replace('>','\\u003e').replace('&','\\u0026')
    (args.inventory_root/'coverage-map.html').write_text(HTML.replace('__DATA__',payload))
    print(json.dumps(result['summary'],indent=2))


if __name__=='__main__':main()
