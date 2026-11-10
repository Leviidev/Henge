#!/usr/bin/env python3
"""Retarget/independently link all declared QuartzCore AIR modules and pack them."""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor,as_completed
import hashlib
import json
from pathlib import Path
import struct
import subprocess
from catalog_metallibs import inspect_metallib
from shader_inventory_repair_pack import pack


def sha(b):return hashlib.sha256(b).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def metadata(data,record,function,kind):
    section=record['header']['sections'][kind];relative=function['offsets'][kind];start=section['offset']+relative
    # Both observed writers are accepted by Metal: older records count the
    # length word itself; current ordinary-library writer counts only payload.
    end=section['offset']+min([f['offsets'][kind] for f in record['functions'] if f['offsets'][kind]>relative]+[section['size']])
    blob=data[start:end];declared=struct.unpack_from('<I',blob)[0]
    if declared not in (len(blob),len(blob)-4) or blob[-4:]!=b'ENDT':raise ValueError('unsupported bounded metadata length convention')
    return blob


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inventory_root',type=Path);p.add_argument('--workers',type=int,default=4);a=p.parse_args();root=a.inventory_root.resolve();out=root/'quartzcore-150-01';out.mkdir(exist_ok=False);modules=out/'modules';modules.mkdir();source=root/'inventory-integrity-03/quartzcore-slice0-unmodified.metallib';raw=source.read_bytes();record=inspect_metallib(raw);assert sha(raw)=='e406ee627a363ffd7da3582125cb3f4c83f73a9d8b2e2711ecaa0f1594531657';assert record['air_region_count']==150 and not record['malformed_records'] and not record['integrity_mismatches'];save(out/'source-catalog.json',record)
    def one(index,region):
        result={'index':index,'source_air_sha256':region['sha256'],'source_offset_in_slice':region['offset'],'source_size':region['size'],'function_indices':region['function_indices'],'commands':[]};air=modules/f'{index:03}.source.air';ios=modules/f'{index:03}.ios.air';lib=modules/f'{index:03}.metallib';data=raw[region['offset']:region['offset']+region['size']];assert sha(data)==region['sha256'];air.write_bytes(data)
        for command in [['xcrun','--sdk','iphoneos','metal','-x','ir','-c',str(air),'-target','air64-apple-ios17.0.0','-o',str(ios)],['xcrun','--sdk','iphoneos','metallib',str(ios),'-o',str(lib)]]:
            try:cp=subprocess.run(command,capture_output=True,text=True,timeout=30)
            except subprocess.TimeoutExpired as e:result.update(status='timeout',error=str(e));return result
            result['commands'].append({'command':command,'returncode':cp.returncode,'stdout':cp.stdout,'stderr':cp.stderr})
            if cp.returncode:result['status']='compiler_or_linker_failed';return result
        target=lib.read_bytes();parsed=inspect_metallib(target);expected=[record['functions'][i] for i in region['function_indices']];result.update(output_sha256=sha(target),output_path=str(lib),retargeted_air_sha256=sha(ios.read_bytes()),functions=[{'name':f['name'],'type_raw':f['type_raw']} for f in expected],malformed_records=parsed['malformed_records'],integrity_mismatches=parsed['integrity_mismatches'],metadata=[])
        same=Counter((f['name'],f['type_raw']) for f in expected)==Counter((f['name'],f['type_raw']) for f in parsed['functions']);result['function_inventory_matches']=same
        if same:
            by_name={f['name']:f for f in parsed['functions']}
            for f in expected:
                o=by_name[f['name']];checks={}
                for kind in ['public_metadata','private_metadata']:
                    before=metadata(raw,record,f,kind);after=metadata(target,parsed,o,kind);checks[kind]={'source_sha256':sha(before),'output_sha256':sha(after),'source_bytes':len(before),'output_bytes':len(after),'bytes_equal':before==after,'payload_bytes_equal':before[4:]==after[4:],'source_length_counts_header':struct.unpack_from('<I',before)[0]==len(before),'output_length_counts_header':struct.unpack_from('<I',after)[0]==len(after)}
                result['metadata'].append({'name':f['name'],**checks})
        result['status']='module_inventory_preserved' if same and not parsed['malformed_records'] and not parsed['integrity_mismatches'] else 'review_required';return result
    results=[]
    with ThreadPoolExecutor(max_workers=min(4,max(1,a.workers))) as pool:
        tasks=[pool.submit(one,i,m) for i,m in enumerate(record['air_regions'])]
        for task in as_completed(tasks):
            results.append(task.result())
            if len(results)%25==0:save(out/'module-results.json',sorted(results,key=lambda x:x['index']));print(len(results),dict(Counter(x['status'] for x in results)),flush=True)
    results.sort(key=lambda x:x['index']);save(out/'module-results.json',results)
    if any(r['status']!='module_inventory_preserved' for r in results):raise SystemExit('module failure; preserving evidence without candidate')
    blob,provenance=pack([Path(r['output_path']) for r in results]);candidate=out/'quartzcore-ios17-packed.metallib';candidate.write_bytes(blob);got=inspect_metallib(blob);assert Counter((f['name'],f['type_raw']) for f in got['functions'])==Counter((f['name'],f['type_raw']) for f in record['functions']);assert got['air_region_count']==150;provenance.update(source_FAT_sha256='87eb062eeeb6ed534c42fe9dd3ef4f08706714c759f9f5ce65c4bab6788b3650',source_FAT_slice_index=0,source_FAT_slice_offset=192,source_slice_sha256=sha(raw),source_slice_path=str(source),source_module_count=150);save(out/'candidate-provenance.json',provenance);save(out/'candidate-catalog.json',got);save(out/'summary.json',{'status':'150module_candidate_built_runtime_pending','candidate':str(candidate),'candidate_sha256':sha(blob),'source_slice_sha256':sha(raw),'functions':len(got['functions']),'AIR_regions':got['air_region_count'],'module_results':dict(Counter(r['status'] for r in results)),'metadata_changed':[m for r in results for m in r['metadata'] if not m['public_metadata']['bytes_equal'] or not m['private_metadata']['bytes_equal']],'metadata_payload_changed':[m for r in results for m in r['metadata'] if not m['public_metadata']['payload_bytes_equal'] or not m['private_metadata']['payload_bytes_equal']],'metadata_length_convention':'Source length includes four-byte header; output length excludes it. Compare bounded payloads independently.','runtime_verified':False});print(str(candidate))


if __name__=='__main__':main()
