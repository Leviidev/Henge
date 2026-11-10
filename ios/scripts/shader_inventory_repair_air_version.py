#!/usr/bin/env python3
"""Repair demonstrated target-architecture/AIR metadata mismatch without rewriting IR.
Only observed AIR2.5→iOS16 and AIR2.2→iOS13 profiles are accepted.
"""
import argparse,json,hashlib
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from shader_inventory_repair_expansion import invoke,save,sha,inventory
from shader_inventory_repair_quartzcore import metadata
from shader_inventory_repair_pack import pack
from catalog_metallibs import inspect_metallib


def target_for(version):
    return {(2,5):'air64_v25-apple-ios16.0.0',(2,2):'air64_v22-apple-ios13.0.0'}[tuple(version)]


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('expansion',type=Path);a=p.parse_args();root=a.expansion.resolve();sources=json.loads((root/'results.json').read_text());results=[]
    for row in sources:
        if row['status']!='module_failure_retained_no_complete_candidate':continue
        folder=root/row['sha256'];dest=folder/'matched-air-version';dest.mkdir(exist_ok=True);source=Path(row['path']).read_bytes();rec=inspect_metallib(source)
        def one(module):
            i=module['index'];region=rec['air_regions'][i];expected=[rec['functions'][j]for j in region['function_indices']];versions={tuple(f['air_version'])for f in expected};assert len(versions)==1;version=next(iter(versions));target=target_for(version);air=dest/f'{i:04}.ios.air';lib=dest/f'{i:04}.metallib';r={'index':i,'source_air_sha256':region['sha256'],'source_AIR_version':version,'target':target,'commands':[]}
            for cmd in [['xcrun','--sdk','iphoneos','metal','-x','ir','-c',str(folder/f'{i:04}.source.air'),'-target',target,'-o',str(air)],['xcrun','--sdk','iphoneos','metallib',str(air),'-o',str(lib)]]:
                run=invoke(cmd);r['commands'].append(run)
                if run.get('returncode')!=0:r['status']='failed';return r
            b=lib.read_bytes();got=inspect_metallib(b);assert inventory({'functions':expected})==inventory(got);assert not got['malformed_records']and not got['integrity_mismatches'];checks=[]
            for f,g in zip(expected,got['functions']):
                assert f['air_version']==g['air_version'];m={'name':f['name']}
                for k in ['public_metadata','private_metadata']:
                    before=metadata(source,rec,f,k);after=metadata(b,got,g,k);m[k]={'source_sha256':sha(before),'output_sha256':sha(after),'payload_equal':before[4:]==after[4:]};assert m[k]['payload_equal']
                checks.append(m)
            r.update(status='matched_version_module_preserved',output=str(lib),output_sha256=sha(b),output_header=got['header'],metadata=checks);return r
        with ThreadPoolExecutor(max_workers=4)as pool:modules=list(pool.map(one,row['modules']))
        evidence={'source_sha256':row['sha256'],'source_path':row['path'],'initial_failure_retained':str(folder/'result.json'),'modules':modules}
        if all(m['status']=='matched_version_module_preserved'for m in modules):
            b,prov=pack([Path(m['output'])for m in modules],allowed_format_versions=(tuple(modules[0]['output_header']['format_version']),));got=inspect_metallib(b);assert inventory(got)==inventory(rec);candidate=dest/'candidate.metallib';candidate.write_bytes(b);save(dest/'candidate-catalog.json',got);save(dest/'candidate-provenance.json',prov);evidence.update(status='matched_air_version_candidate_structurally_preserved',candidate=str(candidate),candidate_sha256=sha(b),functions=len(got['functions']),AIR_regions=got['air_region_count'],target_os=got['header']['target_os'],target_os_version=got['header']['target_os_version'])
        else:evidence['status']='repair_incomplete'
        save(dest/'result.json',evidence);results.append(evidence);save(root/'matched-air-version-results.json',results);print(row['sha256'][:12],evidence['status'],flush=True)
    save(root/'matched-air-version-results.json',results)
if __name__=='__main__':main()
