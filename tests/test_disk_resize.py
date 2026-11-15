"""Exercise production GPT expansion independently using Python's CRC32 oracle."""
from pathlib import Path
import fcntl
import hashlib
import os
import platform
import struct
import subprocess
import tempfile
import zlib
ROOT=Path(__file__).resolve().parents[1]
B=ROOT/'build/disk-resize';B.mkdir(parents=True,exist_ok=True)
command=['cc','-std=c11','-Wall','-Wextra','-Werror','-O1','-g','-fsanitize=address,undefined','-Ihost','host/disk_resize.c','tests/disk_resize_driver.c','-o',str(B/'grow')]
if platform.system()!='Darwin':command.insert(1,'-DHENGE_DISK_RESIZE_TEST')
subprocess.run(command,cwd=ROOT,check=True)
SIZE=4*1024*1024
APFS=bytes.fromhex('ef57347c0000aa11aa1100306543ecac')
def fixture(path,corrupt=False,recovery=False):
    sectors=SIZE//512
    entries=bytearray(128*128);entries[:16]=APFS;entries[16:32]=bytes(range(16))
    struct.pack_into('<QQ',entries,32,40,sectors-40)
    if recovery:
        struct.pack_into('<Q',entries,40,sectors-100)
        entries[128:144]=b'R'*16;struct.pack_into('<QQ',entries,128+32,sectors-99,sectors-34)
    def header(here,other,table):
        h=bytearray(512);h[:8]=b'EFI PART';struct.pack_into('<III',h,8,0x10000,92,0)
        struct.pack_into('<QQQQ',h,24,here,other,34,sectors-34);h[56:72]=bytes(range(16));struct.pack_into('<QIII',h,72,table,128,128,zlib.crc32(entries))
        struct.pack_into('<I',h,16,zlib.crc32(h[:92]));return h
    mbr=bytearray(512);mbr[510:]=b'\x55\xaa';mbr[450]=0xee;struct.pack_into('<II',mbr,454,1,sectors-1)
    with path.open('wb') as f:
        f.truncate(SIZE);f.seek(0);f.write(mbr);f.write(header(1,sectors-1,2));f.write(entries)
        f.seek(100*512);f.write(b'USER DATA MUST SURVIVE')
        f.seek((sectors-33)*512);f.write(entries);f.write(header(sectors-1,1,sectors-33))
    if corrupt:
        with path.open('r+b') as f:f.seek(512+16);f.write(b'bad!')
