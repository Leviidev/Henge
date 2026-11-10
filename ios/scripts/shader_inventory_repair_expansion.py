#!/usr/bin/env python3
"""Provenance-bound offline retarget of the 23 direct +11 embedded expansion.
No deployment, runtime pipeline claims, or source metadata/hash rewriting.
"""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
from collections import Counter
from concurrent.futures import ThreadPoolExecutor,as_completed
from catalog_metallibs import inspect_metallib
from shader_inventory_repair_pack import pack
from shader_inventory_repair_quartzcore import metadata


def sha(b):return hashlib.sha256(b).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def invoke(cmd,timeout=45):
    try:
        c=subprocess.run(cmd,capture_output=True,text=True,timeout=timeout);return {'command':cmd,'returncode':c.returncode,'stdout':c.stdout,'stderr':c.stderr}
    except subprocess.TimeoutExpired as e:return {'command':cmd,'timeout':timeout,'error':str(e)}
def target_for(version):
    return {(2,6):'air64_v26-apple-ios17.0.0',(2,5):'air64_v25-apple-ios16.0.0',(2,2):'air64_v22-apple-ios13.0.0'}[tuple(version)]
def inventory(r):return Counter((f['name'],f['type_raw'])for f in r['functions'])


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inventory_root',type=Path);a=p.parse_args();root=a.inventory_root.resolve();boundary=root/'sonoma-binary-boundary-01';out=root/'inventory-expansion-02';out.mkdir(exist_ok=True)
    direct=json.loads((boundary/'direct-libraries-catalog.json').read_text())['libraries'];embedded=json.loads((boundary/'findings.json').read_text())['embedded_AIR_libraries'];inputs=[]
    for rec in direct:
        if not rec['in_previous_shipped_catalog']:inputs.append({'sha256':rec['sha256'],'path':str((boundary/'new-direct-artifacts'/(rec['sha256']+'.metallib')).resolve()),'role':'direct_resource','aliases':rec['source_aliases']})
    for rec in embedded:inputs.append({'sha256':rec['sha256'],'path':str((boundary/'embedded'/(rec['sha256']+'.metallib')).resolve()),'role':'AMD_driver_embedded_relevance_unestablished' if any('AMD' in x['image']for x in rec['aliases'])else 'embedded_framework_or_codec','aliases':rec['aliases']})
    save(out/'inputs.json',inputs);rows=[]
    with ThreadPoolExecutor(max_workers=4)as pool:
        for source in inputs:
            raw=Path(source['path']).read_bytes();assert sha(raw)==source['sha256'];rec=inspect_metallib(raw);assert not rec['malformed_records'] and not rec['integrity_mismatches'];folder=out/source['sha256'];folder.mkdir(exist_ok=True);save(folder/'source-catalog.json',rec)
            row=dict(source,header=rec['header'],source_air_regions=rec['air_region_count'],source_functions=len(rec['functions']),modules=[]);rows.append(row)
            if not rec['air_regions']:
                row.update(status='empty_carrier_preserved_no_executable_conversion_needed',candidate=source['path'],candidate_sha256=source['sha256']);save(folder/'result.json',row);continue
            def one(index,region):
                d={'index':index,'source_offset':region['offset'],'source_size':region['size'],'source_sha256':region['sha256'],'function_indices':region['function_indices'],'commands':[]};air=folder/f'{index:04}.source.air';target=folder/f'{index:04}.ios.air';lib=folder/f'{index:04}.metallib';data=raw[region['offset']:region['offset']+region['size']];assert sha(data)==region['sha256'];air.write_bytes(data)
                if index==0:
                    ir=invoke(['/opt/homebrew/opt/llvm/bin/llvm-dis',str(air),'-o','-']);(folder/'first-module.ll').write_text(ir.get('stdout',''));d['source_target_triples']=re.findall(r'target triple = "([^"]+)"',ir.get('stdout',''));d['target_evidence_scope']='first module only; full library declared target recorded separately'
                versions={tuple(rec['functions'][j]['air_version'])for j in region['function_indices']};assert len(versions)==1;selected_target=target_for(next(iter(versions)));d['selected_target']=selected_target
                for cmd in [['xcrun','--sdk','iphoneos','metal','-x','ir','-c',str(air),'-target',selected_target,'-o',str(target)],['xcrun','--sdk','iphoneos','metallib',str(target),*(['--cikernel']if rec['header']['library_type_raw']==1 else []),'-o',str(lib)]]:
                    run=invoke(cmd);d['commands'].append(run)
                    if run.get('returncode')!=0:d['status']='compile_or_link_failed';return d
                b=lib.read_bytes();got=inspect_metallib(b);wanted=[rec['functions'][i]for i in region['function_indices']];same=Counter((f['name'],f['type_raw'])for f in wanted)==inventory(got);d.update(output_sha256=sha(b),output_path=str(lib),retargeted_air_sha256=sha(target.read_bytes()),function_inventory_preserved=same,malformed_records=got['malformed_records'],integrity_mismatches=got['integrity_mismatches'],metadata=[])
                if same:
                    for f,g in zip(wanted,got['functions']):
                        m={'name':f['name']}
                        for k in ['public_metadata','private_metadata']:
                            try:
                                before=metadata(raw,rec,f,k);after=metadata(b,got,g,k);m[k]={'source_sha256':sha(before),'output_sha256':sha(after),'bytes_equal':before==after,'payload_bytes_equal':before[4:]==after[4:]}
                            except Exception as e:m[k]={'error':str(e),'payload_bytes_equal':None}
                        d['metadata'].append(m)
                d['status']='structural_inventory_preserved' if same and not got['malformed_records'] else 'structural_or_inventory_failure';return d
            tasks=[pool.submit(one,i,region)for i,region in enumerate(rec['air_regions'])]
            row['modules']=[f.result()for f in as_completed(tasks)];row['modules'].sort(key=lambda x:x['index'])
            if any(m['status']!='structural_inventory_preserved'for m in row['modules']):row['status']='module_failure_retained_no_complete_candidate'
            else:
                paths=[Path(m['output_path'])for m in row['modules']]
                try:
                    if rec['header']['library_type_raw']==1:
                        assert len(paths)==1,'CI multiregion archive needs explicit link review';blob=paths[0].read_bytes();provenance={'mode':'Apple metallib --cikernel','integrity_review_required':True}
                    else:blob,provenance=pack(paths,allowed_format_versions=(tuple(inspect_metallib(paths[0].read_bytes())['header']['format_version']),))
                    candidate=folder/'candidate.metallib';candidate.write_bytes(blob);got=inspect_metallib(blob);assert inventory(got)==inventory(rec);assert got['header']['library_type_raw']==rec['header']['library_type_raw'];save(folder/'candidate-catalog.json',got);save(folder/'candidate-provenance.json',provenance);row.update(candidate=str(candidate),candidate_sha256=sha(blob),candidate_header=got['header'],candidate_air_regions=got['air_region_count'],candidate_functions=len(got['functions']),integrity_mismatches=got['integrity_mismatches'],status='candidate_integrity_review_required'if got['integrity_mismatches']else 'candidate_structural_inventory_preserved')
                except Exception as e:row.update(status='pack_failure',error=str(e))
            save(folder/'result.json',row);save(out/'results.json',rows);print(source['sha256'][:12],row['status'],len(row['modules']),flush=True)
    save(out/'results.json',rows)
if __name__=='__main__':main()
