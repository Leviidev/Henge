#!/usr/bin/env python3
"""Experimental container-only merge of independently linked executable MTLBs.

Preserves each input's AIR, public/private metadata, function fields and hashes;
relocates OFFT and RFLT offsets and combines reflection lists. Never merges LLVM
modules or resolves cross-module symbols. Only the bounded executable profile
below is supported. This is not a general linker or deployment authorization.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct

from catalog_metallibs import inspect_metallib, tags_at


def need(condition, reason):
    if not condition:
        raise ValueError(reason)


def tag(key, payload):
    return key.encode('ascii') + struct.pack('<H', len(payload)) + payload


def checked(data, allowed_format_versions=((2, 7),)):
    result = inspect_metallib(data)
    need(result['format'] == 'metallib' and not result['malformed_records'], 'invalid MTLB structure')
    need(not result['integrity_mismatches'], 'unreviewed AIR integrity mismatch')
    need(result['header']['library_type_raw'] == 0, 'only executable libraries supported')
    need(all(v in ((2, 4), (2, 7)) for v in allowed_format_versions), 'unreviewed format profile')
    need(tuple(result['header']['format_version']) in allowed_format_versions, 'MTLB format requires explicit reviewed profile')
    need(not result['uncovered_bitcode_ranges'], 'uncovered AIR bytes')
    need(all(r['structurally_valid_wrapper'] for r in result['air_regions']), 'unsupported AIR wrapper')
    return result


def pack(inputs, *, allowed_format_versions=((2, 7),)):
    parts = {'public_metadata': bytearray(), 'private_metadata': bytearray(), 'bitcode': bytearray()}
    functions, reflection_groups, sources = [], [], []
    reflection_length, reflection_count = 0, 0
    identity = None
    original_inventory = Counter()
    for path in inputs:
        data = path.read_bytes(); rec = checked(data, allowed_format_versions); sections = rec['header']['sections']
        need(identity is None or data[:16] == identity, 'input platform/version/kind disagreement')
        identity = data[:16]
        section_bytes = {k: data[s['offset']:s['offset']+s['size']] for k,s in sections.items() if k != 'functions'}
        base = {k: len(v) for k,v in parts.items()}
        ext_start = sections['functions']['offset'] + sections['functions']['size'] + 4
        ext_end = sections['public_metadata']['offset']
        extension = []
        if ext_start < ext_end:
            extension, stop = tags_at(data, ext_start, ext_end)
            need(stop == ext_end, 'header extension tail')
        need(all(t['tag'] in ('UUID', 'RLST') for t in extension), 'unsupported header extension; no guessing offsets')
        rlists = [t for t in extension if t['tag'] == 'RLST'];need(len(rlists)<=1,'duplicate RLST')
        rmap = {}
        if rlists:
            need(rlists[0]['size']==16,'bad RLST size')
            ro,rs=struct.unpack('<QQ',rlists[0]['data']);need(ro+rs<=len(data) and rs>=4,'RLST bounds')
            rdata=data[ro:ro+rs];count=struct.unpack_from('<I',rdata)[0];pos=4
            for _ in range(count):
                need(pos+4<=rs,'truncated reflection group')
                size=struct.unpack_from('<I',rdata,pos)[0]
                need(size>=8 and pos+size<=rs,'reflection group bounds')
                # Keep group bytes opaque and unmodified. Only its list-relative
                # record offset changes. Existing RFLT must point at this start.
                rmap[pos]=4+reflection_length
                reflection_groups.append(rdata[pos:pos+size]);reflection_length+=size;reflection_count+=1;pos+=size
            need(pos==rs,'uncovered reflection bytes')
        source_functions=[]
        for f in rec['functions']:
            start=f['record_offset'];raw_tags,stop=tags_at(data,start+4,start+f['record_size'])
            need(stop==start+f['record_size'],'function record tail')
            need(all(t['tag'] in ('NAME','TYPE','HASH','OFFT','VERS','MDSZ','RFLT','TESS','LAYR') for t in raw_tags),
                 'unsupported function tag; no guessing offsets')
            body=bytearray()
            for t in raw_tags:
                value=t['data']
                if t['tag']=='OFFT':
                    offsets=struct.unpack('<QQQ',value)
                    value=struct.pack('<QQQ',*(offsets[i]+base[k] for i,k in enumerate(parts)))
                elif t['tag']=='RFLT':
                    need(len(value)==8,'bad RFLT size');old=struct.unpack('<Q',value)[0]
                    need(old in rmap,'RFLT does not reference an observed reflection group')
                    value=struct.pack('<Q',rmap[old])
                body+=tag(t['tag'],value)
            body+=b'ENDT';functions.append(struct.pack('<I',len(body)+4)+body)
            original_inventory[(f['name'],f['type_raw'])]+=1
            source_functions.append({'name':f['name'],'type_raw':f['type_raw'],'original_index':f['index']})
        for k in parts:parts[k]+=section_bytes[k]
        # Every byte must be in an understood container region. Preserve actual
        # reflection records; UUID identities remain in provenance, not reused.
        extents=[(0,88),(sections['functions']['offset'],ext_end)]
        extents.extend((s['offset'],s['offset']+s['size']) for k,s in sections.items() if k!='functions')
        if rlists:extents.append((ro,ro+rs))
        covered=sorted((a,b) for a,b in extents if a!=b);cursor=0
        for a,b in covered:need(a==cursor,'noncontiguous/overlapping unsupported container bytes');cursor=b
        need(cursor==len(data),'unrecognized trailing sections')
        sources.append({'path':str(path.resolve()),'sha256':hashlib.sha256(data).hexdigest(),
                        'byte_size':len(data),'function_count':len(rec['functions']),
                        'air_regions':[{'sha256':r['sha256'],'size':r['size']} for r in rec['air_regions']],
                        'functions':source_functions,'section_sha256':{k:hashlib.sha256(v).hexdigest() for k,v in section_bytes.items()},
                        'relocated_section_bases':base,'original_header_extensions':[
                            {'tag':t['tag'],'data_hex':t['data'].hex()} for t in extension]})
    need(identity is not None,'no inputs')
    function_data=struct.pack('<I',len(functions))+b''.join(functions)
    uid=hashlib.sha256(b''.join(bytes.fromhex(s['sha256']) for s in sources)).digest()[:16]
    extension_size=26+(22 if reflection_groups else 0)
    public_offset=88+len(function_data)+extension_size
    private_offset=public_offset+len(parts['public_metadata'])
    bitcode_offset=private_offset+len(parts['private_metadata'])
    reflection_offset=bitcode_offset+len(parts['bitcode'])
    reflection=struct.pack('<I',reflection_count)+b''.join(reflection_groups) if reflection_groups else b''
    extension=(tag('RLST',struct.pack('<QQ',reflection_offset,len(reflection))) if reflection else b'')+tag('UUID',uid)+b'ENDT'
    header=identity+struct.pack('<9Q',reflection_offset+len(reflection),88,len(function_data)-4,
                public_offset,len(parts['public_metadata']),private_offset,len(parts['private_metadata']),
                bitcode_offset,len(parts['bitcode']))
    output=header+function_data+extension+bytes(parts['public_metadata'])+bytes(parts['private_metadata'])+bytes(parts['bitcode'])+reflection
    actual=checked(output, allowed_format_versions)
    need(Counter((f['name'],f['type_raw']) for f in actual['functions'])==original_inventory,'function multiplicity changed')
    need([r['sha256'] for r in actual['air_regions']]==[r['sha256'] for s in sources for r in s['air_regions']],
         'AIR bytes or module ordering changed')
    evidence={'status':'container_packed_inventory_preserved_runtime_unverified','sources':sources,
              'output_sha256':hashlib.sha256(output).hexdigest(),'byte_size':len(output),
              'function_count':len(actual['functions']),'air_region_count':actual['air_region_count'],
              'reflection_records':reflection_count,'runtime_verified':False,'pixel_verified':False,
              'allowed_format_versions':allowed_format_versions,
              'limitations':['No cross-module linking or dependency resolution.','Each input must already be independently linked.',
                             'No iPad runtime acceptance implied.','Opaque reflection group bytes preserved; schema not decoded.']}
    return output,evidence


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inputs',type=Path,nargs='+');p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();output,evidence=pack(a.inputs);a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_bytes(output)
    a.output.with_suffix('.manifest.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps({k:v for k,v in evidence.items() if k!='sources'},indent=2))


if __name__=='__main__':main()
