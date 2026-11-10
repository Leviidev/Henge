#!/usr/bin/env python3
"""Bounded executable-library linking probes, retained inputs only."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

from shader_inventory_repair_probe import run, inventory


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('inventory_root', type=Path)
    p.add_argument('--large', action='store_true')
    a = p.parse_args();root=a.inventory_root.resolve();out=root/'inventory-repair-02'
    source='7fb0f218577f2c921e833d760f487ef4bd4e366b1290e02543528cc6ceadeb1d'
    records={x['sha256']:x for x in json.loads((root/'shipped/catalog.json').read_text())['libraries']}
    jobs=[]
    if not a.large:
        for mode, flags in [('default',[]),('nostdlib',['--nostdlib']),('no-opt',['--no-enable-link-optimizations']),('no-opt-nostdlib',['--no-enable-link-optimizations','--nostdlib'])]:
            jobs.append((source,mode,flags,[str(root/'batch-all-01'/source/'00033.ios.air')],Counter({('memcpy',2):1})))
    else:
        source='5fa11a98566e5925b0d0afaf320a6f9e0e0fb5820abfc4109b2b1abd6124b52a'
        jobs.append((source,'whole-no-opt',['--no-enable-link-optimizations'],['@'+str(root/'batch-all-01'/source/'modules.rsp')],inventory(records[source])))
    results=[]
    for digest,mode,flags,inputs,expected in jobs:
        output=out/(digest+'-'+mode+'.metallib')
        command=['xcrun','--sdk','iphoneos','air-lld','--arch','air64','--ios_version_min','17.0',*flags,*inputs,'-o',str(output)]
        row=run(command,output,expected,60);row.update(source_sha256=digest,mode=mode)
        results.append(row);print(mode,row.get('returncode'),row.get('seconds'),row.get('function_count'),row.get('function_delta'),row.get('stderr'),flush=True)
    (out/('executable-large-probes.json' if a.large else 'executable-memcpy-probes.json')).write_text(json.dumps(results,indent=2)+'\n')


if __name__=='__main__':main()
