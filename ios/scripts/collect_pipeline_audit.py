#!/usr/bin/env python3
"""Collect opt-in Henge pipeline captures with bounded, hash-checked extraction."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import shlex
import struct
import subprocess
import tarfile
from datetime import datetime, timezone


def validate_capture(blob, item, digest):
    if blob is None or item['sha256']!=digest:
        raise ValueError('Capture identity mismatch')
    blob_hash=hashlib.sha256(blob).hexdigest()
    if item.get('schema',1)==1:
        if blob_hash!=digest:raise ValueError('Legacy capture hash mismatch')
    elif item['schema']==2:
        bindings=base64.b64decode(item['bindings_data_base64'],validate=True)
        if json.loads(bindings)!=item['function_refs'] or item['blob_sha256']!=blob_hash:
            raise ValueError('Capture binding or blob mismatch')
        if hashlib.sha256((blob_hash+'\n').encode()+bindings).hexdigest()!=digest:
            raise ValueError('Bound capture identity mismatch')
    else:raise ValueError('Unsupported capture schema')
    if len(blob)!=item['byte_size'] or len(blob)<16:raise ValueError('Capture size mismatch')
    tag,_,_,length=struct.unpack_from('<4I',blob)
    if tag not in (0xe,0x33) or tag!=item['tag'] or length>len(blob)-16:
        raise ValueError('Invalid serialized capture header')
    if not isinstance(item['function_refs'],dict):raise ValueError('Invalid function bindings')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',required=True)
    parser.add_argument('--host-key-alias')
    parser.add_argument('--documents',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5']
    if args.host_key_alias:ssh+=['-o','HostKeyAlias='+args.host_key_alias]
    ssh+=[args.host]
    code='''import pathlib,tarfile,sys,re
p=pathlib.Path(DOCUMENTS)/'shader-pipeline-audit'
with tarfile.open(fileobj=sys.stdout.buffer,mode='w|gz') as archive:
 for metadata in sorted(p.glob('*.json')):
  if not re.fullmatch(r'[0-9a-f]{64}\\.json',metadata.name):continue
  blob=metadata.with_suffix('.bin')
  if not blob.is_file():continue
  archive.add(blob,arcname=blob.name,recursive=False)
  archive.add(metadata,arcname=metadata.name,recursive=False)
'''.replace('DOCUMENTS',repr(args.documents))
    archive=subprocess.check_output(ssh+['python3 -c '+shlex.quote(code)],timeout=90)
    args.output.mkdir(parents=True,exist_ok=True)
    files={};total=0
    with tarfile.open(fileobj=io.BytesIO(archive),mode='r:gz') as source:
        for member in source:
            if (not member.isfile() or not re.fullmatch(r'[0-9a-f]{64}\.(json|bin)',member.name)
                    or member.name in files or member.size>1024*1024):
                raise ValueError('Unexpected capture member')
            total+=member.size
            if total>64*1024*1024 or len(files)>=4096:raise ValueError('Capture exceeds collection bounds')
            files[member.name]=source.extractfile(member).read()
    cases=[]
    for name,data in files.items():
        if not name.endswith('.json'):continue
        item=json.loads(data);digest=name[:-5];blob=files.get(digest+'.bin')
        validate_capture(blob,item,digest)
        cases.append({**item,'file':digest+'.bin'})
    if len(cases)*2!=len(files):raise ValueError('Unpaired capture files')
    for name,data in files.items():
        path=args.output/name
        if path.exists() and path.read_bytes()!=data:raise ValueError('Existing capture differs')
        path.write_bytes(data)
    manifest={'captured_at_utc':datetime.now(timezone.utc).isoformat(),'cases':cases,
              'count':len(cases),'bytes':total,'limits':'Observed opt-in pipeline creations; not exhaustive coverage.'}
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'cases':len(cases),'bytes':total,'live_created':sum(x['state_created'] for x in cases)}))


if __name__=='__main__':main()