def grow(path,size,okay):
    r=subprocess.run([str(B/'grow'),str(path),str(size)],capture_output=True,text=True)
    assert (r.returncode==0)==okay,r.stderr
    return r
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder);image=root/'disk.img';fixture(image);original=image.read_bytes()
    assert grow(image,SIZE*2,True).stdout.strip()=='1'
    assert image.stat().st_size==SIZE*2
    assert Path(str(image)+'.before-expansion').read_bytes()==original
    with image.open('rb') as f:
        front=f.read(1024);primary=bytearray(front[512:]);f.seek(SIZE*2-512);backup=bytearray(f.read(512))
        f.seek(100*512);assert f.read(len(b'USER DATA MUST SURVIVE'))==b'USER DATA MUST SURVIVE'
        for h in [primary,backup]:
            wanted=struct.unpack_from('<I',h,16)[0];struct.pack_into('<I',h,16,0);assert zlib.crc32(h[:92])==wanted
        assert struct.unpack_from('<Q',primary,32)[0]==SIZE*2//512-1
        assert struct.unpack_from('<Q',backup,24)[0]==SIZE*2//512-1
        assert struct.unpack_from('<Q',primary,48)[0]==SIZE*2//512-34
        assert struct.unpack_from('<I',front,458)[0]==SIZE*2//512-1
    before=hashlib.sha256(image.read_bytes()).digest();grow(image,SIZE*3,False);assert hashlib.sha256(image.read_bytes()).digest()==before
    for kind in ['crc','shrink','locked','non-gpt','recovery']:
        path=root/kind;fixture(path,corrupt=kind=='crc',recovery=kind=='recovery');old=path.read_bytes()
        if kind=='non-gpt':path.write_bytes(b'\0'*SIZE);old=path.read_bytes()
        if kind=='locked':
            with path.open('r+b') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);grow(path,SIZE*2,False)
        else:
            r=grow(path,SIZE//2 if kind=='shrink' else SIZE*2,kind=='recovery')
            if kind=='recovery':assert r.stdout.strip()=='0';continue
        assert path.read_bytes()==old and not Path(str(path)+'.before-expansion').exists()
print('PASS production disk expansion: GPT CRCs/backup relocation, sparse capacity, original backup, payload preservation, busy/shrink/corrupt/non-GPT rejection; recovery partition is never moved')

RECOVERY=bytes.fromhex('727663520079aa11aa1100306543ecac')
def sealed(h):
    struct.pack_into('<I',h,16,0);struct.pack_into('<I',h,16,zlib.crc32(h[:92]));return h
def modify_recovery(path,valid=True,known=True):
    with path.open('r+b') as f:
        f.seek(1024);entries=bytearray(f.read(128*128))
        entries[128:144]=RECOVERY if known else b'R'*16
        entries[144:160]=bytes(reversed(range(16)))
        start,end=struct.unpack_from('<QQ',entries,160)
        data=bytearray((i*37+11)%256 for i in range((end-start+1)*512))
        block=bytearray(4096);block[32:36]=b'NXSB';struct.pack_into('<IQ',block,36,4096,len(data)//4096)
        a=b=0;mod=0xffffffff
        for word in struct.unpack('<1022I',block[8:]):a=(a+word)%mod;b=(b+a)%mod
        low=mod-((a+b)%mod);high=mod-((a+low)%mod);struct.pack_into('<Q',block,0,low|(high<<32))
        if not valid:block[100]^=1
        data[:4096]=block;f.seek(start*512);f.write(data)
        for offset in [512,SIZE-512]:
            f.seek(offset);h=bytearray(f.read(512));struct.pack_into('<I',h,88,zlib.crc32(entries))
            table=struct.unpack_from('<Q',h,72)[0];f.seek(table*512);f.write(entries);f.seek(offset);f.write(sealed(h))
    return bytes(data)
def check_gpt(path):
    with path.open('rb') as f:
        f.seek(512);a=bytearray(f.read(512));f.seek(path.stat().st_size-512);b=bytearray(f.read(512));tables=[]
        for h in [a,b]:
            wanted=struct.unpack_from('<I',h,16)[0];struct.pack_into('<I',h,16,0);assert zlib.crc32(h[:92])==wanted
            f.seek(struct.unpack_from('<Q',h,72)[0]*512);table=f.read(128*128);assert zlib.crc32(table)==struct.unpack_from('<I',h,88)[0];tables.append(table)
        assert tables[0]==tables[1];return tables[0]
with tempfile.TemporaryDirectory() as folder:
    root=Path(folder)
    for label in ['valid','bad-nx-checksum','unknown-type']:
        image=root/label;fixture(image,recovery=True)
        payload=modify_recovery(image,valid=label!='bad-nx-checksum',known=label!='unknown-type')
        grow(image,SIZE*2,True);expanded=image.read_bytes();oldtable=check_gpt(image)
        info=list(map(int,grow(image,'inspect',True).stdout.split()))
        assert info[0]==SIZE*2 and info[4]==1 and info[6]==(label=='valid')
        grow(image,'prepare',label=='valid')
        if label!='valid':
            assert image.read_bytes()==expanded and not Path(str(image)+'.before-apfs-expansion').exists();continue
        assert Path(str(image)+'.before-apfs-expansion').read_bytes()==expanded
        newtable=check_gpt(image);assert newtable[:128]==oldtable[:128]
        assert newtable[128:160]==oldtable[128:160]
        start,end=struct.unpack_from('<QQ',newtable,160);oldend=struct.unpack_from('<Q',oldtable,168)[0]
        assert start%2048==0 and start>oldend and (end-start+1)*512==len(payload)
        with image.open('rb') as f:
            f.seek(start*512);assert f.read(len(payload))==payload
            f.seek(100*512);assert f.read(len(b'USER DATA MUST SURVIVE'))==b'USER DATA MUST SURVIVE'
        after=image.read_bytes();grow(image,'prepare',True);assert image.read_bytes()==after
        info=list(map(int,grow(image,'inspect',True).stdout.split()));assert info[2]>1024*1024 and info[6]==0
print('PASS APFS expansion preparation: read-only inspection, Recovery NX checksum/type guards, verified nonoverlapping aligned copy, UUID/data preservation, both GPT CRCs, atomic backup, idempotence')
