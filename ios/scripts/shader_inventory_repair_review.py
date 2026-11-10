#!/usr/bin/env python3
"""Revalidate retained/offline repaired outputs without changing main trackers."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct

from catalog_metallibs import inspect_metallib, tags_at
from shader_inventory_repair_probe import inventory, delta


def dynamic_header(data, record):
    tags=[]
    for entry in record['unsupported_records']:
        if entry.get('scope')=='header_extension' and entry.get('tag')=='HDYN':
            offset,size=struct.unpack('<QQ',bytes.fromhex(entry['data_hex']))
            found,end=tags_at(data,offset,offset+size)
            assert end==offset+size
            tags.extend({'tag':t['tag'],'data_hex':t['data'].hex()} for t in found)
    return tags


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inventory_root',type=Path);a=p.parse_args()
    root=a.inventory_root.resolve();out=root/'inventory-repair-02'
    old=json.loads((root/'batch-effective-results.json').read_text());rows=[]
    for item in old:
        digest=item['source_sha256'];source=root/'shipped/artifacts'/(digest+'.metallib');sdata=source.read_bytes()
        assert hashlib.sha256(sdata).hexdigest()==digest
        src=inspect_metallib(sdata)
        if src['header']['library_type_raw']==2:
            output=out/(digest+'-shared.metallib');route='shared-library-linker'
        elif (out/(digest+'-packed.metallib')).exists():
            output=out/(digest+'-packed.metallib');route='experimental-module-container-pack'
        else:
            output=Path(item['link']['command'][-1]);route='retained-existing-output'
        row={'source_sha256':digest,'source_paths':item['paths'],'historical_status':item['status'],
             'output':str(output),'route':route,'runtime_verified':False,'pixel_verified':False}
        if not output.exists():
            row['status']='missing_output';rows.append(row);continue
        data=output.read_bytes();dst=inspect_metallib(data)
        row.update(output_sha256=hashlib.sha256(data).hexdigest(),byte_size=len(data),catalog_status=dst['status'],
                   malformed_records=dst['malformed_records'],integrity_mismatch_count=len(dst['integrity_mismatches']),
                   source_functions=len(src['functions']),output_functions=len(dst['functions']),
                   source_air_regions=src['air_region_count'],output_air_regions=dst['air_region_count'],
                   function_delta=delta(inventory(src),inventory(dst)))
        row['kind_preserved']=dst['header'] is not None and src['header']['library_type_raw']==dst['header']['library_type_raw']
        row['target_is_ios17']=dst['header'] is not None and dst['header']['platform_raw']==1 and dst['header']['target_os_raw']==0x82 and dst['header']['target_os_version']==[17,0]
        row['dynamic_header_preserved']=dynamic_header(sdata,src)==dynamic_header(data,dst)
        if dst['malformed_records'] or row['function_delta']['missing'] or row['function_delta']['added'] or not all(row[k] for k in ['kind_preserved','target_is_ios17','dynamic_header_preserved']):
            row['status']='review_failed'
        elif dst['integrity_mismatches']:
            row['status']='inventory_preserved_integrity_review_runtime_unverified'
        elif route=='experimental-module-container-pack':
            row['status']='inventory_preserved_experimental_pack_runtime_unverified'
        else:
            row['status']='inventory_preserved_runtime_unverified'
        rows.append(row)
    summary={'libraries':len(rows),'results':dict(Counter(r['status'] for r in rows)),
             'routes':dict(Counter(r['route'] for r in rows)),
             'function_records':sum(r.get('output_functions',0) for r in rows),
             'integrity_mismatch_records':sum(r.get('integrity_mismatch_count',0) for r in rows),
             'runtime_verified_libraries':0,'pixel_verified_libraries':0,
             'scope':'105 previously attempted top-level MTLB artifacts. Excludes FAT slices, runtime symbol containers, embedded/uncollected libraries and historical pipeline cases.'}
    report={'summary':summary,'libraries':rows}
    (out/'current-offline-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(summary,indent=2))


if __name__=='__main__':main()
