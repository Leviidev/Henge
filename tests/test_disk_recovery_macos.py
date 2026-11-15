"""Real APFS integration on an isolated disposable raw image, never the host disk.
The Recovery container has real APFS data but no bootable Recovery OS: boot policy
and firmware recovery remain physical-guest validation, not claims of this test.
"""
from pathlib import Path
import os
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

if sys.platform != 'darwin':
    raise SystemExit('This real APFS integration test requires macOS')
ROOT=Path(__file__).resolve().parents[1]
DRIVER=ROOT/'build/disk-resize/grow'
assert DRIVER.is_file(), 'Run test_disk_resize.py to build the production driver first'
RECOVERY=bytes.fromhex('727663520079aa11aa1100306543ecac')

def run(*args,plist=False):
    result=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180)
    if result.returncode:
        raise RuntimeError(f'{args!r}: {result.stderr.decode(errors="replace")} {result.stdout.decode(errors="replace")}')
    return plistlib.loads(result.stdout) if plist else result.stdout.decode(errors='replace')

def attach(image):
    info=run('hdiutil','attach','-imagekey','diskimage-class=CRawDiskImage','-nomount','-nobrowse','-plist',str(image),plist=True)
    entities=info['system-entities']
    devices=[v['dev-entry'] for v in entities if re.fullmatch(r'/dev/disk[0-9]+',v.get('dev-entry','')) and v.get('content-hint')=='GUID_partition_scheme']
    if not devices:
        # An initially blank raw image has no partition-scheme hint yet.
        first=entities[0];assert not first.get('content-hint') and re.fullmatch(r'/dev/disk[0-9]+',first.get('dev-entry','')),info
        devices=[first['dev-entry']]
    assert len(devices)==1,info
    # Bind every mutating command to the whole device returned for OUR image.
    device=devices[0]
    images=run('hdiutil','info','-plist',plist=True)['images']
    owned=[v for v in images if Path(v.get('image-path','')).resolve()==image.resolve()]
    assert len(owned)==1 and any(v.get('dev-entry')==device for v in owned[0]['system-entities'])
    return device

def detach(device,expected_image):
    # Resolve only containers whose physical stores belong to this disposable
    # image. APFS uses synthesized devices: unmounting just the backing disk
    # can leave those volumes open in Disk Arbitration.
    owned=containers(device)
    for container in owned:
        run('diskutil','unmountDisk',container['ContainerReference'])
    run('diskutil','unmountDisk',device)
    for container in owned:
        for volume in container.get('Volumes',[]):
            info=run('diskutil','info','-plist',volume['DeviceIdentifier'],plist=True)
            assert not info.get('Mounted') and not info.get('MountPoint'),info
    def attached():
        images=run('hdiutil','info','-plist',plist=True)['images']
        return [v for v in images if any(e.get('dev-entry')==device for e in v['system-entities'])]
    image_owner=attached()
    assert len(image_owner)==1 and Path(image_owner[0]['image-path']).resolve()==expected_image.resolve()
    errors=[]
    for command in [('diskutil','eject',device),('hdiutil','detach',device)]:
        result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
        if not attached():break
        errors.append((command,result.returncode,result.stderr.decode(errors='replace')))
    else:
        # Both public eject interfaces can leave an image-provider handle busy
        # after a *successful clean filesystem unmount*. Only then close our
        # provider forcibly; never force a mounted filesystem or another image.
        current=attached()
        assert len(current)==1 and current[0]['image-path']==image_owner[0]['image-path'],current
        for container in containers(device):
            for volume in container.get('Volumes',[]):
                info=run('diskutil','info','-plist',volume['DeviceIdentifier'],plist=True)
                assert not info.get('Mounted') and not info.get('MountPoint'),info
        print('Cleanly unmounted disposable APFS image retained by provider; closing verified owned handle:',errors,flush=True)
        run('hdiutil','detach','-force',device)
    assert not attached(),errors

def containers(device):
    prefix=device.removeprefix('/dev/')+'s'
    return [c for c in run('diskutil','apfs','list','-plist',plist=True)['Containers']
            if any(p.get('DeviceIdentifier','').startswith(prefix) for p in c.get('PhysicalStores',[]))]

def named(device,name):
    matches=[(c,v) for c in containers(device) for v in c.get('Volumes',[]) if v.get('Name')==name]
    assert len(matches)==1,(name,containers(device))
    return matches[0]

def mounted(volume,name):
    identifier=volume['DeviceIdentifier'];run('diskutil','mount',identifier)
    info=run('diskutil','info','-plist',identifier,plist=True)
    assert info['VolumeName']==name and info['MountPoint'].startswith('/Volumes/')
    path=Path(info['MountPoint'])
    (path/'.metadata_never_index').touch(exist_ok=True)
    return path

