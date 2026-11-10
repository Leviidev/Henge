#!/usr/bin/env python3
"""Verify the helper's non-reserved asset layout and exact pinned resources."""
import argparse
import hashlib
import json
from pathlib import Path


def verify(app, manifest_path):
    if (app/'Resources').exists():raise ValueError('Stale top-level Resources folder; use fresh build directory')
    root=app/'AuditAssets';expected=manifest_path.read_bytes();actual=(root/'inventory-jobs.json').read_bytes()
    if expected!=actual:raise ValueError('Bundled manifest bytes changed')
    manifest=json.loads(expected);assets=[]
    for job in manifest['jobs']:assets.append((job['file'],job['sha256']))
    for value in manifest['controls'].values():
        if isinstance(value,dict) and 'file' in value:
            assets.append((value['file'],value['sha256']))
            if 'consumer_file' in value:assets.append((value['consumer_file'],value['consumer_sha256']))
            if 'consumer_library_file' in value:assets.append((value['consumer_library_file'],value['consumer_library_sha256']))
    if manifest.get("asset_sha256"):assets=list(manifest["asset_sha256"].items())
    for filename,digest in assets:
        if Path(filename).name!=filename:raise ValueError('Asset path must be a basename')
        if hashlib.sha256((root/filename).read_bytes()).hexdigest()!=digest:raise ValueError(f'Asset changed: {filename}')
    return {'status':'asset_layout_and_bytes_verified','app':str(app),'asset_directory':'AuditAssets',
            'manifest_sha256':hashlib.sha256(expected).hexdigest(),'assets_checked':len(assets)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--app',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--output',type=Path)
    a=p.parse_args();r=verify(a.app,a.manifest);text=json.dumps(r,indent=2)+'\n'
    if a.output:a.output.write_text(text)
    print(text,end='')


if __name__=='__main__':main()
