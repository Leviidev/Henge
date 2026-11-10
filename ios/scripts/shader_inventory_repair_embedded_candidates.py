#!/usr/bin/env python3
"""Validate bounded MTLB magic hits; preserve false positives and opaque records."""
import argparse,json,struct,hashlib
from pathlib import Path
from catalog_metallibs import inspect_metallib


def audit(catalog,out):
    d=json.loads(catalog.read_text());rows=[]
    if 'images'in d:hits=d['MTLB_magic_candidates']
    else:
        hits=[]
        for b in d['binaries']:
            for s in b['slices']:
                for h in s.get('MTLB_magic_candidates',[]):hits.append(dict(h,cache_file=str(Path(d['root'])/b['path']),cache_file_offset=h['file_offset'],image=b['path']))
    for h in hits:
        r=dict(h);p=Path(h['cache_file']);offset=h['cache_file_offset'];available=h['available_in_section']
        with p.open('rb') as f:
            f.seek(offset);head=f.read(min(88,available))
            if len(head)<88:r.update(status='not_full_MTLB_header');rows.append(r);continue
            size=struct.unpack_from('<Q',head,16)[0];r['declared_size']=size
            if size<88 or size>available:r.update(status='magic_without_bounded_MTLB_size');rows.append(r);continue
            f.seek(offset);blob=f.read(size)
        parsed=inspect_metallib(blob);r.update(sha256=hashlib.sha256(blob).hexdigest(),catalog=parsed,status='parsed_bounded_record' if not parsed['malformed_records'] else 'bounded_record_requires_review')
        if not parsed['malformed_records']:
            path=out/(r['sha256']+'.metallib');path.write_bytes(blob);r['extracted_path']=str(path)
        rows.append(r)
    return {'source_catalog':str(catalog),'source_catalog_sha256':hashlib.sha256(catalog.read_bytes()).hexdigest(),'records':rows}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('catalog',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True);r=audit(a.catalog,a.out);dest=a.out/(a.catalog.stem+'-hits.json');dest.write_text(json.dumps(r,indent=2)+'\n');from collections import Counter;print(a.catalog.name,Counter(x['status'] for x in r['records']))
if __name__=='__main__':main()
