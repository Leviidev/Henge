#!/usr/bin/env python3
"""Bounded Mach-O/cache image+section inventory from explicit read-only mount roots.
Does not extract/rebase/execute dylibs; MTLB magic hits are candidates, not libraries.
"""
import argparse,hashlib,json,mmap,os,struct,uuid
from pathlib import Path


def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        while b:=f.read(8*1024*1024):h.update(b)
    return h.hexdigest()
def u32(b,o):return struct.unpack_from('<I',b,o)[0]
def name(b):return b.split(b'\0',1)[0].decode('utf-8','replace')
def macho(read):
    h=read(0,32)
    wide=h[:4]==b'\xcf\xfa\xed\xfe'
    if not wide and h[:4]!=b'\xce\xfa\xed\xfe':raise ValueError('unsupported Mach-O header (little endian required)')
    cpu,sub,kind,ncmd,size=struct.unpack_from('<5I',h,4)
    if ncmd>10000 or size>16*1024*1024:raise ValueError('unreasonable load-command bound')
    commands=read(32 if wide else 28,size);cursor=0;segments=[];sections=[];ident=None
    for _ in range(ncmd):
        if cursor+8>len(commands):raise ValueError('truncated load command')
        cmd,length=struct.unpack_from('<II',commands,cursor)
        if length<8 or cursor+length>len(commands):raise ValueError('invalid load command length')
        c=commands[cursor:cursor+length]
        if cmd==(0x19 if wide else 1):
            base,entry=(72,80) if wide else (56,68)
            if length<base:raise ValueError('short segment')
            seg=name(c[8:24]);vm,sz,fo,fs=struct.unpack_from('<4Q' if wide else '<4I',c,24);count=u32(c,64 if wide else 48)
            if base+entry*count>length:raise ValueError('truncated section array')
            segments.append({'name':seg,'vmaddr':vm,'vmsize':sz,'fileoff':fo,'filesize':fs})
            for i in range(count):
                s=c[base+i*entry:base+(i+1)*entry];addr,n=struct.unpack_from('<QQ' if wide else '<II',s,32);off=u32(s,48 if wide else 40);flags=u32(s,64 if wide else 56)
                sections.append({'segment':name(s[16:32]),'section':name(s[:16]),'address':addr,'size':n,'file_offset':off,'flags':flags,'zero_fill':(flags&255) in (1,12,18)})
        elif cmd==0x1b and length==24:ident=str(uuid.UUID(bytes=c[8:24]))
        cursor+=length
    if cursor!=size:raise ValueError('unconsumed load command bytes')
    return {'cpu':cpu,'subtype':sub,'file_type':kind,'uuid':ident,'segments':segments,'sections':sections}


def cache_inventory(primary):
    paths=[primary]+sorted(p for p in primary.parent.glob(primary.name+'.*') if p.suffix[1:].isdigit());handles=[];maps=[];files=[]
    for p in paths:
        f=p.open('rb');mm=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ);handles.append((f,mm));mo,mc=struct.unpack_from('<II',mm,16)
        if not mm[:16].startswith(b'dyld_v1') or mo+mc*32>len(mm):raise ValueError('cache mapping bounds')
        ident=str(uuid.UUID(bytes=mm[88:104]));files.append({'file':str(p),'bytes':len(mm),'uuid':ident,'sha256':digest(p)})
        for i in range(mc):
            a,n,off,maxp,initp=struct.unpack_from('<QQQII',mm,mo+i*32)
            if off+n>len(mm):raise ValueError('cache mapping outside file')
            maps.append((a,n,off,mm,str(p)))
    declared_subcaches=[]
    primary_header=handles[0][1]
    if u32(primary_header,16)>=400:
        so,sc=struct.unpack_from('<II',primary_header,392)
        if so+sc*56>len(primary_header):raise ValueError('subcache array bounds')
        for i in range(sc):
            row=primary_header[so+i*56:so+(i+1)*56];suffix=name(row[24:]);ident=str(uuid.UUID(bytes=row[:16]))
            if not suffix.startswith('.') or '/' in suffix:raise ValueError('unsupported subcache suffix')
            found=[f for f in files if f['file']==str(primary)+suffix and f['uuid']==ident]
            if len(found)!=1:raise ValueError('declared subcache UUID/file mismatch')
            declared_subcaches.append({'suffix':suffix,'uuid':ident})
        if len(declared_subcaches)!=len(files)-1:raise ValueError('extra/missing subcache file')
    def vmread(addr,n):
        for a,size,off,mm,path in maps:
            if a<=addr and addr+n<=a+size:return bytes(mm[off+addr-a:off+addr-a+n])
        raise ValueError('virtual range absent from declared cache mappings')
    mm=handles[0][1];io,ic=struct.unpack_from('<II',mm,24)
    if not ic:
        if u32(mm,16)<456:raise ValueError('unknown modern cache image table')
        io,ic=struct.unpack_from('<II',mm,448)
    if io+ic*32>len(mm) or ic>100000:raise ValueError('cache image table bound')
    images=[];hits=[]
    for i in range(ic):
        addr,mtime,inode,po,pad=struct.unpack_from('<QQQII',mm,io+i*32);end=mm.find(b'\0',po,min(len(mm),po+8192))
        if not 0<po<end:raise ValueError('image pathname bound')
        path=name(mm[po:end]);row={'index':i,'path':path,'address':addr}
        try:
            row.update(macho(lambda o,n:vmread(addr+o,n)))
            for s in row['sections']:
                if s['zero_fill'] or not s['size']:continue
                data=vmread(s['address'],s['size']);pos=0
                while (pos:=data.find(b'MTLB',pos))>=0:
                    hit={'image':path,'segment':s['segment'],'section':s['section'],'section_offset':pos,'address':s['address']+pos,'available_in_section':len(data)-pos}
                    for a,n,off,buf,fp in maps:
                        if a<=hit['address']<a+n:hit.update(cache_file=fp,cache_file_offset=off+hit['address']-a);break
                    hits.append(hit);pos+=4
        except (ValueError,struct.error) as e:row['error']=str(e)
        images.append(row)
    for f,mm in handles:mm.close();f.close()
    return {'primary':str(primary),'files':files,'declared_subcaches':declared_subcaches,'declared_image_count':ic,'images':images,'MTLB_magic_candidates':hits,'limits':['MTLB magic candidates require format/bounds validation; no validity or executability inferred.','Scan covers non-zero-fill declared Mach-O sections, not unallocated cache padding or compressed/nested arbitrary resources.']}