def mark_recovery(image):
    # Offline GPT-only type update models the real trailing Recovery partition.
    # The Apple APFS filesystem itself was created by diskutil, not our fixture.
    with image.open('r+b') as f:
        f.seek(512);primary=bytearray(f.read(512));f.seek(image.stat().st_size-512);backup=bytearray(f.read(512))
        count,stride=struct.unpack_from('<II',primary,80)
        f.seek(struct.unpack_from('<Q',primary,72)[0]*512);entries=bytearray(f.read(count*stride))
        apfs=bytes.fromhex('ef57347c0000aa11aa1100306543ecac')
        indexes=[i for i in range(count) if entries[i*stride:i*stride+16]==apfs]
        assert len(indexes)==2
        index=max(indexes,key=lambda i:struct.unpack_from('<Q',entries,i*stride+40)[0])
        entries[index*stride:index*stride+16]=RECOVERY
        identity=bytes(entries[index*stride+16:index*stride+32])
        for header,offset in [(primary,512),(backup,image.stat().st_size-512)]:
            struct.pack_into('<I',header,88,zlib.crc32(entries));struct.pack_into('<I',header,16,0)
            struct.pack_into('<I',header,16,zlib.crc32(header[:struct.unpack_from('<I',header,12)[0]]))
            f.seek(struct.unpack_from('<Q',header,72)[0]*512);f.write(entries);f.seek(offset);f.write(header)
        f.flush();os.fsync(f.fileno())
    return identity

with tempfile.TemporaryDirectory(prefix='henge-apfs-integration-') as directory:
    image=Path(directory)/'test.img'
    with image.open('wb') as f:f.truncate(1<<30)
    device=None;tag=uuid.uuid4().hex[:10];main_name='HengeMain-'+tag;recovery_name='HengeRecovery-'+tag
    payload=os.urandom(65536)
    try:
        device=attach(image)
        run('diskutil','partitionDisk',device,'GPT','APFS',main_name,'384m','APFS',recovery_name,'R')
        main,main_vol=named(device,main_name);recovery,recovery_vol=named(device,recovery_name)
        original_capacity=main['CapacityCeiling'];recovery_capacity=recovery['CapacityCeiling']
        recovery_uuid=recovery['APFSContainerUUID']
        for volume,name in [(main_vol,main_name),(recovery_vol,recovery_name)]:
            path=mounted(volume,name)/'henge-verification.bin'
            with path.open('wb') as f:f.write(payload);f.flush();os.fsync(f.fileno())
        detach(device,image);device=None
        recovery_identity=mark_recovery(image)
        run(str(DRIVER),str(image),str(2<<30))
        inspect=list(map(int,run(str(DRIVER),str(image),'inspect').split()))
        assert inspect[6]==1,inspect
        run(str(DRIVER),str(image),'prepare')
        assert Path(str(image)+'.before-expansion').exists() and Path(str(image)+'.before-apfs-expansion').exists()
        device=attach(image)
        main,main_vol=named(device,main_name);recovery,recovery_vol=named(device,recovery_name)
        assert recovery['APFSContainerUUID']==recovery_uuid and recovery['CapacityCeiling']==recovery_capacity
        run('diskutil','apfs','resizeContainer',main['ContainerReference'],'0')
        main,main_vol=named(device,main_name);recovery,recovery_vol=named(device,recovery_name)
        assert main['CapacityCeiling']>original_capacity+(512<<20),(original_capacity,main)
        for volume,name in [(main_vol,main_name),(recovery_vol,recovery_name)]:
            assert (mounted(volume,name)/'henge-verification.bin').read_bytes()==payload
            run('diskutil','verifyVolume',volume['DeviceIdentifier'])
        detach(device,image);device=None
        with image.open('rb') as f:
            f.seek(512);h=f.read(512);count,stride=struct.unpack_from('<II',h,80)
            f.seek(struct.unpack_from('<Q',h,72)[0]*512);entries=f.read(count*stride)
            recovery_entries=[entries[i*stride:(i+1)*stride] for i in range(count) if entries[i*stride:i*stride+16]==RECOVERY]
            assert len(recovery_entries)==1 and recovery_entries[0][16:32]==recovery_identity
        print('PASS real APFS expansion: production Recovery relocation, native diskutil container growth, both mounted payloads and filesystem verification, Recovery UUID/GPT identity preserved')
    finally:
        if device:
            subprocess.run(['hdiutil','detach','-force',device],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
