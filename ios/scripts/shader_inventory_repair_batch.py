#!/usr/bin/env python3
"""Assemble four retained module collections; verify source/output provenance."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

from catalog_metallibs import inspect_metallib
from shader_inventory_repair_pack import pack
from shader_inventory_repair_probe import inventory, delta


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('inventory_root',type=Path);a=parser.parse_args()
    root=a.inventory_root.resolve();out=root/'inventory-repair-02'
    original={x['sha256']:x for x in json.loads((root/'shipped/catalog.json').read_text())['libraries']}
    old=json.loads((root/'module-link-audit-01/results.json').read_text());groups={}
    for entry in old:groups.setdefault(entry['source_library_sha256'],[]).append(entry)
    repaired=json.loads((out/'executable-memcpy-probes.json').read_text())[0];results=[]
    for digest,entries in sorted(groups.items()):
        start=time.monotonic();source=root/'shipped/artifacts'/(digest+'.metallib')
        assert hashlib.sha256(source.read_bytes()).hexdigest()==digest
        paths=[];checks=[]
        for e in sorted(entries,key=lambda e:e['index']):
            index=e['index'];air=root/'batch-all-01'/digest/f'{index:05d}.ios.air'
            actual_air=hashlib.sha256(air.read_bytes()).hexdigest();assert actual_air==e['input_air_sha256']
            if e['status']=='module_inventory_preserved':
                path=root/'module-link-audit-01'/digest/f'{index:05d}.metallib';expected=e['output_sha256']
            else:
                assert digest.startswith('7fb0f218') and index==33
                path=Path(repaired['output']);expected=repaired['output_sha256']
            actual_output=hashlib.sha256(path.read_bytes()).hexdigest();assert actual_output==expected
            got=inspect_metallib(path.read_bytes());want=Counter((f['name'],f['type_raw']) for f in e['expected_functions'])
            assert inventory(got)==want, (digest,index)
            checks.append({'index':index,'retargeted_air_sha256':actual_air,'linked_module_sha256':actual_output,
                           'original_air_sha256':e['source_air_sha256'],'function_indices':e['function_indices']})
            paths.append(path)
        data,manifest=pack(paths);parsed=inspect_metallib(data);difference=delta(inventory(original[digest]),inventory(parsed))
        assert not difference['missing'] and not difference['added']
        destination=out/(digest+'-packed.metallib');destination.write_bytes(data)
        manifest.update(original_library_sha256=digest,original_library_path=str(source),
                        verified_module_provenance=checks,function_delta=difference)
        destination.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        summary={k:v for k,v in manifest.items() if k not in ('sources','verified_module_provenance')}
        summary.update(output=str(destination),seconds=round(time.monotonic()-start,3));results.append(summary)
        print(digest[:12],summary['function_count'],summary['air_region_count'],summary['seconds'],flush=True)
    (out/'packed-libraries.json').write_text(json.dumps(results,indent=2)+'\n')


if __name__=='__main__':main()
