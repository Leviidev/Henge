#!/usr/bin/env python3
"""Bounded integrity evidence helpers; no repair-by-rehash or source mutation."""
from collections import Counter
import hashlib
import struct
from catalog_metallibs import inspect_metallib


def sha(data):return hashlib.sha256(data).hexdigest()


def frame_embedded_section(data):
    records=[];pos=0
    while pos<len(data):
        if pos+88>len(data) or data[pos:pos+4]!=b'MTLB':raise ValueError(f'expected bounded MTLB header at {pos}')
        size=struct.unpack_from('<Q',data,pos+16)[0]
        if size<88 or pos+size>len(data):raise ValueError(f'declared embedded record exceeds enclosing section at {pos}')
        blob=data[pos:pos+size];record=inspect_metallib(blob)
        if record['malformed_records']:raise ValueError(f'malformed embedded record at {pos}: {record["malformed_records"]}')
        end=pos+size;aligned=min((end+15)&~15,len(data));padding=data[end:aligned]
        if any(padding):raise ValueError(f'nonzero alignment padding at {end}')
        records.append({'section_offset':pos,'byte_size':size,'sha256':sha(blob),'alignment_padding_bytes':len(padding),'library_type_raw':record['header']['library_type_raw'],'functions':[{'name':f['name'],'type_raw':f['type_raw'],'shader_stage':f['shader_stage']} for f in record['functions']],'air_region_count':record['air_region_count'],'integrity_mismatches':record['integrity_mismatches'],'unsupported_records':record['unsupported_records']});pos=aligned
    return records


def inspect_pair(source,output):
    a=inspect_metallib(source);b=inspect_metallib(output)
    def describe(data,r):
        return {'sha256':sha(data),'byte_size':len(data),'declared_file_size':r['header']['declared_file_size'],'header':r['header'],'function_count':len(r['functions']),'function_type_counts':dict(Counter(str(f['type_raw']) for f in r['functions'])),'air_region_count':r['air_region_count'],'air_regions':r['air_regions'],'unique_declared_air_sha256':sorted(set(f.get('declared_air_sha256','') for f in r['functions'])),'malformed_records':r['malformed_records'],'integrity_mismatches':r['integrity_mismatches'],'uncovered_bitcode_ranges':r['uncovered_bitcode_ranges'],'opaque_tag_counts':dict(Counter(x.get('tag',x.get('scope')) for x in r['unsupported_records']))}
    return {'source':describe(source,a),'output':describe(output,b),'name_type_multiplicity_preserved':Counter((f['name'],f['type_raw']) for f in a['functions'])==Counter((f['name'],f['type_raw']) for f in b['functions']),'declared_hashes_preserved_from_source':{f.get('declared_air_sha256') for f in a['functions']}=={f.get('declared_air_sha256') for f in b['functions']},'output_functions':[{'name':f['name'],'type_raw':f['type_raw']} for f in b['functions']]}


def main():
    import argparse,json
    from pathlib import Path
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inventory_root',type=Path);a=p.parse_args();root=a.inventory_root.resolve();out=root/'inventory-integrity-03';native=json.loads((out/'native-ci-results.json').read_text());rows=[]
    for original in json.loads((root/'inventory-repair-02/current-offline-review.json').read_text())['libraries']:
        if not original['integrity_mismatch_count']:continue
        source=root/'shipped/artifacts'/(original['source_sha256']+'.metallib');output=Path(original['output']);record=inspect_pair(source.read_bytes(),output.read_bytes());assert record['source']['sha256']==original['source_sha256'] and record['output']['sha256']==original['output_sha256'];assert not record['source']['malformed_records'] and not record['source']['integrity_mismatches'] and not record['output']['malformed_records'];assert record['name_type_multiplicity_preserved'] and not record['declared_hashes_preserved_from_source']
        record.update(source_path=str(source),output_path=str(output),guest_source_aliases=original['source_paths'],classification='tool_produced_HASH_semantics_unknown_structure_and_CI_API_evidence_separate',native_ci=[])
        for r in native:
            if r['source_sha256']!=original['source_sha256']:continue
            report=r['report'];expected=record['output_functions'];assert Counter(report['ci_names'])==Counter(f['name'] for f in expected);record['native_ci'].append({'label':r['label'],'export_names_match':True,'constructor_samples':report['constructor_samples'],'oracle_cases':report.get('oracle_cases',[]),'os':report['os'],'device':report.get('device'),'pixel_scope':'CUIScaleClampKernel2x2scales1and0' if report.get('oracle_cases') else 'not_executed'})
        for name in ['public_metadata','private_metadata']:
            section_hashes=[]
            for path,key in [(source,'source'),(output,'output')]:
                b=path.read_bytes();section=record[key]['header']['sections'][name];section_hashes.append(sha(b[section['offset']:section['offset']+section['size']]))
            record[name+'_source_output_hashes']=section_hashes;record[name+'_bytes_preserved']=len(set(section_hashes))==1
        possible={};inputs=[('converted_serialized_AIR',output.read_bytes()[record['output']['air_regions'][0]['offset']:record['output']['air_regions'][0]['offset']+record['output']['air_regions'][0]['size']]),('linker_input_AIR',(output.parent/'00000.ios.air').read_bytes())]
        for label,data in inputs:
            possible[label+'_full']=sha(data)
            if data[:4]==bytes.fromhex('dec0170b'):
                off,size=struct.unpack_from('<II',data,8);possible[label+'_raw_bitcode']=sha(data[off:off+size]);possible[label+'_through_bitcode_end']=sha(data[:off+size])
        record['bounded_HASH_contract_candidates']=possible;record['matching_HASH_contract_candidates']=[k for k,v in possible.items() if v in record['output']['unique_declared_air_sha256']];rows.append(record)
    summary={'status':'eight_structurally_valid_tool_emitted_HASH_discrepancies_reviewed_not_rehashed','libraries':len(rows),'function_records':sum(r['output']['function_count'] for r in rows),'module_hash_discrepancies':sum(r['output']['air_region_count'] for r in rows),'original_source_hash_mismatches':0,'output_record_hash_mismatches':sum(len(r['output']['integrity_mismatches']) for r in rows),'stale_original_hash_hypothesis_supported':False,'native_full_export_enumeration_libraries':8,'native_shipped_pixel_scope':'Only CoreUI CUIScaleClampKernel, two2x2cases, both original and converted; not iPad proof.','canonical_HASH_contract':'unresolved; serialized full AIR/raw bitcode/linker input candidate digests do not establish the contract','production_policy':'Keep mismatch evidence and reviewed classification; do not automatically accept these archives through the strict runtime converter or mutate HASH bytes.'}
    (out/'eight-integrity-review.json').write_text(json.dumps({'summary':summary,'libraries':rows},indent=2)+'\n');print(json.dumps(summary,indent=2))


if __name__=='__main__':main()