def filesystem_inventory(root):
    counts={'regular_files':0,'symlinks':0,'directories':0};binaries=[];direct=[];errors=[]
    magics={b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf'}
    for folder,dirs,files in os.walk(root,followlinks=False,onerror=lambda e:errors.append({'path':e.filename,'error':str(e)})):
        counts['directories']+=1
        for n in files:
            p=Path(folder)/n;rel=str(p.relative_to(root))
            try:
                if p.is_symlink():counts['symlinks']+=1;continue
                if not p.is_file():continue
                counts['regular_files']+=1
                with p.open('rb') as f:magic=f.read(4)
                if magic==b'MTLB':direct.append({'path':rel,'bytes':p.stat().st_size,'sha256':digest(p)})
                if magic not in magics:continue
                row={'path':rel,'bytes':p.stat().st_size,'sha256':digest(p),'magic':magic.hex(),'slices':[]}
                with p.open('rb') as f:
                    mm=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ)
                    ranges=[(0,len(mm))]
                    if magic in (b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf'):
                        endian='<' if magic==b'\xbe\xba\xfe\xca' else '>';wide=magic==b'\xca\xfe\xba\xbf';count=struct.unpack_from(endian+'I',mm,4)[0];width=32 if wide else 20
                        if count>128 or 8+count*width>len(mm):raise ValueError('FAT table bounds')
                        ranges=[]
                        for i in range(count):
                            off,sz=struct.unpack_from(endian+('QQ' if wide else 'II'),mm,8+i*width+8)
                            if off+sz>len(mm):raise ValueError('FAT slice bounds')
                            ranges.append((off,sz))
                    for off,sz in ranges:
                        s={'offset':off,'size':sz,'magic':bytes(mm[off:off+4]).hex()}
                        if mm[off:off+4]==b'MTLB':
                            s['classification']='FAT-contained MTLB; not Mach-O';row['slices'].append(s);continue
                        try:
                            def read(o,n):
                                if o+n>sz:raise ValueError('slice read bounds')
                                return bytes(mm[off+o:off+o+n])
                            s.update(macho(read));s['MTLB_magic_candidates']=[]
                            for section in s['sections']:
                                if section['zero_fill'] or not section['size']:continue
                                data=read(section['file_offset'],section['size']);pos=0
                                while (pos:=data.find(b'MTLB',pos))>=0:s['MTLB_magic_candidates'].append({'segment':section['segment'],'section':section['section'],'file_offset':off+section['file_offset']+pos,'available_in_section':len(data)-pos});pos+=4
                        except (ValueError,struct.error) as e:s['error']=str(e)
                        row['slices'].append(s)
                    mm.close()
                binaries.append(row)
            except (OSError,ValueError,struct.error) as e:errors.append({'path':rel,'error':str(e)})
    return {'root':str(root),'counts':counts,'binaries':binaries,'direct_MTLB':direct,'errors':errors,'limits':['No symlink traversal; aliases may refer to already inventoried paths or external overlays.','Header identity independent of extension. Nested compressed packages and arbitrary non-Mach-O data are not decoded.','Big-endian Mach-O headers are recorded unsupported rather than silently omitted.']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--cache',type=Path);p.add_argument('--root',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if bool(a.cache)==bool(a.root):p.error('exactly one --cache or --root')
    r=cache_inventory(a.cache) if a.cache else filesystem_inventory(a.root);a.output.write_text(json.dumps(r,indent=2)+'\n');print('saved',a.output)
if __name__=='__main__':main()
